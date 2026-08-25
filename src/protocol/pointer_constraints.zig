//! Protocol-neutral bounded pointer-constraint state.
//!
//! This owner deliberately remains unadvertised until the physical input path
//! can apply exact confinement. It establishes generation-safe lock/confine
//! lifetime, copied region state, surface-commit publication, and activation
//! events without claiming incomplete wire support.

const std = @import("std");
const wayring = @import("wayring");
const region = @import("../region.zig");
const objects = wayring.objects;

const none = std.math.maxInt(u32);

pub const Config = struct {
    constraint_capacity: usize = 16,
    region_operation_capacity: usize = 16,
    event_capacity: usize = 32,

    fn validate(config: Config) !void {
        inline for (.{
            config.constraint_capacity,
            config.region_operation_capacity,
            config.event_capacity,
        }) |capacity| if (capacity == 0 or capacity >= none) return error.InvalidConfig;
        const operations_per_slot = std.math.mul(
            usize,
            config.region_operation_capacity,
            2,
        ) catch return error.InvalidConfig;
        _ = std.math.mul(
            usize,
            config.constraint_capacity,
            operations_per_slot,
        ) catch return error.InvalidConfig;
    }
};

pub const WireConfig = struct {
    constraint_capacity: usize = 16,
    region_operation_capacity: usize = 16,
    event_capacity: usize = 32,
};

