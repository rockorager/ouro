//! Standalone bounded cursor-shape-v1 wire adapter.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Shape = enum(u32) {
    default = 1,
    context_menu,
    help,
    pointer,
    progress,
    wait,
    cell,
    crosshair,
    text,
    vertical_text,
    alias,
    copy,
    move,
    no_drop,
    not_allowed,
    grab,
    grabbing,
    e_resize,
    n_resize,
    ne_resize,
    nw_resize,
    s_resize,
    se_resize,
    sw_resize,
    w_resize,
    ew_resize,
    ns_resize,
    nesw_resize,
    nwse_resize,
    col_resize,
    row_resize,
    all_scroll,
    zoom_in,
    zoom_out,
    dnd_ask,
    all_resize,

    pub fn name(shape: Shape) []const u8 {
        return shape_names[@intFromEnum(shape) - 1];
    }
};

pub const shape_names = [_][]const u8{
    "default",    "context-menu", "help",        "pointer",       "progress",    "wait",
    "cell",       "crosshair",    "text",        "vertical-text", "alias",       "copy",
    "move",       "no-drop",      "not-allowed", "grab",          "grabbing",    "e-resize",
    "n-resize",   "ne-resize",    "nw-resize",   "s-resize",      "se-resize",   "sw-resize",
    "w-resize",   "ew-resize",    "ns-resize",   "nesw-resize",   "nwse-resize", "col-resize",
    "row-resize", "all-scroll",   "zoom-in",     "zoom-out",      "dnd-ask",     "all-resize",
};

pub const fallback_name = "default";

pub const Config = struct {
    manager_capacity: usize = 8,
    device_capacity: usize = 32,
    event_capacity: usize = 32,
    global_version: u32 = 2,

    fn validate(c: Config) !void {
        if (c.manager_capacity == 0 or c.manager_capacity >= none or
            c.device_capacity == 0 or c.device_capacity >= none or
            c.event_capacity == 0 or c.event_capacity >= none or
            c.global_version == 0 or c.global_version > 2) return error.InvalidConfig;
    }
};

