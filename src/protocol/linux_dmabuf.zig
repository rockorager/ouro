//! Bounded ownership and validation for zwp_linux_dmabuf_v1 parameters.
//!
//! This module deliberately does not install the protocol global yet. The
//! compositor must not advertise DMA-BUF until these retained descriptors can
//! traverse the renderer. It owns the difficult protocol lifetime boundary in
//! isolation: request FDs move from one-shot params into persistent buffers,
//! and are closed exactly once on every cancellation and failure path.

const std = @import("std");
const linux = std.os.linux;

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
    params_capacity: usize = 16,
    buffer_capacity: usize = 16,

    fn validate(config: Config) Error!void {
        if (config.params_capacity == 0 or config.params_capacity >= none or
            config.buffer_capacity == 0 or config.buffer_capacity >= none)
            return error.InvalidConfig;
    }
};

pub const Handle = struct {
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

const ParamsSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    next_free: u32 = none,
    used: bool = false,
    planes: [max_planes]?Plane = [_]?Plane{null} ** max_planes,
};

const BufferSlot = struct {
    active: bool = false,
    generation: u32 = 1,
    next_free: u32 = none,
    value: Buffer = undefined,
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    params: []ParamsSlot,
    buffers: []BufferSlot,
    params_free: u32,
    buffers_free: u32,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Store {
        try config.validate();
        const params = allocator.alloc(ParamsSlot, config.params_capacity) catch
            return error.Exhausted;
        errdefer allocator.free(params);
        const buffers = allocator.alloc(BufferSlot, config.buffer_capacity) catch
            return error.Exhausted;
        for (params, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < params.len) @intCast(index + 1) else none,
        };
        for (buffers, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < buffers.len) @intCast(index + 1) else none,
        };
        return .{
            .allocator = allocator,
            .params = params,
            .buffers = buffers,
            .params_free = 0,
            .buffers_free = 0,
        };
    }

    pub fn deinit(store: *Store) void {
        for (store.params) |*slot| if (slot.active) closePlanes(&slot.planes);
        for (store.buffers) |*slot| if (slot.active) closePlanes(&slot.value.planes);
        store.allocator.free(store.buffers);
        store.allocator.free(store.params);
        store.* = undefined;
    }

    pub fn createParams(store: *Store) Error!Handle {
        if (store.params_free == none) return error.Exhausted;
        const index = store.params_free;
        const slot = &store.params[index];
        store.params_free = slot.next_free;
        slot.* = .{ .active = true, .generation = slot.generation };
        return .{ .index = index, .generation = slot.generation };
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
        const last_row = std.math.mul(u64, plane.stride, @as(u32, @intCast(height - 1))) catch
            return error.OutOfBounds;
        const end = std.math.add(u64, plane.offset, last_row) catch
            return error.OutOfBounds;
        _ = std.math.add(u64, end, row_bytes) catch return error.OutOfBounds;
        if (store.buffers_free == none) return error.Exhausted;

        const index = store.buffers_free;
        const slot = &store.buffers[index];
        store.buffers_free = slot.next_free;
        slot.* = .{
            .active = true,
            .generation = slot.generation,
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
        if (handle.index >= store.buffers.len) return error.StaleHandle;
        const slot = &store.buffers[handle.index];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleHandle;
        return &slot.value;
    }

    pub fn destroyParams(store: *Store, handle: Handle) Error!void {
        const slot = try store.resolveParams(handle);
        closePlanes(&slot.planes);
        releaseSlot(ParamsSlot, slot, &store.params_free, handle.index);
    }

    pub fn destroyBuffer(store: *Store, handle: Handle) Error!void {
        if (handle.index >= store.buffers.len) return error.StaleHandle;
        const slot = &store.buffers[handle.index];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleHandle;
        closePlanes(&slot.value.planes);
        releaseSlot(BufferSlot, slot, &store.buffers_free, handle.index);
    }

    fn resolveParams(store: *Store, handle: Handle) Error!*ParamsSlot {
        if (handle.index >= store.params.len) return error.StaleHandle;
        const slot = &store.params[handle.index];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleHandle;
        return slot;
    }
};

fn releaseSlot(comptime T: type, slot: *T, free_head: *u32, index: u32) void {
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

fn expectClosed(fd: linux.fd_t) !void {
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}

test "linux-dmabuf: params transfer descriptor ownership to persistent buffer" {
    var store = try Store.init(std.testing.allocator, .{ .params_capacity = 1, .buffer_capacity = 1 });
    defer store.deinit();
    const params = try store.createParams();
    const fd = try eventFd();
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

test "linux-dmabuf: rejected and canceled params close every received descriptor" {
    var store = try Store.init(std.testing.allocator, .{ .params_capacity = 1, .buffer_capacity = 1 });
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
    var store = try Store.init(std.testing.allocator, .{ .params_capacity = 1, .buffer_capacity = 1 });
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
