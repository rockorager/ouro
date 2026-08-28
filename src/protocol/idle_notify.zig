//! Fixed-capacity ext-idle-notify-v1 protocol owner.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);
const slot_pool = @import("slot_pool.zig");

pub const SeatValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) bool,

    pub fn validate(self: SeatValidator, peer: wayring.io_uring.Peer, seat: u32) bool {
        return self.validateFn(self.context, peer, seat);
    }
};

pub const Clock = struct {
    context: ?*anyopaque = null,
    nowFn: *const fn (?*anyopaque) anyerror!u64,

    pub fn now(self: Clock) !u64 {
        return self.nowFn(self.context);
    }
};

pub const Config = struct {
    notification_capacity: usize = 32,

    fn validate(config: Config) !void {
        if (config.notification_capacity == 0 or config.notification_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.ext_idle_notifier_v1;
        const Notification = protocol.ext_idle_notification_v1;

        const Event = enum { idled, resumed };
        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            input_only: bool = false,
            timeout_ns: u64 = 0,
            last_activity_ns: u64 = 0,
            idle: bool = false,
            events: [2]Event = undefined,
            event_head: u2 = 0,
            event_len: u2 = 0,
        };

        allocator: std.mem.Allocator,
        validator: SeatValidator,
        clock: Clock,
        slots: slot_pool.Pool(Slot),
        inhibited: bool = false,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, validator: SeatValidator, clock: Clock, config: Config) !Self {
            try config.validate();
            return .{ .allocator = allocator, .validator = validator, .clock = clock, .slots = try slot_pool.Pool(Slot).init(allocator, config.notification_capacity) };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 2, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_idle_notification => |value| if (try self.create(actor, server_objects, peer, decoded.handle, value, false)) |control| return control,
                    .get_input_idle_notification => |value| if (try self.create(actor, server_objects, peer, decoded.handle, value, true)) |control| return control,
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Notification.info) return null;
            const slot = self.fromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Notification, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn create(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, manager: objects.Handle, value: anytype, comptime input_only: bool) !?wayring.dispatch.Control {
            if (!self.validator.validate(peer, value.seat))
                return try self.protocolError(actor, manager.id, "invalid idle-notification seat");
            const now = try self.clock.now();
            const slot = self.acquire() catch return try self.noMemory(actor);
            const admitted = if (input_only)
                Manager.admit_get_input_idle_notification(server_objects, manager, value, .{ .id = slot })
            else
                Manager.admit_get_idle_notification(server_objects, manager, value, .{ .id = slot });
            const resource = admitted catch |err| {
                self.release(self.index(slot));
                return try self.failure(actor, manager.id, err);
            };
            slot.resource = resource.id;
            slot.peer = peer;
            slot.input_only = input_only;
            slot.timeout_ns = @as(u64, value.timeout) * std.time.ns_per_ms;
            slot.last_activity_ns = now;
            return null;
        }

        /// Applies one user-activity boundary atomically across notifications.
        /// An idle notification retains idled/resumed ordering under TX pressure.
        pub fn activity(self: *Self, now_ns: u64) !void {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and slot.idle and slot.event_len == slot.events.len)
                    return error.Exhausted;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active) continue;
                if (slot.idle) try self.enqueue(slot, .resumed);
                slot.idle = false;
                slot.last_activity_ns = now_ns;
            }
        }

        /// Updates inhibitor policy. Input-only notifications deliberately
        /// ignore this state as required by version 2 of the protocol.
        pub fn setInhibited(self: *Self, inhibited: bool, now_ns: u64) !void {
            if (self.inhibited == inhibited) return;
            if (inhibited) for (self.slots.entries.items) |slot|
                if (slot.header.active and !slot.input_only and slot.idle and slot.event_len == slot.events.len)
                    return error.Exhausted;
            self.inhibited = inhibited;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.input_only) continue;
                if (inhibited and slot.idle) try self.enqueue(slot, .resumed);
                slot.idle = false;
                slot.last_activity_ns = now_ns;
            }
        }

        pub fn advance(self: *Self, now_ns: u64) !void {
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.idle or (!slot.input_only and self.inhibited)) continue;
                if (now_ns >= deadline(slot) and slot.event_len == slot.events.len) return error.Exhausted;
            }
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.idle or (!slot.input_only and self.inhibited)) continue;
                if (now_ns < deadline(slot)) continue;
                try self.enqueue(slot, .idled);
                slot.idle = true;
            }
        }

        pub fn nextDeadline(self: *const Self) ?u64 {
            var next: ?u64 = null;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.idle or (!slot.input_only and self.inhibited)) continue;
                const value = deadline(slot);
                if (next == null or value < next.?) next = value;
            }
            return next;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, _: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.slots.entries.items) |slot| while (slot.header.active and slot.event_len != 0 and samePeer(slot.peer, peer)) {
                const event = slot.events[slot.event_head];
                (switch (event) {
                    .idled => Notification.encodeEvent(queue, slot.resource.id, .idled),
                    .resumed => Notification.encodeEvent(queue, slot.resource.id, .resumed),
                }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return err,
                };
                slot.event_head = @intCast((slot.event_head + 1) % slot.events.len);
                slot.event_len -= 1;
                count += 1;
            };
            return count;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and slot.event_len != 0 and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Notification.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(self.index(slot));
                return true;
            }
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer)) self.release(slot.header.index);
        }

        fn enqueue(_: *Self, slot: *Slot, event: Event) !void {
            if (slot.event_len == slot.events.len) return error.Exhausted;
            const offset: usize = (slot.event_head + slot.event_len) % slot.events.len;
            slot.events[offset] = event;
            slot.event_len += 1;
        }

        fn deadline(slot: *const Slot) u64 {
            return slot.last_activity_ns +| slot.timeout_ns;
        }

        fn acquire(self: *Self) !*Slot {
            return self.slots.acquire();
        }

        fn release(self: *Self, i: u32) void {
            self.slots.release(self.slots.at(i) orelse return);
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            return self.slots.fromContext(object.context);
        }

        fn index(_: *const Self, slot: *const Slot) u32 {
            return slot.header.index;
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, message);
            return .stop;
        }

        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return if (err == error.Exhausted or err == error.OutOfMemory)
                self.noMemory(actor)
            else
                self.protocolError(actor, id, @errorName(err));
        }

        fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
            return a.slot == b.slot and a.generation == b.generation;
        }
    };
}

