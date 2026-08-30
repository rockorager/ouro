//! Bounded ownership and validation for zwp_linux_dmabuf_v1 parameters.
//!
//! The compositor must not advertise DMA-BUF until these retained descriptors
//! can traverse the renderer and the renderer's DRM device is known. It owns
//! the difficult protocol lifetime boundary in isolation: request FDs move
//! from one-shot params into persistent buffers, and are closed exactly once
//! on every cancellation and failure path.

const std = @import("std");
const wayring = @import("wayring");
const linux = std.os.linux;
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");

const none = std.math.maxInt(u32);
pub const max_planes = 4;

pub const drm_format_argb8888: u32 = fourcc('A', 'R', '2', '4');
pub const drm_format_xrgb8888: u32 = fourcc('X', 'R', '2', '4');
pub const modifier_linear: u64 = 0;
pub const modifier_invalid: u64 = (@as(u64, 1) << 56) - 1;

pub const Error = error{
    InvalidConfig,
    Exhausted,
    StaleHandle,
    AlreadyUsed,
    PlaneIndex,
    PlaneSet,
    Incomplete,
    InvalidFormat,
    InvalidDimensions,
    OutOfBounds,
};

pub const Config = struct {
    global_version: u32 = 6,
    feedback_slots: u32 = 8,

    fn validate(config: Config) Error!void {
        if (config.global_version == 0 or config.global_version > 6 or config.feedback_slots == 0)
            return error.InvalidConfig;
    }
};

pub const Handle = struct {
    index: u32,
    generation: u32,
};

pub const Lease = struct {
    index: u32,
    generation: u32,
};

pub const Plane = struct {
    fd: linux.fd_t,
    offset: u32,
    stride: u32,
    modifier: u64,
};

pub const Buffer = struct {
    width: u32,
    height: u32,
    format: u32,
    flags: u32,
    planes: [max_planes]?Plane,
    plane_count: u8,
};

pub const ImportValidator = struct {
    context: *anyopaque,
    validate_fn: *const fn (*anyopaque, *const Buffer) anyerror!void,

    pub fn validate(validator: ImportValidator, buffer: *const Buffer) !void {
        try validator.validate_fn(validator.context, buffer);
    }
};

const ParamsSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    index: u32 = none,
    next_free: u32 = none,
    used: bool = false,
    planes: [max_planes]?Plane = [_]?Plane{null} ** max_planes,
};

