//! Bounded relative-pointer-v1 ownership and motion publication.
//!
//! Relative motion follows the focus of the associated wl_pointer. Events
//! retain their original microsecond timestamp and unclipped normalized delta;
//! Ouro currently has no separate unaccelerated input stream, so the same
//! normalized delta is reported for both protocol fields.

const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 16,
    outbound_capacity: usize = 64,
    global_version: u32 = 1,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none or
            config.outbound_capacity == 0 or config.outbound_capacity >= none or
            config.global_version != 1)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_relative_pointer_manager_v1;
        const RelativePointer = protocol.zwp_relative_pointer_v1;

        const Id = packed struct { index: u32, generation: u32 };
        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            pointer: Seat.PointerId = undefined,
        };
        const Motion = struct {
            relative: Id,
            time_usec: u64,
            dx: i32,
            dy: i32,
        };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            motion: Motion = undefined,
        };

        allocator: std.mem.Allocator,
        seat: *Seat,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        slots: []Slot,
        outbound: []Outbound,
        outbound_len: usize = 0,
        free_head: u32 = 0,
        next_sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, seat: *Seat, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const slots = try allocator.alloc(Slot, config.resource_capacity);
            errdefer allocator.free(slots);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            for (slots, 0..) |*slot, slot_index| slot.* = .{
                .next_free = if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else none,
            };
            @memset(outbound, .{});
            return .{
                .allocator = allocator,
                .seat = seat,
                .global_version = config.global_version,
                .slots = slots,
                .outbound = outbound,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Manager.info,
                self.global_version,
                self,
                bind,
            );
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return self.requestOn(actor, server_objects, peer, target, message, fds);
        }

        pub fn requestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
                return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_relative_pointer => |payload| {
                        const pointer = self.seat.pointerIdOn(server_objects, payload.pointer) catch
                            return try self.protocolError(actor, decoded.handle.id, "invalid wl_pointer");
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.pointer = pointer;
                        const admitted = Manager.admit_get_relative_pointer(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .id = slot },
                        ) catch |err| {
                            self.release(self.slotIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &RelativePointer.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(
                    RelativePointer,
                    server_objects,
                    message,
                    fds,
                );
                switch (decoded.value) {
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn consume(self: *Self, event: input.Event) !void {
            const motion = switch (event) {
                .pointer_motion => |value| value,
                else => return,
            };
            var count: usize = 0;
            for (self.slots) |slot|
                count += @intFromBool(slot.active and self.seat.pointerFocused(slot.pointer));
            if (self.outboundFree() < count) return error.Exhausted;
            const dx = fixed(motion.dx);
            const dy = fixed(motion.dy);
            for (self.slots) |*slot| {
                if (!slot.active or !self.seat.pointerFocused(slot.pointer)) continue;
                self.enqueue(slot.peer, .{
                    .relative = self.slotId(slot),
                    .time_usec = motion.time_usec,
                    .dx = dx,
                    .dy = dy,
                }) catch unreachable;
            }
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (self.outbound_len == 0) return completed;
            while (self.oldest(peer)) |outbound| {
                const slot = self.resolve(outbound.motion.relative) catch {
                    outbound.active = false;
                    self.outbound_len -= 1;
                    completed += 1;
                    continue;
                };
                const timestamp = outbound.motion.time_usec;
                wayring.server.sendEvent(
                    protocol,
                    RelativePointer,
                    server_objects,
                    queue,
                    slot.resource,
                    .{ .relative_motion = .{
                        .utime_hi = @truncate(timestamp >> 32),
                        .utime_lo = @truncate(timestamp),
                        .dx = outbound.motion.dx,
                        .dy = outbound.motion.dy,
                        .dx_unaccel = outbound.motion.dx,
                        .dy_unaccel = outbound.motion.dy,
                    } },
                ) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                outbound.active = false;
                self.outbound_len -= 1;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.outbound_len == 0) return false;
            for (self.outbound) |slot|
                if (slot.active and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &RelativePointer.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                const id = self.slotId(slot);
                for (self.outbound) |*outbound| {
                    if (outbound.active and std.meta.eql(outbound.motion.relative, id)) {
                        outbound.active = false;
                        self.outbound_len -= 1;
                    }
                }
                self.release(id.index);
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const index = self.free_head;
            const slot = &self.slots[index];
            self.free_head = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation };
            return slot;
        }

        fn release(self: *Self, index: u32) void {
            const slot = &self.slots[index];
            if (!slot.active) return;
            const generation = slot.generation +% 1;
            slot.* = .{
                .generation = if (generation == 0) 1 else generation,
                .next_free = self.free_head,
            };
            self.free_head = index;
        }

        fn resolve(self: *Self, id: Id) !*Slot {
            if (id.index >= self.slots.len) return error.Stale;
            const slot = &self.slots[id.index];
            if (!slot.active or slot.generation != id.generation) return error.Stale;
            return slot;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(self.slots.ptr);
            const size = std.math.mul(usize, self.slots.len, @sizeOf(Slot)) catch return null;
            const end = std.math.add(usize, start, size) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
            const slot = &self.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active and @intFromPtr(slot) == address) slot else null;
        }

        fn slotId(self: *const Self, slot: *const Slot) Id {
            return .{ .index = self.slotIndex(slot), .generation = slot.generation };
        }

        fn slotIndex(self: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }

        fn enqueue(self: *Self, peer: wayring.io_uring.Peer, motion: Motion) !void {
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .sequence = self.next_sequence,
                    .peer = peer,
                    .motion = motion,
                };
                self.next_sequence +%= 1;
                self.outbound_len += 1;
                return;
            };
            return error.Exhausted;
        }

        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Outbound {
            var result: ?*Outbound = null;
            for (self.outbound) |*slot| if (slot.active and samePeer(slot.peer, peer)) {
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            };
            return result;
        }

        fn outboundFree(self: *const Self) usize {
            return self.outbound.len - self.outbound_len;
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, message);
            return .stop;
        }

        fn failure(
            self: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return self.protocolError(actor, id, @errorName(cause));
        }
    };
}

