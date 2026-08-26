//! Fixed-capacity wl_seat owner and protocol-neutral focus boundary.
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
const cursor_role_id: surface_state.RoleId = 0x6375_7273_6f72_5f5f;

pub const SeatClientId = packed struct {
    slot: u32,
    generation: u32,
};

/// XKB text intentionally owns no layout policy beyond the conventional evdev
/// rules. R20 may replace it from compositor configuration at startup.
pub const default_keymap =
    \\xkb_keymap {
    \\ xkb_keycodes { include "evdev+aliases(qwerty)" };
    \\ xkb_types { include "complete" };
    \\ xkb_compatibility { include "complete" };
    \\ xkb_symbols { include "pc+us+inet(evdev)" };
    \\ xkb_geometry { include "pc(pc105)" };
    \\};
;

pub const Config = struct {
    seat_capacity: usize,
    pointer_capacity: usize,
    keyboard_capacity: usize,
    device_capacity: usize,
    outbound_capacity: usize,
    event_capacity: usize,
    name: []const u8 = "seat0",
    keymap: []const u8,
    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    global_version: u32 = 9,
    initial_serial: u32 = 1,

    fn validate(config: Config) !void {
        inline for (.{
            config.seat_capacity,
            config.pointer_capacity,
            config.keyboard_capacity,
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

        const Header = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const SeatSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            last_implicit_grab_serial: u32 = 0,
            last_user_action_serial: u32 = 0,
        };
        const PointerSlot = struct {
            header: Header = .{},
            seat_index: u32 = none,
            seat_generation: u32 = 0,
            client: ClientId = undefined,
            last_serial: u32 = 0,
        };
        const KeyboardSlot = struct {
            header: Header = .{},
            seat_index: u32 = none,
            seat_generation: u32 = 0,
            client: ClientId = undefined,
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
        };
        const Id = PointerId;
        const OutboundSlot = struct {
            active: bool = false,
            sequence: u64 = 0,
            client: ClientId = undefined,
            value: Outbound = undefined,
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
        seats: []SeatSlot,
        pointers: []PointerSlot,
        keyboards: []KeyboardSlot,
        devices: []DeviceSlot,
        outbound: []OutboundSlot,
        outbound_len: usize = 0,
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        seat_free: u32,
        pointer_free: u32,
        keyboard_free: u32,
        pointer_devices: usize = 0,
        keyboard_devices: usize = 0,
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
            const seats = try allocator.alloc(SeatSlot, config.seat_capacity);
            errdefer allocator.free(seats);
            const pointers = try allocator.alloc(PointerSlot, config.pointer_capacity);
            errdefer allocator.free(pointers);
            const keyboards = try allocator.alloc(KeyboardSlot, config.keyboard_capacity);
            errdefer allocator.free(keyboards);
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
            initHeaders(SeatSlot, seats);
            initHeaders(PointerSlot, pointers);
            initHeaders(KeyboardSlot, keyboards);
            @memset(devices, .{});
            @memset(outbound, .{});
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
                .devices = devices,
                .outbound = outbound,
                .events = events,
                .seat_free = 0,
                .pointer_free = 0,
                .keyboard_free = 0,
            };
        }

        pub fn deinit(adapter: *Self) void {
            _ = linux.close(adapter.keymap_fd);
            adapter.allocator.free(adapter.name);
            adapter.allocator.free(adapter.events);
            adapter.allocator.free(adapter.outbound);
            adapter.allocator.free(adapter.devices);
            adapter.allocator.free(adapter.keyboards);
            adapter.allocator.free(adapter.pointers);
            adapter.allocator.free(adapter.seats);
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Seat.info,
                adapter.global_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = acquire(SeatSlot, adapter.seats, &adapter.seat_free) catch
                return error.OutOfMemory;
            slot.header.resource = binding.resource;
            slot.peer = binding.peer;
            const id = adapter.seatId(slot);
            const client = clientId(binding.peer);
            adapter.ensureOutbound(2) catch {
                release(SeatSlot, adapter.seats, &adapter.seat_free, id.index);
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
                const slot = fromContext(SeatSlot, adapter.seats, object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try adapter.seatRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Pointer.info) {
                const slot = fromContext(PointerSlot, adapter.pointers, object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try adapter.pointerRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Keyboard.info) {
                const slot = fromContext(KeyboardSlot, adapter.keyboards, object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try adapter.keyboardRequest(actor, server_objects, slot, message, fds);
            }
            return null;
        }

        fn seatRequest(adapter: *Self, actor: *wayring.connection.Actor, server_objects: anytype, seat: *SeatSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Seat, server_objects, message, fds);
            switch (decoded.value) {
                .get_pointer => |payload| {
                    if (adapter.pointer_devices == 0)
                        return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "pointer capability unavailable");
                    const slot = acquire(PointerSlot, adapter.pointers, &adapter.pointer_free) catch
                        return try adapter.noMemory(actor);
                    slot.seat_index = adapter.seatIndex(seat);
                    slot.seat_generation = seat.header.generation;
                    slot.client = clientId(seat.peer);
                    const focused = adapter.pointer_delivery != null and
                        sameClient(clientId(seat.peer), adapter.pointer_delivery.?.client);
                    if (focused) adapter.ensureOutbound(1) catch {
                        release(PointerSlot, adapter.pointers, &adapter.pointer_free, adapter.pointerIndex(slot));
                        return try adapter.noMemory(actor);
                    };
                    const admitted = Seat.admit_get_pointer(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                        release(PointerSlot, adapter.pointers, &adapter.pointer_free, adapter.pointerIndex(slot));
                        return try adapter.failure(actor, decoded.handle.id, err);
                    };
                    slot.header.resource = admitted.id;
                    if (adapter.pointer_delivery) |focus| if (focused) {
                        const serial = adapter.issueSerial();
                        try adapter.enqueue(clientId(seat.peer), .{ .pointer_enter = .{
                            .pointer = adapter.pointerId(slot),
                            .serial = serial,
                            .target = focus,
                            .point = adapter.pointer_point,
                        } });
                        slot.last_serial = serial;
                    };
                },
                .get_keyboard => |payload| {
                    if (adapter.keyboard_devices == 0)
                        return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "keyboard capability unavailable");
                    const slot = acquire(KeyboardSlot, adapter.keyboards, &adapter.keyboard_free) catch
                        return try adapter.noMemory(actor);
                    slot.seat_index = adapter.seatIndex(seat);
                    slot.seat_generation = seat.header.generation;
                    slot.client = clientId(seat.peer);
                    const extra: usize = if (adapter.keyboard_focus != null) 4 else 2;
                    adapter.ensureOutbound(extra) catch {
                        release(KeyboardSlot, adapter.keyboards, &adapter.keyboard_free, adapter.keyboardIndex(slot));
                        return try adapter.noMemory(actor);
                    };
                    const admitted = Seat.admit_get_keyboard(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                        release(KeyboardSlot, adapter.keyboards, &adapter.keyboard_free, adapter.keyboardIndex(slot));
                        return try adapter.failure(actor, decoded.handle.id, err);
                    };
                    slot.header.resource = admitted.id;
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
                .get_touch => return try adapter.protocolError(actor, decoded.handle.id, Seat.@"error".missing_capability.value, "touch is not supported"),
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn pointerRequest(adapter: *Self, actor: *wayring.connection.Actor, server_objects: anytype, pointer: *PointerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Pointer, server_objects, message, fds);
            switch (decoded.value) {
                .set_cursor => |payload| {
                    const client = pointer.client;
                    if (payload.serial == 0 or payload.serial != pointer.last_serial or
                        adapter.pointer_delivery == null or
                        !sameClient(client, adapter.pointer_delivery.?.client))
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid pointer serial");
                    var surface_id: ?SurfaceId = null;
                    if (payload.surface) |object_id| {
                        const handle = server_objects.namespace.lookupHandle(object_id) orelse
                            return try adapter.protocolError(actor, decoded.handle.id, 0, "stale cursor surface");
                        const object = server_objects.namespace.resolve(handle) orelse
                            return try adapter.protocolError(actor, decoded.handle.id, 0, "stale cursor surface");
                        const cursor = adapter.core.getSurfaceObject(handle, object) catch
                            return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid cursor surface");
                        cursor.role.assign(cursor_role_id, false) catch
                            return try adapter.protocolError(actor, decoded.handle.id, Pointer.@"error".role.value, "cursor surface already has another role");
                        surface_id = adapter.core.surfaceIdObject(handle, object) catch
                            return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid cursor surface");
                    }
                    adapter.publish(.{ .cursor_requested = .{
                        .client = client,
                        .serial = payload.serial,
                        .surface = surface_id,
                        .hotspot = .{ .x = payload.hotspot_x, .y = payload.hotspot_y },
                    } }) catch return try adapter.noMemory(actor);
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

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Seat.info) {
                const slot = fromContext(SeatSlot, adapter.seats, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releaseSeat(adapter.seatIndex(slot));
                return true;
            }
            if (object.interface == &Pointer.info) {
                const slot = fromContext(PointerSlot, adapter.pointers, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.dropOutboundResource(.pointer, adapter.pointerIndex(slot), slot.header.generation);
                release(PointerSlot, adapter.pointers, &adapter.pointer_free, adapter.pointerIndex(slot));
                return true;
            }
            if (object.interface == &Keyboard.info) {
                const slot = fromContext(KeyboardSlot, adapter.keyboards, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.dropOutboundResource(.keyboard, adapter.keyboardIndex(slot), slot.header.generation);
                release(KeyboardSlot, adapter.keyboards, &adapter.keyboard_free, adapter.keyboardIndex(slot));
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
            const slot = fromContext(PointerSlot, adapter.pointers, object.context) orelse
                return error.StalePointer;
            if (!std.meta.eql(slot.header.resource, handle)) return error.StalePointer;
            return adapter.pointerId(slot);
        }

        pub fn pointerFocused(adapter: *Self, id: PointerId) bool {
            const pointer = adapter.resolvePointer(id) catch return false;
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
                pointer.last_serial == serial and adapter.pointerFocused(id);
        }

        pub fn pointerState(adapter: *const Self) PointerState {
            return .{ .focus = adapter.pointer_focus, .point = adapter.pointer_point };
        }

        pub fn nextSerial(adapter: *Self) u32 {
            return adapter.issueSerial();
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
            const seat = fromContext(SeatSlot, adapter.seats, object.context) orelse return false;
            return std.meta.eql(seat.header.resource, handle) and
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
                for (adapter.keyboards, 0..) |slot, index| if (adapter.keyboardBelongs(&slot, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_leave = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                    } }) catch unreachable;
            }
            adapter.keyboard_focus = target;
            if (target) |value| {
                const serial = adapter.issueSerial();
                for (adapter.keyboards, 0..) |slot, index| if (adapter.keyboardBelongs(&slot, value.client))
                    adapter.enqueue(value.client, .{ .keyboard_enter = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                        .pressed_keys = adapter.pressed_keys,
                    } }) catch unreachable;
                for (adapter.keyboards, 0..) |slot, index| if (adapter.keyboardBelongs(&slot, value.client))
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
                for (adapter.keyboards, 0..) |keyboard, index| if (adapter.keyboardBelongs(&keyboard, value.client))
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
                .device_added => |value| try adapter.addDevice(value.device, value.capabilities),
                .device_removed => |id| try adapter.removeDevice(id),
                .pointer_motion => |value| try adapter.pointerMotion(value, null),
                .pointer_button => |value| try adapter.pointerButton(value),
                .pointer_axis => |value| try adapter.pointerAxis(value),
                .keyboard_key => |value| try adapter.keyboardKey(value),
            }
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
            for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, target.client)) {
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
                for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, target.client)) {
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
                    try Seat.encodeEvent(queue, slot.header.resource.id, .{ .capabilities = .{
                        .capabilities = Seat.capability.fromInt(v.value),
                    } });
                },
                .seat_name => |id| {
                    const slot = adapter.resolveSeat(id.index, id.generation) catch return true;
                    try Seat.encodeEvent(queue, slot.header.resource.id, .{ .name = .{ .name = adapter.name } });
                },
                .pointer_enter => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .enter = .{
                        .serial = v.serial,
                        .surface = surface.id,
                        .surface_x = v.point.x,
                        .surface_y = v.point.y,
                    } });
                },
                .pointer_leave => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .leave = .{
                        .serial = v.serial,
                        .surface = surface.id,
                    } });
                },
                .pointer_motion => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .motion = .{
                        .time = v.time,
                        .surface_x = v.point.x,
                        .surface_y = v.point.y,
                    } });
                },
                .pointer_button => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    if (v.target) |target| _ = adapter.surfaceObject(server_objects, target) catch return true;
                    try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .button = .{
                        .serial = v.serial,
                        .time = v.time,
                        .button = v.button,
                        .state = if (v.pressed) Pointer.button_state.pressed else Pointer.button_state.released,
                    } });
                },
                .pointer_axis_source => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.header.resource) orelse return true;
                    if (object.version >= 5) try Pointer.encodeEvent(queue, slot.header.resource.id, .{
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
                    try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .axis = .{
                        .time = v.time,
                        .axis = protocolAxis(v.axis, Pointer),
                        .value = v.value,
                    } });
                },
                .pointer_axis_stop => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.header.resource) orelse return true;
                    if (object.version >= 5) try Pointer.encodeEvent(queue, slot.header.resource.id, .{
                        .axis_stop = .{ .time = v.time, .axis = protocolAxis(v.axis, Pointer) },
                    });
                },
                .pointer_axis_value120 => |v| {
                    const slot = adapter.resolvePointer(v.pointer) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    const object = server_objects.namespace.resolve(slot.header.resource) orelse return true;
                    if (object.version >= 8) {
                        try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .axis_value120 = .{
                            .axis = protocolAxis(v.axis, Pointer),
                            .value120 = v.value120,
                        } });
                    } else if (object.version >= 5) {
                        const discrete = @divTrunc(v.value120, 120);
                        if (discrete != 0) try Pointer.encodeEvent(queue, slot.header.resource.id, .{
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
                    const object = server_objects.namespace.resolve(slot.header.resource) orelse return true;
                    if (object.version >= 5)
                        try Pointer.encodeEvent(queue, slot.header.resource.id, .{ .frame = .{} });
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
                    try Keyboard.encodeEvent(queue, slot.header.resource.id, .{ .keymap = .{
                        .format = Keyboard.keymap_format.xkb_v1,
                        .fd = fd,
                        .size = adapter.keymap_size,
                    } });
                    owned = false;
                },
                .keyboard_repeat => |id| {
                    const slot = adapter.resolveKeyboard(id) catch return true;
                    const object = server_objects.namespace.resolve(slot.header.resource) orelse return true;
                    if (object.version >= 4) try Keyboard.encodeEvent(queue, slot.header.resource.id, .{
                        .repeat_info = .{ .rate = adapter.repeat_rate, .delay = adapter.repeat_delay },
                    });
                },
                .keyboard_enter => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    var keys: [code_count * 4]u8 = undefined;
                    const bytes = encodePressedKeys(&v.pressed_keys, &keys);
                    try Keyboard.encodeEvent(queue, slot.header.resource.id, .{ .enter = .{
                        .serial = v.serial,
                        .surface = surface.id,
                        .keys = bytes,
                    } });
                },
                .keyboard_leave => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    const surface = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.header.resource.id, .{ .leave = .{
                        .serial = v.serial,
                        .surface = surface.id,
                    } });
                },
                .keyboard_key => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.header.resource.id, .{ .key = .{
                        .serial = v.serial,
                        .time = v.time,
                        .key = v.key,
                        .state = if (v.pressed) Keyboard.key_state.pressed else Keyboard.key_state.released,
                    } });
                },
                .keyboard_modifiers => |v| {
                    const slot = adapter.resolveKeyboard(v.keyboard) catch return true;
                    _ = adapter.surfaceObject(server_objects, v.target) catch return true;
                    try Keyboard.encodeEvent(queue, slot.header.resource.id, .{ .modifiers = .{
                        .serial = v.serial,
                        .mods_depressed = v.state.depressed,
                        .mods_latched = v.state.latched,
                        .mods_locked = v.state.locked,
                        .group = v.state.group,
                    } });
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
            const slot = available orelse return error.DeviceCapacityExhausted;
            const old = adapter.capabilityBits();
            const pointer_devices = adapter.pointer_devices + @intFromBool(capabilities.pointer);
            const keyboard_devices = adapter.keyboard_devices + @intFromBool(capabilities.keyboard);
            const current = capabilityBitsFor(pointer_devices, keyboard_devices);
            try adapter.ensureOutbound(adapter.capabilityPublicationCount(old, current));
            slot.* = .{ .active = true, .id = id, .capabilities = capabilities };
            adapter.pointer_devices = pointer_devices;
            adapter.keyboard_devices = keyboard_devices;
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
            const current = capabilityBitsFor(pointer_devices, keyboard_devices);
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
            try adapter.ensureOutbound(outbound_needed);

            if (cancel_grab) adapter.cancelPointerGrab() catch unreachable;
            slot.active = false;
            adapter.pointer_devices = pointer_devices;
            adapter.keyboard_devices = keyboard_devices;
            adapter.pressed_keys = keys_after;
            const modifiers_changed = !std.meta.eql(adapter.modifiers, next_modifiers);
            adapter.modifiers = next_modifiers;
            if (!cancel_grab) adapter.pressed_buttons = buttons_after;
            if (keyboard_target) |target| {
                for (0..code_count) |code| if (bitSet(&old_keys, @intCast(code)) and
                    !bitSet(&keys_after, @intCast(code)))
                {
                    const serial = adapter.issueSerial();
                    for (adapter.keyboards, 0..) |keyboard, index| if (adapter.keyboardBelongs(&keyboard, target.client))
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
                    for (adapter.keyboards, 0..) |keyboard, index| if (adapter.keyboardBelongs(&keyboard, target.client))
                        adapter.enqueue(target.client, .{ .keyboard_modifiers = .{
                            .keyboard = .{ .index = @intCast(index), .generation = keyboard.header.generation },
                            .serial = serial,
                            .target = target,
                            .state = next_modifiers,
                        } }) catch unreachable;
                }
            }
            adapter.enqueueCapabilities(old, current) catch unreachable;
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
            for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, delivery.client)) {
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
                if (present.value == 0) {
                    if (value.source != .wheel) axis_commands += 1;
                } else {
                    axis_commands += 1 + @as(usize, @intFromBool(axisValue120(present.value120) != null));
                }
            };
            if (axis_commands == 0) return;
            const command_count = axis_commands + 2;
            const resource_count = adapter.pointerResourceCount(target.client);
            try adapter.ensureOutbound(command_count * resource_count);
            for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, target.client)) {
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
                    if (present.value == 0) {
                        if (value.source != .wheel) adapter.enqueue(target.client, .{
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
            if (value.key >= code_count) return error.InvalidCode;
            const device = try adapter.resolveDevice(value.device);
            const was = bitSet(&device.keys, value.key);
            if (was == value.pressed) return;
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
            try adapter.ensureOutbound(resource_count *
                (1 + @as(usize, @intFromBool(modifiers_changed))));
            writeBit(&device.keys, value.key, value.pressed);
            adapter.rebuildPressed();
            adapter.caps_lock_active = next_caps_lock;
            adapter.num_lock_active = next_num_lock;
            adapter.modifiers = next_modifiers;
            if (!aggregate_changed or target == null) return;
            const delivery = target.?;
            const serial = adapter.issueSerial();
            for (adapter.keyboards, 0..) |slot, index| if (adapter.keyboardBelongs(&slot, delivery.client))
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
                for (adapter.keyboards, 0..) |slot, index| if (adapter.keyboardBelongs(&slot, delivery.client))
                    adapter.enqueue(delivery.client, .{ .keyboard_modifiers = .{
                        .keyboard = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = modifier_serial,
                        .target = delivery,
                        .state = next_modifiers,
                    } }) catch unreachable;
            }
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
                for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, value.client))
                    adapter.enqueue(value.client, .{ .pointer_leave = .{
                        .pointer = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                    } }) catch unreachable;
            }
            adapter.pointer_delivery = target;
            if (target) |value| {
                const serial = adapter.issueSerial();
                for (adapter.pointers, 0..) |slot, index| if (adapter.pointerBelongs(&slot, value.client))
                    adapter.enqueue(value.client, .{ .pointer_enter = .{
                        .pointer = .{ .index = @intCast(index), .generation = slot.header.generation },
                        .serial = serial,
                        .target = value,
                        .point = adapter.pointer_point,
                    } }) catch unreachable;
                adapter.setLastPointerSerial(value.client, serial);
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
                    slot.active = false;
                    adapter.outbound_len -= 1;
                }
            }
        }

        fn capabilityPublicationCount(adapter: *const Self, old: u32, current: u32) usize {
            if (old == current) return 0;
            var count: usize = 0;
            for (adapter.seats) |seat| if (seat.header.active) {
                count += 1;
            };
            return count;
        }

        fn enqueueCapabilities(adapter: *Self, old: u32, current: u32) !void {
            if (old == current) return;
            for (adapter.seats, 0..) |seat, index| if (seat.header.active)
                adapter.enqueue(clientId(seat.peer), .{ .seat_capabilities = .{
                    .seat = .{ .index = @intCast(index), .generation = seat.header.generation },
                    .value = current,
                } }) catch unreachable;
        }

        fn capabilityBits(adapter: *const Self) u32 {
            return capabilityBitsFor(adapter.pointer_devices, adapter.keyboard_devices);
        }

        fn capabilityBitsFor(pointer_devices: usize, keyboard_devices: usize) u32 {
            return (if (pointer_devices != 0) Seat.capability.pointer.value else 0) |
                (if (keyboard_devices != 0) Seat.capability.keyboard.value else 0);
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
                for (adapter.pointers) |pointer| if (pointer.header.active and pointer.last_serial == serial) {
                    used = true;
                    break;
                };
                if (!used) return serial;
            }
        }

        fn setLastPointerSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.pointers) |*pointer| {
                if (pointer.header.active and sameClient(pointer.client, client))
                    pointer.last_serial = serial;
            }
        }

        fn setImplicitGrabSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.pointers) |pointer| {
                if (!pointer.header.active or !sameClient(pointer.client, client)) continue;
                if (pointer.seat_index >= adapter.seats.len) continue;
                const seat = &adapter.seats[pointer.seat_index];
                if (seat.header.active and seat.header.generation == pointer.seat_generation) {
                    seat.last_implicit_grab_serial = serial;
                    seat.last_user_action_serial = serial;
                }
            }
        }

        fn setUserActionSerial(adapter: *Self, client: ClientId, serial: u32) void {
            for (adapter.seats) |*seat| {
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
            const seat = fromContext(SeatSlot, adapter.seats, object.context) orelse return null;
            if (!std.meta.eql(seat.header.resource, handle) or !std.meta.eql(seat.peer, peer)) return null;
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
            for (adapter.seats) |*seat| if (seat.header.active and sameClient(clientId(seat.peer), client)) {
                const object = server_objects.namespace.resolve(seat.header.resource) orelse continue;
                if (object.interface == &Seat.info and object.context == @as(?*anyopaque, @ptrCast(seat)))
                    return true;
            };
            for (adapter.pointers) |*pointer| if (pointer.header.active and sameClient(pointer.client, client)) {
                const object = server_objects.namespace.resolve(pointer.header.resource) orelse continue;
                if (object.interface == &Pointer.info and object.context == @as(?*anyopaque, @ptrCast(pointer)))
                    return true;
            };
            for (adapter.keyboards) |*keyboard| if (keyboard.header.active and sameClient(keyboard.client, client)) {
                const object = server_objects.namespace.resolve(keyboard.header.resource) orelse continue;
                if (object.interface == &Keyboard.info and object.context == @as(?*anyopaque, @ptrCast(keyboard)))
                    return true;
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
            for (adapter.pointers) |slot| if (adapter.pointerBelongs(&slot, value.?)) {
                count += 1;
            };
            return count;
        }

        fn keyboardResourceCount(adapter: *const Self, target: ?FocusTarget) usize {
            if (target == null) return 0;
            var count: usize = 0;
            for (adapter.keyboards) |slot| if (adapter.keyboardBelongs(&slot, target.?.client)) {
                count += 1;
            };
            return count;
        }

        fn pointerBelongs(adapter: *const Self, slot: *const PointerSlot, client: ClientId) bool {
            _ = adapter;
            if (!slot.header.active) return false;
            return sameClient(slot.client, client);
        }

        fn keyboardBelongs(adapter: *const Self, slot: *const KeyboardSlot, client: ClientId) bool {
            _ = adapter;
            if (!slot.header.active) return false;
            return sameClient(slot.client, client);
        }

        fn resolveDevice(adapter: *Self, id: input.DeviceId) !*DeviceSlot {
            return adapter.findDevice(id) orelse error.StaleDevice;
        }
        fn findDevice(adapter: *Self, id: input.DeviceId) ?*DeviceSlot {
            for (adapter.devices) |*slot| if (slot.active and std.meta.eql(slot.id, id)) return slot;
            return null;
        }
        fn resolveSeat(adapter: *const Self, index: u32, generation: u32) !*SeatSlot {
            if (index >= adapter.seats.len) return error.StaleSeat;
            const slot = &adapter.seats[index];
            if (!slot.header.active or slot.header.generation != generation) return error.StaleSeat;
            return slot;
        }
        fn resolvePointer(adapter: *Self, id: Id) !*PointerSlot {
            if (id.index >= adapter.pointers.len) return error.StalePointer;
            const slot = &adapter.pointers[id.index];
            if (!slot.header.active or slot.header.generation != id.generation) return error.StalePointer;
            return slot;
        }
        fn resolveKeyboard(adapter: *Self, id: Id) !*KeyboardSlot {
            if (id.index >= adapter.keyboards.len) return error.StaleKeyboard;
            const slot = &adapter.keyboards[id.index];
            if (!slot.header.active or slot.header.generation != id.generation) return error.StaleKeyboard;
            return slot;
        }

        fn releaseSeat(adapter: *Self, index: u32) void {
            const generation = adapter.seats[index].header.generation;
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
            release(SeatSlot, adapter.seats, &adapter.seat_free, index);
        }

        const ResourceKind = enum { pointer, keyboard };
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
        fn seatIndex(adapter: *Self, slot: *SeatSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.seats.ptr)) / @sizeOf(SeatSlot));
        }
        fn pointerIndex(adapter: *Self, slot: *PointerSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.pointers.ptr)) / @sizeOf(PointerSlot));
        }
        fn keyboardIndex(adapter: *Self, slot: *KeyboardSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.keyboards.ptr)) / @sizeOf(KeyboardSlot));
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

