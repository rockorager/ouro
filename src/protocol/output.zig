//! Dynamically growing wl_output owner for one physical desktop output.

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
        if (config.resource_capacity == 0 or config.resource_capacity >= none or
            config.association_capacity == 0 or config.association_capacity >= none or
            config.outbound_capacity == 0 or config.outbound_capacity >= none or
            config.scale <= 0)
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
        pub const Reference = struct {
            handle: objects.Handle,
        };
        pub const LogicalSnapshot = struct {
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };
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
            entered: std.ArrayListUnmanaged(u32) = .empty,
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
        scale_120: u32,
        mode: ?Mode = null,
        available: bool = false,
        resources: []*Resource,
        resource_free: u32,
        associations: []Association,
        association_free: u32,
        outbound: []Outbound,
        outbound_len: usize = 0,
        associations_dirty: bool = false,
        next_sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Output.info.validateVersion(config.global_version);
            const resources = try allocator.alloc(*Resource, config.resource_capacity);
            errdefer allocator.free(resources);
            var resources_initialized: usize = 0;
            errdefer for (resources[0..resources_initialized]) |resource| allocator.destroy(resource);
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
            for (resources, 0..) |*resource, index| {
                resource.* = try allocator.create(Resource);
                resources_initialized += 1;
                resource.*.* = .{
                    .next_free = if (index + 1 < resources.len) @intCast(index + 1) else none,
                };
            }
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
                .scale_120 = try std.math.mul(u32, @intCast(config.scale), 120),
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
            for (adapter.associations) |*association| association.entered.deinit(adapter.allocator);
            adapter.allocator.free(adapter.associations);
            for (adapter.resources) |resource| adapter.allocator.destroy(resource);
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
            const resource = adapter.resources[index];
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
            adapter.associations_dirty = true;
            for (adapter.resources, 0..) |resource, index| if (resource.active) {
                const id = adapter.idFor(@intCast(index));
                adapter.enqueue(id, .geometry) catch unreachable;
                adapter.enqueue(id, .mode) catch unreachable;
                if (resource.version >= 2) adapter.enqueue(id, .done) catch unreachable;
            };
        }

        /// Publishes the compositor-space scale in 1/120 increments. The
        /// integer wl_output event rounds upward as required for clients that
        /// do not bind fractional-scale-v1; xdg-output consumes the exact
        /// logical dimensions from `logicalSnapshot`.
        pub fn publishScale(adapter: *Self, scale_120: u32) !void {
            if (scale_120 == 0 or
                @divTrunc(@as(u64, scale_120) + 119, 120) > std.math.maxInt(i32))
                return error.InvalidScale;
            if (adapter.scale_120 == scale_120) return;
            var event_count: usize = 0;
            for (adapter.resources) |resource| {
                if (resource.active and resource.version >= 2) event_count += 2;
            }
            try adapter.ensureOutbound(event_count);
            adapter.scale_120 = scale_120;
            for (adapter.resources, 0..) |resource, index| {
                if (!resource.active or resource.version < 2) continue;
                const id = adapter.idFor(@intCast(index));
                adapter.enqueue(id, .scale) catch unreachable;
                adapter.enqueue(id, .done) catch unreachable;
            }
        }

        pub fn setAvailable(adapter: *Self, available: bool) void {
            if (adapter.available != available) adapter.associations_dirty = true;
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
            for (surfaces, 0..) |surface, index| {
                if (surface.id == 0 or surface.generation == 0) return error.InvalidSurface;
                for (surfaces[0..index]) |previous|
                    if (std.meta.eql(surface, previous)) return error.DuplicateSurface;
            }
            var required: usize = 0;
            for (surfaces) |surface| {
                if (adapter.findAssociation(peer, surface) == null) required += 1;
            }
            try adapter.ensureAssociations(required);

            var changed = false;
            for (adapter.associations) |*association| {
                if (!association.active or !samePeer(association.peer, peer)) continue;
                var desired = false;
                for (surfaces) |surface| if (std.meta.eql(association.surface, surface)) {
                    desired = true;
                    break;
                };
                if (association.desired != desired) {
                    association.desired = desired;
                    changed = true;
                }
            }
            for (surfaces) |surface| {
                if (adapter.findAssociation(peer, surface) == null) {
                    const association = adapter.acquireAssociation() catch unreachable;
                    association.peer = peer;
                    association.surface = surface;
                    association.desired = true;
                    changed = true;
                }
            }
            var index: usize = 0;
            while (index < adapter.associations.len) : (index += 1) {
                const association = &adapter.associations[index];
                if (association.active and samePeer(association.peer, peer) and
                    !association.desired and association.entered.items.len == 0)
                {
                    adapter.releaseAssociation(@intCast(index));
                    changed = true;
                }
            }
            if (changed) adapter.associations_dirty = true;
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
            var association_index: usize = 0;
            while (association_index < adapter.associations.len) : (association_index += 1) {
                const association = &adapter.associations[association_index];
                if (!association.active) continue;
                removeEntered(association, id.index);
                if (!association.desired and association.entered.items.len == 0)
                    adapter.releaseAssociation(@intCast(association_index));
            }
            adapter.releaseResource(id.index);
            adapter.associations_dirty = true;
            return true;
        }

        pub fn surfaceRemoved(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            handle: objects.Handle,
        ) void {
            if (adapter.findAssociation(peer, handle)) |association| {
                adapter.releaseAssociation(adapter.associationIndex(association));
                adapter.associations_dirty = true;
            }
        }

        pub fn pendingOutbound(adapter: *const Self) usize {
            return adapter.outbound_len + @intFromBool(adapter.associations_dirty);
        }

        pub fn pendingOutboundOn(adapter: *Self, peer: wayring.io_uring.Peer) bool {
            if (adapter.outbound_len != 0) for (adapter.outbound) |slot| {
                if (!slot.active) continue;
                const resource = adapter.resolve(slot.resource) catch continue;
                if (samePeer(resource.peer, peer)) return true;
            };
            if (!adapter.associations_dirty) return false;
            for (adapter.associations) |association| {
                if (!association.active or !samePeer(association.peer, peer)) continue;
                for (adapter.resources, 0..) |resource, index| {
                    if (!resource.active or !samePeer(resource.peer, peer)) continue;
                    const entered = isEntered(&association, @intCast(index));
                    if (entered != (adapter.available and association.desired)) return true;
                }
            }
            return false;
        }

        pub fn flushOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (adapter.outbound_len == 0 and !adapter.associations_dirty) return completed;
            while (adapter.oldestOutbound(peer)) |slot| {
                adapter.emit(queue, slot.*) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.active = false;
                adapter.outbound_len -= 1;
                completed += 1;
            }
            if (adapter.associations_dirty) {
                completed += try adapter.flushAssociations(peer, server_objects, queue);
                adapter.associations_dirty = adapter.hasPendingAssociations();
            }
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

        pub fn reference(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            handle: objects.Handle,
            object: objects.Object,
        ) !Reference {
            if (object.interface != &Output.info) return error.WrongInterface;
            const resource = adapter.fromContext(object.context) orelse return error.ForeignResource;
            if (!resource.active or !samePeer(resource.peer, peer) or
                !std.meta.eql(resource.handle, handle)) return error.ForeignResource;
            return .{ .handle = resource.handle };
        }

        pub fn logicalSnapshot(adapter: *const Self) LogicalSnapshot {
            return .{
                .width = if (adapter.mode) |mode|
                    @intCast(@divTrunc(@as(u64, @intCast(mode.width)) * 120, adapter.scale_120))
                else
                    null,
                .height = if (adapter.mode) |mode|
                    @intCast(@divTrunc(@as(u64, @intCast(mode.height)) * 120, adapter.scale_120))
                else
                    null,
                .name = adapter.name,
                .description = adapter.description,
            };
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
                    const entered = isEntered(association, @intCast(resource_index));
                    const should_enter = adapter.available and association.desired;
                    if (entered == should_enter) continue;
                    if (should_enter) try association.entered.ensureUnusedCapacity(adapter.allocator, 1);
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
                        association.entered.appendAssumeCapacity(@intCast(resource_index))
                    else
                        removeEntered(association, @intCast(resource_index));
                    completed += 1;
                }
                if (!association.desired and association.entered.items.len == 0)
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
                .scale => .{ .scale = .{
                    .factor = @intCast(@divTrunc(@as(u64, adapter.scale_120) + 119, 120)),
                } },
                .name => .{ .name = .{ .name = adapter.name } },
                .description => .{ .description = .{ .description = adapter.description } },
                .done => .{ .done = .{} },
            };
            try Output.encodeEvent(queue, resource.handle.id, event);
        }

        fn acquireResource(adapter: *Self) !u32 {
            if (adapter.resource_free == none) try adapter.growResources();
            const index = adapter.resource_free;
            const resource = adapter.resources[index];
            adapter.resource_free = resource.next_free;
            resource.active = true;
            resource.next_free = none;
            adapter.associations_dirty = true;
            return index;
        }

        fn releaseResource(adapter: *Self, index: u32) void {
            const generation = adapter.resources[index].generation +% 1;
            adapter.resources[index].* = .{
                .generation = generation,
                .next_free = adapter.resource_free,
            };
            adapter.resource_free = index;
            adapter.associations_dirty = true;
        }

        fn acquireAssociation(adapter: *Self) !*Association {
            if (adapter.association_free == none) try adapter.ensureAssociations(1);
            const index = adapter.association_free;
            const association = &adapter.associations[index];
            adapter.association_free = association.next_free;
            const entered = association.entered;
            association.* = .{ .active = true, .entered = entered };
            return association;
        }

        fn releaseAssociation(adapter: *Self, index: u32) void {
            adapter.associations[index].entered.clearRetainingCapacity();
            const entered = adapter.associations[index].entered;
            adapter.associations[index] = .{ .next_free = adapter.association_free, .entered = entered };
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

        fn ensureOutbound(adapter: *Self, needed: usize) !void {
            const required = try std.math.add(usize, adapter.outbound_len, needed);
            if (required <= adapter.outbound.len) return;
            var capacity = adapter.outbound.len;
            while (capacity < required) capacity = try std.math.add(usize, capacity, @max(capacity / 2, 1));
            const old_len = adapter.outbound.len;
            adapter.outbound = try adapter.allocator.realloc(adapter.outbound, capacity);
            @memset(adapter.outbound[old_len..], .{});
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
                adapter.outbound_len += 1;
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
                if (slot.active and std.meta.eql(slot.resource, id)) {
                    slot.active = false;
                    adapter.outbound_len -= 1;
                }
            }
        }

        fn hasPendingAssociations(adapter: *const Self) bool {
            for (adapter.associations) |association| {
                if (!association.active) continue;
                for (adapter.resources, 0..) |resource, index| {
                    if (!resource.active) continue;
                    const entered = isEntered(&association, @intCast(index));
                    if (entered != (adapter.available and association.desired)) return true;
                }
            }
            return false;
        }

        fn idFor(adapter: *const Self, index: u32) Id {
            return .{ .index = index, .generation = adapter.resources[index].generation };
        }

        fn resolve(adapter: *Self, id: Id) !*Resource {
            if (id.index >= adapter.resources.len) return error.StaleResource;
            const resource = adapter.resources[id.index];
            if (!resource.active or resource.generation != id.generation)
                return error.StaleResource;
            return resource;
        }

        fn indexFor(adapter: *const Self, resource: *const Resource) u32 {
            for (adapter.resources, 0..) |candidate, index|
                if (candidate == resource) return @intCast(index);
            unreachable;
        }

        fn fromContext(adapter: *Self, context: ?*anyopaque) ?*Resource {
            const resource: *Resource = @ptrCast(@alignCast(context orelse return null));
            for (adapter.resources) |candidate| if (candidate == resource) return resource;
            return null;
        }

        fn growResources(adapter: *Self) !void {
            if (adapter.resources.len >= none) return error.OutOfMemory;
            const resource = try adapter.allocator.create(Resource);
            errdefer adapter.allocator.destroy(resource);
            const old_len = adapter.resources.len;
            adapter.resources = try adapter.allocator.realloc(adapter.resources, old_len + 1);
            resource.* = .{};
            adapter.resources[old_len] = resource;
            adapter.resource_free = @intCast(old_len);
        }

        fn ensureAssociations(adapter: *Self, needed: usize) !void {
            var free: usize = 0;
            for (adapter.associations) |association| free += @intFromBool(!association.active);
            if (free >= needed) return;
            const additional = needed - free;
            const old_len = adapter.associations.len;
            const new_len = try std.math.add(usize, old_len, @max(additional, @max(old_len / 2, 1)));
            if (new_len >= none) return error.OutOfMemory;
            adapter.associations = try adapter.allocator.realloc(adapter.associations, new_len);
            for (adapter.associations[old_len..], old_len..) |*association, index| association.* = .{
                .next_free = if (index + 1 < new_len) @intCast(index + 1) else adapter.association_free,
            };
            adapter.association_free = @intCast(old_len);
        }

        fn isEntered(association: *const Association, resource_index: u32) bool {
            return std.mem.indexOfScalar(u32, association.entered.items, resource_index) != null;
        }

        fn removeEntered(association: *Association, resource_index: u32) void {
            if (std.mem.indexOfScalar(u32, association.entered.items, resource_index)) |index|
                _ = association.entered.swapRemove(index);
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
    const object_a: objects.Object = .{
        .interface = &@import("core_protocol").wl_output.info,
        .version = 4,
        .context = adapter.resources[resource_a],
    };
    try std.testing.expectEqual(
        adapter.resources[resource_a].handle,
        (try adapter.reference(peer_a, adapter.resources[resource_a].handle, object_a)).handle,
    );
    try std.testing.expectError(
        error.ForeignResource,
        adapter.reference(peer_b, adapter.resources[resource_a].handle, object_a),
    );
    try std.testing.expectError(
        error.ForeignResource,
        adapter.reference(peer_a, .{ .id = 9, .generation = 99 }, object_a),
    );
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

test "output: storage grows beyond initial capacities" {
    const TestAdapter = Adapter(@import("core_protocol"));
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .resource_capacity = 1,
        .association_capacity = 1,
        .outbound_capacity = 1,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 8 };

    const first = try adapter.acquireResource();
    const first_context = adapter.resources[first];
    first_context.peer = peer;
    first_context.handle = .{ .id = 20, .generation = 1 };
    var index: usize = 1;
    while (index < 70) : (index += 1) {
        const resource_index = try adapter.acquireResource();
        adapter.resources[resource_index].peer = peer;
        adapter.resources[resource_index].handle = .{ .id = @intCast(20 + index), .generation = 1 };
    }
    try std.testing.expect(first_context == adapter.resources[first]);
    try std.testing.expect(adapter.fromContext(first_context) == first_context);

    const surfaces = [_]objects.Handle{
        .{ .id = 100, .generation = 1 },
        .{ .id = 101, .generation = 1 },
        .{ .id = 102, .generation = 1 },
    };
    try adapter.reconcileSurfaces(peer, &surfaces);
    try std.testing.expect(adapter.associations.len > 1);
    for (surfaces) |surface| try std.testing.expect(adapter.findAssociation(peer, surface) != null);

    try adapter.enqueue(adapter.idFor(first), .geometry);
    try adapter.ensureOutbound(3);
    try adapter.enqueue(adapter.idFor(first), .scale);
    try adapter.enqueue(adapter.idFor(first), .done);
    try std.testing.expect(adapter.outbound.len > 1);
    try std.testing.expectEqual(@as(u64, 1), adapter.oldestOutbound(peer).?.sequence);

    const old_id = adapter.idFor(first);
    adapter.dropOutbound(old_id);
    adapter.releaseResource(first);
    const reused = try adapter.acquireResource();
    try std.testing.expectEqual(first, reused);
    try std.testing.expect(old_id.generation != adapter.idFor(reused).generation);
    try std.testing.expectError(error.StaleResource, adapter.resolve(old_id));
}

test "output: fractional scale republishes integer fallback and logical size" {
    const TestAdapter = Adapter(@import("core_protocol"));
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .resource_capacity = 1,
        .association_capacity = 1,
        .outbound_capacity = 1,
    });
    defer adapter.deinit();
    try adapter.publishMode(1920, 1200, 60_000, 600, 340);
    const resource_index = try adapter.acquireResource();
    const resource = adapter.resources[resource_index];
    resource.peer = .{ .slot = 1, .generation = 1 };
    resource.version = 4;
    resource.handle = .{ .id = 7, .generation = 1 };

    try adapter.publishScale(156);
    const snapshot = adapter.logicalSnapshot();
    try std.testing.expectEqual(@as(?i32, 1476), snapshot.width);
    try std.testing.expectEqual(@as(?i32, 923), snapshot.height);
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_len);
    try std.testing.expect(adapter.oldestOutbound(resource.peer).?.event == .scale);
    try adapter.publishScale(156);
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_len);
    try std.testing.expectError(error.InvalidScale, adapter.publishScale(0));
}
