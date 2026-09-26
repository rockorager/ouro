//! High-resolution input subscriptions. Seat owns event ordering and calls
//! send before publishing each timestamp-bearing core event.
const std = @import("std");
const wayring = @import("wayring");
const slot_pool = @import("slot_pool.zig");
const objects = wayring.objects;

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_input_timestamps_manager_v1;
        const Timestamps = protocol.zwp_input_timestamps_v1;
        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = undefined,
            peer: wayring.io_uring.Peer = undefined,
            input: ?objects.Handle = null,
        };

        runtime: ?*Runtime = null,
        slots: slot_pool.Pool(Slot),

        pub fn init(allocator: std.mem.Allocator) !Self {
            return .{ .slots = try slot_pool.Pool(Slot).init(allocator, 16) };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            return runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    inline .get_keyboard_timestamps, .get_pointer_timestamps, .get_touch_timestamps => |payload, tag| {
                        const input_id = switch (tag) {
                            .get_keyboard_timestamps => payload.keyboard,
                            .get_pointer_timestamps => payload.pointer,
                            .get_touch_timestamps => payload.touch,
                            else => unreachable,
                        };
                        const input = server_objects.namespace.lookupHandle(input_id) orelse return error.Stale;
                        // Each fanout and its core event must fit in an empty
                        // TX queue. Bound admission, not event delivery, so a
                        // client cannot create a permanently blocked head.
                        if ((self.count(peer, input) + 1) * 20 + 32 > actor.transmit.byte_budget)
                            return try noMemory(actor);
                        const slot = self.slots.acquire() catch return try noMemory(actor);
                        errdefer self.slots.release(slot);
                        slot.peer = peer;
                        slot.input = input;
                        const admitted = try switch (tag) {
                            .get_keyboard_timestamps => Manager.admit_get_keyboard_timestamps(server_objects, decoded.handle, payload, .{ .id = slot }),
                            .get_pointer_timestamps => Manager.admit_get_pointer_timestamps(server_objects, decoded.handle, payload, .{ .id = slot }),
                            .get_touch_timestamps => Manager.admit_get_touch_timestamps(server_objects, decoded.handle, payload, .{ .id = slot }),
                            else => unreachable,
                        };
                        slot.resource = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Timestamps.info) {
                const slot = self.slots.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(slot.peer, peer) or slot.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Timestamps, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Timestamps.info) {
                const slot = self.slots.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.slots.release(slot);
                return true;
            }
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        /// Resource release and capability loss are permanent for an existing
        /// subscription, even if the object ID or capability is later reused.
        pub fn invalidate(self: *Self, peer: wayring.io_uring.Peer, input: objects.Handle) void {
            for (self.slots.entries.items) |slot| {
                if (matches(slot, peer, input)) slot.input = null;
            }
        }

        pub fn send(self: *Self, comptime Interface: type, queue: *wayring.tx.Queue, peer: wayring.io_uring.Peer, input: objects.Handle, time_usec: ?u64, event: Interface.Event) !void {
            if (time_usec) |usec| {
                const timestamp: Timestamps.Event = .{ .timestamp = .{
                    .tv_sec_hi = @intCast((usec / 1_000_000) >> 32),
                    .tv_sec_lo = @truncate(usec / 1_000_000),
                    .tv_nsec = @intCast((usec % 1_000_000) * 1000),
                } };
                // No descriptors or intervening reactor operations: preflight
                // makes the entire fanout + core event atomic under backpressure.
                try queue.ensureCapacity(self.count(peer, input) * (try Timestamps.eventSize(timestamp)) + try Interface.eventSize(event), 0);
                for (self.slots.entries.items) |slot| {
                    if (matches(slot, peer, input)) try Timestamps.encodeEvent(queue, slot.resource.id, timestamp);
                }
            }
            try Interface.encodeEvent(queue, input.id, event);
        }

        fn count(self: *Self, peer: wayring.io_uring.Peer, input: objects.Handle) usize {
            var result: usize = 0;
            for (self.slots.entries.items) |slot| result += @intFromBool(matches(slot, peer, input));
            return result;
        }

        fn matches(slot: *const Slot, peer: wayring.io_uring.Peer, input: objects.Handle) bool {
            return slot.header.active and std.meta.eql(slot.peer, peer) and slot.input != null and std.meta.eql(slot.input.?, input);
        }

        fn noMemory(actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
    };
}

