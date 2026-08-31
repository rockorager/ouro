//! Owner for the ext-transient-seat-v1 protocol and its isolated wl_seats.
//!
//! Global publication is deliberately a two step operation.  `nextMutation`
//! starts one Wayring mutation; the caller must call `mutationPublished` only
//! after `Runtime.publishNext` returns `.complete`.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;

pub const Config = struct {
    seat_capacity: usize = 8,
    transient_capacity: usize = 16,
    manager_capacity: usize = 8,
    outbound_capacity: usize = 16,
};

pub fn Adapter(comptime protocol: type, comptime SeatAdapter: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Manager = protocol.ext_transient_seat_manager_v1;
        const Transient = protocol.ext_transient_seat_v1;
        const none = std.math.maxInt(u32);

        pub const SeatId = struct { index: u32, generation: u32 };
        pub const TransientId = struct { index: u32, generation: u32 };
        pub const PointerPosition = struct { x: i32 = 0, y: i32 = 0 };
        pub const Mutation = union(enum) { add: SeatId, remove: SeatId };
        pub const InitSeatFn = *const fn (?*anyopaque, std.mem.Allocator, *SeatAdapter) anyerror!void;

        const State = enum { free, queued, adding, ready, remove_queued, removing, retired };
        const ManagerSlot = struct { active: bool = false, generation: u32 = 1, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = undefined };
        const SeatSlot = struct {
            adapter: SeatAdapter = undefined,
            initialized: bool = false,
            state: State = .free,
            generation: u32 = 1,
            peer: wayring.io_uring.Peer = undefined,
            transient: ?TransientId = null,
            pointer_position: PointerPosition = .{},
            sequence: u64 = 0,
        };
        const TransientSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = undefined,
            seat: ?SeatId = null,
        };
        const Out = union(enum) {
            ready: struct { transient: TransientId, name: ?u32 = null },
            denied: TransientId,
        };
        const OutSlot = struct { active: bool = false, sequence: u64 = 0, value: Out = undefined };

        allocator: std.mem.Allocator,
        runtime: ?*Runtime = null,
        manager_global: ?objects.Handle = null,
        managers: []ManagerSlot,
        seats: []SeatSlot,
        transients: []TransientSlot,
        outbound: []OutSlot,
        init_context: ?*anyopaque,
        init_seat: InitSeatFn,
        mutation: ?Mutation = null,
        pending_work: usize = 0,
        sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, config: Config, context: ?*anyopaque, init_seat: InitSeatFn) !Self {
            if (config.seat_capacity == 0 or config.manager_capacity == 0 or config.outbound_capacity == 0 or
                config.transient_capacity == 0 or config.seat_capacity >= none or config.manager_capacity >= none or config.transient_capacity >= none) return error.InvalidConfig;
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const seats = try allocator.alloc(SeatSlot, config.seat_capacity);
            errdefer allocator.free(seats);
            const outbound = try allocator.alloc(OutSlot, config.outbound_capacity);
            errdefer allocator.free(outbound);
            const transients = try allocator.alloc(TransientSlot, config.transient_capacity);
            errdefer allocator.free(transients);
            @memset(managers, .{});
            @memset(seats, .{});
            @memset(outbound, .{});
            @memset(transients, .{});
            return .{ .allocator = allocator, .managers = managers, .seats = seats, .transients = transients, .outbound = outbound, .init_context = context, .init_seat = init_seat };
        }

        pub fn deinit(self: *Self) void {
            for (self.seats) |*seat| if (seat.initialized) seat.adapter.deinit();
            self.allocator.free(self.transients);
            self.allocator.free(self.outbound);
            self.allocator.free(self.seats);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.manager_global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.manager_global.?;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            for (self.managers) |*manager| if (!manager.active) {
                const generation = manager.generation;
                manager.* = .{ .active = true, .generation = generation, .peer = binding.peer, .resource = binding.resource };
                return manager;
            };
            return error.OutOfMemory;
        }

        /// Starts at most one global mutation. Temporary publication contention
        /// is represented by `null`, never by a protocol denial.
        pub fn nextMutation(self: *Self) !?Mutation {
            if (self.mutation != null) return null;
            for (self.seats, 0..) |*seat, i| if (seat.state == .queued) {
                const id = SeatId{ .index = @intCast(i), .generation = seat.generation };
                _ = seat.adapter.install(self.runtime orelse return error.NotInstalled) catch |err| switch (err) {
                    error.GlobalUpdateActive => return null,
                    else => return err,
                };
                self.setState(seat, .adding);
                self.mutation = .{ .add = id };
                return self.mutation;
            };
            for (self.seats, 0..) |*seat, i| if (seat.state == .remove_queued) {
                const id = SeatId{ .index = @intCast(i), .generation = seat.generation };
                seat.adapter.removeGlobal() catch |err| switch (err) {
                    error.GlobalUpdateActive => return null,
                    else => return err,
                };
                self.setState(seat, .removing);
                self.mutation = .{ .remove = id };
                return self.mutation;
            };
            return null;
        }

        pub fn activeMutation(self: *const Self) ?Mutation {
            return self.mutation;
        }

        pub fn mutationPublished(self: *Self, completed: Mutation) !void {
            if (self.mutation == null or !std.meta.eql(self.mutation.?, completed)) return error.StaleMutation;
            self.mutation = null;
            const id = switch (completed) {
                inline else => |id| id,
            };
            const seat = self.validSeat(id) orelse return;
            switch (completed) {
                .add => {
                    if (seat.transient == null) self.setState(seat, .remove_queued) else {
                        self.setState(seat, .ready);
                        const out = self.outForTransient(seat.transient.?) orelse return error.MissingReservation;
                        out.value.ready.name = seat.adapter.globalName() orelse return error.MissingGlobal;
                    }
                },
                .remove => self.setState(seat, .retired),
            }
            try self.advance();
        }

        fn destroySeat(self: *Self, seat: *SeatSlot) void {
            seat.transient = null;
            switch (seat.state) {
                .queued => self.setState(seat, .retired),
                .adding => {}, // add completion observes the absent handle
                .ready => self.setState(seat, .remove_queued),
                else => {},
            }
        }

        fn destroyTransient(self: *Self, transient: *TransientSlot) void {
            const id = self.transientId(transient);
            if (transient.seat) |seat_id| if (self.validSeat(seat_id)) |seat| self.destroySeat(seat);
            self.cancelOutbound(id);
            transient.active = false;
            transient.generation = nextGeneration(transient.generation);
            transient.seat = null;
        }

        pub fn advance(self: *Self) !void {
            for (self.seats) |*seat| if (seat.state == .retired and seat.transient == null) {
                if (!seat.initialized) unreachable;
                if (seat.adapter.globalName() != null or seat.adapter.resourceCount() != 0 or seat.adapter.deviceCount() != 0) continue;
                seat.adapter.deinit();
                const generation = nextGeneration(seat.generation);
                self.setState(seat, .free);
                seat.* = .{ .generation = generation };
            };
        }

        pub fn hasPendingWork(self: *const Self) bool {
            return self.mutation != null or self.pending_work != 0;
        }

        fn setState(self: *Self, seat: *SeatSlot, state: State) void {
            const was_pending = stateNeedsWork(seat.state);
            const is_pending = stateNeedsWork(state);
            if (!was_pending and is_pending) self.pending_work += 1;
            if (was_pending and !is_pending) {
                std.debug.assert(self.pending_work != 0);
                self.pending_work -= 1;
            }
            seat.state = state;
        }

        fn stateNeedsWork(state: State) bool {
            return state == .queued or state == .remove_queued or state == .retired;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            if (target.object.interface == &Manager.info) {
                const manager = self.managerFrom(target.object.context) orelse return null;
                if (!std.meta.eql(manager.peer, peer) or manager.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .create => |value| {
                        // Context is patched after admission, while the stable slot address
                        // is what subsequent dispatch uses.
                        var chosen: ?*SeatSlot = null;
                        for (self.seats) |*seat| if (seat.state == .free) {
                            chosen = seat;
                            break;
                        };
                        const transient = self.freeTransient() orelse return error.Exhausted;
                        if (chosen) |seat| {
                            try self.init_seat(self.init_context, self.allocator, &seat.adapter);
                            seat.initialized = true;
                            errdefer {
                                seat.adapter.deinit();
                                seat.initialized = false;
                            }
                            const id = self.transientId(transient);
                            const out = self.reserve(.{ .ready = .{ .transient = id } }) orelse return error.Exhausted;
                            errdefer out.active = false;
                            const admitted = try Manager.admit_create(server_objects, decoded.handle, value, .{ .seat = transient });
                            transient.* = .{ .active = true, .generation = id.generation, .peer = peer, .resource = admitted.seat, .seat = self.seatId(seat) };
                            self.setState(seat, .queued);
                            seat.peer = peer;
                            seat.transient = id;
                        } else {
                            const id = self.transientId(transient);
                            const out = self.reserve(.{ .denied = id }) orelse return error.Exhausted;
                            errdefer out.active = false;
                            const admitted = try Manager.admit_create(server_objects, decoded.handle, value, .{ .seat = transient });
                            transient.* = .{ .active = true, .generation = id.generation, .peer = peer, .resource = admitted.seat };
                        }
                    },
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Transient.info) {
                const transient = self.transientFrom(target.object.context) orelse return null;
                if (!std.meta.eql(transient.peer, peer) or transient.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Transient, server_objects, message, fds);
                self.destroyTransient(transient);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            for (self.seats) |*seat| if (seat.initialized) {
                if (try seat.adapter.requestOn(actor, server_objects, target, message, fds)) |control| return control;
            };
            return null;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) if (self.managerFrom(object.context)) |manager| {
                if (!std.meta.eql(manager.resource, handle)) return false;
                manager.active = false;
                manager.generation = nextGeneration(manager.generation);
                return true;
            };
            if (object.interface == &Transient.info) if (self.transientFrom(object.context)) |transient| {
                if (!std.meta.eql(transient.resource, handle)) return false;
                self.destroyTransient(transient);
                return true;
            };
            for (self.seats) |*seat| if (seat.initialized and seat.adapter.resourceRemoved(handle, object)) {
                return true;
            };
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.managers) |*manager| {
                if (manager.active and std.meta.eql(manager.peer, peer)) manager.active = false;
            }
            for (self.transients) |*transient| if (transient.active and std.meta.eql(transient.peer, peer)) self.destroyTransient(transient);
        }

        pub fn resolveSeat(self: *Self, peer: wayring.io_uring.Peer, seat_object_id: u32) ?*SeatAdapter {
            for (self.seats) |*seat| if (seat.initialized and seat.state != .free and seat.adapter.ownsSeat(peer, seat_object_id)) return &seat.adapter;
            return null;
        }

        pub fn pointerPosition(self: *Self, adapter: *SeatAdapter) ?PointerPosition {
            const seat = self.seatForAdapter(adapter) orelse return null;
            return seat.pointer_position;
        }

        pub fn setPointerPosition(self: *Self, adapter: *SeatAdapter, position: PointerPosition) bool {
            const seat = self.seatForAdapter(adapter) orelse return false;
            seat.pointer_position = position;
            return true;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |out| if (out.active) switch (out.value) {
                .ready => |v| if (self.validTransientConst(v.transient)) |t| if (std.meta.eql(t.peer, peer)) return true,
                .denied => |v| if (self.validTransientConst(v)) |t| if (std.meta.eql(t.peer, peer)) return true,
            };
            return false;
        }

        pub fn pendingSeatOutboundOn(self: *Self, server_objects: anytype) bool {
            for (self.seats) |*seat| {
                if (seat.initialized and seat.adapter.pendingOutboundOn(server_objects)) return true;
            }
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            while (self.oldest(peer)) |out| {
                switch (out.value) {
                    .ready => |v| if (self.validTransient(v.transient)) |transient|
                        try wayring.server.sendEvent(protocol, Transient, server_objects, queue, transient.resource, .{ .ready = .{ .global_name = v.name.? } }),
                    .denied => |v| if (self.validTransient(v)) |transient|
                        try wayring.server.sendEvent(protocol, Transient, server_objects, queue, transient.resource, .{ .denied = .{} }),
                }
                out.active = false;
                count += 1;
            }
            return count;
        }

        pub fn flushSeatsOn(self: *Self, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.seats) |*seat| {
                if (seat.initialized) count += try seat.adapter.flushOn(server_objects, queue);
            }
            return count;
        }

        fn reserve(self: *Self, value: Out) ?*OutSlot {
            for (self.outbound) |*out| if (!out.active) {
                out.* = .{ .active = true, .sequence = self.sequence, .value = value };
                self.sequence +%= 1;
                return out;
            };
            return null;
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*OutSlot {
            var found: ?*OutSlot = null;
            for (self.outbound) |*out| if (out.active and (found == null or out.sequence < found.?.sequence)) switch (out.value) {
                .ready => |v| if (v.name != null) if (self.validTransient(v.transient)) |t| {
                    if (std.meta.eql(t.peer, peer)) found = out;
                },
                .denied => |v| if (self.validTransient(v)) |t| if (std.meta.eql(t.peer, peer)) {
                    found = out;
                },
            };
            return found;
        }
        fn validSeat(self: *Self, id: SeatId) ?*SeatSlot {
            return if (id.index < self.seats.len and self.seats[id.index].generation == id.generation) &self.seats[id.index] else null;
        }
        fn validSeatConst(self: *const Self, id: SeatId) ?*const SeatSlot {
            return if (id.index < self.seats.len and self.seats[id.index].generation == id.generation) &self.seats[id.index] else null;
        }
        fn seatForAdapter(self: *Self, adapter: *SeatAdapter) ?*SeatSlot {
            for (self.seats) |*seat| if (seat.initialized and &seat.adapter == adapter) return seat;
            return null;
        }
        fn seatId(self: *Self, seat: *SeatSlot) SeatId {
            return .{ .index = @intCast((@intFromPtr(seat) - @intFromPtr(self.seats.ptr)) / @sizeOf(SeatSlot)), .generation = seat.generation };
        }
        fn transientId(self: *Self, transient: *TransientSlot) TransientId {
            return .{ .index = @intCast((@intFromPtr(transient) - @intFromPtr(self.transients.ptr)) / @sizeOf(TransientSlot)), .generation = transient.generation };
        }
        fn validTransient(self: *Self, id: TransientId) ?*TransientSlot {
            return if (id.index < self.transients.len and self.transients[id.index].active and self.transients[id.index].generation == id.generation) &self.transients[id.index] else null;
        }
        fn validTransientConst(self: *const Self, id: TransientId) ?*const TransientSlot {
            return if (id.index < self.transients.len and self.transients[id.index].active and self.transients[id.index].generation == id.generation) &self.transients[id.index] else null;
        }
        fn transientFrom(self: *Self, context: ?*anyopaque) ?*TransientSlot {
            const transient = from(TransientSlot, self.transients, context) orelse return null;
            return if (transient.active) transient else null;
        }
        fn freeTransient(self: *Self) ?*TransientSlot {
            for (self.transients) |*transient| if (!transient.active) return transient;
            return null;
        }
        fn outForTransient(self: *Self, id: TransientId) ?*OutSlot {
            for (self.outbound) |*out| if (out.active) switch (out.value) {
                .ready => |v| if (std.meta.eql(v.transient, id)) return out,
                else => {},
            };
            return null;
        }
        fn cancelOutbound(self: *Self, id: TransientId) void {
            for (self.outbound) |*out| if (out.active) switch (out.value) {
                .ready => |v| if (std.meta.eql(v.transient, id)) {
                    out.active = false;
                },
                .denied => |v| if (std.meta.eql(v, id)) {
                    out.active = false;
                },
            };
        }
        fn managerFrom(self: *Self, context: ?*anyopaque) ?*ManagerSlot {
            const m = from(ManagerSlot, self.managers, context) orelse return null;
            return if (m.active) m else null;
        }
    };
}