const BufferSlot = struct {
    active: bool = false,
    resource_alive: bool = false,
    generation: u32 = 1,
    index: u32 = none,
    next_free: u32 = none,
    leases: usize = 0,
    value: Buffer = undefined,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    params: std.ArrayListUnmanaged(*ParamsSlot) = .empty,
    buffers: std.ArrayListUnmanaged(*BufferSlot) = .empty,
    params_free: u32 = none,
    buffers_free: u32 = none,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Store {
        try config.validate();
        return .{ .allocator = allocator };
    }

    pub fn deinit(store: *Store) void {
        for (store.params.items) |slot| {
            if (slot.active) closePlanes(&slot.planes);
            store.allocator.destroy(slot);
        }
        for (store.buffers.items) |slot| {
            if (slot.active) closePlanes(&slot.value.planes);
            store.allocator.destroy(slot);
        }
        store.buffers.deinit(store.allocator);
        store.params.deinit(store.allocator);
        store.* = undefined;
    }

    pub fn createParams(store: *Store) Error!Handle {
        const slot = try acquireStoreSlot(ParamsSlot, store.allocator, &store.params, &store.params_free);
        const index = slot.index;
        return .{ .index = index, .generation = slot.generation };
    }

    pub fn paramsUsed(store: *Store, handle: Handle) Error!bool {
        return (try store.resolveParams(handle)).used;
    }

    /// Takes ownership of `fd`, including when the request is rejected.
    pub fn addPlane(
        store: *Store,
        handle: Handle,
        fd: linux.fd_t,
        plane_index: u32,
        offset: u32,
        stride: u32,
        modifier: u64,
    ) Error!void {
        errdefer _ = linux.close(fd);
        const slot = try store.resolveParams(handle);
        if (slot.used) return error.AlreadyUsed;
        if (plane_index >= max_planes) return error.PlaneIndex;
        if (slot.planes[plane_index] != null) return error.PlaneSet;
        slot.planes[plane_index] = .{
            .fd = fd,
            .offset = offset,
            .stride = stride,
            .modifier = modifier,
        };
    }

    /// Consumes the params object once. On success, descriptor ownership moves
    /// to the returned persistent buffer; destroying params cannot invalidate
    /// it. Protocol adapters should map validation errors to the corresponding
    /// fatal zwp_linux_buffer_params_v1 error.
    pub fn createBuffer(
        store: *Store,
        handle: Handle,
        width: i32,
        height: i32,
        format: u32,
        flags: u32,
    ) Error!Handle {
        const params = try store.resolveParams(handle);
        if (params.used) return error.AlreadyUsed;
        params.used = true;
        if (width <= 0 or height <= 0) return error.InvalidDimensions;
        if (format != drm_format_argb8888 and format != drm_format_xrgb8888)
            return error.InvalidFormat;
        // Ouro does not yet deinterlace or invert imported content. These
        // layouts must not be accepted until the renderer models them.
        if (flags != 0) return error.InvalidFormat;
        const plane = params.planes[0] orelse return error.Incomplete;
        for (params.planes[1..]) |candidate| if (candidate != null)
            return error.Incomplete;
        if (plane.modifier != modifier_linear and plane.modifier != modifier_invalid)
            return error.InvalidFormat;
        const row_bytes = std.math.mul(u32, @intCast(width), 4) catch
            return error.OutOfBounds;
        if (plane.stride < row_bytes) return error.OutOfBounds;
        const plane_bytes = std.math.mul(u64, plane.stride, @as(u32, @intCast(height))) catch
            return error.OutOfBounds;
        const required_bytes = std.math.add(u64, plane.offset, plane_bytes) catch
            return error.OutOfBounds;
        var descriptor = std.mem.zeroes(linux.Statx);
        const status = linux.statx(plane.fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &descriptor);
        if (linux.errno(status) != .SUCCESS or !descriptor.mask.SIZE or required_bytes > descriptor.size)
            return error.OutOfBounds;
        const slot = try acquireStoreSlot(BufferSlot, store.allocator, &store.buffers, &store.buffers_free);
        const index = slot.index;
        slot.* = .{
            .active = true,
            .resource_alive = true,
            .generation = slot.generation,
            .index = index,
            .value = .{
                .width = @intCast(width),
                .height = @intCast(height),
                .format = format,
                .flags = flags,
                .planes = params.planes,
                .plane_count = 1,
            },
        };
        params.planes = [_]?Plane{null} ** max_planes;
        return .{ .index = index, .generation = slot.generation };
    }

    pub fn buffer(store: *Store, handle: Handle) Error!*const Buffer {
        const slot = try store.resolveBuffer(handle.index, handle.generation);
        if (!slot.resource_alive)
            return error.StaleHandle;
        return &slot.value;
    }

    /// Retains the DMA-BUF independently of its wl_buffer resource. An attached
    /// surface may therefore outlive wl_buffer.destroy without invalidating an
    /// in-flight import or renderer sample.
    pub fn retainBuffer(store: *Store, handle: Handle) Error!Lease {
        const slot = try store.resolveBuffer(handle.index, handle.generation);
        if (!slot.resource_alive) return error.StaleHandle;
        slot.leases = std.math.add(usize, slot.leases, 1) catch return error.Exhausted;
        return .{ .index = handle.index, .generation = handle.generation };
    }

    pub fn leasedBuffer(store: *Store, lease: Lease) Error!*const Buffer {
        const slot = try store.resolveBuffer(lease.index, lease.generation);
        if (slot.leases == 0) return error.StaleHandle;
        return &slot.value;
    }

    pub fn duplicateLease(store: *Store, lease: Lease) Error!Lease {
        const slot = try store.resolveBuffer(lease.index, lease.generation);
        if (!slot.resource_alive or slot.leases == 0) return error.StaleHandle;
        slot.leases = std.math.add(usize, slot.leases, 1) catch return error.Exhausted;
        return lease;
    }

    pub fn bufferAlive(store: *Store, lease: Lease) bool {
        const slot = store.resolveBuffer(lease.index, lease.generation) catch return false;
        return slot.resource_alive;
    }

    pub fn releaseLease(store: *Store, lease: Lease) Error!void {
        const slot = try store.resolveBuffer(lease.index, lease.generation);
        if (slot.leases == 0) return error.StaleHandle;
        slot.leases -= 1;
        if (slot.leases == 0 and !slot.resource_alive)
            store.releaseBufferSlot(lease.index);
    }

    pub fn destroyParams(store: *Store, handle: Handle) Error!void {
        const slot = try store.resolveParams(handle);
        closePlanes(&slot.planes);
        releaseSlot(ParamsSlot, slot, &store.params_free, handle.index);
    }

    pub fn destroyBuffer(store: *Store, handle: Handle) Error!void {
        const slot = try store.resolveBuffer(handle.index, handle.generation);
        if (!slot.resource_alive) return error.StaleHandle;
        slot.resource_alive = false;
        if (slot.leases == 0) store.releaseBufferSlot(handle.index);
    }

    fn resolveParams(store: *Store, handle: Handle) Error!*ParamsSlot {
        if (handle.index >= store.params.items.len) return error.StaleHandle;
        const slot = store.params.items[handle.index];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleHandle;
        return slot;
    }

    fn resolveBuffer(store: *Store, index: u32, generation: u32) Error!*BufferSlot {
        if (index >= store.buffers.items.len) return error.StaleHandle;
        const slot = store.buffers.items[index];
        if (!slot.active or slot.generation != generation) return error.StaleHandle;
        return slot;
    }

    fn releaseBufferSlot(store: *Store, index: u32) void {
        const slot = store.buffers.items[index];
        std.debug.assert(slot.active and !slot.resource_alive and slot.leases == 0);
        closePlanes(&slot.value.planes);
        releaseSlot(BufferSlot, slot, &store.buffers_free, index);
    }
};

