//! Bounded tablet-v2 wire-resource ownership.
//!
//! Physical tablet state belongs to `input/tablet.zig`. This adapter owns only
//! per-client protocol resources. It remains unadvertised until tablet, tool,
//! and pad synchronization and event delivery are complete.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    tablet_seat_capacity: usize = 16,
    global_version: u32 = 2,

    fn validate(config: Config) !void {
        if (config.manager_capacity == 0 or config.manager_capacity >= none or
            config.tablet_seat_capacity == 0 or config.tablet_seat_capacity >= none or
            config.global_version == 0 or config.global_version > 2)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_tablet_manager_v2;
        const TabletSeat = protocol.zwp_tablet_seat_v2;

        const ManagerSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        const Binding = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource_present: bool = false,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            child_references: usize = 0,
        };

        allocator: std.mem.Allocator,
        seat: *Seat,
        managers: []ManagerSlot,
        bindings: []Binding,
        manager_free: u32 = 0,
        binding_free: u32 = 0,
        global_version: u32,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(
            allocator: std.mem.Allocator,
            seat: *Seat,
            config: Config,
        ) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const bindings = try allocator.alloc(Binding, config.tablet_seat_capacity);
            for (managers, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < managers.len) @intCast(i + 1) else none,
            };
            for (bindings, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < bindings.len) @intCast(i + 1) else none,
            };
            return .{
                .allocator = allocator,
                .seat = seat,
                .managers = managers,
                .bindings = bindings,
                .global_version = config.global_version,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.bindings);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(
                &Manager.info,
                self.global_version,
                self,
                bind,
            );
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = self.acquireManager() catch return error.OutOfMemory;
            slot.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                peer,
                target,
                message,
                fds,
            );
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
                const manager = self.managerFromObject(target.object) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer))
                    return null;
                const decoded = try wayring.server.decodeRequest(
                    Manager,
                    server_objects,
                    message,
                    fds,
                );
                switch (decoded.value) {
                    .destroy => {},
                    .get_tablet_seat => |value| {
                        if (!self.seat.validateSeatOn(server_objects, peer, value.seat))
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                "invalid tablet seat wl_seat",
                            );
                        const binding = self.acquireBinding() catch return try self.noMemory(actor);
                        binding.peer = peer;
                        const admitted = Manager.admit_get_tablet_seat(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .tablet_seat = binding },
                        ) catch |err| {
                            self.releaseBinding(self.bindingIndex(binding));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        binding.resource = admitted.tablet_seat;
                        binding.resource_present = true;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &TabletSeat.info) return null;
            const binding = self.bindingFromObject(target.object) orelse return null;
            if (!binding.resource_present or !std.meta.eql(binding.resource, handle) or
                !samePeer(binding.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(
                TabletSeat,
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

        pub fn resourceRemoved(
            self: *Self,
            handle: objects.Handle,
            object: objects.Object,
        ) bool {
            if (object.interface == &Manager.info) {
                const slot = self.managerFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.releaseManager(self.managerIndex(slot));
                return true;
            }
            if (object.interface != &TabletSeat.info) return false;
            const binding = self.bindingFromObject(&object) orelse return false;
            if (!binding.resource_present or !std.meta.eql(binding.resource, handle)) return false;
            binding.resource_present = false;
            if (binding.child_references == 0) self.releaseBinding(self.bindingIndex(binding));
            return true;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.managers, 0..) |slot, i|
                if (slot.active and samePeer(slot.peer, peer)) self.releaseManager(@intCast(i));
            for (self.bindings, 0..) |slot, i|
                if (slot.active and samePeer(slot.peer, peer)) self.releaseBinding(@intCast(i));
        }

        fn acquireManager(self: *Self) !*ManagerSlot {
            if (self.manager_free == none) return error.Exhausted;
            const index = self.manager_free;
            const slot = &self.managers[index];
            self.manager_free = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn releaseManager(self: *Self, index: u32) void {
            const slot = &self.managers[index];
            if (!slot.active) return;
            slot.* = .{ .next_free = self.manager_free };
            self.manager_free = index;
        }

        fn acquireBinding(self: *Self) !*Binding {
            if (self.binding_free == none) return error.Exhausted;
            const index = self.binding_free;
            const slot = &self.bindings[index];
            self.binding_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation };
            return slot;
        }

        fn releaseBinding(self: *Self, index: u32) void {
            const slot = &self.bindings[index];
            if (!slot.active) return;
            const generation = bump(slot.generation);
            slot.* = .{
                .generation = generation,
                .next_free = if (generation == 0) none else self.binding_free,
            };
            if (generation != 0) self.binding_free = index;
        }

        fn retainBinding(self: *Self, index: u32, generation: u32) !void {
            if (index >= self.bindings.len) return error.StaleBinding;
            const slot = &self.bindings[index];
            if (!slot.active or slot.generation != generation) return error.StaleBinding;
            slot.child_references = std.math.add(usize, slot.child_references, 1) catch
                return error.Exhausted;
        }

        fn releaseBindingReference(self: *Self, index: u32, generation: u32) void {
            if (index >= self.bindings.len) return;
            const slot = &self.bindings[index];
            if (!slot.active or slot.generation != generation or slot.child_references == 0)
                return;
            slot.child_references -= 1;
            if (!slot.resource_present and slot.child_references == 0)
                self.releaseBinding(index);
        }

        fn managerFromObject(self: *Self, object: *const objects.Object) ?*ManagerSlot {
            return fromContext(ManagerSlot, self.managers, object.context);
        }

        fn bindingFromObject(self: *Self, object: *const objects.Object) ?*Binding {
            return fromContext(Binding, self.bindings, object.context);
        }

        fn managerIndex(self: *const Self, slot: *const ManagerSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.managers.ptr)) /
                @sizeOf(ManagerSlot));
        }

        fn bindingIndex(self: *const Self, slot: *const Binding) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.bindings.ptr)) /
                @sizeOf(Binding));
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, object_id, 0, message);
            return .stop;
        }

        fn failure(
            self: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return self.protocolError(actor, object_id, @errorName(cause));
        }
    };
}

fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const bytes = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    const end = std.math.add(usize, start, bytes) catch return null;
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0)
        return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active and @intFromPtr(slot) == address) slot else null;
}

fn bump(generation: u32) u32 {
    return if (generation == std.math.maxInt(u32)) 0 else generation + 1;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "tablet-v2: tablet-seat parent retires only after its children" {
    const protocol = @import("core_protocol");
    const FakeSeat = struct {
        pub fn validateSeatOn(_: *@This(), _: anytype, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    };
    const TestAdapter = Adapter(protocol, FakeSeat);
    var seat: FakeSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
    });
    defer adapter.deinit();

    const binding = try adapter.acquireBinding();
    const index = adapter.bindingIndex(binding);
    const generation = binding.generation;
    binding.resource_present = true;
    try adapter.retainBinding(index, generation);
    try adapter.retainBinding(index, generation);

    binding.resource_present = false;
    adapter.releaseBindingReference(index, generation);
    try std.testing.expect(binding.active);
    try std.testing.expectEqual(@as(usize, 1), binding.child_references);
    adapter.releaseBindingReference(index, generation);
    try std.testing.expect(!binding.active);
    try std.testing.expectError(error.StaleBinding, adapter.retainBinding(index, generation));
}

test "tablet-v2: disconnect matches the complete peer generation" {
    const protocol = @import("core_protocol");
    const FakeSeat = struct {
        pub fn validateSeatOn(_: *@This(), _: anytype, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    };
    const TestAdapter = Adapter(protocol, FakeSeat);
    var seat: FakeSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 2,
        .tablet_seat_capacity = 2,
    });
    defer adapter.deinit();

    const stale = try adapter.acquireBinding();
    stale.peer = .{ .slot = 4, .generation = 1 };
    const live = try adapter.acquireBinding();
    live.peer = .{ .slot = 4, .generation = 2 };
    adapter.disconnected(stale.peer);
    try std.testing.expect(!stale.active);
    try std.testing.expect(live.active);
}