fn initHeaders(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, index| slot.* = .{ .header = .{
        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
    } };
}

fn acquire(comptime T: type, slots: []T, free: *u32) !*T {
    if (free.* == none) return error.Exhausted;
    const index = free.*;
    const slot = &slots[index];
    free.* = slot.header.next_free;
    const generation = slot.header.generation;
    slot.* = .{ .header = .{ .active = true, .generation = generation } };
    return slot;
}

fn release(comptime T: type, slots: []T, free: *u32, index: u32) void {
    const slot = &slots[index];
    if (!slot.header.active) return;
    slot.header.active = false;
    if (slot.header.generation != std.math.maxInt(u32)) {
        slot.header.generation += 1;
        slot.header.next_free = free.*;
        free.* = index;
    } else slot.header.next_free = none;
}

fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    const slot: *T = @ptrCast(@alignCast(pointer));
    return if (slot.header.active) slot else null;
}

fn clientId(peer: wayring.io_uring.Peer) SeatClientId {
    return .{ .slot = peer.slot, .generation = peer.generation };
}

fn sameClient(a: anytype, b: @TypeOf(a)) bool {
    return a.slot == b.slot and a.generation == b.generation;
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

fn countTestOutbound(adapter: *const TestAdapter, tag: std.meta.Tag(TestAdapter.Outbound)) usize {
    var count: usize = 0;
    for (adapter.outbound) |slot| if (slot.active and std.meta.activeTag(slot.value) == tag) {
        count += 1;
    };
    return count;
}

test "seat: capabilities aggregate exact physical generations" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const first: input.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 4 };
    const second: input.DeviceId = .{ .slot = 1, .generation = 1, .seat_generation = 4 };

    try adapter.consume(.{ .device_added = .{
        .device = first,
        .capabilities = .{ .pointer = true },
    } });
    try adapter.consume(.{ .device_added = .{
        .device = second,
        .capabilities = .{ .pointer = true, .keyboard = true },
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

test "seat: serial wrap skips zero and live client pointer serials" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const first = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    first.peer = .{ .slot = 0, .generation = 3 };
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
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
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = clientId(peer);
    pointer.header.resource = try server_objects.insertClient(
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
    pointer.last_serial = 44;
    try std.testing.expect(adapter.validateCursorShapeOn(&server_objects, peer, 2, 44));
    try std.testing.expect(!adapter.validateCursorShapeOn(&server_objects, peer, 2, 43));
    try std.testing.expect(!adapter.validateCursorShapeOn(
        &server_objects,
        .{ .slot = 2, .generation = 7 },
        2,
        44,
    ));
    release(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free, id.index);
    try std.testing.expect(!adapter.pointerFocused(id));
    try std.testing.expect(!adapter.validateCursorShapeOn(&server_objects, peer, 2, 44));
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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = peer;
    seat.last_implicit_grab_serial = 81;
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const other = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    other.peer = peer;
    other.last_implicit_grab_serial = 82;
    other.header.resource = try server_objects.insertClient(3, &test_protocol.wl_seat.info, 9, other);

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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = peer;
    seat.last_user_action_serial = 91;
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const other = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    other.peer = peer;
    other.last_user_action_serial = 92;
    other.header.resource = try server_objects.insertClient(3, &test_protocol.wl_seat.info, 9, other);

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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = peer;
    seat.last_user_action_serial = 91;
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = peer;
    seat.last_implicit_grab_serial = 101;
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
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
        .capabilities = .{ .pointer = true },
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

test "seat: physical modifier and lock state follows the published keymap" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const client = clientId(peer);
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
    keyboard.client = client;
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .capabilities = .{ .keyboard = true },
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

test "seat: pointer axis delivers wheel precision and finger stops" {
    var core: FakeCore = .{};
    var adapter = try testAdapter(&core);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const target = try adapter.makeTarget(peer, .{ .index = 0, .generation = 1 });
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = clientId(peer);
    try adapter.setPointerFocus(target, .{ .x = 0, .y = 0 });
    clearTestOutbound(&adapter);
    const device: input.DeviceId = .{ .slot = 0, .generation = 2, .seat_generation = 8 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .capabilities = .{ .pointer = true },
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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = .{ .slot = 0, .generation = 1 };
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
    keyboard.seat_index = adapter.seatIndex(seat);
    keyboard.seat_generation = seat.header.generation;
    keyboard.client = clientId(seat.peer);
    keyboard.header.resource = try server_objects.insertClient(3, &test_protocol.wl_keyboard.info, 9, keyboard);
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
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &TestCore.Display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = .{ .slot = 0, .generation = 1 };
    seat.header.resource = try server_objects.insertClient(2, &test_protocol.wl_seat.info, 9, seat);
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = clientId(seat.peer);
    pointer.header.resource = try server_objects.insertClient(3, &test_protocol.wl_pointer.info, 9, pointer);
    const old_id = adapter.pointerId(pointer);

    const seat_object = server_objects.namespace.resolve(seat.header.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(seat.header.resource, seat_object));
    _ = try adapter.resolvePointer(old_id);

    const pointer_object = server_objects.namespace.resolve(pointer.header.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(pointer.header.resource, pointer_object));
    try std.testing.expectError(error.StalePointer, adapter.resolvePointer(old_id));
    const replacement = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
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
        .capabilities = .{ .pointer = true, .keyboard = true },
    } });
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = client;
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
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
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = .{ .slot = 0, .generation = 1 };
    const client = clientId(seat.peer);
    try adapter.enqueue(client, .{ .seat_name = adapter.seatId(seat) });
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    const added = input.Event{ .device_added = .{
        .device = device,
        .capabilities = .{ .pointer = true },
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
        .capabilities = .{ .pointer = true, .keyboard = true },
    } });
    const seat = try acquire(TestAdapter.SeatSlot, adapter.seats, &adapter.seat_free);
    seat.peer = peer;
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = client;
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
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
        .capabilities = .{ .pointer = true },
    } });
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
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
    for (adapter.outbound) |slot| if (slot.active)
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
        .capabilities = .{ .pointer = true },
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
    const pointer = try acquire(TestAdapter.PointerSlot, adapter.pointers, &adapter.pointer_free);
    pointer.client = client;
    pointer.header.resource = try server_objects.insertClient(3, &test_protocol.wl_pointer.info, 9, pointer);
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
    keyboard.client = client;
    keyboard.header.resource = try server_objects.insertClient(4, &test_protocol.wl_keyboard.info, 9, keyboard);
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .capabilities = .{ .pointer = true, .keyboard = true },
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
    const keyboard = try acquire(TestAdapter.KeyboardSlot, adapter.keyboards, &adapter.keyboard_free);
    keyboard.client = client;
    keyboard.header.resource = try server_objects.insertClient(4, &test_protocol.wl_keyboard.info, 9, keyboard);
    const device: input.DeviceId = .{ .slot = 0, .generation = 5, .seat_generation = 7 };
    try adapter.consume(.{ .device_added = .{
        .device = device,
        .capabilities = .{ .keyboard = true },
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