pub fn Store(comptime SurfaceId: type, comptime PointerId: type) type {
    return struct {
        const Self = @This();

        pub const ConstraintId = packed struct { index: u32, generation: u32 };
        pub const Kind = enum { locked, confined };
        pub const Lifetime = enum { oneshot, persistent };
        pub const Event = union(enum) {
            activated: struct { id: ConstraintId, kind: Kind },
            deactivated: struct { id: ConstraintId, kind: Kind },
        };
        pub const MotionPolicy = union(enum) {
            free,
            locked: ConstraintId,
            confined: ConstraintId,
        };
        pub const RegionSnapshot = struct {
            unrestricted: bool,
            operations: []const region.Operation,
        };

        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            kind: Kind = .locked,
            lifetime: Lifetime = .persistent,
            surface: SurfaceId = undefined,
            pointer: PointerId = undefined,
            engaged: bool = false,
            defunct: bool = false,
            current_region_null: bool = true,
            current_region_len: usize = 0,
            current_region: []region.Operation = &.{},
            pending_region_null: bool = true,
            pending_region_len: usize = 0,
            pending_region: []region.Operation = &.{},
            region_dirty: bool = false,
            current_hint: ?Point = null,
            pending_hint: ?Point = null,
            hint_dirty: bool = false,
        };

        pub const Point = struct { x: i32, y: i32 };

        allocator: std.mem.Allocator,
        slots: []Slot,
        region_storage: []region.Operation,
        events: []Event,
        region_capacity: usize,
        free_head: u32 = 0,
        event_head: usize = 0,
        event_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.constraint_capacity);
            errdefer allocator.free(slots);
            const operations_per_slot = try std.math.mul(
                usize,
                config.region_operation_capacity,
                2,
            );
            const region_storage = try allocator.alloc(
                region.Operation,
                try std.math.mul(
                    usize,
                    config.constraint_capacity,
                    operations_per_slot,
                ),
            );
            errdefer allocator.free(region_storage);
            const events = try allocator.alloc(Event, config.event_capacity);
            for (slots, 0..) |*slot, slot_index| {
                const offset = slot_index * operations_per_slot;
                slot.* = .{
                    .next_free = if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else none,
                    .current_region = region_storage[offset..][0..config.region_operation_capacity],
                    .pending_region = region_storage[offset + config.region_operation_capacity ..][0..config.region_operation_capacity],
                };
            }
            return .{
                .allocator = allocator,
                .slots = slots,
                .region_storage = region_storage,
                .events = events,
                .region_capacity = config.region_operation_capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.allocator.free(self.region_storage);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn create(
            self: *Self,
            kind: Kind,
            lifetime: Lifetime,
            surface: SurfaceId,
            pointer: PointerId,
            operations: ?[]const region.Operation,
        ) !ConstraintId {
            if (self.findSurface(surface) != null) return error.AlreadyConstrained;
            const slot = try self.acquire();
            errdefer self.release(self.slotIndex(slot));
            slot.kind = kind;
            slot.lifetime = lifetime;
            slot.surface = surface;
            slot.pointer = pointer;
            try self.copyPendingRegion(slot, operations);
            self.publishSlot(slot);
            return self.constraintId(slot);
        }

        pub fn destroy(self: *Self, constraint_id: ConstraintId) !void {
            _ = try self.resolve(constraint_id);
            self.discardEvents(constraint_id);
            self.release(constraint_id.index);
        }

        pub fn setRegion(
            self: *Self,
            constraint_id: ConstraintId,
            operations: ?[]const region.Operation,
        ) !void {
            const slot = try self.resolve(constraint_id);
            if (slot.defunct) return;
            try self.copyPendingRegion(slot, operations);
        }

        pub fn setCursorHint(self: *Self, constraint_id: ConstraintId, hint: Point) !void {
            const slot = try self.resolve(constraint_id);
            if (slot.kind != .locked) return error.NotLocked;
            if (slot.defunct) return;
            slot.pending_hint = hint;
            slot.hint_dirty = true;
        }

        pub fn commitSurface(self: *Self, surface: SurfaceId) void {
            for (self.slots) |*slot| {
                if (!slot.active or slot.defunct or !std.meta.eql(slot.surface, surface)) continue;
                self.publishSlot(slot);
            }
        }

        pub fn updateFocus(
            self: *Self,
            pointer: PointerId,
            surface: ?SurfaceId,
            point: Point,
        ) !void {
            var required_events: usize = 0;
            for (self.slots) |*slot| {
                if (!slot.active or !std.meta.eql(slot.pointer, pointer)) continue;
                const qualifies = !slot.defunct and surface != null and
                    std.meta.eql(slot.surface, surface.?) and self.containsSlot(slot, point);
                if (qualifies != slot.engaged) required_events += 1;
            }
            if (required_events > self.events.len - self.event_len) return error.Exhausted;

            for (self.slots) |*slot| {
                if (!slot.active or !std.meta.eql(slot.pointer, pointer)) continue;
                const qualifies = !slot.defunct and surface != null and
                    std.meta.eql(slot.surface, surface.?) and self.containsSlot(slot, point);
                if (qualifies == slot.engaged) continue;
                const constraint_id = self.constraintId(slot);
                if (qualifies) {
                    self.enqueueAssumeCapacity(.{ .activated = .{ .id = constraint_id, .kind = slot.kind } });
                    slot.engaged = true;
                } else {
                    self.enqueueAssumeCapacity(.{ .deactivated = .{ .id = constraint_id, .kind = slot.kind } });
                    slot.engaged = false;
                    if (slot.lifetime == .oneshot) slot.defunct = true;
                }
            }
        }

        pub fn motionPolicy(self: *Self, pointer: PointerId) MotionPolicy {
            for (self.slots) |*slot| {
                if (!slot.active or !slot.engaged or !std.meta.eql(slot.pointer, pointer)) continue;
                return switch (slot.kind) {
                    .locked => .{ .locked = self.constraintId(slot) },
                    .confined => .{ .confined = self.constraintId(slot) },
                };
            }
            return .free;
        }

        pub fn contains(self: *Self, constraint_id: ConstraintId, point: Point) !bool {
            return self.containsSlot(try self.resolve(constraint_id), point);
        }

        pub fn cursorHint(self: *Self, constraint_id: ConstraintId) !?Point {
            return (try self.resolve(constraint_id)).current_hint;
        }

        pub fn copyRegion(
            self: *Self,
            constraint_id: ConstraintId,
            destination: []region.Operation,
        ) !RegionSnapshot {
            const slot = try self.resolve(constraint_id);
            if (destination.len < slot.current_region_len) return error.Exhausted;
            @memcpy(
                destination[0..slot.current_region_len],
                slot.current_region[0..slot.current_region_len],
            );
            return .{
                .unrestricted = slot.current_region_null,
                .operations = destination[0..slot.current_region_len],
            };
        }

        pub fn popEvent(self: *Self) ?Event {
            const event = self.peekEvent() orelse return null;
            self.dropEvent();
            return event;
        }

        pub fn peekEvent(self: *const Self) ?Event {
            if (self.event_len == 0) return null;
            return self.events[self.event_head];
        }

        pub fn dropEvent(self: *Self) void {
            std.debug.assert(self.event_len != 0);
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_len -= 1;
        }

        pub fn pendingEvents(self: *const Self) bool {
            return self.event_len != 0;
        }

        pub fn surfaceRemoved(self: *Self, surface: SurfaceId) !void {
            var required_events: usize = 0;
            for (self.slots) |*slot| {
                if (slot.active and slot.engaged and std.meta.eql(slot.surface, surface)) {
                    required_events += 1;
                }
            }
            if (required_events > self.events.len - self.event_len) return error.Exhausted;

            for (self.slots) |*slot| {
                if (!slot.active or !std.meta.eql(slot.surface, surface)) continue;
                if (slot.engaged) self.enqueueAssumeCapacity(.{ .deactivated = .{
                    .id = self.constraintId(slot),
                    .kind = slot.kind,
                } });
                slot.engaged = false;
                slot.defunct = true;
            }
        }

        pub fn pointerRemoved(self: *Self, pointer: PointerId) !void {
            var required_events: usize = 0;
            for (self.slots) |*slot| {
                if (slot.active and slot.engaged and std.meta.eql(slot.pointer, pointer)) {
                    required_events += 1;
                }
            }
            if (required_events > self.events.len - self.event_len) return error.Exhausted;

            for (self.slots) |*slot| {
                if (!slot.active or !std.meta.eql(slot.pointer, pointer)) continue;
                if (slot.engaged) self.enqueueAssumeCapacity(.{ .deactivated = .{
                    .id = self.constraintId(slot),
                    .kind = slot.kind,
                } });
                slot.engaged = false;
                slot.defunct = true;
            }
        }

        fn copyPendingRegion(self: *Self, slot: *Slot, operations: ?[]const region.Operation) !void {
            if (operations) |source| {
                if (source.len > self.region_capacity) return error.Exhausted;
                @memcpy(slot.pending_region[0..source.len], source);
                slot.pending_region_len = source.len;
                slot.pending_region_null = false;
            } else {
                slot.pending_region_len = 0;
                slot.pending_region_null = true;
            }
            slot.region_dirty = true;
        }

        fn publishSlot(_: *Self, slot: *Slot) void {
            if (slot.region_dirty) {
                @memcpy(
                    slot.current_region[0..slot.pending_region_len],
                    slot.pending_region[0..slot.pending_region_len],
                );
                slot.current_region_len = slot.pending_region_len;
                slot.current_region_null = slot.pending_region_null;
                slot.region_dirty = false;
            }
            if (slot.hint_dirty) {
                slot.current_hint = slot.pending_hint;
                slot.hint_dirty = false;
            }
        }

        fn containsSlot(_: *Self, slot: *const Slot, point: Point) bool {
            if (slot.current_region_null) return true;
            var inside = false;
            for (slot.current_region[0..slot.current_region_len]) |operation| switch (operation) {
                .add => |rectangle| if (rectangleContains(rectangle, point)) {
                    inside = true;
                },
                .subtract => |rectangle| if (rectangleContains(rectangle, point)) {
                    inside = false;
                },
            };
            return inside;
        }

        fn enqueueAssumeCapacity(self: *Self, event: Event) void {
            std.debug.assert(self.event_len < self.events.len);
            const tail = (self.event_head + self.event_len) % self.events.len;
            self.events[tail] = event;
            self.event_len += 1;
        }

        fn discardEvents(self: *Self, constraint_id: ConstraintId) void {
            var retained: usize = 0;
            for (0..self.event_len) |offset| {
                const event = self.events[(self.event_head + offset) % self.events.len];
                const event_id = switch (event) {
                    inline else => |payload| payload.id,
                };
                if (std.meta.eql(event_id, constraint_id)) continue;
                self.events[(self.event_head + retained) % self.events.len] = event;
                retained += 1;
            }
            self.event_len = retained;
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const slot_index = self.free_head;
            const slot = &self.slots[slot_index];
            self.free_head = slot.next_free;
            const generation = slot.generation;
            const current_region = slot.current_region;
            const pending_region = slot.pending_region;
            slot.* = .{
                .active = true,
                .generation = generation,
                .current_region = current_region,
                .pending_region = pending_region,
            };
            return slot;
        }

        fn release(self: *Self, slot_index: u32) void {
            const slot = &self.slots[slot_index];
            if (!slot.active) return;
            const generation = slot.generation +% 1;
            const current_region = slot.current_region;
            const pending_region = slot.pending_region;
            slot.* = .{
                .generation = if (generation == 0) 1 else generation,
                .next_free = self.free_head,
                .current_region = current_region,
                .pending_region = pending_region,
            };
            self.free_head = slot_index;
        }

        fn resolve(self: *Self, constraint_id: ConstraintId) !*Slot {
            if (constraint_id.index >= self.slots.len) return error.StaleConstraint;
            const slot = &self.slots[constraint_id.index];
            if (!slot.active or slot.generation != constraint_id.generation) return error.StaleConstraint;
            return slot;
        }

        fn findSurface(self: *Self, surface: SurfaceId) ?*Slot {
            for (self.slots) |*slot|
                if (slot.active and std.meta.eql(slot.surface, surface)) return slot;
            return null;
        }

        fn constraintId(self: *const Self, slot: *const Slot) ConstraintId {
            return .{ .index = self.slotIndex(slot), .generation = slot.generation };
        }

        fn slotIndex(self: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }
    };
}

