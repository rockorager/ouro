//! Dynamically sized desktop interaction owner.
//!
//! This module keeps physical device aggregation, desktop policy mutation, and
//! protocol publication separate. It hit-tests copied scene values, updates
//! desktop focus synchronously, and retains protocol-neutral focus commands for
//! the composition root to apply at a turn boundary.

const std = @import("std");
const input = @import("../backend/input/backend.zig");
const input_platform = @import("../backend/input/platform.zig");
const geometry = @import("../scene/geometry.zig");
const hit_test = @import("../scene/hit_test.zig");
const cursor_model = @import("../scene/cursor.zig");

const code_count = 0x300;
const state_words = code_count / 64;
const key_tab = 15;
const key_q = 16;
const key_f = 33;
const key_m = 50;
const key_space = 57;
const key_j = 36;
const key_k = 37;
const key_left_shift = 42;
const key_right_shift = 54;
const key_left_meta = 125;
const key_right_meta = 126;

pub const Config = struct {
    window_capacity: usize,
    device_capacity: usize,
    command_capacity: usize,
    bounds: geometry.Rect,
    initial_position: geometry.Point = .{ .x = 0, .y = 0 },
};

pub fn Interaction(comptime Desktop: type) type {
    return struct {
        const Self = @This();
        pub const SceneWindow = Desktop.SceneWindow;
        pub const ToplevelId = @TypeOf(@as(SceneWindow, undefined).id);
        pub const SurfaceId = @TypeOf(@as(SceneWindow, undefined).surface);
        pub const Cursor = cursor_model.Cursor(SurfaceId);

        pub const Target = struct {
            toplevel: ToplevelId,
            surface: SurfaceId,
            /// Surface-local wl_fixed (24.8) coordinates.
            point: FixedPoint,
        };
        pub const FixedPoint = struct { x: i32, y: i32 };
        pub const Cancellation = packed struct {
            pointer_focus: bool = false,
            keyboard_focus: bool = false,
            pointer_grab: bool = false,
            _padding: u5 = 0,
        };
        pub const Command = union(enum) {
            pointer_focus: ?Target,
            keyboard_focus: Target,
            cancel: Cancellation,
            key_consumed,
            close: ToplevelId,
        };
        const InteractiveOperation = struct {
            target: Target,
            kind: Desktop.InteractiveKind,
            start_x_fixed: i64,
            start_y_fixed: i64,
            geometry: Desktop.InteractiveGeometry,
        };
        pub const Mode = union(enum) {
            default,
            button_grab: Target,
            popup_grab: struct { toplevel: ToplevelId, surface: SurfaceId },
            interactive: InteractiveOperation,
        };

        const Device = struct {
            active: bool = false,
            id: input.DeviceId = undefined,
            capabilities: input_platform.Capabilities = .{},
            buttons: [state_words]u64 = [_]u64{0} ** state_words,
            keys: [state_words]u64 = [_]u64{0} ** state_words,
            swallowed_keys: [state_words]u64 = [_]u64{0} ** state_words,
        };

        allocator: std.mem.Allocator,
        bounds: geometry.Rect,
        x_fixed: i64,
        y_fixed: i64,
        windows: []SceneWindow,
        devices: []Device,
        commands: []Command,
        command_head: usize = 0,
        command_len: usize = 0,
        pointer_devices: usize = 0,
        hover: ?Target = null,
        pointer_inside: bool = false,
        keyboard_focus: ?Target = null,
        mode: Mode = .default,
        cursor: Cursor = .{},

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            if (config.window_capacity == 0 or config.device_capacity == 0 or
                config.command_capacity == 0)
                return error.InvalidConfig;
            const command_slots = std.math.add(usize, config.command_capacity, 1) catch
                return error.InvalidConfig;
            try config.bounds.validate();
            if (!config.bounds.contains(config.initial_position)) return error.InvalidConfig;
            try validateFixedBounds(config.bounds);
            const windows = try allocator.alloc(SceneWindow, config.window_capacity);
            errdefer allocator.free(windows);
            const devices = try allocator.alloc(Device, config.device_capacity);
            errdefer allocator.free(devices);
            // One extra slot is reserved for destruction/device-loss cancellation.
            const commands = try allocator.alloc(Command, command_slots);
            @memset(devices, .{});
            return .{
                .allocator = allocator,
                .bounds = config.bounds,
                .x_fixed = @as(i64, config.initial_position.x) * 256,
                .y_fixed = @as(i64, config.initial_position.y) * 256,
                .windows = windows,
                .devices = devices,
                .commands = commands,
                .cursor = .{ .position = config.initial_position },
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.commands);
            self.allocator.free(self.devices);
            self.allocator.free(self.windows);
            self.* = undefined;
        }

        /// Consumes one normalized input event transactionally. On ordinary
        /// command backpressure, no interaction or desktop state changes.
        pub fn consume(
            self: *Self,
            desktop: *Desktop,
            surfaces: anytype,
            event: input.Event,
        ) !void {
            switch (event) {
                .device_added => |value| try self.addDevice(value.device, value.capabilities),
                .device_removed => |id| try self.removeDevice(desktop, id),
                .pointer_motion => |value| try self.pointerMotion(
                    desktop,
                    surfaces,
                    value.device,
                    value.dx,
                    value.dy,
                ),
                .pointer_button => |value| try self.pointerButton(
                    desktop,
                    value.device,
                    value.button,
                    value.pressed,
                ),
                .pointer_axis => |value| _ = try self.resolveDevice(value.device),
                .swipe_begin => |value| try self.acceptGesture(value.device),
                .swipe_update => |value| try self.acceptGesture(value.device),
                .swipe_end => |value| try self.acceptGesture(value.device),
                .pinch_begin => |value| try self.acceptGesture(value.device),
                .pinch_update => |value| try self.acceptGesture(value.device),
                .pinch_end => |value| try self.acceptGesture(value.device),
                .hold_begin => |value| try self.acceptGesture(value.device),
                .hold_end => |value| try self.acceptGesture(value.device),
                .keyboard_key => |value| try self.keyboardKey(
                    desktop,
                    value.device,
                    value.key,
                    value.pressed,
                ),
            }
        }

        fn acceptGesture(self: *Self, device_id: input.DeviceId) !void {
            const device = try self.resolveDevice(device_id);
            if (!device.capabilities.pointer) return error.MissingCapability;
        }

        pub fn peekCommand(self: *const Self) ?Command {
            if (self.command_len == 0) return null;
            return self.commands[self.command_head];
        }

        pub fn dropCommand(self: *Self) void {
            if (self.command_len == 0) return;
            self.command_head = (self.command_head + 1) % self.commands.len;
            self.command_len -= 1;
        }

        pub fn pendingCommands(self: *const Self) usize {
            return self.command_len;
        }

        pub fn pointerPosition(self: *const Self) geometry.Point {
            return .{ .x = fixedFloor(self.x_fixed), .y = fixedFloor(self.y_fixed) };
        }

        pub fn validatePointerMotion(
            self: *Self,
            device_id: input.DeviceId,
            dx: f64,
            dy: f64,
        ) !void {
            const device = try self.resolveDevice(device_id);
            if (!device.capabilities.pointer) return error.MissingCapability;
            if (!std.math.isFinite(dx) or !std.math.isFinite(dy)) return error.InvalidMotion;
        }

        /// Preflights an output-derived pointer domain without changing any
        /// retained focus, pointer, or cursor state.
        pub fn validateBounds(_: *const Self, bounds: geometry.Rect) !void {
            try bounds.validate();
            try validateFixedBounds(bounds);
        }

        /// Applies bounds previously accepted by `validateBounds`. The turn is
        /// single-threaded, so output creation can validate all owners first
        /// and then publish this clamp without a fallible trailing edge.
        pub fn applyBounds(self: *Self, bounds: geometry.Rect) void {
            self.validateBounds(bounds) catch unreachable;
            self.bounds = bounds;
            self.x_fixed = clampFixed(self.x_fixed, bounds.x, bounds.width);
            self.y_fixed = clampFixed(self.y_fixed, bounds.y, bounds.height);
            self.cursor.move(self.pointerPosition());
        }

        pub fn interactionMode(self: *const Self) Mode {
            return self.mode;
        }

        pub fn cursorRequest(self: *Self, surface: ?SurfaceId, hotspot: geometry.Point) void {
            self.cursor.request(surface, hotspot);
        }

        pub fn setPopupGrab(self: *Self, target: anytype) void {
            if (target) |value| {
                if (self.mode == .interactive) return;
                self.mode = .{ .popup_grab = .{
                    .toplevel = value.toplevel,
                    .surface = value.surface,
                } };
            } else if (self.mode == .popup_grab) {
                self.mode = .default;
            }
        }

        pub fn beginInteractive(self: *Self, desktop: *Desktop, request: Desktop.InteractiveRequest) !void {
            const target = switch (self.mode) {
                .button_grab => |value| value,
                else => return,
            };
            if (!std.meta.eql(target.toplevel, request.id)) return;
            const value = try desktop.beginInteractive(request) orelse return;
            self.mode = .{ .interactive = .{
                .target = target,
                .kind = request.kind,
                .start_x_fixed = self.x_fixed,
                .start_y_fixed = self.y_fixed,
                .geometry = value,
            } };
            self.keyboard_focus = target;
        }

        /// Applies a compositor-policy focus request, such as a validated
        /// xdg-activation token, through the same desktop and seat command
        /// boundary as an implicit pointer grab.
        pub fn activateToplevel(
            self: *Self,
            desktop: *Desktop,
            toplevel: ToplevelId,
            surface: SurfaceId,
        ) !void {
            try self.ensureCommandCapacity(1);
            try desktop.focusToplevel(toplevel);
            const target: Target = .{
                .toplevel = toplevel,
                .surface = surface,
                .point = .{ .x = 0, .y = 0 },
            };
            self.keyboard_focus = target;
            self.enqueue(.{ .keyboard_focus = target });
        }

        /// Cancels every state edge naming an exact destroyed surface. Seat
        /// resource teardown independently drops stale wire operations; this
        /// terminal command handles still-live protocol focus on device loss.
        pub fn surfaceDestroyed(self: *Self, surface: SurfaceId) void {
            self.cursor.surfaceDestroyed(surface);
            self.removeCommandsMatching(null, surface);
            self.cancelMatching(null, surface);
        }

        pub fn toplevelDestroyed(self: *Self, toplevel: ToplevelId) void {
            self.removeCommandsMatching(toplevel, null);
            self.cancelMatching(toplevel, null);
        }

        fn pointerMotion(
            self: *Self,
            desktop: *Desktop,
            surfaces: anytype,
            device_id: input.DeviceId,
            dx: f64,
            dy: f64,
        ) !void {
            try self.validatePointerMotion(device_id, dx, dy);
            try self.ensureCommandCapacity(1);
            const next_x = clampFixed(self.x_fixed +| fixedDelta(dx), self.bounds.x, self.bounds.width);
            const next_y = clampFixed(self.y_fixed +| fixedDelta(dy), self.bounds.y, self.bounds.height);
            const interactive_rect: ?geometry.Rect = if (self.mode == .interactive) rect: {
                const operation = self.mode.interactive;
                break :rect interactiveRect(
                    operation,
                    fixedFloor(next_x) - fixedFloor(operation.start_x_fixed),
                    fixedFloor(next_y) - fixedFloor(operation.start_y_fixed),
                    self.bounds,
                ) catch return error.InvalidGeometry;
            } else null;
            const point: geometry.Point = .{ .x = fixedFloor(next_x), .y = fixedFloor(next_y) };
            const windows = while (true) {
                break desktop.sceneSnapshot(self.windows) catch {
                    const capacity = std.math.mul(usize, self.windows.len, 2) catch
                        return error.OutOfMemory;
                    self.windows = try self.allocator.realloc(self.windows, capacity);
                    continue;
                };
            };
            const hit = surfaces.topmost(SceneWindow, windows, point);
            var target: ?Target = if (hit) |value| target: {
                const local_x = next_x - @as(i64, point.x - value.local.x) * 256;
                const local_y = next_y - @as(i64, point.y - value.local.y) * 256;
                break :target .{
                    .toplevel = value.toplevel,
                    .surface = value.surface,
                    .point = .{
                        .x = std.math.cast(i32, local_x) orelse return error.InvalidGeometry,
                        .y = std.math.cast(i32, local_y) orelse return error.InvalidGeometry,
                    },
                };
            } else null;
            const inside = target != null;
            if (target == null) switch (self.mode) {
                .popup_grab => |grab| for (windows) |window| {
                    if (!window.visible or !window.content_ready or
                        !std.meta.eql(window.surface, grab.surface)) continue;
                    target = .{
                        .toplevel = grab.toplevel,
                        .surface = grab.surface,
                        .point = .{
                            .x = std.math.cast(i32, next_x - @as(i64, window.geometry.x) * 256) orelse
                                return error.InvalidGeometry,
                            .y = std.math.cast(i32, next_y - @as(i64, window.geometry.y) * 256) orelse
                                return error.InvalidGeometry,
                        },
                    };
                    break;
                },
                else => {},
            };
            if (interactive_rect) |rect|
                try desktop.updateInteractive(self.mode.interactive.target.toplevel, rect);
            self.enqueue(.{ .pointer_focus = target });
            self.x_fixed = next_x;
            self.y_fixed = next_y;
            self.hover = target;
            self.pointer_inside = inside;
            self.cursor.move(point);
        }

        fn pointerButton(
            self: *Self,
            desktop: *Desktop,
            device_id: input.DeviceId,
            button: u32,
            pressed: bool,
        ) !void {
            if (button >= code_count) return error.InvalidCode;
            const device = try self.resolveDevice(device_id);
            if (!device.capabilities.pointer) return error.MissingCapability;
            const was = bitSet(&device.buttons, button);
            if (was == pressed) return;
            const aggregate_was = self.anyDeviceButton(button);
            const aggregate_after = pressed or self.otherDeviceButton(device, button);
            const dismisses_popup = !aggregate_was and aggregate_after and
                self.mode == .popup_grab and !self.pointer_inside;
            if (dismisses_popup) _ = try desktop.dismissPopupGrab();
            const begins_grab = !aggregate_was and aggregate_after and self.mode == .default and
                self.hover != null;
            if (begins_grab) {
                try self.ensureCommandCapacity(1);
                try desktop.focusToplevel(self.hover.?.toplevel);
            }
            const ends_interactive = !aggregate_after and !self.anyOtherPressedButton(device, button) and
                self.mode == .interactive;
            if (ends_interactive) try desktop.endInteractive(self.mode.interactive.target.toplevel);
            writeBit(&device.buttons, button, pressed);
            if (begins_grab) {
                const target = self.hover.?;
                self.mode = .{ .button_grab = target };
                self.keyboard_focus = target;
                self.enqueue(.{ .keyboard_focus = target });
            } else if (dismisses_popup) {
                self.mode = .default;
            } else if (!aggregate_after and !self.anyPressedButton() and
                (self.mode == .button_grab or self.mode == .interactive))
            {
                self.mode = .default;
            }
        }

        fn addDevice(
            self: *Self,
            id: input.DeviceId,
            capabilities: input_platform.Capabilities,
        ) !void {
            if (self.findDevice(id) != null) return error.DuplicateDevice;
            var available: ?*Device = null;
            for (self.devices) |*device| if (!device.active) {
                available = device;
                break;
            };
            const device = available orelse return error.DeviceCapacityExhausted;
            device.* = .{ .active = true, .id = id, .capabilities = capabilities };
            if (capabilities.pointer) {
                self.pointer_devices += 1;
                self.cursor.pointer_available = true;
            }
        }

        fn keyboardKey(
            self: *Self,
            desktop: *Desktop,
            device_id: input.DeviceId,
            key: u32,
            pressed: bool,
        ) !void {
            if (key >= code_count) return error.InvalidCode;
            const device = try self.resolveDevice(device_id);
            if (!device.capabilities.keyboard) return error.MissingCapability;
            const was = bitSet(&device.keys, key);
            if (was == pressed) return;
            const release_binding = !pressed and bitSet(&device.swallowed_keys, key);
            const meta = self.anyDeviceKey(key_left_meta) or self.anyDeviceKey(key_right_meta) or
                (pressed and (key == key_left_meta or key == key_right_meta));
            const shift = self.anyDeviceKey(key_left_shift) or self.anyDeviceKey(key_right_shift) or
                (pressed and (key == key_left_shift or key == key_right_shift));
            const binding = pressed and meta and isBindingKey(key);
            const close_target = if (binding and key == key_q) desktop.focusedToplevel() else null;
            if (binding or release_binding)
                try self.ensureCommandCapacity(1 + @as(usize, @intFromBool(close_target != null)));
            if (binding) switch (key) {
                key_tab => try desktop.focusNext(),
                key_q => {},
                key_f => try desktop.toggleFocusedFullscreen(),
                key_m => try desktop.toggleFocusedMaximized(),
                key_space => try desktop.toggleFocusedFloating(),
                key_j => if (shift) try desktop.moveFocusedTile(.next) else try desktop.focusNext(),
                key_k => if (shift) try desktop.moveFocusedTile(.previous) else try desktop.focusPrevious(),
                else => unreachable,
            };
            writeBit(&device.keys, key, pressed);
            writeBit(&device.swallowed_keys, key, binding);
            if (binding or release_binding) self.enqueue(.key_consumed);
            if (close_target) |id| self.enqueue(.{ .close = id });
        }

        fn removeDevice(self: *Self, desktop: *Desktop, id: input.DeviceId) !void {
            const device = self.findDevice(id) orelse return error.StaleDevice;
            const pointer = device.capabilities.pointer;
            const cancel_grab = pointer and (self.mode == .button_grab or self.mode == .interactive);
            if (pointer and self.mode == .interactive)
                try desktop.endInteractive(self.mode.interactive.target.toplevel);
            device.* = .{};
            if (pointer) self.pointer_devices -= 1;
            const lost_pointer = pointer and self.pointer_devices == 0;
            if (lost_pointer) self.cursor.pointer_available = false;
            if (cancel_grab or lost_pointer) {
                const cancellation: Cancellation = .{
                    .pointer_focus = lost_pointer and self.hover != null,
                    .pointer_grab = cancel_grab,
                };
                if (lost_pointer) self.hover = null;
                self.mode = .default;
                self.enqueueCancellation(cancellation);
            }
        }

        fn cancelMatching(
            self: *Self,
            toplevel: ?ToplevelId,
            surface: ?SurfaceId,
        ) void {
            const pointer = matches(self.hover, toplevel, surface);
            const keyboard = matches(self.keyboard_focus, toplevel, surface);
            const grab = switch (self.mode) {
                .button_grab => |target| matches(target, toplevel, surface),
                .popup_grab => |target| (toplevel == null or std.meta.eql(target.toplevel, toplevel.?)) and
                    (surface == null or std.meta.eql(target.surface, surface.?)),
                .interactive => |operation| matches(operation.target, toplevel, surface),
                .default => false,
            };
            if (!pointer and !keyboard and !grab) return;
            if (pointer) self.hover = null;
            if (keyboard) self.keyboard_focus = null;
            if (grab) self.mode = .default;
            self.enqueueCancellation(.{
                .pointer_focus = pointer,
                .keyboard_focus = keyboard,
                .pointer_grab = grab,
            });
        }

        fn ensureCommandCapacity(self: *Self, count: usize) !void {
            // A pending terminal edge is the trailing publication barrier.
            // Ordinary work waits until it drains, so later cancellation flags
            // can coalesce into that edge without changing command ordering.
            if (self.cancellationIndex() != null) return error.Backpressure;
            const needed = std.math.add(usize, self.command_len, count + 1) catch
                return error.OutOfMemory;
            if (needed <= self.commands.len) return;
            var capacity = self.commands.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            const replacement = try self.allocator.alloc(Command, capacity);
            for (0..self.command_len) |offset|
                replacement[offset] = self.commands[(self.command_head + offset) % self.commands.len];
            self.allocator.free(self.commands);
            self.commands = replacement;
            self.command_head = 0;
        }

        fn enqueue(self: *Self, command: Command) void {
            std.debug.assert(self.command_len < self.commands.len - 1);
            self.appendCommand(command);
        }

        fn enqueueCancellation(self: *Self, cancellation: Cancellation) void {
            if (self.cancellationIndex()) |index| {
                const pending = &self.commands[index].cancel;
                pending.pointer_focus = pending.pointer_focus or cancellation.pointer_focus;
                pending.keyboard_focus = pending.keyboard_focus or cancellation.keyboard_focus;
                pending.pointer_grab = pending.pointer_grab or cancellation.pointer_grab;
                return;
            }
            // Normal admission reserves this exact slot. Terminal publication
            // therefore never fails and never evicts an unrepresented edge.
            std.debug.assert(self.command_len < self.commands.len);
            self.appendCommand(.{ .cancel = cancellation });
        }

        fn appendCommand(self: *Self, command: Command) void {
            const tail = (self.command_head + self.command_len) % self.commands.len;
            self.commands[tail] = command;
            self.command_len += 1;
        }

        fn cancellationIndex(self: *const Self) ?usize {
            for (0..self.command_len) |offset| {
                const index = (self.command_head + offset) % self.commands.len;
                if (self.commands[index] == .cancel) return index;
            }
            return null;
        }

        fn removeCommandsMatching(
            self: *Self,
            toplevel: ?ToplevelId,
            surface: ?SurfaceId,
        ) void {
            var retained: usize = 0;
            const original_len = self.command_len;
            for (0..original_len) |offset| {
                const source = (self.command_head + offset) % self.commands.len;
                if (commandMatches(self.commands[source], toplevel, surface)) continue;
                const destination = (self.command_head + retained) % self.commands.len;
                self.commands[destination] = self.commands[source];
                retained += 1;
            }
            self.command_len = retained;
        }

        fn resolveDevice(self: *Self, id: input.DeviceId) !*Device {
            return self.findDevice(id) orelse error.StaleDevice;
        }

        fn findDevice(self: *Self, id: input.DeviceId) ?*Device {
            for (self.devices) |*device| if (device.active and std.meta.eql(device.id, id))
                return device;
            return null;
        }

        fn anyDeviceButton(self: *const Self, button: u32) bool {
            for (self.devices) |*device| if (device.active and bitSet(&device.buttons, button))
                return true;
            return false;
        }

        fn anyDeviceKey(self: *const Self, key: u32) bool {
            for (self.devices) |*device| if (device.active and bitSet(&device.keys, key))
                return true;
            return false;
        }

        fn otherDeviceButton(self: *const Self, excluded: *const Device, button: u32) bool {
            for (self.devices) |*device| if (device.active and device != excluded and
                bitSet(&device.buttons, button))
                return true;
            return false;
        }

        fn anyPressedButton(self: *const Self) bool {
            for (self.devices) |device| if (device.active) {
                for (device.buttons) |word| if (word != 0) return true;
            };
            return false;
        }

        fn anyOtherPressedButton(self: *const Self, changed: *const Device, button: u32) bool {
            for (self.devices) |*device| if (device.active) {
                for (device.buttons, 0..) |word, word_index| {
                    var value = word;
                    if (device == changed and word_index == button / 64)
                        value &= ~(@as(u64, 1) << @intCast(button % 64));
                    if (value != 0) return true;
                }
            };
            return false;
        }

        fn interactiveRect(operation: InteractiveOperation, dx: i32, dy: i32, bounds: geometry.Rect) !geometry.Rect {
            const original = operation.geometry.rect;
            if (operation.kind == .move) {
                const min_x = @as(i64, bounds.x) - original.width + 1;
                const max_x = @as(i64, bounds.x) + bounds.width - 1;
                const min_y = @as(i64, bounds.y) - original.height + 1;
                const max_y = @as(i64, bounds.y) + bounds.height - 1;
                return .{
                    .x = std.math.cast(i32, std.math.clamp(@as(i64, original.x) + dx, min_x, max_x)) orelse return error.InvalidGeometry,
                    .y = std.math.cast(i32, std.math.clamp(@as(i64, original.y) + dy, min_y, max_y)) orelse return error.InvalidGeometry,
                    .width = original.width,
                    .height = original.height,
                };
            }
            const edge = operation.kind.resize;
            var left: i64 = original.x;
            var right: i64 = @as(i64, original.x) + original.width;
            var top: i64 = original.y;
            var bottom: i64 = @as(i64, original.y) + original.height;
            const moves_left = edge == .left or edge == .top_left or edge == .bottom_left;
            const moves_right = edge == .right or edge == .top_right or edge == .bottom_right;
            const moves_top = edge == .top or edge == .top_left or edge == .top_right;
            const moves_bottom = edge == .bottom or edge == .bottom_left or edge == .bottom_right;
            if (moves_left) left += dx;
            if (moves_right) right += dx;
            if (moves_top) top += dy;
            if (moves_bottom) bottom += dy;
            constrainAxis(&left, &right, moves_left, operation.geometry.min_width, operation.geometry.max_width);
            constrainAxis(&top, &bottom, moves_top, operation.geometry.min_height, operation.geometry.max_height);
            const width = right - left;
            const height = bottom - top;
            return .{
                .x = std.math.cast(i32, left) orelse return error.InvalidGeometry,
                .y = std.math.cast(i32, top) orelse return error.InvalidGeometry,
                .width = std.math.cast(i32, width) orelse return error.InvalidGeometry,
                .height = std.math.cast(i32, height) orelse return error.InvalidGeometry,
            };
        }

        fn constrainAxis(start: *i64, end: *i64, moves_start: bool, minimum: i32, maximum: i32) void {
            const min_size: i64 = @max(minimum, 1);
            const max_size: i64 = if (maximum > 0) @max(maximum, minimum) else std.math.maxInt(i32);
            const size = std.math.clamp(end.* - start.*, min_size, max_size);
            if (moves_start) start.* = end.* - size else end.* = start.* + size;
        }

        fn commandMatches(
            command: Command,
            toplevel: ?ToplevelId,
            surface: ?SurfaceId,
        ) bool {
            return switch (command) {
                .pointer_focus => |target| matches(target, toplevel, surface),
                .keyboard_focus => |target| matches(target, toplevel, surface),
                .cancel => false,
                .key_consumed => false,
                .close => |id| toplevel != null and std.meta.eql(id, toplevel.?),
            };
        }

        fn matches(target: anytype, toplevel: ?ToplevelId, surface: ?SurfaceId) bool {
            const value: Target = switch (@typeInfo(@TypeOf(target))) {
                .optional => target orelse return false,
                else => target,
            };
            return (toplevel != null and std.meta.eql(value.toplevel, toplevel.?)) or
                (surface != null and std.meta.eql(value.surface, surface.?));
        }
    };
}

