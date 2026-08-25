//! Fixed-capacity wl_output owner for one physical desktop output.

const std = @import("std");
const wayring = @import("wayring");

const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 4,
    association_capacity: usize = 16,
    outbound_capacity: usize = 64,
    global_version: u32 = 4,
    name: []const u8 = "ouro-0",
    description: []const u8 = "Ouro output",
    make: []const u8 = "Ouro",
    model: []const u8 = "Unknown",
    physical_width_mm: i32 = 0,
    physical_height_mm: i32 = 0,
    scale: i32 = 1,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity > 64 or
            config.association_capacity == 0 or config.association_capacity >= none or
            config.resource_capacity > config.outbound_capacity / 9 or
            config.outbound_capacity >= none or config.scale <= 0)
            return error.InvalidConfig;
        if (config.physical_width_mm < 0 or config.physical_height_mm < 0)
            return error.InvalidConfig;
        inline for (.{ config.name, config.description, config.make, config.model }) |value|
            if (value.len == 0 or std.mem.indexOfScalar(u8, value, 0) != null)
                return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Output = protocol.wl_output;

        const Id = struct { index: u32, generation: u32 };
        const Resource = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            handle: objects.Handle = .{ .id = 0, .generation = 0 },
            version: u32 = 0,
        };
        const Association = struct {
            active: bool = false,
            desired: bool = false,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            surface: objects.Handle = .{ .id = 0, .generation = 0 },
            entered: u64 = 0,
        };
        const Mode = struct { width: i32, height: i32, refresh_millihz: i32 };
        const Event = enum { geometry, mode, scale, name, description, done };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            resource: Id = undefined,
            event: Event = undefined,
        };

        allocator: std.mem.Allocator,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        name: []u8,
        description: []u8,
        make: []u8,
        model: []u8,
        physical_width_mm: i32,
        physical_height_mm: i32,
        scale: i32,
        mode: ?Mode = null,
        available: bool = false,
        resources: []Resource,
        resource_free: u32,
        associations: []Association,
        association_free: u32,
        outbound: []Outbound,
        next_sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Output.info.validateVersion(config.global_version);
            const resources = try allocator.alloc(Resource, config.resource_capacity);
            errdefer allocator.free(resources);
            const associations = try allocator.alloc(Association, config.association_capacity);
            errdefer allocator.free(associations);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            errdefer allocator.free(outbound);
            const name = try allocator.dupe(u8, config.name);
            errdefer allocator.free(name);
            const description = try allocator.dupe(u8, config.description);
            errdefer allocator.free(description);
            const make = try allocator.dupe(u8, config.make);
            errdefer allocator.free(make);
            const model = try allocator.dupe(u8, config.model);
            errdefer allocator.free(model);
            for (resources, 0..) |*resource, index| resource.* = .{
                .next_free = if (index + 1 < resources.len) @intCast(index + 1) else none,
            };
            for (associations, 0..) |*association, index| association.* = .{
                .next_free = if (index + 1 < associations.len) @intCast(index + 1) else none,
            };
            @memset(outbound, .{});
            return .{
                .allocator = allocator,
                .global_version = config.global_version,
                .name = name,
                .description = description,
                .make = make,
                .model = model,
                .physical_width_mm = config.physical_width_mm,
                .physical_height_mm = config.physical_height_mm,
                .scale = config.scale,
                .resources = resources,
                .resource_free = 0,
                .associations = associations,
                .association_free = 0,
                .outbound = outbound,
            };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.allocator.free(adapter.model);
            adapter.allocator.free(adapter.make);
            adapter.allocator.free(adapter.description);
            adapter.allocator.free(adapter.name);
            adapter.allocator.free(adapter.outbound);
            adapter.allocator.free(adapter.associations);
            adapter.allocator.free(adapter.resources);
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Output.info,
                adapter.global_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const index = adapter.acquireResource() catch return error.OutOfMemory;
            const resource = &adapter.resources[index];
            resource.peer = binding.peer;
            resource.handle = binding.resource;
            resource.version = binding.version;
            adapter.queueSnapshot(adapter.idFor(index)) catch {
                adapter.releaseResource(index);
                return error.OutOfMemory;
            };
            return resource;
        }

        pub fn publishMode(
            adapter: *Self,
            width: u32,
            height: u32,
            refresh_millihz: u32,
            physical_width_mm: u32,
            physical_height_mm: u32,
        ) !void {
            if (width == 0 or height == 0 or refresh_millihz == 0 or
                width > std.math.maxInt(i32) or height > std.math.maxInt(i32) or
                refresh_millihz > std.math.maxInt(i32) or
                physical_width_mm > std.math.maxInt(i32) or
                physical_height_mm > std.math.maxInt(i32))
                return error.InvalidMode;
            var event_count: usize = 0;
            for (adapter.resources) |resource| {
                if (resource.active) event_count += if (resource.version >= 2) 3 else 2;
            }
            try adapter.ensureOutbound(event_count);
            adapter.physical_width_mm = @intCast(physical_width_mm);
            adapter.physical_height_mm = @intCast(physical_height_mm);
            adapter.mode = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .refresh_millihz = @intCast(refresh_millihz),
            };
            adapter.available = true;
            for (adapter.resources, 0..) |resource, index| if (resource.active) {
                const id = adapter.idFor(@intCast(index));
                adapter.enqueue(id, .geometry) catch unreachable;
                adapter.enqueue(id, .mode) catch unreachable;
                if (resource.version >= 2) adapter.enqueue(id, .done) catch unreachable;
            };
        }

        pub fn setAvailable(adapter: *Self, available: bool) void {
            adapter.available = available;
        }

        /// Reconciles the mapped surface set without directly writing the
        /// transport. `flushOn` retains each enter/leave transition until its
        /// generated event is accepted.
        pub fn reconcileSurfaces(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            surfaces: []const objects.Handle,
        ) !void {
            if (surfaces.len > adapter.associations.len) return error.Exhausted;
            for (surfaces, 0..) |surface, index| {
                if (surface.id == 0 or surface.generation == 0) return error.InvalidSurface;
                for (surfaces[0..index]) |previous|
                    if (std.meta.eql(surface, previous)) return error.DuplicateSurface;
            }
            var required: usize = 0;
            for (surfaces) |surface| {
                if (adapter.findAssociation(peer, surface) == null) required += 1;
            }
            var free: usize = 0;
            for (adapter.associations) |association| free += @intFromBool(!association.active);
            if (required > free) return error.Exhausted;

            for (adapter.associations) |*association| {
                if (association.active and samePeer(association.peer, peer)) association.desired = false;
            }
            for (surfaces) |surface| {
                if (adapter.findAssociation(peer, surface)) |association| {
                    association.desired = true;
                } else {
                    const association = adapter.acquireAssociation() catch unreachable;
                    association.peer = peer;
                    association.surface = surface;
                    association.desired = true;
                }
            }
            var index: usize = 0;
            while (index < adapter.associations.len) : (index += 1) {
                const association = &adapter.associations[index];
                if (association.active and samePeer(association.peer, peer) and
                    !association.desired and association.entered == 0)
                    adapter.releaseAssociation(@intCast(index));
            }
        }

        pub fn request(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            if (target.object.interface != &Output.info) return null;
            const resource = adapter.fromContext(target.object.context) orelse return null;
            if (!resource.active or !samePeer(resource.peer, peer) or
                resource.handle.id != message.header.object_id) return null;
            const runtime = adapter.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            const decoded = try wayring.server.decodeRequest(Output, server_objects, message, fds);
            switch (decoded.value) {
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface != &Output.info) return false;
            const resource = adapter.fromContext(object.context) orelse return false;
            if (!std.meta.eql(resource.handle, handle)) return false;
            const id = adapter.idFor(adapter.indexFor(resource));
            adapter.dropOutbound(id);
            const bit = @as(u64, 1) << @intCast(id.index);
            var association_index: usize = 0;
            while (association_index < adapter.associations.len) : (association_index += 1) {
                const association = &adapter.associations[association_index];
                if (!association.active) continue;
                association.entered &= ~bit;
                if (!association.desired and association.entered == 0)
                    adapter.releaseAssociation(@intCast(association_index));
            }
            adapter.releaseResource(id.index);
            return true;
        }

        pub fn surfaceRemoved(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            handle: objects.Handle,
        ) void {
            if (adapter.findAssociation(peer, handle)) |association|
                adapter.releaseAssociation(adapter.associationIndex(association));
        }

        pub fn pendingOutbound(adapter: *const Self) usize {
            var count: usize = 0;
            for (adapter.outbound) |slot| count += @intFromBool(slot.active);
            for (adapter.associations) |association| {
                if (!association.active) continue;
                for (adapter.resources, 0..) |resource, index| {
                    if (!resource.active) continue;
                    const bit = @as(u64, 1) << @intCast(index);
                    const entered = association.entered & bit != 0;
                    count += @intFromBool(entered != (adapter.available and association.desired));
                }
            }
            return count;
        }

        pub fn flushOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            while (adapter.oldestOutbound(peer)) |slot| {
                adapter.emit(queue, slot.*) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.active = false;
                completed += 1;
            }
            completed += try adapter.flushAssociations(peer, server_objects, queue);
            return completed;
        }

        pub fn resourceIds(
            adapter: *const Self,
            peer: wayring.io_uring.Peer,
            output: []u32,
        ) ![]const u32 {
            var count: usize = 0;
            for (adapter.resources) |resource| {
                if (!resource.active or !samePeer(resource.peer, peer)) continue;
                if (count == output.len) return error.OutputTooSmall;
                output[count] = resource.handle.id;
                count += 1;
            }
            return output[0..count];
        }

        fn flushAssociations(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            var association_index: usize = 0;
            while (association_index < adapter.associations.len) : (association_index += 1) {
                const association = &adapter.associations[association_index];
                if (!association.active or !samePeer(association.peer, peer)) continue;
                const surface = server_objects.namespace.resolve(association.surface) orelse {
                    adapter.releaseAssociation(@intCast(association_index));
                    continue;
                };
                if (surface.interface != &protocol.wl_surface.info) {
                    adapter.releaseAssociation(@intCast(association_index));
                    continue;
                }
                for (adapter.resources, 0..) |resource, resource_index| {
                    if (!resource.active or !samePeer(resource.peer, peer)) continue;
                    const bit = @as(u64, 1) << @intCast(resource_index);
                    const entered = association.entered & bit != 0;
                    const should_enter = adapter.available and association.desired;
                    if (entered == should_enter) continue;
                    protocol.wl_surface.encodeEvent(
                        queue,
                        association.surface.id,
                        if (should_enter)
                            .{ .enter = .{ .output = resource.handle.id } }
                        else
                            .{ .leave = .{ .output = resource.handle.id } },
                    ) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    };
                    if (should_enter)
                        association.entered |= bit
                    else
                        association.entered &= ~bit;
                    completed += 1;
                }
                if (!association.desired and association.entered == 0)
                    adapter.releaseAssociation(@intCast(association_index));
            }
            return completed;
        }

        fn queueSnapshot(adapter: *Self, id: Id) !void {
            const resource = try adapter.resolve(id);
            var count: usize = 1 + @as(usize, @intFromBool(adapter.mode != null));
            if (resource.version >= 2) count += 2;
            if (resource.version >= 4) count += 2;
            try adapter.ensureOutbound(count);
            adapter.enqueue(id, .geometry) catch unreachable;
            if (adapter.mode != null) adapter.enqueue(id, .mode) catch unreachable;
            if (resource.version >= 2) adapter.enqueue(id, .scale) catch unreachable;
            if (resource.version >= 4) {
                adapter.enqueue(id, .name) catch unreachable;
                adapter.enqueue(id, .description) catch unreachable;
            }
            if (resource.version >= 2) adapter.enqueue(id, .done) catch unreachable;
        }

        fn emit(adapter: *Self, queue: *wayring.tx.Queue, outbound: Outbound) !void {
            const resource = adapter.resolve(outbound.resource) catch return;
            const event: Output.Event = switch (outbound.event) {
                .geometry => .{ .geometry = .{
                    .x = 0,
                    .y = 0,
                    .physical_width = adapter.physical_width_mm,
                    .physical_height = adapter.physical_height_mm,
                    .subpixel = Output.subpixel.unknown,
                    .make = adapter.make,
                    .model = adapter.model,
                    .transform = Output.transform.normal,
                } },
                .mode => .{ .mode = .{
                    .flags = Output.mode.fromInt(Output.mode.current.value | Output.mode.preferred.value),
                    .width = adapter.mode.?.width,
                    .height = adapter.mode.?.height,
                    .refresh = adapter.mode.?.refresh_millihz,
                } },
                .scale => .{ .scale = .{ .factor = adapter.scale } },
                .name => .{ .name = .{ .name = adapter.name } },
                .description => .{ .description = .{ .description = adapter.description } },
                .done => .{ .done = .{} },
            };
            try Output.encodeEvent(queue, resource.handle.id, event);
        }

        fn acquireResource(adapter: *Self) !u32 {
            if (adapter.resource_free == none) return error.Exhausted;
            const index = adapter.resource_free;
            const resource = &adapter.resources[index];
            adapter.resource_free = resource.next_free;
            resource.active = true;
            resource.next_free = none;
            return index;
        }

        fn releaseResource(adapter: *Self, index: u32) void {
            const generation = adapter.resources[index].generation +% 1;
            adapter.resources[index] = .{
                .generation = generation,
                .next_free = adapter.resource_free,
            };
            adapter.resource_free = index;
        }

        fn acquireAssociation(adapter: *Self) !*Association {
            if (adapter.association_free == none) return error.Exhausted;
            const index = adapter.association_free;
            const association = &adapter.associations[index];
            adapter.association_free = association.next_free;
            association.* = .{ .active = true };
            return association;
        }

        fn releaseAssociation(adapter: *Self, index: u32) void {
            adapter.associations[index] = .{ .next_free = adapter.association_free };
            adapter.association_free = index;
        }

        fn findAssociation(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            surface: objects.Handle,
        ) ?*Association {
            for (adapter.associations) |*association|
                if (association.active and samePeer(association.peer, peer) and
                    std.meta.eql(association.surface, surface))
                    return association;
            return null;
        }

        fn associationIndex(adapter: *const Self, association: *const Association) u32 {
            return @intCast((@intFromPtr(association) - @intFromPtr(adapter.associations.ptr)) /
                @sizeOf(Association));
        }

        fn ensureOutbound(adapter: *const Self, needed: usize) !void {
            var pending: usize = 0;
            for (adapter.outbound) |slot| pending += @intFromBool(slot.active);
            if (pending + needed > adapter.outbound.len) return error.Exhausted;
        }

        fn enqueue(adapter: *Self, resource: Id, event: Event) !void {
            for (adapter.outbound) |*slot| if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .sequence = adapter.next_sequence,
                    .resource = resource,
                    .event = event,
                };
                adapter.next_sequence +%= 1;
                return;
            };
            return error.Exhausted;
        }

        fn oldestOutbound(adapter: *Self, peer: wayring.io_uring.Peer) ?*Outbound {
            var oldest: ?*Outbound = null;
            for (adapter.outbound) |*slot| {
                if (!slot.active) continue;
                const resource = adapter.resolve(slot.resource) catch continue;
                if (samePeer(resource.peer, peer) and
                    (oldest == null or slot.sequence < oldest.?.sequence))
                    oldest = slot;
            }
            return oldest;
        }

        fn dropOutbound(adapter: *Self, id: Id) void {
            for (adapter.outbound) |*slot| {
                if (slot.active and std.meta.eql(slot.resource, id)) slot.active = false;
            }
        }

        fn idFor(adapter: *const Self, index: u32) Id {
            return .{ .index = index, .generation = adapter.resources[index].generation };
        }

        fn resolve(adapter: *Self, id: Id) !*Resource {
            if (id.index >= adapter.resources.len) return error.StaleResource;
            const resource = &adapter.resources[id.index];
            if (!resource.active or resource.generation != id.generation)
                return error.StaleResource;
            return resource;
        }

        fn indexFor(adapter: *const Self, resource: *const Resource) u32 {
            return @intCast((@intFromPtr(resource) - @intFromPtr(adapter.resources.ptr)) /
                @sizeOf(Resource));
        }

        fn fromContext(adapter: *Self, context: ?*anyopaque) ?*Resource {
            const resource: *Resource = @ptrCast(@alignCast(context orelse return null));
            const address = @intFromPtr(resource);
            const start = @intFromPtr(adapter.resources.ptr);
            const end = start + adapter.resources.len * @sizeOf(Resource);
            if (address < start or address >= end or (address - start) % @sizeOf(Resource) != 0)
                return null;
            return resource;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "output: resources and surface associations are peer scoped" {
    const TestAdapter = Adapter(@import("core_protocol"));
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .resource_capacity = 2,
        .association_capacity = 2,
        .outbound_capacity = 18,
    });
    defer adapter.deinit();
    const peer_a: wayring.io_uring.Peer = .{ .slot = 1, .generation = 4 };
    const peer_b: wayring.io_uring.Peer = .{ .slot = 2, .generation = 7 };
    const resource_a = try adapter.acquireResource();
    adapter.resources[resource_a].peer = peer_a;
    adapter.resources[resource_a].handle = .{ .id = 9, .generation = 2 };
    const resource_b = try adapter.acquireResource();
    adapter.resources[resource_b].peer = peer_b;
    adapter.resources[resource_b].handle = .{ .id = 9, .generation = 3 };
    try adapter.enqueue(adapter.idFor(resource_b), .geometry);
    try adapter.enqueue(adapter.idFor(resource_a), .geometry);
    try std.testing.expectEqual(adapter.idFor(resource_a), adapter.oldestOutbound(peer_a).?.resource);
    try std.testing.expectEqual(adapter.idFor(resource_b), adapter.oldestOutbound(peer_b).?.resource);

    var ids: [2]u32 = undefined;
    try std.testing.expectEqualSlices(u32, &.{9}, try adapter.resourceIds(peer_a, &ids));
    try std.testing.expectEqualSlices(u32, &.{9}, try adapter.resourceIds(peer_b, &ids));
    const surface: objects.Handle = .{ .id = 12, .generation = 5 };
    try adapter.reconcileSurfaces(peer_a, &.{surface});
    try adapter.reconcileSurfaces(peer_b, &.{surface});
    try std.testing.expect(adapter.findAssociation(peer_a, surface) != null);
    try std.testing.expect(adapter.findAssociation(peer_b, surface) != null);
    try adapter.reconcileSurfaces(peer_a, &.{});
    try std.testing.expect(adapter.findAssociation(peer_a, surface) == null);
    try std.testing.expect(adapter.findAssociation(peer_b, surface).?.desired);
}
