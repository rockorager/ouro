//! Bounded tablet-v2 wire-resource ownership.
//!
//! Physical tablet state belongs to `input/tablet.zig`. This adapter owns only
//! per-client protocol resources. It remains unadvertised until tablet, tool,
//! and pad synchronization and event delivery are complete.

const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const platform = @import("../backend/input/platform.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    tablet_seat_capacity: usize = 16,
    tablet_capacity: usize = 64,
    outbound_capacity: usize = 256,
    global_version: u32 = 2,

    fn validate(config: Config) !void {
        if (config.manager_capacity == 0 or config.manager_capacity >= none or
            config.tablet_seat_capacity == 0 or config.tablet_seat_capacity >= none or
            config.tablet_capacity == 0 or config.tablet_capacity >= none or
            config.outbound_capacity == 0 or config.outbound_capacity >= none or
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
        const Tablet = protocol.zwp_tablet_v2;
        const Id = packed struct { index: u32, generation: u32 };

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
        const TabletSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            binding: Id = undefined,
            resource: ?objects.Handle = null,
            device: input.DeviceId = undefined,
        };
        const TabletEvent = union(enum) {
            create,
            id: struct { vendor: u32, product: u32 },
            done,
            removed,
        };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            tablet: Id = undefined,
            value: TabletEvent = undefined,
        };

        allocator: std.mem.Allocator,
        seat: *Seat,
        managers: []ManagerSlot,
        bindings: []Binding,
        tablets: []TabletSlot,
        outbound: []Outbound,
        manager_free: u32 = 0,
        binding_free: u32 = 0,
        tablet_free: u32 = 0,
        outbound_len: usize = 0,
        next_sequence: u64 = 1,
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
            errdefer allocator.free(bindings);
            const tablets = try allocator.alloc(TabletSlot, config.tablet_capacity);
            errdefer allocator.free(tablets);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            for (managers, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < managers.len) @intCast(i + 1) else none,
            };
            for (bindings, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < bindings.len) @intCast(i + 1) else none,
            };
            for (tablets, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < tablets.len) @intCast(i + 1) else none,
            };
            @memset(outbound, .{});
            return .{
                .allocator = allocator,
                .seat = seat,
                .managers = managers,
                .bindings = bindings,
                .tablets = tablets,
                .outbound = outbound,
                .global_version = config.global_version,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.tablets);
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
            if (target.object.interface == &TabletSeat.info) {
                const binding = self.bindingFromObject(target.object) orelse return null;
                if (!binding.resource_present or !std.meta.eql(binding.resource, handle) or
                    !samePeer(binding.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(TabletSeat, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Tablet.info) return null;
            const tablet = self.tabletFromObject(target.object) orelse return null;
            if (tablet.resource == null or !std.meta.eql(tablet.resource.?, handle)) return null;
            const binding = self.resolveBinding(tablet.binding) catch return null;
            if (!samePeer(binding.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Tablet, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        /// Fans one physical tablet out to every live tablet-seat resource.
        /// Admission is atomic: no binding observes the device unless all
        /// child and ordered outbound records are available.
        pub fn publishTablet(self: *Self, device: input.DeviceId, info: platform.DeviceInfo) !void {
            var bindings: usize = 0;
            for (self.bindings) |binding|
                bindings += @intFromBool(binding.active and binding.resource_present);
            const records_per_binding: usize = if (info.vendor != 0 or info.product != 0) 3 else 2;
            const needed = std.math.mul(usize, bindings, records_per_binding) catch
                return error.Exhausted;
            if (self.freeTablets() < bindings or
                self.outbound.len - self.outbound_len < needed)
                return error.Exhausted;
            for (self.bindings, 0..) |binding, binding_index| {
                if (!binding.active or !binding.resource_present) continue;
                const tablet = self.acquireTablet(.{
                    .index = @intCast(binding_index),
                    .generation = binding.generation,
                }) catch unreachable;
                tablet.device = device;
                const id = self.tabletId(tablet);
                self.enqueue(binding.peer, id, .create) catch unreachable;
                if (info.vendor != 0 or info.product != 0)
                    self.enqueue(binding.peer, id, .{ .id = .{
                        .vendor = info.vendor,
                        .product = info.product,
                    } }) catch unreachable;
                self.enqueue(binding.peer, id, .done) catch unreachable;
            }
        }

        pub fn removeTablet(self: *Self, device: input.DeviceId) !void {
            var count: usize = 0;
            for (self.tablets) |slot|
                count += @intFromBool(slot.active and std.meta.eql(slot.device, device));
            if (self.outbound.len - self.outbound_len < count) return error.Exhausted;
            for (self.tablets) |*slot| {
                if (!slot.active or !std.meta.eql(slot.device, device)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, self.tabletId(slot), .removed) catch unreachable;
            }
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.outbound_len == 0) return false;
            for (self.outbound) |slot|
                if (slot.active and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            while (self.oldest(peer)) |outbound| {
                const tablet = self.resolveTablet(outbound.tablet) catch {
                    self.dropOutbound(outbound);
                    completed += 1;
                    continue;
                };
                const binding = self.resolveBinding(tablet.binding) catch {
                    self.releaseTablet(outbound.tablet.index);
                    completed += 1;
                    continue;
                };
                switch (outbound.value) {
                    .create => {
                        if (!binding.resource_present) {
                            self.releaseTablet(outbound.tablet.index);
                            completed += 1;
                            continue;
                        }
                        const created = TabletSeat.construct_event_tablet_added(
                            protocol,
                            server_objects,
                            queue,
                            binding.resource,
                            .{ .id = .{ .context = tablet } },
                        ) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                            else => return err,
                        };
                        tablet.resource = created.id;
                    },
                    .id => |value| wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .id = .{ .vid = value.vendor, .pid = value.product } }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    },
                    .done => wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .done = .{} }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    },
                    .removed => wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .removed = .{} }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    },
                }
                self.dropOutbound(outbound);
                completed += 1;
            }
            return completed;
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
            if (object.interface == &TabletSeat.info) {
                const binding = self.bindingFromObject(&object) orelse return false;
                if (!binding.resource_present or !std.meta.eql(binding.resource, handle)) return false;
                binding.resource_present = false;
                if (binding.child_references == 0) self.releaseBinding(self.bindingIndex(binding));
                return true;
            }
            if (object.interface != &Tablet.info) return false;
            const tablet = self.tabletFromObject(&object) orelse return false;
            if (tablet.resource == null or !std.meta.eql(tablet.resource.?, handle)) return false;
            self.releaseTablet(self.tabletIndex(tablet));
            return true;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.tablets, 0..) |slot, i| if (slot.active) {
                const binding = self.resolveBinding(slot.binding) catch continue;
                if (samePeer(binding.peer, peer)) self.releaseTablet(@intCast(i));
            };
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

        fn acquireTablet(self: *Self, binding: Id) !*TabletSlot {
            if (self.tablet_free == none) return error.Exhausted;
            const index = self.tablet_free;
            const slot = &self.tablets[index];
            self.tablet_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation, .binding = binding };
            self.retainBinding(binding.index, binding.generation) catch |err| {
                slot.* = .{ .generation = generation, .next_free = self.tablet_free };
                self.tablet_free = index;
                return err;
            };
            return slot;
        }

        fn releaseTablet(self: *Self, index: u32) void {
            const slot = &self.tablets[index];
            if (!slot.active) return;
            const id = self.tabletId(slot);
            for (self.outbound) |*outbound| if (outbound.active and std.meta.eql(outbound.tablet, id))
                self.dropOutbound(outbound);
            const binding = slot.binding;
            const generation = bump(slot.generation);
            slot.* = .{ .generation = generation, .next_free = if (generation == 0) none else self.tablet_free };
            if (generation != 0) self.tablet_free = index;
            self.releaseBindingReference(binding.index, binding.generation);
        }

        fn resolveBinding(self: *Self, id: Id) !*Binding {
            if (id.index >= self.bindings.len) return error.StaleBinding;
            const slot = &self.bindings[id.index];
            if (!slot.active or slot.generation != id.generation) return error.StaleBinding;
            return slot;
        }

        fn resolveTablet(self: *Self, id: Id) !*TabletSlot {
            if (id.index >= self.tablets.len) return error.StaleTablet;
            const slot = &self.tablets[id.index];
            if (!slot.active or slot.generation != id.generation) return error.StaleTablet;
            return slot;
        }

        fn freeTablets(self: *const Self) usize {
            var count: usize = 0;
            for (self.tablets) |slot| count += @intFromBool(!slot.active and slot.generation != 0);
            return count;
        }

        fn enqueue(self: *Self, peer: wayring.io_uring.Peer, tablet: Id, value: TabletEvent) !void {
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = self.next_sequence, .peer = peer, .tablet = tablet, .value = value };
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

        fn dropOutbound(self: *Self, slot: *Outbound) void {
            if (!slot.active) return;
            slot.active = false;
            self.outbound_len -= 1;
        }

        fn managerFromObject(self: *Self, object: *const objects.Object) ?*ManagerSlot {
            return fromContext(ManagerSlot, self.managers, object.context);
        }

        fn bindingFromObject(self: *Self, object: *const objects.Object) ?*Binding {
            return fromContext(Binding, self.bindings, object.context);
        }

        fn tabletFromObject(self: *Self, object: *const objects.Object) ?*TabletSlot {
            return fromContext(TabletSlot, self.tablets, object.context);
        }

        fn managerIndex(self: *const Self, slot: *const ManagerSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.managers.ptr)) /
                @sizeOf(ManagerSlot));
        }

        fn bindingIndex(self: *const Self, slot: *const Binding) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.bindings.ptr)) /
                @sizeOf(Binding));
        }

        fn tabletId(self: *const Self, slot: *const TabletSlot) Id {
            return .{ .index = self.tabletIndex(slot), .generation = slot.generation };
        }

        fn tabletIndex(self: *const Self, slot: *const TabletSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.tablets.ptr)) /
                @sizeOf(TabletSlot));
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

