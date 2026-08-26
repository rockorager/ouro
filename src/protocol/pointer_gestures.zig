//! Standalone, allocation-free-after-init pointer-gestures-unstable-v1 adapter.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const PointerId = packed struct { index: u32, generation: u32 };

pub const PointerValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) ?PointerId,

    pub fn validate(self: PointerValidator, peer: wayring.io_uring.Peer, wire_id: u32) ?PointerId {
        return self.validateFn(self.context, peer, wire_id);
    }
};

pub const Config = struct {
    manager_capacity: usize = 8,
    gesture_capacity: usize = 32,
    outbound_capacity: usize = 128,
    global_version: u32 = 3,

    fn validate(self: Config) !void {
        if (self.manager_capacity == 0 or self.manager_capacity >= none or
            self.gesture_capacity == 0 or self.gesture_capacity >= none or
            self.outbound_capacity == 0 or self.outbound_capacity >= none or
            self.global_version == 0 or self.global_version > 3)
            return error.InvalidConfig;
    }
};

pub const Kind = enum { swipe, pinch, hold };
pub const Fixed = struct { dx: i32, dy: i32 };

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_pointer_gestures_v1;
        const Swipe = protocol.zwp_pointer_gesture_swipe_v1;
        const Pinch = protocol.zwp_pointer_gesture_pinch_v1;
        const Hold = protocol.zwp_pointer_gesture_hold_v1;
        const Id = packed struct { index: u32, generation: u32 };

        const ManagerSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        const Slot = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            pointer: PointerId = undefined,
            kind: Kind = .swipe,
            sequence_active: bool = false,
        };
        const Event = union(enum) {
            begin: struct { serial: u32, time: u32, surface: u32, fingers: u32 },
            update: struct { time: u32, dx: i32, dy: i32, scale: i32, rotation: i32 },
            end: struct { serial: u32, time: u32, cancelled: i32 },
        };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            gesture: Id = undefined,
            event: Event = undefined,
        };

        allocator: std.mem.Allocator,
        validator: PointerValidator,
        managers: []ManagerSlot,
        slots: []Slot,
        outbound: []Outbound,
        manager_free: u32 = 0,
        free_head: u32 = 0,
        outbound_len: usize = 0,
        next_sequence: u64 = 1,
        global_version: u32,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, validator: PointerValidator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const slots = try allocator.alloc(Slot, config.gesture_capacity);
            errdefer allocator.free(slots);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            for (managers, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < managers.len) @intCast(i + 1) else none,
            };
            for (slots, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none,
            };
            @memset(outbound, .{});
            return .{ .allocator = allocator, .validator = validator, .managers = managers, .slots = slots, .outbound = outbound, .global_version = config.global_version };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.slots);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, self.global_version, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (self.manager_free == none) return error.OutOfMemory;
            const index = self.manager_free;
            const slot = &self.managers[index];
            self.manager_free = slot.next_free;
            slot.* = .{ .active = true, .resource = binding.resource, .peer = binding.peer };
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managerFromObject(target.object) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .release => {},
                    .get_swipe_gesture => |payload| try self.admit(actor, server_objects, peer, decoded.handle, payload, .swipe),
                    .get_pinch_gesture => |payload| try self.admit(actor, server_objects, peer, decoded.handle, payload, .pinch),
                    .get_hold_gesture => |payload| try self.admit(actor, server_objects, peer, decoded.handle, payload, .hold),
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            const slot = self.slotFromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            if (slot.kind == .swipe and target.object.interface == &Swipe.info) {
                const decoded = try wayring.server.decodeRequest(Swipe, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (slot.kind == .pinch and target.object.interface == &Pinch.info) {
                const decoded = try wayring.server.decodeRequest(Pinch, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (slot.kind == .hold and target.object.interface == &Hold.info) {
                const decoded = try wayring.server.decodeRequest(Hold, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn admit(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, manager: objects.Handle, payload: anytype, kind: Kind) !void {
            const pointer = self.validator.validate(peer, payload.pointer) orelse
                return self.postProtocolError(actor, manager.id, "invalid wl_pointer");
            for (self.slots) |slot| if (slot.active and slot.kind == kind and
                samePeer(slot.peer, peer) and std.meta.eql(slot.pointer, pointer))
                return self.postProtocolError(actor, manager.id, "gesture already exists for wl_pointer");
            const slot = self.acquire() catch return self.postNoMemory(actor);
            slot.peer = peer;
            slot.pointer = pointer;
            slot.kind = kind;
            if (kind == .swipe) {
                const admitted = Manager.admit_get_swipe_gesture(server_objects, manager, payload, .{ .id = slot }) catch |err| {
                    self.release(self.slotIndex(slot));
                    return self.postProtocolError(actor, manager.id, @errorName(err));
                };
                slot.resource = admitted.id;
            } else if (kind == .pinch) {
                const admitted = Manager.admit_get_pinch_gesture(server_objects, manager, payload, .{ .id = slot }) catch |err| {
                    self.release(self.slotIndex(slot));
                    return self.postProtocolError(actor, manager.id, @errorName(err));
                };
                slot.resource = admitted.id;
            } else {
                const admitted = Manager.admit_get_hold_gesture(server_objects, manager, payload, .{ .id = slot }) catch |err| {
                    self.release(self.slotIndex(slot));
                    return self.postProtocolError(actor, manager.id, @errorName(err));
                };
                slot.resource = admitted.id;
            }
        }

        pub fn beginSwipe(self: *Self, pointer: PointerId, serial: u32, time: u32, surface: u32, fingers: u32) !void {
            return self.begin(.swipe, pointer, serial, time, surface, fingers);
        }
        pub fn beginPinch(self: *Self, pointer: PointerId, serial: u32, time: u32, surface: u32, fingers: u32) !void {
            return self.begin(.pinch, pointer, serial, time, surface, fingers);
        }
        pub fn beginHold(self: *Self, pointer: PointerId, serial: u32, time: u32, surface: u32, fingers: u32) !void {
            return self.begin(.hold, pointer, serial, time, surface, fingers);
        }
        fn begin(self: *Self, kind: Kind, pointer: PointerId, serial: u32, time: u32, surface: u32, fingers: u32) !void {
            if (surface == 0 or fingers == 0) return error.InvalidState;
            var count: usize = 0;
            for (self.slots) |slot| if (slot.active and std.meta.eql(slot.pointer, pointer)) {
                if (slot.sequence_active) return error.InvalidState;
                count += @intFromBool(slot.kind == kind);
            };
            try self.prepare(count);
            for (self.slots) |*slot| if (slot.active and slot.kind == kind and std.meta.eql(slot.pointer, pointer)) {
                self.enqueue(slot, .{ .begin = .{ .serial = serial, .time = time, .surface = surface, .fingers = fingers } }) catch unreachable;
                slot.sequence_active = true;
            };
        }

        pub fn updateSwipe(self: *Self, pointer: PointerId, time: u32, delta: Fixed) !void {
            return self.update(.swipe, pointer, time, delta, 0, 0);
        }
        pub fn updatePinch(self: *Self, pointer: PointerId, time: u32, delta: Fixed, scale: i32, rotation: i32) !void {
            return self.update(.pinch, pointer, time, delta, scale, rotation);
        }
        fn update(self: *Self, kind: Kind, pointer: PointerId, time: u32, delta: Fixed, scale: i32, rotation: i32) !void {
            var count: usize = 0;
            for (self.slots) |slot| count += @intFromBool(slot.active and slot.sequence_active and slot.kind == kind and std.meta.eql(slot.pointer, pointer));
            if (count == 0) return;
            try self.prepare(count);
            for (self.slots) |*slot| if (slot.active and slot.sequence_active and slot.kind == kind and std.meta.eql(slot.pointer, pointer))
                self.enqueue(slot, .{ .update = .{ .time = time, .dx = delta.dx, .dy = delta.dy, .scale = scale, .rotation = rotation } }) catch unreachable;
        }

        pub fn endSwipe(self: *Self, pointer: PointerId, serial: u32, time: u32, cancelled: bool) !void {
            return self.end(.swipe, pointer, serial, time, cancelled);
        }
        pub fn endPinch(self: *Self, pointer: PointerId, serial: u32, time: u32, cancelled: bool) !void {
            return self.end(.pinch, pointer, serial, time, cancelled);
        }
        pub fn endHold(self: *Self, pointer: PointerId, serial: u32, time: u32, cancelled: bool) !void {
            return self.end(.hold, pointer, serial, time, cancelled);
        }
        fn end(self: *Self, kind: Kind, pointer: PointerId, serial: u32, time: u32, cancelled: bool) !void {
            var count: usize = 0;
            for (self.slots) |slot| count += @intFromBool(slot.active and slot.sequence_active and slot.kind == kind and std.meta.eql(slot.pointer, pointer));
            if (count == 0) return;
            try self.prepare(count);
            for (self.slots) |*slot| if (slot.active and slot.sequence_active and slot.kind == kind and std.meta.eql(slot.pointer, pointer)) {
                self.enqueue(slot, .{ .end = .{ .serial = serial, .time = time, .cancelled = @intFromBool(cancelled) } }) catch unreachable;
                slot.sequence_active = false;
            };
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            while (self.oldest(peer)) |item| {
                const slot = self.resolve(item.gesture) catch {
                    self.dropOutbound(item);
                    completed += 1;
                    continue;
                };
                self.send(server_objects, queue, slot, item.event) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                self.dropOutbound(item);
                completed += 1;
            }
            return completed;
        }

        fn send(_: *Self, server_objects: anytype, queue: *wayring.tx.Queue, slot: *Slot, event: Event) !void {
            switch (slot.kind) {
                .swipe => switch (event) {
                    .begin => |e| try wayring.server.sendEvent(protocol, Swipe, server_objects, queue, slot.resource, .{ .begin = e }),
                    .update => |e| try wayring.server.sendEvent(protocol, Swipe, server_objects, queue, slot.resource, .{ .update = .{ .time = e.time, .dx = e.dx, .dy = e.dy } }),
                    .end => |e| try wayring.server.sendEvent(protocol, Swipe, server_objects, queue, slot.resource, .{ .end = e }),
                },
                .pinch => switch (event) {
                    .begin => |e| try wayring.server.sendEvent(protocol, Pinch, server_objects, queue, slot.resource, .{ .begin = e }),
                    .update => |e| try wayring.server.sendEvent(protocol, Pinch, server_objects, queue, slot.resource, .{ .update = e }),
                    .end => |e| try wayring.server.sendEvent(protocol, Pinch, server_objects, queue, slot.resource, .{ .end = e }),
                },
                .hold => switch (event) {
                    .begin => |e| try wayring.server.sendEvent(protocol, Hold, server_objects, queue, slot.resource, .{ .begin = e }),
                    .end => |e| try wayring.server.sendEvent(protocol, Hold, server_objects, queue, slot.resource, .{ .end = e }),
                    .update => unreachable,
                },
            }
        }

        pub fn pendingOutboundOn(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |item| if (item.active and samePeer(item.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (self.slotFromObject(&object)) |slot| if (std.meta.eql(slot.resource, handle)) {
                self.purge(self.slotId(slot));
                self.release(self.slotIndex(slot));
                return true;
            };
            if (self.managerFromObject(&object)) |slot| if (std.meta.eql(slot.resource, handle)) {
                const i: u32 = @intCast((@intFromPtr(slot) - @intFromPtr(self.managers.ptr)) / @sizeOf(ManagerSlot));
                slot.* = .{ .next_free = self.manager_free };
                self.manager_free = i;
                return true;
            };
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots, 0..) |*slot, i| if (slot.active and samePeer(slot.peer, peer)) {
                self.purge(self.slotId(slot));
                self.release(@intCast(i));
            };
            for (self.managers, 0..) |*slot, i| if (slot.active and samePeer(slot.peer, peer)) {
                slot.* = .{ .next_free = self.manager_free };
                self.manager_free = @intCast(i);
            };
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const i = self.free_head;
            const slot = &self.slots[i];
            self.free_head = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation };
            return slot;
        }
        fn release(self: *Self, i: u32) void {
            const slot = &self.slots[i];
            if (!slot.active) return;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.* = .{ .retired = true, .generation = slot.generation };
                return;
            }
            slot.* = .{ .generation = slot.generation + 1, .next_free = self.free_head };
            self.free_head = i;
        }
        fn prepare(self: *Self, count: usize) !void {
            if (count > self.outbound.len - self.outbound_len) return error.Exhausted;
            if (count != 0 and self.next_sequence > std.math.maxInt(u64) - count) {
                if (self.outbound_len != 0) return error.Exhausted;
                self.next_sequence = 1;
            }
        }
        fn enqueue(self: *Self, slot: *Slot, event: Event) !void {
            try self.prepare(1);
            for (self.outbound) |*item| if (!item.active) {
                item.* = .{ .active = true, .sequence = self.next_sequence, .peer = slot.peer, .gesture = self.slotId(slot), .event = event };
                self.next_sequence += 1;
                self.outbound_len += 1;
                return;
            };
            unreachable;
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Outbound {
            var result: ?*Outbound = null;
            for (self.outbound) |*item| {
                if (item.active and samePeer(item.peer, peer) and
                    (result == null or item.sequence < result.?.sequence))
                    result = item;
            }
            return result;
        }
        fn dropOutbound(self: *Self, item: *Outbound) void {
            item.active = false;
            self.outbound_len -= 1;
        }
        fn purge(self: *Self, id: Id) void {
            for (self.outbound) |*item| if (item.active and std.meta.eql(item.gesture, id)) self.dropOutbound(item);
        }
        fn resolve(self: *Self, id: Id) !*Slot {
            if (id.index >= self.slots.len) return error.Stale;
            const slot = &self.slots[id.index];
            if (!slot.active or slot.generation != id.generation) return error.Stale;
            return slot;
        }
        fn slotId(self: *const Self, slot: *const Slot) Id {
            return .{ .index = self.slotIndex(slot), .generation = slot.generation };
        }
        fn slotIndex(self: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }
        fn slotFromObject(self: *Self, object: *const objects.Object) ?*Slot {
            return fromContext(Slot, self.slots, object.context);
        }
        fn managerFromObject(self: *Self, object: *const objects.Object) ?*ManagerSlot {
            return fromContext(ManagerSlot, self.managers, object.context);
        }
        fn postNoMemory(_: *Self, actor: *wayring.connection.Actor) !void {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
        }
        fn postProtocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !void {
            try Core.postError(actor, id, 0, message);
        }
    };
}

fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const size = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    const end = std.math.add(usize, start, size) catch return null;
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    return &slots[(address - start) / @sizeOf(T)];
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn acceptPointer(_: ?*anyopaque, _: wayring.io_uring.Peer, wire: u32) ?PointerId {
    return .{ .index = wire, .generation = 7 };
}

test "pointer gestures: bounded sequencing, fanout, cleanup, and retirement" {
    const protocol = @import("core_protocol");
    const A = Adapter(protocol);
    try std.testing.expectError(error.InvalidConfig, A.init(std.testing.allocator, .{ .validateFn = acceptPointer }, .{ .global_version = 4 }));
    var adapter = try A.init(std.testing.allocator, .{ .validateFn = acceptPointer }, .{ .gesture_capacity = 3, .outbound_capacity = 2 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const pointer: PointerId = .{ .index = 9, .generation = 7 };
    const first = try adapter.acquire();
    first.peer = peer;
    first.pointer = pointer;
    first.kind = .swipe;
    const other = try adapter.acquire();
    other.peer = peer;
    other.pointer = .{ .index = 10, .generation = 7 };
    other.kind = .swipe;

    try adapter.updateSwipe(pointer, 1, .{ .dx = 2, .dy = 3 });
    try adapter.beginSwipe(pointer, 4, 5, 6, 3);
    try std.testing.expect(first.sequence_active);
    try std.testing.expect(!other.sequence_active);
    try adapter.endSwipe(pointer, 7, 8, true);
    try std.testing.expect(!first.sequence_active);
    var saw_cancelled = false;
    for (adapter.outbound) |item| {
        if (!item.active) continue;
        switch (item.event) {
            .end => |event| saw_cancelled = event.cancelled == 1,
            else => {},
        }
    }
    try std.testing.expect(saw_cancelled);
    try adapter.endSwipe(pointer, 9, 10, false);
    try std.testing.expectError(error.Exhausted, adapter.beginSwipe(pointer, 11, 12, 13, 3));
    try std.testing.expect(!first.sequence_active);

    adapter.purge(adapter.slotId(first));
    const stale = adapter.slotId(first);
    adapter.release(adapter.slotIndex(first));
    const reused = try adapter.acquire();
    try std.testing.expect(stale.generation != reused.generation);
    reused.generation = std.math.maxInt(u32);
    adapter.release(adapter.slotIndex(reused));
    try std.testing.expect(reused.retired);
    adapter.disconnected(peer);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);
}
