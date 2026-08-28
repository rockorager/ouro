//! Growable pointer-warp-v1 manager and silent policy bridge.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");

pub const Config = struct {
    /// Initial reservation only; manager ownership grows with client demand.
    resource_capacity: usize = 8,
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Manager = protocol.wp_pointer_warp_v1;

        pub const Handler = struct {
            context: ?*anyopaque = null,
            applyFn: *const fn (
                ?*anyopaque,
                wayring.io_uring.Peer,
                CoreSurface.SurfaceId,
                u32,
                i32,
                i32,
                u32,
            ) void,
        };

        const Resource = struct {
            header: slot_pool.Header = .{},
            handle: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        handler: Handler,
        resources: slot_pool.Pool(Resource),
        runtime: ?*Runtime = null,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *CoreSurface,
            handler: Handler,
            config: Config,
        ) !Self {
            if (config.resource_capacity == 0) return error.InvalidConfig;
            return .{
                .allocator = allocator,
                .core = core,
                .handler = handler,
                .resources = try slot_pool.Pool(Resource).init(allocator, config.resource_capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.resources.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            return try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const resource = try self.resources.acquire();
            resource.handle = binding.resource;
            resource.peer = binding.peer;
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
            const server_objects = try runtime.clients.get(peer);
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            const resource = self.fromObject(target.object) orelse return null;
            if (target.object.interface != &Manager.info or
                !std.meta.eql(resource.handle, handle) or !samePeer(resource.peer, peer)) return null;
            const actor = try runtime.clients.reactor.getActor(peer);
            const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .warp_pointer => |value| {
                    const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse null;
                    if (surface_handle) |candidate| if (server_objects.namespace.resolve(candidate)) |object| {
                        const surface = self.core.surfaceIdObject(candidate, object) catch null;
                        if (surface) |id| self.handler.applyFn(
                            self.handler.context,
                            peer,
                            id,
                            value.pointer,
                            value.x,
                            value.y,
                            value.serial,
                        );
                    };
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            const resource = self.fromObject(&object) orelse return false;
            if (!std.meta.eql(resource.handle, handle)) return false;
            self.remove(resource);
            return true;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            var index = self.resources.entries.items.len;
            while (index != 0) {
                index -= 1;
                const resource = self.resources.entries.items[index];
                if (resource.header.active and samePeer(resource.peer, peer)) self.remove(resource);
            }
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Resource {
            const context = object.context orelse return null;
            return self.resources.fromContext(context);
        }

        fn remove(self: *Self, resource: *Resource) void {
            self.resources.release(resource);
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