/// Bounded wire owner advertising only the formats accepted by Store.
pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Dmabuf = protocol.zwp_linux_dmabuf_v1;
        const Params = protocol.zwp_linux_buffer_params_v1;
        const WlBuffer = protocol.wl_buffer;
        const Feedback = protocol.zwp_linux_dmabuf_feedback_v1;

        const Header = struct {
            active: bool = false,
            generation: u32 = 1,
            index: u32 = none,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const ManagerSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            version: u32 = 0,
            advertisement: u8 = 0,
        };
        const Pending = union(enum) {
            none,
            failed,
            created: u32,
        };
        const ParamsResource = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            state: Handle = undefined,
            sampling_device: ?linux.dev_t = null,
            pending: Pending = .none,
        };
        const BufferResource = struct {
            header: Header = .{},
            state: Handle = undefined,
        };
        const FeedbackResource = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            version: u32 = 4,
            stage: u8 = 0,
        };
        const FormatEntry = extern struct {
            format: u32,
            padding: u32 = 0,
            modifier: u64,
        };
        const format_entries = [_]FormatEntry{
            .{ .format = drm_format_argb8888, .modifier = modifier_linear },
            .{ .format = drm_format_argb8888, .modifier = modifier_invalid },
            .{ .format = drm_format_xrgb8888, .modifier = modifier_linear },
            .{ .format = drm_format_xrgb8888, .modifier = modifier_invalid },
        };
        const format_indices = std.mem.asBytes(&[_]u16{ 0, 1, 2, 3 }).*;

        allocator: std.mem.Allocator,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        store: Store,
        managers: slot_pool.Pool(ManagerSlot),
        params: slot_pool.Pool(ParamsResource),
        buffers: slot_pool.Pool(BufferResource),
        feedback: slot_pool.Pool(FeedbackResource),
        feedback_limit: u32,
        format_table_fd: linux.fd_t,
        device: [@sizeOf(linux.dev_t)]u8 = undefined,
        import_validator: ?ImportValidator = null,
        pending_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Dmabuf.info.validateVersion(config.global_version);
            var store = try Store.init(allocator, config);
            errdefer store.deinit();
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, 4);
            errdefer managers.deinit();
            var params = try slot_pool.Pool(ParamsResource).init(allocator, 8);
            errdefer params.deinit();
            var buffers = try slot_pool.Pool(BufferResource).init(allocator, 16);
            errdefer buffers.deinit();
            var feedback = try slot_pool.Pool(FeedbackResource).init(allocator, config.feedback_slots);
            errdefer feedback.deinit();
            const table_fd = try createFormatTable();
            errdefer _ = linux.close(table_fd);
            return .{
                .allocator = allocator,
                .global_version = config.global_version,
                .store = store,
                .managers = managers,
                .params = params,
                .buffers = buffers,
                .feedback = feedback,
                .feedback_limit = config.feedback_slots,
                .format_table_fd = table_fd,
            };
        }

        pub fn deinit(adapter: *Self) void {
            _ = linux.close(adapter.format_table_fd);
            adapter.store.deinit();
            adapter.feedback.deinit();
            adapter.buffers.deinit();
            adapter.params.deinit();
            adapter.managers.deinit();
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime, device: linux.dev_t) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            @memcpy(&adapter.device, std.mem.asBytes(&device));
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Dmabuf.info,
                adapter.global_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        pub fn setImportValidator(adapter: *Self, validator: ?ImportValidator) void {
            adapter.import_validator = validator;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = adapter.managers.acquire() catch
                return error.OutOfMemory;
            slot.header.resource = binding.resource;
            slot.peer = binding.peer;
            slot.version = binding.version;
            slot.advertisement = if (binding.version >= 4) 4 else 0;
            if (slot.advertisement < 4) adapter.pending_len += 1;
            return slot;
        }

        pub fn request(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            if (target.object.interface != &Dmabuf.info and
                target.object.interface != &Params.info and
                target.object.interface != &WlBuffer.info and
                target.object.interface != &Feedback.info)
                return null;
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
            if (target.object.interface == &Dmabuf.info) {
                const manager = adapter.managers.fromContext(target.object.context) orelse
                    return null;
                if (!std.meta.eql(manager.header.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Dmabuf, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_params => |payload| {
                        const slot = adapter.params.acquire() catch
                            return try adapter.noMemory(actor);
                        slot.peer = manager.peer;
                        slot.state = adapter.store.createParams() catch {
                            adapter.params.release(slot);
                            return try adapter.noMemory(actor);
                        };
                        slot.sampling_device = null;
                        const admitted = Dmabuf.admit_create_params(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .params_id = slot },
                        ) catch |cause| {
                            adapter.store.destroyParams(slot.state) catch unreachable;
                            adapter.params.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.header.resource = admitted.params_id;
                    },
                    .get_default_feedback => |payload| {
                        const slot = adapter.acquireFeedback() catch return try adapter.noMemory(actor);
                        slot.peer = manager.peer;
                        slot.version = manager.version;
                        const admitted = Dmabuf.admit_get_default_feedback(server_objects, decoded.handle, payload, .{ .id = slot }) catch |cause| {
                            adapter.feedback.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.header.resource = admitted.id;
                        adapter.pending_len += 1;
                    },
                    .get_surface_feedback => |payload| {
                        const surface_handle = server_objects.namespace.lookupHandle(payload.surface) orelse
                            return try adapter.failure(actor, decoded.handle.id, error.InvalidSurface);
                        const surface = server_objects.namespace.resolve(surface_handle) orelse
                            return try adapter.failure(actor, decoded.handle.id, error.InvalidSurface);
                        if (surface.interface != &protocol.wl_surface.info)
                            return try adapter.failure(actor, decoded.handle.id, error.InvalidSurface);
                        const slot = adapter.acquireFeedback() catch return try adapter.noMemory(actor);
                        slot.peer = manager.peer;
                        slot.version = manager.version;
                        const admitted = Dmabuf.admit_get_surface_feedback(server_objects, decoded.handle, payload, .{ .id = slot }) catch |cause| {
                            adapter.feedback.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.header.resource = admitted.id;
                        adapter.pending_len += 1;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Params.info) {
                const slot = adapter.params.fromContext(target.object.context) orelse
                    return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try adapter.paramsRequest(actor, server_objects, slot, message, fds);
            }
            if (target.object.interface == &WlBuffer.info) {
                const slot = adapter.buffers.fromContext(target.object.context) orelse
                    return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(WlBuffer, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Feedback.info) {
                const slot = adapter.feedback.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Feedback, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn paramsRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *ParamsResource,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Params, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .add => |payload| {
                    const modifier = (@as(u64, payload.modifier_hi) << 32) | payload.modifier_lo;
                    adapter.store.addPlane(
                        slot.state,
                        payload.fd,
                        payload.plane_idx,
                        payload.offset,
                        payload.stride,
                        modifier,
                    ) catch |cause| return try adapter.paramsError(actor, decoded.handle.id, cause);
                },
                .create => |payload| {
                    const created = adapter.store.createBuffer(
                        slot.state,
                        payload.width,
                        payload.height,
                        payload.format,
                        payload.flags.value,
                    ) catch |cause| switch (cause) {
                        error.Exhausted => {
                            slot.pending = .failed;
                            adapter.pending_len += 1;
                            try decoded.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        },
                        else => return try adapter.paramsError(actor, decoded.handle.id, cause),
                    };
                    adapter.validateCreated(slot, created) catch {
                        adapter.store.destroyBuffer(created) catch unreachable;
                        slot.pending = .failed;
                        adapter.pending_len += 1;
                        try decoded.finish(protocol, server_objects, &actor.transmit);
                        return .continue_dispatch;
                    };
                    const buffer = adapter.buffers.acquire() catch {
                        adapter.store.destroyBuffer(created) catch unreachable;
                        slot.pending = .failed;
                        adapter.pending_len += 1;
                        try decoded.finish(protocol, server_objects, &actor.transmit);
                        return .continue_dispatch;
                    };
                    buffer.state = created;
                    slot.pending = .{ .created = buffer.header.index };
                    adapter.pending_len += 1;
                },
                .create_immed => |payload| {
                    const created = adapter.store.createBuffer(
                        slot.state,
                        payload.width,
                        payload.height,
                        payload.format,
                        payload.flags.value,
                    ) catch |cause| return try adapter.paramsError(actor, decoded.handle.id, if (cause == error.Exhausted)
                        error.InvalidWlBuffer
                    else
                        cause);
                    adapter.validateCreated(slot, created) catch {
                        adapter.store.destroyBuffer(created) catch unreachable;
                        return try adapter.paramsError(actor, decoded.handle.id, error.InvalidWlBuffer);
                    };
                    const buffer = adapter.buffers.acquire() catch {
                        adapter.store.destroyBuffer(created) catch unreachable;
                        return try adapter.paramsError(actor, decoded.handle.id, error.InvalidWlBuffer);
                    };
                    buffer.state = created;
                    const admitted = Params.admit_create_immed(
                        server_objects,
                        decoded.handle,
                        payload,
                        .{ .buffer_id = buffer },
                    ) catch |cause| {
                        adapter.store.destroyBuffer(created) catch unreachable;
                        adapter.buffers.release(buffer);
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    buffer.header.resource = admitted.buffer_id;
                },
                .set_sampling_device => |payload| {
                    if (payload.device.len != @sizeOf(linux.dev_t))
                        return try adapter.paramsError(actor, decoded.handle.id, error.InvalidDeviceSize);
                    if (try adapter.store.paramsUsed(slot.state))
                        return try adapter.paramsError(actor, decoded.handle.id, error.AlreadyUsed);
                    var device: linux.dev_t = undefined;
                    @memcpy(std.mem.asBytes(&device), payload.device);
                    slot.sampling_device = device;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn validateCreated(adapter: *Self, slot: *const ParamsResource, handle: Handle) !void {
            if (slot.sampling_device) |device|
                if (!std.mem.eql(u8, std.mem.asBytes(&device), &adapter.device))
                    return error.UnsupportedSamplingDevice;
            const validator = adapter.import_validator orelse return;
            try validator.validate(try adapter.store.buffer(handle));
        }

        pub fn flushOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (adapter.pending_len == 0) return completed;
            for (adapter.managers.entries.items) |manager| {
                if (!manager.header.active or !samePeer(manager.peer, peer)) continue;
                if (manager.advertisement >= 4) continue;
                while (manager.advertisement < 4) {
                    const format = if (manager.advertisement / 2 == 0)
                        drm_format_argb8888
                    else
                        drm_format_xrgb8888;
                    const modifier = if (manager.advertisement % 2 == 0)
                        modifier_linear
                    else
                        modifier_invalid;
                    var emitted = true;
                    if (manager.version >= 3) {
                        Dmabuf.encodeEvent(queue, manager.header.resource.id, .{ .modifier = .{
                            .format = format,
                            .modifier_hi = @intCast(modifier >> 32),
                            .modifier_lo = @truncate(modifier),
                        } }) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                            else => return err,
                        };
                    } else if (manager.advertisement % 2 == 0) {
                        Dmabuf.encodeEvent(queue, manager.header.resource.id, .{ .format = .{
                            .format = format,
                        } }) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                            else => return err,
                        };
                    } else {
                        emitted = false;
                    }
                    manager.advertisement += 1;
                    completed += @intFromBool(emitted);
                }
                adapter.pending_len -= 1;
            }
            for (adapter.params.entries.items) |slot| {
                if (!slot.header.active or !samePeer(slot.peer, peer)) continue;
                switch (slot.pending) {
                    .none => {},
                    .failed => {
                        wayring.server.sendEvent(
                            protocol,
                            Params,
                            server_objects,
                            queue,
                            slot.header.resource,
                            .{ .failed = .{} },
                        ) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                            else => return err,
                        };
                        slot.pending = .none;
                        adapter.pending_len -= 1;
                        completed += 1;
                    },
                    .created => |buffer_index| {
                        const buffer = adapter.buffers.at(buffer_index) orelse unreachable;
                        const admitted = Params.construct_event_created(
                            protocol,
                            server_objects,
                            queue,
                            slot.header.resource,
                            .{ .buffer = .{ .context = buffer } },
                        ) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                            else => return err,
                        };
                        buffer.header.resource = admitted.buffer;
                        slot.pending = .none;
                        adapter.pending_len -= 1;
                        completed += 1;
                    },
                }
            }
            for (adapter.feedback.entries.items) |slot| {
                if (!slot.header.active or !samePeer(slot.peer, peer)) continue;
                const stage_count = feedbackStageCount(slot.version);
                while (slot.stage < stage_count) {
                    const event: Feedback.Event = if (slot.version >= 6) switch (slot.stage) {
                        0 => {
                            const duplicated = linux.fcntl(adapter.format_table_fd, linux.F.DUPFD_CLOEXEC, 0);
                            if (linux.errno(duplicated) != .SUCCESS) return error.SystemCallFailed;
                            const fd: linux.fd_t = @intCast(duplicated);
                            Feedback.encodeEvent(queue, slot.header.resource.id, .{ .format_table = .{ .fd = fd, .size = @sizeOf(@TypeOf(format_entries)) } }) catch |err| {
                                _ = linux.close(fd);
                                switch (err) {
                                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                                    else => return err,
                                }
                            };
                            slot.stage += 1;
                            completed += 1;
                            continue;
                        },
                        1 => .{ .tranche_target_device = .{ .device = &adapter.device } },
                        2 => .{ .tranche_flags = .{ .flags = Feedback.tranche_flags.sampling } },
                        3 => .{ .tranche_formats = .{ .indices = &format_indices } },
                        4 => .{ .tranche_done = .{} },
                        5 => .{ .done = .{} },
                        else => unreachable,
                    } else switch (slot.stage) {
                        0 => {
                            const duplicated = linux.fcntl(adapter.format_table_fd, linux.F.DUPFD_CLOEXEC, 0);
                            if (linux.errno(duplicated) != .SUCCESS) return error.SystemCallFailed;
                            const fd: linux.fd_t = @intCast(duplicated);
                            Feedback.encodeEvent(queue, slot.header.resource.id, .{ .format_table = .{ .fd = fd, .size = @sizeOf(@TypeOf(format_entries)) } }) catch |err| {
                                _ = linux.close(fd);
                                switch (err) {
                                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                                    else => return err,
                                }
                            };
                            slot.stage += 1;
                            completed += 1;
                            continue;
                        },
                        1 => .{ .main_device = .{ .device = &adapter.device } },
                        2 => .{ .tranche_target_device = .{ .device = &adapter.device } },
                        3 => .{ .tranche_flags = .{ .flags = .{ .value = 0 } } },
                        4 => .{ .tranche_formats = .{ .indices = &format_indices } },
                        5 => .{ .tranche_done = .{} },
                        6 => .{ .done = .{} },
                        else => unreachable,
                    };
                    Feedback.encodeEvent(queue, slot.header.resource.id, event) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    };
                    slot.stage += 1;
                    completed += 1;
                }
                adapter.pending_len -= 1;
            }
            return completed;
        }

        pub fn pendingOutbound(adapter: *const Self, peer: wayring.io_uring.Peer) bool {
            if (adapter.pending_len == 0) return false;
            for (adapter.managers.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and slot.advertisement < 4)
                    return true;
            for (adapter.params.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and slot.pending != .none)
                    return true;
            for (adapter.feedback.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and
                    slot.stage < feedbackStageCount(slot.version))
                    return true;
            return false;
        }

        pub fn bufferFromObject(adapter: *Self, object: *const objects.Object) ?Handle {
            if (object.interface != &WlBuffer.info) return null;
            const slot = adapter.buffers.fromContext(object.context) orelse return null;
            return slot.state;
        }

        pub fn retainBuffer(adapter: *Self, handle: Handle) Error!Lease {
            return adapter.store.retainBuffer(handle);
        }

        pub fn leasedBuffer(adapter: *Self, lease: Lease) Error!*const Buffer {
            return adapter.store.leasedBuffer(lease);
        }

        pub fn duplicateLease(adapter: *Self, lease: Lease) Error!Lease {
            return adapter.store.duplicateLease(lease);
        }

        pub fn releaseLease(adapter: *Self, lease: Lease) Error!void {
            try adapter.store.releaseLease(lease);
        }

        pub fn externalImporter(adapter: *Self, comptime CoreSurface: type) CoreSurface.ExternalImporter {
            const Bridge = struct {
                fn acquire(
                    context: *anyopaque,
                    object: *const objects.Object,
                ) !?CoreSurface.ExternalBuffer {
                    const owner: *Self = @ptrCast(@alignCast(context));
                    const handle = owner.bufferFromObject(object) orelse return null;
                    const lease = try owner.store.retainBuffer(handle);
                    errdefer owner.store.releaseLease(lease) catch unreachable;
                    const value = try owner.store.leasedBuffer(lease);
                    var result: CoreSurface.ExternalBuffer = .{
                        .context = owner,
                        .token = encodeLease(lease),
                        .alive_fn = @This().alive,
                        .width = value.width,
                        .height = value.height,
                        .format = value.format,
                        .modifier = value.planes[0].?.modifier,
                        .plane_count = value.plane_count,
                        .release_fn = @This().release,
                    };
                    for (0..value.plane_count) |plane_index| {
                        const plane = value.planes[plane_index].?;
                        result.fds[plane_index] = plane.fd;
                        result.strides[plane_index] = plane.stride;
                        result.offsets[plane_index] = plane.offset;
                    }
                    return result;
                }

                fn release(context: *anyopaque, token: u64) void {
                    const owner: *Self = @ptrCast(@alignCast(context));
                    owner.store.releaseLease(decodeLease(token)) catch unreachable;
                }

                fn alive(context: *anyopaque, token: u64) bool {
                    const owner: *Self = @ptrCast(@alignCast(context));
                    return owner.store.bufferAlive(decodeLease(token));
                }
            };
            return .{ .context = adapter, .acquire_fn = Bridge.acquire };
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Dmabuf.info) {
                const slot = adapter.managers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                if (slot.advertisement < 4) adapter.pending_len -= 1;
                adapter.managers.release(slot);
                return true;
            }
            if (object.interface == &Params.info) {
                const slot = adapter.params.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                if (slot.pending != .none) adapter.pending_len -= 1;
                if (slot.pending == .created) {
                    const buffer_index = slot.pending.created;
                    const buffer = adapter.buffers.at(buffer_index) orelse unreachable;
                    adapter.store.destroyBuffer(buffer.state) catch unreachable;
                    adapter.buffers.release(buffer);
                }
                adapter.store.destroyParams(slot.state) catch unreachable;
                adapter.params.release(slot);
                return true;
            }
            if (object.interface == &WlBuffer.info) {
                const slot = adapter.buffers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.store.destroyBuffer(slot.state) catch unreachable;
                adapter.buffers.release(slot);
                return true;
            }
            if (object.interface == &Feedback.info) {
                const slot = adapter.feedback.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                if (slot.stage < feedbackStageCount(slot.version)) adapter.pending_len -= 1;
                adapter.feedback.release(slot);
                return true;
            }
            return false;
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn paramsError(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            const code = switch (cause) {
                error.AlreadyUsed => Params.@"error".already_used.value,
                error.PlaneIndex => Params.@"error".plane_idx.value,
                error.PlaneSet => Params.@"error".plane_set.value,
                error.Incomplete => Params.@"error".incomplete.value,
                error.InvalidFormat => Params.@"error".invalid_format.value,
                error.InvalidDimensions => Params.@"error".invalid_dimensions.value,
                error.OutOfBounds => Params.@"error".out_of_bounds.value,
                error.InvalidWlBuffer => Params.@"error".invalid_wl_buffer.value,
                error.InvalidDeviceSize => Params.@"error".invalid_dev_t_size.value,
                else => Params.@"error".invalid_wl_buffer.value,
            };
            _ = adapter;
            try ProtocolCore.postError(actor, id, code, @errorName(cause));
            return .stop;
        }

        fn failure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return adapter.paramsError(actor, id, cause);
        }

        fn acquireFeedback(adapter: *Self) !*FeedbackResource {
            if (adapter.feedback.free_head == slot_pool.none and
                adapter.feedback.entries.items.len >= adapter.feedback_limit)
                return error.OutOfMemory;
            const slot = try adapter.feedback.acquire();
            slot.stage = 0;
            return slot;
        }

        fn feedbackStageCount(version: u32) u8 {
            return if (version >= 6) 6 else 7;
        }

        fn createFormatTable() !linux.fd_t {
            const result = linux.memfd_create(
                "ouro-dmabuf-formats",
                linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING,
            );
            if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
            const fd: linux.fd_t = @intCast(result);
            errdefer _ = linux.close(fd);
            const bytes = std.mem.asBytes(&format_entries);
            var offset: usize = 0;
            while (offset < bytes.len) {
                const written = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
                switch (linux.errno(written)) {
                    .SUCCESS => {
                        if (written == 0) return error.SystemCallFailed;
                        offset += written;
                    },
                    .INTR => continue,
                    else => return error.SystemCallFailed,
                }
            }
            const sealed = linux.fcntl(
                fd,
                linux.F.ADD_SEALS,
                linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_WRITE | linux.F.SEAL_SEAL,
            );
            if (linux.errno(sealed) != .SUCCESS) return error.SystemCallFailed;
            return fd;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn encodeLease(lease: Lease) u64 {
    return (@as(u64, lease.generation) << 32) | lease.index;
}

fn decodeLease(token: u64) Lease {
    return .{ .index = @truncate(token), .generation = @truncate(token >> 32) };
}

fn acquireStoreSlot(
    comptime T: type,
    allocator: std.mem.Allocator,
    slots: *std.ArrayListUnmanaged(*T),
    free_head: *u32,
) Error!*T {
    if (free_head.* != none) {
        const slot = slots.items[free_head.*];
        free_head.* = slot.next_free;
        slot.* = .{
            .active = true,
            .generation = slot.generation,
            .index = slot.index,
        };
        return slot;
    }
    if (slots.items.len >= none) return error.Exhausted;
    const slot = allocator.create(T) catch return error.Exhausted;
    errdefer allocator.destroy(slot);
    const index: u32 = @intCast(slots.items.len);
    slot.* = .{ .active = true, .index = index };
    slots.append(allocator, slot) catch return error.Exhausted;
    return slot;
}

fn releaseSlot(comptime T: type, slot: *T, free_head: *u32, index: u32) void {
    std.debug.assert(slot.index == index);
    slot.active = false;
    slot.generation +%= 1;
    if (slot.generation == 0) slot.generation = 1;
    slot.next_free = free_head.*;
    free_head.* = index;
}

fn closePlanes(planes: *[max_planes]?Plane) void {
    for (planes) |*plane| if (plane.*) |value| {
        _ = linux.close(value.fd);
        plane.* = null;
    };
}

fn fourcc(a: u8, b: u8, c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, c) << 16) | (@as(u32, d) << 24);
}

fn eventFd() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    return @intCast(result);
}

fn sizedFd(size: usize) !linux.fd_t {
    const result = linux.memfd_create("ouro-dmabuf-test", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    return fd;
}

fn expectClosed(fd: linux.fd_t) !void {
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}

test "linux-dmabuf: generated wire adapter is complete" {
    const TestAdapter = Adapter(@import("core_protocol"));
    std.testing.refAllDecls(TestAdapter);
    var adapter = try TestAdapter.init(std.testing.allocator, .{});
    adapter.deinit();
}

test "linux-dmabuf: sampling device gates renderer import" {
    const TestAdapter = Adapter(@import("core_protocol"));
    const Gate = struct {
        calls: usize = 0,

        fn validate(context: *anyopaque, _: *const Buffer) !void {
            const gate: *@This() = @ptrCast(@alignCast(context));
            gate.calls += 1;
        }
    };

    var adapter = try TestAdapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    var gate: Gate = .{};
    adapter.setImportValidator(.{ .context = &gate, .validate_fn = Gate.validate });
    const device: linux.dev_t = 0x1234;
    @memcpy(&adapter.device, std.mem.asBytes(&device));

    const params = try adapter.params.acquire();
    params.state = try adapter.store.createParams();
    const fd = try sizedFd(4);
    try adapter.store.addPlane(params.state, fd, 0, 0, 4, modifier_linear);
    const buffer = try adapter.store.createBuffer(params.state, 1, 1, drm_format_argb8888, 0);

    params.sampling_device = 0x5678;
    try std.testing.expectError(
        error.UnsupportedSamplingDevice,
        adapter.validateCreated(params, buffer),
    );
    try std.testing.expectEqual(@as(usize, 0), gate.calls);
    params.sampling_device = device;
    try adapter.validateCreated(params, buffer);
    try std.testing.expectEqual(@as(usize, 1), gate.calls);

    try adapter.store.destroyBuffer(buffer);
    try adapter.store.destroyParams(params.state);
    adapter.params.release(params);
    try expectClosed(fd);
}

test "linux-dmabuf: resource and descriptor stores grow without moving live entries" {
    const TestAdapter = Adapter(@import("core_protocol"));
    var adapter = try TestAdapter.init(std.testing.allocator, .{});
    defer adapter.deinit();

    const first_manager = try adapter.managers.acquire();
    const first_address = @intFromPtr(first_manager);
    for (0..31) |_| _ = try adapter.managers.acquire();
    try std.testing.expectEqual(first_address, @intFromPtr(first_manager));
    try std.testing.expect(adapter.managers.fromContext(first_manager) == first_manager);

    var params: [32]Handle = undefined;
    var buffers: [32]Handle = undefined;
    for (&params, &buffers) |*params_handle, *buffer_handle| {
        params_handle.* = try adapter.store.createParams();
        const fd = try sizedFd(4);
        try adapter.store.addPlane(params_handle.*, fd, 0, 0, 4, modifier_linear);
        buffer_handle.* = try adapter.store.createBuffer(
            params_handle.*,
            1,
            1,
            drm_format_argb8888,
            0,
        );
    }
    const first_buffer = try adapter.store.buffer(buffers[0]);
    for (params) |handle| try adapter.store.destroyParams(handle);
    try std.testing.expect(first_buffer == try adapter.store.buffer(buffers[0]));
    for (buffers) |handle| try adapter.store.destroyBuffer(handle);
}

test "linux-dmabuf: legacy advertisements survive transmit backpressure" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol);
    var adapter = try TestAdapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 7 };
    const manager = try adapter.managers.acquire();
    adapter.pending_len += 1;
    manager.peer = peer;
    manager.version = 3;
    manager.header.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_linux_dmabuf_v1.info,
        3,
        manager,
    );

    var blocked = wayring.tx.Queue.init(&blocks, 16, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.flushOn(peer, &server_objects, &blocked),
    );
    try std.testing.expect(adapter.pendingOutbound(peer));

    var output = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 4),
        try adapter.flushOn(peer, &server_objects, &output),
    );
    try std.testing.expect(!adapter.pendingOutbound(peer));
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    var bytes = snapshot.first;
    const expected = [_]struct { format: u32, modifier: u64 }{
        .{ .format = drm_format_argb8888, .modifier = modifier_linear },
        .{ .format = drm_format_argb8888, .modifier = modifier_invalid },
        .{ .format = drm_format_xrgb8888, .modifier = modifier_linear },
        .{ .format = drm_format_xrgb8888, .modifier = modifier_invalid },
    };
    for (expected) |pair| {
        const message = (try wayring.wire.Message.decode(bytes)).?;
        const event = try protocol.zwp_linux_dmabuf_v1.decodeEvent(message, &fds);
        try std.testing.expectEqual(protocol.zwp_linux_dmabuf_v1.Event.modifier, std.meta.activeTag(event));
        try std.testing.expectEqual(pair.format, event.modifier.format);
        const modifier = (@as(u64, event.modifier.modifier_hi) << 32) |
            event.modifier.modifier_lo;
        try std.testing.expectEqual(pair.modifier, modifier);
        bytes = bytes[message.header.size..];
    }
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "linux-dmabuf: version 6 feedback resumes with sampling tranche and no main device" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol);
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .feedback_slots = 1 });
    defer adapter.deinit();
    const device: linux.dev_t = 0x1234;
    @memcpy(&adapter.device, std.mem.asBytes(&device));
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
    defer descriptors.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 9, .generation = 3 };
    const feedback = try adapter.acquireFeedback();
    feedback.peer = peer;
    feedback.version = 6;
    feedback.header.resource = try server_objects.insertClient(
        7,
        &protocol.zwp_linux_dmabuf_feedback_v1.info,
        1,
        feedback,
    );
    adapter.pending_len += 1;
    try std.testing.expectError(error.OutOfMemory, adapter.acquireFeedback());

    var blocked = wayring.tx.Queue.init(&blocks, 8, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(peer, &server_objects, &blocked));
    try std.testing.expect(adapter.pendingOutbound(peer));
    try std.testing.expectEqual(@as(u8, 0), feedback.stage);

    var output = wayring.tx.Queue.init(&blocks, 512, &descriptors, 1);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 6), try adapter.flushOn(peer, &server_objects, &output));
    try std.testing.expect(!adapter.pendingOutbound(peer));
    var descriptor_scratch: [2]linux.fd_t = undefined;
    var control: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 1);
    defer fds.deinit();
    const duplicated = linux.fcntl(descriptor_scratch[0], linux.F.DUPFD_CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(duplicated));
    try fds.append(@intCast(duplicated));
    var bytes = snapshot.first;
    const tags = [_]std.meta.Tag(protocol.zwp_linux_dmabuf_feedback_v1.Event){
        .format_table,
        .tranche_target_device,
        .tranche_flags,
        .tranche_formats,
        .tranche_done,
        .done,
    };
    for (tags, 0..) |tag, index| {
        const message = (try wayring.wire.Message.decode(bytes)).?;
        const event = try protocol.zwp_linux_dmabuf_feedback_v1.decodeEvent(message, &fds);
        try std.testing.expectEqual(tag, std.meta.activeTag(event));
        if (index == 0) {
            try std.testing.expectEqual(@as(u32, 64), event.format_table.size);
            var table: [64]u8 = undefined;
            const read = linux.pread(event.format_table.fd, &table, table.len, 0);
            try std.testing.expectEqual(table.len, read);
            try std.testing.expectEqualSlices(u8, std.mem.asBytes(&TestAdapter.format_entries), &table);
            _ = linux.close(event.format_table.fd);
        } else if (index == 1) {
            try std.testing.expectEqualSlices(u8, std.mem.asBytes(&device), event.tranche_target_device.device);
        } else if (index == 2) {
            try std.testing.expectEqual(
                protocol.zwp_linux_dmabuf_feedback_v1.tranche_flags.sampling.value,
                event.tranche_flags.flags.value,
            );
        } else if (index == 3) {
            try std.testing.expectEqualSlices(u8, &TestAdapter.format_indices, event.tranche_formats.indices);
        }
        bytes = bytes[message.header.size..];
    }
    try std.testing.expectEqual(@as(usize, 0), bytes.len);

    const object = server_objects.namespace.resolve(feedback.header.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(feedback.header.resource, object));
    const reused = try adapter.acquireFeedback();
    try std.testing.expect(reused == feedback);
    adapter.feedback.release(reused);
}

