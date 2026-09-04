//! Bounded xdg-toplevel-icon-v1 builders and committed icon snapshots.
//!
//! Source icon objects remain mutable until their first successful assignment.
//! Assignment deep-copies the name and every SHM variant, so destroying the
//! source icon and its buffers cannot alter a toplevel's pending/current icon.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
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
            header: slot_pool.Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            done_pending: bool = false,
        };

        const IconSlot = struct {
            header: slot_pool.Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            name_len: usize = 0,
            name: []u8 = &.{},
            immutable: bool = false,
        };

        const SourceVariant = struct {
            header: slot_pool.Header = .{},
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
            header: slot_pool.Header = .{},
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
        managers: slot_pool.Pool(ManagerSlot),
        icons: slot_pool.Pool(IconSlot),
        variants: slot_pool.Pool(SourceVariant),
        assignments: slot_pool.Pool(AssignmentSlot),
        name_bytes: usize,
        snapshot_limit: usize,
        snapshot_bytes: usize = 0,

        pub fn init(allocator: std.mem.Allocator, shell: *Shell, shm: *Shm, config: Config) !Self {
            try config.validate();
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, config.manager_capacity);
            errdefer managers.deinit();
            var icons = try slot_pool.Pool(IconSlot).init(allocator, config.icon_capacity);
            errdefer icons.deinit();
            var variants = try slot_pool.Pool(SourceVariant).init(allocator, config.variant_capacity);
            errdefer variants.deinit();
            const assignments = try slot_pool.Pool(AssignmentSlot).init(allocator, config.assignment_capacity);
            return .{
                .allocator = allocator,
                .shell = shell,
                .shm = shm,
                .managers = managers,
                .icons = icons,
                .variants = variants,
                .assignments = assignments,
                .name_bytes = config.name_bytes,
                .snapshot_limit = config.max_snapshot_bytes,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.assignments.entries.items) |slot| if (slot.header.active) {
                self.freeSnapshot(&slot.pending);
                self.freeSnapshot(&slot.current);
            };
            std.debug.assert(self.snapshot_bytes == 0);
            for (self.icons.entries.items) |slot| if (slot.name.len != 0) self.allocator.free(slot.name);
            self.assignments.deinit();
            self.variants.deinit();
            self.icons.deinit();
            self.managers.deinit();
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
                const manager = from(ManagerSlot, &self.managers, target.object.context) orelse return null;
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
                            const icon = from(IconSlot, &self.icons, object.context) orelse
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
                const icon = from(IconSlot, &self.icons, target.object.context) orelse return null;
                if (!std.meta.eql(icon.resource, handle) or !samePeer(icon.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Icon, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_name => |payload| {
                        if (icon.immutable) return try self.immutable(actor, decoded.handle.id);
                        self.setName(icon, payload.icon_name);
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
                            .header = variant.header,
                            .icon_index = icon.header.index,
                            .icon_generation = icon.header.generation,
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
            for (self.managers.entries.items) |slot| if (slot.header.active and slot.done_pending and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.managers.entries.items) |slot| {
                if (!slot.header.active or !slot.done_pending or !samePeer(slot.peer, peer)) continue;
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
                const icon = from(IconSlot, &self.icons, object.context) orelse return false;
                if (!std.meta.eql(icon.resource, handle)) return false;
                self.releaseIcon(indexOf(IconSlot, self.icons, icon));
                return true;
            }
            if (object.interface == &Manager.info) {
                const manager = from(ManagerSlot, &self.managers, object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                self.releaseManager(indexOf(ManagerSlot, self.managers, manager));
                return true;
            }
            if (object.interface == &protocol.wl_buffer.info) {
                for (self.variants.entries.items) |variant| {
                    if (!variant.header.active or !std.meta.eql(variant.buffer, handle)) continue;
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
            for (self.variants.entries.items) |variant| if (self.variantBelongs(variant.*, icon)) {
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
            for (self.variants.entries.items) |source_ptr| {
                const source = source_ptr.*;
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
            return self.managers.acquire();
        }
        fn acquireIcon(self: *Self) !*IconSlot {
            const slot = try self.icons.acquire();
            slot.name = self.allocator.alloc(u8, self.name_bytes) catch |err| {
                self.icons.release(slot);
                return err;
            };
            return slot;
        }
        fn setName(self: *Self, icon: *IconSlot, name: []const u8) void {
            if (name.len > self.name_bytes) {
                icon.name_len = 0;
                return;
            }
            @memcpy(icon.name[0..name.len], name);
            icon.name_len = name.len;
        }
        fn acquireVariant(self: *Self) !*SourceVariant {
            return self.variants.acquire();
        }
        fn acquireAssignment(self: *Self, toplevel: Shell.ToplevelId) !*AssignmentSlot {
            const slot = try self.assignments.acquire();
            slot.toplevel = toplevel;
            return slot;
        }

        fn releaseManager(self: *Self, index: u32) void {
            if (self.managers.at(index)) |slot| self.managers.release(slot);
        }
        fn releaseIcon(self: *Self, index: u32) void {
            const icon = self.icons.at(index) orelse return;
            for (self.variants.entries.items) |variant| if (self.variantBelongs(variant.*, icon)) self.releaseVariant(variant.header.index);
            self.allocator.free(icon.name);
            icon.name = &.{};
            self.icons.release(icon);
        }
        fn releaseVariant(self: *Self, index: u32) void {
            if (self.variants.at(index)) |slot| self.variants.release(slot);
        }
        fn releaseAssignment(self: *Self, index: u32) void {
            const slot = self.assignments.at(index) orelse return;
            self.freeSnapshot(&slot.pending);
            self.freeSnapshot(&slot.current);
            self.assignments.release(slot);
        }
        fn releaseAssignmentIfEmpty(self: *Self, slot: *AssignmentSlot) void {
            if (!slot.pending_valid and slot.pending == null and slot.current == null)
                self.releaseAssignment(indexOf(AssignmentSlot, self.assignments, slot));
        }

        fn resolveIcon(self: *Self, index: u32, generation: u32) !*IconSlot {
            const slot = self.icons.at(index) orelse return error.StaleIcon;
            if (slot.header.generation != generation) return error.StaleIcon;
            return slot;
        }
        fn findVariant(self: *Self, icon: *IconSlot, width: u32, scale: i32) ?*SourceVariant {
            for (self.variants.entries.items) |variant| if (self.variantBelongs(variant.*, icon) and variant.width == width and variant.scale == scale) return variant;
            return null;
        }
        fn hasVariants(self: *const Self, icon: *const IconSlot) bool {
            for (self.variants.entries.items) |variant| if (self.variantBelongs(variant.*, icon)) return true;
            return false;
        }
        fn variantBelongs(self: *const Self, variant: SourceVariant, icon: *const IconSlot) bool {
            _ = self;
            return variant.header.active and variant.icon_index == icon.header.index and variant.icon_generation == icon.header.generation;
        }
        fn findAssignment(self: *Self, toplevel: Shell.ToplevelId) ?*AssignmentSlot {
            for (self.assignments.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.toplevel, toplevel)) return slot;
            return null;
        }
        fn findAssignmentConst(self: *const Self, toplevel: Shell.ToplevelId) ?*const AssignmentSlot {
            for (self.assignments.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.toplevel, toplevel)) return slot;
            return null;
        }
        fn iconName(self: *Self, icon: *IconSlot) []u8 {
            _ = self;
            return icon.name;
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

fn from(comptime T: type, pool: anytype, context: ?*anyopaque) ?*T {
    return pool.fromContext(context);
}

fn indexOf(comptime T: type, pool: anytype, slot: *const T) u32 {
    _ = pool;
    return slot.header.index;
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
    const grown = try adapter.acquireIcon();
    try std.testing.expect(first != grown);
    const generation = first.header.generation;
    adapter.releaseIcon(0);
    const second = try adapter.acquireIcon();
    try std.testing.expect(second.header.generation != generation);
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
    adapter.setName(icon, "name-too-long-for-storage");
    try std.testing.expectEqual(@as(usize, 0), icon.name_len);
    adapter.setName(icon, "ouro");
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
        .header = variant.header,
        .icon_index = 0,
        .icon_generation = icon.header.generation,
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
