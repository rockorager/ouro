//! Bounded wp_fractional_scale_v1 surface scale publication.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
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
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            surface: CoreSurface.SurfaceId = .{ .index = 0, .generation = 0 },
            event_pending: bool = true,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: []Slot,
        free_head: u32 = 0,
        preferred_scale: u32,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *CoreSurface,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.resource_capacity);
            for (slots, 0..) |*slot, slot_index| slot.* = .{
                .next_free = if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else none,
            };
            return .{
                .allocator = allocator,
                .core = core,
                .slots = slots,
                .preferred_scale = config.preferred_scale,
            };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.allocator.free(adapter.slots);
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
                        for (adapter.slots) |slot| if (slot.active and std.meta.eql(slot.surface, surface))
                            return try adapter.protocolError(actor, decoded.handle.id, "fractional scale already exists");
                        const slot = adapter.acquire() catch return try adapter.noMemory(actor);
                        const admitted = Manager.admit_get_fractional_scale(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |cause| {
                            adapter.release(adapter.index(slot));
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.surface = surface;
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
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            for (adapter.slots) |*slot| {
                if (!slot.active or !slot.event_pending) continue;
                if (server_objects.namespace.resolve(slot.resource) == null) continue;
                Scale.encodeEvent(queue, slot.resource.id, .{ .preferred_scale = .{
                    .scale = adapter.preferred_scale,
                } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.event_pending = false;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(adapter: *const Self) bool {
            for (adapter.slots) |slot| if (slot.active and slot.event_pending) return true;
            return false;
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Scale.info) {
                const slot = adapter.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.release(adapter.index(slot));
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        fn acquire(adapter: *Self) !*Slot {
            if (adapter.free_head == none) return error.Exhausted;
            const index_value = adapter.free_head;
            const slot = &adapter.slots[index_value];
            adapter.free_head = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn release(adapter: *Self, index_value: u32) void {
            const slot = &adapter.slots[index_value];
            if (!slot.active) return;
            slot.* = .{ .next_free = adapter.free_head };
            adapter.free_head = index_value;
        }

        fn fromObject(adapter: *Self, object: *const objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(adapter.slots.ptr);
            const bytes = std.math.mul(usize, adapter.slots.len, @sizeOf(Slot)) catch return null;
            const end = std.math.add(usize, start, bytes) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
            const slot = &adapter.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active and @intFromPtr(slot) == address) slot else null;
        }

        fn index(adapter: *Self, slot: *Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.slots.ptr)) / @sizeOf(Slot));
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

test "fractional scale: bounded slots retain one pending preferred scale" {
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
    try std.testing.expect(slot.event_pending);
    try std.testing.expectError(error.Exhausted, adapter.acquire());
    adapter.release(0);
    try std.testing.expectEqual(@as(u32, 0), adapter.free_head);
}
