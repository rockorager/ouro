//! Growable wl_subcompositor ownership and synchronized commit policy.

const std = @import("std");
const wayring = @import("wayring");
const subsurface_state = @import("../subsurface.zig");
const surface_state = @import("../surface.zig");

const objects = wayring.objects;
const none = std.math.maxInt(u32);
const subsurface_role_id: surface_state.RoleId = 0x7375_6273_7572_6663;

pub const Config = struct {
    resource_capacity: usize = 16,
    surface_capacity: usize = 16,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none or
            config.surface_capacity == 0 or config.surface_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Core: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wl_subcompositor;
        const Subsurface = protocol.wl_subsurface;
        const Graph = subsurface_state.Graph(Core.SurfaceId, void);

        pub const StackEntry = Graph.StackEntry;
        pub const Placement = Graph.Placement;

        const Slot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            child: Core.SurfaceId = undefined,
        };

        allocator: std.mem.Allocator,
        core: *Core,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: []*Slot,
        free_head: u32 = 0,
        graph: Graph,
        surface_scratch: []Core.SurfaceId,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *Core,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try allocSlots(allocator, config.resource_capacity);
            errdefer freeSlots(allocator, slots);
            const scratch = try allocator.alloc(Core.SurfaceId, config.surface_capacity);
            errdefer allocator.free(scratch);
            var graph = try Graph.init(allocator, config.surface_capacity, 1);
            errdefer graph.deinit(allocator);
            for (slots, 0..) |slot, index| slot.* = .{
                .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
            };
            return .{
                .allocator = allocator,
                .core = core,
                .slots = slots,
                .graph = graph,
                .surface_scratch = scratch,
            };
        }

        pub fn deinit(self: *Self) void {
            self.graph.deinit(self.allocator);
            self.allocator.free(self.surface_scratch);
            freeSlots(self.allocator, self.slots);
            self.* = undefined;
        }

        /// Connects commit policy after this owner reaches its stable address.
        pub fn connect(self: *Self) !void {
            try self.core.setContentCommitHook(.{
                .context = self,
                .plan_fn = contentPlan,
                .committed_fn = contentCommitted,
            });
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
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
            if (target.object.interface != &Manager.info and
                target.object.interface != &Subsurface.info)
                return null;
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
                    .get_subsurface => |payload| {
                        const child_handle = server_objects.namespace.lookupHandle(payload.surface) orelse
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, "invalid child surface");
                        const parent_handle = server_objects.namespace.lookupHandle(payload.parent) orelse
                            return try self.managerError(actor, decoded.handle.id, .bad_parent, "invalid parent surface");
                        const child = self.core.surfaceId(child_handle) catch
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, "invalid child surface");
                        const parent = self.core.surfaceId(parent_handle) catch
                            return try self.managerError(actor, decoded.handle.id, .bad_parent, "invalid parent surface");
                        if (!samePeer(try self.core.surfacePeer(child), peer))
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, "foreign child surface");
                        if (!samePeer(try self.core.surfacePeer(parent), peer))
                            return try self.managerError(actor, decoded.handle.id, .bad_parent, "foreign parent surface");
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        const slot_index = self.slotIndex(slot);
                        const surface = self.core.getSurfaceById(child) catch |cause| {
                            self.release(slot_index);
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, @errorName(cause));
                        };
                        surface.role.assign(subsurface_role_id, true) catch |cause| {
                            self.release(slot_index);
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, @errorName(cause));
                        };
                        self.graph.add(child, parent) catch |cause| {
                            surface.role.deactivateObject(subsurface_role_id) catch unreachable;
                            self.release(slot_index);
                            if (cause == error.OutOfMemory) return try self.noMemory(actor);
                            return try self.managerError(actor, decoded.handle.id, .bad_surface, @errorName(cause));
                        };
                        const admitted = Manager.admit_get_subsurface(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .id = slot },
                        ) catch |cause| {
                            _ = self.graph.remove(child, &.{}) catch unreachable;
                            surface.role.deactivateObject(subsurface_role_id) catch unreachable;
                            self.release(slot_index);
                            return try self.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.peer = peer;
                        slot.child = child;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Subsurface.info) return null;
            const slot = self.fromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Subsurface, server_objects, message, fds);
            // Destroying the associated wl_surface makes the role object
            // inert; only its eventual destructor still has an effect.
            _ = self.core.getSurfaceById(slot.child) catch {
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            };
            switch (decoded.value) {
                .destroy => {},
                .set_position => |value| self.graph.setPosition(slot.child, value.x, value.y) catch |cause|
                    return try self.subsurfaceError(actor, decoded.handle.id, @errorName(cause)),
                .place_above => |value| self.place(server_objects, slot, value.sibling, true) catch |cause|
                    return try self.subsurfaceError(actor, decoded.handle.id, @errorName(cause)),
                .place_below => |value| self.place(server_objects, slot, value.sibling, false) catch |cause|
                    return try self.subsurfaceError(actor, decoded.handle.id, @errorName(cause)),
                .set_sync => self.graph.setSync(slot.child) catch |cause|
                    return try self.subsurfaceError(actor, decoded.handle.id, @errorName(cause)),
                .set_desync => self.setDesync(slot.child) catch |cause|
                    return try self.subsurfaceError(actor, decoded.handle.id, @errorName(cause)),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn place(
            self: *Self,
            server_objects: anytype,
            slot: *Slot,
            sibling_id: u32,
            above: bool,
        ) !void {
            const sibling_handle = server_objects.namespace.lookupHandle(sibling_id) orelse
                return error.UnknownObject;
            const sibling = self.core.surfaceId(sibling_handle) catch
                return error.StaleSurface;
            if (!samePeer(try self.core.surfacePeer(sibling), slot.peer))
                return error.ForeignSurface;
            if (above) try self.graph.placeAbove(slot.child, sibling) else try self.graph.placeBelow(slot.child, sibling);
        }

        fn setDesync(self: *Self, child: Core.SurfaceId) !void {
            try self.ensureSurfaceScratch();
            const changed = try self.graph.transitionDesync(child, self.surface_scratch);
            for (changed) |surface| _ = self.core.transitionSurfaceDesync(surface) catch continue;
        }

        fn contentPlan(
            context: *anyopaque,
            surface: Core.SurfaceId,
            dependencies: []Core.UpdateToken,
        ) !Core.ContentCommitPlan {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.ensureSurfaceScratch();
            const children = try self.graph.directChildren(surface, self.surface_scratch);
            var count: usize = 0;
            for (children) |child| if (try self.core.newestSynchronizedUpdate(child)) |update| {
                if (count == dependencies.len) return error.OutputTooSmall;
                dependencies[count] = update;
                count += 1;
            };
            return .{
                .kind = if (self.graph.effectivelySynchronized(surface)) .sync else .desync,
                .dependency_count = count,
            };
        }

        fn contentCommitted(context: *anyopaque, surface: Core.SurfaceId) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.graph.commitStructure(surface);
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Subsurface.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.setDesync(slot.child) catch {};
                _ = self.graph.remove(slot.child, &.{}) catch {};
                if (self.core.getSurfaceById(slot.child)) |surface|
                    surface.role.deactivateObject(subsurface_role_id) catch {}
                else |_| {}
                self.release(self.slotIndex(slot));
                return true;
            }
            if (object.interface == &protocol.wl_surface.info) {
                const id = self.core.surfaceIdObject(handle, &object) catch return false;
                self.graph.surfaceDestroyed(id);
                return false;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn surfaceForResource(
            self: *Self,
            handle: objects.Handle,
            object: *const objects.Object,
        ) ?Core.SurfaceId {
            if (object.interface != &Subsurface.info) return null;
            const slot = self.fromObject(object) orelse return null;
            return if (std.meta.eql(slot.resource, handle)) slot.child else null;
        }

        pub fn directChildren(self: *Self, parent: Core.SurfaceId) ![]const Core.SurfaceId {
            try self.ensureSurfaceScratch();
            return self.graph.directChildren(parent, self.surface_scratch);
        }

        pub fn stack(
            self: *Self,
            parent: Core.SurfaceId,
            output: []StackEntry,
        ) ![]StackEntry {
            return self.graph.stack(parent, output);
        }

        pub fn sceneOrder(
            self: *Self,
            root: Core.SurfaceId,
            output: []Core.SurfaceId,
        ) ![]Core.SurfaceId {
            return self.graph.sceneOrder(root, output);
        }

        pub fn position(self: *Self, child: Core.SurfaceId) !Graph.Position {
            return self.graph.position(child);
        }

        pub fn placement(self: *Self, child: Core.SurfaceId) !Placement {
            return self.graph.placement(child);
        }

        pub fn visible(self: *Self, child: Core.SurfaceId) !bool {
            return self.graph.isVisible(child);
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) try self.growSlots();
            const index = self.free_head;
            const slot = self.slots[index];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn release(self: *Self, index: u32) void {
            const slot = self.slots[index];
            slot.* = .{ .next_free = self.free_head };
            self.free_head = index;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            for (self.slots) |slot| if (@intFromPtr(slot) == @intFromPtr(pointer))
                return if (slot.active) slot else null;
            return null;
        }

        fn slotIndex(self: *Self, slot: *Slot) u32 {
            for (self.slots, 0..) |candidate, index| if (candidate == slot) return @intCast(index);
            unreachable;
        }

        fn allocSlots(allocator: std.mem.Allocator, count: usize) ![]*Slot {
            const slots = try allocator.alloc(*Slot, count);
            errdefer allocator.free(slots);
            var initialized: usize = 0;
            errdefer for (slots[0..initialized]) |slot| allocator.destroy(slot);
            while (initialized < count) : (initialized += 1)
                slots[initialized] = try allocator.create(Slot);
            return slots;
        }

        fn freeSlots(allocator: std.mem.Allocator, slots: []*Slot) void {
            for (slots) |slot| allocator.destroy(slot);
            allocator.free(slots);
        }

        fn growSlots(self: *Self) !void {
            const old_len = self.slots.len;
            if (old_len >= none - 1) return error.OutOfMemory;
            const new_len = @min(@as(usize, none - 1), old_len + @max(old_len, 1));
            self.slots = try self.allocator.realloc(self.slots, new_len);
            var initialized = old_len;
            errdefer {
                for (self.slots[old_len..initialized]) |slot| self.allocator.destroy(slot);
                self.slots = self.allocator.realloc(self.slots, old_len) catch self.slots[0..old_len];
            }
            while (initialized < new_len) : (initialized += 1) {
                const slot = try self.allocator.create(Slot);
                slot.* = .{
                    .next_free = if (initialized + 1 < new_len) @intCast(initialized + 1) else none,
                };
                self.slots[initialized] = slot;
            }
            self.free_head = @intCast(old_len);
        }

        fn ensureSurfaceScratch(self: *Self) !void {
            const minimum = self.graph.activeSurfaceCount();
            if (self.surface_scratch.len >= minimum) return;
            self.surface_scratch = try self.allocator.realloc(self.surface_scratch, minimum);
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn managerError(self: *Self, actor: *wayring.connection.Actor, id: u32, code: Manager.@"error", message: []const u8) !wayring.dispatch.Control {
            _ = self;
            try ProtocolCore.postError(actor, id, code.value, message);
            return .stop;
        }

        fn subsurfaceError(self: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            _ = self;
            try ProtocolCore.postError(actor, id, Subsurface.@"error".bad_surface.value, message);
            return .stop;
        }

        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return self.subsurfaceError(actor, id, @errorName(cause));
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "subcompositor: synchronized child is claimed by parent and desync transitions queue" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
        pub const UpdateToken = struct { index: u32, generation: u32 };
        pub const ContentCommitPlan = struct {
            kind: @import("../content_update.zig").Kind = .desync,
            dependency_count: usize = 0,
        };
        pub const ContentCommitHook = struct {
            context: *anyopaque,
            plan_fn: *const fn (*anyopaque, SurfaceId, []UpdateToken) anyerror!ContentCommitPlan,
            committed_fn: *const fn (*anyopaque, SurfaceId) void,
        };

        hook: ?ContentCommitHook = null,
        child_update: ?UpdateToken = null,
        transitioned: usize = 0,

        pub fn setContentCommitHook(core: *@This(), hook: ContentCommitHook) !void {
            if (core.hook != null) return error.AlreadyInstalled;
            core.hook = hook;
        }

        pub fn newestSynchronizedUpdate(core: *@This(), id: SurfaceId) !?UpdateToken {
            return if (id.index == 1) core.child_update else null;
        }

        pub fn transitionSurfaceDesync(core: *@This(), _: SurfaceId) !usize {
            core.transitioned += 1;
            return 1;
        }
    };
    const TestAdapter = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .resource_capacity = 2,
        .surface_capacity = 3,
    });
    defer adapter.deinit();
    try adapter.connect();

    const parent: FakeCore.SurfaceId = .{ .index = 0, .generation = 1 };
    const child: FakeCore.SurfaceId = .{ .index = 1, .generation = 1 };
    try adapter.graph.add(child, parent);
    try adapter.graph.setPosition(child, 7, -3);
    core.child_update = .{ .index = 4, .generation = 2 };

    var dependencies: [2]FakeCore.UpdateToken = undefined;
    const child_plan = try core.hook.?.plan_fn(core.hook.?.context, child, &dependencies);
    try std.testing.expectEqual(@import("../content_update.zig").Kind.sync, child_plan.kind);
    const parent_plan = try core.hook.?.plan_fn(core.hook.?.context, parent, &dependencies);
    try std.testing.expectEqual(@as(usize, 1), parent_plan.dependency_count);
    try std.testing.expectEqual(core.child_update.?, dependencies[0]);

    core.hook.?.committed_fn(core.hook.?.context, parent);
    try std.testing.expect(try adapter.visible(child));
    try std.testing.expectEqual(
        subsurface_state.Graph(FakeCore.SurfaceId, void).Position{ .x = 7, .y = -3 },
        try adapter.position(child),
    );
    try adapter.setDesync(child);
    try std.testing.expectEqual(@as(usize, 1), core.transitioned);
}

test "subcompositor: resource and graph storage grow without moving live resources" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
        pub const UpdateToken = struct { index: u32, generation: u32 };
        pub const ContentCommitPlan = struct {};

        pub fn setContentCommitHook(_: *@This(), _: anytype) !void {}
    };
    const TestAdapter = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .resource_capacity = 1,
        .surface_capacity = 1,
    });
    defer adapter.deinit();

    const first = try adapter.acquire();
    _ = try adapter.acquire();
    _ = try adapter.acquire();
    try std.testing.expectEqual(first, adapter.slots[0]);

    const parent: FakeCore.SurfaceId = .{ .index = 0, .generation = 1 };
    var index: u32 = 1;
    while (index <= 32) : (index += 1) try adapter.graph.add(
        .{ .index = index, .generation = 1 },
        parent,
    );
    try std.testing.expectEqual(@as(usize, 32), (try adapter.directChildren(parent)).len);
    try std.testing.expect(adapter.surface_scratch.len >= 33);
}
