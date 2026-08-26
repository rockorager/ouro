//! Dynamically sized owner for one-workspace desktop policy.
//!
//! The shell adapter owns protocol resources and transmission. This owner
//! stores only copied value IDs, consumes shell-neutral events, and retains configure
//! commands until the caller confirms that the shell accepted them.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");
const layout = @import("layout.zig");

const none = std.math.maxInt(u32);

pub const Config = struct {
    toplevel_capacity: usize,
    popup_capacity: usize = 8,
    command_capacity: usize,
    metadata_bytes: usize,

    fn validate(config: Config) !void {
        inline for (.{ config.toplevel_capacity, config.popup_capacity, config.command_capacity, config.metadata_bytes }) |value|
            if (value == 0 or value >= none) return error.InvalidConfig;
        _ = std.math.mul(usize, config.toplevel_capacity, config.metadata_bytes) catch
            return error.InvalidConfig;
    }
};

pub fn Desktop(comptime Shell: type) type {
    return struct {
        const Self = @This();

        pub const ToplevelId = packed struct {
            index: u32,
            generation: u32,
        };

        pub const WorkspaceId = packed struct {
            index: u32,
            generation: u32,
        };

        pub const workspace_id: WorkspaceId = .{ .index = 0, .generation = 1 };

        pub const Mode = enum { tiled, floating };

        pub const InteractiveKind = union(enum) {
            move,
            resize: Shell.ResizeEdge,
        };
        pub const InteractiveRequest = struct {
            id: ToplevelId,
            kind: InteractiveKind,
        };
        pub const InteractiveGeometry = struct {
            rect: geometry.Rect,
            min_width: i32,
            min_height: i32,
            max_width: i32,
            max_height: i32,
        };

        pub const Metadata = struct {
            title: []const u8,
            app_id: []const u8,
            min_width: i32,
            min_height: i32,
            max_width: i32,
            max_height: i32,
        };

        pub const SceneWindow = struct {
            id: ToplevelId,
            surface: Shell.SurfaceId,
            managed: bool = true,
            keyboard_focusable: bool = true,
            geometry: geometry.Rect,
            has_window_geometry: bool = false,
            surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
            visible: bool,
            stacking: u32,
            mode: Mode,
            content_ready: bool,
        };

        pub const Command = struct {
            id: ToplevelId,
            shell_id: Shell.ToplevelId,
            configure: Shell.ToplevelConfigure,
        };

        const PopupCommand = struct {
            id: Shell.PopupId,
            configure: Shell.PopupConfigure = undefined,
            reposition_token: ?u32 = null,
            done: bool = false,
        };

        const Header = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
        };

        const Slot = struct {
            header: Header = .{},
            shell_id: Shell.ToplevelId = undefined,
            surface: Shell.SurfaceId = undefined,
            mode: Mode = .tiled,
            floating: geometry.Rect = undefined,
            scene: SceneWindow = undefined,
            target_scene: SceneWindow = undefined,
            title: []u8 = &.{},
            title_len: usize = 0,
            app_id: []u8 = &.{},
            app_id_len: usize = 0,
            min_width: i32 = 0,
            min_height: i32 = 0,
            max_width: i32 = 0,
            max_height: i32 = 0,
            parent: ?ToplevelId = null,
            initial_committed: bool = false,
            fullscreen: bool = false,
            maximized: bool = false,
            minimized: bool = false,
            resizing: bool = false,
            content_ready: bool = false,
            configured: bool = false,
            last_configure: Shell.ToplevelConfigure = .{ .width = 0, .height = 0 },
            applied_configure: ?Shell.ToplevelConfigure = null,
            expected_serial: ?u32 = null,
            configure_ready: bool = false,
        };

        const Desired = struct {
            active: bool = false,
            rect: geometry.Rect = undefined,
            visible: bool = false,
            stacking: u32 = 0,
            configure: Shell.ToplevelConfigure = .{ .width = 0, .height = 0 },
        };

        const PopupSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            shell_id: Shell.PopupId = undefined,
            surface: Shell.SurfaceId = undefined,
            parent: Shell.SurfaceId = undefined,
            owner: ToplevelId = undefined,
            placement: Shell.PopupPlacement = undefined,
            configure: Shell.PopupConfigure = undefined,
            pending_configure: ?Shell.PopupConfigure = null,
            expected_serial: ?u32 = null,
            content_ready: bool = false,
            grabbed: bool = false,
            has_window_geometry: bool = false,
            surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
            scene: SceneWindow = undefined,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        free: u32,
        live: usize = 0,
        popups: []PopupSlot,
        popup_free: u32,
        popup_live: usize = 0,
        work_area: geometry.Rect,
        metadata_storage: []u8,
        metadata_bytes: usize,
        focus: []u32,
        focus_len: usize = 0,
        tile_order: []u32,
        tile_len: usize = 0,
        layout_items: []layout.Item,
        placements: []layout.Placement,
        desired: []Desired,
        commands: []Command,
        command_head: usize = 0,
        command_len: usize = 0,
        popup_commands: []PopupCommand,
        popup_command_head: usize = 0,
        popup_command_len: usize = 0,
        popup_grab: ?Shell.PopupId = null,
        popup_dismiss: ?Shell.PopupId = null,
        pending_event: ?Shell.Event = null,
        interactive_request: ?InteractiveRequest = null,
        destroyed: ?ToplevelId = null,
        destroyed_surface: ?Shell.SurfaceId = null,
        scene_changed: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            config: Config,
            work_area: geometry.Rect,
        ) !Self {
            try config.validate();
            try work_area.validate();
            const slots = try allocator.alloc(Slot, config.toplevel_capacity);
            errdefer allocator.free(slots);
            const popups = try allocator.alloc(PopupSlot, config.popup_capacity);
            errdefer allocator.free(popups);
            const metadata_per_slot = try std.math.mul(usize, config.metadata_bytes, 2);
            const storage_len = try std.math.mul(
                usize,
                config.toplevel_capacity,
                metadata_per_slot,
            );
            const metadata_storage = try allocator.alloc(u8, storage_len);
            errdefer allocator.free(metadata_storage);
            const focus = try allocator.alloc(u32, config.toplevel_capacity);
            errdefer allocator.free(focus);
            const tile_order = try allocator.alloc(u32, config.toplevel_capacity);
            errdefer allocator.free(tile_order);
            const layout_items = try allocator.alloc(layout.Item, config.toplevel_capacity);
            errdefer allocator.free(layout_items);
            const placements = try allocator.alloc(layout.Placement, config.toplevel_capacity);
            errdefer allocator.free(placements);
            const desired = try allocator.alloc(Desired, config.toplevel_capacity);
            errdefer allocator.free(desired);
            const commands = try allocator.alloc(Command, config.command_capacity);
            errdefer allocator.free(commands);
            // One trailing slot is reserved for topmost-first popup dismissal,
            // so destruction can always publish the next terminal edge.
            const popup_command_slots = std.math.add(usize, config.popup_capacity, 1) catch
                return error.InvalidConfig;
            const popup_commands = try allocator.alloc(PopupCommand, popup_command_slots);
            errdefer allocator.free(popup_commands);

            for (slots, 0..) |*slot, index| {
                const start = index * config.metadata_bytes * 2;
                slot.* = .{
                    .header = .{
                        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
                    },
                    .title = metadata_storage[start .. start + config.metadata_bytes],
                    .app_id = metadata_storage[start + config.metadata_bytes .. start + config.metadata_bytes * 2],
                };
            }
            for (popups, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < popups.len) @intCast(index + 1) else none,
            };
            @memset(desired, .{});
            return .{
                .allocator = allocator,
                .slots = slots,
                .free = 0,
                .popups = popups,
                .popup_free = 0,
                .work_area = work_area,
                .metadata_storage = metadata_storage,
                .metadata_bytes = config.metadata_bytes,
                .focus = focus,
                .tile_order = tile_order,
                .layout_items = layout_items,
                .placements = placements,
                .desired = desired,
                .commands = commands,
                .popup_commands = popup_commands,
            };
        }

        pub fn deinit(desktop: *Self) void {
            desktop.allocator.free(desktop.popup_commands);
            desktop.allocator.free(desktop.commands);
            desktop.allocator.free(desktop.desired);
            desktop.allocator.free(desktop.placements);
            desktop.allocator.free(desktop.layout_items);
            desktop.allocator.free(desktop.tile_order);
            desktop.allocator.free(desktop.focus);
            desktop.allocator.free(desktop.metadata_storage);
            desktop.allocator.free(desktop.popups);
            desktop.allocator.free(desktop.slots);
            desktop.* = undefined;
        }

        /// Drains at most `limit` shell events. A capacity failure retains the
        /// exact event locally, so destructive shell dequeue never loses it.
        pub fn consume(desktop: *Self, shell: *Shell, limit: usize) !usize {
            var count: usize = 0;
            while (count < limit) {
                if (desktop.destroyed != null or desktop.destroyed_surface != null) break;
                const event = desktop.pending_event orelse shell.popEvent() orelse break;
                desktop.applyEvent(shell, event) catch |cause| {
                    desktop.pending_event = event;
                    return cause;
                };
                desktop.pending_event = null;
                count += 1;
            }
            return count;
        }

        pub fn peekCommand(desktop: *const Self) ?Command {
            if (desktop.command_len == 0) return null;
            return desktop.commands[desktop.command_head];
        }

        pub fn dropCommand(desktop: *Self) void {
            if (desktop.command_len == 0) return;
            desktop.command_head = (desktop.command_head + 1) % desktop.commands.len;
            desktop.command_len -= 1;
        }

        /// Transfers one configure to the R16 outbound owner. If that owner is
        /// backpressured, its error leaves the desktop command queued exactly
        /// once for retry.
        pub fn flushConfigure(desktop: *Self, shell: *Shell) !?u32 {
            if (desktop.popup_command_len != 0) {
                const command = desktop.popup_commands[desktop.popup_command_head];
                if (command.done) {
                    try shell.queuePopupDone(command.id);
                    desktop.popup_command_head = (desktop.popup_command_head + 1) % desktop.popup_commands.len;
                    desktop.popup_command_len -= 1;
                    return null;
                }
                const serial = if (command.reposition_token) |token|
                    try shell.queuePopupReposition(command.id, command.configure, token)
                else
                    try shell.queuePopupConfigure(command.id, command.configure);
                if (desktop.popupByShell(command.id)) |slot| {
                    slot.expected_serial = serial;
                    slot.pending_configure = command.configure;
                } else |_| {}
                desktop.popup_command_head = (desktop.popup_command_head + 1) % desktop.popup_commands.len;
                desktop.popup_command_len -= 1;
                return serial;
            }
            const command = desktop.peekCommand() orelse return null;
            const serial = try shell.queueToplevelConfigure(command.shell_id, command.configure);
            if (desktop.resolveIndex(command.id)) |index| {
                const slot = &desktop.slots[index];
                if (std.meta.eql(slot.last_configure, command.configure)) {
                    slot.expected_serial = serial;
                    slot.configure_ready = false;
                }
            } else |_| {}
            desktop.dropCommand();
            return serial;
        }

        pub fn pendingCommands(desktop: *const Self) usize {
            return desktop.command_len + desktop.popup_command_len;
        }

        pub fn takeDestroyed(desktop: *Self) ?ToplevelId {
            const id = desktop.destroyed;
            desktop.destroyed = null;
            return id;
        }

        pub fn takeDestroyedSurface(desktop: *Self) ?Shell.SurfaceId {
            const id = desktop.destroyed_surface;
            desktop.destroyed_surface = null;
            return id;
        }

        pub fn peekInteractiveRequest(desktop: *const Self) ?InteractiveRequest {
            return desktop.interactive_request;
        }

        pub fn dropInteractiveRequest(desktop: *Self) void {
            desktop.interactive_request = null;
        }

        pub fn beginInteractive(desktop: *Self, request: InteractiveRequest) !?InteractiveGeometry {
            const index = try desktop.resolveIndex(request.id);
            const slot = &desktop.slots[index];
            if (slot.minimized or slot.fullscreen or slot.maximized) return null;
            try desktop.requireCommandCapacity(desktop.live);
            if (slot.mode == .tiled) {
                slot.floating = slot.scene.geometry;
                slot.mode = .floating;
                desktop.removeTile(index);
            }
            slot.resizing = request.kind == .resize;
            desktop.promoteFocus(index);
            try desktop.reflow();
            return .{
                .rect = slot.floating,
                .min_width = @max(slot.min_width, 1),
                .min_height = @max(slot.min_height, 1),
                .max_width = slot.max_width,
                .max_height = slot.max_height,
            };
        }

        pub fn updateInteractive(desktop: *Self, id: ToplevelId, rect: geometry.Rect) !void {
            try desktop.setFloatingGeometry(id, rect);
        }

        pub fn endInteractive(desktop: *Self, id: ToplevelId) !void {
            const index = desktop.resolveIndex(id) catch return;
            const slot = &desktop.slots[index];
            if (!slot.resizing) return;
            try desktop.requireCommandCapacity(1);
            slot.resizing = false;
            try desktop.reflow();
        }

        pub fn takeSceneChanged(desktop: *Self) bool {
            const changed = desktop.scene_changed;
            desktop.scene_changed = false;
            return changed;
        }

        pub fn transactionPending(desktop: *const Self) bool {
            for (desktop.slots) |slot| {
                if (!slot.header.active or !slot.configured) continue;
                if (slot.applied_configure == null or
                    !std.meta.eql(slot.applied_configure.?, slot.last_configure)) return true;
            }
            return false;
        }

        pub fn expireTransaction(desktop: *Self) bool {
            if (!desktop.transactionPending()) return false;
            desktop.publishScene();
            return true;
        }

        pub fn focused(desktop: *const Self) ?ToplevelId {
            if (desktop.focus_len == 0) return null;
            return desktop.idFor(desktop.focus[0]);
        }

        pub fn focusedToplevel(desktop: *const Self) ?ToplevelId {
            return desktop.focused();
        }

        pub fn shellToplevel(desktop: *const Self, id: ToplevelId) !Shell.ToplevelId {
            return desktop.slots[try desktop.resolveIndex(id)].shell_id;
        }

        pub fn reconfigureShellToplevel(desktop: *Self, shell_id: Shell.ToplevelId) !void {
            const id = try desktop.idForShell(shell_id);
            if (desktop.commandCountFor(id) != 0) return;
            try desktop.requireCommandCapacity(1);
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            desktop.enqueue(.{
                .id = id,
                .shell_id = slot.shell_id,
                .configure = slot.last_configure,
            });
        }

        pub fn focusToplevel(desktop: *Self, id: ToplevelId) !void {
            const index = try desktop.resolveIndex(id);
            if (desktop.slots[index].minimized) return error.NotVisible;
            if (desktop.focus_len != 0 and desktop.focus[0] == index) return;
            try desktop.requireCommandCapacity(desktop.live);
            desktop.promoteFocus(index);
            try desktop.reflow();
        }

        pub fn focusNext(desktop: *Self) !void {
            const current = desktop.focused() orelse return;
            const current_index = try desktop.resolveIndex(current);
            for (1..desktop.slots.len + 1) |offset| {
                const index = (current_index + offset) % desktop.slots.len;
                if (desktop.slots[index].header.active and !desktop.slots[index].minimized)
                    return desktop.focusToplevel(desktop.idFor(@intCast(index)));
            }
        }

        pub fn focusPrevious(desktop: *Self) !void {
            const current = desktop.focused() orelse return;
            const current_index = try desktop.resolveIndex(current);
            for (1..desktop.slots.len + 1) |offset| {
                const index = (current_index + desktop.slots.len - offset) % desktop.slots.len;
                if (desktop.slots[index].header.active and !desktop.slots[index].minimized)
                    return desktop.focusToplevel(desktop.idFor(@intCast(index)));
            }
        }

        pub fn moveFocusedTile(desktop: *Self, direction: enum { next, previous }) !void {
            const id = desktop.focused() orelse return;
            const focused_index = try desktop.resolveIndex(id);
            if (desktop.slots[focused_index].mode != .tiled or desktop.tile_len < 2) return;
            var position: usize = 0;
            while (position < desktop.tile_len and desktop.tile_order[position] != focused_index) : (position += 1) {}
            if (position == desktop.tile_len) return error.InvalidTileOrder;
            try desktop.requireCommandCapacity(desktop.live);
            const other = switch (direction) {
                .next => (position + 1) % desktop.tile_len,
                .previous => (position + desktop.tile_len - 1) % desktop.tile_len,
            };
            std.mem.swap(u32, &desktop.tile_order[position], &desktop.tile_order[other]);
            try desktop.reflow();
        }

        pub fn toggleFocusedFullscreen(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            const index = try desktop.resolveIndex(id);
            try desktop.requestState(id, .fullscreen, !desktop.slots[index].fullscreen);
        }

        pub fn toggleFocusedMaximized(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            const index = try desktop.resolveIndex(id);
            try desktop.requestState(id, .maximized, !desktop.slots[index].maximized);
        }

        pub fn toggleFocusedFloating(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            const index = try desktop.resolveIndex(id);
            try desktop.setFloating(id, desktop.slots[index].mode != .floating);
        }

        pub fn setFloating(desktop: *Self, id: ToplevelId, floating: bool) !void {
            const index = try desktop.resolveIndex(id);
            const mode: Mode = if (floating) .floating else .tiled;
            if (desktop.slots[index].mode == mode) return;
            try desktop.requireCommandCapacity(desktop.live);
            const slot = &desktop.slots[index];
            if (!floating and !slot.minimized and !slot.fullscreen and !slot.maximized)
                try desktop.validateLayout(desktop.layoutCount() + 1, desktop.work_area);
            slot.mode = mode;
            if (floating) desktop.removeTile(index) else desktop.appendTile(index);
            try desktop.reflow();
        }

        pub fn setFloatingGeometry(desktop: *Self, id: ToplevelId, rect: geometry.Rect) !void {
            try rect.validate();
            const index = try desktop.resolveIndex(id);
            if (desktop.slots[index].mode != .floating) return error.NotFloating;
            try desktop.requireCommandCapacity(1);
            desktop.slots[index].floating = rect;
            try desktop.reflow();
        }

        pub fn setWorkArea(desktop: *Self, rect: geometry.Rect) !void {
            try desktop.validateWorkArea(rect);
            desktop.applyWorkArea(rect);
        }

        /// Reserves all layout and configure capacity needed by a work-area
        /// replacement without changing desktop policy or queued commands.
        pub fn validateWorkArea(desktop: *Self, rect: geometry.Rect) !void {
            try rect.validate();
            try desktop.validateLayout(desktop.layoutCount(), rect);
            try desktop.requireCommandCapacity(desktop.live);
        }

        /// Publishes a work area accepted by `validateWorkArea`. Coordinator
        /// turns are single-threaded, so the reserved reflow cannot fail.
        pub fn applyWorkArea(desktop: *Self, rect: geometry.Rect) void {
            desktop.validateWorkArea(rect) catch unreachable;
            desktop.work_area = rect;
            desktop.reflow() catch unreachable;
        }

        pub fn workArea(desktop: *const Self) geometry.Rect {
            return desktop.work_area;
        }

        pub fn scene(desktop: *const Self, id: ToplevelId) !SceneWindow {
            return desktop.slots[try desktop.resolveIndex(id)].scene;
        }

        pub fn sceneForSurface(desktop: *const Self, surface: Shell.SurfaceId) !SceneWindow {
            for (desktop.popups) |slot| {
                if (slot.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            for (desktop.slots) |slot| {
                if (slot.header.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            return error.StaleSurface;
        }

        pub fn toplevelSceneForSurface(desktop: *const Self, surface: Shell.SurfaceId) !SceneWindow {
            for (desktop.slots) |slot| {
                if (slot.header.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            return error.StaleToplevel;
        }

        pub fn popupGrabTarget(desktop: *const Self) ?struct {
            toplevel: ToplevelId,
            surface: Shell.SurfaceId,
        } {
            const id = desktop.popup_grab orelse return null;
            for (desktop.popups) |slot| if (slot.active and std.meta.eql(slot.shell_id, id))
                return .{ .toplevel = slot.owner, .surface = slot.surface };
            return null;
        }

        /// Dismisses the active popup stack after a press outside every client
        /// surface. popup_done is delivered topmost-first as each role is
        /// destroyed, preserving xdg-shell's stack discipline.
        pub fn dismissPopupGrab(desktop: *Self) !bool {
            const id = desktop.popup_grab orelse return false;
            try desktop.enqueuePopupDone(id);
            desktop.popup_grab = null;
            desktop.popup_dismiss = id;
            return true;
        }

        /// Copies a stable, back-to-front scene snapshot. No arena pointers
        /// escape, and insufficient caller storage changes no desktop state.
        pub fn sceneSnapshot(desktop: *const Self, output: []SceneWindow) ![]SceneWindow {
            if (output.len < desktop.live + desktop.popup_live) return error.Exhausted;
            var len: usize = 0;
            for (desktop.slots) |slot| {
                if (!slot.header.active) continue;
                var position = len;
                while (position > 0 and output[position - 1].stacking > slot.scene.stacking) {
                    output[position] = output[position - 1];
                    position -= 1;
                }
                output[position] = slot.scene;
                len += 1;
            }
            for (desktop.popups) |slot| if (slot.active) {
                var position = len;
                while (position > 0 and output[position - 1].stacking > slot.scene.stacking) {
                    output[position] = output[position - 1];
                    position -= 1;
                }
                output[position] = slot.scene;
                len += 1;
            };
            return output[0..len];
        }

        /// Grows caller-owned snapshot storage as needed, then fills it using
        /// the stable slice API. The caller remains responsible for freeing it.
        pub fn sceneSnapshotGrowing(
            desktop: *const Self,
            allocator: std.mem.Allocator,
            storage: *[]SceneWindow,
        ) ![]SceneWindow {
            const needed = std.math.add(usize, desktop.live, desktop.popup_live) catch
                return error.OutOfMemory;
            if (storage.len < needed) {
                var capacity = storage.len;
                while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                    return error.OutOfMemory;
                storage.* = try allocator.realloc(storage.*, capacity);
            }
            return desktop.sceneSnapshot(storage.*);
        }

        pub fn metadata(desktop: *const Self, id: ToplevelId) !Metadata {
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            return .{
                .title = slot.title[0..slot.title_len],
                .app_id = slot.app_id[0..slot.app_id_len],
                .min_width = slot.min_width,
                .min_height = slot.min_height,
                .max_width = slot.max_width,
                .max_height = slot.max_height,
            };
        }

        pub fn idForShell(desktop: *const Self, shell_id: Shell.ToplevelId) !ToplevelId {
            for (desktop.slots, 0..) |slot, index| {
                if (slot.header.active and std.meta.eql(slot.shell_id, shell_id))
                    return desktop.idFor(@intCast(index));
            }
            return error.StaleToplevel;
        }

        fn applyEvent(desktop: *Self, shell: *Shell, event: Shell.Event) !void {
            switch (event) {
                .toplevel_created => |value| try desktop.create(value.id, value.surface),
                .popup_created => |value| try desktop.createPopup(value),
                .popup_commit_ready => |value| try desktop.commitPopup(value),
                .popup_reposition_requested => |value| try desktop.repositionPopup(value),
                .popup_grab_requested => |id| {
                    const slot = try desktop.popupByShell(id);
                    slot.grabbed = true;
                    desktop.popup_grab = id;
                },
                .popup_destroyed => |id| desktop.destroyPopup(id),
                .metadata_changed => |shell_id| {
                    const id = try desktop.idForShell(shell_id);
                    const source = try shell.metadata(shell_id);
                    try desktop.copyMetadata(id, source);
                },
                .parent_changed => |value| try desktop.setParent(
                    try desktop.idForShell(value.id),
                    if (value.parent) |parent| try desktop.idForShell(parent) else null,
                ),
                .state_requested => |request| try desktop.requestState(
                    try desktop.idForShell(request.id),
                    request.state,
                    request.enabled,
                ),
                .move_requested => |shell_id| {
                    if (desktop.interactive_request != null) return error.Backpressure;
                    desktop.interactive_request = .{
                        .id = try desktop.idForShell(shell_id),
                        .kind = .move,
                    };
                },
                .resize_requested => |request| {
                    if (desktop.interactive_request != null) return error.Backpressure;
                    desktop.interactive_request = .{
                        .id = try desktop.idForShell(request.id),
                        .kind = .{ .resize = request.edge },
                    };
                },
                .commit_ready => |commit| {
                    const id = try desktop.idForShell(commit.id);
                    const index = try desktop.resolveIndex(id);
                    if (commit.constraints_changed or commit.unmapped)
                        try desktop.copyMetadata(id, try shell.metadata(commit.id));
                    if (commit.unmapped) {
                        try desktop.resetUnmapped(index);
                        return;
                    }
                    desktop.slots[index].content_ready = commit.mapped;
                    desktop.slots[index].scene.content_ready = commit.mapped;
                    desktop.slots[index].target_scene.content_ready = commit.mapped;
                    desktop.slots[index].target_scene.has_window_geometry = commit.has_window_geometry;
                    desktop.slots[index].target_scene.surface_offset = .{
                        .x = commit.surface_offset_x,
                        .y = commit.surface_offset_y,
                    };
                    if (commit.initial_commit) {
                        try desktop.beginInitialCommit(index);
                        return;
                    }
                    if (desktop.slots[index].expected_serial == commit.serial)
                        desktop.slots[index].configure_ready = true;
                    desktop.publishReadyScene();
                },
                .toplevel_destroyed => |shell_id| try desktop.destroyShell(shell_id),
            }
        }

        fn create(desktop: *Self, shell_id: Shell.ToplevelId, surface: Shell.SurfaceId) !void {
            if (desktop.idForShell(shell_id)) |_| return error.DuplicateToplevel else |_| {}
            if (desktop.free == none) try desktop.growToplevels();
            try desktop.validateLayout(desktop.layoutCount() + 1, desktop.work_area);
            try desktop.requireCommandCapacity(desktop.live + 1);
            const index = desktop.acquire();
            const slot = &desktop.slots[index];
            slot.shell_id = shell_id;
            slot.surface = surface;
            slot.floating = desktop.defaultFloating();
            slot.scene = .{
                .id = desktop.idFor(index),
                .surface = surface,
                .geometry = desktop.work_area,
                .visible = false,
                .stacking = 0,
                .mode = .tiled,
                .content_ready = false,
            };
            slot.target_scene = slot.scene;
            desktop.live += 1;
        }

        fn createPopup(desktop: *Self, value: anytype) !void {
            if (desktop.popup_free == none) try desktop.growPopups();
            try desktop.requirePopupCommandCapacity(1);
            const parent = try desktop.sceneForSurface(value.parent);
            const positioned = try placePopup(value.placement, parent.geometry, desktop.work_area);
            const configure: Shell.PopupConfigure = .{
                .x = positioned.x,
                .y = positioned.y,
                .width = positioned.width,
                .height = positioned.height,
            };
            const index = desktop.popup_free;
            const slot = &desktop.popups[index];
            desktop.popup_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{
                .active = true,
                .generation = generation,
                .shell_id = value.id,
                .surface = value.surface,
                .parent = value.parent,
                .owner = parent.id,
                .placement = value.placement,
                .configure = configure,
                .scene = .{
                    .id = parent.id,
                    .surface = value.surface,
                    .geometry = popupAbsolute(configure, parent.geometry),
                    .visible = false,
                    .stacking = desktop.nextStacking(),
                    .mode = .floating,
                    .content_ready = false,
                },
            };
            desktop.popup_live += 1;
            const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                desktop.popup_commands.len;
            desktop.popup_commands[tail] = .{ .id = value.id, .configure = configure };
            desktop.popup_command_len += 1;
        }

        fn commitPopup(desktop: *Self, value: anytype) !void {
            const slot = try desktop.popupByShell(value.id);
            if (slot.expected_serial != value.serial) return;
            const parent = desktop.sceneForSurface(slot.parent) catch return;
            const configure = slot.pending_configure orelse return;
            const next = SceneWindow{
                .id = slot.owner,
                .surface = slot.surface,
                .geometry = popupAbsolute(configure, parent.geometry),
                .has_window_geometry = value.has_window_geometry,
                .surface_offset = .{ .x = value.surface_offset_x, .y = value.surface_offset_y },
                .visible = parent.visible,
                .stacking = slot.scene.stacking,
                .mode = .floating,
                .content_ready = true,
            };
            desktop.scene_changed = !std.meta.eql(slot.scene, next) or desktop.scene_changed;
            slot.scene = next;
            slot.configure = configure;
            slot.pending_configure = null;
            slot.content_ready = true;
            slot.has_window_geometry = value.has_window_geometry;
            slot.surface_offset = next.surface_offset;
            slot.expected_serial = null;
        }

        fn repositionPopup(desktop: *Self, value: anytype) !void {
            try desktop.requirePopupCommandCapacity(1);
            const slot = try desktop.popupByShell(value.id);
            const parent = try desktop.sceneForSurface(slot.parent);
            const positioned = try placePopup(value.placement, parent.geometry, desktop.work_area);
            const configure: Shell.PopupConfigure = .{
                .x = positioned.x,
                .y = positioned.y,
                .width = positioned.width,
                .height = positioned.height,
            };
            const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                desktop.popup_commands.len;
            desktop.popup_commands[tail] = .{
                .id = value.id,
                .configure = configure,
                .reposition_token = value.token,
            };
            desktop.popup_command_len += 1;
            slot.placement = value.placement;
        }

        fn destroyPopup(desktop: *Self, id: Shell.PopupId) void {
            const slot = desktop.popupByShell(id) catch return;
            if (desktop.destroyed_surface != null) return;
            const surface = slot.surface;
            const parent = slot.parent;
            const was_grab = if (desktop.popup_grab) |grab| std.meta.eql(grab, id) else false;
            const was_dismiss = if (desktop.popup_dismiss) |dismiss| std.meta.eql(dismiss, id) else false;
            const index: u32 = @intCast((@intFromPtr(slot) - @intFromPtr(desktop.popups.ptr)) /
                @sizeOf(PopupSlot));
            desktop.removePopupCommand(id);
            const generation = slot.generation;
            if (generation == std.math.maxInt(u32)) {
                slot.* = .{ .generation = generation };
            } else {
                slot.* = .{
                    .generation = generation + 1,
                    .next_free = desktop.popup_free,
                };
                desktop.popup_free = index;
            }
            desktop.popup_live -= 1;
            desktop.scene_changed = true;
            desktop.destroyed_surface = surface;
            const parent_popup = desktop.popupBySurface(parent);
            if (was_dismiss) {
                if (parent_popup) |popup| {
                    desktop.enqueuePopupDone(popup.shell_id) catch unreachable;
                    desktop.popup_dismiss = popup.shell_id;
                } else {
                    desktop.popup_dismiss = null;
                }
            } else if (was_grab) {
                desktop.popup_grab = if (parent_popup) |popup|
                    if (popup.grabbed) popup.shell_id else null
                else
                    null;
            }
        }

        fn destroyShell(desktop: *Self, shell_id: Shell.ToplevelId) !void {
            const id = try desktop.idForShell(shell_id);
            const index = try desktop.resolveIndex(id);
            const reclaimable = desktop.commandCountFor(id);
            if (desktop.commandAvailable() + reclaimable < desktop.live - 1)
                return error.Backpressure;
            if (desktop.interactive_request) |request| {
                if (std.meta.eql(request.id, id)) desktop.interactive_request = null;
            }
            desktop.removeCommandsFor(id);
            desktop.removeFocus(index);
            desktop.removeTile(index);
            desktop.unmapParenting(index);
            desktop.release(index);
            desktop.live -= 1;
            try desktop.reflow();
            desktop.destroyed = id;
        }

        fn setParent(desktop: *Self, id: ToplevelId, parent: ?ToplevelId) !void {
            const index = try desktop.resolveIndex(id);
            if (parent) |value| _ = try desktop.resolveIndex(value);
            desktop.slots[index].parent = parent;
            try desktop.reflow();
        }

        fn beginInitialCommit(desktop: *Self, index: u32) !void {
            const slot = &desktop.slots[index];
            if (slot.initial_committed) return;
            const adds_layout = slot.mode == .tiled and !slot.minimized and
                !slot.fullscreen and !slot.maximized;
            try desktop.validateLayout(desktop.layoutCount() + @intFromBool(adds_layout), desktop.work_area);
            try desktop.requireCommandCapacity(desktop.live);
            slot.initial_committed = true;
            if (slot.mode == .tiled) desktop.appendTile(index);
            desktop.promoteFocus(index);
            try desktop.reflow();
            // An unmapped role has no pixels to expose, so its initial layout
            // is a safe scene baseline. A later reflow can then retain content
            // committed for this configure until every participant is ready.
            slot.scene = slot.target_scene;
        }

        fn resetUnmapped(desktop: *Self, index: u32) !void {
            const id = desktop.idFor(index);
            const reclaimable = desktop.commandCountFor(id);
            if (desktop.commandAvailable() + reclaimable < desktop.live - 1)
                return error.Backpressure;
            if (desktop.interactive_request) |request| {
                if (std.meta.eql(request.id, id)) desktop.interactive_request = null;
            }
            desktop.removeCommandsFor(id);
            desktop.removeFocus(index);
            if (desktop.slots[index].mode == .tiled and desktop.slots[index].initial_committed)
                desktop.removeTile(index);
            desktop.unmapParenting(index);
            const slot = &desktop.slots[index];
            slot.mode = .tiled;
            slot.floating = desktop.defaultFloating();
            slot.fullscreen = false;
            slot.maximized = false;
            slot.minimized = false;
            slot.resizing = false;
            slot.initial_committed = false;
            slot.configured = false;
            slot.applied_configure = null;
            slot.expected_serial = null;
            slot.configure_ready = false;
            slot.content_ready = false;
            slot.scene.content_ready = false;
            slot.target_scene.content_ready = false;
            slot.scene.visible = false;
            slot.target_scene.visible = false;
            try desktop.reflow();
        }

        fn unmapParenting(desktop: *Self, index: u32) void {
            const id = desktop.idFor(index);
            const replacement = desktop.slots[index].parent;
            desktop.slots[index].parent = null;
            for (desktop.slots) |*child| {
                if (!child.header.active or child.parent == null or
                    !std.meta.eql(child.parent.?, id)) continue;
                child.parent = replacement;
            }
        }

        fn copyMetadata(desktop: *Self, id: ToplevelId, source: anytype) !void {
            if (source.title.len > desktop.metadata_bytes or source.app_id.len > desktop.metadata_bytes)
                return error.MetadataTooLong;
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            @memcpy(slot.title[0..source.title.len], source.title);
            @memcpy(slot.app_id[0..source.app_id.len], source.app_id);
            slot.title_len = source.title.len;
            slot.app_id_len = source.app_id.len;
            slot.min_width = source.min_width;
            slot.min_height = source.min_height;
            slot.max_width = source.max_width;
            slot.max_height = source.max_height;
        }

        fn requestState(desktop: *Self, id: ToplevelId, state: Shell.RequestedState, enabled: bool) !void {
            const index = try desktop.resolveIndex(id);
            const slot = &desktop.slots[index];
            const unchanged = switch (state) {
                .fullscreen => slot.fullscreen == enabled,
                .maximized => slot.maximized == enabled,
                .minimized => slot.minimized == enabled,
            };
            if (unchanged) return;
            try desktop.requireCommandCapacity(desktop.live);
            var next_layout_count = desktop.layoutCount();
            const was_eligible = desktop.isLayoutEligible(index);
            const next_fullscreen = if (state == .fullscreen) enabled else slot.fullscreen;
            const next_maximized = if (state == .maximized) enabled else slot.maximized;
            const next_minimized = if (state == .minimized) enabled else slot.minimized;
            const will_be_eligible = slot.initial_committed and slot.mode == .tiled and !next_fullscreen and
                !next_maximized and !next_minimized;
            if (was_eligible and !will_be_eligible) next_layout_count -= 1;
            if (!was_eligible and will_be_eligible) next_layout_count += 1;
            try desktop.validateLayout(next_layout_count, desktop.work_area);
            switch (state) {
                .fullscreen => slot.fullscreen = enabled,
                .maximized => slot.maximized = enabled,
                .minimized => {
                    slot.minimized = enabled;
                    if (enabled) desktop.removeFocus(index) else desktop.promoteFocus(index);
                },
            }
            try desktop.reflow();
        }

        fn reflow(desktop: *Self) !void {
            @memset(desktop.desired, .{});
            var item_len: usize = 0;
            for (desktop.tile_order[0..desktop.tile_len]) |index| {
                const slot = &desktop.slots[index];
                if (!slot.minimized and !slot.fullscreen and !slot.maximized) {
                    desktop.layout_items[item_len] = .{ .slot = index };
                    item_len += 1;
                }
            }
            const placements = try layout.plan(
                desktop.layout_items[0..item_len],
                desktop.work_area,
                desktop.placements,
            );
            for (placements) |placement| {
                desktop.desired[placement.slot] = .{
                    .active = true,
                    .rect = placement.rect,
                    .visible = true,
                };
            }

            var stacking: u32 = 0;
            for (desktop.tile_order[0..desktop.tile_len]) |index| {
                const slot = &desktop.slots[index];
                if (slot.minimized) {
                    desktop.desired[index] = .{
                        .active = true,
                        .rect = slot.scene.geometry,
                        .visible = false,
                    };
                } else if (slot.fullscreen or slot.maximized) {
                    desktop.desired[index] = .{
                        .active = true,
                        .rect = desktop.work_area,
                        .visible = true,
                    };
                }
                desktop.desired[index].stacking = stacking;
                stacking += 1;
            }
            for (desktop.slots, 0..) |slot, index| {
                if (!slot.header.active or slot.mode != .floating) continue;
                desktop.desired[index] = .{
                    .active = true,
                    .rect = if (slot.fullscreen or slot.maximized) desktop.work_area else slot.floating,
                    .visible = !slot.minimized,
                    .stacking = stacking,
                };
                stacking += 1;
            }
            if (desktop.focus_len != 0) {
                const focused_index = desktop.focus[0];
                const focused_slot = &desktop.slots[focused_index];
                if (focused_slot.mode == .floating or focused_slot.fullscreen or
                    focused_slot.maximized)
                {
                    desktop.desired[focused_index].stacking = stacking;
                }
            }

            // Preserve the policy order above while moving every child after
            // its parent. Repeating the stable move handles complete ancestor
            // chains without allocating another scene-order buffer.
            for (0..desktop.live) |_| {
                var moved = false;
                for (desktop.slots, 0..) |slot, child_index| {
                    if (!slot.header.active or slot.parent == null) continue;
                    const parent_index = desktop.resolveIndex(slot.parent.?) catch continue;
                    const child_stacking = desktop.desired[child_index].stacking;
                    const parent_stacking = desktop.desired[parent_index].stacking;
                    if (child_stacking > parent_stacking) continue;
                    for (desktop.desired, desktop.slots) |*desired, candidate| {
                        if (!candidate.header.active or desired.stacking <= child_stacking or
                            desired.stacking > parent_stacking) continue;
                        desired.stacking -= 1;
                    }
                    desktop.desired[child_index].stacking = parent_stacking;
                    moved = true;
                }
                if (!moved) break;
            }

            for (desktop.slots, 0..) |*slot, index| {
                if (!slot.header.active or !slot.initial_committed) continue;
                const desired = &desktop.desired[index];
                std.debug.assert(desired.active);
                desired.configure = .{
                    .width = desired.rect.width,
                    .height = desired.rect.height,
                    .states = .{
                        .maximized = slot.maximized,
                        .fullscreen = slot.fullscreen,
                        .activated = desktop.focus_len != 0 and desktop.focus[0] == index,
                        .resizing = slot.resizing,
                        .tiled_left = slot.mode == .tiled and desired.rect.x == desktop.work_area.x,
                        .tiled_right = slot.mode == .tiled and
                            desired.rect.x + desired.rect.width == desktop.work_area.x + desktop.work_area.width,
                        .tiled_top = slot.mode == .tiled and desired.rect.y == desktop.work_area.y,
                        .tiled_bottom = slot.mode == .tiled and
                            desired.rect.y + desired.rect.height == desktop.work_area.y + desktop.work_area.height,
                        .suspended = slot.minimized,
                    },
                };
                if (!slot.configured or !std.meta.eql(slot.last_configure, desired.configure)) {
                    desktop.enqueue(.{
                        .id = desktop.idFor(@intCast(index)),
                        .shell_id = slot.shell_id,
                        .configure = desired.configure,
                    });
                    slot.last_configure = desired.configure;
                    slot.configured = true;
                    slot.expected_serial = null;
                    slot.configure_ready = false;
                }
                slot.target_scene = .{
                    .id = desktop.idFor(@intCast(index)),
                    .surface = slot.surface,
                    .geometry = desired.rect,
                    .has_window_geometry = slot.target_scene.has_window_geometry,
                    .surface_offset = slot.target_scene.surface_offset,
                    .visible = desired.visible,
                    .stacking = desired.stacking,
                    .mode = slot.mode,
                    .content_ready = slot.content_ready,
                };
            }
            desktop.publishReadyScene();
        }

        fn publishReadyScene(desktop: *Self) void {
            for (desktop.slots) |slot| {
                if (!slot.header.active or !slot.configured) continue;
                if (slot.applied_configure == null or
                    !std.meta.eql(slot.applied_configure.?, slot.last_configure))
                {
                    if (slot.expected_serial == null or !slot.configure_ready) return;
                }
            }
            desktop.publishScene();
        }

        fn publishScene(desktop: *Self) void {
            var changed = false;
            var max_toplevel_stacking: u32 = 0;
            for (desktop.slots) |*slot| {
                if (!slot.header.active) continue;
                changed = !std.meta.eql(slot.scene, slot.target_scene) or changed;
                slot.scene = slot.target_scene;
                max_toplevel_stacking = @max(max_toplevel_stacking, slot.scene.stacking);
                if (slot.configured) slot.applied_configure = slot.last_configure;
                slot.expected_serial = null;
                slot.configure_ready = false;
            }
            var min_popup_stacking: ?u32 = null;
            for (desktop.popups) |popup| if (popup.active) {
                min_popup_stacking = if (min_popup_stacking) |current|
                    @min(current, popup.scene.stacking)
                else
                    popup.scene.stacking;
            };
            if (min_popup_stacking) |minimum| if (minimum <= max_toplevel_stacking) {
                const shift = max_toplevel_stacking - minimum +| 1;
                for (desktop.popups) |*popup| {
                    if (popup.active) popup.scene.stacking +|= shift;
                }
                changed = true;
            };
            for (0..desktop.popup_live) |_| for (desktop.popups) |*popup| {
                if (!popup.active or !popup.content_ready) continue;
                const parent = desktop.sceneForSurface(popup.parent) catch {
                    changed = popup.scene.visible or changed;
                    popup.scene.visible = false;
                    continue;
                };
                const next_geometry = popupAbsolute(popup.configure, parent.geometry);
                changed = !std.meta.eql(popup.scene.geometry, next_geometry) or
                    popup.scene.visible != parent.visible or changed;
                popup.scene.geometry = next_geometry;
                popup.scene.visible = parent.visible;
            };
            desktop.scene_changed = changed or desktop.scene_changed;
        }

        fn defaultFloating(desktop: *const Self) geometry.Rect {
            const width: i32 = @intCast(@max(1, @divTrunc(@as(i64, desktop.work_area.width) * 3, 4)));
            const height: i32 = @intCast(@max(1, @divTrunc(@as(i64, desktop.work_area.height) * 3, 4)));
            return .{
                .x = desktop.work_area.x + @divTrunc(desktop.work_area.width - width, 2),
                .y = desktop.work_area.y + @divTrunc(desktop.work_area.height - height, 2),
                .width = width,
                .height = height,
            };
        }

        fn commandAvailable(desktop: *const Self) usize {
            return desktop.commands.len - desktop.command_len;
        }

        fn isLayoutEligible(desktop: *const Self, index: u32) bool {
            const slot = &desktop.slots[index];
            return slot.initial_committed and slot.mode == .tiled and !slot.minimized and
                !slot.fullscreen and !slot.maximized;
        }

        fn layoutCount(desktop: *const Self) usize {
            var count: usize = 0;
            for (desktop.slots, 0..) |slot, index| {
                if (slot.header.active and desktop.isLayoutEligible(@intCast(index))) count += 1;
            }
            return count;
        }

        fn validateLayout(desktop: *const Self, count: usize, area: geometry.Rect) !void {
            _ = desktop;
            if (count > 1 and (area.width < 2 or area.height < count - 1))
                return error.WorkAreaTooSmall;
        }

        fn requireCommandCapacity(desktop: *Self, count: usize) !void {
            const needed = std.math.add(usize, desktop.command_len, count) catch
                return error.OutOfMemory;
            if (needed <= desktop.commands.len) return;
            var capacity = desktop.commands.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            const replacement = try desktop.allocator.alloc(Command, capacity);
            for (0..desktop.command_len) |offset|
                replacement[offset] = desktop.commands[(desktop.command_head + offset) % desktop.commands.len];
            desktop.allocator.free(desktop.commands);
            desktop.commands = replacement;
            desktop.command_head = 0;
        }

        fn requirePopupCommandCapacity(desktop: *Self, count: usize) !void {
            const needed = std.math.add(usize, desktop.popup_command_len, count + 1) catch
                return error.OutOfMemory;
            if (needed <= desktop.popup_commands.len) return;
            var capacity = desktop.popup_commands.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            const replacement = try desktop.allocator.alloc(PopupCommand, capacity);
            for (0..desktop.popup_command_len) |offset|
                replacement[offset] = desktop.popup_commands[(desktop.popup_command_head + offset) % desktop.popup_commands.len];
            desktop.allocator.free(desktop.popup_commands);
            desktop.popup_commands = replacement;
            desktop.popup_command_head = 0;
        }

        fn enqueue(desktop: *Self, command: Command) void {
            std.debug.assert(desktop.command_len < desktop.commands.len);
            const tail = (desktop.command_head + desktop.command_len) % desktop.commands.len;
            desktop.commands[tail] = command;
            desktop.command_len += 1;
        }

        fn commandCountFor(desktop: *const Self, id: ToplevelId) usize {
            var count: usize = 0;
            for (0..desktop.command_len) |offset| {
                const index = (desktop.command_head + offset) % desktop.commands.len;
                if (std.meta.eql(desktop.commands[index].id, id)) count += 1;
            }
            return count;
        }

        fn removeCommandsFor(desktop: *Self, id: ToplevelId) void {
            var retained: usize = 0;
            const original_len = desktop.command_len;
            for (0..original_len) |offset| {
                const source = (desktop.command_head + offset) % desktop.commands.len;
                if (std.meta.eql(desktop.commands[source].id, id)) continue;
                const destination = (desktop.command_head + retained) % desktop.commands.len;
                desktop.commands[destination] = desktop.commands[source];
                retained += 1;
            }
            desktop.command_len = retained;
        }

        fn popupByShell(desktop: *Self, id: Shell.PopupId) !*PopupSlot {
            for (desktop.popups) |*slot| if (slot.active and std.meta.eql(slot.shell_id, id))
                return slot;
            return error.StalePopup;
        }

        fn removePopupCommand(desktop: *Self, id: Shell.PopupId) void {
            var retained: usize = 0;
            const original_len = desktop.popup_command_len;
            for (0..original_len) |offset| {
                const source = (desktop.popup_command_head + offset) % desktop.popup_commands.len;
                if (std.meta.eql(desktop.popup_commands[source].id, id)) continue;
                const destination = (desktop.popup_command_head + retained) % desktop.popup_commands.len;
                desktop.popup_commands[destination] = desktop.popup_commands[source];
                retained += 1;
            }
            desktop.popup_command_len = retained;
        }

        fn enqueuePopupDone(desktop: *Self, id: Shell.PopupId) !void {
            if (desktop.popup_command_len == desktop.popup_commands.len) return error.Exhausted;
            const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                desktop.popup_commands.len;
            desktop.popup_commands[tail] = .{ .id = id, .done = true };
            desktop.popup_command_len += 1;
        }

        fn popupBySurface(desktop: *Self, surface: Shell.SurfaceId) ?*PopupSlot {
            for (desktop.popups) |*slot| if (slot.active and std.meta.eql(slot.surface, surface))
                return slot;
            return null;
        }

        fn nextStacking(desktop: *const Self) u32 {
            var next: u32 = 0;
            for (desktop.slots) |slot| {
                if (slot.header.active) next = @max(next, slot.scene.stacking +| 1);
            }
            for (desktop.popups) |slot| {
                if (slot.active) next = @max(next, slot.scene.stacking +| 1);
            }
            return next;
        }

        fn growToplevels(desktop: *Self) !void {
            const old_len = desktop.slots.len;
            const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            if (new_len >= none) return error.OutOfMemory;
            const slots = try desktop.allocator.alloc(Slot, new_len);
            errdefer desktop.allocator.free(slots);
            const storage_len = std.math.mul(usize, new_len, desktop.metadata_bytes * 2) catch
                return error.OutOfMemory;
            const storage = try desktop.allocator.alloc(u8, storage_len);
            errdefer desktop.allocator.free(storage);
            const focus = try desktop.allocator.alloc(u32, new_len);
            errdefer desktop.allocator.free(focus);
            const tile_order = try desktop.allocator.alloc(u32, new_len);
            errdefer desktop.allocator.free(tile_order);
            const layout_items = try desktop.allocator.alloc(layout.Item, new_len);
            errdefer desktop.allocator.free(layout_items);
            const placements = try desktop.allocator.alloc(layout.Placement, new_len);
            errdefer desktop.allocator.free(placements);
            const desired = try desktop.allocator.alloc(Desired, new_len);
            errdefer desktop.allocator.free(desired);

            for (slots, 0..) |*slot, index| {
                const start = index * desktop.metadata_bytes * 2;
                if (index < old_len) {
                    slot.* = desktop.slots[index];
                    @memcpy(storage[start .. start + desktop.metadata_bytes], slot.title);
                    @memcpy(storage[start + desktop.metadata_bytes .. start + desktop.metadata_bytes * 2], slot.app_id);
                } else slot.* = .{ .header = .{
                    .next_free = if (index + 1 < new_len) @intCast(index + 1) else none,
                } };
                slot.title = storage[start .. start + desktop.metadata_bytes];
                slot.app_id = storage[start + desktop.metadata_bytes .. start + desktop.metadata_bytes * 2];
            }
            @memcpy(focus[0..desktop.focus_len], desktop.focus[0..desktop.focus_len]);
            @memcpy(tile_order[0..desktop.tile_len], desktop.tile_order[0..desktop.tile_len]);
            @memcpy(desired[0..old_len], desktop.desired);
            @memset(desired[old_len..], .{});

            desktop.allocator.free(desktop.desired);
            desktop.allocator.free(desktop.placements);
            desktop.allocator.free(desktop.layout_items);
            desktop.allocator.free(desktop.tile_order);
            desktop.allocator.free(desktop.focus);
            desktop.allocator.free(desktop.metadata_storage);
            desktop.allocator.free(desktop.slots);
            desktop.slots = slots;
            desktop.metadata_storage = storage;
            desktop.focus = focus;
            desktop.tile_order = tile_order;
            desktop.layout_items = layout_items;
            desktop.placements = placements;
            desktop.desired = desired;
            desktop.free = @intCast(old_len);
        }

        fn growPopups(desktop: *Self) !void {
            const old_len = desktop.popups.len;
            const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            if (new_len >= none) return error.OutOfMemory;
            const popups = try desktop.allocator.alloc(PopupSlot, new_len);
            @memcpy(popups[0..old_len], desktop.popups);
            for (popups[old_len..], old_len..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < new_len) @intCast(index + 1) else none,
            };
            desktop.allocator.free(desktop.popups);
            desktop.popups = popups;
            desktop.popup_free = @intCast(old_len);
        }

        fn acquire(desktop: *Self) u32 {
            std.debug.assert(desktop.free != none);
            const index = desktop.free;
            const slot = &desktop.slots[index];
            desktop.free = slot.header.next_free;
            const generation = slot.header.generation;
            const title = slot.title;
            const app_id = slot.app_id;
            slot.* = .{
                .header = .{ .active = true, .generation = generation },
                .title = title,
                .app_id = app_id,
            };
            return index;
        }

        fn release(desktop: *Self, index: u32) void {
            const slot = &desktop.slots[index];
            const generation = slot.header.generation;
            const title = slot.title;
            const app_id = slot.app_id;
            if (generation == std.math.maxInt(u32)) {
                slot.* = .{
                    .header = .{ .retired = true, .generation = generation },
                    .title = title,
                    .app_id = app_id,
                };
            } else {
                slot.* = .{
                    .header = .{ .generation = generation + 1, .next_free = desktop.free },
                    .title = title,
                    .app_id = app_id,
                };
                desktop.free = index;
            }
        }

        fn resolveIndex(desktop: *const Self, id: ToplevelId) !u32 {
            if (id.index >= desktop.slots.len) return error.StaleToplevel;
            const slot = &desktop.slots[id.index];
            if (!slot.header.active or slot.header.generation != id.generation)
                return error.StaleToplevel;
            return id.index;
        }

        fn idFor(desktop: *const Self, index: u32) ToplevelId {
            return .{ .index = index, .generation = desktop.slots[index].header.generation };
        }

        fn promoteFocus(desktop: *Self, index: u32) void {
            desktop.removeFocus(index);
            std.mem.copyBackwards(u32, desktop.focus[1 .. desktop.focus_len + 1], desktop.focus[0..desktop.focus_len]);
            desktop.focus[0] = index;
            desktop.focus_len += 1;
        }

        fn removeFocus(desktop: *Self, index: u32) void {
            for (desktop.focus[0..desktop.focus_len], 0..) |value, position| {
                if (value != index) continue;
                std.mem.copyForwards(
                    u32,
                    desktop.focus[position .. desktop.focus_len - 1],
                    desktop.focus[position + 1 .. desktop.focus_len],
                );
                desktop.focus_len -= 1;
                return;
            }
        }

        fn appendTile(desktop: *Self, index: u32) void {
            desktop.tile_order[desktop.tile_len] = index;
            desktop.tile_len += 1;
        }

        fn removeTile(desktop: *Self, index: u32) void {
            for (desktop.tile_order[0..desktop.tile_len], 0..) |value, position| {
                if (value != index) continue;
                std.mem.copyForwards(
                    u32,
                    desktop.tile_order[position .. desktop.tile_len - 1],
                    desktop.tile_order[position + 1 .. desktop.tile_len],
                );
                desktop.tile_len -= 1;
                return;
            }
        }
    };
}

const PopupGeometry = struct { x: i32, y: i32, width: i32, height: i32 };

fn placePopup(placement: anytype, parent: geometry.Rect, bounds: geometry.Rect) !PopupGeometry {
    const width: i64 = placement.width;
    const height: i64 = placement.height;
    if (width <= 0 or height <= 0) return error.InvalidGeometry;
    const anchor_x = popupAnchorPoint(placement.anchor, true, placement.anchor_x, placement.anchor_width);
    const anchor_y = popupAnchorPoint(placement.anchor, false, placement.anchor_y, placement.anchor_height);
    var x = popupOrigin(anchor_x, width, placement.gravity, true) + placement.offset_x;
    var y = popupOrigin(anchor_y, height, placement.gravity, false) + placement.offset_y;
    var adjusted_width = width;
    var adjusted_height = height;
    const left: i64 = @as(i64, bounds.x) - parent.x;
    const top: i64 = @as(i64, bounds.y) - parent.y;
    const right = left + bounds.width;
    const bottom = top + bounds.height;

    if ((x < left or x + width > right) and placement.constraint_adjustment & 4 != 0) {
        const flipped_anchor = flipDirection(placement.anchor, true);
        const flipped_gravity = flipDirection(placement.gravity, true);
        const candidate = popupOrigin(
            popupAnchorPoint(flipped_anchor, true, placement.anchor_x, placement.anchor_width),
            width,
            flipped_gravity,
            true,
        ) + placement.offset_x;
        if (candidate >= left and candidate + width <= right) x = candidate;
    }
    if ((y < top or y + height > bottom) and placement.constraint_adjustment & 8 != 0) {
        const flipped_anchor = flipDirection(placement.anchor, false);
        const flipped_gravity = flipDirection(placement.gravity, false);
        const candidate = popupOrigin(
            popupAnchorPoint(flipped_anchor, false, placement.anchor_y, placement.anchor_height),
            height,
            flipped_gravity,
            false,
        ) + placement.offset_y;
        if (candidate >= top and candidate + height <= bottom) y = candidate;
    }
    if (placement.constraint_adjustment & 1 != 0)
        x = std.math.clamp(x, left, @max(left, right - width));
    if (placement.constraint_adjustment & 2 != 0)
        y = std.math.clamp(y, top, @max(top, bottom - height));
    if (placement.constraint_adjustment & 16 != 0) {
        const clipped_left = @max(x, left);
        const clipped_right = @min(x + adjusted_width, right);
        x = clipped_left;
        adjusted_width = @max(1, clipped_right - clipped_left);
    }
    if (placement.constraint_adjustment & 32 != 0) {
        const clipped_top = @max(y, top);
        const clipped_bottom = @min(y + adjusted_height, bottom);
        y = clipped_top;
        adjusted_height = @max(1, clipped_bottom - clipped_top);
    }
    return .{
        .x = std.math.cast(i32, x) orelse return error.InvalidGeometry,
        .y = std.math.cast(i32, y) orelse return error.InvalidGeometry,
        .width = std.math.cast(i32, adjusted_width) orelse return error.InvalidGeometry,
        .height = std.math.cast(i32, adjusted_height) orelse return error.InvalidGeometry,
    };
}

fn popupAnchorPoint(direction: u32, horizontal: bool, start: i32, size: i32) i64 {
    const toward_start = if (horizontal)
        direction == 3 or direction == 5 or direction == 6
    else
        direction == 1 or direction == 5 or direction == 7;
    const toward_end = if (horizontal)
        direction == 4 or direction == 7 or direction == 8
    else
        direction == 2 or direction == 6 or direction == 8;
    if (toward_start) return start;
    if (toward_end) return @as(i64, start) + size;
    return @as(i64, start) + @divTrunc(@as(i64, size), 2);
}

fn popupOrigin(anchor: i64, size: i64, gravity: u32, horizontal: bool) i64 {
    const toward_start = if (horizontal)
        gravity == 3 or gravity == 5 or gravity == 6
    else
        gravity == 1 or gravity == 5 or gravity == 7;
    const toward_end = if (horizontal)
        gravity == 4 or gravity == 7 or gravity == 8
    else
        gravity == 2 or gravity == 6 or gravity == 8;
    if (toward_start) return anchor - size;
    if (toward_end) return anchor;
    return anchor - @divTrunc(size, 2);
}

fn flipDirection(direction: u32, horizontal: bool) u32 {
    return if (horizontal) switch (direction) {
        3 => 4,
        4 => 3,
        5 => 7,
        7 => 5,
        6 => 8,
        8 => 6,
        else => direction,
    } else switch (direction) {
        1 => 2,
        2 => 1,
        5 => 6,
        6 => 5,
        7 => 8,
        8 => 7,
        else => direction,
    };
}

fn popupAbsolute(configure: anytype, parent: geometry.Rect) geometry.Rect {
    return .{
        .x = parent.x +| configure.x,
        .y = parent.y +| configure.y,
        .width = configure.width,
        .height = configure.height,
    };
}

const TestShell = struct {
    pub const SurfaceId = packed struct { index: u32, generation: u32 };
    pub const ToplevelId = packed struct { index: u32, generation: u32 };
    pub const PopupId = packed struct { index: u32, generation: u32 };
    pub const ResizeEdge = enum { top, bottom, left, top_left, bottom_left, right, top_right, bottom_right };
    pub const PopupPlacement = struct {
        width: i32,
        height: i32,
        anchor_x: i32,
        anchor_y: i32,
        anchor_width: i32,
        anchor_height: i32,
        anchor: u32,
        gravity: u32,
        constraint_adjustment: u32,
        offset_x: i32,
        offset_y: i32,
    };
    pub const RequestedState = enum { maximized, fullscreen, minimized };
    pub const StateSet = packed struct(u16) {
        maximized: bool = false,
        fullscreen: bool = false,
        resizing: bool = false,
        activated: bool = false,
        tiled_left: bool = false,
        tiled_right: bool = false,
        tiled_top: bool = false,
        tiled_bottom: bool = false,
        suspended: bool = false,
        _padding: u7 = 0,
    };
    pub const ToplevelConfigure = struct {
        width: i32,
        height: i32,
        states: StateSet = .{},
    };
    pub const PopupConfigure = struct { x: i32, y: i32, width: i32, height: i32 };
    pub const Event = union(enum) {
        toplevel_created: struct { id: ToplevelId, surface: SurfaceId },
        popup_created: struct { id: PopupId, surface: SurfaceId, parent: SurfaceId, placement: PopupPlacement },
        metadata_changed: ToplevelId,
        parent_changed: struct { id: ToplevelId, parent: ?ToplevelId },
        state_requested: struct { id: ToplevelId, state: RequestedState, enabled: bool },
        move_requested: ToplevelId,
        resize_requested: struct { id: ToplevelId, edge: ResizeEdge },
        commit_ready: struct {
            id: ToplevelId,
            serial: u32,
            has_window_geometry: bool = false,
            surface_offset_x: i32 = 0,
            surface_offset_y: i32 = 0,
            unmapped: bool = false,
            constraints_changed: bool = false,
            initial_commit: bool = false,
            mapped: bool = true,
        },
        popup_commit_ready: struct {
            id: PopupId,
            serial: u32,
            has_window_geometry: bool = false,
            surface_offset_x: i32 = 0,
            surface_offset_y: i32 = 0,
        },
        popup_reposition_requested: struct { id: PopupId, placement: PopupPlacement, token: u32 },
        popup_grab_requested: PopupId,
        toplevel_destroyed: ToplevelId,
        popup_destroyed: PopupId,
    };

    events: [16]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    title: []const u8 = "",
    app_id: []const u8 = "",
    reject_configure: bool = false,
    configure_serial: u32 = 40,
    configured: ?ToplevelConfigure = null,
    popup_configured: ?PopupConfigure = null,
    popup_done: ?PopupId = null,

    fn push(shell: *TestShell, event: Event) void {
        shell.events[(shell.head + shell.len) % shell.events.len] = event;
        shell.len += 1;
    }

    pub fn popEvent(shell: *TestShell) ?Event {
        if (shell.len == 0) return null;
        const event = shell.events[shell.head];
        shell.head = (shell.head + 1) % shell.events.len;
        shell.len -= 1;
        return event;
    }

    pub fn metadata(shell: *TestShell, id: ToplevelId) !struct {
        title: []const u8,
        app_id: []const u8,
        min_width: i32,
        min_height: i32,
        max_width: i32,
        max_height: i32,
    } {
        _ = id;
        return .{
            .title = shell.title,
            .app_id = shell.app_id,
            .min_width = 10,
            .min_height = 20,
            .max_width = 0,
            .max_height = 0,
        };
    }

    pub fn queueToplevelConfigure(
        shell: *TestShell,
        id: ToplevelId,
        value: ToplevelConfigure,
    ) !u32 {
        _ = id;
        if (shell.reject_configure) return error.Exhausted;
        shell.configure_serial += 1;
        shell.configured = value;
        return shell.configure_serial;
    }

    pub fn queuePopupConfigure(shell: *TestShell, id: PopupId, value: PopupConfigure) !u32 {
        _ = id;
        if (shell.reject_configure) return error.Exhausted;
        shell.configure_serial += 1;
        shell.popup_configured = value;
        return shell.configure_serial;
    }

    pub fn queuePopupReposition(shell: *TestShell, id: PopupId, value: PopupConfigure, token: u32) !u32 {
        _ = token;
        return shell.queuePopupConfigure(id, value);
    }

    pub fn queuePopupDone(shell: *TestShell, id: PopupId) !void {
        if (shell.reject_configure) return error.Exhausted;
        shell.popup_done = id;
    }
};

const TestDesktop = Desktop(TestShell);

fn initTestDesktop(command_capacity: usize) !TestDesktop {
    return TestDesktop.init(std.testing.allocator, .{
        .toplevel_capacity = 3,
        .command_capacity = command_capacity,
        .metadata_bytes = 16,
    }, .{ .x = 0, .y = 0, .width = 100, .height = 60 });
}

fn created(index: u32) TestShell.Event {
    return .{ .toplevel_created = .{
        .id = .{ .index = index, .generation = 1 },
        .surface = .{ .index = index + 10, .generation = 2 },
    } };
}

fn beginInitialDesktop(desktop: *TestDesktop, shell: *TestShell) !void {
    for (desktop.slots) |slot| {
        if (!slot.header.active or slot.initial_committed) continue;
        shell.push(.{ .commit_ready = .{
            .id = slot.shell_id,
            .serial = 0,
            .initial_commit = true,
            .mapped = false,
        } });
    }
    _ = try desktop.consume(shell, shell.len);
}

fn settleDesktop(desktop: *TestDesktop, shell: *TestShell) !void {
    try beginInitialDesktop(desktop, shell);
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(shell);
    for (desktop.slots) |slot| {
        if (!slot.header.active) continue;
        if (slot.expected_serial) |serial| shell.push(.{ .commit_ready = .{
            .id = slot.shell_id,
            .serial = serial,
            .mapped = true,
        } });
    }
    _ = try desktop.consume(shell, shell.len);
}

test "desktop: shell events produce exact tiling, focus, metadata, and configures" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 8));

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 }, (try desktop.scene(first)).geometry);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 }, (try desktop.scene(first)).geometry);
    try std.testing.expectEqual(geometry.Rect{ .x = 50, .y = 0, .width = 50, .height = 60 }, (try desktop.scene(second)).geometry);
    try std.testing.expectEqual(second, desktop.focused().?);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    var snapshot_storage: [3]TestDesktop.SceneWindow = undefined;
    const snapshot = try desktop.sceneSnapshot(&snapshot_storage);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expect(snapshot[0].stacking < snapshot[1].stacking);

    shell.title = "terminal";
    shell.app_id = "term";
    shell.push(.{ .metadata_changed = .{ .index = 0, .generation = 1 } });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
    } });
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 8));
    try std.testing.expectEqualStrings("terminal", (try desktop.metadata(first)).title);
    try std.testing.expect((try desktop.scene(first)).content_ready);
}