test "seat: input timestamps preserve boundaries and atomically fan out under backpressure" {
    const protocol = @import("core_protocol");
    const Pointer = protocol.wl_pointer;
    const Timestamps = protocol.zwp_input_timestamps_v1;
    var adapter = try Adapter(protocol).init(std.testing.allocator);
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 7 };
    const input: objects.Handle = .{ .id = 3, .generation = 2 };
    for (0..2) |i| {
        const slot = try adapter.slots.acquire();
        slot.peer = peer;
        slot.input = input;
        slot.resource = .{ .id = @intCast(4 + i), .generation = 1 };
    }
    // A different peer with an identical object ID and generation is isolated.
    const foreign = try adapter.slots.acquire();
    foreign.peer = .{ .slot = peer.slot, .generation = peer.generation + 1 };
    foreign.input = input;
    foreign.resource = .{ .id = 6, .generation = 1 };
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 80, &descriptors, 0);
    defer queue.deinit();
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    var fd_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const cases = [_]struct { usec: u64, hi: u32, lo: u32, nsec: u32, ms: u32 }{
        .{ .usec = 0, .hi = 0, .lo = 0, .nsec = 0, .ms = 0 },
        .{ .usec = 999, .hi = 0, .lo = 0, .nsec = 999000, .ms = 0 },
        .{ .usec = 1000, .hi = 0, .lo = 0, .nsec = 1000000, .ms = 1 },
        .{ .usec = 999999, .hi = 0, .lo = 0, .nsec = 999999000, .ms = 999 },
        .{ .usec = 1000000, .hi = 0, .lo = 1, .nsec = 0, .ms = 1000 },
        .{ .usec = 4294967295999, .hi = 0, .lo = 4294967, .nsec = 295999000, .ms = 4294967295 },
        .{ .usec = 4294967296000, .hi = 0, .lo = 4294967, .nsec = 296000000, .ms = 0 },
        .{ .usec = 4294967295999999, .hi = 0, .lo = 4294967295, .nsec = 999999000, .ms = 4294967295 },
        .{ .usec = 4294967296000000, .hi = 1, .lo = 0, .nsec = 0, .ms = 0 },
        .{ .usec = 4294967301123456, .hi = 1, .lo = 5, .nsec = 123456000, .ms = 5123 },
        .{ .usec = 18446744073709551615, .hi = 4294, .lo = 4154504685, .nsec = 551615000, .ms = 1271310319 },
    };
    for (cases) |c| {
        const event: Pointer.Event = .{ .motion = .{ .time = c.ms, .surface_x = -17, .surface_y = 33 } };
        // 24 bytes of unrelated output leave only 56 bytes for a 60-byte
        // timestamp/timestamp/motion group: even its first timestamp must wait.
        try Pointer.encodeEvent(&queue, input.id, .{ .frame = .{} });
        try Pointer.encodeEvent(&queue, input.id, .{ .frame = .{} });
        try Pointer.encodeEvent(&queue, input.id, .{ .frame = .{} });
        try std.testing.expectError(error.ByteBudgetExceeded, adapter.send(Pointer, &queue, peer, input, c.usec, event));
        try std.testing.expectEqual(@as(usize, 24), queue.queuedBytes());
        var snapshot = try queue.snapshot(&fd_scratch, &control);
        try queue.begin(snapshot);
        try queue.complete(snapshot.byteCount());
        try adapter.send(Pointer, &queue, peer, input, c.usec, event);
        snapshot = try queue.snapshot(&fd_scratch, &control);
        var bytes = snapshot.first;
        for (0..2) |i| {
            const message = (try wayring.wire.Message.decode(bytes)).?;
            try std.testing.expectEqual(@as(u32, @intCast(4 + i)), message.header.object_id);
            const timestamp = (try Timestamps.decodeEvent(message, &fds)).timestamp;
            try std.testing.expectEqual(c.hi, timestamp.tv_sec_hi);
            try std.testing.expectEqual(c.lo, timestamp.tv_sec_lo);
            try std.testing.expectEqual(c.nsec, timestamp.tv_nsec);
            bytes = bytes[message.header.size..];
        }
        const message = (try wayring.wire.Message.decode(bytes)).?;
        try std.testing.expectEqual(input.id, message.header.object_id);
        const motion = (try Pointer.decodeEvent(message, &fds)).motion;
        try std.testing.expectEqual(c.ms, motion.time);
        try std.testing.expectEqual(@as(i32, -17), motion.surface_x);
        try std.testing.expectEqual(@as(i32, 33), motion.surface_y);
        try std.testing.expectEqual(@as(usize, message.header.size), bytes.len);
        try queue.begin(snapshot);
        try queue.complete(snapshot.byteCount());
    }
    // Null means no meaningful timestamp (synthetic release), not time zero.
    try adapter.send(Pointer, &queue, peer, input, null, .{ .button = .{ .serial = 9, .time = 0, .button = 272, .state = .released } });
    try std.testing.expectEqual(@as(usize, 24), queue.queuedBytes());
    adapter.invalidate(peer, input);
    try std.testing.expectEqual(@as(usize, 0), adapter.count(peer, input));
    try std.testing.expectEqual(@as(usize, 1), adapter.count(foreign.peer, input));
    try std.testing.expectEqual(@as(usize, 0), adapter.count(peer, .{ .id = input.id, .generation = input.generation + 1 }));
}
