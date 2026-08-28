//! Bounded xdg-toplevel-icon-v1 builders and committed icon snapshots.
//!
//! Source icon objects remain mutable until their first successful assignment.
//! Assignment deep-copies the name and every SHM variant, so destroying the
//! source icon and its buffers cannot alter a toplevel's pending/current icon.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 16,
    icon_capacity: usize = 64,
    variant_capacity: usize = 256,
    assignment_capacity: usize = 64,
    name_bytes: usize = 256,
    max_snapshot_bytes: usize = 64 * 1024 * 1024,

    fn validate(config: Config) !void {
        inline for (.{ config.manager_capacity, config.icon_capacity, config.variant_capacity, config.assignment_capacity, config.name_bytes, config.max_snapshot_bytes }) |capacity|
            if (capacity == 0 or capacity >= none) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Shell: type, comptime Shm: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xdg_toplevel_icon_manager_v1;
        const Icon = protocol.xdg_toplevel_icon_v1;

        pub const Variant = struct {
            width: u32,
            scale: i32,
            stride: usize,
            format: wayring.shm.Format,
            bytes: []const u8,
        };

        pub const Snapshot = struct {
            name: []const u8,
            variants: []const Variant,
        };

        const ManagerSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            done_pending: bool = false,
        };

        const IconSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            name_len: usize = 0,
            immutable: bool = false,
        };

        const SourceVariant = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            icon_index: u32 = none,
            icon_generation: u32 = 0,
            buffer: objects.Handle = .{ .id = 0, .generation = 0 },
            token: wayring.shm.BufferToken = undefined,
            width: u32 = 0,
            scale: i32 = 0,
            stride: usize = 0,
            format: wayring.shm.Format = undefined,
            extent: usize = 0,
        };

        const OwnedSnapshot = struct {
            name: []u8,
            variants: []Variant,
            allocation_bytes: usize,
        };

        const AssignmentSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            toplevel: Shell.ToplevelId = undefined,
            pending_valid: bool = false,
            pending: ?OwnedSnapshot = null,
            current: ?OwnedSnapshot = null,
        };

        allocator: std.mem.Allocator,
        shell: *Shell,
        shm: *Shm,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        managers: []ManagerSlot,
        icons: []IconSlot,
        variants: []SourceVariant,
        assignments: []AssignmentSlot,
        names: []u8,
        name_bytes: usize,
        snapshot_limit: usize,
        snapshot_bytes: usize = 0,
        manager_free: u32 = 0,
        icon_free: u32 = 0,
        variant_free: u32 = 0,
        assignment_free: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, shell: *Shell, shm: *Shm, config: Config) !Self {
            try config.validate();
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const icons = try allocator.alloc(IconSlot, config.icon_capacity);
            errdefer allocator.free(icons);
            const variants = try allocator.alloc(SourceVariant, config.variant_capacity);
            errdefer allocator.free(variants);
            const assignments = try allocator.alloc(AssignmentSlot, config.assignment_capacity);
            errdefer allocator.free(assignments);
            const names = try allocator.alloc(u8, try std.math.mul(usize, config.icon_capacity, config.name_bytes));
            errdefer allocator.free(names);
            initFree(ManagerSlot, managers);
            initFree(IconSlot, icons);
            initFree(SourceVariant, variants);
            initFree(AssignmentSlot, assignments);
            return .{
                .allocator = allocator,
                .shell = shell,
                .shm = shm,
                .managers = managers,
                .icons = icons,
                .variants = variants,
                .assignments = assignments,
                .names = names,
                .name_bytes = config.name_bytes,
                .snapshot_limit = config.max_snapshot_bytes,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.assignments) |*slot| if (slot.active) {
                self.freeSnapshot(&slot.pending);
                self.freeSnapshot(&slot.current);
            };
            std.debug.assert(self.snapshot_bytes == 0);
            self.allocator.free(self.names);
            self.allocator.free(self.assignments);
            self.allocator.free(self.variants);
            self.allocator.free(self.icons);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = try self.acquireManager();
            slot.peer = binding.peer;
            slot.resource = binding.resource;
            slot.done_pending = true;
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_icon => |payload| {
                        const icon = self.acquireIcon() catch return try self.noMemory(actor);
                        icon.peer = peer;
                        const admitted = Manager.admit_create_icon(server_objects, decoded.handle, payload, .{ .id = icon }) catch |cause| {
                            self.releaseIcon(indexOf(IconSlot, self.icons, icon));
                            return try self.failure(actor, decoded.handle.id, cause);
                        };
                        icon.resource = admitted.id;
                    },
                    .set_icon => |payload| {
                        const toplevel = self.shell.toplevelIdOn(server_objects, payload.toplevel) catch
                            return try self.failure(actor, decoded.handle.id, error.InvalidToplevel);
                        if (payload.icon) |object_id| {
                            const icon_handle = server_objects.namespace.lookupHandle(object_id) orelse
                                return try self.failure(actor, decoded.handle.id, error.InvalidIcon);
                            const object = server_objects.namespace.resolve(icon_handle) orelse
                                return try self.failure(actor, decoded.handle.id, error.InvalidIcon);
                            const icon = from(IconSlot, self.icons, object.context) orelse
                                return try self.failure(actor, decoded.handle.id, error.InvalidIcon);
                            if (object.interface != &Icon.info or !std.meta.eql(icon.resource, icon_handle) or !samePeer(icon.peer, peer))
                                return try self.failure(actor, decoded.handle.id, error.InvalidIcon);
                            self.assign(toplevel, icon) catch |cause| switch (cause) {
                                error.Exhausted, error.OutOfMemory => return try self.noMemory(actor),
                                else => return try self.failure(actor, decoded.handle.id, cause),
                            };
                        } else self.reset(toplevel) catch return try self.noMemory(actor);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Icon.info) {
                const icon = from(IconSlot, self.icons, target.object.context) orelse return null;
                if (!std.meta.eql(icon.resource, handle) or !samePeer(icon.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Icon, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_name => |payload| {
                        if (icon.immutable) return try self.immutable(actor, decoded.handle.id);
                        if (payload.icon_name.len > self.name_bytes) return try self.noMemory(actor);
                        const destination = self.iconName(icon);
                        @memcpy(destination[0..payload.icon_name.len], payload.icon_name);
                        icon.name_len = payload.icon_name.len;
                    },
                    .add_buffer => |payload| {
                        if (icon.immutable) return try self.immutable(actor, decoded.handle.id);
                        if (payload.scale <= 0)
                            return try self.invalidBuffer(actor, decoded.handle.id, "icon buffer scale must be positive");
                        const buffer_handle = server_objects.namespace.lookupHandle(payload.buffer) orelse
                            return try self.invalidBuffer(actor, decoded.handle.id, "invalid icon buffer");
                        const object = server_objects.namespace.resolve(buffer_handle) orelse
                            return try self.invalidBuffer(actor, decoded.handle.id, "invalid icon buffer");
                        const token = self.shm.bufferToken(object) orelse
                            return try self.invalidBuffer(actor, decoded.handle.id, "icon buffer must use wl_shm");
                        const info = self.shm.store.bufferInfo(token) catch
                            return try self.invalidBuffer(actor, decoded.handle.id, "invalid icon buffer backing");
                        if (info.width == 0 or info.width != info.height)
                            return try self.invalidBuffer(actor, decoded.handle.id, "icon buffer must be square");
                        const variant = self.findVariant(icon, info.width, payload.scale) orelse
                            self.acquireVariant() catch return try self.noMemory(actor);
                        variant.* = .{
                            .active = true,
                            .generation = variant.generation,
                            .icon_index = indexOf(IconSlot, self.icons, icon),
                            .icon_generation = icon.generation,
                            .buffer = buffer_handle,
                            .token = token,
                            .width = info.width,
                            .scale = payload.scale,
                            .stride = info.stride,
                            .format = info.format,
                            .extent = info.extent,
                        };
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.managers) |slot| if (slot.active and slot.done_pending and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.managers) |*slot| {
                if (!slot.active or !slot.done_pending or !samePeer(slot.peer, peer)) continue;
                if (server_objects.namespace.resolve(slot.resource) == null) {
                    slot.done_pending = false;
                    continue;
                }
                Manager.encodeEvent(queue, slot.resource.id, .{ .done = .{} }) catch |cause| switch (cause) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return cause,
                };
                slot.done_pending = false;
                count += 1;
            }
            return count;
        }

        /// Publishes the pending icon state at the wl_surface commit boundary.
        pub fn surfaceCommitted(self: *Self, surface: Shell.SurfaceId) !void {
            const toplevel = self.shell.toplevelForSurface(surface) catch return;
            const slot = self.findAssignment(toplevel) orelse return;
            if (!slot.pending_valid) return;
            self.freeSnapshot(&slot.current);
            slot.current = slot.pending;
            slot.pending = null;
            slot.pending_valid = false;
            if (slot.current == null) self.releaseAssignmentIfEmpty(slot);
        }

        pub fn snapshot(self: *const Self, toplevel: Shell.ToplevelId) ?Snapshot {
            const slot = self.findAssignmentConst(toplevel) orelse return null;
            const current = slot.current orelse return null;
            return .{ .name = current.name, .variants = current.variants };
        }

        /// Called before Shell handles xdg_toplevel removal.
        pub fn toplevelRemoved(self: *Self, handle: objects.Handle, object: objects.Object) void {
            const toplevel = self.shell.toplevelIdResource(handle, &object) catch return;
            if (self.findAssignment(toplevel)) |slot| self.releaseAssignment(indexOf(AssignmentSlot, self.assignments, slot));
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Icon.info) {
                const icon = from(IconSlot, self.icons, object.context) orelse return false;
                if (!std.meta.eql(icon.resource, handle)) return false;
                self.releaseIcon(indexOf(IconSlot, self.icons, icon));
                return true;
            }
            if (object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                self.releaseManager(indexOf(ManagerSlot, self.managers, manager));
                return true;
            }
            if (object.interface == &protocol.wl_buffer.info) {
                for (self.variants) |*variant| {
                    if (!variant.active or !std.meta.eql(variant.buffer, handle)) continue;
                    const icon = self.resolveIcon(variant.icon_index, variant.icon_generation) catch {
                        self.releaseVariant(indexOf(SourceVariant, self.variants, variant));
                        continue;
                    };
                    if (self.runtime) |runtime| {
                        if (runtime.clients.reactor.getActor(icon.peer)) |actor| {
                            Core.postError(actor, icon.resource.id, Icon.@"error".no_buffer.value, "icon buffer destroyed before icon") catch {};
                        } else |_| {}
                    }
                    self.releaseVariant(indexOf(SourceVariant, self.variants, variant));
                }
                return false;
            }
            return false;
        }

        fn assign(self: *Self, toplevel: Shell.ToplevelId, icon: *IconSlot) !void {
            if (icon.name_len == 0 and !self.hasVariants(icon)) {
                try self.reset(toplevel);
                icon.immutable = true;
                return;
            }
            var snapshot_value = try self.copySnapshot(icon);
            errdefer self.destroySnapshot(&snapshot_value);
            const assignment = self.findAssignment(toplevel) orelse try self.acquireAssignment(toplevel);
            self.freeSnapshot(&assignment.pending);
            assignment.pending = snapshot_value;
            assignment.pending_valid = true;
            icon.immutable = true;
        }

        fn reset(self: *Self, toplevel: Shell.ToplevelId) !void {
            if (self.findAssignment(toplevel)) |assignment| {
                self.freeSnapshot(&assignment.pending);
                assignment.pending = null;
                assignment.pending_valid = true;
            }
        }

        fn copySnapshot(self: *Self, icon: *IconSlot) !OwnedSnapshot {
            var count: usize = 0;
            var total = icon.name_len;
            for (self.variants) |variant| if (self.variantBelongs(variant, icon)) {
                count += 1;
                total = try std.math.add(usize, total, variant.extent);
            };
            if (total > self.snapshot_limit - self.snapshot_bytes) return error.Exhausted;
            const name = try self.allocator.dupe(u8, self.iconName(icon)[0..icon.name_len]);
            errdefer self.allocator.free(name);
            const variants = try self.allocator.alloc(Variant, count);
            errdefer self.allocator.free(variants);
            var initialized: usize = 0;
            errdefer for (variants[0..initialized]) |variant| self.allocator.free(@constCast(variant.bytes));
            for (self.variants) |source| {
                if (!self.variantBelongs(source, icon)) continue;
                const bytes = copied: {
                    const destination = try self.allocator.alloc(u8, source.extent);
                    errdefer self.allocator.free(destination);
                    const pin = try self.shm.store.pin(source.token);
                    defer self.shm.store.unpin(pin) catch {};
                    var access = try self.shm.store.access(pin);
                    var access_active = true;
                    defer if (access_active) access.end() catch {};
                    if (access.bytes.len != destination.len) return error.InvalidBuffer;
                    @memcpy(destination, access.bytes);
                    try access.end();
                    access_active = false;
                    break :copied destination;
                };
                variants[initialized] = .{
                    .width = source.width,
                    .scale = source.scale,
                    .stride = source.stride,
                    .format = source.format,
                    .bytes = bytes,
                };
                initialized += 1;
            }
            self.snapshot_bytes += total;
            return .{ .name = name, .variants = variants, .allocation_bytes = total };
        }

        fn destroySnapshot(self: *Self, snapshot_value: *OwnedSnapshot) void {
            for (snapshot_value.variants) |variant| self.allocator.free(@constCast(variant.bytes));
            self.allocator.free(snapshot_value.variants);
            self.allocator.free(snapshot_value.name);
            std.debug.assert(self.snapshot_bytes >= snapshot_value.allocation_bytes);
            self.snapshot_bytes -= snapshot_value.allocation_bytes;
            snapshot_value.* = undefined;
        }

        fn freeSnapshot(self: *Self, optional: *?OwnedSnapshot) void {
            if (optional.*) |*snapshot_value| self.destroySnapshot(snapshot_value);
            optional.* = null;
        }

        fn acquireManager(self: *Self) !*ManagerSlot {
            return acquire(ManagerSlot, self.managers, &self.manager_free);
        }
        fn acquireIcon(self: *Self) !*IconSlot {
            return acquire(IconSlot, self.icons, &self.icon_free);
        }
        fn acquireVariant(self: *Self) !*SourceVariant {
            return acquire(SourceVariant, self.variants, &self.variant_free);
        }
        fn acquireAssignment(self: *Self, toplevel: Shell.ToplevelId) !*AssignmentSlot {
            const slot = try acquire(AssignmentSlot, self.assignments, &self.assignment_free);
            slot.toplevel = toplevel;
            return slot;
        }

        fn releaseManager(self: *Self, index: u32) void {
            release(ManagerSlot, self.managers, &self.manager_free, index);
        }
        fn releaseIcon(self: *Self, index: u32) void {
            const icon = &self.icons[index];
            if (!icon.active) return;
            for (self.variants, 0..) |variant, i| if (self.variantBelongs(variant, icon)) self.releaseVariant(@intCast(i));
            release(IconSlot, self.icons, &self.icon_free, index);
        }
        fn releaseVariant(self: *Self, index: u32) void {
            release(SourceVariant, self.variants, &self.variant_free, index);
        }
        fn releaseAssignment(self: *Self, index: u32) void {
            const slot = &self.assignments[index];
            if (!slot.active) return;
            self.freeSnapshot(&slot.pending);
            self.freeSnapshot(&slot.current);
            release(AssignmentSlot, self.assignments, &self.assignment_free, index);
        }
        fn releaseAssignmentIfEmpty(self: *Self, slot: *AssignmentSlot) void {
            if (!slot.pending_valid and slot.pending == null and slot.current == null)
                self.releaseAssignment(indexOf(AssignmentSlot, self.assignments, slot));
        }

        fn resolveIcon(self: *Self, index: u32, generation: u32) !*IconSlot {
            if (index >= self.icons.len) return error.StaleIcon;
            const slot = &self.icons[index];
            if (!slot.active or slot.generation != generation) return error.StaleIcon;
            return slot;
        }
        fn findVariant(self: *Self, icon: *IconSlot, width: u32, scale: i32) ?*SourceVariant {
            for (self.variants) |*variant| if (self.variantBelongs(variant.*, icon) and variant.width == width and variant.scale == scale) return variant;
            return null;
        }
        fn hasVariants(self: *const Self, icon: *const IconSlot) bool {
            for (self.variants) |variant| if (self.variantBelongs(variant, icon)) return true;
            return false;
        }
        fn variantBelongs(self: *const Self, variant: SourceVariant, icon: *const IconSlot) bool {
            return variant.active and variant.icon_index == indexOf(IconSlot, self.icons, icon) and variant.icon_generation == icon.generation;
        }
        fn findAssignment(self: *Self, toplevel: Shell.ToplevelId) ?*AssignmentSlot {
            for (self.assignments) |*slot| if (slot.active and std.meta.eql(slot.toplevel, toplevel)) return slot;
            return null;
        }
        fn findAssignmentConst(self: *const Self, toplevel: Shell.ToplevelId) ?*const AssignmentSlot {
            for (self.assignments) |*slot| if (slot.active and std.meta.eql(slot.toplevel, toplevel)) return slot;
            return null;
        }
        fn iconName(self: *Self, icon: *IconSlot) []u8 {
            const index = indexOf(IconSlot, self.icons, icon);
            return self.names[index * self.name_bytes ..][0..self.name_bytes];
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn immutable(_: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            try Core.postError(actor, id, Icon.@"error".immutable.value, "assigned icon is immutable");
            return .stop;
        }
        fn invalidBuffer(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, Icon.@"error".invalid_buffer.value, message);
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return self.protocolError(actor, id, 0, @errorName(cause));
        }
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, i| slot.* = .{ .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none };
}