test "desktop: initial commit gates configure and unmap requires it again" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try std.testing.expect(desktop.focused() == null);
    try std.testing.expect(!(try desktop.scene(id)).visible);

    try beginInitialDesktop(&desktop, &shell);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    try std.testing.expectEqual(id, desktop.focused().?);
    const serial = (try desktop.flushConfigure(&shell)).?;
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = serial,
        .mapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect((try desktop.scene(id)).content_ready);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .unmapped = true,
        .mapped = false,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.slots[id.index].initial_committed);
    try std.testing.expect(!desktop.slots[id.index].configured);
    try std.testing.expect(desktop.focused() == null);
    try std.testing.expect(!(try desktop.scene(id)).visible);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());

    try beginInitialDesktop(&desktop, &shell);
    try std.testing.expect(desktop.slots[id.index].initial_committed);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
}

test "desktop: toplevel parents preserve ancestor stacking and reparent on unmap" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);

    const child = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const ancestor = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const parent = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    shell.push(.{ .parent_changed = .{
        .id = .{ .index = 0, .generation = 1 },
        .parent = .{ .index = 2, .generation = 1 },
    } });
    shell.push(.{ .parent_changed = .{
        .id = .{ .index = 2, .generation = 1 },
        .parent = .{ .index = 1, .generation = 1 },
    } });
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);

    try std.testing.expect((try desktop.scene(child)).stacking > (try desktop.scene(parent)).stacking);
    try std.testing.expect((try desktop.scene(parent)).stacking > (try desktop.scene(ancestor)).stacking);
    try std.testing.expectEqual(parent, desktop.slots[child.index].parent.?);
    try std.testing.expectEqual(ancestor, desktop.slots[parent.index].parent.?);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 2, .generation = 1 },
        .serial = 0,
        .unmapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(ancestor, desktop.slots[child.index].parent.?);
    try std.testing.expect(desktop.slots[parent.index].parent == null);
    try std.testing.expect(!(try desktop.scene(parent)).content_ready);
    try std.testing.expect((try desktop.scene(child)).stacking > (try desktop.scene(ancestor)).stacking);

    shell.push(.{ .toplevel_destroyed = .{ .index = 1, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.slots[child.index].parent == null);
}

test "desktop: committed toplevel constraints update interaction bounds" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(@as(i32, 0), (try desktop.metadata(id)).min_width);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .constraints_changed = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const metadata = try desktop.metadata(id);
    try std.testing.expectEqual(@as(i32, 10), metadata.min_width);
    try std.testing.expectEqual(@as(i32, 20), metadata.min_height);
}

