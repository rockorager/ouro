//! Wayland ownership for linux-drm-syncobj-v1 timelines and surface state.

const std = @import("std");
const linux = std.os.linux;
const wayring = @import("wayring");
const drm_syncobj = @import("../drm_syncobj.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    surface_capacity: usize = 8,
    timeline_capacity: usize = 16,

    fn validate(config: Config) !void {
        if (config.surface_capacity == 0 or config.surface_capacity >= none or
            config.timeline_capacity == 0 or config.timeline_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_linux_drm_syncobj_manager_v1;
        const Surface = protocol.wp_linux_drm_syncobj_surface_v1;
        const Timeline = protocol.wp_linux_drm_syncobj_timeline_v1;

        const Header = struct {
            active: bool = false,
            index: u32 = 0,
            next_free: u32 = none,
        };
        const SurfaceSlot = struct {
            header: Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            surface: CoreSurface.SurfaceId = undefined,
            peer: wayring.io_uring.Peer = undefined,
        };
        const TimelineSlot = struct {
            header: Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            timeline: *drm_syncobj.Timeline = undefined,
            peer: wayring.io_uring.Peer = undefined,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        device: *drm_syncobj.Device,
        surfaces: Pool(SurfaceSlot),
        timelines: Pool(TimelineSlot),
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *CoreSurface,
            device: *drm_syncobj.Device,
            config: Config,
        ) !Self {
            try config.validate();
            var surfaces = try Pool(SurfaceSlot).init(allocator, config.surface_capacity);
            errdefer surfaces.deinit();
            var timelines = try Pool(TimelineSlot).init(allocator, config.timeline_capacity);
            errdefer timelines.deinit();
            return .{
                .allocator = allocator,
                .core = core,
                .device = device,
                .surfaces = surfaces,
                .timelines = timelines,
            };
        }

        pub fn deinit(adapter: *Self) void {
            for (adapter.surfaces.entries.items) |slot| if (slot.header.active)
                adapter.releaseSurface(slot);
            for (adapter.timelines.entries.items) |slot| if (slot.header.active)
                adapter.releaseTimeline(slot);
            adapter.surfaces.deinit();
            adapter.timelines.deinit();
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            adapter.global = try runtime.addGlobalWithBinder(&Manager.info, 1, adapter, bind);
            return adapter.global.?;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            return adapter.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                peer,
                target,
                message,
                fds,
            );
        }

        pub fn requestOn(
            adapter: *Self,
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
                if (target.object.context != @as(?*anyopaque, @ptrCast(adapter))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_surface => |value| {
                        const surface = adapter.core.surfaceIdOn(server_objects, value.surface) catch
                            return try adapter.managerError(
                                actor,
                                decoded.handle.id,
                                Manager.@"error".surface_exists.value,
                                "invalid syncobj surface",
                            );
                        if (!samePeer(try adapter.core.surfacePeer(surface), peer))
                            return try adapter.managerError(
                                actor,
                                decoded.handle.id,
                                Manager.@"error".surface_exists.value,
                                "foreign syncobj surface",
                            );
                        const slot = adapter.surfaces.acquire() catch return try adapter.noMemory(actor);
                        const admitted = Manager.admit_get_surface(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |cause| {
                            adapter.surfaces.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        adapter.core.enableExplicitSync(surface, admitted.id) catch |cause| {
                            _ = server_objects.cancelClient(admitted.id) catch unreachable;
                            adapter.surfaces.release(slot);
                            return switch (cause) {
                                error.ExplicitSyncExists => try adapter.managerError(
                                    actor,
                                    decoded.handle.id,
                                    Manager.@"error".surface_exists.value,
                                    "syncobj surface already exists",
                                ),
                                else => try adapter.failure(actor, decoded.handle.id, cause),
                            };
                        };
                        slot.resource = admitted.id;
                        slot.surface = surface;
                        slot.peer = peer;
                    },
                    .import_timeline => |value| {
                        defer _ = linux.close(value.fd);
                        const timeline = adapter.device.importTimeline(value.fd) catch
                            return try adapter.managerError(
                                actor,
                                decoded.handle.id,
                                Manager.@"error".invalid_timeline.value,
                                "invalid syncobj timeline",
                            );
                        var timeline_owned = true;
                        errdefer if (timeline_owned) timeline.unreference();
                        const slot = adapter.timelines.acquire() catch return try adapter.noMemory(actor);
                        const admitted = Manager.admit_import_timeline(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |cause| {
                            adapter.timelines.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.timeline = timeline;
                        slot.peer = peer;
                        timeline_owned = false;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Timeline.info) {
                const slot = adapter.timelines.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Timeline, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Surface.info) return null;
            const slot = adapter.surfaces.fromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Surface, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .set_acquire_point => |value| if (try adapter.setPoint(
                    actor,
                    server_objects,
                    slot,
                    value.timeline,
                    value.point_hi,
                    value.point_lo,
                    true,
                )) |control| return control,
                .set_release_point => |value| if (try adapter.setPoint(
                    actor,
                    server_objects,
                    slot,
                    value.timeline,
                    value.point_hi,
                    value.point_lo,
                    false,
                )) |control| return control,
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn setPoint(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            surface: *SurfaceSlot,
            timeline_id: u32,
            high: u32,
            low: u32,
            acquire: bool,
        ) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(timeline_id) orelse
                return adapter.surfaceError(actor, surface.resource.id, "invalid syncobj timeline");
            const object = server_objects.namespace.resolve(handle) orelse
                return adapter.surfaceError(actor, surface.resource.id, "invalid syncobj timeline");
            const timeline = adapter.timelines.fromObject(object) orelse
                return adapter.surfaceError(actor, surface.resource.id, "invalid syncobj timeline");
            if (!std.meta.eql(timeline.resource, handle) or !samePeer(timeline.peer, surface.peer))
                return adapter.surfaceError(actor, surface.resource.id, "invalid syncobj timeline");
            var point = timeline.timeline.point(drm_syncobj.pointValue(high, low)) catch |cause|
                return adapter.failure(actor, surface.resource.id, cause);
            var point_owned = true;
            errdefer if (point_owned) point.deinit();
            if (acquire)
                adapter.core.setExplicitSyncAcquire(surface.surface, surface.resource, point) catch
                    return adapter.surfaceError(actor, surface.resource.id, "syncobj surface no longer exists")
            else
                adapter.core.setExplicitSyncRelease(surface.surface, surface.resource, point) catch
                    return adapter.surfaceError(actor, surface.resource.id, "syncobj surface no longer exists");
            point_owned = false;
            return null;
        }

        pub fn resourceRemoved(
            adapter: *Self,
            handle: objects.Handle,
            object: objects.Object,
        ) bool {
            if (object.interface == &Surface.info) {
                const slot = adapter.surfaces.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseSurface(slot);
                return true;
            }
            if (object.interface == &Timeline.info) {
                const slot = adapter.timelines.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseTimeline(slot);
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        pub fn disconnected(adapter: *Self, peer: wayring.io_uring.Peer) void {
            for (adapter.surfaces.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer)) adapter.releaseSurface(slot);
            for (adapter.timelines.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer)) adapter.releaseTimeline(slot);
        }

        fn releaseSurface(adapter: *Self, slot: *SurfaceSlot) void {
            adapter.core.disableExplicitSync(slot.surface, slot.resource);
            adapter.surfaces.release(slot);
        }

        fn releaseTimeline(adapter: *Self, slot: *TimelineSlot) void {
            slot.timeline.unreference();
            adapter.timelines.release(slot);
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn managerError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }

        fn surfaceError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Surface.@"error".no_surface.value, message);
            return .stop;
        }

        fn failure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.OutOfMemory, error.Exhausted => adapter.noMemory(actor),
                else => adapter.managerError(actor, id, 0, @errorName(cause)),
            };
        }
    };
}

fn Pool(comptime T: type) type {
    return struct {
        allocator: std.mem.Allocator,
        entries: std.ArrayListUnmanaged(*T) = .empty,
        free_head: u32 = none,

        fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            var pool: @This() = .{ .allocator = allocator };
            errdefer pool.deinit();
            try pool.entries.ensureTotalCapacity(allocator, capacity);
            for (0..capacity) |_| {
                const slot = try allocator.create(T);
                slot.* = .{ .header = .{
                    .index = @intCast(pool.entries.items.len),
                    .next_free = pool.free_head,
                } };
                pool.free_head = slot.header.index;
                pool.entries.appendAssumeCapacity(slot);
            }
            return pool;
        }

        fn deinit(pool: *@This()) void {
            for (pool.entries.items) |slot| {
                std.debug.assert(!slot.header.active);
                pool.allocator.destroy(slot);
            }
            pool.entries.deinit(pool.allocator);
            pool.* = undefined;
        }

        fn acquire(pool: *@This()) !*T {
            if (pool.free_head == none) {
                if (pool.entries.items.len >= none) return error.Exhausted;
                const slot = try pool.allocator.create(T);
                errdefer pool.allocator.destroy(slot);
                slot.* = .{ .header = .{
                    .active = true,
                    .index = @intCast(pool.entries.items.len),
                } };
                try pool.entries.append(pool.allocator, slot);
                return slot;
            }
            const slot = pool.entries.items[pool.free_head];
            pool.free_head = slot.header.next_free;
            const index = slot.header.index;
            slot.* = .{ .header = .{ .active = true, .index = index } };
            return slot;
        }

        fn release(pool: *@This(), slot: *T) void {
            std.debug.assert(slot.header.active);
            const index = slot.header.index;
            slot.* = .{ .header = .{ .index = index, .next_free = pool.free_head } };
            pool.free_head = index;
        }

        fn fromObject(pool: *@This(), object: *const objects.Object) ?*T {
            const pointer = object.context orelse return null;
            for (pool.entries.items) |slot|
                if (slot.header.active and pointer == @as(*anyopaque, @ptrCast(slot))) return slot;
            return null;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "linux-drm-syncobj: generated wire adapter is complete" {
    const protocol = @import("core_protocol");
    const Core = @import("core_surface.zig").Adapter(protocol);
    const Syncobj = Adapter(protocol, Core);
    std.testing.refAllDecls(Syncobj);
}

test "linux-drm-syncobj: resource pools grow without moving live entries" {
    const Entry = struct {
        header: struct {
            active: bool = false,
            index: u32 = 0,
            next_free: u32 = none,
        } = .{},
    };
    var pool = try Pool(Entry).init(std.testing.allocator, 1);
    defer pool.deinit();
    const first = try pool.acquire();
    const address = @intFromPtr(first);
    const second = try pool.acquire();
    try std.testing.expectEqual(address, @intFromPtr(first));
    pool.release(first);
    pool.release(second);
}