fn nextGeneration(value: u32) u32 {
    const n = value +% 1;
    return if (n == 0) 1 else n;
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const p: *T = @ptrCast(@alignCast(context orelse return null));
    const begin = @intFromPtr(slots.ptr);
    const address = @intFromPtr(p);
    return if (address >= begin and address < begin + slots.len * @sizeOf(T) and (address - begin) % @sizeOf(T) == 0) p else null;
}

fn afterDestroy(state: anytype) @TypeOf(state) {
    return switch (state) {
        .queued => .retired,
        .ready => .remove_queued,
        else => state,
    };
}

test "transient seat generations never wrap to zero" {
    try std.testing.expectEqual(@as(u32, 1), nextGeneration(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 8), nextGeneration(7));
}

test "transient publication ordering transitions" {
    const S = enum { free, queued, adding, ready, remove_queued, removing, retired };
    var state: S = .queued;
    state = .adding;
    // `ready` is intentionally impossible until the add completion callback.
    try std.testing.expectEqual(S.adding, state);
    state = .ready;
    try std.testing.expectEqual(S.ready, state);
}

test "destroy while adding suppresses ready and ordinary destroy removes" {
    const S = enum { free, queued, adding, ready, remove_queued, removing, retired };
    try std.testing.expectEqual(S.adding, afterDestroy(S.adding));
    // The add callback observes the missing handle and chooses remove_queued.
    try std.testing.expectEqual(S.remove_queued, S.remove_queued);
    try std.testing.expectEqual(S.remove_queued, afterDestroy(S.ready));
    try std.testing.expectEqual(S.retired, afterDestroy(S.queued));
}

test "slot recycling predicate waits for every owner" {
    const recyclable = struct {
        fn check(handle: bool, global: bool, resources: usize, devices: usize) bool {
            return !handle and !global and resources == 0 and devices == 0;
        }
    }.check;
    try std.testing.expect(!recyclable(false, false, 1, 0));
    try std.testing.expect(!recyclable(false, false, 0, 1));
    try std.testing.expect(!recyclable(true, false, 0, 0));
    try std.testing.expect(recyclable(false, false, 0, 0));
}