test "tablet-v2: tablet publication is atomic and metadata stays ordered" {
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
        .tablet_seat_capacity = 2,
        .tablet_capacity = 2,
        .outbound_capacity = 6,
    });
    defer adapter.deinit();
    const first = try adapter.acquireBinding();
    first.resource_present = true;
    first.peer = .{ .slot = 1, .generation = 1 };
    const second = try adapter.acquireBinding();
    second.resource_present = true;
    second.peer = .{ .slot = 2, .generation = 1 };
    const device: input.DeviceId = .{ .slot = 3, .generation = 4, .seat_generation = 5 };

    try adapter.publishTablet(device, .{ .capabilities = .{ .tablet_tool = true }, .vendor = 10, .product = 20 });
    try std.testing.expectEqual(@as(usize, 6), adapter.outbound_len);
    try std.testing.expect(adapter.pendingOutbound(first.peer));
    const create = adapter.oldest(first.peer).?;
    try std.testing.expect(create.value == .create);
    create.active = false;
    adapter.outbound_len -= 1;
    const id = adapter.oldest(first.peer).?;
    try std.testing.expectEqual(@as(u32, 10), id.value.id.vendor);
    id.active = false;
    adapter.outbound_len -= 1;
    try std.testing.expect(adapter.oldest(first.peer).?.value == .done);

    try std.testing.expectError(error.Exhausted, adapter.publishTablet(device, .{ .capabilities = .{ .tablet_tool = true } }));
    try std.testing.expectEqual(@as(usize, 0), adapter.freeTablets());
}

test "tablet-v2: TX pressure cannot duplicate a server-created tablet" {
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
        .tablet_capacity = 1,
        .outbound_capacity = 3,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        8,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 3 };
    const binding = try adapter.acquireBinding();
    binding.peer = peer;
    binding.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_tablet_seat_v2.info,
        2,
        binding,
    );
    binding.resource_present = true;
    try adapter.publishTablet(
        .{ .slot = 1, .generation = 2, .seat_generation = 3 },
        .{ .capabilities = .{ .tablet_tool = true }, .vendor = 4, .product = 5 },
    );

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var first_queue = wayring.tx.Queue.init(&blocks, 12, &descriptors, 1);
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(peer, &server_objects, &first_queue));
    const resource = adapter.tablets[0].resource.?;
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_len);
    first_queue.deinit();

    var second_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    defer second_queue.deinit();
    try std.testing.expectEqual(@as(usize, 2), try adapter.flushOn(peer, &server_objects, &second_queue));
    try std.testing.expectEqual(resource, adapter.tablets[0].resource.?);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);
}