fn validateFixedBounds(bounds: geometry.Rect) !void {
    const right = @as(i64, bounds.x) + bounds.width - 1;
    const bottom = @as(i64, bounds.y) + bounds.height - 1;
    inline for (.{ @as(i64, bounds.x), @as(i64, bounds.y), right, bottom }) |coordinate|
        if (coordinate * 256 < std.math.minInt(i32) or
            coordinate * 256 > std.math.maxInt(i32))
            return error.InvalidConfig;
}

fn fixedDelta(value: f64) i64 {
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(scaled);
}

fn clampFixed(value: i64, origin: i32, extent: i32) i64 {
    const minimum = @as(i64, origin) * 256;
    const maximum = (@as(i64, origin) + extent) * 256 - 1;
    return std.math.clamp(value, minimum, maximum);
}

fn fixedFloor(value: i64) i32 {
    return @intCast(@divFloor(value, 256));
}

fn bitSet(words: *const [state_words]u64, code: u32) bool {
    return words[code / 64] & (@as(u64, 1) << @intCast(code % 64)) != 0;
}

fn writeBit(words: *[state_words]u64, code: u32, value: bool) void {
    const mask = @as(u64, 1) << @intCast(code % 64);
    if (value) words[code / 64] |= mask else words[code / 64] &= ~mask;
}

