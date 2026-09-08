//! Independently updated KMS cursor, using the cursor IOCTL compatibility
//! interface. Drivers can apply these updates asynchronously to the primary
//! plane. Immutable cursor BOs stay alive until the owning CRTC is drained.
const std = @import("std");
const drm = @import("manager.zig");
const framebuffer = @import("framebuffer.zig");
const gbm = @import("../gbm.zig");
const render = @import("../../render/types.zig");
const c = @cImport({
    @cInclude("xf86drm.h");
    @cInclude("xf86drmMode.h");
});

pub const Size = struct { width: u32, height: u32 };
pub const Update = struct {
    crtc: u32,
    handle: u32,
    width: u32,
    height: u32,
    x: i32,
    y: i32,
    image: bool,
};
pub const Platform = struct {
    context: ?*anyopaque = null,
    size_fn: *const fn (?*anyopaque, std.posix.fd_t) anyerror!Size = realSize,
    update_fn: *const fn (?*anyopaque, std.posix.fd_t, Update) anyerror!void = realUpdate,
};

fn realSize(_: ?*anyopaque, fd: std.posix.fd_t) !Size {
    var width: u64 = 0;
    var height: u64 = 0;
    if (c.drmGetCap(fd, c.DRM_CAP_CURSOR_WIDTH, &width) != 0 or
        c.drmGetCap(fd, c.DRM_CAP_CURSOR_HEIGHT, &height) != 0 or
        width == 0 or height == 0 or width > 512 or height > 512)
        return error.CursorUnsupported;
    return .{ .width = @intCast(width), .height = @intCast(height) };
}

fn realUpdate(_: ?*anyopaque, fd: std.posix.fd_t, update: Update) !void {
    var request: c.struct_drm_mode_cursor2 = std.mem.zeroes(c.struct_drm_mode_cursor2);
    request.flags = @as(u32, c.DRM_MODE_CURSOR_MOVE) | (if (update.image) @as(u32, c.DRM_MODE_CURSOR_BO) else 0);
    request.crtc_id = update.crtc;
    request.handle = update.handle;
    request.width = update.width;
    request.height = update.height;
    request.x = update.x;
    request.y = update.y;
    if (c.drmIoctl(fd, c.DRM_IOCTL_MODE_CURSOR2, &request) != 0) {
        if (std.c.errno(@as(c_int, -1)) == .BUSY) return error.CursorBusy;
        return error.CursorUpdateFailed;
    }
}

pub fn selectPlane(snapshot: drm.Snapshot) ?drm.Plane {
    const crtc = snapshot.selectedCrtc();
    if (crtc.index >= 32) return null;
    const mask = @as(u32, 1) << @intCast(crtc.index);
    var selected: ?drm.Plane = null;
    for (snapshot.planes) |plane| {
        if (plane.plane_type_value == 2 and
            plane.possible_crtcs & mask != 0 and
            (plane.current_crtc_id == crtc.id or
                (plane.current_crtc_id == 0 and plane.possible_crtcs == mask)))
        {
            // The compatibility IOCTL addresses a CRTC's designated cursor.
            // Do not guess which shared/unbound plane the driver would use.
            if (selected != null) return null;
            selected = plane;
        }
    }
    return selected;
}

const capacity = 64;
const Image = struct {
    key: u64,
    width: u32,
    height: u32,
    buffer: framebuffer.DumbBuffer,
};

