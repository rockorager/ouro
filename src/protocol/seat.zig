//! Growable wl_seat owner and protocol-neutral focus boundary.
//!
//! Physical device identities and events remain owned by the input backend.
//! This adapter aggregates capabilities and pressed state, owns all seat child
//! resources, validates client/surface generations at every delivery, and
//! keeps outbound operations until Wayring TX storage can accept them.

const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const input_platform = @import("../backend/input/platform.zig");
const surface_state = @import("../surface.zig");
const slot_pool = @import("slot_pool.zig");

const linux = std.os.linux;
const objects = wayring.objects;
const none = std.math.maxInt(u32);
const code_count = 0x300;
const state_words = code_count / 64;
const key_left_ctrl = 29;
const key_left_shift = 42;
const key_right_shift = 54;
const key_left_alt = 56;
const key_caps_lock = 58;
const key_num_lock = 69;
const key_right_ctrl = 97;
const key_right_alt = 100;
const key_left_meta = 125;
const key_right_meta = 126;
const mod_shift: u32 = 1 << 0;
const mod_lock: u32 = 1 << 1;
const mod_control: u32 = 1 << 2;
const mod_alt: u32 = 1 << 3;
const mod_num: u32 = 1 << 4;
const mod_meta: u32 = 1 << 6;
const mod_alt_gr: u32 = 1 << 7;
const cursor_role_id = surface_state.cursor_role_id;
const input_keymap = @import("../input/keymap.zig");

pub const SeatClientId = packed struct {
    slot: u32,
    generation: u32,
};

/// XKB text intentionally owns no layout policy beyond the conventional evdev
/// rules. R20 may replace it from compositor configuration at startup.
pub const default_keymap = input_keymap.default_text;