fn isBindingKey(key: u32) bool {
    return key == key_tab or key == key_q or key == key_f or key == key_m or key == key_space or
        key == key_j or key == key_k;
}

const TestId = packed struct { index: u32, generation: u32 };
const TestDesktop = struct {
    pub const InteractiveKind = union(enum) {
        move,
        resize: enum { top, bottom, left, top_left, bottom_left, right, top_right, bottom_right },
    };
    pub const InteractiveRequest = struct { id: TestId, kind: InteractiveKind };
    pub const InteractiveGeometry = struct {
        rect: geometry.Rect,
        min_width: i32,
        min_height: i32,
        max_width: i32,
        max_height: i32,
    };
    pub const SceneWindow = struct {
        id: TestId,
        surface: TestId,
        geometry: geometry.Rect,
        surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
        visible: bool,
        content_ready: bool,
    };

    windows: [2]SceneWindow,
    len: usize = 2,
    focused: ?TestId = null,
    reject_focus: bool = false,
    popup_dismissed: bool = false,
    focus_next_count: usize = 0,
    focus_previous_count: usize = 0,
    move_next_count: usize = 0,
    move_previous_count: usize = 0,
    fullscreen_count: usize = 0,
    maximized_count: usize = 0,
    floating_count: usize = 0,
    interactive_rect: ?geometry.Rect = null,
    resizing: bool = false,

    pub fn sceneSnapshot(self: *const @This(), output: []SceneWindow) ![]SceneWindow {
        if (output.len < self.len) return error.Exhausted;
        @memcpy(output[0..self.len], self.windows[0..self.len]);
        return output[0..self.len];
    }

    pub fn focusToplevel(self: *@This(), id: TestId) !void {
        if (self.reject_focus) return error.Backpressure;
        for (self.windows[0..self.len]) |window| if (std.meta.eql(window.id, id)) {
            if (!window.visible) return error.NotVisible;
            self.focused = id;
            return;
        };
        return error.StaleToplevel;
    }

    pub fn dismissPopupGrab(self: *@This()) !bool {
        self.popup_dismissed = true;
        return true;
    }

    pub fn focusNext(self: *@This()) !void {
        self.focus_next_count += 1;
    }

    pub fn focusPrevious(self: *@This()) !void {
        self.focus_previous_count += 1;
    }

    pub fn moveFocusedTile(self: *@This(), direction: enum { next, previous }) !void {
        switch (direction) {
            .next => self.move_next_count += 1,
            .previous => self.move_previous_count += 1,
        }
    }

    pub fn focusedToplevel(self: *const @This()) ?TestId {
        return self.focused;
    }

    pub fn toggleFocusedFullscreen(self: *@This()) !void {
        self.fullscreen_count += 1;
    }

    pub fn toggleFocusedMaximized(self: *@This()) !void {
        self.maximized_count += 1;
    }

    pub fn toggleFocusedFloating(self: *@This()) !void {
        self.floating_count += 1;
    }

    pub fn beginInteractive(self: *@This(), request: InteractiveRequest) !?InteractiveGeometry {
        for (self.windows[0..self.len]) |window| if (std.meta.eql(window.id, request.id)) {
            self.resizing = request.kind == .resize;
            return .{
                .rect = window.geometry,
                .min_width = 5,
                .min_height = 4,
                .max_width = 50,
                .max_height = 40,
            };
        };
        return error.StaleToplevel;
    }

    pub fn updateInteractive(self: *@This(), _: TestId, rect: geometry.Rect) !void {
        self.interactive_rect = rect;
    }

    pub fn endInteractive(self: *@This(), _: TestId) !void {
        self.resizing = false;
    }
};