test "linux-dmabuf: async created event retains buffer across params teardown" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol);
    var adapter = try TestAdapter.init(std.testing.allocator, .{});
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 8 };

    const params = try adapter.params.acquire();
    params.peer = peer;
    params.state = try adapter.store.createParams();
    params.header.resource = try server_objects.insertClient(
        5,
        &protocol.zwp_linux_buffer_params_v1.info,
        3,
        params,
    );
    const fd = try sizedFd(4);
    try adapter.store.addPlane(params.state, fd, 0, 0, 4, modifier_linear);
    const state = try adapter.store.createBuffer(
        params.state,
        1,
        1,
        drm_format_argb8888,
        0,
    );
    const buffer = try adapter.buffers.acquire();
    buffer.state = state;
    params.pending = .{ .created = buffer.header.index };
    adapter.pending_len += 1;

    var blocked = wayring.tx.Queue.init(&blocks, 8, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.flushOn(peer, &server_objects, &blocked),
    );
    try std.testing.expect(adapter.pendingOutbound(peer));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));

    var output = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(peer, &server_objects, &output),
    );
    try std.testing.expect(!adapter.pendingOutbound(peer));
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try protocol.zwp_linux_buffer_params_v1.decodeEvent(message, &fds);
    try std.testing.expectEqual(
        protocol.zwp_linux_buffer_params_v1.Event.created,
        std.meta.activeTag(event),
    );
    try std.testing.expectEqual(buffer.header.resource.id, event.created.buffer);

    const CoreSurface = @import("core_surface.zig").Adapter(protocol);
    const importer = adapter.externalImporter(CoreSurface);
    const live_buffer_object = server_objects.namespace.resolve(buffer.header.resource).?.*;
    const external = (try importer.acquire_fn(importer.context, &live_buffer_object)).?;
    try std.testing.expectEqual(@as(u64, modifier_linear), external.modifier);
    try std.testing.expectEqual(fd, external.fds[0]);

    const params_object = server_objects.namespace.resolve(params.header.resource).?.*;
    try std.testing.expect(adapter.resourceRemoved(params.header.resource, params_object));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expect(adapter.resourceRemoved(buffer.header.resource, live_buffer_object));
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    external.release_fn(external.context, external.token);
    try expectClosed(fd);
}