test "desktop: popup configure maps above its owning toplevel" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const owner = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const parent = (try desktop.scene(owner)).surface;
    const popup_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 2 };
    shell.push(.{ .popup_created = .{
        .id = popup_id,
        .surface = popup_surface,
        .parent = parent,
        .placement = .{
            .width = 20,
            .height = 10,
            .anchor_x = 10,
            .anchor_y = 10,
            .anchor_width = 20,
            .anchor_height = 10,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
    } });
    _ = try desktop.consume(&shell, 1);
    const serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(TestShell.PopupConfigure{
        .x = 30,
        .y = 20,
        .width = 20,
        .height = 10,
    }, shell.popup_configured.?);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = serial } });
    _ = try desktop.consume(&shell, 1);
    const popup = try desktop.sceneForSurface(popup_surface);
    try std.testing.expectEqual(owner, popup.id);
    try std.testing.expectEqual(geometry.Rect{ .x = 30, .y = 20, .width = 20, .height = 10 }, popup.geometry);
    try std.testing.expect(popup.visible and popup.content_ready);
    try std.testing.expectError(error.StaleToplevel, desktop.toplevelSceneForSurface(popup_surface));
    try std.testing.expectEqual(owner, (try desktop.toplevelSceneForSurface(parent)).id);
    var snapshot_storage: [4]TestDesktop.SceneWindow = undefined;
    const snapshot = try desktop.sceneSnapshot(&snapshot_storage);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expect(snapshot[0].stacking < snapshot[1].stacking);
    try std.testing.expectEqual(popup_surface, snapshot[1].surface);

    shell.push(.{ .popup_reposition_requested = .{
        .id = popup_id,
        .placement = .{
            .width = 10,
            .height = 10,
            .anchor_x = 0,
            .anchor_y = 0,
            .anchor_width = 20,
            .anchor_height = 20,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
        .token = 99,
    } });
    _ = try desktop.consume(&shell, 1);
    const reposition_serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(
        geometry.Rect{ .x = 30, .y = 20, .width = 20, .height = 10 },
        (try desktop.sceneForSurface(popup_surface)).geometry,
    );
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = reposition_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 20, .y = 20, .width = 10, .height = 10 },
        (try desktop.sceneForSurface(popup_surface)).geometry,
    );

    shell.push(.{ .popup_grab_requested = popup_id });
    _ = try desktop.consume(&shell, 1);
    const grab = desktop.popupGrabTarget() orelse return error.MissingPopupGrab;
    try std.testing.expectEqual(owner, grab.toplevel);
    try std.testing.expectEqual(popup_surface, grab.surface);
    try std.testing.expect(try desktop.dismissPopupGrab());
    try std.testing.expect(desktop.popupGrabTarget() == null);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(popup_id, shell.popup_done.?);

    shell.push(.{ .popup_destroyed = popup_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectError(error.StaleSurface, desktop.sceneForSurface(popup_surface));
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: popup placement flips before sliding or resizing" {
    const placement: TestShell.PopupPlacement = .{
        .width = 20,
        .height = 20,
        .anchor_x = 90,
        .anchor_y = 50,
        .anchor_width = 10,
        .anchor_height = 10,
        .anchor = 8,
        .gravity = 8,
        .constraint_adjustment = 4 | 8,
        .offset_x = 0,
        .offset_y = 0,
    };
    try std.testing.expectEqual(PopupGeometry{
        .x = 70,
        .y = 30,
        .width = 20,
        .height = 20,
    }, try placePopup(
        placement,
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
    ));
}

test "desktop: scene transaction waits for every exact configure serial" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(&shell);
    const first_serial = desktop.slots[try desktop.resolveIndex(first)].expected_serial.?;
    const second_serial = desktop.slots[try desktop.resolveIndex(second)].expected_serial.?;

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = first_serial,
    } });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial - 1,
    } });
    _ = try desktop.consume(&shell, 2);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 },
        (try desktop.scene(first)).geometry,
    );
    try std.testing.expect(!desktop.takeSceneChanged());

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 },
        (try desktop.scene(first)).geometry,
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 50, .y = 0, .width = 50, .height = 60 },
        (try desktop.scene(second)).geometry,
    );
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: expired transaction publishes latest target and ignores late readiness" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(&shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const first_serial = desktop.slots[try desktop.resolveIndex(first)].expected_serial.?;
    const second_serial = desktop.slots[try desktop.resolveIndex(second)].expected_serial.?;
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = first_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.transactionPending());
    try std.testing.expect(desktop.expireTransaction());
    try std.testing.expect(!desktop.transactionPending());
    try std.testing.expect(desktop.takeSceneChanged());
    try std.testing.expectEqual(@as(i32, 50), (try desktop.scene(first)).geometry.width);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.takeSceneChanged());
}

