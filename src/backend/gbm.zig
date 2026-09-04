//! Narrow, replaceable GBM boundary. Devices borrow their DRM FD: this module
//! never closes or duplicates it, and all BO metadata crossing the boundary is
//! copied into fixed-size Ouro records.

const std = @import("std");

const c = @cImport({
    @cInclude("gbm.h");
    @cInclude("drm_fourcc.h");
});

pub const max_planes = 4;
pub const modifier_linear: u64 = 0;
pub const modifier_invalid: u64 = (@as(u64, 1) << 56) - 1;
pub const format_xrgb8888: u32 = fourcc('X', 'R', '2', '4');
pub const format_argb8888: u32 = fourcc('A', 'R', '2', '4');
pub const format_xbgr8888: u32 = fourcc('X', 'B', '2', '4');
pub const format_abgr8888: u32 = fourcc('A', 'B', '2', '4');
pub const format_xrgb2101010: u32 = fourcc('X', 'R', '3', '0');

pub const FormatModifier = struct {
    fourcc: u32,
    modifier: u64,
};

fn fourcc(a: u8, b: u8, value_c: u8, d: u8) u32 {
    return @as(u32, a) | (@as(u32, b) << 8) | (@as(u32, value_c) << 16) |
        (@as(u32, d) << 24);
}

pub const Device = *anyopaque;
pub const Bo = *anyopaque;
pub const MapToken = *anyopaque;

pub const Allocation = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    explicit_modifier: bool,
};

pub const Import = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    plane_count: u8,
    fds: [max_planes]std.posix.fd_t = [_]std.posix.fd_t{-1} ** max_planes,
    strides: [max_planes]u32 = [_]u32{0} ** max_planes,
    offsets: [max_planes]u32 = [_]u32{0} ** max_planes,
};

pub const MapAccess = enum { read, write };
pub const ImportUsage = enum { rendering, scanout };

pub const Metadata = struct {
    width: u32,
    height: u32,
    format: u32,
    modifier: u64,
    plane_count: u8,
    handles: [max_planes]u32 = [_]u32{0} ** max_planes,
    strides: [max_planes]u32 = [_]u32{0} ** max_planes,
    offsets: [max_planes]u32 = [_]u32{0} ** max_planes,
};

pub const Mapping = struct {
    data: [*]u8,
    stride: u32,
    token: MapToken,
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create_device: *const fn (*anyopaque, std.posix.fd_t) anyerror!Device,
        destroy_device: *const fn (*anyopaque, Device) void,
        create_bo: *const fn (*anyopaque, Device, Allocation) anyerror!Bo,
        import_bo: *const fn (*anyopaque, Device, Import, ImportUsage) anyerror!Bo,
        destroy_bo: *const fn (*anyopaque, Bo) void,
        metadata: *const fn (*anyopaque, Bo) anyerror!Metadata,
        export_plane_fd: *const fn (*anyopaque, Bo, u8) anyerror!std.posix.fd_t,
        map: *const fn (*anyopaque, Bo, MapAccess) anyerror!Mapping,
        unmap: *const fn (*anyopaque, Bo, MapToken) void,
    };

    pub fn createDevice(self: Platform, fd: std.posix.fd_t) !Device {
        return self.vtable.create_device(self.context, fd);
    }

    pub fn destroyDevice(self: Platform, device: Device) void {
        self.vtable.destroy_device(self.context, device);
    }

    pub fn createBo(self: Platform, device: Device, allocation: Allocation) !Bo {
        return self.vtable.create_bo(self.context, device, allocation);
    }

    pub fn importBo(self: Platform, device: Device, import: Import, usage: ImportUsage) !Bo {
        return self.vtable.import_bo(self.context, device, import, usage);
    }

    pub fn destroyBo(self: Platform, bo: Bo) void {
        self.vtable.destroy_bo(self.context, bo);
    }

    pub fn getMetadata(self: Platform, bo: Bo) !Metadata {
        return self.vtable.metadata(self.context, bo);
    }

    /// Returns a new DMA-BUF FD owned by the caller. The BO remains owned by
    /// GBM; exporting it does not transfer or duplicate BO ownership.
    pub fn exportPlaneFd(self: Platform, bo: Bo, plane: u8) !std.posix.fd_t {
        return self.vtable.export_plane_fd(self.context, bo, plane);
    }

    pub fn map(self: Platform, bo: Bo, access: MapAccess) !Mapping {
        return self.vtable.map(self.context, bo, access);
    }

    pub fn unmap(self: Platform, bo: Bo, token: MapToken) void {
        self.vtable.unmap(self.context, bo, token);
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create_device = realCreateDevice,
    .destroy_device = realDestroyDevice,
    .create_bo = realCreateBo,
    .import_bo = realImportBo,
    .destroy_bo = realDestroyBo,
    .metadata = realMetadata,
    .export_plane_fd = realExportPlaneFd,
    .map = realMap,
    .unmap = realUnmap,
};

fn realCreateDevice(_: *anyopaque, fd: std.posix.fd_t) !Device {
    return @ptrCast(c.gbm_create_device(fd) orelse return error.CreateDeviceFailed);
}

fn realDestroyDevice(_: *anyopaque, device: Device) void {
    c.gbm_device_destroy(@ptrCast(@alignCast(device)));
}