pub const Cursor = struct {
    platform: Platform,
    buffers: framebuffer.Platform,
    fd: std.posix.fd_t,
    crtc: u32,
    size: Size,
    images: [capacity]Image = undefined,
    count: usize = 0,
    desired: ?usize = null,
    active: ?usize = null,
    x: i32 = 0,
    y: i32 = 0,
    shown_x: i32 = 0,
    shown_y: i32 = 0,
    failed: bool = false,
    /// A plane may only become visible after the software cursor is erased.
    primary_clean: bool = false,
    submitted_clean: ?bool = null,

    pub fn init(platform: Platform, buffers: framebuffer.Platform, fd: std.posix.fd_t, crtc: u32) !Cursor {
        const size = try platform.size_fn(platform.context, fd);
        if (size.width == 0 or size.height == 0 or size.width > 512 or size.height > 512)
            return error.CursorUnsupported;
        return .{ .platform = platform, .buffers = buffers, .fd = fd, .crtc = crtc, .size = size };
    }

    /// Called only after KMS has detached the plane and drained this CRTC.
    pub fn deinit(self: *Cursor) void {
        for (self.images[0..self.count]) |image| self.buffers.destroyDumb(self.fd, image.buffer);
        self.count = 0;
        self.active = null;
        self.desired = null;
    }

    fn prepare(self: *Cursor, sample: render.SurfaceSample) !usize {
        _ = try render.validateSample(sample);
        if (sample.source.bytes.len > 512 * 512 * 4 or sample.source.format != .argb8888_premultiplied or sample.transform != .normal or
            sample.global_alpha != 255 or sample.source.native != null or
            sample.source.upload != null or sample.source.external != null or
            sample.destination.width > self.size.width or sample.destination.height > self.size.height or
            sample.crop.x != 0 or sample.crop.y != 0 or
            sample.crop.width != @as(i64, sample.source.size.width) * render.fixed_one or
            sample.crop.height != @as(i64, sample.source.size.height) * render.fixed_one)
            return error.CursorUnsupported;
        const shape = [3]u32{ sample.source.size.width, sample.source.size.height, sample.source.stride };
        const key = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, std.mem.asBytes(&shape)), sample.source.bytes);
        for (self.images[0..self.count], 0..) |image, index|
            if (image.key == key and image.width == sample.destination.width and
                image.height == sample.destination.height) return index;
        if (self.count == capacity) return error.CursorCacheFull;
        const buffer = try self.buffers.createDumb(self.fd, self.size.width, self.size.height, gbm.format_argb8888);
        errdefer self.buffers.destroyDumb(self.fd, buffer);
        if (buffer.stride < self.size.width * 4 or buffer.bytes.len < @as(usize, buffer.stride) * self.size.height)
            return error.InvalidCursorBuffer;
        @memset(buffer.bytes, 0);
        paint(buffer.bytes, buffer.stride, sample);
        const index = self.count;
        self.images[index] = .{ .key = key, .width = sample.destination.width, .height = sample.destination.height, .buffer = buffer };
        self.count += 1;
        return index;
    }

    /// Returns true when the scene should omit its software cursor. Unsupported
    /// shapes/captures use null. A failed hide retains the plane and never adds
    /// a second cursor; a later update can retry detaching it.
    pub fn update(self: *Cursor, sample: ?render.SurfaceSample) bool {
        self.desired = if (!self.failed) if (sample) |value| self.prepare(value) catch null else null else null;
        if (sample) |value| {
            self.x = value.destination.x;
            self.y = value.destination.y;
        }
        if (self.desired == null) {
            self.hide() catch return true;
            return false;
        }
        if (self.primary_clean and self.submitted_clean != false) self.show() catch |err| {
            if (err == error.CursorBusy) return true;
            self.failed = true;
            self.desired = null;
            self.hide() catch return true;
            std.log.warn("hardware cursor unavailable on CRTC {d}; using software cursor", .{self.crtc});
            return false;
        };
        return true;
    }

    fn show(self: *Cursor) !void {
        const index = self.desired orelse return;
        if (self.active == index and self.shown_x == self.x and self.shown_y == self.y) return;
        try self.platform.update_fn(self.platform.context, self.fd, .{
            .crtc = self.crtc,
            .handle = self.images[index].buffer.handle,
            .width = self.size.width,
            .height = self.size.height,
            .x = self.x,
            .y = self.y,
            .image = self.active != index,
        });
        self.active = index;
        self.shown_x = self.x;
        self.shown_y = self.y;
    }

    pub fn hide(self: *Cursor) !void {
        if (self.active == null) return;
        try self.platform.update_fn(self.platform.context, self.fd, .{
            .crtc = self.crtc,
            .handle = 0,
            .width = 0,
            .height = 0,
            .x = 0,
            .y = 0,
            .image = true,
        });
        self.active = null;
    }

    pub fn presented(self: *Cursor) void {
        self.primary_clean = self.submitted_clean orelse false;
        self.submitted_clean = null;
        // The coordinator retries show through update(), where failure can
        // request a software repaint without changing completed-frame state.
    }
};

/// Premultiplied ARGB bilinear resampling, with transparent padding to the
/// kernel's cursor dimensions. Position-only updates never touch these bytes.
fn paint(destination: []u8, stride: u32, sample: render.SurfaceSample) void {
    const width = sample.destination.width;
    const height = sample.destination.height;
    for (0..height) |y| {
        const sy = coordinate(y, sample.source.size.height, height);
        const y0: usize = @intCast(sy >> 16);
        const y1 = @min(y0 + 1, sample.source.size.height - 1);
        for (0..width) |x| {
            const sx = coordinate(x, sample.source.size.width, width);
            const x0: usize = @intCast(sx >> 16);
            const x1 = @min(x0 + 1, sample.source.size.width - 1);
            for (0..4) |channel| {
                const top = lerp(sample.source.bytes[y0 * sample.source.stride + x0 * 4 + channel], sample.source.bytes[y0 * sample.source.stride + x1 * 4 + channel], sx & 65535);
                const bottom = lerp(sample.source.bytes[y1 * sample.source.stride + x0 * 4 + channel], sample.source.bytes[y1 * sample.source.stride + x1 * 4 + channel], sx & 65535);
                destination[y * stride + x * 4 + channel] = @intCast(lerp(top, bottom, sy & 65535));
            }
        }
    }
}