const TestSurfaces = struct {
    hole_surface: ?TestId = null,

    pub fn topmost(
        self: *@This(),
        comptime Window: type,
        windows: []const Window,
        point: geometry.Point,
    ) ?hit_test.Hit(Window) {
        return hit_test.topmost(Window, windows, point, self);
    }

    pub fn inputContains(self: *@This(), surface: TestId, point: geometry.Point) !bool {
        _ = point;
        return self.hole_surface == null or !std.meta.eql(self.hole_surface.?, surface);
    }
};

const TestInteraction = Interaction(TestDesktop);
const device_a: input.DeviceId = .{ .slot = 0, .generation = 4, .seat_generation = 2 };
const device_b: input.DeviceId = .{ .slot = 1, .generation = 7, .seat_generation = 2 };

fn testDesktop() TestDesktop {
    return .{ .windows = .{
        .{
            .id = .{ .index = 1, .generation = 5 },
            .surface = .{ .index = 11, .generation = 8 },
            .geometry = .{ .x = 0, .y = 0, .width = 40, .height = 30 },
            .visible = true,
            .content_ready = true,
        },
        .{
            .id = .{ .index = 2, .generation = 6 },
            .surface = .{ .index = 12, .generation = 9 },
            .geometry = .{ .x = 10, .y = 5, .width = 20, .height = 20 },
            .visible = true,
            .content_ready = true,
        },
    } };
}