pub const Config = struct {
    seat_capacity: usize,
    pointer_capacity: usize,
    keyboard_capacity: usize,
    touch_capacity: usize = 8,
    touch_contact_capacity: usize = 32,
    device_capacity: usize,
    outbound_capacity: usize,
    event_capacity: usize,
    name: []const u8 = "seat0",
    keymap: []const u8,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    global_version: u32 = 10,
    initial_serial: u32 = 1,

    fn validate(config: Config) !void {
        inline for (.{
            config.seat_capacity,
            config.pointer_capacity,
            config.keyboard_capacity,
            config.touch_capacity,
            config.touch_contact_capacity,
            config.device_capacity,
            config.outbound_capacity,
            config.event_capacity,
        }) |capacity| if (capacity == 0 or capacity >= none) return error.InvalidConfig;
        if (config.name.len == 0 or std.mem.indexOfScalar(u8, config.name, 0) != null or
            config.keymap.len == 0 or config.keymap.len >= std.math.maxInt(u32) or
            config.initial_serial == 0 or config.repeat_rate < 0 or config.repeat_delay < 0)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Seat = protocol.wl_seat;
        const Pointer = protocol.wl_pointer;
        const Keyboard = protocol.wl_keyboard;
        const Touch = protocol.wl_touch;

        pub const SurfaceId = CoreSurface.SurfaceId;
        pub const ClientId = SeatClientId;
        pub const FocusTarget = struct {
            client: ClientId,
            surface: SurfaceId,
        };
        pub const PointerState = struct {
            focus: ?FocusTarget,
            point: Point,
        };
        pub const Point = struct { x: i32, y: i32 };
        const Axis = enum { vertical, horizontal };
        pub const ModifierState = struct {
            depressed: u32 = 0,
            latched: u32 = 0,
            locked: u32 = 0,
            group: u32 = 0,
        };
        pub const GrabState = union(enum) {
            idle,
            active: FocusTarget,
            cancelled: FocusTarget,
        };
        pub const CursorRequest = struct {
            client: ClientId,
            serial: u32,
            surface: ?SurfaceId,
            hotspot: Point,
        };
        pub const Event = union(enum) {
            cursor_requested: CursorRequest,
            pointer_grab_cancelled: FocusTarget,
        };
        pub const PointerId = struct { index: u32, generation: u32 };
        pub const TouchId = PointerId;
        pub const TouchContactId = struct { device: input.DeviceId, id: i32 };

        const SeatSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            last_implicit_grab_serial: u32 = 0,
            last_user_action_serial: u32 = 0,
        };
        const PointerSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            seat_index: u32 = none,
            seat_generation: u32 = 0,
            client: ClientId = undefined,
            capability_generation: u32 = 1,
            last_serial: u32 = 0,
            enter_serial: u32 = 0,
        };
        const KeyboardSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            seat_index: u32 = none,
            seat_generation: u32 = 0,
            client: ClientId = undefined,
            capability_generation: u32 = 1,
        };
        const TouchSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            seat_index: u32 = none,
            seat_generation: u32 = 0,
            client: ClientId = undefined,
            resource_generation: u64 = 0,
            capability_generation: u32 = 0,
            pending_frame_events: usize = 0,
        };
        const ContactSlot = struct {
            active: bool = false,
            contact: TouchContactId = undefined,
            target: ?FocusTarget = null,
            max_resource_generation: u64 = 0,
            offset: Point = .{ .x = 0, .y = 0 },
        };
        const DeviceSlot = struct {
            active: bool = false,
            id: input.DeviceId = undefined,
            capabilities: @import("../backend/input/platform.zig").Capabilities = .{},
            keys: [state_words]u64 = [_]u64{0} ** state_words,
            buttons: [state_words]u64 = [_]u64{0} ** state_words,
        };

        const Outbound = union(enum) {
            seat_capabilities: struct { seat: Id, value: u32 },
            seat_name: Id,
            pointer_enter: struct { pointer: Id, serial: u32, target: FocusTarget, point: Point },
            pointer_leave: struct { pointer: Id, serial: u32, target: FocusTarget },
            pointer_motion: struct { pointer: Id, target: FocusTarget, time: u32, point: Point },
            pointer_button: struct { pointer: Id, target: ?FocusTarget, serial: u32, time: u32, button: u32, pressed: bool },
            pointer_axis_source: struct { pointer: Id, target: FocusTarget, source: input_platform.AxisSource },
            pointer_axis: struct { pointer: Id, target: FocusTarget, time: u32, axis: Axis, value: i32 },
            pointer_axis_stop: struct { pointer: Id, target: FocusTarget, time: u32, axis: Axis },
            pointer_axis_value120: struct { pointer: Id, target: FocusTarget, axis: Axis, value120: i32 },
            pointer_frame: struct { pointer: Id, target: ?FocusTarget },
            keyboard_keymap: Id,
            keyboard_repeat: Id,
            keyboard_enter: struct { keyboard: Id, serial: u32, target: FocusTarget, pressed_keys: [state_words]u64 },
            keyboard_leave: struct { keyboard: Id, serial: u32, target: FocusTarget },
            keyboard_key: struct { keyboard: Id, serial: u32, target: FocusTarget, time: u32, key: u32, pressed: bool },
            keyboard_modifiers: struct { keyboard: Id, serial: u32, target: FocusTarget, state: ModifierState },
            touch_down: struct { touch: Id, serial: u32, time: u32, id: i32, target: FocusTarget, point: Point },
            touch_up: struct { touch: Id, serial: u32, time: u32, id: i32 },
            touch_motion: struct { touch: Id, time: u32, id: i32, point: Point },
            touch_frame: struct { touch: Id, client: ClientId },
            touch_cancel: struct { touch: Id, client: ClientId },
        };
        const Id = PointerId;
        const OutboundSlot = struct {
            active: bool = false,
            sequence: u64 = 0,
            client: ClientId = undefined,
            value: Outbound = undefined,
        };

        pub const GrabbedKeyboardKey = struct {
            serial: u32,
            time: u32,
            key: u32,
            state: u32,
            modifiers: ?struct {
                serial: u32,
                state: ModifierState,
            },
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        name: []u8,
        keymap_fd: linux.fd_t,
        keymap_size: u32,
        repeat_rate: i32,
        repeat_delay: i32,
        next_serial: u32,
        next_sequence: u64 = 1,
        seats: slot_pool.Pool(SeatSlot),
        pointers: slot_pool.Pool(PointerSlot),
        keyboards: slot_pool.Pool(KeyboardSlot),
        touches: slot_pool.Pool(TouchSlot),
        contacts: []ContactSlot,
        devices: []DeviceSlot,
        outbound: []OutboundSlot,
        outbound_len: usize = 0,
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        pointer_devices: usize = 0,
        keyboard_devices: usize = 0,
        touch_devices: usize = 0,
        pointer_capability_generation: u32 = 1,
        keyboard_capability_generation: u32 = 1,
        touch_capability_generation: u32 = 1,
        next_touch_resource_generation: u64 = 1,
        pressed_keys: [state_words]u64 = [_]u64{0} ** state_words,
        pressed_buttons: [state_words]u64 = [_]u64{0} ** state_words,
        pointer_focus: ?FocusTarget = null,
        pointer_delivery: ?FocusTarget = null,
        pointer_point: Point = .{ .x = 0, .y = 0 },
        keyboard_focus: ?FocusTarget = null,
        modifiers: ModifierState = .{},
        caps_lock_active: bool = false,
        num_lock_active: bool = false,
        pointer_grab: GrabState = .idle,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            try config.validate();
            try Seat.info.validateVersion(config.global_version);
            var seats = try slot_pool.Pool(SeatSlot).init(allocator, config.seat_capacity);
            errdefer seats.deinit();
            var pointers = try slot_pool.Pool(PointerSlot).init(allocator, config.pointer_capacity);
            errdefer pointers.deinit();
            var keyboards = try slot_pool.Pool(KeyboardSlot).init(allocator, config.keyboard_capacity);
            errdefer keyboards.deinit();
            var touches = try slot_pool.Pool(TouchSlot).init(allocator, config.touch_capacity);
            errdefer touches.deinit();
            const contacts = try allocator.alloc(ContactSlot, config.touch_contact_capacity);
            errdefer allocator.free(contacts);
            const devices = try allocator.alloc(DeviceSlot, config.device_capacity);
            errdefer allocator.free(devices);
            const outbound = try allocator.alloc(OutboundSlot, config.outbound_capacity);
            errdefer allocator.free(outbound);
            const event_slots = try std.math.add(usize, config.event_capacity, 1);
            const events = try allocator.alloc(Event, event_slots);
            errdefer allocator.free(events);
            const name = try allocator.dupe(u8, config.name);
            errdefer allocator.free(name);
            const keymap = try createKeymap(config.keymap);
            errdefer _ = linux.close(keymap.fd);
            @memset(devices, .{});
            @memset(outbound, .{});
            @memset(contacts, .{});
            return .{
                .allocator = allocator,
                .core = core,
                .global_version = config.global_version,
                .name = name,
                .keymap_fd = keymap.fd,
                .keymap_size = keymap.size,
                .repeat_rate = config.repeat_rate,
                .repeat_delay = config.repeat_delay,
                .next_serial = config.initial_serial,
                .seats = seats,
                .pointers = pointers,
                .keyboards = keyboards,
                .touches = touches,
                .contacts = contacts,
                .devices = devices,
                .outbound = outbound,
                .events = events,
            };
        }

        pub fn deinit(adapter: *Self) void {
            _ = linux.close(adapter.keymap_fd);
            adapter.allocator.free(adapter.name);
            adapter.allocator.free(adapter.events);
            adapter.allocator.free(adapter.outbound);
            adapter.allocator.free(adapter.devices);
            adapter.allocator.free(adapter.contacts);
            adapter.touches.deinit();
            adapter.keyboards.deinit();
            adapter.pointers.deinit();
            adapter.seats.deinit();
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.global != null) return error.AlreadyInstalled;
            const first_install = adapter.runtime == null;
            if (!first_install and adapter.runtime.? != runtime) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer if (first_install) {
                adapter.runtime = null;
            };
            const global = try runtime.addGlobalWithBinder(
                &Seat.info,
                adapter.global_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        /// Withdraws this seat global while preserving already-bound seat and
        /// child resources. A later install may republish the same isolated
        /// seat after those resources and its virtual devices have retired.
        pub fn removeGlobal(adapter: *Self) !void {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            const global = adapter.global orelse return error.NotInstalled;
            try runtime.removeGlobal(global);
            adapter.global = null;
        }

        pub fn globalName(adapter: *const Self) ?u32 {
            return if (adapter.global) |global| global.id else null;
        }

        pub fn resourceCount(adapter: *const Self) usize {
            var count: usize = 0;
            for (adapter.seats.entries.items) |slot| count += @intFromBool(slot.header.active);
            for (adapter.pointers.entries.items) |slot| count += @intFromBool(slot.header.active);
            for (adapter.keyboards.entries.items) |slot| count += @intFromBool(slot.header.active);
            for (adapter.touches.entries.items) |slot| count += @intFromBool(slot.header.active);
            return count;
        }

        pub fn deviceCount(adapter: *const Self) usize {
            var count: usize = 0;
            for (adapter.devices) |slot| count += @intFromBool(slot.active);
            return count;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = adapter.seats.acquire() catch
                return error.OutOfMemory;
            slot.resource = binding.resource;
            slot.peer = binding.peer;
            const id = adapter.seatId(slot);
            const client = clientId(binding.peer);
            adapter.ensureOutbound(2) catch {
                adapter.seats.release(adapter.seats.entries.items[id.index]);
                return error.OutOfMemory;
            };
            adapter.enqueue(client, .{ .seat_capabilities = .{
                .seat = id,
                .value = adapter.capabilityBits(),
            } }) catch unreachable;
            adapter.enqueue(client, .{ .seat_name = id }) catch unreachable;
            return slot;
        }

        pub fn request(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return adapter.requestOn(actor, server_objects, target, message, fds);
        }

        pub fn requestOn(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const object = target.object;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (object.interface == &Seat.info) {
                const slot = adapter.seats.fromContext(object.context) orelse return null;
                if (!std.meta.eql(slot.resource, handle)) return null;
                return try adapter.seatRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Pointer.info) {
                const slot = adapter.pointers.fromContext(object.context) orelse return null;
                if (!std.meta.eql(slot.resource, handle)) return null;
                return try adapter.pointerRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Keyboard.info) {
                const slot = adapter.keyboards.fromContext(object.context) orelse return null;
                if (!std.meta.eql(slot.resource, handle)) return null;
                return try adapter.keyboardRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Touch.info) {
                const slot = adapter.touches.fromContext(object.context) orelse return null;
                if (!std.meta.eql(slot.resource, handle)) return null;
                return try adapter.touchRequest(actor, server_objects, slot, message, fds);
            }
            return null;
        }

        fn seatRequest(adapter: *Self, actor: *wayring.connection.Actor, server_objects: anytype, seat: *SeatSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Seat, server_objects, message, fds);
            switch (decoded.value) {
                .get_pointer => |payload| {
                    if (adapter.pointer_devices == 0)
                        return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "pointer capability unavailable");
                    const slot = adapter.pointers.acquire() catch
                        return try adapter.noMemory(actor);
                    slot.seat_index = adapter.seatIndex(seat);
                    slot.seat_generation = seat.header.generation;
                    slot.client = clientId(seat.peer);
                    slot.capability_generation = adapter.pointer_capability_generation;
                    const focused = adapter.pointer_delivery != null and
                        sameClient(clientId(seat.peer), adapter.pointer_delivery.?.client);
                    if (focused) adapter.ensureOutbound(1) catch {
                        adapter.pointers.release(slot);
                        return try adapter.noMemory(actor);
                    };
                    const admitted = Seat.admit_get_pointer(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                        adapter.pointers.release(slot);
                        return try adapter.failure(actor, decoded.handle.id, err);
                    };
                    slot.resource = admitted.id;
                    if (adapter.pointer_delivery) |focus| if (focused) {
                        const serial = adapter.issueSerial();
                        try adapter.enqueue(clientId(seat.peer), .{ .pointer_enter = .{
                            .pointer = adapter.pointerId(slot),
                            .serial = serial,
                            .target = focus,
                            .point = adapter.pointer_point,
                        } });
                        slot.last_serial = serial;
                        slot.enter_serial = serial;
                    };
                },
                .get_keyboard => |payload| {
                    if (adapter.keyboard_devices == 0)
                        return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "keyboard capability unavailable");
                    const slot = adapter.keyboards.acquire() catch
                        return try adapter.noMemory(actor);
                    slot.seat_index = adapter.seatIndex(seat);
                    slot.seat_generation = seat.header.generation;
                    slot.client = clientId(seat.peer);
                    slot.capability_generation = adapter.keyboard_capability_generation;
                    const extra: usize = if (adapter.keyboard_focus != null) 4 else 2;
                    adapter.ensureOutbound(extra) catch {
                        adapter.keyboards.release(slot);
                        return try adapter.noMemory(actor);
                    };
                    const admitted = Seat.admit_get_keyboard(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                        adapter.keyboards.release(slot);
                        return try adapter.failure(actor, decoded.handle.id, err);
                    };
                    slot.resource = admitted.id;
                    const client = clientId(seat.peer);
                    adapter.enqueue(client, .{ .keyboard_keymap = adapter.keyboardId(slot) }) catch unreachable;
                    adapter.enqueue(client, .{ .keyboard_repeat = adapter.keyboardId(slot) }) catch unreachable;
                    if (adapter.keyboard_focus) |focus| if (sameClient(client, focus.client)) {
                        const serial = adapter.issueSerial();
                        adapter.enqueue(client, .{ .keyboard_enter = .{
                            .keyboard = adapter.keyboardId(slot),
                            .serial = serial,
                            .target = focus,
                            .pressed_keys = adapter.pressed_keys,
                        } }) catch unreachable;
                        adapter.enqueue(client, .{ .keyboard_modifiers = .{
                            .keyboard = adapter.keyboardId(slot),
                            .serial = serial,
                            .target = focus,
                            .state = adapter.modifiers,
                        } }) catch unreachable;
                    };
                },
                .get_touch => |payload| {
                    if (adapter.touch_devices == 0)
                        return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "touch capability unavailable");
                    const slot = adapter.touches.acquire() catch return try adapter.noMemory(actor);
                    slot.seat_index = adapter.seatIndex(seat);
                    slot.seat_generation = seat.header.generation;
                    slot.client = clientId(seat.peer);
                    slot.resource_generation = adapter.next_touch_resource_generation;
                    adapter.next_touch_resource_generation +%= 1;
                    if (adapter.next_touch_resource_generation == 0) adapter.next_touch_resource_generation = 1;
                    slot.capability_generation = adapter.touch_capability_generation;
                    slot.pending_frame_events = 0;
                    const admitted = Seat.admit_get_touch(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                        adapter.touches.release(slot);
                        return try adapter.failure(actor, decoded.handle.id, err);
                    };
                    slot.resource = admitted.id;
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn pointerRequest(adapter: *Self, actor: *wayring.connection.Actor, server_objects: anytype, pointer: *PointerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Pointer, server_objects, message, fds);
            switch (decoded.value) {
                .set_cursor => |payload| set_cursor: {
                    if (!adapter.pointerActive(pointer)) break :set_cursor;
                    const client = pointer.client;
                    if (payload.serial == 0 or payload.serial != pointer.enter_serial or
                        adapter.pointer_delivery == null or
                        !sameClient(client, adapter.pointer_delivery.?.client))
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid pointer serial");
                    adapter.requestCursorOn(
                        server_objects,
                        pointer.client,
                        payload.serial,
                        payload.surface,
                        .{ .x = payload.hotspot_x, .y = payload.hotspot_y },
                        0,
                    ) catch |err| return switch (err) {
                        error.StaleSurface => try adapter.protocolError(actor, decoded.handle.id, 0, "stale cursor surface"),
                        error.InvalidSurface => try adapter.protocolError(actor, decoded.handle.id, 0, "invalid cursor surface"),
                        error.SurfaceRole => try adapter.protocolError(actor, decoded.handle.id, Pointer.@"error".role.value, "cursor surface already has another role"),
                        error.Exhausted => try adapter.noMemory(actor),
                    };
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn keyboardRequest(_: *Self, actor: *wayring.connection.Actor, server_objects: anytype, _: *KeyboardSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Keyboard, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn touchRequest(_: *Self, actor: *wayring.connection.Actor, server_objects: anytype, _: *TouchSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Touch, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Seat.info) {
                const slot = adapter.seats.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseSeat(adapter.seatIndex(slot));
                return true;
            }
            if (object.interface == &Pointer.info) {
                const slot = adapter.pointers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.dropOutboundResource(.pointer, adapter.pointerIndex(slot), slot.header.generation);
                adapter.pointers.release(slot);
                return true;
            }
            if (object.interface == &Keyboard.info) {
                const slot = adapter.keyboards.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.dropOutboundResource(.keyboard, adapter.keyboardIndex(slot), slot.header.generation);
                adapter.keyboards.release(slot);
                return true;
            }
            if (object.interface == &Touch.info) {
                const slot = adapter.touches.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.dropOutboundResource(.touch, adapter.touchIndex(slot), slot.header.generation);
                const owner = slot.client;
                adapter.touches.release(slot);
                if (adapter.touchResourceCount(owner) == 0)
                    for (adapter.contacts) |*contact| if (contact.active and contact.target != null and sameClient(contact.target.?.client, owner)) {
                        contact.target = null;
                    };
                return true;
            }
            if (std.mem.eql(u8, object.interface.name, "wl_surface")) {
                const id = adapter.core.surfaceIdObject(handle, &object) catch return false;
                adapter.surfaceRemoved(id);
            }
            return false;
        }

        pub fn makeTarget(adapter: *Self, peer: wayring.io_uring.Peer, surface: SurfaceId) !FocusTarget {
            _ = try adapter.core.getSurfaceById(surface);
            return .{ .client = clientId(peer), .surface = surface };
        }

        pub fn targetBelongsTo(
            adapter: *const Self,
            target: FocusTarget,
            peer: wayring.io_uring.Peer,
        ) bool {
            _ = adapter;
            return sameClient(target.client, clientId(peer));
        }

        pub fn surfaceHandleOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: FocusTarget,
        ) !objects.Handle {
            if (!adapter.targetBelongsTo(target, peer)) return error.ForeignSurface;
            return adapter.surfaceObject(server_objects, target);
        }

        pub fn validateSeatOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
        ) bool {
            return adapter.seatByObject(server_objects, peer, seat_object) != null;
        }

        pub fn pointerIdOn(adapter: *Self, server_objects: anytype, object_id: u32) !PointerId {
            const handle = server_objects.namespace.lookupHandle(object_id) orelse
                return error.StalePointer;
            const object = server_objects.namespace.resolve(handle) orelse
                return error.StalePointer;
            if (object.interface != &Pointer.info) return error.StalePointer;
            const slot = adapter.pointers.fromContext(object.context) orelse
                return error.StalePointer;
            if (!std.meta.eql(slot.resource, handle)) return error.StalePointer;
            return adapter.pointerId(slot);
        }

        pub fn pointerFocused(adapter: *Self, id: PointerId) bool {
            const pointer = adapter.resolvePointer(id) catch return false;
            if (!adapter.pointerActive(pointer)) return false;
            const focus = adapter.pointer_delivery orelse return false;
            return sameClient(pointer.client, focus.client);
        }

        /// Cursor-shape requests use the same exact enter serial and focused
        /// pointer ownership as wl_pointer.set_cursor, but invalid requests are
        /// ignored by that extension rather than becoming protocol errors.
        pub fn validateCursorShapeOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            pointer_object: u32,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const id = adapter.pointerIdOn(server_objects, pointer_object) catch return false;
            const pointer = adapter.resolvePointer(id) catch return false;
            return sameClient(pointer.client, clientId(peer)) and
                pointer.enter_serial == serial and adapter.pointerFocused(id);
        }

        pub fn validatePointerWarpOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            pointer_object: u32,
            surface: SurfaceId,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const id = adapter.pointerIdOn(server_objects, pointer_object) catch return false;
            const pointer = adapter.resolvePointer(id) catch return false;
            if (!adapter.pointerActive(pointer)) return false;
            const delivery = adapter.deliveryTarget() orelse return false;
            return sameClient(pointer.client, clientId(peer)) and
                pointer.enter_serial == serial and
                sameClient(pointer.client, delivery.client) and
                std.meta.eql(delivery.surface, surface);
        }

        pub fn applyPointerWarp(adapter: *Self, surface: SurfaceId, point: Point) bool {
            const delivery = adapter.deliveryTarget() orelse return false;
            if (!std.meta.eql(delivery.surface, surface)) return false;
            adapter.pointer_point = point;
            adapter.pointer_focus = delivery;
            return true;
        }

        pub fn requestTabletCursorOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            serial: u32,
            surface: ?u32,
            hotspot: Point,
            owner: u128,
        ) !void {
            try adapter.requestCursorOn(server_objects, clientId(peer), serial, surface, hotspot, owner);
        }

        fn requestCursorOn(
            adapter: *Self,
            server_objects: anytype,
            client: ClientId,
            serial: u32,
            surface: ?u32,
            hotspot: Point,
            owner: u128,
        ) !void {
            var surface_id: ?SurfaceId = null;
            if (surface) |object_id| {
                const handle = server_objects.namespace.lookupHandle(object_id) orelse return error.StaleSurface;
                const object = server_objects.namespace.resolve(handle) orelse return error.StaleSurface;
                const cursor = adapter.core.getSurfaceObject(handle, object) catch return error.InvalidSurface;
                cursor.role.assignOwned(cursor_role_id, owner, false) catch return error.SurfaceRole;
                surface_id = adapter.core.surfaceIdObject(handle, object) catch return error.InvalidSurface;
            }
            adapter.publish(.{ .cursor_requested = .{
                .client = client,
                .serial = serial,
                .surface = surface_id,
                .hotspot = hotspot,
            } }) catch return error.Exhausted;
        }

        pub fn pointerState(adapter: *const Self) PointerState {
            return .{ .focus = adapter.pointer_focus, .point = adapter.pointer_point };
        }

        pub fn nextSerial(adapter: *Self) u32 {
            return adapter.issueSerial();
        }

        pub fn keyboardSnapshot(adapter: *const Self) struct {
            keymap_size: u32,
            repeat_rate: i32,
            repeat_delay: i32,
            modifiers: ModifierState,
        } {
            return .{
                .keymap_size = adapter.keymap_size,
                .repeat_rate = adapter.repeat_rate,
                .repeat_delay = adapter.repeat_delay,
                .modifiers = adapter.modifiers,
            };
        }

        /// The caller owns the returned descriptor.
        pub fn duplicateKeymap(adapter: *const Self) !linux.fd_t {
            const duplicated = linux.dup(adapter.keymap_fd);
            if (linux.errno(duplicated) != .SUCCESS) return error.KeymapDuplicateFailed;
            return @intCast(duplicated);
        }

        /// Replaces the seat keymap and transfers ownership of `fd` only after
        /// every existing wl_keyboard has capacity for the update.
        pub fn setKeymapOwned(adapter: *Self, fd: linux.fd_t, size: u32) !void {
            if (size == 0) return error.InvalidKeymap;
            var count: usize = 0;
            for (adapter.keyboards.entries.items, 0..) |slot, index| {
                if (!slot.header.active) continue;
                const id: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                var has_keymap = false;
                var has_repeat = false;
                for (adapter.outbound) |out| if (out.active) switch (out.value) {
                    .keyboard_keymap => |value| has_keymap = has_keymap or std.meta.eql(value, id),
                    .keyboard_repeat => |value| has_repeat = has_repeat or std.meta.eql(value, id),
                    else => {},
                };
                count += @as(usize, @intFromBool(!has_keymap)) +
                    @as(usize, @intFromBool(!has_repeat));
            }
            try adapter.ensureOutbound(count);
            for (adapter.keyboards.entries.items, 0..) |slot, index| if (slot.header.active) {
                const id: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                var has_keymap = false;
                var has_repeat = false;
                for (adapter.outbound) |out| if (out.active) switch (out.value) {
                    .keyboard_keymap => |value| has_keymap = has_keymap or std.meta.eql(value, id),
                    .keyboard_repeat => |value| has_repeat = has_repeat or std.meta.eql(value, id),
                    else => {},
                };
                if (!has_keymap) adapter.enqueue(slot.client, .{ .keyboard_keymap = id }) catch unreachable;
                if (!has_repeat) adapter.enqueue(slot.client, .{ .keyboard_repeat = id }) catch unreachable;
            };
            const previous = adapter.keymap_fd;
            adapter.keymap_fd = fd;
            adapter.keymap_size = size;
            _ = linux.close(previous);
        }

        pub fn ownsSeat(adapter: *Self, peer: wayring.io_uring.Peer, object_id: u32) bool {
            const runtime = adapter.runtime orelse return false;
            const server_objects = runtime.clients.get(peer) catch return false;
            return adapter.seatByObject(server_objects, peer, object_id) != null;
        }

        pub fn addVirtualKeyboard(adapter: *Self, device: input.DeviceId) !void {
            try adapter.addDevice(device, .{ .keyboard = true });
        }

        pub fn removeVirtualKeyboard(adapter: *Self, device: input.DeviceId) !void {
            try adapter.removeDevice(device);
        }

        /// Virtual input deliberately enters below physical input-method grab
        /// routing so an input method cannot consume its own synthesized keys.
        pub fn virtualKeyboardKey(
            adapter: *Self,
            device: input.DeviceId,
            time_ms: u32,
            key: u32,
            pressed: bool,
        ) !void {
            try adapter.keyboardKey(.{
                .device = device,
                .time_usec = @as(u64, time_ms) * 1000,
                .key = key,
                .pressed = pressed,
            });
        }

        pub fn keyboardTransitionPending(
            adapter: *Self,
            device: input.DeviceId,
            key: u32,
            pressed: bool,
        ) bool {
            if (key >= code_count) return false;
            const slot = adapter.findDevice(device) orelse return false;
            return bitSet(&slot.keys, key) != pressed;
        }

        pub fn virtualModifiers(adapter: *Self, state: ModifierState) !void {
            try adapter.setModifiers(state);
        }

        pub fn restoreDerivedModifiers(adapter: *Self) !void {
            try adapter.setModifiers(adapter.modifierState(adapter.pressed_keys));
        }

        /// Validates an input serial against the exact wl_seat resource named
        /// by an xdg_popup.grab request. Pointer-enter serials intentionally do
        /// not qualify: only a delivered button press establishes this token.
        pub fn validatePopupGrab(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const runtime = adapter.runtime orelse return false;
            const server_objects = runtime.clients.get(peer) catch return false;
            return adapter.validatePopupGrabOn(server_objects, peer, seat_object, serial);
        }

        pub fn validateSelection(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const runtime = adapter.runtime orelse return false;
            const server_objects = runtime.clients.get(peer) catch return false;
            return adapter.validateSelectionOn(server_objects, peer, seat_object, serial);
        }

        pub fn validateActivation(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: SurfaceId,
        ) bool {
            if (serial == 0) return false;
            const runtime = adapter.runtime orelse return false;
            const server_objects = runtime.clients.get(peer) catch return false;
            return adapter.validateActivationOn(server_objects, peer, seat_object, serial, surface);
        }

        fn validateActivationOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: SurfaceId,
        ) bool {
            if (serial == 0) return false;
            const seat = adapter.seatByObject(server_objects, peer, seat_object) orelse return false;
            if (seat.last_user_action_serial != serial) return false;
            const focus = adapter.keyboard_focus orelse return false;
            return sameClient(focus.client, clientId(peer)) and
                std.meta.eql(focus.surface, surface);
        }

        pub fn validateInteractiveGrab(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: SurfaceId,
        ) bool {
            if (serial == 0) return false;
            const runtime = adapter.runtime orelse return false;
            const server_objects = runtime.clients.get(peer) catch return false;
            return adapter.validateInteractiveGrabOn(server_objects, peer, seat_object, serial, surface);
        }

        fn validateInteractiveGrabOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: SurfaceId,
        ) bool {
            if (serial == 0) return false;
            const seat = adapter.seatByObject(server_objects, peer, seat_object) orelse return false;
            if (seat.last_implicit_grab_serial != serial) return false;
            return switch (adapter.pointer_grab) {
                .active => |target| sameClient(target.client, clientId(peer)) and
                    std.meta.eql(target.surface, surface),
                else => false,
            };
        }

        fn validateSelectionOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const seat = adapter.seatByObject(server_objects, peer, seat_object) orelse return false;
            return seat.last_user_action_serial == serial;
        }

        fn validatePopupGrabOn(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            if (serial == 0) return false;
            const handle = server_objects.namespace.lookupHandle(seat_object) orelse return false;
            const object = server_objects.namespace.resolve(handle) orelse return false;
            if (object.interface != &Seat.info) return false;
            const seat = adapter.seats.fromContext(object.context) orelse return false;
            return std.meta.eql(seat.resource, handle) and
                std.meta.eql(seat.peer, peer) and
                seat.last_implicit_grab_serial == serial;
        }

        pub fn setPointerFocus(adapter: *Self, target: ?FocusTarget, point: Point) !void {
            if (target) |value| _ = try adapter.core.getSurfaceById(value.surface);
            adapter.pointer_point = point;
            if (adapter.pointer_grab == .active) {
                adapter.pointer_focus = target;
                return;
            }
            try adapter.transitionPointer(target);
            adapter.pointer_focus = target;
        }

        pub fn setKeyboardFocus(adapter: *Self, target: ?FocusTarget) !void {
            if (target) |value| _ = try adapter.core.getSurfaceById(value.surface);
            if (optionalTargetEqual(adapter.keyboard_focus, target)) return;
            const old = adapter.keyboard_focus;
            const count = adapter.keyboardResourceCount(old) + adapter.keyboardResourceCount(target) * 2;
            try adapter.ensureOutbound(count);
            if (old) |value| {
                const serial = adapter.issueSerial();
                for (adapter.keyboards.entries.items, 0..) |slot, index| if (adapter.keyboardBelongs(slot, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_leave = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                    } }) catch unreachable;
            }
            adapter.keyboard_focus = target;
            if (target) |value| {
                const serial = adapter.issueSerial();
                for (adapter.keyboards.entries.items, 0..) |slot, index| if (adapter.keyboardBelongs(slot, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_enter = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                        .pressed_keys = adapter.pressed_keys,
                    } }) catch unreachable;
                for (adapter.keyboards.entries.items, 0..) |slot, index| if (adapter.keyboardBelongs(slot, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_modifiers = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                        .state = adapter.modifiers,
                    } }) catch unreachable;
            }
        }

        /// Protocol-neutral xkb state publication boundary. R19 does not
        /// choose key bindings or a layout; a later input router computes
        /// these masks from the configured keymap.
        pub fn setModifiers(adapter: *Self, state: ModifierState) !void {
            if (std.meta.eql(adapter.modifiers, state)) return;
            const target = adapter.keyboard_focus;
            try adapter.ensureOutbound(adapter.keyboardResourceCount(target));
            adapter.modifiers = state;
            if (target) |value| {
                const serial = adapter.issueSerial();
                for (adapter.keyboards.entries.items, 0..) |keyboard, index| if (adapter.keyboardBelongs(keyboard, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_modifiers = .{
                        .keyboard = .{ .index = @intCast(index), .generation = keyboard.header.generation },
                        .serial = serial,
                        .target = value,
                        .state = state,
                    } }) catch unreachable;
            }
        }

        /// Consumes one R18 normalized event. No ring submission or policy
        /// mutation occurs here; delivery is queued for `flushOn`.
        pub fn consume(adapter: *Self, event: input.Event) !void {
            switch (event) {
                .device_added => |value| try adapter.addDevice(value.device, value.info.capabilities),
                .device_removed => |id| try adapter.removeDevice(id),
                .pointer_motion => |value| try adapter.pointerMotion(value, null),
                .pointer_button => |value| try adapter.pointerButton(value),
                .pointer_axis => |value| try adapter.pointerAxis(value),
                .keyboard_key => |value| try adapter.keyboardKey(value),
                .swipe_begin,
                .swipe_update,
                .swipe_end,
                .pinch_begin,
                .pinch_update,
                .pinch_end,
                .hold_begin,
                .hold_end,
                .tablet_tool_axis,
                .tablet_tool_proximity,
                .tablet_tool_tip,
                .tablet_tool_button,
                .tablet_pad_button,
                .tablet_pad_ring,
                .tablet_pad_strip,
                .touch_down,
                .touch_up,
                .touch_motion,
                .touch_frame,
                .touch_cancel,
                => {},
            }
        }

        /// Applies a normalized key event to the physical and aggregate seat
        /// state without queueing wl_keyboard events. A null result means the
        /// per-device change did not change the aggregate key state.
        pub fn consumeGrabbedKeyboardKey(adapter: *Self, event: input.Event) !?GrabbedKeyboardKey {
            return switch (event) {
                .keyboard_key => |value| try adapter.keyboardKeyTransition(value, false),
                else => error.NotKeyboardKey,
            };
        }

        /// Queues a normalized pointer motion at an exact compositor-derived
        /// surface-local point. The physical runtime uses this after hit
        /// testing so the protocol owner does not integrate the same delta a
        /// second time.
        pub fn consumePointerMotionAt(
            adapter: *Self,
            event: input.Event,
            point: Point,
        ) !void {
            switch (event) {
                .pointer_motion => |value| try adapter.pointerMotion(value, point),
                else => return error.NotPointerMotion,
            }
        }

        /// Starts a contact on an exact generation-checked surface. The fixed
        /// offset retains its down-time coordinate space for the implicit grab.
        pub fn touchDown(adapter: *Self, contact: TouchContactId, target: FocusTarget, time_ms: u32, point: Point, offset: Point) !?u32 {
            if (adapter.touch_devices == 0) return error.TouchUnavailable;
            _ = try adapter.core.getSurfaceById(target.surface);
            if (adapter.findContact(contact) != null) return error.DuplicateContact;
            var available: ?*ContactSlot = null;
            for (adapter.contacts) |*slot| if (!slot.active) {
                available = slot;
                break;
            };
            const slot = available orelse return error.ContactCapacityExhausted;
            const max_generation = adapter.latestTouchResourceGeneration(target.client);
            const count = adapter.touchResourceCountThrough(target.client, max_generation);
            try adapter.ensureOutbound(count);
            slot.* = .{
                .active = true,
                .contact = contact,
                .target = if (count == 0) null else target,
                .max_resource_generation = max_generation,
                .offset = offset,
            };
            if (count == 0) return null;
            const serial = adapter.issueSerial();
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchParticipates(touch, slot)) {
                adapter.enqueue(target.client, .{ .touch_down = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .serial = serial,
                    .time = time_ms,
                    .id = contact.id,
                    .target = target,
                    .point = point,
                } }) catch unreachable;
                touch.pending_frame_events +|= 1;
            };
            adapter.setUserActionSerial(target.client, serial);
            return serial;
        }

        pub fn touchMotion(adapter: *Self, contact: TouchContactId, time_ms: u32, point: Point) !void {
            const active = adapter.findContact(contact) orelse return error.StaleContact;
            const target = active.target orelse return;
            const count = adapter.touchResourceCountForContact(active);
            try adapter.ensureOutbound(count);
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchParticipates(touch, active)) {
                adapter.enqueue(target.client, .{ .touch_motion = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .time = time_ms,
                    .id = contact.id,
                    .point = point,
                } }) catch unreachable;
                touch.pending_frame_events +|= 1;
            };
        }

        pub const TouchTarget = struct { focus: FocusTarget, offset: Point };

        pub fn touchTarget(adapter: *Self, contact: TouchContactId) ?TouchTarget {
            const active = adapter.findContact(contact) orelse return null;
            return .{ .focus = active.target orelse return null, .offset = active.offset };
        }

        pub fn touchUp(adapter: *Self, contact: TouchContactId, time_ms: u32) !?u32 {
            const active = adapter.findContact(contact) orelse return error.StaleContact;
            const target = active.target orelse {
                active.active = false;
                return null;
            };
            const count = adapter.touchResourceCountForContact(active);
            try adapter.ensureOutbound(count);
            const serial = adapter.issueSerial();
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchParticipates(touch, active)) {
                adapter.enqueue(target.client, .{ .touch_up = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .serial = serial,
                    .time = time_ms,
                    .id = contact.id,
                } }) catch unreachable;
                touch.pending_frame_events +|= 1;
            };
            active.active = false;
            return serial;
        }

        /// Terminates a backend batch. Exactly one frame is queued per live
        /// resource which has an event in the unfinished batch.
        pub fn touchFrame(adapter: *Self) !void {
            var count: usize = 0;
            for (adapter.touches.entries.items) |touch|
                count += @intFromBool(adapter.touchActive(touch) and touch.pending_frame_events != 0);
            try adapter.ensureOutbound(count);
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchActive(touch) and touch.pending_frame_events != 0) {
                adapter.enqueue(touch.client, .{ .touch_frame = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .client = touch.client,
                } }) catch unreachable;
                touch.pending_frame_events = 0;
            };
        }

        pub fn touchCancel(adapter: *Self) !void {
            var count: usize = 0;
            for (adapter.touches.entries.items) |touch|
                count += @intFromBool(adapter.touchResourceHasContact(touch));
            try adapter.ensureOutbound(count);
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchResourceHasContact(touch)) {
                adapter.enqueue(touch.client, .{ .touch_cancel = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .client = touch.client,
                } }) catch unreachable;
                touch.pending_frame_events = 0;
            };
            for (adapter.contacts) |*contact| contact.active = false;
        }

        pub fn touchCancelDevice(adapter: *Self, device: input.DeviceId) !void {
            var count: usize = 0;
            for (adapter.touches.entries.items) |touch|
                count += @intFromBool(adapter.touchResourceHasDeviceContact(touch, device));
            try adapter.ensureOutbound(count);
            for (adapter.touches.entries.items, 0..) |touch, index| if (adapter.touchResourceHasDeviceContact(touch, device)) {
                adapter.enqueue(touch.client, .{ .touch_cancel = .{
                    .touch = .{ .index = @intCast(index), .generation = touch.header.generation },
                    .client = touch.client,
                } }) catch unreachable;
                touch.pending_frame_events = 0;
            };
            for (adapter.contacts) |contact| if (contact.active and std.meta.eql(contact.contact.device, device) and contact.target != null) {
                const client = contact.target.?.client;
                for (adapter.contacts) |*candidate| {
                    if (candidate.active and candidate.target != null and sameClient(candidate.target.?.client, client))
                        candidate.target = null;
                }
            };
            for (adapter.contacts) |*contact| {
                if (contact.active and std.meta.eql(contact.contact.device, device)) contact.active = false;
            }
        }

        fn pointerMotion(
            adapter: *Self,
            value: anytype,
            exact_point: ?Point,
        ) !void {
            _ = try adapter.resolveDevice(value.device);
            const target = adapter.deliveryTarget() orelse return;
            const count = adapter.pointerResourceCount(target.client) * 2;
            try adapter.ensureOutbound(count);
            if (exact_point) |point| {
                adapter.pointer_point = point;
            } else {
                adapter.pointer_point.x +|= fixedFromDelta(value.dx);
                adapter.pointer_point.y +|= fixedFromDelta(value.dy);
            }
            for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, target.client)) {
                const id: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                adapter.enqueue(target.client, .{ .pointer_motion = .{
                    .pointer = id,
                    .target = target,
                    .time = millis(value.time_usec),
                    .point = adapter.pointer_point,
                } }) catch unreachable;
                adapter.enqueue(target.client, .{ .pointer_frame = .{
                    .pointer = id,
                    .target = target,
                } }) catch unreachable;
            };
        }

        pub fn cancelPointerGrab(adapter: *Self) !void {
            const state = adapter.pointer_grab;
            const target = switch (state) {
                .active, .cancelled => |value| value,
                else => return,
            };
            if (state == .active and adapter.event_len >= adapter.events.len - 1)
                return error.Exhausted;
            var button_count: usize = 0;
            for (0..code_count) |code| if (bitSet(&adapter.pressed_buttons, @intCast(code))) {
                button_count += 1;
            };
            const resource_count = adapter.pointerResourceCount(target.client);
            const transition_count = adapter.pointerTransitionCount(adapter.pointer_focus);
            try adapter.ensureOutbound(button_count * resource_count * 2 + transition_count);
            if (state == .active) {
                adapter.pointer_grab = .{ .cancelled = target };
                adapter.publish(.{ .pointer_grab_cancelled = target }) catch unreachable;
            }
            for (0..code_count) |code| if (bitSet(&adapter.pressed_buttons, @intCast(code))) {
                const serial = adapter.issueSerial();
                for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, target.client)) {
                    const id: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                    adapter.enqueue(target.client, .{ .pointer_button = .{
                        .pointer = id,
                        .target = null,
                        .serial = serial,
                        .time = 0,
                        .button = @intCast(code),
                        .pressed = false,
                    } }) catch unreachable;
                    adapter.enqueue(target.client, .{ .pointer_frame = .{
                        .pointer = id,
                        .target = null,
                    } }) catch unreachable;
                };
                adapter.setLastPointerSerial(target.client, serial);
            };
            @memset(&adapter.pressed_buttons, 0);
            for (adapter.devices) |*device| @memset(&device.buttons, 0);
            adapter.pointer_grab = .idle;
            try adapter.transitionPointer(adapter.pointer_focus);
        }

        pub fn grabState(adapter: *const Self) GrabState {
            return adapter.pointer_grab;
        }

        pub fn popEvent(adapter: *Self) ?Event {
            const value = adapter.peekEvent() orelse return null;
            adapter.dropEvent();
            return value;
        }

        pub fn peekEvent(adapter: *const Self) ?Event {
            if (adapter.event_len == 0) return null;
            return adapter.events[adapter.event_head];
        }

        pub fn dropEvent(adapter: *Self) void {
            std.debug.assert(adapter.event_len != 0);
            adapter.event_head = (adapter.event_head + 1) % adapter.events.len;
            adapter.event_len -= 1;
        }

        pub fn pendingOutbound(adapter: *const Self) usize {
            return adapter.outbound_len;
        }

        pub fn pendingOutboundOn(adapter: *Self, server_objects: anytype) bool {
            if (adapter.outbound_len == 0) return false;
            return adapter.oldestOutboundFor(server_objects) != null;
        }

        pub fn flushOn(adapter: *Self, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            if (adapter.outbound_len == 0) return completed;
            while (adapter.oldestOutboundFor(server_objects)) |slot| {
                const done = adapter.emitOutbound(server_objects, queue, slot.value) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.active = false;
                adapter.outbound_len -= 1;
                if (done) completed += 1;
            }
            return completed;
        }

        fn emitOutbound(adapter: *Self, server_objects: anytype, queue: *wayring.tx.Queue, value: Outbound) !bool {
            switch (value) {
                .seat_capabilities => |v| {
                    const slot = adapter.resolveSeat(v.seat.index, v.seat.generation) catch return true;
                    try Seat.encodeEvent(queue, slot.resource.id, .{ .capabilities = .{
                        .capabilities = Seat.capability.fromInt(v.value),
                    } });
                },
                .seat_name => |id| {
                    const slot = adapter.resolveSeat(id.index, id.generation) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 2)
                        try Seat.encodeEvent(queue, slot.resource.id, .{ .name = .{ .name = adapter.name } });
                },
                .pointer_enter => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.resource.id, .{ .enter = .{
                        .serial = v.serial,
                        .surface = surface.id,
                        .surface_x = v.point.x,
                        .surface_y = v.point.y,
                    } });
                },
                .pointer_leave => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.resource.id, .{ .leave = .{
                        .serial = v.serial,
                        .surface = surface.id,
                    } });
                },
                .pointer_motion => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.resource.id, .{ .motion = .{
                        .time = v.time,
                        .surface_x = v.point.x,
                        .surface_y = v.point.y,
                    } });
                },
                .pointer_button => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    if (v.target) |target| _ = adapter.surfaceObject(server_objects, target) catch return true;
                    try Pointer.encodeEvent(queue, slot.resource.id, .{ .button = .{
                        .serial = v.serial,
                        .time = v.time,
                        .button = v.button,
                        .state = if (v.pressed) Pointer.button_state.pressed else Pointer.button_state.released,
                    } });
                },
                .pointer_axis_source => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 5) try Pointer.encodeEvent(queue, slot.resource.id, .{
                        .axis_source = .{ .axis_source = switch (v.source) {
                            .wheel => Pointer.axis_source.wheel,
                            .finger => Pointer.axis_source.finger,
                            .continuous => Pointer.axis_source.continuous,
                        } },
                    });
                },
                .pointer_axis => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.resource.id, .{ .axis = .{
                        .time = v.time,
                        .axis = protocolAxis(v.axis, Pointer),
                        .value = v.value,
                    } });
                },
                .pointer_axis_stop => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 5) try Pointer.encodeEvent(queue, slot.resource.id, .{
                        .axis_stop = .{ .time = v.time, .axis = protocolAxis(v.axis, Pointer) },
                    });
                },
                .pointer_axis_value120 => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 8) {
                        try Pointer.encodeEvent(queue, slot.resource.id, .{ .axis_value120 = .{
                            .axis = protocolAxis(v.axis, Pointer),
                            .value120 = v.value120,
                        } });
                    } else if (object.version >= 5) {
                        const discrete = @divTrunc(v.value120, 120);
                        if (discrete != 0) try Pointer.encodeEvent(queue, slot.resource.id, .{
                            .axis_discrete = .{
                                .axis = protocolAxis(v.axis, Pointer),
                                .discrete = discrete,
                            },
                        });
                    }
                },
                .pointer_frame => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    if (v.target) |target| _ = adapter.surfaceObject(server_objects, target) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 5)
                        try Pointer.encodeEvent(queue, slot.resource.id, .{ .frame = .{} });
                },
                .keyboard_keymap => |id| {
                    const slot = adapter.resolveKeyboard(id) catch return true;
                    const duplicated = linux.dup(adapter.keymap_fd);
                    if (linux.errno(duplicated) != .SUCCESS) return error.KeymapDuplicateFailed;
                    const fd: linux.fd_t = @intCast(duplicated);
                    var owned = true;
                    defer if (owned) {
                        _ = linux.close(fd);
                    };
                    try Keyboard.encodeEvent(queue, slot.resource.id, .{ .keymap = .{
                        .format = Keyboard.keymap_format.xkb_v1,
                        .fd = fd,
                        .size = adapter.keymap_size,
                    } });
                    owned = false;
                },
                .keyboard_repeat => |id| {
                    const slot = adapter.resolveKeyboard(id) catch return true;
                    const object = server_objects.namespace.resolve(slot.resource) orelse return true;
                    if (object.version >= 4) try Keyboard.encodeEvent(queue, slot.resource.id, .{
                        .repeat_info = .{ .rate = adapter.repeat_rate, .delay = adapter.repeat_delay },
                    });
                },
                .keyboard_enter => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    var keys: [code_count * 4]u8 = undefined;
                    const bytes = encodePressedKeys(&v.pressed_keys, &keys);
                    try Keyboard.encodeEvent(queue, slot.resource.id, .{ .enter = .{
                        .serial = v.serial,
                        .surface = surface.id,
                        .keys = bytes,
                    } });
                },
                .keyboard_leave => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.resource.id, .{ .leave = .{
                        .serial = v.serial,
                        .surface = surface.id,
                    } });
                },
                .keyboard_key => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.resource.id, .{ .key = .{
                        .serial = v.serial,
                        .time = v.time,
                        .key = v.key,
                        .state = if (v.pressed) Keyboard.key_state.pressed else Keyboard.key_state.released,
                    } });
                },
                .keyboard_modifiers => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.resource.id, .{ .modifiers = .{
                        .serial = v.serial,
                        .mods_depressed = v.state.depressed,
                        .mods_latched = v.state.latched,
                        .mods_locked = v.state.locked,
                        .group = v.state.group,
                    } });
                },
                .touch_down => |v| {
                    const slot = adapter.resolveTouch(v.touch) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Touch.encodeEvent(queue, slot.resource.id, .{ .down = .{
                        .serial = v.serial,
                        .time = v.time,
                        .surface = surface.id,
                        .id = v.id,
                        .x = v.point.x,
                        .y = v.point.y,
                    } });
                },
                .touch_up => |v| {
                    const slot = adapter.resolveTouch(v.touch) catch return true;
                    try Touch.encodeEvent(queue, slot.resource.id, .{ .up = .{ .serial = v.serial, .time = v.time, .id = v.id } });
                },
                .touch_motion => |v| {
                    const slot = adapter.resolveTouch(v.touch) catch return true;
                    try Touch.encodeEvent(queue, slot.resource.id, .{ .motion = .{ .time = v.time, .id = v.id, .x = v.point.x, .y = v.point.y } });
                },
                .touch_frame => |v| {
                    const slot = adapter.resolveTouch(v.touch) catch return true;
                    try Touch.encodeEvent(queue, slot.resource.id, .{ .frame = .{} });
                },
                .touch_cancel => |v| {
                    const slot = adapter.resolveTouch(v.touch) catch return true;
                    try Touch.encodeEvent(queue, slot.resource.id, .{ .cancel = .{} });
                },
            }
            return true;
        }

        fn addDevice(adapter: *Self, id: input.DeviceId, capabilities: @import("../backend/input/platform.zig").Capabilities) !void {
            if (adapter.findDevice(id) != null) return error.DuplicateDevice;
            var available: ?*DeviceSlot = null;
            for (adapter.devices) |*slot| if (!slot.active) {
                available = slot;
                break;
            };
            if (available == null) {
                const old_len = adapter.devices.len;
                const new_len = std.math.mul(usize, old_len, 2) catch
                    return error.OutOfMemory;
                if (new_len >= none) return error.OutOfMemory;
                adapter.devices = try adapter.allocator.realloc(adapter.devices, new_len);
                @memset(adapter.devices[old_len..], .{});
                available = &adapter.devices[old_len];
            }
            const slot = available.?;
            const old = adapter.capabilityBits();
            const pointer_devices = adapter.pointer_devices + @intFromBool(capabilities.pointer);
            const keyboard_devices = adapter.keyboard_devices + @intFromBool(capabilities.keyboard);
            const touch_devices = adapter.touch_devices + @intFromBool(capabilities.touch);
            const current = capabilityBitsFor(pointer_devices, keyboard_devices, touch_devices);
            try adapter.ensureOutbound(adapter.capabilityPublicationCount(old, current));
            slot.* = .{ .active = true, .id = id, .capabilities = capabilities };
            adapter.pointer_devices = pointer_devices;
            adapter.keyboard_devices = keyboard_devices;
            adapter.touch_devices = touch_devices;
            adapter.enqueueCapabilities(old, current) catch unreachable;
        }

        fn removeDevice(adapter: *Self, id: input.DeviceId) !void {
            const slot = adapter.findDevice(id) orelse return error.StaleDevice;
            const old = adapter.capabilityBits();
            const had_buttons = anySet(&slot.buttons);
            const old_keys = adapter.pressed_keys;
            const keys_after = adapter.aggregateKeysWithout(slot);
            const buttons_after = adapter.aggregateButtonsWithout(slot);
            const cancel_grab = had_buttons and adapter.pointer_grab != .idle;
            const publish_cancellation = adapter.pointer_grab == .active;
            const pointer_devices = adapter.pointer_devices - @intFromBool(slot.capabilities.pointer);
            const keyboard_devices = adapter.keyboard_devices - @intFromBool(slot.capabilities.keyboard);
            const touch_devices = adapter.touch_devices - @intFromBool(slot.capabilities.touch);
            const current = capabilityBitsFor(pointer_devices, keyboard_devices, touch_devices);
            var release_count: usize = 0;
            for (0..code_count) |code| if (bitSet(&old_keys, @intCast(code)) and
                !bitSet(&keys_after, @intCast(code)))
            {
                release_count += 1;
            };
            const keyboard_target = adapter.keyboard_focus;
            const next_modifiers = adapter.modifierState(keys_after);
            var outbound_needed = release_count * adapter.keyboardResourceCount(keyboard_target) +
                adapter.capabilityPublicationCount(old, current);
            if (!std.meta.eql(adapter.modifiers, next_modifiers))
                outbound_needed += adapter.keyboardResourceCount(keyboard_target);
            if (cancel_grab) {
                if (publish_cancellation and adapter.event_len >= adapter.events.len - 1)
                    return error.Exhausted;
                outbound_needed += adapter.pointerCancellationOutbound();
            }
            var touch_cancel_count: usize = 0;
            var has_touch_contacts = false;
            for (adapter.contacts) |contact| if (contact.active and std.meta.eql(contact.contact.device, id)) {
                touch_cancel_count = adapter.touchCancelDeviceCount(id);
                has_touch_contacts = true;
                break;
            };
            outbound_needed += touch_cancel_count;
            try adapter.ensureOutbound(outbound_needed);

            if (cancel_grab) adapter.cancelPointerGrab() catch unreachable;
            if (has_touch_contacts) adapter.touchCancelDevice(id) catch unreachable;
            slot.active = false;
            adapter.pointer_devices = pointer_devices;
            adapter.keyboard_devices = keyboard_devices;
            adapter.touch_devices = touch_devices;
            adapter.pressed_keys = keys_after;
            const modifiers_changed = !std.meta.eql(adapter.modifiers, next_modifiers);
            adapter.modifiers = next_modifiers;
            if (!cancel_grab) adapter.pressed_buttons = buttons_after;
            if (keyboard_target) |target| {
                for (0..code_count) |code| if (bitSet(&old_keys, @intCast(code)) and
                    !bitSet(&keys_after, @intCast(code)))
                {
                    const serial = adapter.issueSerial();
                    for (adapter.keyboards.entries.items, 0..) |keyboard, index| if (adapter.keyboardBelongs(keyboard, target.client))
                        adapter.enqueue(target.client, .{ .keyboard_key = .{
                            .keyboard = .{ .index = @intCast(index), .generation = keyboard.header.generation },
                            .serial = serial,
                            .target = target,
                            .time = 0,
                            .key = @intCast(code),
                            .pressed = false,
                        } }) catch unreachable;
                };
                if (modifiers_changed) {
                    const serial = adapter.issueSerial();
                    for (adapter.keyboards.entries.items, 0..) |keyboard, index| if (adapter.keyboardBelongs(keyboard, target.client))
                        adapter.enqueue(target.client, .{ .keyboard_modifiers = .{
                            .keyboard = .{ .index = @intCast(index), .generation = keyboard.header.generation },
                            .serial = serial,
                            .target = target,
                            .state = next_modifiers,
                        } }) catch unreachable;
                }
            }
            adapter.enqueueCapabilities(old, current) catch unreachable;
            if (slot.capabilities.pointer and pointer_devices == 0)
                advanceCapabilityGeneration(&adapter.pointer_capability_generation);
            if (slot.capabilities.keyboard and keyboard_devices == 0)
                advanceCapabilityGeneration(&adapter.keyboard_capability_generation);
            if (slot.capabilities.touch and touch_devices == 0)
                advanceCapabilityGeneration(&adapter.touch_capability_generation);
        }

        fn pointerButton(adapter: *Self, value: anytype) !void {
            if (value.button >= code_count) return error.InvalidCode;
            const device = try adapter.resolveDevice(value.device);
            const was = bitSet(&device.buttons, value.button);
            if (was == value.pressed) return;
            const aggregate_was = bitSet(&adapter.pressed_buttons, value.button);
            const aggregate_after = value.pressed or adapter.otherDeviceHasButton(device, value.button);
            const aggregate_changed = aggregate_was != aggregate_after;
            const target = if (aggregate_changed) adapter.deliveryTarget() else null;
            var count: usize = if (target) |delivery|
                adapter.pointerResourceCount(delivery.client) * 2
            else
                0;
            const ends_grab = aggregate_changed and !value.pressed and
                adapter.onlyPressedButton(value.button);
            if (ends_grab) count += adapter.pointerTransitionCount(adapter.pointer_focus);
            try adapter.ensureOutbound(count);
            writeBit(&device.buttons, value.button, value.pressed);
            adapter.rebuildPressed();
            if (!aggregate_changed or target == null) return;
            const delivery = target.?;
            const serial = adapter.issueSerial();
            if (value.pressed and adapter.pointer_grab == .idle)
                adapter.pointer_grab = .{ .active = delivery };
            for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, delivery.client)) {
                const id: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                adapter.enqueue(delivery.client, .{ .pointer_button = .{
                    .pointer = id,
                    .target = delivery,
                    .serial = serial,
                    .time = millis(value.time_usec),
                    .button = value.button,
                    .pressed = value.pressed,
                } }) catch unreachable;
                adapter.enqueue(delivery.client, .{ .pointer_frame = .{
                    .pointer = id,
                    .target = delivery,
                } }) catch unreachable;
            };
            adapter.setLastPointerSerial(delivery.client, serial);
            if (value.pressed) adapter.setImplicitGrabSerial(delivery.client, serial);
            if (!value.pressed and !anySet(&adapter.pressed_buttons)) {
                adapter.pointer_grab = .idle;
                try adapter.transitionPointer(adapter.pointer_focus);
            }
        }

        fn pointerAxis(adapter: *Self, value: anytype) !void {
            _ = try adapter.resolveDevice(value.device);
            const target = adapter.deliveryTarget() orelse return;
            const time = millis(value.time_usec);
            var axis_commands: usize = 0;
            inline for (.{ value.vertical, value.horizontal }) |axis| if (axis) |present| {
                if (present.stop or present.value == 0) {
                    if (present.stop or value.source != .wheel) axis_commands += 1;
                } else {
                    axis_commands += 1 + @as(usize, @intFromBool(axisValue120(present.value120) != null));
                }
            };
            if (axis_commands == 0) return;
            const command_count = axis_commands + 2;
            const resource_count = adapter.pointerResourceCount(target.client);
            try adapter.ensureOutbound(command_count * resource_count);
            for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, target.client)) {
                const pointer: Id = .{ .index = @intCast(index), .generation = slot.header.generation };
                adapter.enqueue(target.client, .{ .pointer_axis_source = .{
                    .pointer = pointer,
                    .target = target,
                    .source = value.source,
                } }) catch unreachable;
                inline for (.{
                    .{ Axis.vertical, value.vertical },
                    .{ Axis.horizontal, value.horizontal },
                }) |entry| if (entry[1]) |present| {
                    if (present.stop or present.value == 0) {
                        if (present.stop or value.source != .wheel) adapter.enqueue(target.client, .{
                            .pointer_axis_stop = .{
                                .pointer = pointer,
                                .target = target,
                                .time = time,
                                .axis = entry[0],
                            },
                        }) catch unreachable;
                    } else {
                        if (axisValue120(present.value120)) |value120|
                            adapter.enqueue(target.client, .{ .pointer_axis_value120 = .{
                                .pointer = pointer,
                                .target = target,
                                .axis = entry[0],
                                .value120 = value120,
                            } }) catch unreachable;
                        adapter.enqueue(target.client, .{ .pointer_axis = .{
                            .pointer = pointer,
                            .target = target,
                            .time = time,
                            .axis = entry[0],
                            .value = fixedFromDelta(present.value),
                        } }) catch unreachable;
                    }
                };
                adapter.enqueue(target.client, .{ .pointer_frame = .{
                    .pointer = pointer,
                    .target = target,
                } }) catch unreachable;
            };
        }

        fn keyboardKey(adapter: *Self, value: anytype) !void {
            _ = try adapter.keyboardKeyTransition(value, true);
        }

        fn keyboardKeyTransition(adapter: *Self, value: anytype, deliver: bool) !?GrabbedKeyboardKey {
            if (value.key >= code_count) return error.InvalidCode;
            const device = try adapter.resolveDevice(value.device);
            const was = bitSet(&device.keys, value.key);
            if (was == value.pressed) return null;
            const aggregate_was = bitSet(&adapter.pressed_keys, value.key);
            const aggregate_after = value.pressed or adapter.otherDeviceHasKey(device, value.key);
            const aggregate_changed = aggregate_was != aggregate_after;
            const target = if (aggregate_changed) adapter.keyboard_focus else null;
            var next_keys = adapter.pressed_keys;
            writeBit(&next_keys, value.key, aggregate_after);
            const toggles_lock = aggregate_changed and value.pressed;
            const next_caps_lock = if (toggles_lock and value.key == key_caps_lock)
                !adapter.caps_lock_active
            else
                adapter.caps_lock_active;
            const next_num_lock = if (toggles_lock and value.key == key_num_lock)
                !adapter.num_lock_active
            else
                adapter.num_lock_active;
            const next_modifiers = modifierStateFor(next_keys, next_caps_lock, next_num_lock);
            const modifiers_changed = !std.meta.eql(adapter.modifiers, next_modifiers);
            const resource_count = adapter.keyboardResourceCount(target);
            if (deliver) try adapter.ensureOutbound(resource_count *
                (1 + @as(usize, @intFromBool(modifiers_changed))));
            writeBit(&device.keys, value.key, value.pressed);
            adapter.rebuildPressed();
            adapter.caps_lock_active = next_caps_lock;
            adapter.num_lock_active = next_num_lock;
            adapter.modifiers = next_modifiers;
            if (!aggregate_changed) return null;
            if (!deliver) {
                const serial = adapter.issueSerial();
                return .{
                    .serial = serial,
                    .time = millis(value.time_usec),
                    .key = value.key,
                    .state = @intFromBool(value.pressed),
                    .modifiers = if (modifiers_changed) .{
                        .serial = adapter.issueSerial(),
                        .state = next_modifiers,
                    } else null,
                };
            }
            if (target == null) return null;
            const delivery = target.?;
            const serial = adapter.issueSerial();
            for (adapter.keyboards.entries.items, 0..) |slot, index| if (adapter.keyboardBelongs(slot, delivery.client))
                adapter.enqueue(delivery.client, .{ .keyboard_key = .{
                    .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                    .serial = serial,
                    .target = delivery,
                    .time = millis(value.time_usec),
                    .key = value.key,
                    .pressed = value.pressed,
                } }) catch unreachable;
            if (value.pressed) adapter.setUserActionSerial(delivery.client, serial);
            if (modifiers_changed) {
                const modifier_serial = adapter.issueSerial();
                for (adapter.keyboards.entries.items, 0..) |slot, index| if (adapter.keyboardBelongs(slot, delivery.client))
                    adapter.enqueue(delivery.client, .{ .keyboard_modifiers = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = modifier_serial,
                        .target = delivery,
                        .state = next_modifiers,
                    } }) catch unreachable;
            }
            return null;
        }

        fn modifierState(adapter: *const Self, keys: [state_words]u64) ModifierState {
            return modifierStateFor(keys, adapter.caps_lock_active, adapter.num_lock_active);
        }

        fn modifierStateFor(keys: [state_words]u64, caps_lock: bool, num_lock: bool) ModifierState {
            var depressed: u32 = 0;
            if (bitSet(&keys, key_left_shift) or bitSet(&keys, key_right_shift)) depressed |= mod_shift;
            if (bitSet(&keys, key_left_ctrl) or bitSet(&keys, key_right_ctrl)) depressed |= mod_control;
            if (bitSet(&keys, key_left_alt)) depressed |= mod_alt;
            if (bitSet(&keys, key_right_alt)) depressed |= mod_alt_gr;
            if (bitSet(&keys, key_left_meta) or bitSet(&keys, key_right_meta)) depressed |= mod_meta;
            return .{
                .depressed = depressed,
                .locked = (if (caps_lock) mod_lock else 0) | (if (num_lock) mod_num else 0),
            };
        }

        fn transitionPointer(adapter: *Self, target: ?FocusTarget) !void {
            if (optionalTargetEqual(adapter.pointer_delivery, target)) return;
            const old = adapter.pointer_delivery;
            const count = adapter.pointerResourceCount(if (old) |v| v.client else null) +
                adapter.pointerResourceCount(if (target) |v| v.client else null);
            try adapter.ensureOutbound(count);
            if (old) |value| {
                const serial = adapter.issueSerial();
                for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, value.client))
                    adapter.enqueue(value.client, .{ .pointer_leave = .{
                        .pointer = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                    } }) catch unreachable;
                adapter.setPointerEnterSerial(value.client, 0);
            }
            adapter.pointer_delivery = target;
            if (target) |value| {
                const serial = adapter.issueSerial();
                for (adapter.pointers.entries.items, 0..) |slot, index| if (adapter.pointerBelongs(slot, value.client))
                    adapter.enqueue(value.client, .{ .pointer_enter = .{
                        .pointer = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                        .point = adapter.pointer_point,
                    } }) catch unreachable;
                adapter.setLastPointerSerial(value.client, serial);
                adapter.setPointerEnterSerial(value.client, serial);
            }
        }

        fn surfaceRemoved(adapter: *Self, id: SurfaceId) void {
            if (adapter.pointer_focus) |v| {
                if (std.meta.eql(v.surface, id)) adapter.pointer_focus = null;
            }
            if (adapter.pointer_delivery) |v| {
                if (std.meta.eql(v.surface, id)) adapter.pointer_delivery = null;
            }
            if (adapter.keyboard_focus) |v| {
                if (std.meta.eql(v.surface, id)) adapter.keyboard_focus = null;
            }
            switch (adapter.pointer_grab) {
                .active => |v| if (std.meta.eql(v.surface, id)) {
                    adapter.pointer_grab = .{ .cancelled = v };
                    adapter.publishTerminal(.{ .pointer_grab_cancelled = v });
                },
                else => {},
            }
            for (adapter.outbound) |*slot| {
                if (slot.active and outboundTargets(slot.value, id)) {
                    adapter.dropPendingTouchEvent(slot.value);
                    slot.active = false;
                    adapter.outbound_len -= 1;
                }
            }
        }

        fn capabilityPublicationCount(adapter: *const Self, old: u32, current: u32) usize {
            if (old == current) return 0;
            var count: usize = 0;
            for (adapter.seats.entries.items) |seat| if (seat.header.active) {
                count += 1;
            };
            return count;
        }

        fn enqueueCapabilities(adapter: *Self, old: u32, current: u32) !void {
            if (old == current) return;
            for (adapter.seats.entries.items, 0..) |seat, index| if (seat.header.active)
                adapter.enqueue(clientId(seat.peer), .{ .seat_capabilities = .{
                    .seat = .{ .index = @intCast(index), .generation = seat.header.generation },
                    .value = current,
                } }) catch unreachable;
        }

        fn capabilityBits(adapter: *const Self) u32 {
            return capabilityBitsFor(adapter.pointer_devices, adapter.keyboard_devices, adapter.touch_devices);
        }

        fn capabilityBitsFor(pointer_devices: usize, keyboard_devices: usize, touch_devices: usize) u32 {
            return (if (pointer_devices != 0) Seat.capability.pointer.value else 0) |
                (if (keyboard_devices != 0) Seat.capability.keyboard.value else 0) |
                (if (touch_devices != 0) Seat.capability.touch.value else 0);
        }

        fn aggregateKeysWithout(adapter: *const Self, excluded: *const DeviceSlot) [state_words]u64 {
            var result = [_]u64{0} ** state_words;
            for (adapter.devices) |*device| if (device.active and device != excluded) {
                for (&result, device.keys) |*aggregate, word| aggregate.* |= word;
            };
            return result;
        }

        fn aggregateButtonsWithout(adapter: *const Self, excluded: *const DeviceSlot) [state_words]u64 {
            var result = [_]u64{0} ** state_words;
            for (adapter.devices) |*device| if (device.active and device != excluded) {
                for (&result, device.buttons) |*aggregate, word| aggregate.* |= word;
            };
            return result;
        }

        fn otherDeviceHasKey(adapter: *const Self, excluded: *const DeviceSlot, code: u32) bool {
            for (adapter.devices) |*device| if (device.active and device != excluded and bitSet(&device.keys, code))
                return true;
            return false;
        }

        fn otherDeviceHasButton(adapter: *const Self, excluded: *const DeviceSlot, code: u32) bool {
            for (adapter.devices) |*device| if (device.active and device != excluded and bitSet(&device.buttons, code))
                return true;
            return false;
        }

        fn onlyPressedButton(adapter: *const Self, code: u32) bool {
            var remaining = adapter.pressed_buttons;
            writeBit(&remaining, code, false);
            return !anySet(&remaining);
        }

        fn pointerTransitionCount(adapter: *const Self, target: ?FocusTarget) usize {
            if (optionalTargetEqual(adapter.pointer_delivery, target)) return 0;
            return adapter.pointerResourceCount(if (adapter.pointer_delivery) |value| value.client else null) +
                adapter.pointerResourceCount(if (target) |value| value.client else null);
        }

        fn pointerCancellationOutbound(adapter: *const Self) usize {
            var button_count: usize = 0;
            for (0..code_count) |code| if (bitSet(&adapter.pressed_buttons, @intCast(code))) {
                button_count += 1;
            };
            const target = switch (adapter.pointer_grab) {
                .active, .cancelled => |value| value,
                .idle => return 0,
            };
            return button_count * adapter.pointerResourceCount(target.client) * 2 +
                adapter.pointerTransitionCount(adapter.pointer_focus);
        }

        fn rebuildPressed(adapter: *Self) void {
            @memset(&adapter.pressed_keys, 0);
            @memset(&adapter.pressed_buttons, 0);
            for (adapter.devices) |device| if (device.active) {
                for (&adapter.pressed_keys, device.keys) |*aggregate, word| aggregate.* |= word;
                for (&adapter.pressed_buttons, device.buttons) |*aggregate, word| aggregate.* |= word;
            };
        }

        fn issueSerial(adapter: *Self) u32 {
            // Fewer pointer slots than nonzero serial values guarantees that
            // at least one value is not retained by a live pointer resource.
            while (true) {
                const serial = adapter.next_serial;
                adapter.next_serial +%= 1;
                if (adapter.next_serial == 0) adapter.next_serial = 1;
                var used = false;
                for (adapter.pointers.entries.items) |pointer| if (adapter.pointerActive(pointer) and
                    (pointer.last_serial == serial or pointer.enter_serial == serial))
                {
                    used = true;
                    break;
                };
                if (!used) return serial;
            }
        }

        fn setLastPointerSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.pointers.entries.items) |pointer| {
                if (adapter.pointerActive(pointer) and sameClient(pointer.client, client))
                    pointer.last_serial = serial;
            }
        }

        fn setPointerEnterSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.pointers.entries.items) |pointer| {
                if (adapter.pointerActive(pointer) and sameClient(pointer.client, client))
                    pointer.enter_serial = serial;
            }
        }

        fn setImplicitGrabSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.pointers.entries.items) |pointer| {
                if (!adapter.pointerActive(pointer) or !sameClient(pointer.client, client)) continue;
                if (pointer.seat_index >= adapter.seats.entries.items.len) continue;
                const seat = adapter.seats.entries.items[pointer.seat_index];
                if (seat.header.active and seat.header.generation == pointer.seat_generation) {
                    seat.last_implicit_grab_serial = serial;
                    seat.last_user_action_serial = serial;
                }
            }
        }

        fn setUserActionSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.seats.entries.items) |seat| {
                if (seat.header.active and sameClient(clientId(seat.peer), client))
                    seat.last_user_action_serial = serial;
            }
        }

        fn seatByObject(
            adapter: *Self,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
        ) ?*SeatSlot {
            const handle = server_objects.namespace.lookupHandle(seat_object) orelse return null;
            const object = server_objects.namespace.resolve(handle) orelse return null;
            if (object.interface != &Seat.info) return null;
            const seat = adapter.seats.fromContext(object.context) orelse return null;
            if (!std.meta.eql(seat.resource, handle) or !std.meta.eql(seat.peer, peer)) return null;
            return seat;
        }

        fn enqueue(adapter: *Self, client: ClientId, value: Outbound) !void {
            for (adapter.outbound) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = adapter.next_sequence, .client = client, .value = value };
                adapter.next_sequence +%= 1;
                adapter.outbound_len += 1;
                return;
            };
            return error.Exhausted;
        }

        fn ensureOutbound(adapter: *const Self, needed: usize) !void {
            if (adapter.outbound.len - adapter.outbound_len < needed) return error.Exhausted;
        }

        fn oldestOutboundFor(adapter: *Self, server_objects: anytype) ?*OutboundSlot {
            var result: ?*OutboundSlot = null;
            for (adapter.outbound) |*slot| {
                if (!slot.active) continue;
                if (!adapter.clientPresent(server_objects, slot.client)) continue;
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            }
            return result;
        }

        fn clientPresent(adapter: *Self, server_objects: anytype, client: ClientId) bool {
            for (adapter.seats.entries.items) |seat| if (seat.header.active and sameClient(clientId(seat.peer), client)) {
                const object = server_objects.namespace.resolve(seat.resource) orelse continue;
                if (object.interface == &Seat.info and object.context == @as(?*anyopaque, @ptrCast(seat)))
                    return true;
            };
            for (adapter.pointers.entries.items) |pointer| if (pointer.header.active and sameClient(pointer.client, client)) {
                const object = server_objects.namespace.resolve(pointer.resource) orelse continue;
                if (object.interface == &Pointer.info and object.context == @as(?*anyopaque, @ptrCast(pointer)))
                    return true;
            };
            for (adapter.keyboards.entries.items) |keyboard| if (keyboard.header.active and sameClient(keyboard.client, client)) {
                const object = server_objects.namespace.resolve(keyboard.resource) orelse continue;
                if (object.interface == &Keyboard.info and object.context == @as(?*anyopaque, @ptrCast(keyboard)))
                    return true;
            };
            for (adapter.touches.entries.items) |touch| if (touch.header.active and sameClient(touch.client, client)) {
                const object = server_objects.namespace.resolve(touch.resource) orelse continue;
                if (object.interface == &Touch.info and object.context == @as(?*anyopaque, @ptrCast(touch))) return true;
            };
            return false;
        }

        fn surfaceObject(adapter: *Self, server_objects: anytype, target: FocusTarget) !objects.Handle {
            const handle = try adapter.core.surfaceHandle(target.surface);
            const object = server_objects.namespace.resolve(handle) orelse return error.StaleSurface;
            if (!std.mem.eql(u8, object.interface.name, "wl_surface")) return error.StaleSurface;
            const exact = try adapter.core.surfaceIdObject(handle, object);
            if (!std.meta.eql(exact, target.surface)) return error.StaleSurface;
            return handle;
        }

        fn encodePressedKeys(pressed_keys: *const [state_words]u64, storage: *[code_count * 4]u8) []const u8 {
            var offset: usize = 0;
            for (0..code_count) |code| if (bitSet(pressed_keys, @intCast(code))) {
                std.mem.writeInt(u32, storage[offset..][0..4], @intCast(code), @import("builtin").cpu.arch.endian());
                offset += 4;
            };
            return storage[0..offset];
        }

        fn deliveryTarget(adapter: *const Self) ?FocusTarget {
            return switch (adapter.pointer_grab) {
                .active => |v| v,
                else => adapter.pointer_delivery,
            };
        }

        fn pointerResourceCount(adapter: *const Self, client: anytype) usize {
            const value: ?ClientId = client;
            if (value == null) return 0;
            var count: usize = 0;
            for (adapter.pointers.entries.items) |slot| if (adapter.pointerBelongs(slot, value.?)) {
                count += 1;
            };
            return count;
        }

        fn keyboardResourceCount(adapter: *const Self, target: ?FocusTarget) usize {
            if (target == null) return 0;
            var count: usize = 0;
            for (adapter.keyboards.entries.items) |slot| if (adapter.keyboardBelongs(slot, target.?.client)) {
                count += 1;
            };
            return count;
        }

        fn pointerBelongs(adapter: *const Self, slot: *const PointerSlot, client: ClientId) bool {
            if (!adapter.pointerActive(slot)) return false;
            return sameClient(slot.client, client);
        }

        fn keyboardBelongs(adapter: *const Self, slot: *const KeyboardSlot, client: ClientId) bool {
            if (!adapter.keyboardActive(slot)) return false;
            return sameClient(slot.client, client);
        }

        fn pointerActive(adapter: *const Self, slot: *const PointerSlot) bool {
            return slot.header.active and slot.capability_generation == adapter.pointer_capability_generation;
        }
        fn keyboardActive(adapter: *const Self, slot: *const KeyboardSlot) bool {
            return slot.header.active and slot.capability_generation == adapter.keyboard_capability_generation;
        }
        fn touchActive(adapter: *const Self, slot: *const TouchSlot) bool {
            return slot.header.active and slot.capability_generation == adapter.touch_capability_generation;
        }
        fn touchResourceCount(adapter: *const Self, client: ClientId) usize {
            var count: usize = 0;
            for (adapter.touches.entries.items) |slot|
                count += @intFromBool(adapter.touchActive(slot) and sameClient(slot.client, client));
            return count;
        }
        fn latestTouchResourceGeneration(adapter: *const Self, client: ClientId) u64 {
            var generation: u64 = 0;
            for (adapter.touches.entries.items) |slot| {
                if (adapter.touchActive(slot) and sameClient(slot.client, client))
                    generation = @max(generation, slot.resource_generation);
            }
            return generation;
        }
        fn touchResourceCountThrough(adapter: *const Self, client: ClientId, generation: u64) usize {
            var count: usize = 0;
            for (adapter.touches.entries.items) |slot|
                count += @intFromBool(adapter.touchActive(slot) and sameClient(slot.client, client) and
                    slot.resource_generation <= generation);
            return count;
        }
        fn findContact(adapter: *Self, id: TouchContactId) ?*ContactSlot {
            for (adapter.contacts) |*slot| if (slot.active and std.meta.eql(slot.contact, id)) return slot;
            return null;
        }
        fn touchParticipates(adapter: *const Self, touch: *const TouchSlot, contact: *const ContactSlot) bool {
            const target = contact.target orelse return false;
            return adapter.touchActive(touch) and sameClient(touch.client, target.client) and
                touch.resource_generation <= contact.max_resource_generation;
        }
        fn touchResourceCountForContact(adapter: *const Self, contact: *const ContactSlot) usize {
            var count: usize = 0;
            for (adapter.touches.entries.items) |touch|
                count += @intFromBool(adapter.touchParticipates(touch, contact));
            return count;
        }
        fn touchResourceHasContact(adapter: *const Self, touch: *const TouchSlot) bool {
            for (adapter.contacts) |contact|
                if (contact.active and adapter.touchParticipates(touch, &contact)) return true;
            return false;
        }
        fn touchResourceHasDeviceContact(adapter: *const Self, touch: *const TouchSlot, device: input.DeviceId) bool {
            for (adapter.contacts) |contact|
                if (contact.active and std.meta.eql(contact.contact.device, device) and
                    adapter.touchParticipates(touch, &contact)) return true;
            return false;
        }
        fn touchCancelDeviceCount(adapter: *const Self, device: input.DeviceId) usize {
            var count: usize = 0;
            for (adapter.touches.entries.items) |touch|
                count += @intFromBool(adapter.touchResourceHasDeviceContact(touch, device));
            return count;
        }
        fn dropPendingTouchEvent(adapter: *Self, value: Outbound) void {
            const id = switch (value) {
                .touch_down => |event| event.touch,
                else => return,
            };
            const touch = adapter.resolveTouch(id) catch return;
            if (touch.pending_frame_events != 0) touch.pending_frame_events -= 1;
        }

        fn resolveDevice(adapter: *Self, id: input.DeviceId) !*DeviceSlot {
            return adapter.findDevice(id) orelse error.StaleDevice;
        }
        fn findDevice(adapter: *Self, id: input.DeviceId) ?*DeviceSlot {
            for (adapter.devices) |*slot| if (slot.active and std.meta.eql(slot.id, id)) return slot;
            return null;
        }
        fn resolveSeat(adapter: *const Self, index: u32, generation: u32) !*SeatSlot {
            if (index >= adapter.seats.entries.items.len) return error.StaleSeat;
            const slot = adapter.seats.entries.items[index];
            if (!slot.header.active or slot.header.generation != generation) return error.StaleSeat;
            return slot;
        }
        fn resolvePointer(adapter: *Self, id: Id) !*PointerSlot {
            if (id.index >= adapter.pointers.entries.items.len) return error.StalePointer;
            const slot = adapter.pointers.entries.items[id.index];
            if (!slot.header.active or slot.header.generation != id.generation) return error.StalePointer;
            return slot;
        }
        fn resolveKeyboard(adapter: *Self, id: Id) !*KeyboardSlot {
            if (id.index >= adapter.keyboards.entries.items.len) return error.StaleKeyboard;
            const slot = adapter.keyboards.entries.items[id.index];
            if (!slot.header.active or slot.header.generation != id.generation) return error.StaleKeyboard;
            return slot;
        }
        fn resolveTouch(adapter: *Self, id: Id) !*TouchSlot {
            if (id.index >= adapter.touches.entries.items.len) return error.StaleTouch;
            const slot = adapter.touches.entries.items[id.index];
            if (!slot.header.active or slot.header.generation != id.generation) return error.StaleTouch;
            return slot;
        }

        fn releaseSeat(adapter: *Self, index: u32) void {
            const generation = adapter.seats.entries.items[index].header.generation;
            for (adapter.outbound) |*slot| if (slot.active) switch (slot.value) {
                .seat_capabilities => |value| {
                    if (value.seat.index == index and value.seat.generation == generation) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                .seat_name => |value| {
                    if (value.index == index and value.generation == generation) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                else => {},
            };
            adapter.seats.release(adapter.seats.entries.items[index]);
        }

        const ResourceKind = enum { pointer, keyboard, touch };
        fn dropOutboundResource(adapter: *Self, kind: ResourceKind, index: u32, generation: u32) void {
            for (adapter.outbound) |*slot| if (slot.active) {
                const id: ?Id = switch (slot.value) {
                    .pointer_enter => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_leave => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_motion => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_button => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_axis_source => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_axis => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_axis_stop => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_axis_value120 => |v| if (kind == .pointer) v.pointer else null,
                    .pointer_frame => |v| if (kind == .pointer) v.pointer else null,
                    .keyboard_keymap => |v| if (kind == .keyboard) v else null,
                    .keyboard_repeat => |v| if (kind == .keyboard) v else null,
                    .keyboard_enter => |v| if (kind == .keyboard) v.keyboard else null,
                    .keyboard_leave => |v| if (kind == .keyboard) v.keyboard else null,
                    .keyboard_key => |v| if (kind == .keyboard) v.keyboard else null,
                    .keyboard_modifiers => |v| if (kind == .keyboard) v.keyboard else null,
                    .touch_down => |v| if (kind == .touch) v.touch else null,
                    .touch_up => |v| if (kind == .touch) v.touch else null,
                    .touch_motion => |v| if (kind == .touch) v.touch else null,
                    .touch_frame => |v| if (kind == .touch) v.touch else null,
                    .touch_cancel => |v| if (kind == .touch) v.touch else null,
                    else => null,
                };
                if (id == null) continue;
                if (id.?.index == index and id.?.generation == generation) {
                    slot.active = false;
                    adapter.outbound_len -= 1;
                }
            };
        }

        fn publish(adapter: *Self, value: Event) !void {
            if (adapter.event_len >= adapter.events.len - 1) return error.Exhausted;
            const tail = (adapter.event_head + adapter.event_len) % adapter.events.len;
            adapter.events[tail] = value;
            adapter.event_len += 1;
        }

        fn publishTerminal(adapter: *Self, value: Event) void {
            std.debug.assert(adapter.event_len < adapter.events.len);
            const tail = (adapter.event_head + adapter.event_len) % adapter.events.len;
            adapter.events[tail] = value;
            adapter.event_len += 1;
        }

        fn seatId(adapter: *Self, slot: *SeatSlot) Id {
            return .{ .index = adapter.seatIndex(slot), .generation = slot.header.generation };
        }
        fn pointerId(adapter: *Self, slot: *PointerSlot) Id {
            return .{ .index = adapter.pointerIndex(slot), .generation = slot.header.generation };
        }
        fn keyboardId(adapter: *Self, slot: *KeyboardSlot) Id {
            return .{ .index = adapter.keyboardIndex(slot), .generation = slot.header.generation };
        }
        fn touchIndex(_: *Self, slot: *TouchSlot) u32 {
            return slot.header.index;
        }
        fn seatIndex(_: *Self, slot: *SeatSlot) u32 {
            return slot.header.index;
        }
        fn pointerIndex(_: *Self, slot: *PointerSlot) u32 {
            return slot.header.index;
        }
        fn keyboardIndex(_: *Self, slot: *KeyboardSlot) u32 {
            return slot.header.index;
        }

        fn noMemory(adapter: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(adapter: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(adapter: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, 0, @errorName(cause));
        }
    };
}

fn clientId(peer: wayring.io_uring.Peer) SeatClientId {
    return .{ .slot = peer.slot, .generation = peer.generation };
}

fn sameClient(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn advanceCapabilityGeneration(generation: *u32) void {
    generation.* +%= 1;
    if (generation.* == 0) generation.* = 1;
}
fn optionalTargetEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null or b == null) return a == null and b == null;
    return sameClient(a.?.client, b.?.client) and std.meta.eql(a.?.surface, b.?.surface);
}
fn millis(usec: u64) u32 {
    return @truncate(usec / 1000);
}
fn fixedFromDelta(value: f64) i32 {
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(scaled);
}
fn axisValue120(value: ?f64) ?i32 {
    const present = value orelse return null;
    const rounded = @round(present);
    if (rounded == 0) return null;
    if (rounded >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (rounded <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(rounded);
}
fn protocolAxis(axis: anytype, comptime Pointer: type) Pointer.axis {
    return switch (axis) {
        .vertical => Pointer.axis.vertical_scroll,
        .horizontal => Pointer.axis.horizontal_scroll,
    };
}
fn bitSet(words: anytype, code: u32) bool {
    return words[code / 64] & (@as(u64, 1) << @intCast(code % 64)) != 0;
}
fn writeBit(words: *[state_words]u64, code: u32, value: bool) void {
    const mask = @as(u64, 1) << @intCast(code % 64);
    if (value) words[code / 64] |= mask else words[code / 64] &= ~mask;
}
fn anySet(words: *const [state_words]u64) bool {
    for (words) |word| if (word != 0) return true;
    return false;
}

fn createKeymap(bytes: []const u8) !struct { fd: linux.fd_t, size: u32 } {
    const size = std.math.add(usize, bytes.len, @intFromBool(bytes[bytes.len - 1] != 0)) catch
        return error.KeymapTooLarge;
    if (size > std.math.maxInt(u32)) return error.KeymapTooLarge;
    const result = linux.memfd_create("ouro-keymap", linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(result) != .SUCCESS) return error.KeymapCreateFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.KeymapCreateFailed;
    if (linux.pwrite(fd, bytes.ptr, bytes.len, 0) != bytes.len) return error.KeymapCreateFailed;
    if (size != bytes.len) {
        const zero: [1]u8 = .{0};
        if (linux.pwrite(fd, &zero, 1, @intCast(bytes.len)) != 1) return error.KeymapCreateFailed;
    }
    const sealed = linux.fcntl(fd, linux.F.ADD_SEALS, linux.F.SEAL_SHRINK | linux.F.SEAL_GROW |
        linux.F.SEAL_WRITE | linux.F.SEAL_SEAL);
    if (linux.errno(sealed) != .SUCCESS) return error.KeymapSealFailed;
    return .{ .fd = fd, .size = @intCast(size) };
}

fn outboundTargets(value: anytype, surface: anytype) bool {
    return switch (value) {
        .pointer_enter => |v| std.meta.eql(v.target.surface, surface),
        .pointer_leave => |v| std.meta.eql(v.target.surface, surface),
        .pointer_motion => |v| std.meta.eql(v.target.surface, surface),
        .pointer_button => |v| v.target != null and std.meta.eql(v.target.?.surface, surface),
        .pointer_axis_source => |v| std.meta.eql(v.target.surface, surface),
        .pointer_axis => |v| std.meta.eql(v.target.surface, surface),
        .pointer_axis_stop => |v| std.meta.eql(v.target.surface, surface),
        .pointer_axis_value120 => |v| std.meta.eql(v.target.surface, surface),
        .pointer_frame => |v| v.target != null and std.meta.eql(v.target.?.surface, surface),
        .keyboard_enter => |v| std.meta.eql(v.target.surface, surface),
        .keyboard_leave => |v| std.meta.eql(v.target.surface, surface),
        .keyboard_key => |v| std.meta.eql(v.target.surface, surface),
        .keyboard_modifiers => |v| std.meta.eql(v.target.surface, surface),
        .touch_down => |v| std.meta.eql(v.target.surface, surface),
        else => false,
    };
}

const test_protocol = @import("core_protocol");

const FakeCore = struct {
    pub const SurfaceId = struct { index: u32, generation: u32 };
    generation: u32 = 1,
    state: u8 = 0,

    pub fn getSurfaceById(core: *FakeCore, id: SurfaceId) !*u8 {
        if (id.index != 0 or id.generation != core.generation) return error.StaleSurface;
        return &core.state;
    }

    pub fn surfaceHandle(core: *FakeCore, id: SurfaceId) !objects.Handle {
        _ = try core.getSurfaceById(id);
        return .{ .id = 10, .generation = id.generation };
    }

    pub fn surfaceIdObject(core: *FakeCore, handle: objects.Handle, _: *const objects.Object) !SurfaceId {
        if (handle.id != 10 or handle.generation != core.generation) return error.StaleSurface;
        return .{ .index = 0, .generation = core.generation };
    }
};

const TestAdapter = Adapter(test_protocol, FakeCore);
const TestCore = wayring.server.Core(test_protocol);

fn testAdapter(core: *FakeCore) !TestAdapter {
    return testAdapterWithCapacity(core, 16, 4);
}

fn testAdapterWithCapacity(core: *FakeCore, outbound_capacity: usize, event_capacity: usize) !TestAdapter {
    return TestAdapter.init(std.testing.allocator, core, .{
        .seat_capacity = 2,
        .pointer_capacity = 2,
        .keyboard_capacity = 2,
        .device_capacity = 2,
        .outbound_capacity = outbound_capacity,
        .event_capacity = event_capacity,
        .keymap = default_keymap,
        .initial_serial = std.math.maxInt(u32),
    });
}

fn clearTestOutbound(adapter: *TestAdapter) void {
    for (adapter.outbound) |*slot| slot.active = false;
    adapter.outbound_len = 0;
}

fn addTestTouchResource(adapter: *TestAdapter, client: TestAdapter.ClientId) !*TestAdapter.TouchSlot {
    const touch = try adapter.touches.acquire();
    touch.client = client;
    touch.resource_generation = adapter.next_touch_resource_generation;
    adapter.next_touch_resource_generation += 1;
    touch.capability_generation = adapter.touch_capability_generation;
    touch.pending_frame_events = 0;
    return touch;
}

fn countTestOutbound(adapter: *const TestAdapter, tag: std.meta.Tag(TestAdapter.Outbound)) usize {
    var count: usize = 0;
    for (adapter.outbound) |*slot| if (slot.active and std.meta.activeTag(slot.value) == tag) {
        count += 1;
    };
    return count;
}

test "seat: ownership reservations grow without invalidating contexts" {
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .seat_capacity = 1,
        .pointer_capacity = 1,
        .keyboard_capacity = 1,
        .device_capacity = 1,
        .outbound_capacity = 1,
        .event_capacity = 1,
        .keymap = default_keymap,
    });
    defer adapter.deinit();

    const seat = try adapter.seats.acquire();
    const seat_context: *anyopaque = seat;
    _ = try adapter.seats.acquire();
    try std.testing.expect(adapter.seats.fromContext(seat_context) == seat);

    const pointer = try adapter.pointers.acquire();
    const pointer_context: *anyopaque = pointer;
    _ = try adapter.pointers.acquire();
    try std.testing.expect(adapter.pointers.fromContext(pointer_context) == pointer);

    const keyboard = try adapter.keyboards.acquire();
    const keyboard_context: *anyopaque = keyboard;
    _ = try adapter.keyboards.acquire();
    try std.testing.expect(adapter.keyboards.fromContext(keyboard_context) == keyboard);
}