/// Owns decoded protocol resources around `Store` without advertising a
/// global. Runtime publication is intentionally deferred until the physical
/// motion path applies lock suppression and exact confinement.
pub fn Adapter(comptime protocol: type, comptime Core: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_pointer_constraints_v1;
        const LockedPointer = protocol.zwp_locked_pointer_v1;
        const ConfinedPointer = protocol.zwp_confined_pointer_v1;
        const State = Store(Core.SurfaceId, u8);

        pub const ConstraintId = State.ConstraintId;
        pub const MotionPolicy = State.MotionPolicy;
        pub const FocusPoint = struct { x: i32, y: i32 };

        const ResourceSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            constraint: ?ConstraintId = null,
        };

        allocator: std.mem.Allocator,
        core: *Core,
        seat: *Seat,
        state: State,
        resources: []ResourceSlot,
        region_scratch: []region.Operation,
        free_head: u32 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *Core,
            seat: *Seat,
            config: WireConfig,
        ) !Self {
            var state = try State.init(allocator, .{
                .constraint_capacity = config.constraint_capacity,
                .region_operation_capacity = config.region_operation_capacity,
                .event_capacity = config.event_capacity,
            });
            errdefer state.deinit();
            const resources = try allocator.alloc(ResourceSlot, config.constraint_capacity);
            errdefer allocator.free(resources);
            const region_scratch = try allocator.alloc(region.Operation, config.region_operation_capacity);
            for (resources, 0..) |*slot, slot_index| slot.* = .{
                .next_free = if (slot_index + 1 < resources.len) @intCast(slot_index + 1) else none,
            };
            return .{
                .allocator = allocator,
                .core = core,
                .seat = seat,
                .state = state,
                .resources = resources,
                .region_scratch = region_scratch,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.region_scratch);
            self.allocator.free(self.resources);
            self.state.deinit();
            self.* = undefined;
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
                    .lock_pointer => |payload| if (try self.createConstraint(
                        .locked,
                        actor,
                        server_objects,
                        peer,
                        decoded.handle,
                        payload,
                    )) |control| return control,
                    .confine_pointer => |payload| if (try self.createConstraint(
                        .confined,
                        actor,
                        server_objects,
                        peer,
                        decoded.handle,
                        payload,
                    )) |control| return control,
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &LockedPointer.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(LockedPointer, server_objects, message, fds);
                const constraint_id = slot.constraint orelse return null;
                switch (decoded.value) {
                    .destroy => {
                        try self.state.destroy(constraint_id);
                        slot.constraint = null;
                    },
                    .set_cursor_position_hint => |payload| try self.state.setCursorHint(
                        constraint_id,
                        .{ .x = payload.surface_x, .y = payload.surface_y },
                    ),
                    .set_region => |payload| if (try self.setRegion(
                        actor,
                        server_objects,
                        decoded.handle.id,
                        constraint_id,
                        payload.region,
                    )) |control| return control,
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &ConfinedPointer.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(ConfinedPointer, server_objects, message, fds);
                const constraint_id = slot.constraint orelse return null;
                switch (decoded.value) {
                    .destroy => {
                        try self.state.destroy(constraint_id);
                        slot.constraint = null;
                    },
                    .set_region => |payload| if (try self.setRegion(
                        actor,
                        server_objects,
                        decoded.handle.id,
                        constraint_id,
                        payload.region,
                    )) |control| return control,
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn surfaceCommitted(self: *Self, surface: Core.SurfaceId) void {
            self.state.commitSurface(surface);
        }

        pub fn surfaceRemoved(self: *Self, surface: Core.SurfaceId) !void {
            try self.state.surfaceRemoved(surface);
        }

        pub fn updateFocus(self: *Self, surface: ?Core.SurfaceId, point: FocusPoint) !void {
            try self.state.updateFocus(0, surface, .{
                .x = @divFloor(point.x, 256),
                .y = @divFloor(point.y, 256),
            });
        }

        pub fn motionPolicy(self: *Self) MotionPolicy {
            return self.state.motionPolicy(0);
        }

        pub fn copyRegion(
            self: *Self,
            constraint_id: ConstraintId,
            destination: []region.Operation,
        ) !State.RegionSnapshot {
            return self.state.copyRegion(constraint_id, destination);
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            while (self.state.peekEvent()) |event| {
                const event_id = switch (event) {
                    inline else => |payload| payload.id,
                };
                const slot = self.findConstraint(event_id) orelse {
                    self.state.dropEvent();
                    continue;
                };
                if (!samePeer(slot.peer, peer)) break;
                switch (event) {
                    .activated => |payload| switch (payload.kind) {
                        .locked => try self.sendConstraintEvent(
                            LockedPointer,
                            server_objects,
                            queue,
                            slot.resource,
                            .{ .locked = .{} },
                        ),
                        .confined => try self.sendConstraintEvent(
                            ConfinedPointer,
                            server_objects,
                            queue,
                            slot.resource,
                            .{ .confined = .{} },
                        ),
                    },
                    .deactivated => |payload| switch (payload.kind) {
                        .locked => try self.sendConstraintEvent(
                            LockedPointer,
                            server_objects,
                            queue,
                            slot.resource,
                            .{ .unlocked = .{} },
                        ),
                        .confined => try self.sendConstraintEvent(
                            ConfinedPointer,
                            server_objects,
                            queue,
                            slot.resource,
                            .{ .unconfined = .{} },
                        ),
                    },
                }
                self.state.dropEvent();
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            const event = self.state.peekEvent() orelse return false;
            const event_id = switch (event) {
                inline else => |payload| payload.id,
            };
            for (self.resources) |slot|
                if (slot.active and slot.constraint != null and
                    std.meta.eql(slot.constraint.?, event_id)) return samePeer(slot.peer, peer);
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &LockedPointer.info or object.interface == &ConfinedPointer.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                if (slot.constraint) |constraint_id| self.state.destroy(constraint_id) catch {};
                self.release(self.slotIndex(slot));
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn createConstraint(
            self: *Self,
            comptime kind: State.Kind,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            manager: objects.Handle,
            payload: anytype,
        ) !?wayring.dispatch.Control {
            const lifetime: State.Lifetime = if (payload.lifetime.value == Manager.lifetime.oneshot.value)
                .oneshot
            else if (payload.lifetime.value == Manager.lifetime.persistent.value)
                .persistent
            else
                return try self.protocolError(actor, manager.id, 0, "invalid constraint lifetime");
            const surface = self.core.surfaceIdOn(server_objects, payload.surface) catch
                return try self.protocolError(actor, manager.id, 0, "invalid constraint surface");
            _ = self.seat.pointerIdOn(server_objects, payload.pointer) catch
                return try self.protocolError(actor, manager.id, 0, "invalid constraint pointer");
            const operations: ?[]const region.Operation = if (payload.region) |region_id|
                self.core.copyRegionOn(server_objects, region_id, self.region_scratch) catch |cause| switch (cause) {
                    error.Exhausted => return try self.noMemory(actor),
                    else => return try self.protocolError(actor, manager.id, 0, "invalid constraint region"),
                }
            else
                null;
            const slot = self.acquire() catch return try self.noMemory(actor);
            errdefer self.release(self.slotIndex(slot));
            const constraint_id = self.state.create(kind, lifetime, surface, 0, operations) catch |cause| switch (cause) {
                error.AlreadyConstrained => return try self.protocolError(
                    actor,
                    manager.id,
                    Manager.@"error".already_constrained.value,
                    "surface already has a pointer constraint",
                ),
                error.Exhausted => return try self.noMemory(actor),
                else => return cause,
            };
            errdefer self.state.destroy(constraint_id) catch {};
            const admitted = if (kind == .locked)
                try Manager.admit_lock_pointer(server_objects, manager, payload, .{ .id = slot })
            else
                try Manager.admit_confine_pointer(server_objects, manager, payload, .{ .id = slot });
            slot.peer = peer;
            slot.constraint = constraint_id;
            slot.resource = admitted.id;
            return null;
        }

        fn setRegion(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            resource_id: u32,
            constraint_id: ConstraintId,
            region_id: ?u32,
        ) !?wayring.dispatch.Control {
            const operations: ?[]const region.Operation = if (region_id) |value|
                self.core.copyRegionOn(server_objects, value, self.region_scratch) catch |cause| switch (cause) {
                    error.Exhausted => return try self.noMemory(actor),
                    else => return try self.protocolError(actor, resource_id, 0, "invalid constraint region"),
                }
            else
                null;
            self.state.setRegion(constraint_id, operations) catch |cause| switch (cause) {
                error.Exhausted => return try self.noMemory(actor),
                else => return cause,
            };
            return null;
        }

        fn sendConstraintEvent(
            _: *Self,
            comptime Interface: type,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            resource: objects.Handle,
            event: Interface.Event,
        ) !void {
            wayring.server.sendEvent(protocol, Interface, server_objects, queue, resource, event) catch |cause| switch (cause) {
                error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return error.Exhausted,
                else => return cause,
            };
        }

        fn acquire(self: *Self) !*ResourceSlot {
            if (self.free_head == none) return error.Exhausted;
            const slot_index = self.free_head;
            const slot = &self.resources[slot_index];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true, .generation = slot.generation };
            return slot;
        }

        fn release(self: *Self, slot_index: u32) void {
            const slot = &self.resources[slot_index];
            if (!slot.active) return;
            const generation = slot.generation +% 1;
            slot.* = .{
                .generation = if (generation == 0) 1 else generation,
                .next_free = self.free_head,
            };
            self.free_head = slot_index;
        }

        fn findConstraint(self: *Self, constraint_id: ConstraintId) ?*ResourceSlot {
            for (self.resources) |*slot|
                if (slot.active and slot.constraint != null and
                    std.meta.eql(slot.constraint.?, constraint_id)) return slot;
            return null;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*ResourceSlot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(self.resources.ptr);
            const size = std.math.mul(usize, self.resources.len, @sizeOf(ResourceSlot)) catch return null;
            const end = std.math.add(usize, start, size) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(ResourceSlot) != 0)
                return null;
            const slot = &self.resources[(address - start) / @sizeOf(ResourceSlot)];
            return if (slot.active and @intFromPtr(slot) == address) slot else null;
        }

        fn slotIndex(self: *const Self, slot: *const ResourceSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.resources.ptr)) / @sizeOf(ResourceSlot));
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(
            self: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try self.postProtocolError(actor, object_id, code, message);
            return .stop;
        }

        fn postProtocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            code: u32,
            message: []const u8,
        ) !void {
            try ProtocolCore.postError(actor, object_id, code, message);
        }
    };
}