pub const PointerValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32, u32) bool,

    pub fn validate(self: PointerValidator, peer: wayring.io_uring.Peer, pointer: u32, serial: u32) bool {
        return self.validateFn(self.context, peer, pointer, serial);
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.wp_cursor_shape_manager_v1;
        const Device = protocol.wp_cursor_shape_device_v1;

        pub const DeviceId = packed struct { index: u32, generation: u32 };
        pub const Event = struct {
            device: DeviceId,
            peer: wayring.io_uring.Peer,
            pointer: u32,
            serial: u32,
            shape: Shape,
        };
        const ManagerSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        const DeviceSlot = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            pointer: u32 = 0,
        };

        allocator: std.mem.Allocator,
        validator: PointerValidator,
        managers: []ManagerSlot,
        devices: []DeviceSlot,
        events: []Event,
        manager_free: u32 = 0,
        device_free: u32 = 0,
        event_head: usize = 0,
        event_len: usize = 0,
        global_version: u32,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, validator: PointerValidator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const devices = try allocator.alloc(DeviceSlot, config.device_capacity);
            errdefer allocator.free(devices);
            const events = try allocator.alloc(Event, config.event_capacity);
            for (managers, 0..) |*slot, i| slot.* = .{ .next_free = if (i + 1 < managers.len) @intCast(i + 1) else none };
            for (devices, 0..) |*slot, i| slot.* = .{ .next_free = if (i + 1 < devices.len) @intCast(i + 1) else none };
            return .{ .allocator = allocator, .validator = validator, .managers = managers, .devices = devices, .events = events, .global_version = config.global_version };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.allocator.free(self.devices);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, self.global_version, self, bind);
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = try self.acquireManager();
            slot.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = fromContext(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_pointer => |payload| {
                        const slot = self.acquireDevice() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.pointer = payload.pointer;
                        const admitted = Manager.admit_get_pointer(server_objects, decoded.handle, payload, .{ .cursor_shape_device = slot }) catch |err| {
                            self.releaseDevice(self.deviceIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.cursor_shape_device;
                    },
                    .get_tablet_tool_v2 => |payload| {
                        const slot = self.acquireDevice() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.pointer = payload.tablet_tool;
                        const admitted = Manager.admit_get_tablet_tool_v2(server_objects, decoded.handle, payload, .{ .cursor_shape_device = slot }) catch |err| {
                            self.releaseDevice(self.deviceIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.cursor_shape_device;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices, target.object.context) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Device, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_shape => |payload| {
                        const version = target.object.version;
                        const maximum: u32 = if (version >= 2) 36 else 34;
                        if (payload.shape.value == 0 or payload.shape.value > maximum)
                            return try self.invalidShape(actor, decoded.handle.id);
                        self.publishShape(slot, payload.serial, @enumFromInt(payload.shape.value)) catch
                            return try self.noMemory(actor);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn peekEvent(self: *const Self) ?*const Event {
            return if (self.event_len == 0) null else &self.events[self.event_head];
        }
        pub fn dropEvent(self: *Self) void {
            if (self.event_len == 0) return;
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_len -= 1;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices, object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.releaseDevice(self.deviceIndex(slot));
                return true;
            }
            if (object.interface == &Manager.info) {
                const slot = fromContext(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                releaseSimple(ManagerSlot, self.managers, &self.manager_free, indexOf(ManagerSlot, self.managers, slot));
                return true;
            }
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.devices, 0..) |*slot, i| if (slot.active and samePeer(slot.peer, peer)) self.releaseDevice(@intCast(i));
            for (self.managers, 0..) |*slot, i| if (slot.active and samePeer(slot.peer, peer)) releaseSimple(ManagerSlot, self.managers, &self.manager_free, @intCast(i));
            var retained: usize = 0;
            const old_len = self.event_len;
            const old_head = self.event_head;
            for (0..old_len) |i| {
                const event = self.events[(old_head + i) % self.events.len];
                if (!samePeer(event.peer, peer)) {
                    self.events[(old_head + retained) % self.events.len] = event;
                    retained += 1;
                }
            }
            self.event_head = old_head;
            self.event_len = retained;
        }

        fn acquireManager(self: *Self) !*ManagerSlot {
            return acquireSimple(ManagerSlot, self.managers, &self.manager_free);
        }
        fn acquireDevice(self: *Self) !*DeviceSlot {
            if (self.device_free == none) return error.Exhausted;
            const i = self.device_free;
            const slot = &self.devices[i];
            self.device_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation };
            return slot;
        }
        fn releaseDevice(self: *Self, i: u32) void {
            const slot = &self.devices[i];
            if (!slot.active) return;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.* = .{ .retired = true, .generation = slot.generation };
            } else {
                slot.* = .{ .generation = slot.generation + 1, .next_free = self.device_free };
                self.device_free = i;
            }
        }
        fn publishShape(self: *Self, slot: *DeviceSlot, serial: u32, shape: Shape) !void {
            if (!self.validator.validate(slot.peer, slot.pointer, serial)) return;
            if (self.event_len == self.events.len) return error.Exhausted;
            self.events[(self.event_head + self.event_len) % self.events.len] = .{
                .device = self.deviceId(slot),
                .peer = slot.peer,
                .pointer = slot.pointer,
                .serial = serial,
                .shape = shape,
            };
            self.event_len += 1;
        }
        fn deviceIndex(self: *const Self, slot: *const DeviceSlot) u32 {
            return indexOf(DeviceSlot, self.devices, slot);
        }
        fn deviceId(self: *const Self, slot: *const DeviceSlot) DeviceId {
            return .{ .index = self.deviceIndex(slot), .generation = slot.generation };
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn invalidShape(_: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            try Core.postError(actor, id, Device.@"error".invalid_shape.value, "invalid cursor shape");
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            _ = self;
            try Core.postError(actor, id, 0, @errorName(err));
            return .stop;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn indexOf(comptime T: type, slots: []T, slot: *const T) u32 {
    return @intCast((@intFromPtr(slot) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const size = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    if (address < start or address >= start + size or (address - start) % @sizeOf(T) != 0) return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active and @intFromPtr(slot) == address) slot else null;
}
fn acquireSimple(comptime T: type, slots: []T, free: *u32) !*T {
    if (free.* == none) return error.Exhausted;
    const i = free.*;
    const slot = &slots[i];
    free.* = slot.next_free;
    slot.* = .{ .active = true };
    return slot;
}
fn releaseSimple(comptime T: type, slots: []T, free: *u32, i: u32) void {
    if (!slots[i].active) return;
    slots[i] = .{ .next_free = free.* };
    free.* = i;
}

test "cursor shape names and version boundaries" {
    const expected = [_][]const u8{ "default", "context-menu", "help", "pointer", "progress", "wait", "cell", "crosshair", "text", "vertical-text", "alias", "copy", "move", "no-drop", "not-allowed", "grab", "grabbing", "e-resize", "n-resize", "ne-resize", "nw-resize", "s-resize", "se-resize", "sw-resize", "w-resize", "ew-resize", "ns-resize", "nesw-resize", "nwse-resize", "col-resize", "row-resize", "all-scroll", "zoom-in", "zoom-out", "dnd-ask", "all-resize" };
    for (expected, 1..) |name, value| try std.testing.expectEqualStrings(name, (@as(Shape, @enumFromInt(value))).name());
    try std.testing.expectEqual(@as(u32, 34), @intFromEnum(Shape.zoom_out));
    try std.testing.expectEqual(@as(u32, 36), @intFromEnum(Shape.all_resize));
}

test "cursor shape bounded generation and client cleanup" {
    const protocol = @import("core_protocol");
    const A = Adapter(protocol);
    const validator: PointerValidator = .{ .validateFn = struct {
        fn call(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32, _: u32) bool {
            return true;
        }
    }.call };
    var adapter = try A.init(std.testing.allocator, validator, .{ .manager_capacity = 1, .device_capacity = 1, .event_capacity = 1 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    const first = try adapter.acquireDevice();
    first.peer = peer;
    const stale = adapter.deviceId(first);
    adapter.releaseDevice(stale.index);
    const second = try adapter.acquireDevice();
    second.peer = peer;
    try std.testing.expect(stale.generation != adapter.deviceId(second).generation);
    adapter.disconnected(peer);
    try std.testing.expect(!second.active);
}

test "cursor shape validation precedes bounded event admission" {
    const protocol = @import("core_protocol");
    const A = Adapter(protocol);
    var accepted = false;
    const validator: PointerValidator = .{ .context = &accepted, .validateFn = struct {
        fn call(context: ?*anyopaque, _: wayring.io_uring.Peer, _: u32, _: u32) bool {
            return (@as(*bool, @ptrCast(@alignCast(context.?)))).*;
        }
    }.call };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .manager_capacity = 1,
        .device_capacity = 2,
        .event_capacity = 1,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    const first = try adapter.acquireDevice();
    first.peer = peer;
    first.pointer = 8;
    try adapter.publishShape(first, 7, .default);
    try std.testing.expectEqual(@as(usize, 0), adapter.event_len);
    accepted = true;
    try adapter.publishShape(first, 7, .default);
    try std.testing.expectEqual(Shape.default, adapter.peekEvent().?.shape);
    const second = try adapter.acquireDevice();
    second.peer = peer;
    second.pointer = 9;
    try std.testing.expectError(error.Exhausted, adapter.publishShape(second, 8, .pointer));
}