fn coordinate(position: usize, source: u32, destination: u32) u64 {
    const value: i64 = @as(i64, @intCast((2 * position + 1) * source * 32768 / destination)) - 32768;
    return @intCast(std.math.clamp(value, 0, @as(i64, source - 1) * 65536));
}

fn lerp(a: u64, b: u64, fraction: u64) u64 {
    return (a * (65536 - fraction) + b * fraction + 32768) >> 16;
}

const Fake = struct {
    bytes: [4][std.heap.page_size_min]u8 align(std.heap.page_size_min) = undefined,
    created: usize = 0,
    destroyed: usize = 0,
    updates: [16]Update = undefined,
    count: usize = 0,
    reject: bool = false,
    busy: bool = false,

    fn cursor(self: *Fake) !Cursor {
        return Cursor.init(.{ .context = self, .size_fn = size, .update_fn = update }, .{ .context = self, .vtable = &buffer_vtable }, 42, 7);
    }

    fn size(_: ?*anyopaque, _: std.posix.fd_t) !Size {
        return .{ .width = 4, .height = 4 };
    }
    fn update(context: ?*anyopaque, _: std.posix.fd_t, value: Update) !void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        if (self.busy) return error.CursorBusy;
        if (self.reject) return error.CursorUpdateFailed;
        self.updates[self.count] = value;
        self.count += 1;
    }
    const buffer_vtable: framebuffer.Platform.VTable = .{
        .add = add,
        .remove = remove,
        .create_dumb = create,
        .destroy_dumb = destroy,
    };
    fn add(_: *anyopaque, _: std.posix.fd_t, _: gbm.Metadata) !u32 {
        return error.UnexpectedFramebuffer;
    }
    fn remove(_: *anyopaque, _: std.posix.fd_t, _: u32) !void {
        return error.UnexpectedFramebuffer;
    }
    fn create(context: *anyopaque, _: std.posix.fd_t, width: u32, height: u32, format: u32) !framebuffer.DumbBuffer {
        const self: *Fake = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(u32, 4), width);
        try std.testing.expectEqual(@as(u32, 4), height);
        try std.testing.expectEqual(gbm.format_argb8888, format);
        if (self.created == self.bytes.len) return error.Exhausted;
        const index = self.created;
        self.created += 1;
        return .{ .handle = @intCast(index + 1), .stride = 16, .bytes = @alignCast(&self.bytes[index]) };
    }
    fn destroy(context: *anyopaque, _: std.posix.fd_t, _: framebuffer.DumbBuffer) void {
        const self: *Fake = @ptrCast(@alignCast(context));
        self.destroyed += 1;
    }
};

fn testSample(bytes: []const u8) render.SurfaceSample {
    return .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{ .size = .{ .width = 2, .height = 1 }, .stride = 8, .format = .argb8888_premultiplied, .bytes = bytes },
        .crop = render.SourceRect.pixels(0, 0, 2, 1),
        .destination = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
    };
}

test "hardware-cursor: clean scanout handoff and motion bypass an in-flight primary frame" {
    var fake = Fake{};
    var cursor = try fake.cursor();
    const pixels = [_]u8{ 0, 0, 128, 128, 0, 255, 0, 255 };
    var value = testSample(&pixels);
    try std.testing.expect(cursor.update(value));
    try std.testing.expectEqual(@as(usize, 0), fake.count); // Still a software cursor on scanout.
    cursor.submitted_clean = true;
    cursor.presented();
    try std.testing.expect(cursor.update(value));
    try std.testing.expectEqual(@as(usize, 1), fake.count);
    try std.testing.expect(fake.updates[0].image);
    const original = fake.bytes[0];
    cursor.submitted_clean = true; // Unrelated GPU frame is still in flight.
    value.destination.x = -1;
    value.clip.width = 1;
    try std.testing.expect(cursor.update(value));
    try std.testing.expectEqual(@as(i32, -1), fake.updates[1].x);
    try std.testing.expect(!fake.updates[1].image);
    try std.testing.expectEqual(@as(usize, 1), fake.created);
    try std.testing.expectEqualSlices(u8, &original, &fake.bytes[0]);
    try std.testing.expectEqualSlices(u8, &pixels, fake.bytes[0][0..8]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 8), fake.bytes[0][8..16]);
    try std.testing.expect(!cursor.update(null));
    try std.testing.expectEqual(@as(u32, 0), fake.updates[2].handle);
    cursor.deinit();
    try std.testing.expectEqual(fake.created, fake.destroyed);
}