fn rectangleContains(rectangle: region.Rectangle, point: anytype) bool {
    const right = @as(i64, rectangle.x) + rectangle.width;
    const bottom = @as(i64, rectangle.y) + rectangle.height;
    return point.x >= rectangle.x and point.y >= rectangle.y and
        @as(i64, point.x) < right and @as(i64, point.y) < bottom;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "pointer constraints: commit publishes copied regions and locked hints" {
    const SurfaceId = packed struct { index: u32, generation: u32 };
    const PointerId = packed struct { index: u32, generation: u32 };
    const TestStore = Store(SurfaceId, PointerId);
    var store = try TestStore.init(std.testing.allocator, .{
        .constraint_capacity = 2,
        .region_operation_capacity = 2,
        .event_capacity = 4,
    });
    defer store.deinit();
    const surface: SurfaceId = .{ .index = 1, .generation = 2 };
    const pointer: PointerId = .{ .index = 3, .generation = 4 };
    var operations = [_]region.Operation{
        .{ .add = .{ .x = 0, .y = 0, .width = 20, .height = 20 } },
        .{ .subtract = .{ .x = 5, .y = 5, .width = 5, .height = 5 } },
    };
    const id = try store.create(.locked, .persistent, surface, pointer, &operations);
    operations[0] = .{ .add = .{ .x = 100, .y = 100, .width = 1, .height = 1 } };
    try std.testing.expect(try store.contains(id, .{ .x = 2, .y = 2 }));
    try std.testing.expect(!(try store.contains(id, .{ .x = 6, .y = 6 })));

    const replacement = [_]region.Operation{
        .{ .add = .{ .x = 100, .y = 100, .width = 10, .height = 10 } },
    };
    try store.setRegion(id, &replacement);
    try store.setCursorHint(id, .{ .x = 7, .y = 8 });
    try std.testing.expect(try store.contains(id, .{ .x = 2, .y = 2 }));
    try std.testing.expect(!(try store.contains(id, .{ .x = 102, .y = 102 })));
    try std.testing.expectEqual(@as(?TestStore.Point, null), try store.cursorHint(id));
    store.commitSurface(surface);
    try std.testing.expect(!(try store.contains(id, .{ .x = 2, .y = 2 })));
    try std.testing.expect(try store.contains(id, .{ .x = 102, .y = 102 }));
    var copied: [2]region.Operation = undefined;
    const snapshot = try store.copyRegion(id, &copied);
    try std.testing.expect(!snapshot.unrestricted);
    try std.testing.expectEqualSlices(region.Operation, &replacement, snapshot.operations);
    try std.testing.expectEqual(TestStore.Point{ .x = 7, .y = 8 }, (try store.cursorHint(id)).?);
    try std.testing.expectError(
        error.AlreadyConstrained,
        store.create(.confined, .persistent, surface, pointer, null),
    );
}

test "pointer constraints: focus activation and oneshot deactivation are exact" {
    const SurfaceId = packed struct { index: u32, generation: u32 };
    const PointerId = packed struct { index: u32, generation: u32 };
    const TestStore = Store(SurfaceId, PointerId);
    var store = try TestStore.init(std.testing.allocator, .{
        .constraint_capacity = 1,
        .region_operation_capacity = 1,
        .event_capacity = 2,
    });
    defer store.deinit();
    const surface: SurfaceId = .{ .index = 1, .generation = 2 };
    const pointer: PointerId = .{ .index = 3, .generation = 4 };
    const id = try store.create(.confined, .oneshot, surface, pointer, null);

    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(
        TestStore.Event{ .activated = .{ .id = id, .kind = .confined } },
        store.popEvent().?,
    );
    try std.testing.expectEqual(TestStore.MotionPolicy{ .confined = id }, store.motionPolicy(pointer));
    try store.updateFocus(pointer, null, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(
        TestStore.Event{ .deactivated = .{ .id = id, .kind = .confined } },
        store.popEvent().?,
    );
    try std.testing.expectEqual(TestStore.MotionPolicy.free, store.motionPolicy(pointer));
    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(?TestStore.Event, null), store.popEvent());
}

test "pointer constraints: focus transitions are atomic under event backpressure" {
    const SurfaceId = packed struct { index: u32, generation: u32 };
    const PointerId = packed struct { index: u32, generation: u32 };
    const TestStore = Store(SurfaceId, PointerId);
    var store = try TestStore.init(std.testing.allocator, .{
        .constraint_capacity = 2,
        .region_operation_capacity = 1,
        .event_capacity = 1,
    });
    defer store.deinit();
    const surface_a: SurfaceId = .{ .index = 1, .generation = 1 };
    const surface_b: SurfaceId = .{ .index = 2, .generation = 1 };
    const pointer: PointerId = .{ .index = 1, .generation = 1 };
    const a = try store.create(.locked, .persistent, surface_a, pointer, null);
    _ = try store.create(.confined, .persistent, surface_b, pointer, null);

    try store.updateFocus(pointer, surface_a, .{ .x = 0, .y = 0 });
    _ = store.popEvent();
    try std.testing.expectError(
        error.Exhausted,
        store.updateFocus(pointer, surface_b, .{ .x = 0, .y = 0 }),
    );
    try std.testing.expectEqual(TestStore.MotionPolicy{ .locked = a }, store.motionPolicy(pointer));
    try std.testing.expectEqual(@as(?TestStore.Event, null), store.popEvent());
}

test "pointer constraints: teardown is exact and generations reject stale ids" {
    const SurfaceId = packed struct { index: u32, generation: u32 };
    const PointerId = packed struct { index: u32, generation: u32 };
    const TestStore = Store(SurfaceId, PointerId);
    var store = try TestStore.init(std.testing.allocator, .{
        .constraint_capacity = 1,
        .region_operation_capacity = 1,
        .event_capacity = 1,
    });
    defer store.deinit();
    const surface: SurfaceId = .{ .index = 1, .generation = 1 };
    const pointer: PointerId = .{ .index = 1, .generation = 1 };
    const old_id = try store.create(.locked, .persistent, surface, pointer, null);
    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });

    try std.testing.expectError(error.Exhausted, store.surfaceRemoved(surface));
    try std.testing.expectEqual(TestStore.MotionPolicy{ .locked = old_id }, store.motionPolicy(pointer));
    _ = store.popEvent();

    try store.surfaceRemoved(surface);
    try std.testing.expectEqual(
        TestStore.Event{ .deactivated = .{ .id = old_id, .kind = .locked } },
        store.popEvent().?,
    );
    try std.testing.expectEqual(TestStore.MotionPolicy.free, store.motionPolicy(pointer));
    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });
    try std.testing.expectEqual(@as(?TestStore.Event, null), store.popEvent());

    try store.destroy(old_id);
    const new_id = try store.create(.locked, .persistent, surface, pointer, null);
    try std.testing.expect(old_id.index == new_id.index);
    try std.testing.expect(old_id.generation != new_id.generation);
    try std.testing.expectError(error.StaleConstraint, store.setRegion(old_id, null));

    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });
    try store.destroy(new_id);
    try std.testing.expectEqual(@as(?TestStore.Event, null), store.popEvent());
}

