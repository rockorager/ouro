//! Bounded wp_fractional_scale_v1 surface scale publication.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 8,
    preferred_scale: u32 = 120,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none or
            config.preferred_scale == 0)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_fractional_scale_manager_v1;
        const Scale = protocol.wp_fractional_scale_v1;

        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            surface: CoreSurface.SurfaceId = .{ .index = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            event_pending: bool = true,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: slot_pool.Pool(Slot),
        preferred_scale: u32,
        event_pending_len: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *CoreSurface,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try slot_pool.Pool(Slot).init(allocator, config.resource_capacity);
            return .{
                .allocator = allocator,
                .core = core,
                .slots = slots,
                .preferred_scale = config.preferred_scale,
            };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.slots.deinit();
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 1, adapter, bind);
            adapter.global = global;
            return global;
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
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return adapter.requestOn(actor, server_objects, target, message, fds);
        }

        pub fn requestOn(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
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
                    .get_fractional_scale => |value| {
                        const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                            return try adapter.protocolError(actor, decoded.handle.id, "invalid fractional-scale surface");
                        const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                            return try adapter.protocolError(actor, decoded.handle.id, "invalid fractional-scale surface");
                        const surface = adapter.core.surfaceIdObject(surface_handle, surface_object) catch
                            return try adapter.protocolError(actor, decoded.handle.id, "invalid fractional-scale surface");
                        for (adapter.slots.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.surface, surface))
                            return try adapter.protocolError(actor, decoded.handle.id, "fractional scale already exists");
                        const slot = adapter.acquire() catch return try adapter.noMemory(actor);
                        const admitted = Manager.admit_get_fractional_scale(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |cause| {
                            adapter.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.surface = surface;
                        slot.peer = try adapter.core.surfacePeer(surface);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Scale.info) {
                const slot = adapter.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Scale, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn flushOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (adapter.event_pending_len == 0) return completed;
            for (adapter.slots.entries.items) |slot| {
                if (!slot.header.active or !samePeer(slot.peer, peer) or !slot.event_pending) continue;
                if (server_objects.namespace.resolve(slot.resource) == null) continue;
                Scale.encodeEvent(queue, slot.resource.id, .{ .preferred_scale = .{
                    .scale = adapter.preferred_scale,
                } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.event_pending = false;
                adapter.event_pending_len -= 1;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(adapter: *const Self, peer: wayring.io_uring.Peer) bool {
            if (adapter.event_pending_len == 0) return false;
            for (adapter.slots.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and slot.event_pending) return true;
            return false;
        }

        /// Publishes a new preferred scale to every live surface binding.
        /// Repeated publication is a no-op and requires no transport storage.
        pub fn publishPreferredScale(adapter: *Self, preferred_scale: u32) !void {
            if (preferred_scale == 0) return error.InvalidScale;
            if (adapter.preferred_scale == preferred_scale) return;
            adapter.preferred_scale = preferred_scale;
            for (adapter.slots.entries.items) |slot| {
                if (!slot.header.active or slot.event_pending) continue;
                slot.event_pending = true;
                adapter.event_pending_len += 1;
            }
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Scale.info) {
                const slot = adapter.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.release(slot);
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        fn acquire(adapter: *Self) !*Slot {
            const slot = try adapter.slots.acquire();
            adapter.event_pending_len += 1;
            return slot;
        }

        fn release(adapter: *Self, slot: *Slot) void {
            if (!slot.header.active) return;
            if (slot.event_pending) adapter.event_pending_len -= 1;
            adapter.slots.release(slot);
        }

        fn fromObject(adapter: *Self, object: *const objects.Object) ?*Slot {
            return adapter.slots.fromContext(object.context);
        }

        fn noMemory(adapter: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(adapter: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, id, Manager.@"error".fractional_scale_exists.value, message);
            return .stop;
        }

        fn failure(adapter: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, @errorName(cause));
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "fractional scale: initial reservation grows without moving contexts" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .resource_capacity = 1,
        .preferred_scale = 180,
    });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    const original = @intFromPtr(slot);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    slot.peer = peer;
    try std.testing.expect(slot.event_pending);
    try std.testing.expect(adapter.pendingOutbound(peer));
    try std.testing.expect(!adapter.pendingOutbound(.{ .slot = 2, .generation = 2 }));
    _ = try adapter.acquire();
    try std.testing.expectEqual(original, @intFromPtr(slot));
    adapter.release(slot);
}

test "fractional scale: changed preference republishes each live resource once" {
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(@import("core_protocol"), FakeCore);
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{});
    defer adapter.deinit();
    const first = try adapter.acquire();
    const second = try adapter.acquire();
    first.event_pending = false;
    second.event_pending = false;
    adapter.event_pending_len = 0;

    try adapter.publishPreferredScale(180);
    try std.testing.expectEqual(@as(u32, 180), adapter.preferred_scale);
    try std.testing.expect(first.event_pending);
    try std.testing.expect(second.event_pending);
    try std.testing.expectEqual(@as(usize, 2), adapter.event_pending_len);
    try adapter.publishPreferredScale(180);
    try std.testing.expectEqual(@as(usize, 2), adapter.event_pending_len);
    try std.testing.expectError(error.InvalidScale, adapter.publishPreferredScale(0));
}