fn realCreateBo(_: *anyopaque, device: Device, allocation: Allocation) !Bo {
    var usage: u32 = c.GBM_BO_USE_SCANOUT | c.GBM_BO_USE_RENDERING;
    const explicit_tiled = usesExplicitModifierPath(allocation);
    if (!explicit_tiled) usage |= c.GBM_BO_USE_LINEAR;
    const bo = if (explicit_tiled) blk: {
        const modifiers = [_]u64{allocation.modifier};
        break :blk c.gbm_bo_create_with_modifiers2(
            @ptrCast(@alignCast(device)),
            allocation.width,
            allocation.height,
            allocation.format,
            &modifiers,
            modifiers.len,
            usage,
        );
    } else c.gbm_bo_create(
        @ptrCast(@alignCast(device)),
        allocation.width,
        allocation.height,
        allocation.format,
        usage,
    );
    return @ptrCast(bo orelse return error.CreateBoFailed);
}

fn realImportBo(_: *anyopaque, device: Device, import: Import, usage: ImportUsage) !Bo {
    if (import.width == 0 or import.height == 0 or import.plane_count == 0 or
        import.plane_count > max_planes)
        return error.InvalidImport;
    var data: c.gbm_import_fd_modifier_data = .{
        .width = import.width,
        .height = import.height,
        .format = import.format,
        .num_fds = import.plane_count,
        .fds = [_]c_int{-1} ** max_planes,
        .strides = [_]c_int{0} ** max_planes,
        .offsets = [_]c_int{0} ** max_planes,
        .modifier = import.modifier,
    };
    for (0..import.plane_count) |plane| {
        if (import.fds[plane] < 0 or import.strides[plane] > std.math.maxInt(c_int) or
            import.offsets[plane] > std.math.maxInt(c_int))
            return error.InvalidImport;
        data.fds[plane] = import.fds[plane];
        data.strides[plane] = @intCast(import.strides[plane]);
        data.offsets[plane] = @intCast(import.offsets[plane]);
    }
    const bo = c.gbm_bo_import(
        @ptrCast(@alignCast(device)),
        c.GBM_BO_IMPORT_FD_MODIFIER,
        &data,
        switch (usage) {
            .rendering => c.GBM_BO_USE_RENDERING,
            .scanout => c.GBM_BO_USE_SCANOUT,
        },
    );
    return @ptrCast(bo orelse return error.ImportBoFailed);
}

fn usesExplicitModifierPath(allocation: Allocation) bool {
    return allocation.explicit_modifier and allocation.modifier != modifier_linear;
}

fn realDestroyBo(_: *anyopaque, bo: Bo) void {
    c.gbm_bo_destroy(@ptrCast(@alignCast(bo)));
}

fn realMetadata(_: *anyopaque, bo_value: Bo) !Metadata {
    const bo: *c.struct_gbm_bo = @ptrCast(@alignCast(bo_value));
    const count = c.gbm_bo_get_plane_count(bo);
    if (count <= 0 or count > max_planes) return error.UnsupportedPlaneCount;
    var result: Metadata = .{
        .width = c.gbm_bo_get_width(bo),
        .height = c.gbm_bo_get_height(bo),
        .format = c.gbm_bo_get_format(bo),
        .modifier = c.gbm_bo_get_modifier(bo),
        .plane_count = @intCast(count),
    };
    for (0..@as(usize, result.plane_count)) |plane| {
        result.handles[plane] = c.gbm_bo_get_handle_for_plane(bo, @intCast(plane)).u32;
        result.strides[plane] = c.gbm_bo_get_stride_for_plane(bo, @intCast(plane));
        result.offsets[plane] = c.gbm_bo_get_offset(bo, @intCast(plane));
    }
    return result;
}

fn realExportPlaneFd(_: *anyopaque, bo_value: Bo, plane: u8) !std.posix.fd_t {
    const bo: *c.struct_gbm_bo = @ptrCast(@alignCast(bo_value));
    if (plane >= c.gbm_bo_get_plane_count(bo)) return error.InvalidPlane;
    const fd = c.gbm_bo_get_fd_for_plane(bo, plane);
    if (fd < 0) return error.ExportDmaBufFailed;
    return fd;
}

fn realMap(_: *anyopaque, bo_value: Bo, access: MapAccess) !Mapping {
    const bo: *c.struct_gbm_bo = @ptrCast(@alignCast(bo_value));
    var stride: u32 = 0;
    var map_data: ?*anyopaque = null;
    const data = c.gbm_bo_map(
        bo,
        0,
        0,
        c.gbm_bo_get_width(bo),
        c.gbm_bo_get_height(bo),
        switch (access) {
            .read => c.GBM_BO_TRANSFER_READ,
            .write => c.GBM_BO_TRANSFER_WRITE,
        },
        &stride,
        &map_data,
    ) orelse return error.MapFailed;
    const token = map_data orelse return error.MapFailed;
    return .{ .data = @ptrCast(data), .stride = stride, .token = token };
}

fn realUnmap(_: *anyopaque, bo_value: Bo, token: MapToken) void {
    c.gbm_bo_unmap(@ptrCast(@alignCast(bo_value)), token);
}

test "gbm: real boundary is linked" {
    try std.testing.expect(real.context == @as(*anyopaque, @ptrCast(&real_context)));
}

test "gbm: explicit linear allocation uses ordinary linear path" {
    const linear: Allocation = .{
        .width = 1920,
        .height = 1200,
        .format = format_xrgb8888,
        .modifier = modifier_linear,
        .explicit_modifier = true,
    };
    const tiled: Allocation = .{
        .width = 1920,
        .height = 1200,
        .format = format_xrgb8888,
        .modifier = 1,
        .explicit_modifier = true,
    };

    try std.testing.expect(!usesExplicitModifierPath(linear));
    try std.testing.expect(usesExplicitModifierPath(tiled));
}