test "desktop: focus history and tiled-floating transitions are deterministic" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 8);
    try settleDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try desktop.focusToplevel(first);
    try desktop.setFloating(first, true);
    try desktop.setFloatingGeometry(first, .{ .x = 5, .y = 6, .width = 30, .height = 20 });
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(first, desktop.focused().?);
    try std.testing.expectEqual(geometry.Rect{ .x = 5, .y = 6, .width = 30, .height = 20 }, (try desktop.scene(first)).geometry);

    try desktop.focusNext();
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try std.testing.expectEqual(second, desktop.focused().?);
    try desktop.toggleFocusedFullscreen();
    try desktop.toggleFocusedMaximized();
    try desktop.toggleFocusedFloating();
    const second_index = try desktop.resolveIndex(second);
    try std.testing.expect(desktop.slots[second_index].fullscreen);
    try std.testing.expect(desktop.slots[second_index].maximized);
    try std.testing.expectEqual(TestDesktop.Mode.floating, desktop.slots[second_index].mode);
    try desktop.focusToplevel(first);

    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(second, desktop.focused().?);
    try std.testing.expectError(error.StaleToplevel, desktop.scene(first));
}

test "desktop: interactive resize preserves geometry and publishes resizing state" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    try settleDesktop(&desktop, &shell);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const before = (try desktop.scene(id)).geometry;
    shell.push(.{ .resize_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .edge = .bottom_right,
    } });
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    const request = desktop.peekInteractiveRequest().?;
    const interactive = (try desktop.beginInteractive(request)).?;
    desktop.dropInteractiveRequest();
    try std.testing.expectEqual(before, interactive.rect);
    try std.testing.expect(desktop.slots[id.index].mode == .floating);
    try std.testing.expect(desktop.slots[id.index].last_configure.states.resizing);
    try desktop.updateInteractive(id, .{ .x = before.x, .y = before.y, .width = 80, .height = 40 });
    try std.testing.expectEqual(@as(i32, 80), desktop.slots[id.index].floating.width);
    try desktop.endInteractive(id);
    try std.testing.expect(!desktop.slots[id.index].last_configure.states.resizing);
}

