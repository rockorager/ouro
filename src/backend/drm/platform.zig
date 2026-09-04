//! Replaceable udev/libdrm platform boundary. Every value crossing it is an
//! Ouro-owned scalar or fixed-size record; no udev/libdrm pointer escapes.

const std = @import("std");

const c = @cImport({
    @cInclude("libudev.h");
    @cInclude("drm_fourcc.h");
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

pub const path_capacity = 256;
pub const name_capacity = 32;
pub const invalid_index = std.math.maxInt(u32);
pub const modifier_invalid: u64 = (@as(u64, 1) << 56) - 1;

pub const Card = struct {
    path: [path_capacity:0]u8 = [_:0]u8{0} ** path_capacity,
    path_len: u16 = 0,
    syspath: [path_capacity:0]u8 = [_:0]u8{0} ** path_capacity,
    syspath_len: u16 = 0,
    boot_vga: bool = false,

    pub fn devicePath(self: *const Card) [:0]const u8 {
        return self.path[0..self.path_len :0];
    }

    pub fn stablePath(self: *const Card) []const u8 {
        return self.syspath[0..self.syspath_len];
    }
};

pub const Mode = struct {
    clock: u32,
    hdisplay: u16,
    hsync_start: u16,
    hsync_end: u16,
    htotal: u16,
    hskew: u16,
    vdisplay: u16,
    vsync_start: u16,
    vsync_end: u16,
    vtotal: u16,
    vscan: u16,
    vrefresh: u32,
    flags: u32,
    mode_type: u32,
    name: [name_capacity]u8 = [_]u8{0} ** name_capacity,
    name_len: u8 = 0,

    pub fn preferred(self: Mode) bool {
        return self.mode_type & c.DRM_MODE_TYPE_PREFERRED != 0;
    }
};

pub const BlobProperty = struct {
    id: u32 = 0,
    inherited: u64 = 0,
};

pub const RangeProperty = struct {
    id: u32 = 0,
    inherited: u64 = 0,
    minimum: u64 = 0,
    maximum: u64 = 0,
};

pub const ColorspaceProperty = struct {
    id: u32 = 0,
    inherited: u64 = 0,
    default: ?u64 = null,
    bt2020_rgb: ?u64 = null,
};

pub const HdrCapabilities = struct {
    bt2020_rgb: bool = false,
    pq: bool = false,
    hlg: bool = false,
};

pub const ZposProperty = struct {
    id: u32,
    inherited: u64,
    maximum: u64,
    immutable: bool,
};

pub const ConnectorProperties = struct {
    crtc_id: u32,
    vrr_capable: bool = false,
    colorspace: ColorspaceProperty = .{},
    hdr_output_metadata: BlobProperty = .{},
    max_bpc: RangeProperty = .{},
    hdr_capabilities: HdrCapabilities = .{},
};
pub const CrtcProperties = struct {
    active: u32,
    mode_id: u32,
    vrr_enabled: u32 = 0,
    degamma_lut: BlobProperty = .{},
    degamma_lut_size: u64 = 0,
    ctm: BlobProperty = .{},
    gamma_lut: BlobProperty = .{},
    gamma_lut_size: u64 = 0,
};
pub const PlaneProperties = struct {
    plane_type: u32,
    fb_id: u32,
    crtc_id: u32,
    src_x: u32,
    src_y: u32,
    src_w: u32,
    src_h: u32,
    crtc_x: u32,
    crtc_y: u32,
    crtc_w: u32,
    crtc_h: u32,
    in_fence_fd: u32 = 0,
    zpos: ?ZposProperty = null,
};

pub const Connector = struct {
    id: u32,
    connector_type: u32,
    connector_type_id: u32,
    connected: bool,
    desktop: bool,
    width_mm: u32,
    height_mm: u32,
    encoder_id: u32,
    mode_start: u32,
    mode_count: u32,
    encoder_start: u32,
    encoder_count: u32,
    properties: ConnectorProperties,
};

pub const Encoder = struct {
    id: u32,
    crtc_id: u32,
    possible_crtcs: u32,
};

pub const Crtc = struct {
    id: u32,
    index: u32,
    properties: CrtcProperties,
};

pub const Format = struct {
    fourcc: u32,
    modifier: u64,
};

pub const LeaseResult = struct {
    fd: std.posix.fd_t,
    lessee_id: u32,
};

pub const Plane = struct {
    id: u32,
    possible_crtcs: u32,
    current_crtc_id: u32 = 0,
    plane_type_value: u64,
    has_in_formats: bool = false,
    format_start: u32,
    format_count: u32,
    properties: PlaneProperties,
};

/// Storage is allocated by the DRM owner at initialization and reused on each
/// scan. Platform implementations may only advance counts and write records.
pub const TopologyBuffer = struct {
    connectors: []Connector,
    modes: []Mode,
    connector_encoders: []u32,
    encoders: []Encoder,
    crtcs: []Crtc,
    planes: []Plane,
    formats: []Format,
    connector_count: usize = 0,
    mode_count: usize = 0,
    connector_encoder_count: usize = 0,
    encoder_count: usize = 0,
    crtc_count: usize = 0,
    plane_count: usize = 0,
    format_count: usize = 0,

    pub fn reset(self: *TopologyBuffer) void {
        self.connector_count = 0;
        self.mode_count = 0;
        self.connector_encoder_count = 0;
        self.encoder_count = 0;
        self.crtc_count = 0;
        self.plane_count = 0;
        self.format_count = 0;
    }
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        discover: *const fn (*anyopaque, []Card, []const u8) anyerror!usize,
        enable_client_caps: *const fn (*anyopaque, std.posix.fd_t) anyerror!void,
        read_topology: *const fn (*anyopaque, std.posix.fd_t, *TopologyBuffer) anyerror!void,
        open_lease_device: *const fn (*anyopaque, [:0]const u8) anyerror!std.posix.fd_t,
        create_lease: *const fn (*anyopaque, std.posix.fd_t, []const u32) anyerror!LeaseResult,
        revoke_lease: *const fn (*anyopaque, std.posix.fd_t, u32) anyerror!void,
        list_lessees: *const fn (*anyopaque, std.posix.fd_t, []u32) anyerror!usize,
    };

    pub fn discover(self: Platform, cards: []Card, seat: []const u8) !usize {
        return self.vtable.discover(self.context, cards, seat);
    }

    pub fn enableClientCaps(self: Platform, fd: std.posix.fd_t) !void {
        return self.vtable.enable_client_caps(self.context, fd);
    }

    pub fn readTopology(self: Platform, fd: std.posix.fd_t, buffer: *TopologyBuffer) !void {
        return self.vtable.read_topology(self.context, fd, buffer);
    }

    pub fn openLeaseDevice(self: Platform, path: [:0]const u8) !std.posix.fd_t {
        return self.vtable.open_lease_device(self.context, path);
    }

    pub fn createLease(self: Platform, fd: std.posix.fd_t, objects: []const u32) !LeaseResult {
        return self.vtable.create_lease(self.context, fd, objects);
    }

    pub fn revokeLease(self: Platform, fd: std.posix.fd_t, lessee_id: u32) !void {
        return self.vtable.revoke_lease(self.context, fd, lessee_id);
    }

    pub fn listLessees(self: Platform, fd: std.posix.fd_t, storage: []u32) ![]const u32 {
        const count = try self.vtable.list_lessees(self.context, fd, storage);
        if (count > storage.len) return error.InvalidPlatformResult;
        return storage[0..count];
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .discover = realDiscover,
    .enable_client_caps = realEnableClientCaps,
    .read_topology = realReadTopology,
    .open_lease_device = realOpenLeaseDevice,
    .create_lease = realCreateLease,
    .revoke_lease = realRevokeLease,
    .list_lessees = realListLessees,
};

fn realDiscover(_: *anyopaque, cards: []Card, seat: []const u8) !usize {
    const udev = c.udev_new() orelse return error.UdevUnavailable;
    defer _ = c.udev_unref(udev);
    const enumerate = c.udev_enumerate_new(udev) orelse return error.UdevUnavailable;
    defer _ = c.udev_enumerate_unref(enumerate);
    if (c.udev_enumerate_add_match_subsystem(enumerate, "drm") < 0 or
        c.udev_enumerate_scan_devices(enumerate) < 0)
        return error.UdevEnumerationFailed;

    var count: usize = 0;
    var entry = c.udev_enumerate_get_list_entry(enumerate);
    while (entry != null) : (entry = c.udev_list_entry_get_next(entry)) {
        const syspath_ptr = c.udev_list_entry_get_name(entry) orelse continue;
        const device = c.udev_device_new_from_syspath(udev, syspath_ptr) orelse continue;
        defer _ = c.udev_device_unref(device);
        const sysname = c.udev_device_get_sysname(device) orelse continue;
        const sysname_slice = std.mem.span(sysname);
        if (!isCardName(sysname_slice)) continue;
        const devnode = c.udev_device_get_devnode(device) orelse continue;
        const device_seat = if (c.udev_device_get_property_value(device, "ID_SEAT")) |value|
            std.mem.span(value)
        else
            "seat0";
        if (!std.mem.eql(u8, device_seat, seat)) continue;
        if (count == cards.len) return error.CardCapacityExceeded;

        var card: Card = .{};
        try copyZ(&card.path, &card.path_len, std.mem.span(devnode));
        try copyZ(&card.syspath, &card.syspath_len, std.mem.span(syspath_ptr));
        var parent = c.udev_device_get_parent(device);
        while (parent != null) : (parent = c.udev_device_get_parent(parent)) {
            if (c.udev_device_get_sysattr_value(parent, "boot_vga")) |value| {
                card.boot_vga = std.mem.eql(u8, std.mem.span(value), "1");
                break;
            }
        }
        cards[count] = card;
        count += 1;
    }
    return count;
}

fn realEnableClientCaps(_: *anyopaque, fd: std.posix.fd_t) !void {
    if (c.drmSetClientCap(fd, c.DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0)
        return error.UniversalPlanesUnsupported;
    if (c.drmSetClientCap(fd, c.DRM_CLIENT_CAP_ATOMIC, 1) != 0)
        return error.AtomicUnsupported;
}

fn realReadTopology(_: *anyopaque, fd: std.posix.fd_t, out: *TopologyBuffer) !void {
    out.reset();
    const resources = c.drmModeGetResources(fd) orelse return error.GetResourcesFailed;
    defer c.drmModeFreeResources(resources);

    var index: usize = 0;
    while (index < @as(usize, @intCast(resources.*.count_crtcs))) : (index += 1) {
        if (out.crtc_count == out.crtcs.len) return error.CrtcCapacityExceeded;
        const id = resources.*.crtcs[index];
        const props = try objectProperties(fd, id, c.DRM_MODE_OBJECT_CRTC);
        defer c.drmModeFreeObjectProperties(props);
        out.crtcs[out.crtc_count] = .{
            .id = id,
            .index = @intCast(index),
            .properties = try crtcProperties(fd, props),
        };
        out.crtc_count += 1;
    }

    index = 0;
    while (index < @as(usize, @intCast(resources.*.count_encoders))) : (index += 1) {
        if (out.encoder_count == out.encoders.len) return error.EncoderCapacityExceeded;
        const encoder = c.drmModeGetEncoder(fd, resources.*.encoders[index]) orelse
            return error.GetEncoderFailed;
        defer c.drmModeFreeEncoder(encoder);
        out.encoders[out.encoder_count] = .{
            .id = encoder.*.encoder_id,
            .crtc_id = encoder.*.crtc_id,
            .possible_crtcs = encoder.*.possible_crtcs,
        };
        out.encoder_count += 1;
    }

    index = 0;
    while (index < @as(usize, @intCast(resources.*.count_connectors))) : (index += 1) {
        if (out.connector_count == out.connectors.len) return error.ConnectorCapacityExceeded;
        const connector = c.drmModeGetConnector(fd, resources.*.connectors[index]) orelse
            return error.GetConnectorFailed;
        defer c.drmModeFreeConnector(connector);
        const mode_start = out.mode_count;
        var mode_index: usize = 0;
        while (mode_index < @as(usize, @intCast(connector.*.count_modes))) : (mode_index += 1) {
            if (out.mode_count == out.modes.len) return error.ModeCapacityExceeded;
            out.modes[out.mode_count] = copyMode(connector.*.modes[mode_index]);
            out.mode_count += 1;
        }
        const encoder_start = out.connector_encoder_count;
        var encoder_index: usize = 0;
        while (encoder_index < @as(usize, @intCast(connector.*.count_encoders))) : (encoder_index += 1) {
            if (out.connector_encoder_count == out.connector_encoders.len)
                return error.ConnectorEncoderCapacityExceeded;
            out.connector_encoders[out.connector_encoder_count] = connector.*.encoders[encoder_index];
            out.connector_encoder_count += 1;
        }
        const props = try objectProperties(fd, connector.*.connector_id, c.DRM_MODE_OBJECT_CONNECTOR);
        defer c.drmModeFreeObjectProperties(props);
        out.connectors[out.connector_count] = .{
            .id = connector.*.connector_id,
            .connector_type = connector.*.connector_type,
            .connector_type_id = connector.*.connector_type_id,
            .connected = connector.*.connection == c.DRM_MODE_CONNECTED,
            .desktop = connector.*.connector_type != c.DRM_MODE_CONNECTOR_WRITEBACK,
            .width_mm = connector.*.mmWidth,
            .height_mm = connector.*.mmHeight,
            .encoder_id = connector.*.encoder_id,
            .mode_start = @intCast(mode_start),
            .mode_count = @intCast(out.mode_count - mode_start),
            .encoder_start = @intCast(encoder_start),
            .encoder_count = @intCast(out.connector_encoder_count - encoder_start),
            .properties = try connectorProperties(fd, props),
        };
        out.connector_count += 1;
    }

    const plane_resources = c.drmModeGetPlaneResources(fd) orelse return error.GetPlaneResourcesFailed;
    defer c.drmModeFreePlaneResources(plane_resources);
    index = 0;
    while (index < @as(usize, @intCast(plane_resources.*.count_planes))) : (index += 1) {
        if (out.plane_count == out.planes.len) return error.PlaneCapacityExceeded;
        const plane = c.drmModeGetPlane(fd, plane_resources.*.planes[index]) orelse
            return error.GetPlaneFailed;
        defer c.drmModeFreePlane(plane);
        const props = try objectProperties(fd, plane.*.plane_id, c.DRM_MODE_OBJECT_PLANE);
        defer c.drmModeFreeObjectProperties(props);
        const format_start = out.format_count;
        var format_index: usize = 0;
        while (format_index < @as(usize, @intCast(plane.*.count_formats))) : (format_index += 1) {
            try appendFormat(out, plane.*.formats[format_index], modifier_invalid);
        }
        const in_formats = optionalProperty(fd, props, "IN_FORMATS") catch return error.GetPropertyFailed;
        if (in_formats) |property| if (property.value != 0)
            try appendModifierBlob(fd, out, property.value, format_start);
        const plane_type = try requiredPropertyValue(fd, props, "type");
        out.planes[out.plane_count] = .{
            .id = plane.*.plane_id,
            .possible_crtcs = plane.*.possible_crtcs,
            .current_crtc_id = plane.*.crtc_id,
            .plane_type_value = plane_type.value,
            .has_in_formats = in_formats != null and in_formats.?.value != 0,
            .format_start = @intCast(format_start),
            .format_count = @intCast(out.format_count - format_start),
            .properties = .{
                .plane_type = plane_type.id,
                .fb_id = try requiredProperty(fd, props, "FB_ID"),
                .crtc_id = try requiredProperty(fd, props, "CRTC_ID"),
                .src_x = try requiredProperty(fd, props, "SRC_X"),
                .src_y = try requiredProperty(fd, props, "SRC_Y"),
                .src_w = try requiredProperty(fd, props, "SRC_W"),
                .src_h = try requiredProperty(fd, props, "SRC_H"),
                .crtc_x = try requiredProperty(fd, props, "CRTC_X"),
                .crtc_y = try requiredProperty(fd, props, "CRTC_Y"),
                .crtc_w = try requiredProperty(fd, props, "CRTC_W"),
                .crtc_h = try requiredProperty(fd, props, "CRTC_H"),
                .in_fence_fd = if (try optionalProperty(fd, props, "IN_FENCE_FD")) |value| value.id else 0,
                .zpos = try optionalZposProperty(fd, props),
            },
        };
        out.plane_count += 1;
    }
}

fn realOpenLeaseDevice(_: *anyopaque, path: [:0]const u8) !std.posix.fd_t {
    const result = std.os.linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
    if (std.os.linux.errno(result) != .SUCCESS) return error.OpenLeaseDeviceFailed;
    const fd: std.posix.fd_t = @intCast(result);
    errdefer _ = std.os.linux.close(fd);
    const is_master = c.drmIsMaster(fd);
    if (is_master < 0) return error.QueryLeaseDeviceMasterFailed;
    if (is_master == 1 and c.drmDropMaster(fd) != 0)
        return error.DropLeaseDeviceMasterFailed;
    return fd;
}

fn realCreateLease(
    _: *anyopaque,
    fd: std.posix.fd_t,
    objects: []const u32,
) !LeaseResult {
    if (objects.len == 0 or objects.len > std.math.maxInt(c_int))
        return error.InvalidLeaseObjects;
    var lessee_id: u32 = 0;
    const lease_fd = c.drmModeCreateLease(
        fd,
        objects.ptr,
        @intCast(objects.len),
        @bitCast(std.os.linux.O{ .CLOEXEC = true }),
        &lessee_id,
    );
    if (lease_fd < 0) return error.CreateLeaseFailed;
    if (lessee_id == 0) {
        _ = std.os.linux.close(lease_fd);
        return error.CreateLeaseFailed;
    }
    return .{ .fd = lease_fd, .lessee_id = lessee_id };
}

fn realRevokeLease(_: *anyopaque, fd: std.posix.fd_t, lessee_id: u32) !void {
    if (lessee_id == 0 or c.drmModeRevokeLease(fd, lessee_id) != 0)
        return error.RevokeLeaseFailed;
}

fn realListLessees(_: *anyopaque, fd: std.posix.fd_t, storage: []u32) !usize {
    const list = c.drmModeListLessees(fd) orelse return error.ListLesseesFailed;
    defer c.drmFree(list);
    if (list[0].count > storage.len) return error.LesseeCapacityExceeded;
    const words: [*]const u32 = @ptrCast(list);
    for (storage[0..list[0].count], 0..) |*entry, index| entry.* = words[index + 1];
    return list[0].count;
}

const PropertyValue = struct { id: u32, value: u64 };

fn connectorProperties(fd: std.posix.fd_t, props: *c.drmModeObjectProperties) !ConnectorProperties {
    return .{
        .crtc_id = try requiredProperty(fd, props, "CRTC_ID"),
        .vrr_capable = if (try optionalProperty(fd, props, "vrr_capable")) |value|
            value.value != 0
        else
            false,
        .colorspace = try optionalColorspaceProperty(fd, props),
        .hdr_output_metadata = try optionalBlobProperty(fd, props, "HDR_OUTPUT_METADATA"),
        .max_bpc = try optionalRangeProperty(fd, props, "max bpc"),
        .hdr_capabilities = try optionalHdrCapabilities(fd, props),
    };
}

fn crtcProperties(fd: std.posix.fd_t, props: *c.drmModeObjectProperties) !CrtcProperties {
    return .{
        .active = try requiredProperty(fd, props, "ACTIVE"),
        .mode_id = try requiredProperty(fd, props, "MODE_ID"),
        .vrr_enabled = if (try optionalProperty(fd, props, "VRR_ENABLED")) |value| value.id else 0,
        .degamma_lut = try optionalBlobProperty(fd, props, "DEGAMMA_LUT"),
        .degamma_lut_size = if (try optionalProperty(fd, props, "DEGAMMA_LUT_SIZE")) |value| value.value else 0,
        .ctm = try optionalBlobProperty(fd, props, "CTM"),
        .gamma_lut = try optionalBlobProperty(fd, props, "GAMMA_LUT"),
        .gamma_lut_size = if (try optionalProperty(fd, props, "GAMMA_LUT_SIZE")) |value| value.value else 0,
    };
}

fn optionalColorspaceProperty(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
) !ColorspaceProperty {
    const found = try propertyByName(fd, props, "Colorspace") orelse return .{};
    defer c.drmModeFreeProperty(found.property);
    return parseColorspaceProperty(found.property, found.value);
}

fn parseColorspaceProperty(
    property: *const c.drmModePropertyRes,
    inherited: u64,
) !ColorspaceProperty {
    if (property.*.flags & c.DRM_MODE_PROP_ENUM == 0 or property.*.count_enums < 0)
        return error.MalformedProperty;
    var result: ColorspaceProperty = .{
        .id = property.*.prop_id,
        .inherited = inherited,
    };
    var index: usize = 0;
    while (index < @as(usize, @intCast(property.*.count_enums))) : (index += 1) {
        const entry = property.*.enums[index];
        const name = std.mem.sliceTo(entry.name[0..], 0);
        if (std.mem.eql(u8, name, "Default")) result.default = entry.value;
        if (std.mem.eql(u8, name, "BT2020_RGB")) result.bt2020_rgb = entry.value;
    }
    return result;
}

fn optionalBlobProperty(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
    name: []const u8,
) !BlobProperty {
    const found = try propertyByName(fd, props, name) orelse return .{};
    defer c.drmModeFreeProperty(found.property);
    if (found.property.*.flags & c.DRM_MODE_PROP_BLOB == 0)
        return error.MalformedProperty;
    return .{ .id = found.property.*.prop_id, .inherited = found.value };
}

fn optionalHdrCapabilities(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
) !HdrCapabilities {
    const found = try propertyByName(fd, props, "EDID") orelse return .{};
    defer c.drmModeFreeProperty(found.property);
    if (found.property.*.flags & c.DRM_MODE_PROP_BLOB == 0)
        return error.MalformedProperty;
    if (found.value == 0 or found.value > std.math.maxInt(u32)) return .{};
    const blob = c.drmModeGetPropertyBlob(fd, @intCast(found.value)) orelse return .{};
    defer c.drmModeFreePropertyBlob(blob);
    const bytes: [*]const u8 = @ptrCast(blob.*.data orelse return .{});
    return parseEdidHdrCapabilities(bytes[0..blob.*.length]);
}

fn parseEdidHdrCapabilities(edid: []const u8) HdrCapabilities {
    const block_bytes = 128;
    const header = [_]u8{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
    if (edid.len < block_bytes or !std.mem.eql(u8, edid[0..header.len], &header) or
        !validEdidBlock(edid[0..block_bytes])) return .{};
    const extension_count = edid[126];
    const required = std.math.mul(usize, @as(usize, extension_count) + 1, block_bytes) catch
        return .{};
    if (required > edid.len) return .{};

    var capabilities: HdrCapabilities = .{};
    for (0..extension_count) |extension_index| {
        const start = (extension_index + 1) * block_bytes;
        const extension = edid[start..][0..block_bytes];
        if (extension[0] != 0x02 or !validEdidBlock(extension)) continue;
        const data_end = extension[2];
        if (data_end < 4 or data_end > 127) continue;
        var cursor: usize = 4;
        while (cursor < data_end) {
            const header_byte = extension[cursor];
            const payload_len: usize = header_byte & 0x1f;
            const next = cursor + 1 + payload_len;
            if (next > data_end) break;
            const payload = extension[cursor + 1 .. next];
            if (header_byte >> 5 == 0x07 and payload.len >= 2) switch (payload[0]) {
                0x05 => capabilities.bt2020_rgb = capabilities.bt2020_rgb or
                    payload[1] & 0x80 != 0,
                0x06 => {
                    capabilities.pq = capabilities.pq or payload[1] & 0x04 != 0;
                    capabilities.hlg = capabilities.hlg or payload[1] & 0x08 != 0;
                },
                else => {},
            };
            cursor = next;
        }
    }
    return capabilities;
}

fn validEdidBlock(block: []const u8) bool {
    if (block.len != 128) return false;
    var checksum: u8 = 0;
    for (block) |byte| checksum +%= byte;
    return checksum == 0;
}

fn optionalRangeProperty(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
    name: []const u8,
) !RangeProperty {
    const found = try propertyByName(fd, props, name) orelse return .{};
    defer c.drmModeFreeProperty(found.property);
    return parseRangeProperty(found.property, found.value);
}

fn parseRangeProperty(
    property: *const c.drmModePropertyRes,
    inherited: u64,
) !RangeProperty {
    if (property.*.flags & c.DRM_MODE_PROP_RANGE == 0 or property.*.count_values != 2 or
        property.*.values[0] > property.*.values[1])
        return error.MalformedProperty;
    return .{
        .id = property.*.prop_id,
        .inherited = inherited,
        .minimum = property.*.values[0],
        .maximum = property.*.values[1],
    };
}

fn optionalZposProperty(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
) !?ZposProperty {
    const found = try propertyByName(fd, props, "zpos") orelse return null;
    defer c.drmModeFreeProperty(found.property);
    const immutable = found.property.*.flags & c.DRM_MODE_PROP_IMMUTABLE != 0;
    var maximum = found.value;
    if (!immutable and found.property.*.count_values >= 2)
        maximum = @max(maximum, found.property.*.values[1]);
    return .{
        .id = found.property.*.prop_id,
        .inherited = found.value,
        .maximum = maximum,
        .immutable = immutable,
    };
}

const Property = struct {
    property: *c.drmModePropertyRes,
    value: u64,
};

fn propertyByName(
    fd: std.posix.fd_t,
    props: *c.drmModeObjectProperties,
    name: []const u8,
) !?Property {
    var index: usize = 0;
    while (index < props.*.count_props) : (index += 1) {
        const property = c.drmModeGetProperty(fd, props.*.props[index]) orelse
            return error.GetPropertyFailed;
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        if (std.mem.eql(u8, property_name, name)) return .{
            .property = property,
            .value = props.*.prop_values[index],
        };
        c.drmModeFreeProperty(property);
    }
    return null;
}

fn objectProperties(fd: std.posix.fd_t, id: u32, object_type: u32) !*c.drmModeObjectProperties {
    return c.drmModeObjectGetProperties(fd, id, object_type) orelse error.GetPropertiesFailed;
}

fn requiredProperty(fd: std.posix.fd_t, props: *c.drmModeObjectProperties, name: []const u8) !u32 {
    return (try optionalProperty(fd, props, name) orelse return error.MissingRequiredProperty).id;
}

fn requiredPropertyValue(fd: std.posix.fd_t, props: *c.drmModeObjectProperties, name: []const u8) !PropertyValue {
    return try optionalProperty(fd, props, name) orelse error.MissingRequiredProperty;
}

fn optionalProperty(fd: std.posix.fd_t, props: *c.drmModeObjectProperties, name: []const u8) !?PropertyValue {
    const found = try propertyByName(fd, props, name) orelse return null;
    defer c.drmModeFreeProperty(found.property);
    return .{ .id = found.property.*.prop_id, .value = found.value };
}

fn appendFormat(out: *TopologyBuffer, fourcc: u32, modifier: u64) !void {
    if (out.format_count == out.formats.len) return error.FormatCapacityExceeded;
    out.formats[out.format_count] = .{ .fourcc = fourcc, .modifier = modifier };
    out.format_count += 1;
}

fn appendModifierBlob(fd: std.posix.fd_t, out: *TopologyBuffer, blob_id: u64, format_start: usize) !void {
    const blob = c.drmModeGetPropertyBlob(fd, @intCast(blob_id)) orelse return error.GetPropertyBlobFailed;
    defer c.drmModeFreePropertyBlob(blob);
    if (blob.*.length < @sizeOf(c.struct_drm_format_modifier_blob)) return error.MalformedPropertyBlob;
    const bytes: [*]align(1) const u8 = @ptrCast(blob.*.data orelse return error.MalformedPropertyBlob);
    const header = std.mem.bytesToValue(c.struct_drm_format_modifier_blob, bytes[0..@sizeOf(c.struct_drm_format_modifier_blob)]);
    const formats_bytes = @as(usize, header.count_formats) * @sizeOf(u32);
    const modifiers_bytes = @as(usize, header.count_modifiers) * @sizeOf(c.struct_drm_format_modifier);
    if (@as(usize, header.formats_offset) + formats_bytes > blob.*.length or
        @as(usize, header.modifiers_offset) + modifiers_bytes > blob.*.length)
        return error.MalformedPropertyBlob;
    const formats_raw = bytes[header.formats_offset..][0..formats_bytes];
    const modifiers_raw = bytes[header.modifiers_offset..][0..modifiers_bytes];
    var modifier_index: usize = 0;
    while (modifier_index < header.count_modifiers) : (modifier_index += 1) {
        const offset = modifier_index * @sizeOf(c.struct_drm_format_modifier);
        const modifier = std.mem.bytesToValue(c.struct_drm_format_modifier, modifiers_raw[offset..][0..@sizeOf(c.struct_drm_format_modifier)]);
        var bit: usize = 0;
        while (bit < 64) : (bit += 1) if (modifier.formats & (@as(u64, 1) << @intCast(bit)) != 0) {
            const format_index = @as(usize, modifier.offset) + bit;
            if (format_index >= header.count_formats) return error.MalformedPropertyBlob;
            const byte_index = format_index * @sizeOf(u32);
            const fourcc = std.mem.readInt(u32, formats_raw[byte_index..][0..4], .little);
            // Replace the implicit entry when this is the first explicit
            // modifier; additional modifiers are appended.
            var existing = format_start;
            while (existing < out.format_count) : (existing += 1) {
                if (out.formats[existing].fourcc == fourcc and
                    out.formats[existing].modifier == modifier_invalid)
                {
                    out.formats[existing].modifier = modifier.modifier;
                    break;
                }
            } else try appendFormat(out, fourcc, modifier.modifier);
        };
    }
}

fn copyMode(source: c.drmModeModeInfo) Mode {
    var mode: Mode = .{
        .clock = source.clock,
        .hdisplay = source.hdisplay,
        .hsync_start = source.hsync_start,
        .hsync_end = source.hsync_end,
        .htotal = source.htotal,
        .hskew = source.hskew,
        .vdisplay = source.vdisplay,
        .vsync_start = source.vsync_start,
        .vsync_end = source.vsync_end,
        .vtotal = source.vtotal,
        .vscan = source.vscan,
        .vrefresh = source.vrefresh,
        .flags = source.flags,
        .mode_type = source.type,
    };
    const name = std.mem.sliceTo(&source.name, 0);
    mode.name_len = @intCast(@min(name.len, mode.name.len));
    @memcpy(mode.name[0..mode.name_len], name[0..mode.name_len]);
    return mode;
}

fn isCardName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "card") or name.len == 4) return false;
    for (name[4..]) |character| if (!std.ascii.isDigit(character)) return false;
    return true;
}

fn copyZ(destination: *[path_capacity:0]u8, length: *u16, source: []const u8) !void {
    if (source.len >= destination.len) return error.PathTooLong;
    @memcpy(destination[0..source.len], source);
    destination[source.len] = 0;
    length.* = @intCast(source.len);
}

test "drm platform: card sysname filtering is strict" {
    try std.testing.expect(isCardName("card0"));
    try std.testing.expect(isCardName("card12"));
    try std.testing.expect(!isCardName("card"));
    try std.testing.expect(!isCardName("card0-DP-1"));
    try std.testing.expect(!isCardName("renderD128"));
}

test "drm platform: color properties preserve driver values" {
    var enums = [_]c.struct_drm_mode_property_enum{
        std.mem.zeroes(c.struct_drm_mode_property_enum),
        std.mem.zeroes(c.struct_drm_mode_property_enum),
    };
    @memcpy(enums[0].name[0..7], "Default");
    enums[0].value = 3;
    @memcpy(enums[1].name[0..10], "BT2020_RGB");
    enums[1].value = 9;
    var colorspace = std.mem.zeroes(c.drmModePropertyRes);
    colorspace.prop_id = 41;
    colorspace.flags = c.DRM_MODE_PROP_ENUM;
    colorspace.count_enums = enums.len;
    colorspace.enums = &enums;
    try std.testing.expectEqual(ColorspaceProperty{
        .id = 41,
        .inherited = 9,
        .default = 3,
        .bt2020_rgb = 9,
    }, try parseColorspaceProperty(&colorspace, 9));

    var values = [_]u64{ 8, 16 };
    var max_bpc = std.mem.zeroes(c.drmModePropertyRes);
    max_bpc.prop_id = 42;
    max_bpc.flags = c.DRM_MODE_PROP_RANGE;
    max_bpc.count_values = values.len;
    max_bpc.values = &values;
    try std.testing.expectEqual(RangeProperty{
        .id = 42,
        .inherited = 10,
        .minimum = 8,
        .maximum = 16,
    }, try parseRangeProperty(&max_bpc, 10));
}

test "drm platform: malformed color property types are rejected" {
    var property = std.mem.zeroes(c.drmModePropertyRes);
    try std.testing.expectError(error.MalformedProperty, parseColorspaceProperty(&property, 0));
    try std.testing.expectError(error.MalformedProperty, parseRangeProperty(&property, 0));
}

test "drm platform: CTA EDID publishes exact HDR capabilities" {
    var edid = [_]u8{0} ** 256;
    edid[0..8].* = .{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
    edid[126] = 1;
    setEdidChecksum(edid[0..128]);
    edid[128] = 0x02;
    edid[129] = 3;
    edid[130] = 10;
    edid[132] = 0xe2;
    edid[133] = 0x05;
    edid[134] = 0x80;
    edid[135] = 0xe2;
    edid[136] = 0x06;
    edid[137] = 0x0c;
    setEdidChecksum(edid[128..256]);

    try std.testing.expectEqual(HdrCapabilities{
        .bt2020_rgb = true,
        .pq = true,
        .hlg = true,
    }, parseEdidHdrCapabilities(&edid));
}

test "drm platform: malformed EDID cannot advertise HDR" {
    var edid = [_]u8{0} ** 256;
    edid[0..8].* = .{ 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00 };
    edid[126] = 1;
    setEdidChecksum(edid[0..128]);
    edid[128] = 0x02;
    edid[130] = 7;
    edid[132] = 0xe2;
    edid[133] = 0x06;
    edid[134] = 0x04;
    // Leave the extension checksum invalid.
    try std.testing.expectEqual(HdrCapabilities{}, parseEdidHdrCapabilities(&edid));
    try std.testing.expectEqual(HdrCapabilities{}, parseEdidHdrCapabilities(edid[0..127]));
}

fn setEdidChecksum(block: []u8) void {
    std.debug.assert(block.len == 128);
    block[127] = 0;
    var checksum: u8 = 0;
    for (block) |byte| checksum +%= byte;
    block[127] = 0 -% checksum;
}