test "linux-dmabuf: params transfer descriptor ownership to persistent buffer" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const params = try store.createParams();
    const fd = try sizedFd(8192);
    try store.addPlane(params, fd, 0, 0, 256, modifier_linear);
    const created = try store.createBuffer(params, 64, 32, drm_format_xrgb8888, 0);
    try store.destroyParams(params);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    const info = try store.buffer(created);
    try std.testing.expectEqual(@as(u32, 64), info.width);
    try std.testing.expectEqual(fd, info.planes[0].?.fd);
    try store.destroyBuffer(created);
    try expectClosed(fd);
}

test "linux-dmabuf: retained attachment outlives destroyed buffer resource" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const params = try store.createParams();
    const fd = try sizedFd(4);
    try store.addPlane(params, fd, 0, 0, 4, modifier_linear);
    const created = try store.createBuffer(params, 1, 1, drm_format_argb8888, 0);
    const lease = try store.retainBuffer(created);
    const duplicate = try store.duplicateLease(lease);
    try std.testing.expectEqual(lease, duplicate);
    try std.testing.expect(store.bufferAlive(lease));
    try store.destroyBuffer(created);
    try std.testing.expect(!store.bufferAlive(lease));
    try std.testing.expectError(error.StaleHandle, store.duplicateLease(lease));
    try std.testing.expectError(error.StaleHandle, store.buffer(created));
    try std.testing.expectEqual(fd, (try store.leasedBuffer(lease)).planes[0].?.fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try store.releaseLease(lease);
    try std.testing.expectEqual(fd, (try store.leasedBuffer(duplicate)).planes[0].?.fd);
    try store.releaseLease(duplicate);
    try expectClosed(fd);
    try std.testing.expectError(error.StaleHandle, store.leasedBuffer(lease));
    try store.destroyParams(params);
}