test "desktop: keyboard tile movement reorders layout transactionally" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);
    try settleDesktop(&desktop, &shell);

    const focused = desktop.focused().?;
    try std.testing.expectEqual(@as(u32, 2), focused.index);
    try desktop.focusPrevious();
    try std.testing.expectEqual(@as(u32, 1), desktop.focused().?.index);
    while (desktop.peekCommand() != null) desktop.dropCommand();

    try desktop.moveFocusedTile(.previous);
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 2 }, desktop.tile_order[0..3]);
    while (desktop.peekCommand() != null) desktop.dropCommand();
    try desktop.moveFocusedTile(.next);
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, desktop.tile_order[0..3]);
}

test "desktop: queued destroys preserve exact generations in order" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    desktop.slots[0].header.generation = 7;
    desktop.slots[1].header.generation = 11;
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);

    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    shell.push(.{ .toplevel_destroyed = .{ .index = 1, .generation = 1 } });

    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 8));
    try std.testing.expectEqual(
        TestDesktop.ToplevelId{ .index = 0, .generation = 7 },
        desktop.takeDestroyed().?,
    );
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 8));
    try std.testing.expectEqual(
        TestDesktop.ToplevelId{ .index = 1, .generation = 11 },
        desktop.takeDestroyed().?,
    );
}

