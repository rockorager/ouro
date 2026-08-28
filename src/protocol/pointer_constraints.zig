//! Protocol-neutral bounded pointer-constraint state.
//!
//! The protocol-neutral store and wire adapter establish generation-safe
//! lock/confine lifetime, copied region state, surface-commit publication,
//! exact physical motion policy, and retained activation events.

const std = @import("std");
const wayring = @import("wayring");
const region = @import("../region.zig");
const confinement = @import("../input/confinement.zig");
const slot_pool = @import("slot_pool.zig");
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
        const minimum_events = std.math.mul(
            usize,
            config.constraint_capacity,
            2,
        ) catch return error.InvalidConfig;
        if (config.event_capacity < minimum_events) return error.InvalidConfig;
    }
};

pub const WireConfig = struct {
    constraint_capacity: usize = 16,
    region_operation_capacity: usize = 16,
    input_region_operation_capacity: usize = 64,
    event_capacity: usize = 32,
    global_version: u32 = 1,
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
            header: slot_pool.Header = .{},
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
        slots: slot_pool.Pool(Slot),
        events: []Event,
        region_capacity: usize,
        event_head: usize = 0,
        event_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            var slots = try slot_pool.Pool(Slot).init(allocator, config.constraint_capacity);
            errdefer slots.deinit();
            const events = try allocator.alloc(Event, config.event_capacity);
            return .{
                .allocator = allocator,
                .slots = slots,
                .events = events,
                .region_capacity = config.region_operation_capacity,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            for (self.slots.entries.items) |slot| if (slot.header.active) {
                self.allocator.free(slot.current_region);
                self.allocator.free(slot.pending_region);
            };
            self.slots.deinit();
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
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.defunct or !std.meta.eql(slot.surface, surface)) continue;
                self.publishSlot(slot);
            }
        }

        /// Preflights the focus transitions caused by publishing a surface's
        /// pending constraint regions. The surface commit owner calls this
        /// before mutating any double-buffered state.
        pub fn validateSurfaceCommit(
            self: *Self,
            committed_surface: SurfaceId,
            pointer: PointerId,
            focus_surface: ?SurfaceId,
            point: Point,
        ) !void {
            var required_events: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.pointer, pointer)) continue;
                const qualifies = !slot.defunct and focus_surface != null and
                    std.meta.eql(slot.surface, focus_surface.?) and
                    self.containsSlotVersion(
                        slot,
                        point,
                        std.meta.eql(slot.surface, committed_surface) and slot.region_dirty,
                    );
                if (qualifies != slot.engaged) required_events += 1;
            }
            try self.ensureOrdinaryEventCapacity(required_events);
        }

        pub fn updateFocus(
            self: *Self,
            pointer: PointerId,
            surface: ?SurfaceId,
            point: Point,
        ) !void {
            var required_events: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.pointer, pointer)) continue;
                const qualifies = !slot.defunct and surface != null and
                    std.meta.eql(slot.surface, surface.?) and self.containsSlot(slot, point);
                if (qualifies != slot.engaged) required_events += 1;
            }
            try self.ensureOrdinaryEventCapacity(required_events);

            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.pointer, pointer)) continue;
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
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !slot.engaged or !std.meta.eql(slot.pointer, pointer)) continue;
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

        pub fn constraintSurface(self: *Self, constraint_id: ConstraintId) !SurfaceId {
            return (try self.resolve(constraint_id)).surface;
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

        pub fn surfaceRemoved(self: *Self, surface: SurfaceId) void {
            var required_events: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (slot.header.active and slot.engaged and std.meta.eql(slot.surface, surface)) {
                    required_events += 1;
                }
            }
            std.debug.assert(required_events <= self.events.len - self.event_len);

            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.surface, surface)) continue;
                if (slot.engaged) self.enqueueAssumeCapacity(.{ .deactivated = .{
                    .id = self.constraintId(slot),
                    .kind = slot.kind,
                } });
                slot.engaged = false;
                slot.defunct = true;
            }
        }

        pub fn pointerRemoved(self: *Self, pointer: PointerId) void {
            var required_events: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (slot.header.active and slot.engaged and std.meta.eql(slot.pointer, pointer)) {
                    required_events += 1;
                }
            }
            std.debug.assert(required_events <= self.events.len - self.event_len);

            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.pointer, pointer)) continue;
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
            return containsRegion(
                slot.current_region_null,
                slot.current_region[0..slot.current_region_len],
                point,
            );
        }

        fn containsSlotVersion(
            _: *Self,
            slot: *const Slot,
            point: Point,
            pending: bool,
        ) bool {
            return if (pending)
                containsRegion(
                    slot.pending_region_null,
                    slot.pending_region[0..slot.pending_region_len],
                    point,
                )
            else
                containsRegion(
                    slot.current_region_null,
                    slot.current_region[0..slot.current_region_len],
                    point,
                );
        }

        fn ensureOrdinaryEventCapacity(self: *const Self, required_events: usize) !void {
            const ordinary_capacity = self.events.len -| self.slots.entries.items.len;
            if (self.event_len > ordinary_capacity or
                required_events > ordinary_capacity - self.event_len) return error.Exhausted;
        }

        fn containsRegion(
            unrestricted: bool,
            operations: []const region.Operation,
            point: Point,
        ) bool {
            if (unrestricted) return true;
            var inside = false;
            for (operations) |operation| switch (operation) {
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
            const slot = try self.slots.acquire();
            errdefer self.slots.release(slot);
            slot.current_region = try self.allocator.alloc(region.Operation, self.region_capacity);
            errdefer self.allocator.free(slot.current_region);
            slot.pending_region = try self.allocator.alloc(region.Operation, self.region_capacity);
            return slot;
        }

        fn release(self: *Self, slot_index: u32) void {
            const slot = self.slots.at(slot_index) orelse return;
            self.allocator.free(slot.current_region);
            self.allocator.free(slot.pending_region);
            self.slots.release(slot);
        }

        fn resolve(self: *Self, constraint_id: ConstraintId) !*Slot {
            const slot = self.slots.at(constraint_id.index) orelse return error.StaleConstraint;
            if (slot.header.generation != constraint_id.generation) return error.StaleConstraint;
            return slot;
        }

        fn findSurface(self: *Self, surface: SurfaceId) ?*Slot {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and std.meta.eql(slot.surface, surface)) return slot;
            return null;
        }

        fn constraintId(_: *const Self, slot: *const Slot) ConstraintId {
            return .{ .index = slot.header.index, .generation = slot.header.generation };
        }

        fn slotIndex(_: *const Self, slot: *const Slot) u32 {
            return slot.header.index;
        }
    };
}