fn fixed(value: f64) i32 {
    if (!std.math.isFinite(value)) return 0;
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(scaled);
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "relative pointer: focused resources retain exact unclipped motion" {
    const protocol = @import("core_protocol");
    const FakeSeat = struct {
        pub const PointerId = struct { index: u32, generation: u32 };
        focused: ?PointerId = null,

        pub fn pointerFocused(self: *@This(), id: PointerId) bool {
            return self.focused != null and std.meta.eql(self.focused.?, id);
        }
    };
    const TestAdapter = Adapter(protocol, FakeSeat);
    var seat: FakeSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .resource_capacity = 2,
        .outbound_capacity = 1,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const focused = try adapter.acquire();
    focused.peer = .{ .slot = 1, .generation = 2 };
    focused.pointer = .{ .index = 3, .generation = 4 };
    focused.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_relative_pointer_v1.info,
        1,
        focused,
    );
    const unfocused = try adapter.acquire();
    unfocused.peer = focused.peer;
    unfocused.pointer = .{ .index = 5, .generation = 6 };
    seat.focused = focused.pointer;

    try adapter.consume(.{ .pointer_motion = .{
        .device = .{ .slot = 0, .generation = 1, .seat_generation = 1 },
        .time_usec = 0x123456789,
        .dx = 1.5,
        .dy = -2.25,
    } });

    const motion = adapter.oldest(focused.peer).?.motion;
    try std.testing.expectEqual(adapter.slotId(focused), motion.relative);
    try std.testing.expectEqual(@as(u64, 0x123456789), motion.time_usec);
    try std.testing.expectEqual(@as(i32, 384), motion.dx);
    try std.testing.expectEqual(@as(i32, -576), motion.dy);
    try std.testing.expectError(error.Exhausted, adapter.consume(.{ .pointer_motion = .{
        .device = .{ .slot = 0, .generation = 1, .seat_generation = 1 },
        .time_usec = 2,
        .dx = 1,
        .dy = 1,
    } }));

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 128, &descriptors, 1);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(focused.peer, &server_objects, &output),
    );
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    const relative = (try protocol.zwp_relative_pointer_v1.decodeEvent(message, &fds)).relative_motion;
    try std.testing.expectEqual(@as(u32, 1), relative.utime_hi);
    try std.testing.expectEqual(@as(u32, 0x23456789), relative.utime_lo);
    try std.testing.expectEqual(@as(i32, 384), relative.dx);
    try std.testing.expectEqual(@as(i32, -576), relative.dy_unaccel);

    seat.focused = null;
    try adapter.consume(.{ .pointer_motion = .{
        .device = .{ .slot = 0, .generation = 1, .seat_generation = 1 },
        .time_usec = 3,
        .dx = 4,
        .dy = 5,
    } });
    try std.testing.expect(!adapter.pendingOutbound(focused.peer));
}