fn testSeat(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
    return true;
}

fn testNow(_: ?*anyopaque) anyerror!u64 {
    return 0;
}

test "idle-notify: notification reservation grows with stable contexts" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{ .validateFn = testSeat }, .{ .nowFn = testNow }, .{ .notification_capacity = 1 });
    defer adapter.deinit();
    const first = try adapter.acquire();
    const second = try adapter.acquire();
    try std.testing.expect(first == adapter.slots.entries.items[0]);
    try std.testing.expect(first != second);
}

test "idle-notify: input activity retains exact idled resumed ordering" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol);
    std.testing.refAllDecls(TestAdapter);
    var adapter = try TestAdapter.init(
        std.testing.allocator,
        .{ .validateFn = testSeat },
        .{ .nowFn = testNow },
        .{ .notification_capacity = 1 },
    );
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.input_only = true;
    slot.timeout_ns = 10;
    slot.last_activity_ns = 20;

    try std.testing.expectEqual(@as(?u64, 30), adapter.nextDeadline());
    try adapter.advance(30);
    try std.testing.expect(slot.idle);
    try adapter.activity(31);
    try std.testing.expect(!slot.idle);
    try std.testing.expectEqual(@as(u2, 2), slot.event_len);
    try std.testing.expectEqual(TestAdapter.Event.idled, slot.events[0]);
    try std.testing.expectEqual(TestAdapter.Event.resumed, slot.events[1]);
    try std.testing.expectEqual(@as(?u64, 41), adapter.nextDeadline());
}

test "idle-notify: inhibitors pause standard deadlines but not input-only deadlines" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol);
    var adapter = try TestAdapter.init(
        std.testing.allocator,
        .{ .validateFn = testSeat },
        .{ .nowFn = testNow },
        .{ .notification_capacity = 2 },
    );
    defer adapter.deinit();
    const standard = try adapter.acquire();
    standard.timeout_ns = 10;
    const input = try adapter.acquire();
    input.input_only = true;
    input.timeout_ns = 10;

    try adapter.setInhibited(true, 5);
    try std.testing.expectEqual(@as(?u64, 10), adapter.nextDeadline());
    try adapter.advance(10);
    try std.testing.expect(!standard.idle);
    try std.testing.expect(input.idle);

    try adapter.setInhibited(false, 12);
    try std.testing.expectEqual(@as(?u64, 22), adapter.nextDeadline());
    try adapter.advance(22);
    try std.testing.expect(standard.idle);
    try std.testing.expect(input.idle);
}