test "linux-dmabuf: rejected and canceled params close every received descriptor" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const params = try store.createParams();
    const retained = try eventFd();
    try store.addPlane(params, retained, 0, 0, 4, modifier_linear);
    const duplicate = try eventFd();
    try std.testing.expectError(
        error.PlaneSet,
        store.addPlane(params, duplicate, 0, 0, 4, modifier_linear),
    );
    try expectClosed(duplicate);
    try store.destroyParams(params);
    try expectClosed(retained);
}

test "linux-dmabuf: one-shot validation is generation safe" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();
    const first = try store.createParams();
    const fd = try eventFd();
    try store.addPlane(first, fd, 0, 0, 3, modifier_linear);
    try std.testing.expectError(
        error.OutOfBounds,
        store.createBuffer(first, 1, 1, drm_format_argb8888, 0),
    );
    try std.testing.expectError(
        error.AlreadyUsed,
        store.createBuffer(first, 1, 1, drm_format_argb8888, 0),
    );
    try store.destroyParams(first);
    try expectClosed(fd);

    const second = try store.createParams();
    try std.testing.expectError(error.StaleHandle, store.destroyParams(first));
    try store.destroyParams(second);
}

test "linux-dmabuf: buffer extent includes offset and final row" {
    var store = try Store.init(std.testing.allocator, .{});
    defer store.deinit();

    const truncated = try store.createParams();
    const truncated_fd = try sizedFd(15);
    try store.addPlane(truncated, truncated_fd, 0, 0, 8, modifier_linear);
    try std.testing.expectError(
        error.OutOfBounds,
        store.createBuffer(truncated, 1, 2, drm_format_argb8888, 0),
    );
    try store.destroyParams(truncated);
    try expectClosed(truncated_fd);

    const exact = try store.createParams();
    const exact_fd = try sizedFd(17);
    try store.addPlane(exact, exact_fd, 0, 1, 8, modifier_linear);
    const buffer = try store.createBuffer(exact, 1, 2, drm_format_argb8888, 0);
    try store.destroyParams(exact);
    try store.destroyBuffer(buffer);
    try expectClosed(exact_fd);
}