fn acquire(comptime T: type, slots: []T, free_head: *u32) !*T {
    if (free_head.* == none) return error.Exhausted;
    const index = free_head.*;
    const slot = &slots[index];
    free_head.* = slot.next_free;
    slot.* = .{ .active = true, .generation = slot.generation };
    return slot;
}

fn release(comptime T: type, slots: []T, free_head: *u32, index: u32) void {
    const slot = &slots[index];
    if (!slot.active) return;
    const next = slot.generation +% 1;
    slot.* = .{ .generation = if (next == 0) 1 else next, .next_free = free_head.* };
    free_head.* = index;
}

fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active) slot else null;
}

fn indexOf(comptime T: type, slots: []const T, slot: *const T) u32 {
    return @intCast((@intFromPtr(slot) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "toplevel icon slots are bounded and generation safe" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        pub const ToplevelId = packed struct { index: u32, generation: u32 };

        pub fn toplevelForSurface(_: *@This(), surface: SurfaceId) !ToplevelId {
            return .{ .index = surface.index, .generation = surface.generation };
        }
    };
    const TestShm = wayring.server.Shm(protocol);
    const A = Adapter(protocol, FakeShell, TestShm);
    var shm = try TestShm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &.{
            .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
            .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
        },
    });
    defer shm.deinit(std.testing.allocator);
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &shell, &shm, .{
        .manager_capacity = 1,
        .icon_capacity = 1,
        .variant_capacity = 1,
        .assignment_capacity = 1,
        .name_bytes = 8,
        .max_snapshot_bytes = 16,
    });
    defer adapter.deinit();
    const first = try adapter.acquireIcon();
    try std.testing.expectError(error.Exhausted, adapter.acquireIcon());
    const generation = first.generation;
    adapter.releaseIcon(0);
    const second = try adapter.acquireIcon();
    try std.testing.expect(second.generation != generation);
    try std.testing.expectEqual(@as(usize, 0), second.name_len);
    try std.testing.expect(!second.immutable);
}

