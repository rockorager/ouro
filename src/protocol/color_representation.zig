//! color-representation-v1 adapter for Ouro's RGB surface buffers.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const color = @import("../render/color.zig");

pub const Config = struct { resource_capacity: usize = 8 };

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_color_representation_manager_v1;
        const Surface = protocol.wp_color_representation_surface_v1;

        const Kind = enum { manager, surface };
        const Resource = struct {
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            surface: ?CoreSurface.SurfaceId = null,
            pending: u8 = 0,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        resources: std.ArrayListUnmanaged(*Resource) = .empty,
        initial_capacity: usize,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            if (config.resource_capacity == 0) return error.InvalidConfig;
            var self: Self = .{ .allocator = allocator, .core = core, .initial_capacity = config.resource_capacity };
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
            const resource = try self.create(.manager, binding.resource, binding.peer, null);
            resource.pending = 0;
            return resource;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return null;
            const actor = try runtime.clients.reactor.getActor(peer);
            return self.requestOn(actor, try runtime.clients.get(peer), target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const resource = self.fromObject(target.object) orelse return null;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (!std.meta.eql(resource.handle, handle)) return null;
            if (resource.kind == .manager and target.object.interface == &Manager.info) {
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_surface => |value| {
                        const wl_handle = server_objects.namespace.lookupHandle(value.surface) orelse return try self.invalidObject(actor, "invalid surface");
                        const wl_object = server_objects.namespace.resolve(wl_handle) orelse return try self.invalidObject(actor, "invalid surface");
                        const id = self.core.surfaceIdObject(wl_handle, wl_object) catch return try self.invalidObject(actor, "invalid surface");
                        for (self.resources.items) |item| if (item.kind == .surface and item.surface != null and std.meta.eql(item.surface.?, id))
                            return try self.managerError(actor, decoded.handle.id, "color representation surface exists");
                        const child = self.create(.surface, undefined, resource.peer, id) catch return try self.noMemory(actor);
                        const admitted = Manager.admit_get_surface(server_objects, decoded.handle, value, .{ .id = child }) catch |err| {
                            self.remove(child);
                            return try self.managerError(actor, decoded.handle.id, @errorName(err));
                        };
                        child.handle = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (resource.kind == .surface and target.object.interface == &Surface.info) {
                const decoded = try wayring.server.decodeRequest(Surface, server_objects, message, fds);
                const core_surface = if (resource.surface) |id| self.core.getSurfaceById(id) catch null else null;
                switch (decoded.value) {
                    .destroy => if (core_surface) |destination|
                        destination.setColorRepresentation(.{}),
                    .set_alpha_mode => |value| {
                        const destination = core_surface orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".inert.value, "inert surface");
                        const mode: color.AlphaMode = if (value.alpha_mode.value == Surface.alpha_mode.premultiplied_electrical.value)
                            .premultiplied_electrical
                        else if (value.alpha_mode.value == Surface.alpha_mode.premultiplied_optical.value)
                            .premultiplied_optical
                        else if (value.alpha_mode.value == Surface.alpha_mode.straight.value)
                            .straight
                        else
                            return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".alpha_mode.value, "unsupported alpha mode");
                        destination.setColorRepresentation(.{ .alpha_mode = mode });
                    },
                    .set_coefficients_and_range => |value| {
                        if (core_surface == null) return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".inert.value, "inert surface");
                        if (value.coefficients.value != Surface.coefficients.identity.value or value.range.value != Surface.range.full.value)
                            return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".coefficients.value, "unsupported coefficients or range");
                    },
                    .set_chroma_location => return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".chroma_location.value, "chroma location is unsupported for RGB"),
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.resources.items) |resource| {
                if (resource.kind != .manager or !samePeer(resource.peer, peer) or resource.pending >= 5 or server_objects.namespace.resolve(resource.handle) == null) continue;
                while (resource.pending < 5) {
                    const event: Manager.Event = switch (resource.pending) {
                        0 => .{ .supported_alpha_mode = .{ .alpha_mode = Surface.alpha_mode.premultiplied_electrical } },
                        1 => .{ .supported_alpha_mode = .{ .alpha_mode = Surface.alpha_mode.straight } },
                        2 => .{ .supported_alpha_mode = .{ .alpha_mode = Surface.alpha_mode.premultiplied_optical } },
                        3 => .{ .supported_coefficients_and_ranges = .{ .coefficients = Surface.coefficients.identity, .range = Surface.range.full } },
                        else => .{ .done = .{} },
                    };
                    Manager.encodeEvent(queue, resource.handle.id, event) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    resource.pending += 1;
                    count += 1;
                }
            }
            return count;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.resources.items) |r| if (r.kind == .manager and r.pending < 5 and samePeer(r.peer, peer)) return true;
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
                if (resource.kind == .surface and resource.surface != null and
                    std.meta.eql(resource.surface.?, id))
                {
                    resource.surface = null;
                }
            }
        }

        fn create(self: *Self, kind: Kind, handle: objects.Handle, peer: wayring.io_uring.Peer, surface: ?CoreSurface.SurfaceId) !*Resource {
            const resource = try self.allocator.create(Resource);
            errdefer self.allocator.destroy(resource);
            resource.* = .{ .kind = kind, .handle = handle, .peer = peer, .surface = surface };
            try self.resources.append(self.allocator, resource);
            return resource;
        }

        fn remove(self: *Self, resource: *Resource) void {
            for (self.resources.items, 0..) |item, i| if (item == resource) {
                _ = self.resources.swapRemove(i);
                self.allocator.destroy(resource);
                return;
            };
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Resource {
            const pointer = object.context orelse return null;
            for (self.resources.items) |resource| if (@intFromPtr(resource) == @intFromPtr(pointer)) return resource;
            return null;
        }

        fn managerError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Manager.@"error".surface_exists.value, message);
            return .stop;
        }
        fn surfaceError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
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
