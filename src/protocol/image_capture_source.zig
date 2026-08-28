//! Bounded ownership for ext-image-capture-source-v1 factories and sources.

const std = @import("std");
const wayring = @import("wayring");

const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    source_capacity: usize = 64,

    fn validate(config: Config) !void {
        if (config.manager_capacity < 2 or config.manager_capacity >= none or
            config.source_capacity == 0 or config.source_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(
    comptime protocol: type,
    comptime OutputId: type,
    comptime ToplevelId: type,
) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const SourceProtocol = protocol.ext_image_capture_source_v1;
        const OutputManager = protocol.ext_output_image_capture_source_manager_v1;
        const ToplevelManager = protocol.ext_foreign_toplevel_image_capture_source_manager_v1;

        pub const Target = union(enum) {
            output: OutputId,
            toplevel: ToplevelId,
        };
        pub const SourceId = packed struct { index: u32, generation: u32 };
        pub const Snapshot = struct { id: SourceId, target: ?Target };

        const ManagerKind = enum { output, toplevel };
        const Manager = struct {
            active: bool = false,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            kind: ManagerKind = .output,
        };
        const Source = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            target: ?Target = null,
        };

        allocator: std.mem.Allocator,
        managers: []Manager,
        sources: []Source,
        manager_free: u32 = 0,
        source_free: u32 = 0,
        runtime: ?*Runtime = null,
        output_global: ?objects.Handle = null,
        toplevel_global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            const managers = try allocator.alloc(Manager, config.manager_capacity);
            errdefer allocator.free(managers);
            const sources = try allocator.alloc(Source, config.source_capacity);
            errdefer allocator.free(sources);
            initFree(Manager, managers);
            initFree(Source, sources);
            return .{ .allocator = allocator, .managers = managers, .sources = sources };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.sources);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn installOutput(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.output_global != null or (self.runtime != null and self.runtime.? != runtime))
                return error.AlreadyInstalled;
            self.runtime = runtime;
            self.output_global = try runtime.addGlobalWithBinder(&OutputManager.info, 1, self, bindOutput);
            return self.output_global.?;
        }

        pub fn installToplevel(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.toplevel_global != null or self.runtime == null or self.runtime.? != runtime)
                return error.AlreadyInstalled;
            self.toplevel_global = try runtime.addGlobalWithBinder(&ToplevelManager.info, 1, self, bindToplevel);
            return self.toplevel_global.?;
        }

        fn bindOutput(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            return bind(context, binding, .output);
        }

        fn bindToplevel(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            return bind(context, binding, .toplevel);
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding, kind: ManagerKind) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const manager = self.acquireManager() catch return error.OutOfMemory;
            manager.peer = binding.peer;
            manager.resource = binding.resource;
            manager.kind = kind;
            return manager;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
            resolver: anytype,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                peer,
                target,
                message,
                fds,
                resolver,
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
            resolver: anytype,
        ) !?wayring.dispatch.Control {
            const resource = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &OutputManager.info or target.object.interface == &ToplevelManager.info) {
                const manager = from(Manager, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, resource) or !samePeer(manager.peer, peer)) return null;
                if (manager.kind == .output) {
                    const decoded = try wayring.server.decodeRequest(OutputManager, server_objects, message, fds);
                    switch (decoded.value) {
                        .create_source => |value| {
                            const capture_target = resolver.resolveCaptureOutput(peer, server_objects, value.output);
                            if (try self.createSource(actor, server_objects, peer, decoded.handle, value, capture_target, .output)) |control|
                                return control;
                        },
                        .destroy => {},
                    }
                    try decoded.finish(protocol, server_objects, &actor.transmit);
                } else {
                    const decoded = try wayring.server.decodeRequest(ToplevelManager, server_objects, message, fds);
                    switch (decoded.value) {
                        .create_source => |value| {
                            const capture_target = resolver.resolveCaptureToplevel(peer, server_objects, value.toplevel_handle);
                            if (try self.createSource(actor, server_objects, peer, decoded.handle, value, capture_target, .toplevel)) |control|
                                return control;
                        },
                        .destroy => {},
                    }
                    try decoded.finish(protocol, server_objects, &actor.transmit);
                }
                return .continue_dispatch;
            }
            if (target.object.interface != &SourceProtocol.info) return null;
            const source = from(Source, self.sources, target.object.context) orelse return null;
            if (!std.meta.eql(source.resource, resource) or !samePeer(source.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(SourceProtocol, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn createSource(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            parent: objects.Handle,
            value: anytype,
            resolved: anytype,
            comptime kind: ManagerKind,
        ) !?wayring.dispatch.Control {
            const source = self.acquireSource() catch return try self.noMemory(actor);
            var owned = true;
            defer if (owned) self.releaseSource(self.sourceIndex(source));
            source.peer = peer;
            source.target = if (resolved) |id| switch (kind) {
                .output => .{ .output = id },
                .toplevel => .{ .toplevel = id },
            } else null;
            const admitted = if (kind == .output)
                OutputManager.admit_create_source(server_objects, parent, value, .{ .source = source })
            else
                ToplevelManager.admit_create_source(server_objects, parent, value, .{ .source = source });
            const result = admitted catch |cause| return try self.failure(actor, parent.id, cause);
            source.resource = result.source;
            owned = false;
            return null;
        }

        pub fn snapshotForResource(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            object_id: u32,
        ) ?Snapshot {
            const resource = server_objects.namespace.lookupHandle(object_id) orelse return null;
            const object = server_objects.namespace.resolve(resource) orelse return null;
            if (object.interface != &SourceProtocol.info) return null;
            const source = from(Source, self.sources, object.context) orelse return null;
            if (!std.meta.eql(source.resource, resource) or !samePeer(source.peer, peer)) return null;
            return .{ .id = self.sourceId(source), .target = source.target };
        }

        pub fn invalidate(self: *Self, target: Target) usize {
            var count: usize = 0;
            for (self.sources) |*source| {
                if (!source.active or source.target == null or !std.meta.eql(source.target.?, target)) continue;
                source.target = null;
                count += 1;
            }
            return count;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &SourceProtocol.info) {
                const source = from(Source, self.sources, object.context) orelse return false;
                if (!std.meta.eql(source.resource, handle)) return false;
                self.releaseSource(self.sourceIndex(source));
                return true;
            }
            if (object.interface == &OutputManager.info or object.interface == &ToplevelManager.info) {
                const manager = from(Manager, self.managers, object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                self.releaseManager(self.managerIndex(manager));
                return true;
            }
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.sources, 0..) |source, index|
                if (source.active and samePeer(source.peer, peer)) self.releaseSource(@intCast(index));
            for (self.managers, 0..) |manager, index|
                if (manager.active and samePeer(manager.peer, peer)) self.releaseManager(@intCast(index));
        }

        fn acquireManager(self: *Self) !*Manager {
            if (self.manager_free == none) return error.Exhausted;
            const index = self.manager_free;
            const next = self.managers[index].next_free;
            self.managers[index] = .{ .active = true };
            self.manager_free = next;
            return &self.managers[index];
        }

        fn acquireSource(self: *Self) !*Source {
            if (self.source_free == none) return error.Exhausted;
            const index = self.source_free;
            const next = self.sources[index].next_free;
            const generation = self.sources[index].generation;
            self.sources[index] = .{ .active = true, .generation = generation };
            self.source_free = next;
            return &self.sources[index];
        }

        fn releaseManager(self: *Self, index: u32) void {
            self.managers[index] = .{ .next_free = self.manager_free };
            self.manager_free = index;
        }

        fn releaseSource(self: *Self, index: u32) void {
            const generation = nextGeneration(self.sources[index].generation);
            self.sources[index] = .{ .generation = generation, .next_free = self.source_free };
            self.source_free = index;
        }

        fn sourceId(self: *Self, source: *const Source) SourceId {
            return .{ .index = self.sourceIndex(source), .generation = source.generation };
        }
        fn sourceIndex(self: *Self, source: *const Source) u32 {
            return indexOf(Source, self.sources, source);
        }
        fn managerIndex(self: *Self, manager: *const Manager) u32 {
            return indexOf(Manager, self.managers, manager);
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, @errorName(cause));
            return .stop;
        }
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, index| slot.* = .{
        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
    };
}
fn indexOf(comptime T: type, slots: []const T, pointer: *const T) u32 {
    return @intCast((@intFromPtr(pointer) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    if (address < start or address >= start + slots.len * @sizeOf(T) or (address - start) % @sizeOf(T) != 0)
        return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active) slot else null;
}
fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "image capture source: terminal invalidation and generation reuse" {
    const Id = packed struct { index: u32, generation: u32 };
    const A = Adapter(@import("core_protocol"), Id, Id);
    var adapter = try A.init(std.testing.allocator, .{ .manager_capacity = 2, .source_capacity = 1 });
    defer adapter.deinit();
    const source = try adapter.acquireSource();
    source.target = .{ .output = .{ .index = 3, .generation = 9 } };
    const first = adapter.sourceId(source);
    try std.testing.expectEqual(@as(usize, 1), adapter.invalidate(source.target.?));
    try std.testing.expect(source.target == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.invalidate(.{ .output = .{ .index = 3, .generation = 9 } }));
    adapter.releaseSource(first.index);
    const replacement = try adapter.acquireSource();
    try std.testing.expect(replacement.generation != first.generation);
}

test "image capture source: manager destruction does not release sources" {
    const Id = packed struct { index: u32, generation: u32 };
    const A = Adapter(@import("core_protocol"), Id, Id);
    var adapter = try A.init(std.testing.allocator, .{ .manager_capacity = 2, .source_capacity = 1 });
    defer adapter.deinit();
    const manager = try adapter.acquireManager();
    const source = try adapter.acquireSource();
    adapter.releaseManager(adapter.managerIndex(manager));
    try std.testing.expect(source.active);
}