test "seat: capabilities aggregate exact physical generations" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const first: input.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 4 };
    const second: input.DeviceId = .{ .slot = 1, .generation = 1, .seat_generation = 4 };

    try adapter.consume(.{ .device_added = .{
        .device = first,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try adapter.consume(.{ .device_added = .{
        .device = second,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    try std.testing.expectEqual(
        test_protocol.wl_seat.capability.pointer.value |
            test_protocol.wl_seat.capability.keyboard.value,
        adapter.capabilityBits(),
    );
    try std.testing.expectError(error.StaleDevice, adapter.consume(.{ .device_removed = .{
        .slot = 0,
        .generation = 2,
        .seat_generation = 4,
    } }));
    try adapter.consume(.{ .device_removed = second });
    try std.testing.expectEqual(test_protocol.wl_seat.capability.pointer.value, adapter.capabilityBits());
}

test "seat: touch contacts retain targets and frame marks across flushes" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    const first = try addTestTouchResource(&adapter, client);
    clearTestOutbound(&adapter);

    const one: TestAdapter.TouchContactId = .{ .device = device, .id = 4 };
    try std.testing.expect((try adapter.touchDown(
        one,
        target,
        10,
        .{ .x = 64, .y = 96 },
        .{ .x = 256, .y = 512 },
    )) != null);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .touch_down));
    try std.testing.expectEqual(TestAdapter.TouchTarget{
        .focus = target,
        .offset = .{ .x = 256, .y = 512 },
    }, adapter.touchTarget(one).?);

    // Protocol flushing does not consume the backend frame boundary.
    clearTestOutbound(&adapter);
    try adapter.touchFrame();
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .touch_frame));
    try std.testing.expectEqual(@as(usize, 0), first.pending_frame_events);
    clearTestOutbound(&adapter);

    const second = try addTestTouchResource(&adapter, client);
    try adapter.touchMotion(one, 11, .{ .x = 128, .y = 160 });
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .touch_motion));
    try std.testing.expectEqual(@as(usize, 1), first.pending_frame_events);
    try std.testing.expectEqual(@as(usize, 0), second.pending_frame_events);

    const two: TestAdapter.TouchContactId = .{ .device = device, .id = 8 };
    _ = try adapter.touchDown(
        two,
        target,
        12,
        .{ .x = 192, .y = 224 },
        .{ .x = 512, .y = 768 },
    );
    try std.testing.expectEqual(@as(usize, 2), countTestOutbound(&adapter, .touch_down));
    try std.testing.expectEqual(@as(usize, 1), second.pending_frame_events);
    try adapter.touchFrame();
    try std.testing.expectEqual(@as(usize, 2), countTestOutbound(&adapter, .touch_frame));
    const pending = adapter.pendingOutbound();
    try adapter.touchFrame();
    try std.testing.expectEqual(pending, adapter.pendingOutbound());

    _ = try adapter.touchUp(one, 13);
    _ = try adapter.touchUp(two, 14);
    try std.testing.expect(adapter.touchTarget(one) == null);
    try std.testing.expect(adapter.touchTarget(two) == null);
}

