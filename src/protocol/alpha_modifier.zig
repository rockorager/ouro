//! Growable alpha-modifier-v1 ownership and double-buffered surface state.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;

pub const Config = struct {
    /// Initial allocation only; resource ownership grows with client demand.
    resource_capacity: usize = 16,
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_alpha_modifier_v1;
        const Modifier = protocol.wp_alpha_modifier_surface_v1;

        const Kind = enum { manager, modifier };
        const Resource = struct {
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            surface: ?CoreSurface.SurfaceId = null,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        resources: std.ArrayListUnmanaged(*Resource) = .empty,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            if (config.resource_capacity == 0) return error.InvalidConfig;
            var self: Self = .{
                .allocator = allocator,
                .core = core,
            };
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
            return self.create(.manager, binding.resource, binding.peer, null) catch
                return error.OutOfMemory;
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
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (!std.meta.eql(resource.handle, handle)) return null;
            if (resource.kind == .manager and target.object.interface == &Manager.info) {
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_surface => |value| {
                        const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                            return try self.invalidObject(actor, "invalid alpha surface");
                        const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                            return try self.invalidObject(actor, "invalid alpha surface");
                        const surface = self.core.surfaceIdObject(surface_handle, surface_object) catch
                            return try self.invalidObject(actor, "invalid alpha surface");
                        for (self.resources.items) |item| if (item.kind == .modifier and
                            item.surface != null and std.meta.eql(item.surface.?, surface))
                            return try self.managerError(actor, decoded.handle.id, "alpha modifier already exists");
                        const child = self.create(.modifier, undefined, resource.peer, surface) catch
                            return try self.noMemory(actor);
                        const admitted = Manager.admit_get_surface(
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
            if (resource.kind == .modifier and target.object.interface == &Modifier.info) {
                const decoded = try wayring.server.decodeRequest(Modifier, server_objects, message, fds);
                const destination = (if (resource.surface) |id|
                    self.core.getSurfaceById(id) catch null
                else
                    null) orelse return try self.surfaceError(
                    actor,
                    decoded.handle.id,
                    "alpha modifier surface no longer exists",
                );
                switch (decoded.value) {
                    .destroy => destination.setAlphaMultiplier(std.math.maxInt(u32)),
                    .set_multiplier => |value| {
                        destination.setAlphaMultiplier(value.factor);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            const resource = self.fromObject(&object) orelse return false;
            if (!std.meta.eql(resource.handle, handle)) return false;
            self.remove(resource);
            return true;
        }

        pub fn surfaceRemoved(self: *Self, id: CoreSurface.SurfaceId) void {
            for (self.resources.items) |resource| {
                if (resource.kind == .modifier and resource.surface != null and
                    std.meta.eql(resource.surface.?, id))
                    resource.surface = null;
            }
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            var index: usize = self.resources.items.len;
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

        fn managerError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Manager.@"error".already_constructed.value, message);
            return .stop;
        }
        fn surfaceError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Modifier.@"error".no_surface.value, message);
            return .stop;
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn invalidObject(_: *Self, actor: *wayring.connection.Actor, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 0, message);
            return .stop;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