test "pointer constraints: wire owner retains activation until publication" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };

        pub fn surfaceIdOn(_: *@This(), _: anytype, _: u32) !SurfaceId {
            return .{ .index = 1, .generation = 1 };
        }

        pub fn copyRegionOn(
            _: *@This(),
            _: anytype,
            _: u32,
            destination: []region.Operation,
        ) ![]const region.Operation {
            return destination[0..0];
        }
    };
    const FakeSeat = struct {
        pub const PointerId = packed struct { index: u32, generation: u32 };

        pub fn pointerIdOn(_: *@This(), _: anytype, _: u32) !PointerId {
            return .{ .index = 1, .generation = 1 };
        }
    };
    const TestAdapter = Adapter(protocol, FakeCore, FakeSeat);
    _ = TestAdapter.requestOn;
    var core: FakeCore = .{};
    var seat: FakeSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &seat, .{
        .constraint_capacity = 1,
        .region_operation_capacity = 1,
        .event_capacity = 1,
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
    const surface: FakeCore.SurfaceId = .{ .index = 3, .generation = 4 };
    const constraint_id = try adapter.state.create(.locked, .persistent, surface, 0, null);
    const resource = try adapter.acquire();
    resource.peer = .{ .slot = 1, .generation = 2 };
    resource.constraint = constraint_id;
    resource.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_locked_pointer_v1.info,
        1,
        resource,
    );

    try adapter.updateFocus(surface, .{ .x = 0, .y = 0 });
    try std.testing.expect(adapter.pendingOutbound(resource.peer));
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 32, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(resource.peer, &server_objects, &output),
    );
    try std.testing.expect(!adapter.pendingOutbound(resource.peer));
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    try std.testing.expectEqual(
        protocol.zwp_locked_pointer_v1.Event{ .locked = .{} },
        try protocol.zwp_locked_pointer_v1.decodeEvent(message, &fds),
    );
}
