//! ext-background-effect-v1 ownership and surface-local blur state.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;

pub const Config = struct {
    resource_capacity: usize = 16,
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.ext_background_effect_manager_v1;
        const Effect = protocol.ext_background_effect_surface_v1;

        const Kind = enum { manager, effect };
        const Resource = struct {
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            surface: ?CoreSurface.SurfaceId = null,
            capabilities_pending: bool = false,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        resources: std.ArrayListUnmanaged(*Resource) = .empty,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            if (config.resource_capacity == 0) return error.InvalidConfig;
            var self: Self = .{ .allocator = allocator, .core = core };
            try self.resources.ensureTotalCapacity(allocator, config.resource_capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.resources.items) |resource| self.allocator.destroy(resource);
            self.resources.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const resource = self.create(.manager, binding.resource, binding.peer, null) catch
                return error.OutOfMemory;
            resource.capabilities_pending = true;
            return resource;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return null;
            return self.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                target,
                message,
                fds,
            );
        }

        pub fn requestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const resource = self.fromObject(target.object) orelse return null;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
                return null;
            if (!std.meta.eql(resource.handle, handle)) return null;
            if (resource.kind == .manager and target.object.interface == &Manager.info) {
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_background_effect => |value| {
                        const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                            return try self.invalidObject(actor, "invalid background-effect surface");
                        const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                            return try self.invalidObject(actor, "invalid background-effect surface");
                        const surface = self.core.surfaceIdObject(surface_handle, surface_object) catch
                            return try self.invalidObject(actor, "invalid background-effect surface");
                        for (self.resources.items) |item| if (item.kind == .effect and
                            item.surface != null and std.meta.eql(item.surface.?, surface))
                            return try self.managerError(
                                actor,
                                decoded.handle.id,
                                "background effect already exists",
                            );
                        const child = self.create(.effect, undefined, resource.peer, surface) catch
                            return try self.noMemory(actor);
                        const admitted = Manager.admit_get_background_effect(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = child },
                        ) catch |err| {
                            self.remove(child);
                            return try self.managerError(actor, decoded.handle.id, @errorName(err));
                        };
                        child.handle = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (resource.kind == .effect and target.object.interface == &Effect.info) {
                const decoded = try wayring.server.decodeRequest(Effect, server_objects, message, fds);
                const surface = resource.surface orelse return try self.surfaceError(
                    actor,
                    decoded.handle.id,
                    "background-effect surface no longer exists",
                );
                switch (decoded.value) {
                    .destroy => self.core.setBlurRegionOn(server_objects, surface, null) catch |err|
                        return try self.surfaceError(actor, decoded.handle.id, @errorName(err)),
                    .set_blur_region => |value| self.core.setBlurRegionOn(
                        server_objects,
                        surface,
                        value.region,
                    ) catch |err| return try self.surfaceError(actor, decoded.handle.id, @errorName(err)),
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var count: usize = 0;
            for (self.resources.items) |resource| {
                if (resource.kind != .manager or !resource.capabilities_pending or
                    !samePeer(resource.peer, peer) or
                    server_objects.namespace.resolve(resource.handle) == null)
                    continue;
                Manager.encodeEvent(queue, resource.handle.id, .{ .capabilities = .{
                    .flags = Manager.capability.fromInt(Manager.capability.blur.value),
                } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return err,
                };
                resource.capabilities_pending = false;
                count += 1;
            }
            return count;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.resources.items) |resource|
                if (resource.kind == .manager and resource.capabilities_pending and
                    samePeer(resource.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            const resource = self.fromObject(&object) orelse return false;
            if (!std.meta.eql(resource.handle, handle)) return false;
            self.remove(resource);
            return true;
        }

        pub fn surfaceRemoved(self: *Self, id: CoreSurface.SurfaceId) void {
            for (self.resources.items) |resource| {
                if (resource.kind == .effect and resource.surface != null and
                    std.meta.eql(resource.surface.?, id))
                    resource.surface = null;
            }
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            var index = self.resources.items.len;
            while (index != 0) {
                index -= 1;
                const resource = self.resources.items[index];
                if (samePeer(resource.peer, peer)) self.remove(resource);
            }
        }

        fn create(
            self: *Self,
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            surface: ?CoreSurface.SurfaceId,
        ) !*Resource {
            const resource = try self.allocator.create(Resource);
            errdefer self.allocator.destroy(resource);
            resource.* = .{ .kind = kind, .handle = handle, .peer = peer, .surface = surface };
            try self.resources.append(self.allocator, resource);
            return resource;
        }

        fn remove(self: *Self, resource: *Resource) void {
            for (self.resources.items, 0..) |item, index| if (item == resource) {
                _ = self.resources.swapRemove(index);
                self.allocator.destroy(resource);
                return;
            };
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Resource {
            const context = object.context orelse return null;
            for (self.resources.items) |resource|
                if (@intFromPtr(resource) == @intFromPtr(context)) return resource;
            return null;
        }

        fn managerError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(
                actor,
                id,
                Manager.@"error".background_effect_exists.value,
                message,
            );
            return .stop;
        }
        fn surfaceError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Effect.@"error".surface_destroyed.value, message);
            return .stop;
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn invalidObject(
            _: *Self,
            actor: *wayring.connection.Actor,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 0, message);
            return .stop;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