test "seat: touch device cancellation is atomic and client scoped" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 4, 4);
    defer adapter.deinit();
    const peer_a: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const peer_b: wayring.io_uring.Peer = .{ .slot = 1, .generation = 3 };
    const target_a = try adapter.makeTarget(peer_a, .{ .index = 0, .generation = 1 });
    const target_b = try adapter.makeTarget(peer_b, .{ .index = 0, .generation = 1 });
    const device_a: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    const device_b: input.DeviceId = .{ .slot = 1, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device_a,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    try adapter.consume(.{ .device_added = .{
        .device = device_b,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    _ = try addTestTouchResource(&adapter, clientId(peer_a));
    _ = try addTestTouchResource(&adapter, clientId(peer_b));
    clearTestOutbound(&adapter);

    const on_a: TestAdapter.TouchContactId = .{ .device = device_a, .id = 1 };
    const other_device_same_client: TestAdapter.TouchContactId = .{ .device = device_b, .id = 2 };
    const unrelated: TestAdapter.TouchContactId = .{ .device = device_b, .id = 3 };
    _ = try adapter.touchDown(on_a, target_a, 1, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 });
    _ = try adapter.touchDown(other_device_same_client, target_a, 2, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 });
    _ = try adapter.touchDown(unrelated, target_b, 3, .{ .x = 0, .y = 0 }, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    for (0..adapter.outbound.len) |index|
        try adapter.enqueue(clientId(peer_a), .{ .seat_name = .{ .index = @intCast(index), .generation = 1 } });

    try std.testing.expectError(error.Exhausted, adapter.touchCancelDevice(device_a));
    try std.testing.expect(adapter.findContact(on_a).?.target != null);
    try std.testing.expect(adapter.findContact(other_device_same_client).?.target != null);
    try std.testing.expect(adapter.findContact(unrelated).?.target != null);

    clearTestOutbound(&adapter);
    try adapter.touchCancelDevice(device_a);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .touch_cancel));
    try std.testing.expect(adapter.findContact(on_a) == null);
    try std.testing.expect(adapter.findContact(other_device_same_client).?.target == null);
    try std.testing.expect(adapter.findContact(unrelated).?.target != null);
    clearTestOutbound(&adapter);
    try adapter.touchMotion(other_device_same_client, 4, .{ .x = 1, .y = 1 });
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    try adapter.touchMotion(unrelated, 5, .{ .x = 2, .y = 2 });
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .touch_motion));

    clearTestOutbound(&adapter);
    const old_generation = adapter.touch_capability_generation;
    try adapter.consume(.{ .device_removed = device_a });
    try adapter.consume(.{ .device_removed = device_b });
    try std.testing.expect(adapter.touch_capability_generation != old_generation);
    try std.testing.expect(adapter.findContact(other_device_same_client) == null);
    try std.testing.expect(adapter.findContact(unrelated) == null);
    try adapter.consume(.{ .device_added = .{
        .device = device_a,
        .info = .{ .capabilities = .{ .touch = true } },
    } });
    clearTestOutbound(&adapter);
    const ignored: TestAdapter.TouchContactId = .{ .device = device_a, .id = 9 };
    try std.testing.expect((try adapter.touchDown(
        ignored,
        target_a,
        6,
        .{ .x = 0, .y = 0 },
        .{ .x = 0, .y = 0 },
    )) == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    try std.testing.expect(adapter.findContact(ignored).?.target == null);
    try std.testing.expect((try adapter.touchUp(ignored, 7)) == null);
}