fn initTestInteraction(command_capacity: usize) !TestInteraction {
    return TestInteraction.init(std.testing.allocator, .{
        .window_capacity = 2,
        .device_capacity = 2,
        .command_capacity = command_capacity,
        .bounds = .{ .x = 0, .y = 0, .width = 40, .height = 30 },
        .initial_position = .{ .x = 1, .y = 1 },
    });
}

fn addPointer(interaction: *TestInteraction, desktop: *TestDesktop, surfaces: *TestSurfaces) !void {
    try interaction.consume(desktop, surfaces, .{ .device_added = .{
        .device = device_a,
        .capabilities = .{ .pointer = true },
    } });
}

fn targetFor(window: TestDesktop.SceneWindow) TestInteraction.Target {
    return .{
        .toplevel = window.id,
        .surface = window.surface,
        .point = .{ .x = 0, .y = 0 },
    };
}

test "interaction: invalid command capacity overflow is rejected before allocation" {
    try std.testing.expectError(error.InvalidConfig, TestInteraction.init(
        std.testing.allocator,
        .{
            .window_capacity = 1,
            .device_capacity = 1,
            .command_capacity = std.math.maxInt(usize),
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        },
    ));
}

test "interaction: pointer motion selects exact topmost input surface" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    const command = interaction.peekCommand().?;
    const target = command.pointer_focus.?;
    try std.testing.expectEqual(desktop.windows[1].id, target.toplevel);
    try std.testing.expectEqual(desktop.windows[1].surface, target.surface);
    try std.testing.expectEqual(TestInteraction.FixedPoint{ .x = 3 * 256, .y = 3 * 256 }, target.point);
    try std.testing.expectEqual(geometry.Point{ .x = 13, .y = 8 }, interaction.pointerPosition());
    try std.testing.expectEqual(interaction.pointerPosition(), interaction.cursor.position);
}