/// Owns the advertised protocol resources around `Store` and bridges retained
/// constraint state to exact committed surface/input geometry.
pub fn Adapter(comptime protocol: type, comptime Core: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_pointer_constraints_v1;
        const LockedPointer = protocol.zwp_locked_pointer_v1;
        const ConfinedPointer = protocol.zwp_confined_pointer_v1;
        const State = Store(Core.SurfaceId, u8);

        pub const ConstraintId = State.ConstraintId;
        pub const MotionPolicy = State.MotionPolicy;
        pub const FocusPoint = struct { x: i32, y: i32 };

        const ResourceSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            constraint: ?ConstraintId = null,
        };

        allocator: std.mem.Allocator,
        core: *Core,
        seat: *Seat,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        state: State,
        resources: slot_pool.Pool(ResourceSlot),
        region_scratch: []region.Operation,
        input_region_scratch: []region.Operation,
        boundary_scratch: []u64,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *Core,
            seat: *Seat,
            config: WireConfig,
        ) !Self {
            if (config.global_version != 1 or config.input_region_operation_capacity == 0)
                return error.InvalidConfig;
            try Manager.info.validateVersion(config.global_version);
            var state = try State.init(allocator, .{
                .constraint_capacity = config.constraint_capacity,
                .region_operation_capacity = config.region_operation_capacity,
                .event_capacity = config.event_capacity,
            });
            errdefer state.deinit();
            var resources = try slot_pool.Pool(ResourceSlot).init(allocator, config.constraint_capacity);
            errdefer resources.deinit();
            const region_scratch = try allocator.alloc(region.Operation, config.region_operation_capacity);
            errdefer allocator.free(region_scratch);
            const input_region_scratch = try allocator.alloc(
                region.Operation,
                config.input_region_operation_capacity,
            );
            errdefer allocator.free(input_region_scratch);
            const boundary_scratch = try allocator.alloc(
                u64,
                try confinement.scratchCapacity(
                    config.input_region_operation_capacity,
                    config.region_operation_capacity,
                ),
            );
            return .{
                .allocator = allocator,
                .core = core,
                .seat = seat,
                .global_version = config.global_version,
                .state = state,
                .resources = resources,
                .region_scratch = region_scratch,
                .input_region_scratch = input_region_scratch,
                .boundary_scratch = boundary_scratch,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.boundary_scratch);
            self.allocator.free(self.input_region_scratch);
            self.allocator.free(self.region_scratch);
            self.resources.deinit();
            self.state.deinit();
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

        pub fn validateSurfaceCommit(
            self: *Self,
            committed_surface: Core.SurfaceId,
            focus_surface: ?Core.SurfaceId,
            point: FocusPoint,
        ) !void {
            try self.state.validateSurfaceCommit(
                committed_surface,
                0,
                try self.effectiveFocus(focus_surface, point),
                .{ .x = @divFloor(point.x, 256), .y = @divFloor(point.y, 256) },
            );
        }

        pub fn surfaceRemoved(self: *Self, surface: Core.SurfaceId) void {
            self.state.surfaceRemoved(surface);
        }

        pub fn updateFocus(self: *Self, surface: ?Core.SurfaceId, point: FocusPoint) !void {
            try self.state.updateFocus(0, try self.effectiveFocus(surface, point), .{
                .x = @divFloor(point.x, 256),
                .y = @divFloor(point.y, 256),
            });
        }

        fn effectiveFocus(
            self: *Self,
            surface: ?Core.SurfaceId,
            point: FocusPoint,
        ) !?Core.SurfaceId {
            const id = surface orelse return null;
            const input = try self.core.copyCommittedInput(id, self.input_region_scratch);
            if (!confinement.contains(
                .{ .x = point.x, .y = point.y },
                .{ .width = input.width, .height = input.height },
                .{ .infinite = input.infinite, .operations = input.operations },
                .{ .infinite = true, .operations = &.{} },
            )) return null;
            return id;
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

        pub fn clipMotion(
            self: *Self,
            constraint_id: ConstraintId,
            start: confinement.FixedPoint,
            end: confinement.FixedPoint,
        ) !confinement.FixedPoint {
            const surface = try self.state.constraintSurface(constraint_id);
            const input = try self.core.copyCommittedInput(surface, self.input_region_scratch);
            const constraint = try self.state.copyRegion(constraint_id, self.region_scratch);
            return confinement.clip(
                start,
                end,
                .{ .width = input.width, .height = input.height },
                .{ .infinite = input.infinite, .operations = input.operations },
                .{ .infinite = constraint.unrestricted, .operations = constraint.operations },
                self.boundary_scratch,
            );
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
            for (self.resources.entries.items) |slot|
                if (slot.header.active and slot.constraint != null and
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
                error.Exhausted, error.OutOfMemory => return try self.noMemory(actor),
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
            return self.resources.acquire();
        }

        fn release(self: *Self, slot_index: u32) void {
            const slot = self.resources.at(slot_index) orelse return;
            self.resources.release(slot);
        }

        fn findConstraint(self: *Self, constraint_id: ConstraintId) ?*ResourceSlot {
            for (self.resources.entries.items) |slot|
                if (slot.header.active and slot.constraint != null and
                    std.meta.eql(slot.constraint.?, constraint_id)) return slot;
            return null;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*ResourceSlot {
            return self.resources.fromContext(object.context);
        }

        fn slotIndex(_: *const Self, slot: *const ResourceSlot) u32 {
            return slot.header.index;
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

test "pointer constraints: surface commit preflights region activation events" {
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
    const initial = [_]region.Operation{
        .{ .add = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
    };
    const replacement = [_]region.Operation{
        .{ .add = .{ .x = 20, .y = 20, .width = 10, .height = 10 } },
    };
    const id = try store.create(.confined, .persistent, surface, pointer, &initial);
    try store.updateFocus(pointer, surface, .{ .x = 5, .y = 5 });
    try store.setRegion(id, &replacement);

    try std.testing.expectError(
        error.Exhausted,
        store.validateSurfaceCommit(surface, pointer, surface, .{ .x = 5, .y = 5 }),
    );
    try std.testing.expectEqual(TestStore.MotionPolicy{ .confined = id }, store.motionPolicy(pointer));
    _ = store.popEvent();

    try store.validateSurfaceCommit(surface, pointer, surface, .{ .x = 5, .y = 5 });
    store.commitSurface(surface);
    try store.updateFocus(pointer, surface, .{ .x = 5, .y = 5 });
    try std.testing.expectEqual(
        TestStore.Event{ .deactivated = .{ .id = id, .kind = .confined } },
        store.popEvent().?,
    );
    try std.testing.expectEqual(TestStore.MotionPolicy.free, store.motionPolicy(pointer));
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
        .event_capacity = 4,
    });
    defer store.deinit();
    const surface_a: SurfaceId = .{ .index = 1, .generation = 1 };
    const surface_b: SurfaceId = .{ .index = 2, .generation = 1 };
    const pointer: PointerId = .{ .index = 1, .generation = 1 };
    const a = try store.create(.locked, .persistent, surface_a, pointer, null);
    _ = try store.create(.confined, .persistent, surface_b, pointer, null);

    try store.updateFocus(pointer, surface_a, .{ .x = 0, .y = 0 });
    try std.testing.expectError(
        error.Exhausted,
        store.updateFocus(pointer, surface_b, .{ .x = 0, .y = 0 }),
    );
    try std.testing.expectEqual(TestStore.MotionPolicy{ .locked = a }, store.motionPolicy(pointer));
    try std.testing.expectEqual(
        TestStore.Event{ .activated = .{ .id = a, .kind = .locked } },
        store.popEvent().?,
    );
    try std.testing.expectEqual(@as(?TestStore.Event, null), store.popEvent());
}

test "pointer constraints: teardown is exact and generations reject stale ids" {
    const SurfaceId = packed struct { index: u32, generation: u32 };
    const PointerId = packed struct { index: u32, generation: u32 };
    const TestStore = Store(SurfaceId, PointerId);
    var store = try TestStore.init(std.testing.allocator, .{
        .constraint_capacity = 1,
        .region_operation_capacity = 1,
        .event_capacity = 2,
    });
    defer store.deinit();
    const surface: SurfaceId = .{ .index = 1, .generation = 1 };
    const pointer: PointerId = .{ .index = 1, .generation = 1 };
    const old_id = try store.create(.locked, .persistent, surface, pointer, null);
    try store.updateFocus(pointer, surface, .{ .x = 0, .y = 0 });

    store.surfaceRemoved(surface);
    try std.testing.expectEqual(
        TestStore.Event{ .activated = .{ .id = old_id, .kind = .locked } },
        store.popEvent().?,
    );
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

test "pointer constraints: initial capacity grows without disturbing live state" {
    const State = Store(u32, u32);
    var state = try State.init(std.testing.allocator, .{
        .constraint_capacity = 1,
        .region_operation_capacity = 1,
        .event_capacity = 2,
    });
    defer state.deinit();
    const first = try state.create(.locked, .persistent, 1, 1, null);
    const second = try state.create(.confined, .persistent, 2, 1, null);
    try std.testing.expectEqual(@as(u32, 0), first.index);
    try std.testing.expectEqual(@as(u32, 1), second.index);
    try std.testing.expectEqual(@as(u32, 1), try state.constraintSurface(first));
    try std.testing.expectEqual(@as(u32, 2), try state.constraintSurface(second));
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

        pub fn copyCommittedInput(
            _: *@This(),
            _: SurfaceId,
            destination: []region.Operation,
        ) !struct {
            width: u32,
            height: u32,
            infinite: bool,
            operations: []const region.Operation,
        } {
            return .{
                .width = 10,
                .height = 10,
                .infinite = true,
                .operations = destination[0..0],
            };
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
        .event_capacity = 2,
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