test "hardware-cursor: capture fallback clears plane and waits for software erasure on return" {
    var fake = Fake{};
    var cursor = try fake.cursor();
    defer cursor.deinit();
    const value = testSample(&.{ 0, 0, 255, 255, 0, 255, 0, 255 });
    cursor.primary_clean = true;
    try std.testing.expect(cursor.update(value));
    // Capture uses the normal scene's before/after-cursor partition.
    try std.testing.expect(!cursor.update(null));
    try std.testing.expect(cursor.active == null);
    cursor.submitted_clean = false;
    // A capture may finish delivering before its software frame flips.
    try std.testing.expect(cursor.update(value));
    try std.testing.expect(cursor.active == null);
    cursor.presented();
    try std.testing.expect(cursor.update(value));
    try std.testing.expect(cursor.active == null);
    cursor.submitted_clean = true;
    cursor.presented();
    try std.testing.expect(cursor.update(value));
    try std.testing.expect(cursor.active != null);
    try std.testing.expectEqual(@as(usize, 3), fake.count);
}

test "hardware-cursor: failures cannot silently duplicate a still-visible cursor" {
    var fake = Fake{};
    var cursor = try fake.cursor();
    defer cursor.deinit();
    const value = testSample(&.{ 0, 0, 255, 255, 0, 255, 0, 255 });
    cursor.primary_clean = true;
    fake.busy = true;
    try std.testing.expect(cursor.update(value));
    try std.testing.expect(!cursor.failed);
    fake.busy = false;
    try std.testing.expect(cursor.update(value));
    fake.reject = true;
    try std.testing.expect(cursor.update(null)); // Must not paint software while hide fails.
    try std.testing.expect(cursor.active != null);
    fake.reject = false;
    try std.testing.expect(!cursor.update(null));
    try std.testing.expect(cursor.active == null);
    fake.reject = true;
    try std.testing.expect(!cursor.update(value));
    try std.testing.expect(cursor.failed);
}

test "hardware-cursor: shape cache reuses immutable pixels across theme generations" {
    var fake = Fake{};
    var cursor = try fake.cursor();
    defer cursor.deinit();
    var value = testSample(&.{ 0, 0, 255, 255, 0, 255, 0, 255 });
    try std.testing.expect(cursor.update(value));
    const first = value;
    value.source.bytes = &.{ 0, 0, 0, 255, 255, 255, 255, 255 };
    try std.testing.expect(cursor.update(value));
    value = first;
    value.sample.commit_sequence += 100;
    try std.testing.expect(cursor.update(value));
    try std.testing.expectEqual(@as(usize, 2), fake.created);
    value.destination.width = 5;
    try std.testing.expect(!cursor.update(value));
    try std.testing.expectEqual(@as(usize, 2), fake.created);
}

test "hardware-cursor: fractional image scaling preserves premultiplied alpha and padding" {
    var fake = Fake{};
    var cursor = try fake.cursor();
    defer cursor.deinit();
    var value = testSample(&.{ 0, 0, 128, 128, 0, 0, 0, 0 });
    value.destination.width = 3;
    value.clip.width = 3;
    try std.testing.expect(cursor.update(value));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 128, 128, 0, 0, 64, 64, 0, 0, 0, 0, 0, 0, 0, 0 }, fake.bytes[0][0..16]);
}

test "hardware-cursor: discovery never borrows another output or an ambiguous shared plane" {
    var snapshot: drm.Snapshot = undefined;
    snapshot.selection.crtc_index = 0;
    const crtcs = [_]drm.Crtc{.{ .id = 7, .index = 1, .properties = undefined }};
    snapshot.crtcs = &crtcs;
    var planes = [_]drm.Plane{.{ .id = 10, .possible_crtcs = 2, .plane_type_value = 2, .format_start = 0, .format_count = 0, .properties = undefined }};
    snapshot.planes = &planes;
    try std.testing.expectEqual(@as(u32, 10), selectPlane(snapshot).?.id);
    planes[0].current_crtc_id = 8;
    try std.testing.expect(selectPlane(snapshot) == null);
    planes[0].current_crtc_id = 0;
    planes[0].possible_crtcs = 3;
    try std.testing.expect(selectPlane(snapshot) == null);
    planes[0].current_crtc_id = 7;
    try std.testing.expectEqual(@as(u32, 10), selectPlane(snapshot).?.id);
    planes[0].plane_type_value = 0;
    try std.testing.expect(selectPlane(snapshot) == null);
}