test "seat: serial wrap skips zero and live client pointer serials" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const first = try adapter.seats.acquire();
    first.peer = .{ .slot = 0, .generation = 3 };
    const pointer = try adapter.pointers.acquire();
    pointer.client = clientId(first.peer);
    pointer.last_serial = 1;

    try std.testing.expectEqual(std.math.maxInt(u32), adapter.issueSerial());
    try std.testing.expectEqual(@as(u32, 2), adapter.issueSerial());
}

test "seat: relative pointer lookup retains exact resource generation and focus" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const pointer = try adapter.pointers.acquire();
    pointer.client = clientId(peer);
    pointer.resource = try server_objects.insertClient(
        2,
        &test_protocol.wl_pointer.info,
        9,
        pointer,
    );
    const id = try adapter.pointerIdOn(&server_objects, 2);
    try std.testing.expectEqual(adapter.pointerId(pointer), id);
    try std.testing.expect(!adapter.pointerFocused(id));
    adapter.pointer_delivery = .{
        .client = clientId(peer),
        .surface = .{ .index = 0, .generation = 1 },
    };
    try std.testing.expect(adapter.pointerFocused(id));
    pointer.last_serial = 45;
    pointer.enter_serial = 44;
    try std.testing.expect(adapter.validateCursorShapeOn(&server_objects, peer, 2, 44));
    try std.testing.expect(!adapter.validateCursorShapeOn(&server_objects, peer, 2, 45));
    try std.testing.expect(!adapter.validateCursorShapeOn(&server_objects, peer, 2, 43));
    try std.testing.expect(adapter.validatePointerWarpOn(
        &server_objects,
        peer,
        2,
        adapter.pointer_delivery.?.surface,
        44,
    ));
    try std.testing.expect(!adapter.validatePointerWarpOn(
        &server_objects,
        peer,
        2,
        .{ .index = 1, .generation = 1 },
        44,
    ));
    try std.testing.expect(adapter.applyPointerWarp(
        adapter.pointer_delivery.?.surface,
        .{ .x = 7 * 256, .y = 9 * 256 },
    ));
    try std.testing.expectEqual(TestAdapter.Point{ .x = 7 * 256, .y = 9 * 256 }, adapter.pointerState().point);
    try std.testing.expect(!adapter.validateCursorShapeOn(
        &server_objects,
        .{ .slot = 2, .generation = 7 },
        2,
        45,
    ));
    adapter.pointers.release(adapter.pointers.entries.items[id.index]);
    try std.testing.expect(!adapter.pointerFocused(id));
    try std.testing.expect(!adapter.validateCursorShapeOn(&server_objects, peer, 2, 45));
}

