//! Bounded wlr-virtual-pointer-unstable-v1 adapter.  It deliberately stops at
//! a FIFO boundary: the Coordinator owns interpretation and delivery.
const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const platform = @import("../backend/input/platform.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);
const button_count = 0x300; // Linux input code namespace used by Ouro.
const button_words = button_count / 64;

pub const Config = struct {
    manager_capacity: usize = 4,
    device_capacity: usize = 16,
    event_capacity: usize = 256,

    fn validate(c: Config) !void {
        if (c.manager_capacity == 0 or c.device_capacity == 0 or c.event_capacity == 0 or
            c.manager_capacity >= none or c.device_capacity >= none or
            c.event_capacity > std.math.maxInt(usize) - c.device_capacity) return error.InvalidConfig;
    }
};

pub const Validator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) bool,
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_virtual_pointer_manager_v1;
        const Pointer = protocol.zwlr_virtual_pointer_v1;

        pub const Event = union(enum) {
            device_added: struct { device: input.DeviceId, info: platform.DeviceInfo },
            device_removed: input.DeviceId,
            motion: struct { device: input.DeviceId, time: u32, dx: i32, dy: i32 },
            motion_absolute: struct { device: input.DeviceId, time: u32, x: u32, y: u32, x_extent: u32, y_extent: u32, output_mapped: bool },
            button: struct { device: input.DeviceId, time: u32, button: u32, pressed: bool },
            axis: struct { device: input.DeviceId, time: u32, axis: u32, value: i32, source: platform.AxisSource },
            axis_stop: struct { device: input.DeviceId, time: u32, axis: u32, source: platform.AxisSource },
            axis_discrete: struct { device: input.DeviceId, time: u32, axis: u32, value: i32, discrete: i32, source: platform.AxisSource },
        };
        const ManagerSlot = struct { active: bool = false, next: u32 = none, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined };
        const Device = struct {
            active: bool = false,
            retiring: bool = false,
            generation: u32 = 1,
            next: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            valid: bool = false,
            output_mapped: bool = false,
            axis_source: platform.AxisSource = .wheel,
            pressed: [button_words]u64 = [_]u64{0} ** button_words,
        };

        allocator: std.mem.Allocator,
        managers: []ManagerSlot,
        devices: []Device,
        events: []Event,
        manager_free: u32 = 0,
        device_free: u32 = 0,
        event_head: usize = 0,
        event_count: usize = 0,
        normal_count: usize = 0,
        normal_capacity: usize,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        seat_validator: ?Validator = null,
        output_validator: ?Validator = null,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(2);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const devices = try allocator.alloc(Device, config.device_capacity);
            errdefer allocator.free(devices);
            const events = try allocator.alloc(Event, config.event_capacity + config.device_capacity);
            initFree(ManagerSlot, managers);
            initFree(Device, devices);
            return .{ .allocator = allocator, .managers = managers, .devices = devices, .events = events, .normal_capacity = config.event_capacity };
        }
        pub fn setSeatValidator(self: *Self, validator: ?Validator) void {
            self.seat_validator = validator;
        }
        pub fn setOutputValidator(self: *Self, validator: ?Validator) void {
            self.output_validator = validator;
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
            const global = try runtime.addGlobalWithBinder(&Manager.info, 2, self, bind);
            self.global = global;
            return global;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (self.manager_free == none) return error.OutOfMemory;
            const i = self.manager_free;
            self.manager_free = self.managers[i].next;
            self.managers[i] = .{ .active = true, .resource = binding.resource, .peer = binding.peer };
            return &self.managers[i];
        }
        pub fn peekEvent(self: *const Self) ?*const Event {
            return if (self.event_count == 0) null else &self.events[self.event_head];
        }
        pub fn dropEvent(self: *Self) void {
            if (self.event_count == 0) return;
            const event = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_count -= 1;
            if (event == .device_removed) {
                const id = event.device_removed;
                if (id.slot >= 0xa000_0000) {
                    const i = id.slot - 0xa000_0000;
                    if (i < self.devices.len) {
                        const d = &self.devices[i];
                        if (d.retiring and d.generation == id.generation) self.recycle(i);
                    }
                }
            } else self.normal_count -= 1;
        }
        fn push(self: *Self, event: Event) !void {
            if (self.normal_count == self.normal_capacity) return error.Exhausted;
            self.events[(self.event_head + self.event_count) % self.events.len] = event;
            self.event_count += 1;
            self.normal_count += 1;
        }
        fn pushRemoved(self: *Self, id: input.DeviceId) void {
            std.debug.assert(self.event_count < self.events.len);
            self.events[(self.event_head + self.event_count) % self.events.len] = .{ .device_removed = id };
            self.event_count += 1;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !same(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_virtual_pointer => |p| try self.create(actor, server_objects, peer, decoded.handle, p.seat, null, p, false),
                    .create_virtual_pointer_with_output => |p| try self.create(actor, server_objects, peer, decoded.handle, p.seat, p.output, p, true),
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Pointer.info) return null;
            const d = from(Device, self.devices, target.object.context) orelse return null;
            if (!std.meta.eql(d.resource, handle) or !same(d.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Pointer, server_objects, message, fds);
            if (decoded.value != .destroy and !d.valid) {
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            const id = self.inputId(d);
            switch (decoded.value) {
                .destroy => {},
                .motion => |p| self.push(.{ .motion = .{ .device = id, .time = p.time, .dx = p.dx, .dy = p.dy } }) catch return try self.noMemory(actor),
                .motion_absolute => |p| self.push(.{ .motion_absolute = .{ .device = id, .time = p.time, .x = p.x, .y = p.y, .x_extent = p.x_extent, .y_extent = p.y_extent, .output_mapped = d.output_mapped } }) catch return try self.noMemory(actor),
                .button => |p| {
                    if (p.state.value > 1) return try self.failure(actor, decoded.handle.id, error.InvalidButtonState);
                    if (p.button >= button_count) return try self.failure(actor, decoded.handle.id, error.InvalidButtonCode);
                    const mask = @as(u64, 1) << @intCast(p.button & 63);
                    const word = &d.pressed[p.button / 64];
                    const pressed = p.state.value == 1;
                    if ((word.* & mask != 0) == pressed) {
                        try decoded.finish(protocol, server_objects, &actor.transmit);
                        return .continue_dispatch;
                    }
                    self.push(.{ .button = .{ .device = id, .time = p.time, .button = p.button, .pressed = pressed } }) catch return try self.noMemory(actor);
                    if (pressed) word.* |= mask else word.* &= ~mask;
                },
                .axis => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis = .{ .device = id, .time = p.time, .axis = p.axis.value, .value = p.value, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .axis_source => |p| {
                    if (!validSource(p.axis_source.value)) return try self.invalidSource(actor, decoded.handle.id);
                    d.axis_source = source(p.axis_source.value);
                },
                .axis_stop => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis_stop = .{ .device = id, .time = p.time, .axis = p.axis.value, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .axis_discrete => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis_discrete = .{ .device = id, .time = p.time, .axis = p.axis.value, .value = p.value, .discrete = p.discrete, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .frame => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn create(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, parent: objects.Handle, seat: ?u32, output: ?u32, payload: anytype, comptime with_output: bool) !void {
            const d = self.acquire() catch return self.noMemoryVoid(actor);
            errdefer self.recycle(self.deviceIndex(d));
            d.peer = peer;
            d.valid = seat == null or if (self.seat_validator) |v| v.validateFn(v.context, peer, seat.?) else false;
            d.output_mapped = output != null and if (self.output_validator) |v| v.validateFn(v.context, peer, output.?) else false;
            if (d.valid and self.normal_count == self.normal_capacity)
                return self.noMemoryVoid(actor);
            const admitted = if (with_output)
                Manager.admit_create_virtual_pointer_with_output(server_objects, parent, payload, .{ .id = d })
            else
                Manager.admit_create_virtual_pointer(server_objects, parent, payload, .{ .id = d });
            const result = admitted catch |err| return self.failureVoid(actor, parent.id, err);
            d.resource = result.id;
            if (d.valid) self.push(.{ .device_added = .{ .device = self.inputId(d), .info = .{ .capabilities = .{ .pointer = true } } } }) catch unreachable;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Pointer.info) {
                const d = from(Device, self.devices, object.context) orelse return false;
                if (!std.meta.eql(d.resource, handle)) return false;
                self.retire(self.deviceIndex(d));
                return true;
            }
            if (object.interface == &Manager.info) {
                const m = from(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(m.resource, handle)) return false;
                const i = indexOf(ManagerSlot, self.managers, m);
                m.* = .{ .next = self.manager_free };
                self.manager_free = i;
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.devices, 0..) |d, i| if (d.active and same(d.peer, peer)) self.retire(@intCast(i));
            for (self.managers) |*m| if (m.active and same(m.peer, peer)) {
                const i = indexOf(ManagerSlot, self.managers, m);
                m.* = .{ .next = self.manager_free };
                self.manager_free = i;
            };
        }
        fn acquire(self: *Self) !*Device {
            if (self.device_free == none) return error.Exhausted;
            const i = self.device_free;
            const d = &self.devices[i];
            self.device_free = d.next;
            d.* = .{ .active = true, .generation = d.generation };
            return d;
        }
        fn retire(self: *Self, i: u32) void {
            const d = &self.devices[i];
            if (!d.active) return;
            d.active = false;
            d.retiring = true;
            if (d.valid) self.pushRemoved(self.inputId(d)) else self.recycle(i);
        }
        fn recycle(self: *Self, i: u32) void {
            const d = &self.devices[i];
            const g = d.generation +% 1;
            d.* = .{ .generation = if (g == 0) 1 else g, .next = self.device_free };
            self.device_free = i;
        }
        fn inputId(self: *const Self, d: *const Device) input.DeviceId {
            return .{ .slot = 0xa000_0000 + self.deviceIndex(d), .generation = d.generation, .seat_generation = 0x5650_0002 };
        }
        fn deviceIndex(self: *const Self, d: *const Device) u32 {
            return indexOf(Device, self.devices, d);
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn noMemoryVoid(_: *Self, actor: *wayring.connection.Actor) !void {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
        }
        fn invalidAxis(_: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            try Core.postError(actor, id, Pointer.@"error".invalid_axis.value, "invalid axis");
            return .stop;
        }
        fn invalidSource(_: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            try Core.postError(actor, id, Pointer.@"error".invalid_axis_source.value, "invalid axis source");
            return .stop;
        }
        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            try Core.postError(actor, id, 0, @errorName(err));
            return .stop;
        }
        fn failureVoid(_: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !void {
            try Core.postError(actor, id, 0, @errorName(err));
        }
    };
}

fn validAxis(value: u32) bool {
    return value <= 1;
}
fn validSource(value: u32) bool {
    return value <= 3;
}
fn source(value: u32) platform.AxisSource {
    return switch (value) {
        1 => .finger,
        2 => .continuous,
        else => .wheel,
    };
}
fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, i| slot.* = .{ .next = if (i + 1 < slots.len) @intCast(i + 1) else none };
}
fn indexOf(comptime T: type, slots: []const T, pointer: *const T) u32 {
    return @intCast((@intFromPtr(pointer) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const p = context orelse return null;
    const a = @intFromPtr(p);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (a < start or a >= end or (a - start) % @sizeOf(T) != 0) return null;
    const slot = &slots[(a - start) / @sizeOf(T)];
    return if (slot.active) slot else null;
}
fn same(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return std.meta.eql(a, b);
}

test "cleanup reserve delays generation reuse" {
    const A = Adapter(@import("core_protocol"));
    var a = try A.init(std.testing.allocator, .{ .manager_capacity = 1, .device_capacity = 1, .event_capacity = 1 });
    defer a.deinit();
    const d = try a.acquire();
    d.valid = true;
    try a.push(.{ .device_added = .{ .device = a.inputId(d), .info = .{ .capabilities = .{ .pointer = true } } } });
    const old = a.inputId(d);
    a.retire(0);
    try std.testing.expectError(error.Exhausted, a.acquire());
    a.dropEvent();
    try std.testing.expect(a.peekEvent().?.* == .device_removed);
    a.dropEvent();
    const replacement = try a.acquire();
    try std.testing.expect(replacement.generation != old.generation);
}