test "interaction: gestures require exact pointer device without mutating focus or cursor" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    const position = interaction.pointerPosition();
    const cursor = interaction.cursor;

    const events = [_]input.Event{
        .{ .swipe_begin = .{ .device = device_a, .time_usec = 1, .fingers = 3 } },
        .{ .swipe_update = .{ .device = device_a, .time_usec = 2, .dx = 1, .dy = -1 } },
        .{ .swipe_end = .{ .device = device_a, .time_usec = 3, .cancelled = false } },
        .{ .pinch_begin = .{ .device = device_a, .time_usec = 4, .fingers = 3 } },
        .{ .pinch_update = .{ .device = device_a, .time_usec = 5, .dx = 1, .dy = 2, .scale = 1.2, .angle_delta = 5 } },
        .{ .pinch_end = .{ .device = device_a, .time_usec = 6, .cancelled = true } },
        .{ .hold_begin = .{ .device = device_a, .time_usec = 7, .fingers = 2 } },
        .{ .hold_end = .{ .device = device_a, .time_usec = 8, .cancelled = false } },
    };
    for (events) |event| try interaction.consume(&desktop, &surfaces, event);
    try std.testing.expectEqual(position, interaction.pointerPosition());
    try std.testing.expectEqual(cursor, interaction.cursor);
    try std.testing.expectEqual(@as(?TestInteraction.Target, null), interaction.hover);
    try std.testing.expectEqual(@as(usize, 0), interaction.pendingCommands());

    try std.testing.expectError(error.StaleDevice, interaction.consume(&desktop, &surfaces, .{
        .hold_begin = .{ .device = device_b, .time_usec = 9, .fingers = 2 },
    }));
    try interaction.consume(&desktop, &surfaces, .{ .device_added = .{
        .device = device_b,
        .capabilities = .{ .keyboard = true },
    } });
    try std.testing.expectError(error.MissingCapability, interaction.consume(&desktop, &surfaces, .{
        .swipe_end = .{ .device = device_b, .time_usec = 10, .cancelled = true },
    }));
}

test "interaction: command storage grows while preserving motion order" {
    var interaction = try initTestInteraction(1);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{ .hole_surface = desktop.windows[1].surface };
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    try std.testing.expectEqual(desktop.windows[0].surface, interaction.peekCommand().?.pointer_focus.?.surface);
    try interaction.consume(&desktop, &surfaces, .{
        .pointer_motion = .{ .device = device_a, .time_usec = 2, .dx = 5, .dy = 5 },
    });
    try std.testing.expectEqual(@as(usize, 2), interaction.pendingCommands());
    try std.testing.expectEqual(geometry.Point{ .x = 18, .y = 13 }, interaction.pointerPosition());
}

test "interaction: default press updates desktop and enters exact button grab" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = true,
    } });
    try std.testing.expectEqual(desktop.windows[1].id, desktop.focused.?);
    const grabbed = interaction.interactionMode().button_grab;
    try std.testing.expectEqual(desktop.windows[1].surface, grabbed.surface);
    try std.testing.expectEqual(grabbed, interaction.peekCommand().?.keyboard_focus);
    interaction.dropCommand();

    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 3,
        .dx = -12,
        .dy = -7,
    } });
    try std.testing.expectEqual(desktop.windows[0].surface, interaction.peekCommand().?.pointer_focus.?.surface);
    try std.testing.expectEqual(grabbed, interaction.interactionMode().button_grab);

    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 4,
        .button = 272,
        .pressed = false,
    } });
    try std.testing.expect(interaction.interactionMode() == .default);
}

test "interaction: activation focuses the exact toplevel and queues keyboard focus" {
    var interaction = try initTestInteraction(1);
    defer interaction.deinit();
    var desktop = testDesktop();
    const window = desktop.windows[1];

    try interaction.activateToplevel(&desktop, window.id, window.surface);

    try std.testing.expectEqual(window.id, desktop.focused.?);
    try std.testing.expectEqual(targetFor(window), interaction.peekCommand().?.keyboard_focus);
}