test "seat: popup grabs require the exact seat and delivered press serial" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const seat = try adapter.seats.acquire();
    seat.peer = peer;
    seat.last_implicit_grab_serial = 81;
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const other = try adapter.seats.acquire();
    other.peer = peer;
    other.last_implicit_grab_serial = 82;
    other.resource = try server_objects.insertClient(3, &test_protocol.wl_seat.info, 9, other);

    try std.testing.expect(adapter.validatePopupGrabOn(&server_objects, peer, 2, 81));
    try std.testing.expect(!adapter.validatePopupGrabOn(&server_objects, peer, 2, 82));
    try std.testing.expect(!adapter.validatePopupGrabOn(&server_objects, peer, 3, 81));
    try std.testing.expect(!adapter.validatePopupGrabOn(
        &server_objects,
        .{ .slot = peer.slot, .generation = peer.generation + 1 },
        2,
        81,
    ));
    try std.testing.expect(!adapter.validatePopupGrabOn(&server_objects, peer, 2, 0));
}

test "seat: clipboard selections require the exact seat and latest user action serial" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const seat = try adapter.seats.acquire();
    seat.peer = peer;
    seat.last_user_action_serial = 91;
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const other = try adapter.seats.acquire();
    other.peer = peer;
    other.last_user_action_serial = 92;
    other.resource = try server_objects.insertClient(3, &test_protocol.wl_seat.info, 9, other);

    try std.testing.expect(adapter.validateSelectionOn(&server_objects, peer, 2, 91));
    try std.testing.expect(!adapter.validateSelectionOn(&server_objects, peer, 2, 92));
    try std.testing.expect(!adapter.validateSelectionOn(&server_objects, peer, 3, 91));
    try std.testing.expect(!adapter.validateSelectionOn(
        &server_objects,
        .{ .slot = peer.slot, .generation = peer.generation + 1 },
        2,
        91,
    ));
    try std.testing.expect(!adapter.validateSelectionOn(&server_objects, peer, 2, 0));
}

