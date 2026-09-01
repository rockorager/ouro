//! Bounded wlr-virtual-pointer-unstable-v1 adapter.  It deliberately stops at
//! a FIFO boundary: the Coordinator owns interpretation and delivery.
const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const platform = @import("../backend/input/platform.zig");
const slot_pool = @import("slot_pool.zig");
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
    resolveFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) ?u64,
};

pub fn Adapter(comptime protocol: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_virtual_pointer_manager_v1;
        const Pointer = protocol.zwlr_virtual_pointer_v1;

        pub const SeatResolver = struct {
            context: ?*anyopaque = null,
            resolveFn: *const fn (?*anyopaque, wayring.io_uring.Peer, ?u32) ?*Seat,
        };
        pub const Event = union(enum) {
            device_added: struct { seat: *Seat, device: input.DeviceId, info: platform.DeviceInfo },
            device_removed: struct { seat: *Seat, device: input.DeviceId },
            motion: struct { seat: *Seat, device: input.DeviceId, time: u32, dx: i32, dy: i32, output: ?u64 },
            motion_absolute: struct { seat: *Seat, device: input.DeviceId, time: u32, x: u32, y: u32, x_extent: u32, y_extent: u32, output: ?u64 },
            button: struct { seat: *Seat, device: input.DeviceId, time: u32, button: u32, pressed: bool },
            axis: struct { seat: *Seat, device: input.DeviceId, time: u32, axis: u32, value: i32, source: platform.AxisSource },
            axis_stop: struct { seat: *Seat, device: input.DeviceId, time: u32, axis: u32, source: platform.AxisSource },
            axis_discrete: struct { seat: *Seat, device: input.DeviceId, time: u32, axis: u32, value: i32, discrete: i32, source: platform.AxisSource },
        };
        const ManagerSlot = struct { header: slot_pool.Header = .{}, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined };
        const Device = struct {
            header: slot_pool.Header = .{},
            retiring: bool = false,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            seat: ?*Seat = null,
            output: ?u64 = null,
            axis_source: platform.AxisSource = .wheel,
            pressed: [button_words]u64 = [_]u64{0} ** button_words,
        };

        allocator: std.mem.Allocator,
        managers: slot_pool.Pool(ManagerSlot),
        devices: slot_pool.Pool(Device),
        events: []Event,
        event_head: usize = 0,
        event_count: usize = 0,
        normal_count: usize = 0,
        normal_capacity: usize,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        seat_resolver: SeatResolver,
        output_validator: ?Validator = null,

        pub fn init(allocator: std.mem.Allocator, seat_resolver: SeatResolver, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(2);
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, config.manager_capacity);
            errdefer managers.deinit();
            var devices = try slot_pool.Pool(Device).init(allocator, config.device_capacity);
            errdefer devices.deinit();
            const events = try allocator.alloc(Event, config.event_capacity + config.device_capacity);
            return .{ .allocator = allocator, .managers = managers, .devices = devices, .events = events, .normal_capacity = config.event_capacity, .seat_resolver = seat_resolver };
        }
        pub fn setOutputValidator(self: *Self, validator: ?Validator) void {
            self.output_validator = validator;
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.devices.deinit();
            self.managers.deinit();
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
            const manager = self.managers.acquire() catch return error.OutOfMemory;
            manager.resource = binding.resource;
            manager.peer = binding.peer;
            return manager;
        }
        pub fn peekEvent(self: *const Self) ?*const Event {
            return if (self.event_count == 0) null else &self.events[self.event_head];
        }

        pub fn hasPendingEvents(self: *const Self) bool {
            return self.event_count != 0;
        }

        pub fn dropEvent(self: *Self) void {
            if (self.event_count == 0) return;
            const event = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_count -= 1;
            if (event == .device_removed) {
                const id = event.device_removed.device;
                if (id.slot >= 0xa000_0000) {
                    const i = id.slot - 0xa000_0000;
                    if (i < self.devices.entries.items.len) {
                        const d = self.devices.entries.items[i];
                        if (d.retiring and d.header.generation == id.generation) self.recycle(d);
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
        fn pushRemoved(self: *Self, seat: *Seat, id: input.DeviceId) void {
            std.debug.assert(self.event_count < self.events.len);
            self.events[(self.event_head + self.event_count) % self.events.len] = .{ .device_removed = .{ .seat = seat, .device = id } };
            self.event_count += 1;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managers.fromContext(target.object.context) orelse return null;
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
            const d = self.devices.fromContext(target.object.context) orelse return null;
            if (!std.meta.eql(d.resource, handle) or !same(d.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Pointer, server_objects, message, fds);
            if (decoded.value != .destroy and d.seat == null) {
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            const id = self.inputId(d);
            switch (decoded.value) {
                .destroy => {},
                .motion => |p| self.push(.{ .motion = .{ .seat = d.seat.?, .device = id, .time = p.time, .dx = p.dx, .dy = p.dy, .output = d.output } }) catch return try self.noMemory(actor),
                .motion_absolute => |p| self.push(.{ .motion_absolute = .{ .seat = d.seat.?, .device = id, .time = p.time, .x = p.x, .y = p.y, .x_extent = p.x_extent, .y_extent = p.y_extent, .output = d.output } }) catch return try self.noMemory(actor),
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
                    self.push(.{ .button = .{ .seat = d.seat.?, .device = id, .time = p.time, .button = p.button, .pressed = pressed } }) catch return try self.noMemory(actor);
                    if (pressed) word.* |= mask else word.* &= ~mask;
                },
                .axis => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis = .{ .seat = d.seat.?, .device = id, .time = p.time, .axis = p.axis.value, .value = p.value, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .axis_source => |p| {
                    if (!validSource(p.axis_source.value)) return try self.invalidSource(actor, decoded.handle.id);
                    d.axis_source = source(p.axis_source.value);
                },
                .axis_stop => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis_stop = .{ .seat = d.seat.?, .device = id, .time = p.time, .axis = p.axis.value, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .axis_discrete => |p| {
                    if (!validAxis(p.axis.value)) return try self.invalidAxis(actor, decoded.handle.id);
                    self.push(.{ .axis_discrete = .{ .seat = d.seat.?, .device = id, .time = p.time, .axis = p.axis.value, .value = p.value, .discrete = p.discrete, .source = d.axis_source } }) catch return try self.noMemory(actor);
                },
                .frame => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn create(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, parent: objects.Handle, seat: ?u32, output: ?u32, payload: anytype, comptime with_output: bool) !void {
            const d = self.acquire() catch return self.noMemoryVoid(actor);
            errdefer self.recycle(d);
            d.peer = peer;
            d.seat = self.seat_resolver.resolveFn(self.seat_resolver.context, peer, seat);
            d.output = if (output) |value|
                if (self.output_validator) |resolver|
                    resolver.resolveFn(resolver.context, peer, value)
                else
                    null
            else
                null;
            if (d.seat != null and self.normal_count == self.normal_capacity)
                return self.noMemoryVoid(actor);
            const admitted = if (with_output)
                Manager.admit_create_virtual_pointer_with_output(server_objects, parent, payload, .{ .id = d })
            else
                Manager.admit_create_virtual_pointer(server_objects, parent, payload, .{ .id = d });
            const result = admitted catch |err| return self.failureVoid(actor, parent.id, err);
            d.resource = result.id;
            if (d.seat) |resolved| self.push(.{ .device_added = .{ .seat = resolved, .device = self.inputId(d), .info = .{ .capabilities = .{ .pointer = true } } } }) catch unreachable;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Pointer.info) {
                const d = self.devices.fromContext(object.context) orelse return false;
                if (!std.meta.eql(d.resource, handle)) return false;
                self.retire(d);
                return true;
            }
            if (object.interface == &Manager.info) {
                const m = self.managers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(m.resource, handle)) return false;
                self.managers.release(m);
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.devices.entries.items) |d| if (d.header.active and !d.retiring and same(d.peer, peer)) self.retire(d);
            for (self.managers.entries.items) |m| if (m.header.active and same(m.peer, peer)) self.managers.release(m);
        }
        fn acquire(self: *Self) !*Device {
            // Every newly owned slot carries one terminal-removal reservation.
            try self.ensureEventStorage(self.normal_capacity + self.devices.entries.items.len + 1);
            return self.devices.acquire();
        }
        fn retire(self: *Self, d: *Device) void {
            if (!d.header.active or d.retiring) return;
            d.retiring = true;
            if (d.seat) |seat| self.pushRemoved(seat, self.inputId(d)) else self.recycle(d);
        }
        fn recycle(self: *Self, d: *Device) void {
            self.devices.release(d);
        }
        fn inputId(self: *const Self, d: *const Device) input.DeviceId {
            return .{ .slot = 0xa000_0000 + self.deviceIndex(d), .generation = d.header.generation, .seat_generation = 0x5650_0002 };
        }
        fn deviceIndex(_: *const Self, d: *const Device) u32 {
            return d.header.index;
        }
        fn ensureEventStorage(self: *Self, required: usize) !void {
            if (required <= self.events.len) return;
            const grown = try self.allocator.alloc(Event, required);
            for (0..self.event_count) |i| grown[i] = self.events[(self.event_head + i) % self.events.len];
            self.allocator.free(self.events);
            self.events = grown;
            self.event_head = 0;
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
fn same(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return std.meta.eql(a, b);
}

test "cleanup reserve delays generation reuse" {
    const TestSeat = struct {};
    const Resolver = struct {
        fn resolve(context: ?*anyopaque, _: wayring.io_uring.Peer, _: ?u32) ?*TestSeat {
            return @ptrCast(@alignCast(context orelse return null));
        }
    };
    const A = Adapter(@import("core_protocol"), TestSeat);
    var seat: TestSeat = .{};
    var a = try A.init(std.testing.allocator, .{ .context = &seat, .resolveFn = Resolver.resolve }, .{ .manager_capacity = 1, .device_capacity = 1, .event_capacity = 1 });
    defer a.deinit();
    const d = try a.acquire();
    d.seat = &seat;
    try a.push(.{ .device_added = .{ .seat = &seat, .device = a.inputId(d), .info = .{ .capabilities = .{ .pointer = true } } } });
    const old = a.inputId(d);
    a.retire(d);
    const concurrent = try a.acquire();
    try std.testing.expect(concurrent != d);
    a.dropEvent();
    const removed = a.peekEvent().?.device_removed;
    try std.testing.expect(removed.seat == &seat);
    try std.testing.expectEqual(old, removed.device);
    a.dropEvent();
    const replacement = try a.acquire();
    try std.testing.expect(replacement.header.generation != old.generation);
}

test "motion preserves exact output identity" {
    const TestSeat = struct {};
    const Resolver = struct {
        fn resolve(context: ?*anyopaque, _: wayring.io_uring.Peer, _: ?u32) ?*TestSeat {
            return @ptrCast(@alignCast(context orelse return null));
        }
    };
    const A = Adapter(@import("core_protocol"), TestSeat);
    var seat: TestSeat = .{};
    var adapter = try A.init(
        std.testing.allocator,
        .{ .context = &seat, .resolveFn = Resolver.resolve },
        .{ .manager_capacity = 1, .device_capacity = 1, .event_capacity = 1 },
    );
    defer adapter.deinit();
    const device = try adapter.acquire();
    device.seat = &seat;
    device.output = 0x0000_0007_0000_0003;
    try adapter.push(.{ .motion_absolute = .{
        .seat = &seat,
        .device = adapter.inputId(device),
        .time = 4,
        .x = 5,
        .y = 6,
        .x_extent = 7,
        .y_extent = 8,
        .output = device.output,
    } });
    try std.testing.expectEqual(
        device.output,
        adapter.peekEvent().?.motion_absolute.output,
    );
    adapter.dropEvent();
    try adapter.push(.{ .motion = .{
        .seat = &seat,
        .device = adapter.inputId(device),
        .time = 9,
        .dx = 10,
        .dy = 11,
        .output = device.output,
    } });
    try std.testing.expectEqual(
        device.output,
        adapter.peekEvent().?.motion.output,
    );
}

test "ownership growth preserves contexts and every removal beyond initial reserve" {
    const TestSeat = struct {};
    const Resolver = struct {
        fn resolve(context: ?*anyopaque, _: wayring.io_uring.Peer, _: ?u32) ?*TestSeat {
            return @ptrCast(@alignCast(context orelse return null));
        }
    };
    const A = Adapter(@import("core_protocol"), TestSeat);
    var seat: TestSeat = .{};
    var a = try A.init(std.testing.allocator, .{ .context = &seat, .resolveFn = Resolver.resolve }, .{ .manager_capacity = 1, .device_capacity = 1, .event_capacity = 1 });
    defer a.deinit();

    const first_manager = try a.managers.acquire();
    _ = try a.managers.acquire();
    try std.testing.expect(first_manager == a.managers.entries.items[0]);

    var devices: [4]*A.Device = undefined;
    for (&devices) |*device| {
        device.* = try a.acquire();
        device.*.seat = &seat;
    }
    try std.testing.expect(devices[0] == a.devices.entries.items[0]);
    for (devices) |device| a.retire(device);
    var removals: usize = 0;
    while (a.peekEvent()) |event| {
        try std.testing.expect(event.* == .device_removed);
        removals += 1;
        a.dropEvent();
    }
    try std.testing.expectEqual(devices.len, removals);
}