test "toplevel icon assignment snapshots name and publishes on commit" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        pub const ToplevelId = packed struct { index: u32, generation: u32 };

        pub fn toplevelForSurface(_: *@This(), surface: SurfaceId) !ToplevelId {
            return .{ .index = surface.index, .generation = surface.generation };
        }
    };
    const TestShm = wayring.server.Shm(protocol);
    const A = Adapter(protocol, FakeShell, TestShm);
    var shm = try TestShm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &.{
            .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
            .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
        },
    });
    defer shm.deinit(std.testing.allocator);
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &shell, &shm, .{
        .manager_capacity = 1,
        .icon_capacity = 2,
        .variant_capacity = 1,
        .assignment_capacity = 1,
        .name_bytes = 16,
        .max_snapshot_bytes = 32,
    });
    defer adapter.deinit();

    const toplevel: FakeShell.ToplevelId = .{ .index = 2, .generation = 7 };
    const surface: FakeShell.SurfaceId = .{ .index = 2, .generation = 7 };
    const icon = try adapter.acquireIcon();
    @memcpy(adapter.iconName(icon)[0..4], "ouro");
    icon.name_len = 4;
    try adapter.assign(toplevel, icon);
    try std.testing.expect(icon.immutable);
    try std.testing.expect(adapter.snapshot(toplevel) == null);

    @memcpy(adapter.iconName(icon)[0..4], "xxxx");
    try adapter.surfaceCommitted(surface);
    try std.testing.expectEqualStrings("ouro", adapter.snapshot(toplevel).?.name);

    try adapter.reset(toplevel);
    try std.testing.expect(adapter.snapshot(toplevel) != null);
    try adapter.surfaceCommitted(surface);
    try std.testing.expect(adapter.snapshot(toplevel) == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.snapshot_bytes);

    const empty = try adapter.acquireIcon();
    try adapter.assign(toplevel, empty);
    try std.testing.expect(empty.immutable);
    try std.testing.expect(adapter.findAssignment(toplevel) == null);
}

