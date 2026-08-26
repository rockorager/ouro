//! Bounded idle-inhibitor resources associated with exact wl_surface generations.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    inhibitor_capacity: usize = 32,

    fn validate(config: Config) !void {
        if (config.inhibitor_capacity == 0 or config.inhibitor_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_idle_inhibit_manager_v1;
        const Inhibitor = protocol.zwp_idle_inhibitor_v1;

        const Slot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            surface: CoreSurface.SurfaceId = undefined,
            peer: wayring.io_uring.Peer = undefined,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        slots: []Slot,
        free_head: u32 = 0,
        active_len: usize = 0,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.inhibitor_capacity);
            for (slots, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none,
            };
            return .{ .allocator = allocator, .core = core, .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
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

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_inhibitor => |value| {
                        const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                            return try self.protocolError(actor, decoded.handle.id, "invalid idle-inhibitor surface");
                        const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                            return try self.protocolError(actor, decoded.handle.id, "invalid idle-inhibitor surface");
                        const surface = self.core.surfaceIdObject(surface_handle, surface_object) catch
                            return try self.protocolError(actor, decoded.handle.id, "invalid idle-inhibitor surface");
                        if (!samePeer(try self.core.surfacePeer(surface), peer))
                            return try self.protocolError(actor, decoded.handle.id, "foreign idle-inhibitor surface");
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        const admitted = Manager.admit_create_inhibitor(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |err| {
                            self.release(self.index(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        slot.surface = surface;
                        slot.peer = peer;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Inhibitor.info) return null;
            const slot = self.fromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Inhibitor, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        /// Returns whether at least one live inhibitor is associated with the
        /// exact surface generation. Visibility decides whether it is honored.
        pub fn hasInhibitor(self: *const Self, surface: CoreSurface.SurfaceId) bool {
            for (self.slots) |slot|
                if (slot.active and std.meta.eql(slot.surface, surface)) return true;
            return false;
        }

        pub fn activeCount(self: *const Self) usize {
            return self.active_len;
        }

        pub fn surfaces(self: *const Self, output: []CoreSurface.SurfaceId) ![]const CoreSurface.SurfaceId {
            var count: usize = 0;
            for (self.slots) |slot| {
                if (!slot.active) continue;
                if (count == output.len) return error.OutputTooSmall;
                output[count] = slot.surface;
                count += 1;
            }
            return output[0..count];
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Inhibitor.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(self.index(slot));
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots, 0..) |*slot, i|
                if (slot.active and samePeer(slot.peer, peer)) self.release(@intCast(i));
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const i = self.free_head;
            const slot = &self.slots[i];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true };
            self.active_len += 1;
            return slot;
        }

        fn release(self: *Self, i: u32) void {
            const slot = &self.slots[i];
            if (!slot.active) return;
            slot.* = .{ .next_free = self.free_head };
            self.free_head = i;
            self.active_len -= 1;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(self.slots.ptr);
            const bytes = std.math.mul(usize, self.slots.len, @sizeOf(Slot)) catch return null;
            const end = std.math.add(usize, start, bytes) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
            const slot = &self.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active) slot else null;
        }

        fn index(self: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, message);
            return .stop;
        }

        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.Exhausted, error.OutOfMemory => self.noMemory(actor),
                else => self.protocolError(actor, id, @errorName(err)),
            };
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "idle inhibit: multiple associations are bounded and peer cleanup is exact" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const A = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try A.init(std.testing.allocator, &core, .{ .inhibitor_capacity = 3 });
    defer adapter.deinit();
    const peer_a: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const peer_b: wayring.io_uring.Peer = .{ .slot = 2, .generation = 3 };
    const surface: FakeCore.SurfaceId = .{ .index = 4, .generation = 5 };
    const first = try adapter.acquire();
    first.peer = peer_a;
    first.surface = surface;
    const second = try adapter.acquire();
    second.peer = peer_a;
    second.surface = surface;
    const other = try adapter.acquire();
    other.peer = peer_b;
    other.surface = .{ .index = 6, .generation = 7 };

    try std.testing.expect(adapter.hasInhibitor(surface));
    try std.testing.expectEqual(@as(usize, 3), adapter.activeCount());
    try std.testing.expectError(error.Exhausted, adapter.acquire());
    adapter.disconnected(peer_a);
    try std.testing.expect(!adapter.hasInhibitor(surface));
    try std.testing.expectEqual(@as(usize, 1), adapter.activeCount());
    adapter.disconnected(.{ .slot = peer_b.slot, .generation = peer_b.generation + 1 });
    try std.testing.expectEqual(@as(usize, 1), adapter.activeCount());
}
