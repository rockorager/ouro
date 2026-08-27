//! Bounded security-context-v1 resource, descriptor, and metadata ownership.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const linux = std.os.linux;

pub const Config = struct {
    resource_capacity: usize = 16,
    listener_capacity: usize = 8,
    metadata_bytes: usize = 4096,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.listener_capacity == 0 or
            config.metadata_bytes == 0)
            return error.InvalidConfig;
    }
};

pub const Metadata = struct {
    sandbox_engine: ?[]const u8 = null,
    app_id: ?[]const u8 = null,
    instance_id: ?[]const u8 = null,
};

/// Stable adapter-owned listener state. The commit hook may retain this pointer
/// until adapter teardown; destroying the creating protocol objects does not
/// invalidate a committed listener.
pub const Listener = struct {
    listen_fd: linux.fd_t,
    close_fd: linux.fd_t,
    metadata: Metadata = .{},
    committed: bool = false,
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_security_context_manager_v1;
        const Context = protocol.wp_security_context_v1;

        pub const Committer = struct {
            context: ?*anyopaque = null,
            commitFn: *const fn (?*anyopaque, *Listener) anyerror!void,
        };

        const Kind = enum { manager, context };
        const Resource = struct {
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            listener: ?*Listener = null,
        };

        allocator: std.mem.Allocator,
        committer: Committer,
        resources: std.ArrayListUnmanaged(*Resource) = .empty,
        listeners: std.ArrayListUnmanaged(*Listener) = .empty,
        resource_capacity: usize,
        listener_capacity: usize,
        metadata_capacity: usize,
        metadata_used: usize = 0,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(
            allocator: std.mem.Allocator,
            committer: Committer,
            config: Config,
        ) !Self {
            try config.validate();
            var self: Self = .{
                .allocator = allocator,
                .committer = committer,
                .resource_capacity = config.resource_capacity,
                .listener_capacity = config.listener_capacity,
                .metadata_capacity = config.metadata_bytes,
            };
            errdefer self.resources.deinit(allocator);
            try self.resources.ensureTotalCapacity(allocator, config.resource_capacity);
            try self.listeners.ensureTotalCapacity(allocator, config.listener_capacity);
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.resources.items) |resource| self.allocator.destroy(resource);
            for (self.listeners.items) |listener| self.destroyListener(listener);
            self.listeners.deinit(self.allocator);
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
            return self.createResource(.manager, binding.resource, binding.peer, null) catch
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
            const resource = self.fromObject(target.object) orelse return null;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (!std.meta.eql(resource.handle, handle) or !samePeer(resource.peer, peer)) return null;

            if (resource.kind == .manager and target.object.interface == &Manager.info) {
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_listener => |value| {
                        if (self.listeners.items.len == self.listener_capacity)
                            return try self.noMemory(actor);
                        var listen_owned = true;
                        var close_owned = true;
                        defer if (listen_owned) {
                            _ = linux.close(value.listen_fd);
                        };
                        defer if (close_owned) {
                            _ = linux.close(value.close_fd);
                        };
                        validateListenFd(value.listen_fd) catch
                            return try self.managerError(actor, decoded.handle.id, "listen_fd is not a listening socket");
                        setNonblocking(value.listen_fd) catch
                            return try self.managerError(actor, decoded.handle.id, "listen_fd cannot be made nonblocking");
                        const listener = self.allocator.create(Listener) catch
                            return try self.noMemory(actor);
                        errdefer self.allocator.destroy(listener);
                        listener.* = .{ .listen_fd = value.listen_fd, .close_fd = value.close_fd };
                        self.listeners.appendAssumeCapacity(listener);
                        const child = self.createResource(.context, undefined, peer, listener) catch {
                            _ = self.listeners.pop();
                            self.allocator.destroy(listener);
                            return try self.noMemory(actor);
                        };
                        const admitted = Manager.admit_create_listener(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = child },
                        ) catch |err| {
                            self.removeResource(child);
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        child.handle = admitted.id;
                        listen_owned = false;
                        close_owned = false;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }

            if (resource.kind == .context and target.object.interface == &Context.info) {
                const listener = resource.listener orelse return error.InvalidContext;
                const decoded = try wayring.server.decodeRequest(Context, server_objects, message, fds);
                if (listener.committed and std.meta.activeTag(decoded.value) != .destroy)
                    return try self.contextError(actor, decoded.handle.id, Context.@"error".already_used.value, "security context is already committed");
                switch (decoded.value) {
                    .destroy => {},
                    .set_sandbox_engine => |value| if (try self.setMetadata(actor, decoded.handle.id, listener, .sandbox_engine, value.name)) |control| return control,
                    .set_app_id => |value| if (try self.setMetadata(actor, decoded.handle.id, listener, .app_id, value.app_id)) |control| return control,
                    .set_instance_id => |value| if (try self.setMetadata(actor, decoded.handle.id, listener, .instance_id, value.instance_id)) |control| return control,
                    .commit => {
                        listener.committed = true;
                        self.committer.commitFn(self.committer.context, listener) catch {
                            listener.committed = false;
                            return try self.noMemory(actor);
                        };
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
            self.removeResource(resource);
            return true;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            var index = self.resources.items.len;
            while (index != 0) {
                index -= 1;
                const resource = self.resources.items[index];
                if (samePeer(resource.peer, peer)) self.removeResource(resource);
            }
        }

        fn setMetadata(
            self: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            listener: *Listener,
            comptime field: std.meta.FieldEnum(Metadata),
            value: []const u8,
        ) !?wayring.dispatch.Control {
            if (@field(listener.metadata, @tagName(field)) != null)
                return try self.contextError(actor, id, Context.@"error".already_set.value, "security context metadata is already set");
            if (value.len > self.metadata_capacity - self.metadata_used)
                return try self.noMemory(actor);
            const copy = self.allocator.dupe(u8, value) catch
                return try self.noMemory(actor);
            @field(listener.metadata, @tagName(field)) = copy;
            self.metadata_used += copy.len;
            return null;
        }

        fn createResource(self: *Self, kind: Kind, handle: objects.Handle, peer: wayring.io_uring.Peer, listener: ?*Listener) !*Resource {
            if (self.resources.items.len == self.resource_capacity) return error.Exhausted;
            const resource = try self.allocator.create(Resource);
            errdefer self.allocator.destroy(resource);
            resource.* = .{ .kind = kind, .handle = handle, .peer = peer, .listener = listener };
            self.resources.appendAssumeCapacity(resource);
            return resource;
        }

        fn removeResource(self: *Self, resource: *Resource) void {
            for (self.resources.items, 0..) |item, index| if (item == resource) {
                _ = self.resources.swapRemove(index);
                if (resource.listener) |listener| if (!listener.committed)
                    self.removeListener(listener);
                self.allocator.destroy(resource);
                return;
            };
        }

        fn removeListener(self: *Self, listener: *Listener) void {
            for (self.listeners.items, 0..) |item, index| if (item == listener) {
                _ = self.listeners.swapRemove(index);
                self.destroyListener(listener);
                return;
            };
        }

        fn destroyListener(self: *Self, listener: *Listener) void {
            inline for (.{ "sandbox_engine", "app_id", "instance_id" }) |field| if (@field(listener.metadata, field)) |value| {
                self.metadata_used -= value.len;
                self.allocator.free(value);
            };
            _ = linux.close(listener.listen_fd);
            _ = linux.close(listener.close_fd);
            self.allocator.destroy(listener);
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Resource {
            const context = object.context orelse return null;
            for (self.resources.items) |resource|
                if (@intFromPtr(resource) == @intFromPtr(context)) return resource;
            return null;
        }

        fn managerError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Manager.@"error".invalid_listen_fd.value, message);
            return .stop;
        }

        fn contextError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }

        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.OutOfMemory, error.Exhausted => self.noMemory(actor),
                else => self.contextError(actor, id, Context.@"error".invalid_metadata.value, @errorName(err)),
            };
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
    };
}

pub fn validateListenFd(fd: linux.fd_t) !void {
    var accepting: c_int = 0;
    var length: linux.socklen_t = @sizeOf(c_int);
    const result = linux.getsockopt(
        fd,
        linux.SOL.SOCKET,
        linux.SO.ACCEPTCONN,
        std.mem.asBytes(&accepting).ptr,
        &length,
    );
    if (linux.errno(result) != .SUCCESS or length != @sizeOf(c_int) or accepting == 0)
        return error.InvalidListenFd;
}

fn setNonblocking(fd: linux.fd_t) !void {
    const current = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(current) != .SUCCESS) return error.FcntlFailed;
    const result = linux.fcntl(fd, linux.F.SETFL, current | linux.O.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.FcntlFailed;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "security-context validates listening sockets" {
    const path = "/tmp/ouro-security-context-test.sock";
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};
    const listener = try wayring.unix_socket.listen(path, 1);
    defer _ = linux.close(listener);
    try validateListenFd(listener);

    var pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &pair,
    )));
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);
    try std.testing.expectError(error.InvalidListenFd, validateListenFd(pair[0]));
}