test "seat: activation requires the exact focused surface and latest user action serial" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const surface: FakeCore.SurfaceId = .{ .index = 0, .generation = 1 };
    const seat = try adapter.seats.acquire();
    seat.peer = peer;
    seat.last_user_action_serial = 91;
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    adapter.keyboard_focus = .{ .client = clientId(peer), .surface = surface };

    try std.testing.expect(adapter.validateActivationOn(&server_objects, peer, 2, 91, surface));
    try std.testing.expect(!adapter.validateActivationOn(&server_objects, peer, 2, 90, surface));
    try std.testing.expect(!adapter.validateActivationOn(
        &server_objects,
        .{ .slot = peer.slot, .generation = peer.generation + 1 },
        2,
        91,
        surface,
    ));
    try std.testing.expect(!adapter.validateActivationOn(
        &server_objects,
        peer,
        2,
        91,
        .{ .index = 0, .generation = 2 },
    ));
    adapter.keyboard_focus = null;
    try std.testing.expect(!adapter.validateActivationOn(&server_objects, peer, 2, 91, surface));
}

test "seat: interactive grabs require the exact active pointer-grab surface" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const seat = try adapter.seats.acquire();
    seat.peer = peer;
    seat.last_implicit_grab_serial = 101;
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const target: TestAdapter.FocusTarget = .{
        .client = clientId(peer),
        .surface = .{ .index = 3, .generation = 4 },
    };
    adapter.pointer_grab = .{ .active = target };

    try std.testing.expect(adapter.validateInteractiveGrabOn(
        &server_objects,
        peer,
        2,
        101,
        target.surface,
    ));
    try std.testing.expect(!adapter.validateInteractiveGrabOn(
        &server_objects,
        peer,
        2,
        101,
        .{ .index = target.surface.index + 1, .generation = target.surface.generation },
    ));
    adapter.pointer_grab = .idle;
    try std.testing.expect(!adapter.validateInteractiveGrabOn(
        &server_objects,
        peer,
        2,
        101,
        target.surface,
    ));
}

test "seat: pointer grab retains focus and device removal cancels it" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    try adapter.setPointerFocus(target, .{ .x = 32, .y = 64 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try adapter.consume(.{ .pointer_button = .{
        .device = device,
        .time_usec = 10_000,
        .button = 0x110,
        .pressed = true,
    } });
    try std.testing.expectEqual(TestAdapter.GrabState.active, std.meta.activeTag(adapter.grabState()));
    try adapter.setPointerFocus(null, .{ .x = 0, .y = 0 });
    try std.testing.expect(adapter.pointer_delivery != null);

    try adapter.consume(.{ .device_removed = device });
    try std.testing.expectEqual(TestAdapter.GrabState.idle, std.meta.activeTag(adapter.grabState()));
    const event = adapter.popEvent() orelse return error.MissingCancellation;
    try std.testing.expectEqual(TestAdapter.Event.pointer_grab_cancelled, std.meta.activeTag(event));
    try std.testing.expect(adapter.pointer_delivery == null);
}

test "seat: grabbed key press and release return aggregate events" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });

    const press = (try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 1_234_567,
        .key = 30,
        .pressed = true,
    } })).?;
    try std.testing.expectEqual(@as(u32, 1234), press.time);
    try std.testing.expectEqual(@as(u32, 30), press.key);
    try std.testing.expectEqual(@as(u32, 1), press.state);
    try std.testing.expect(press.modifiers == null);
    const released = (try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 2_000_000,
        .key = 30,
        .pressed = false,
    } })).?;
    try std.testing.expectEqual(@as(u32, 0), released.state);
    try std.testing.expect(released.serial != press.serial);
    try std.testing.expect(!bitSet(&adapter.pressed_keys, 30));
}

test "seat: grabbed modifier transition returns its serial and state" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    const result = (try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 1,
        .key = key_left_shift,
        .pressed = true,
    } })).?;
    const modifiers = result.modifiers.?;
    try std.testing.expectEqual(mod_shift, modifiers.state.depressed);
    try std.testing.expect(modifiers.serial != result.serial);
    try std.testing.expectEqual(mod_shift, adapter.modifiers.depressed);
}

test "seat: grabbed duplicate-device keys retain aggregate semantics" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const first: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    const second: input.DeviceId = .{ .slot = 1, .generation = 2, .seat_generation = 8 };
    for ([_]input.DeviceId{ first, second }) |device| try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try std.testing.expect((try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = first,
        .time_usec = 1,
        .key = 30,
        .pressed = true,
    } })) != null);
    try std.testing.expect((try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = second,
        .time_usec = 2,
        .key = 30,
        .pressed = true,
    } })) == null);
    try std.testing.expect((try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = first,
        .time_usec = 3,
        .key = 30,
        .pressed = false,
    } })) == null);
    try std.testing.expect(bitSet(&adapter.pressed_keys, 30));
    try std.testing.expect((try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = second,
        .time_usec = 4,
        .key = 30,
        .pressed = false,
    } })) != null);
}

test "seat: grabbed key queues no wl_keyboard outbound" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 2, 4);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try adapter.setKeyboardFocus(target);
    clearTestOutbound(&adapter);
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 1 } });
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 1, .generation = 1 } });
    _ = (try adapter.consumeGrabbedKeyboardKey(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 1,
        .key = 30,
        .pressed = true,
    } })).?;
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 0), countTestOutbound(&adapter, .keyboard_key));
    try std.testing.expectEqual(@as(usize, 0), countTestOutbound(&adapter, .keyboard_modifiers));
}

test "seat: physical modifier and lock state follows the published keymap" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try adapter.setKeyboardFocus(target);
    clearTestOutbound(&adapter);

    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 1,
        .key = key_left_shift,
        .pressed = true,
    } });
    try std.testing.expectEqual(mod_shift, adapter.modifiers.depressed);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_key));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_modifiers));
    clearTestOutbound(&adapter);

    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 2,
        .key = key_caps_lock,
        .pressed = true,
    } });
    try std.testing.expectEqual(mod_shift, adapter.modifiers.depressed);
    try std.testing.expectEqual(mod_lock, adapter.modifiers.locked);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_modifiers));
    clearTestOutbound(&adapter);

    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 3,
        .key = key_left_shift,
        .pressed = false,
    } });
    try std.testing.expectEqual(@as(u32, 0), adapter.modifiers.depressed);
    try std.testing.expectEqual(mod_lock, adapter.modifiers.locked);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_modifiers));
    clearTestOutbound(&adapter);

    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 4,
        .key = key_caps_lock,
        .pressed = false,
    } });
    try std.testing.expectEqual(@as(usize, 0), countTestOutbound(&adapter, .keyboard_modifiers));
    clearTestOutbound(&adapter);
    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 5,
        .key = key_caps_lock,
        .pressed = true,
    } });
    try std.testing.expectEqual(@as(u32, 0), adapter.modifiers.locked);
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_modifiers));
}

test "seat: pointer axis delivers wheel precision and explicit stops" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const pointer = try adapter.pointers.acquire();
    pointer.client = clientId(peer);
    try adapter.setPointerFocus(target, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    clearTestOutbound(&adapter);

    try adapter.consume(.{ .pointer_axis = .{
        .device = device,
        .time_usec = 10_000,
        .source = .wheel,
        .vertical = .{ .value = 15, .value120 = 120 },
        .horizontal = null,
    } });
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_source));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_value120));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_frame));

    clearTestOutbound(&adapter);
    try adapter.consume(.{ .pointer_axis = .{
        .device = device,
        .time_usec = 11_000,
        .source = .finger,
        .vertical = .{ .value = 0, .value120 = null },
        .horizontal = null,
    } });
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_source));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_stop));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_frame));

    clearTestOutbound(&adapter);
    try adapter.consume(.{ .pointer_axis = .{
        .device = device,
        .time_usec = 12_000,
        .source = .wheel,
        .vertical = .{ .value = 0, .stop = true },
        .horizontal = null,
    } });
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_source));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_axis_stop));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_frame));
}

test "seat: stale surface generation cannot become focus" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const stale: TestAdapter.FocusTarget = .{
        .client = .{ .slot = 0, .generation = 1 },
        .surface = .{ .index = 0, .generation = 2 },
    };
    try std.testing.expectError(error.StaleSurface, adapter.setKeyboardFocus(stale));
    try std.testing.expectError(error.StaleSurface, adapter.setPointerFocus(stale, .{ .x = 0, .y = 0 }));
}

test "seat: version one resource does not receive seat name" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const seat = try adapter.seats.acquire();
    seat.peer = .{ .slot = 0, .generation = 1 };
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 1, seat);
    try adapter.enqueue(clientId(seat.peer), .{ .seat_name = adapter.seatId(seat) });

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer output.deinit();

    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(&server_objects, &output));
    try std.testing.expectEqual(@as(usize, 0), output.queuedBytes());
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
}

