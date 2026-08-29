//! Replaceable udev/libdrm platform boundary. Every value crossing it is an
//! Ouro-owned scalar or fixed-size record; no udev/libdrm pointer escapes.

const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
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

pub const ConnectorProperties = struct { crtc_id: u32 };
pub const CrtcProperties = struct {
    active: u32,
    mode_id: u32,
    out_fence_ptr: u32 = 0,
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
    plane_type_value: u64,
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
            .properties = .{
                .active = try requiredProperty(fd, props, "ACTIVE"),
                .mode_id = try requiredProperty(fd, props, "MODE_ID"),
                .out_fence_ptr = if (try optionalProperty(fd, props, "OUT_FENCE_PTR")) |value| value.id else 0,
            },
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
            .properties = .{ .crtc_id = try requiredProperty(fd, props, "CRTC_ID") },
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
            .plane_type_value = plane_type.value,
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
        c.O_CLOEXEC,
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

const PropertyValue = struct { id: u32, value: u64 };

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
    var index: usize = 0;
    while (index < props.*.count_props) : (index += 1) {
        const property = c.drmModeGetProperty(fd, props.*.props[index]) orelse
            return error.GetPropertyFailed;
        defer c.drmModeFreeProperty(property);
        const property_name = std.mem.sliceTo(property.*.name[0..], 0);
        if (std.mem.eql(u8, property_name, name)) return .{
            .id = property.*.prop_id,
            .value = props.*.prop_values[index],
        };
    }
    return null;
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