test "interaction: interactive resize follows pointer and ends on button release" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    const target = targetFor(desktop.windows[1]);
    interaction.mode = .{ .button_grab = target };
    writeBit(&interaction.devices[0].buttons, 272, true);
    try interaction.beginInteractive(&desktop, .{
        .id = target.toplevel,
        .kind = .{ .resize = .bottom_right },
    });
    try std.testing.expect(interaction.interactionMode() == .interactive);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 8,
        .dy = 6,
    } });
    try std.testing.expectEqual(
        geometry.Rect{ .x = 10, .y = 5, .width = 28, .height = 26 },
        desktop.interactive_rect.?,
    );
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = false,
    } });
    try std.testing.expect(interaction.interactionMode() == .default);
    try std.testing.expect(!desktop.resizing);
}

test "interaction: interactive geometry clamps moves and constrained left-edge resizes" {
    const target = targetFor(testDesktop().windows[1]);
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 40, .height = 30 };
    const limits: TestDesktop.InteractiveGeometry = .{
        .rect = .{ .x = 10, .y = 5, .width = 20, .height = 20 },
        .min_width = 5,
        .min_height = 4,
        .max_width = 50,
        .max_height = 40,
    };
    try std.testing.expectEqual(
        geometry.Rect{ .x = 39, .y = 29, .width = 20, .height = 20 },
        try TestInteraction.interactiveRect(.{
            .target = target,
            .kind = .move,
            .start_x_fixed = 0,
            .start_y_fixed = 0,
            .geometry = limits,
        }, 100, 100, bounds),
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 25, .y = 5, .width = 5, .height = 20 },
        try TestInteraction.interactiveRect(.{
            .target = target,
            .kind = .{ .resize = .left },
            .start_x_fixed = 0,
            .start_y_fixed = 0,
            .geometry = limits,
        }, 100, 0, bounds),
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = -20, .y = 5, .width = 50, .height = 20 },
        try TestInteraction.interactiveRect(.{
            .target = target,
            .kind = .{ .resize = .left },
            .start_x_fixed = 0,
            .start_y_fixed = 0,
            .geometry = limits,
        }, -100, 0, bounds),
    );
}

test "interaction: failed desktop focus leaves press and grab unchanged" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    interaction.dropCommand();
    desktop.reject_focus = true;
    try std.testing.expectError(error.Backpressure, interaction.consume(&desktop, &surfaces, .{
        .pointer_button = .{ .device = device_a, .time_usec = 2, .button = 272, .pressed = true },
    }));
    try std.testing.expect(interaction.interactionMode() == .default);
    try std.testing.expect(desktop.focused == null);
    try std.testing.expectEqual(@as(usize, 0), interaction.pendingCommands());
}

test "interaction: surface destruction and device loss cancel through one terminal route" {
    var interaction = try initTestInteraction(2);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = true,
    } });
    interaction.dropCommand();
    interaction.cursorRequest(desktop.windows[1].surface, .{ .x = 1, .y = 1 });
    interaction.surfaceDestroyed(desktop.windows[1].surface);
    const destroyed = interaction.peekCommand().?.cancel;
    try std.testing.expect(destroyed.pointer_focus and destroyed.keyboard_focus and destroyed.pointer_grab);
    try std.testing.expect(interaction.interactionMode() == .default);
    try std.testing.expect(interaction.cursor.surface == null);
    interaction.dropCommand();

    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 3,
        .dx = -10,
        .dy = -5,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .device_removed = device_a });
    const lost = interaction.peekCommand().?.cancel;
    try std.testing.expect(lost.pointer_focus);
    try std.testing.expect(!interaction.cursor.pointer_available);
}

test "interaction: destruction retires exact queued focus and preserves unrelated order" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    const desktop = testDesktop();
    const destroyed = targetFor(desktop.windows[1]);
    const unrelated = targetFor(desktop.windows[0]);
    var replacement = destroyed;
    replacement.toplevel.generation += 1;
    replacement.surface.generation += 1;
    interaction.hover = destroyed;
    interaction.keyboard_focus = destroyed;
    interaction.mode = .{ .button_grab = destroyed };
    interaction.enqueue(.{ .pointer_focus = destroyed });
    interaction.enqueue(.{ .keyboard_focus = unrelated });
    interaction.enqueue(.{ .keyboard_focus = destroyed });
    interaction.enqueue(.{ .pointer_focus = replacement });

    interaction.surfaceDestroyed(destroyed.surface);
    try std.testing.expectEqual(@as(usize, 3), interaction.pendingCommands());
    for (0..interaction.command_len) |offset| {
        const index = (interaction.command_head + offset) % interaction.commands.len;
        try std.testing.expect(!TestInteraction.commandMatches(
            interaction.commands[index],
            null,
            destroyed.surface,
        ));
    }
    try std.testing.expectEqual(unrelated, interaction.peekCommand().?.keyboard_focus);
    interaction.dropCommand();
    try std.testing.expectEqual(replacement, interaction.peekCommand().?.pointer_focus.?);
    interaction.dropCommand();
    const cancellation = interaction.peekCommand().?.cancel;
    try std.testing.expect(cancellation.pointer_focus);
    try std.testing.expect(cancellation.keyboard_focus);
    try std.testing.expect(cancellation.pointer_grab);
}

test "interaction: capacity-one terminal cancellation coalesces losslessly" {
    var interaction = try initTestInteraction(1);
    defer interaction.deinit();
    const desktop = testDesktop();
    const pointer = targetFor(desktop.windows[0]);
    const keyboard = targetFor(desktop.windows[1]);
    var grab = pointer;
    grab.toplevel.generation += 1;
    grab.surface.generation += 1;

    interaction.hover = pointer;
    interaction.surfaceDestroyed(pointer.surface);
    interaction.keyboard_focus = keyboard;
    interaction.surfaceDestroyed(keyboard.surface);
    interaction.mode = .{ .button_grab = grab };
    interaction.toplevelDestroyed(grab.toplevel);

    try std.testing.expectEqual(@as(usize, 1), interaction.pendingCommands());
    const cancellation = interaction.peekCommand().?.cancel;
    try std.testing.expect(cancellation.pointer_focus);
    try std.testing.expect(cancellation.keyboard_focus);
    try std.testing.expect(cancellation.pointer_grab);
    try std.testing.expectError(error.Backpressure, interaction.ensureCommandCapacity(1));
    interaction.dropCommand();
    try std.testing.expectEqual(@as(usize, 0), interaction.pendingCommands());
}

test "interaction: removed device buttons cannot retain a later grab" {
    var interaction = try initTestInteraction(4);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .device_added = .{
        .device = device_b,
        .capabilities = .{ .pointer = true },
    } });
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = true,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .device_removed = device_a });
    try std.testing.expect(interaction.peekCommand().?.cancel.pointer_grab);
    interaction.dropCommand();

    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_b,
        .time_usec = 3,
        .button = 272,
        .pressed = true,
    } });
    try std.testing.expect(interaction.interactionMode() == .button_grab);
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_b,
        .time_usec = 4,
        .button = 272,
        .pressed = false,
    } });
    try std.testing.expect(interaction.interactionMode() == .default);
}