test "seat: keymap FD delivery retains ownership across TX backpressure" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const seat = try adapter.seats.acquire();
    seat.peer = .{ .slot = 0, .generation = 1 };
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const keyboard = try adapter.keyboards.acquire();
    keyboard.seat_index = adapter.seatIndex(seat);
    keyboard.seat_generation = seat.header.generation;
    keyboard.client = clientId(seat.peer);
    keyboard.resource = try server_objects.insertClient(3, &test_protocol.wl_keyboard.info, 9, keyboard);
    try adapter.enqueue(clientId(seat.peer), .{ .keyboard_keymap = adapter.keyboardId(keyboard) });

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var blocked = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(&server_objects, &blocked));
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());

    var accepting = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    defer accepting.deinit();
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(&server_objects, &accepting));
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 1), accepting.queuedDescriptors());
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try accepting.snapshot(&descriptor_scratch, &control);
    const seals = linux.fcntl(adapter.keymap_fd, linux.F.GET_SEALS, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(seals));
    const required_seals = linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE | linux.F.SEAL_SEAL;
    try std.testing.expect(@as(usize, @intCast(seals)) & required_seals == required_seals);
    var prefix: [10]u8 = undefined;
    try std.testing.expectEqual(@as(usize, prefix.len), linux.pread(
        descriptor_scratch[0],
        &prefix,
        prefix.len,
        0,
    ));
    try std.testing.expectEqualStrings("xkb_keymap", &prefix);
    try std.testing.expect(snapshot.descriptor_count == 1);
}

test "seat: child resources outlive seat release and stale generations are rejected" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    try std.testing.expectEqual(@as(usize, 0), adapter.resourceCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.deviceCount());
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const seat = try adapter.seats.acquire();
    seat.peer = .{ .slot = 0, .generation = 1 };
    seat.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const pointer = try adapter.pointers.acquire();
    pointer.client = clientId(seat.peer);
    pointer.resource = try server_objects.insertClient(3, &test_protocol.wl_pointer.info, 9, pointer);
    const old_id = adapter.pointerId(pointer);
    try std.testing.expectEqual(@as(usize, 2), adapter.resourceCount());

    const seat_object = server_objects.namespace.resolve(seat.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(seat.resource, seat_object));
    try std.testing.expectEqual(@as(usize, 1), adapter.resourceCount());
    _ = try adapter.resolvePointer(old_id);

    const pointer_object = server_objects.namespace.resolve(pointer.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(pointer.resource, pointer_object));
    try std.testing.expectEqual(@as(usize, 0), adapter.resourceCount());
    try std.testing.expectError(error.StalePointer, adapter.resolvePointer(old_id));
    const replacement = try adapter.pointers.acquire();
    try std.testing.expectEqual(old_id.index, adapter.pointerIndex(replacement));
    try std.testing.expect(old_id.generation != replacement.header.generation);
}

test "seat: button and key backpressure preserves exact retry" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 2, 2);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 4 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    const pointer = try adapter.pointers.acquire();
    pointer.client = client;
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    try adapter.setPointerFocus(target, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    try adapter.setKeyboardFocus(target);
    clearTestOutbound(&adapter);

    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 1 } });
    const button = input.Event{ .pointer_button = .{
        .device = device,
        .time_usec = 1_000,
        .button = 0x110,
        .pressed = true,
    } };
    try std.testing.expectError(error.Exhausted, adapter.consume(button));
    try std.testing.expect(!bitSet(&adapter.devices[0].buttons, 0x110));
    try std.testing.expect(!bitSet(&adapter.pressed_buttons, 0x110));
    try std.testing.expectEqual(TestAdapter.GrabState.idle, std.meta.activeTag(adapter.grabState()));
    clearTestOutbound(&adapter);
    try adapter.consume(button);
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_button));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_frame));
    try std.testing.expect(bitSet(&adapter.devices[0].buttons, 0x110));
    try std.testing.expectEqual(TestAdapter.GrabState.active, std.meta.activeTag(adapter.grabState()));

    clearTestOutbound(&adapter);
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 1 } });
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 1, .generation = 1 } });
    const key = input.Event{ .keyboard_key = .{
        .device = device,
        .time_usec = 2_000,
        .key = 30,
        .pressed = true,
    } };
    try std.testing.expectError(error.Exhausted, adapter.consume(key));
    try std.testing.expect(!bitSet(&adapter.devices[0].keys, 30));
    try std.testing.expect(!bitSet(&adapter.pressed_keys, 30));
    clearTestOutbound(&adapter);
    try adapter.consume(key);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_key));
    try std.testing.expect(bitSet(&adapter.devices[0].keys, 30));
}

test "seat: device add backpressure preserves identity for exact retry" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 1, 2);
    defer adapter.deinit();
    const seat = try adapter.seats.acquire();
    seat.peer = .{ .slot = 0, .generation = 1 };
    const client = clientId(seat.peer);
    try adapter.enqueue(client, .{ .seat_name = adapter.seatId(seat) });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    const added = input.Event{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } };

    try std.testing.expectError(error.Exhausted, adapter.consume(added));
    try std.testing.expect(adapter.findDevice(device) == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.pointer_devices);
    try std.testing.expectEqual(@as(u32, 0), adapter.capabilityBits());
    clearTestOutbound(&adapter);
    try adapter.consume(added);
    try std.testing.expect(adapter.findDevice(device) != null);
    try std.testing.expectEqual(@as(usize, 1), adapter.pointer_devices);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
}

test "seat: device storage grows beyond its initial reservation" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();

    for (0..3) |slot| try adapter.consume(.{ .device_added = .{
        .device = .{ .slot = @intCast(slot), .generation = 1, .seat_generation = 1 },
        .info = .{ .capabilities = .{} },
    } });

    try std.testing.expectEqual(@as(usize, 4), adapter.devices.len);
    try std.testing.expect(adapter.findDevice(.{
        .slot = 2,
        .generation = 1,
        .seat_generation = 1,
    }) != null);
}

test "seat: device removal reserves cancellation releases and capabilities atomically" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 4, 2);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    const seat = try adapter.seats.acquire();
    seat.peer = peer;
    const pointer = try adapter.pointers.acquire();
    pointer.client = client;
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    try adapter.setPointerFocus(target, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    try adapter.setKeyboardFocus(target);
    clearTestOutbound(&adapter);
    try adapter.consume(.{ .pointer_button = .{
        .device = device,
        .time_usec = 1_000,
        .button = 0x110,
        .pressed = true,
    } });
    clearTestOutbound(&adapter);
    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 2_000,
        .key = 30,
        .pressed = true,
    } });
    clearTestOutbound(&adapter);
    try adapter.enqueue(client, .{ .seat_name = adapter.seatId(seat) });

    const removed = input.Event{ .device_removed = device };
    try std.testing.expectError(error.Exhausted, adapter.consume(removed));
    try std.testing.expect(adapter.findDevice(device) != null);
    try std.testing.expectEqual(@as(usize, 1), adapter.pointer_devices);
    try std.testing.expectEqual(@as(usize, 1), adapter.keyboard_devices);
    try std.testing.expect(bitSet(&adapter.pressed_buttons, 0x110));
    try std.testing.expect(bitSet(&adapter.pressed_keys, 30));
    try std.testing.expectEqual(TestAdapter.GrabState.active, std.meta.activeTag(adapter.grabState()));
    try std.testing.expect(adapter.popEvent() == null);

    clearTestOutbound(&adapter);
    try adapter.consume(removed);
    try std.testing.expect(adapter.findDevice(device) == null);
    try std.testing.expectEqual(@as(u32, 0), adapter.capabilityBits());
    try std.testing.expect(!anySet(&adapter.pressed_buttons));
    try std.testing.expect(!anySet(&adapter.pressed_keys));
    try std.testing.expectEqual(TestAdapter.GrabState.idle, std.meta.activeTag(adapter.grabState()));
    try std.testing.expectEqual(@as(usize, 4), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_button));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .pointer_frame));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .keyboard_key));
    try std.testing.expectEqual(@as(usize, 1), countTestOutbound(&adapter, .seat_capabilities));
    _ = adapter.popEvent() orelse return error.MissingCancellation;
    try std.testing.expect(adapter.popEvent() == null);

    const replacement: input.DeviceId = .{ .slot = 0, .generation = 6, .seat_generation = 7 };
    clearTestOutbound(&adapter);
    try adapter.consume(.{ .device_added = .{
        .device = replacement,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    clearTestOutbound(&adapter);
    try std.testing.expect(!adapter.pointerBelongs(pointer, client));
    try std.testing.expect(!adapter.keyboardBelongs(keyboard, client));
    try std.testing.expectEqual(@as(usize, 0), adapter.pointerResourceCount(client));
    try std.testing.expectEqual(@as(usize, 0), adapter.keyboardResourceCount(target));

    const fresh_pointer = try adapter.pointers.acquire();
    fresh_pointer.client = client;
    fresh_pointer.capability_generation = adapter.pointer_capability_generation;
    const fresh_keyboard = try adapter.keyboards.acquire();
    fresh_keyboard.client = client;
    fresh_keyboard.capability_generation = adapter.keyboard_capability_generation;
    try std.testing.expectEqual(@as(usize, 1), adapter.pointerResourceCount(client));
    try std.testing.expectEqual(@as(usize, 1), adapter.keyboardResourceCount(target));
}

test "seat: removed grab surface completes cancellation once" {
    var core: FakeCore = .{};
    var adapter = try testAdapterWithCapacity(&core, 4, 2);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    const pointer = try adapter.pointers.acquire();
    pointer.client = client;
    try adapter.setPointerFocus(target, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    try adapter.consume(.{ .pointer_button = .{
        .device = device,
        .time_usec = 1_000,
        .button = 0x110,
        .pressed = true,
    } });
    clearTestOutbound(&adapter);

    adapter.surfaceRemoved(target.surface);
    try std.testing.expect(adapter.pointer_focus == null);
    try std.testing.expect(adapter.pointer_delivery == null);
    try std.testing.expectEqual(TestAdapter.GrabState.cancelled, std.meta.activeTag(adapter.grabState()));
    const event = adapter.popEvent() orelse return error.MissingCancellation;
    try std.testing.expectEqual(TestAdapter.Event.pointer_grab_cancelled, std.meta.activeTag(event));
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 1 } });
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 2 } });
    try adapter.enqueue(client, .{ .seat_name = .{ .index = 0, .generation = 3 } });
    try std.testing.expectError(error.Exhausted, adapter.cancelPointerGrab());
    try std.testing.expectEqual(TestAdapter.GrabState.cancelled, std.meta.activeTag(adapter.grabState()));
    try std.testing.expect(bitSet(&adapter.pressed_buttons, 0x110));
    clearTestOutbound(&adapter);
    try adapter.cancelPointerGrab();
    try std.testing.expectEqual(TestAdapter.GrabState.idle, std.meta.activeTag(adapter.grabState()));
    try std.testing.expect(!anySet(&adapter.pressed_buttons));
    try std.testing.expect(!anySet(&adapter.devices[0].buttons));
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    for (adapter.outbound) |*slot| if (slot.active)
        try std.testing.expect(!outboundTargets(slot.value, target.surface));
    try std.testing.expect(adapter.popEvent() == null);
    try adapter.cancelPointerGrab();
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
}

test "seat: pointer fixed coordinates saturate" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } });
    try adapter.setPointerFocus(target, .{
        .x = std.math.maxInt(i32) - 1,
        .y = std.math.minInt(i32) + 1,
    });
    try adapter.consume(.{ .pointer_motion = .{
        .device = device,
        .time_usec = 1_000,
        .dx = 1,
        .dy = -1,
    } });
    try std.testing.expectEqual(std.math.maxInt(i32), adapter.pointer_point.x);
    try std.testing.expectEqual(std.math.minInt(i32), adapter.pointer_point.y);
}

test "seat: surface removal retires ordinary commands but not terminal releases" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var surface_context: u8 = 0;
    const surface_handle = try server_objects.insertClient(10, &test_protocol.wl_surface.info, 6, &surface_context);
    core.generation = surface_handle.generation;
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = surface_handle.generation });
    const pointer = try adapter.pointers.acquire();
    pointer.client = client;
    pointer.resource = try server_objects.insertClient(3, &test_protocol.wl_pointer.info, 9, pointer);
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    keyboard.resource = try server_objects.insertClient(4, &test_protocol.wl_keyboard.info, 9, keyboard);
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
    } });
    try adapter.setPointerFocus(target, .{ .x = 10, .y = 20 });
    try adapter.setKeyboardFocus(target);
    try adapter.consume(.{ .pointer_motion = .{
        .device = device,
        .time_usec = 1_000,
        .dx = 1,
        .dy = 1,
    } });
    try adapter.consume(.{ .pointer_button = .{
        .device = device,
        .time_usec = 2_000,
        .button = 0x110,
        .pressed = true,
    } });
    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 3_000,
        .key = 30,
        .pressed = true,
    } });
    try std.testing.expect(adapter.pendingOutbound() != 0);

    adapter.surfaceRemoved(target.surface);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(&server_objects, &output));
    try std.testing.expectEqual(@as(usize, 0), output.queuedBytes());

    _ = adapter.popEvent() orelse return error.MissingCancellation;
    try adapter.cancelPointerGrab();
    try std.testing.expectEqual(@as(usize, 2), try adapter.flushOn(&server_objects, &output));
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var bytes = snapshot.first;
    const button_message = (try wayring.wire.Message.decode(bytes)).?;
    const button_event = try test_protocol.wl_pointer.decodeEvent(button_message, &output.descriptors);
    try std.testing.expectEqual(test_protocol.wl_pointer.Event.button, std.meta.activeTag(button_event));
    try std.testing.expectEqual(test_protocol.wl_pointer.button_state.released, button_event.button.state);
    bytes = bytes[button_message.header.size..];
    const frame_message = (try wayring.wire.Message.decode(bytes)).?;
    const frame_event = try test_protocol.wl_pointer.decodeEvent(frame_message, &output.descriptors);
    try std.testing.expectEqual(test_protocol.wl_pointer.Event.frame, std.meta.activeTag(frame_event));
    try std.testing.expectEqual(@as(usize, frame_message.header.size), bytes.len);
}

test "seat: keyboard enter retains admission-time pressed keys through backpressure" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var surface_context: u8 = 0;
    const surface_handle = try server_objects.insertClient(10, &test_protocol.wl_surface.info, 6, &surface_context);
    core.generation = surface_handle.generation;
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = surface_handle.generation });
    const keyboard = try adapter.keyboards.acquire();
    keyboard.client = client;
    keyboard.resource = try server_objects.insertClient(4, &test_protocol.wl_keyboard.info, 9, keyboard);
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } });
    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 1_000,
        .key = 30,
        .pressed = true,
    } });
    try adapter.setKeyboardFocus(target);

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var blocked = wayring.tx.Queue.init(&blocks, 8, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(&server_objects, &blocked));

    try adapter.consume(.{ .keyboard_key = .{
        .device = device,
        .time_usec = 2_000,
        .key = 31,
        .pressed = true,
    } });
    var output = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 3), try adapter.flushOn(&server_objects, &output));
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    var bytes = snapshot.first;
    const enter_message = (try wayring.wire.Message.decode(bytes)).?;
    const enter_event = try test_protocol.wl_keyboard.decodeEvent(enter_message, &fds);
    try std.testing.expectEqual(test_protocol.wl_keyboard.Event.enter, std.meta.activeTag(enter_event));
    try std.testing.expectEqual(@as(usize, 4), enter_event.enter.keys.len);
    try std.testing.expectEqual(
        @as(u32, 30),
        std.mem.readInt(u32, enter_event.enter.keys[0..4], @import("builtin").cpu.arch.endian()),
    );
    bytes = bytes[enter_message.header.size..];
    const modifiers_message = (try wayring.wire.Message.decode(bytes)).?;
    const modifiers_event = try test_protocol.wl_keyboard.decodeEvent(modifiers_message, &fds);
    try std.testing.expectEqual(test_protocol.wl_keyboard.Event.modifiers, std.meta.activeTag(modifiers_event));
    bytes = bytes[modifiers_message.header.size..];
    const key_message = (try wayring.wire.Message.decode(bytes)).?;
    const key_event = try test_protocol.wl_keyboard.decodeEvent(key_message, &fds);
    try std.testing.expectEqual(test_protocol.wl_keyboard.Event.key, std.meta.activeTag(key_event));
    try std.testing.expectEqual(@as(u32, 31), key_event.key.key);
    try std.testing.expectEqual(test_protocol.wl_keyboard.key_state.pressed, key_event.key.state);
    try std.testing.expectEqual(@as(usize, key_message.header.size), bytes.len);
}