test "desktop: toplevel and command storage grow transactionally" {
    var desktop = try initTestDesktop(3);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const first = desktop.focused().?;
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const second = desktop.focused().?;
    shell.push(created(2));
    shell.push(created(3));
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 2));
    try std.testing.expect(!std.meta.eql(first, desktop.focused().?));
    try std.testing.expect(!std.meta.eql(second, desktop.focused().?));
    try std.testing.expect(desktop.slots.len > 3);
    try std.testing.expect(desktop.commands.len > 3);
}

test "desktop: shell outbound backpressure retains configure ownership" {
    var desktop = try initTestDesktop(3);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    shell.reject_configure = true;
    try std.testing.expectError(error.Exhausted, desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    shell.reject_configure = false;
    try std.testing.expectEqual(@as(?u32, 41), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try std.testing.expect(shell.configured.?.states.activated);
}

test "desktop: stale identity is rejected and exhausted generations retire" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    desktop.slots[0].header.generation = std.math.maxInt(u32);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const exhausted = desktop.focused().?;
    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.slots[0].header.retired);
    try std.testing.expectError(error.StaleToplevel, desktop.scene(exhausted));
    try std.testing.expectEqual(@as(u32, 1), desktop.free);
}

test "desktop: initial toplevel capacity grows without retaining the shell event" {
    var desktop = try TestDesktop.init(std.testing.allocator, .{
        .toplevel_capacity = 1,
        .command_capacity = 4,
        .metadata_bytes = 8,
    }, .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    try std.testing.expect(desktop.pending_event == null);
    try std.testing.expectEqual(@as(usize, 2), desktop.live);
}

test "desktop: minimized and fullscreen requests update visibility and states" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);
    while (desktop.peekCommand() != null) desktop.dropCommand();
    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try desktop.focusToplevel(first);
    try settleDesktop(&desktop, &shell);

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .state = .fullscreen,
        .enabled = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const fullscreen = try desktop.scene(first);
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 }, fullscreen.geometry);
    try std.testing.expect(fullscreen.stacking > (try desktop.scene(second)).stacking);
    while (desktop.peekCommand() != null) desktop.dropCommand();

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .state = .minimized,
        .enabled = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    try std.testing.expect(!(try desktop.scene(first)).visible);
    try std.testing.expectEqual(second, desktop.focused().?);
}