test "interaction: toplevel destruction cancels exact focus and grab generations" {
    var interaction = try initTestInteraction(3);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 12,
        .dy = 7,
    } });
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = true,
    } });
    interaction.dropCommand();
    const target = targetFor(desktop.windows[1]);
    interaction.enqueue(.{ .pointer_focus = target });
    interaction.enqueue(.{ .keyboard_focus = target });
    interaction.toplevelDestroyed(desktop.windows[1].id);
    try std.testing.expectEqual(@as(usize, 1), interaction.pendingCommands());
    const cancellation = interaction.peekCommand().?.cancel;
    try std.testing.expect(cancellation.pointer_focus);
    try std.testing.expect(cancellation.keyboard_focus);
    try std.testing.expect(cancellation.pointer_grab);
    try std.testing.expect(interaction.interactionMode() == .default);
}

test "interaction: output replacement clamps retained pointer and cursor" {
    var interaction = try initTestInteraction(2);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try addPointer(&interaction, &desktop, &surfaces);
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 30,
        .dy = 20,
    } });
    interaction.dropCommand();

    const replacement: geometry.Rect = .{ .x = 0, .y = 0, .width = 3, .height = 2 };
    try interaction.validateBounds(replacement);
    interaction.applyBounds(replacement);
    try std.testing.expectEqual(geometry.Point{ .x = 2, .y = 1 }, interaction.pointerPosition());
    try std.testing.expectEqual(interaction.pointerPosition(), interaction.cursor.position);
    try std.testing.expectEqual(replacement, interaction.bounds);
}

test "interaction: popup grab retains outside delivery and dismisses on press" {
    var interaction = try initTestInteraction(3);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{ .hole_surface = desktop.windows[0].surface };
    try addPointer(&interaction, &desktop, &surfaces);
    interaction.setPopupGrab(@as(?struct { toplevel: TestId, surface: TestId }, .{
        .toplevel = desktop.windows[1].id,
        .surface = desktop.windows[1].surface,
    }));
    try interaction.consume(&desktop, &surfaces, .{ .pointer_motion = .{
        .device = device_a,
        .time_usec = 1,
        .dx = 34,
        .dy = 24,
    } });
    const focus = interaction.peekCommand().?.pointer_focus.?;
    try std.testing.expectEqual(desktop.windows[1].surface, focus.surface);
    try std.testing.expectEqual(@as(i32, 25 * 256), focus.point.x);
    try std.testing.expectEqual(@as(i32, 20 * 256), focus.point.y);
    interaction.dropCommand();

    try interaction.consume(&desktop, &surfaces, .{ .pointer_button = .{
        .device = device_a,
        .time_usec = 2,
        .button = 272,
        .pressed = true,
    } });
    try std.testing.expect(desktop.popup_dismissed);
    try std.testing.expect(interaction.interactionMode() == .default);
}

test "interaction: compositor bindings consume exact press and release pairs" {
    var interaction = try initTestInteraction(2);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    try interaction.consume(&desktop, &surfaces, .{ .device_added = .{
        .device = device_a,
        .capabilities = .{ .keyboard = true },
    } });
    try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
        .device = device_a,
        .time_usec = 1,
        .key = key_left_meta,
        .pressed = true,
    } });
    try std.testing.expectEqual(@as(usize, 0), interaction.pendingCommands());

    inline for ([_]u32{ key_tab, key_f, key_m, key_space }) |key| {
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 2,
            .key = key,
            .pressed = true,
        } });
        try std.testing.expect(interaction.peekCommand().? == .key_consumed);
        interaction.dropCommand();
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 3,
            .key = key,
            .pressed = false,
        } });
        try std.testing.expect(interaction.peekCommand().? == .key_consumed);
        interaction.dropCommand();
    }
    try std.testing.expectEqual(@as(usize, 1), desktop.focus_next_count);
    try std.testing.expectEqual(@as(usize, 1), desktop.fullscreen_count);
    try std.testing.expectEqual(@as(usize, 1), desktop.maximized_count);
    try std.testing.expectEqual(@as(usize, 1), desktop.floating_count);

    inline for ([_]u32{ key_j, key_k }) |key| {
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 4,
            .key = key,
            .pressed = true,
        } });
        try std.testing.expect(interaction.peekCommand().? == .key_consumed);
        interaction.dropCommand();
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 5,
            .key = key,
            .pressed = false,
        } });
        interaction.dropCommand();
    }
    try std.testing.expectEqual(@as(usize, 2), desktop.focus_next_count);
    try std.testing.expectEqual(@as(usize, 1), desktop.focus_previous_count);

    try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
        .device = device_a,
        .time_usec = 6,
        .key = key_left_shift,
        .pressed = true,
    } });
    inline for ([_]u32{ key_j, key_k }) |key| {
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 7,
            .key = key,
            .pressed = true,
        } });
        interaction.dropCommand();
        try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
            .device = device_a,
            .time_usec = 8,
            .key = key,
            .pressed = false,
        } });
        interaction.dropCommand();
    }
    try std.testing.expectEqual(@as(usize, 1), desktop.move_next_count);
    try std.testing.expectEqual(@as(usize, 1), desktop.move_previous_count);
}

test "interaction: close binding retains the exact focused toplevel" {
    var interaction = try initTestInteraction(2);
    defer interaction.deinit();
    var desktop = testDesktop();
    var surfaces = TestSurfaces{};
    desktop.focused = desktop.windows[1].id;
    try interaction.consume(&desktop, &surfaces, .{ .device_added = .{
        .device = device_a,
        .capabilities = .{ .keyboard = true },
    } });
    try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
        .device = device_a,
        .time_usec = 1,
        .key = key_left_meta,
        .pressed = true,
    } });
    try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
        .device = device_a,
        .time_usec = 2,
        .key = key_q,
        .pressed = true,
    } });
    try std.testing.expect(interaction.peekCommand().? == .key_consumed);
    interaction.dropCommand();
    try std.testing.expectEqual(desktop.windows[1].id, interaction.peekCommand().?.close);
    interaction.dropCommand();
    try interaction.consume(&desktop, &surfaces, .{ .keyboard_key = .{
        .device = device_a,
        .time_usec = 3,
        .key = key_q,
        .pressed = false,
    } });
    try std.testing.expect(interaction.peekCommand().? == .key_consumed);
}