test "toplevel icon assignment deep copies ordinary SHM variants" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        pub const ToplevelId = packed struct { index: u32, generation: u32 };

        pub fn toplevelForSurface(_: *@This(), surface: SurfaceId) !ToplevelId {
            return .{ .index = surface.index, .generation = surface.generation };
        }
    };
    const TestShm = wayring.server.Shm(protocol);
    const A = Adapter(protocol, FakeShell, TestShm);
    const formats = [_]wayring.shm.Format{
        .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
        .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
    };
    var shm = try TestShm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &formats,
    });
    defer shm.deinit(std.testing.allocator);
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &shell, &shm, .{
        .manager_capacity = 1,
        .icon_capacity = 1,
        .variant_capacity = 1,
        .assignment_capacity = 1,
        .name_bytes = 8,
        .max_snapshot_bytes = 32,
    });
    defer adapter.deinit();

    const linux = std.os.linux;
    const result = linux.memfd_create("ouro-toplevel-icon-test", linux.MFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(result));
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.ftruncate(fd, 16)));
    const original = [_]u8{ 1, 2, 3, 4 } ** 4;
    try std.testing.expectEqual(@as(usize, original.len), linux.pwrite(fd, &original, original.len, 0));
    const pool = try shm.store.addPool(fd, 16);
    const token = try shm.store.addBuffer(pool, formats[1], 0, 2, 2, 8);

    const icon = try adapter.acquireIcon();
    const variant = try adapter.acquireVariant();
    variant.* = .{
        .active = true,
        .generation = variant.generation,
        .icon_index = 0,
        .icon_generation = icon.generation,
        .buffer = .{ .id = 9, .generation = 1 },
        .token = token,
        .width = 2,
        .scale = 1,
        .stride = 8,
        .format = formats[1],
        .extent = 16,
    };
    const toplevel: FakeShell.ToplevelId = .{ .index = 3, .generation = 4 };
    try adapter.assign(toplevel, icon);
    const replacement = [_]u8{ 9, 8, 7, 6 } ** 4;
    try std.testing.expectEqual(@as(usize, replacement.len), linux.pwrite(fd, &replacement, replacement.len, 0));
    adapter.releaseIcon(0);
    try shm.store.destroyBuffer(token);
    try shm.store.destroyPoolResource(pool);

    try adapter.surfaceCommitted(.{ .index = 3, .generation = 4 });
    const snapshot_value = adapter.snapshot(toplevel).?;
    try std.testing.expectEqual(@as(usize, 1), snapshot_value.variants.len);
    try std.testing.expectEqualSlices(u8, &original, snapshot_value.variants[0].bytes);
    try adapter.reset(toplevel);
    try adapter.surfaceCommitted(.{ .index = 3, .generation = 4 });
}
