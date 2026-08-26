//! Allocation-free parsing and size selection for Xcursor image files.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    x_hotspot: u32,
    y_hotspot: u32,
    delay: u32,
    /// Premultiplied ARGB8888 pixels, represented as B, G, R, A bytes.
    pixels: []const u8,
};

pub const Error = error{
    InvalidSize,
    InvalidFormat,
    NoImage,
};

const image_type: u32 = 0xfffd0002;

/// Selects the first frame at the nominal size nearest `requested_size`.
/// Equal distances prefer the smaller nominal size. The returned pixels borrow
/// `bytes`; Xcursor pixels are exposed in renderer-friendly BGRA byte order.
pub fn select(bytes: []const u8, requested_size: u32) Error!Image {
    if (requested_size == 0) return error.InvalidSize;
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "Xcur"))
        return error.InvalidFormat;

    const header = readU32(bytes, 4) orelse return error.InvalidFormat;
    const version = readU32(bytes, 8) orelse return error.InvalidFormat;
    const toc_count = readU32(bytes, 12) orelse return error.InvalidFormat;
    if (header < 16 or version != 0x0001_0000) return error.InvalidFormat;
    const toc_start: usize = header;
    const toc_bytes = std.math.mul(usize, toc_count, 12) catch return error.InvalidFormat;
    const toc_end = std.math.add(usize, toc_start, toc_bytes) catch return error.InvalidFormat;
    if (toc_end > bytes.len) return error.InvalidFormat;

    var best: ?Image = null;
    var best_subtype: u32 = 0;
    var i: usize = 0;
    while (i < toc_count) : (i += 1) {
        const entry = toc_start + i * 12;
        const kind = readU32(bytes, entry) orelse unreachable;
        if (kind != image_type) continue;
        const subtype = readU32(bytes, entry + 4) orelse unreachable;
        const position = readU32(bytes, entry + 8) orelse unreachable;
        if (subtype == 0) return error.InvalidFormat;
        const image = try parseImage(bytes, toc_start, toc_count, toc_end, subtype, position);

        if (best == null or closer(subtype, best_subtype, requested_size)) {
            best = image;
            best_subtype = subtype;
        }
    }
    return best orelse error.NoImage;
}

fn parseImage(
    bytes: []const u8,
    toc_start: usize,
    toc_count: u32,
    toc_end: usize,
    subtype: u32,
    position_u32: u32,
) Error!Image {
    const position: usize = position_u32;
    if (position < toc_end) return error.InvalidFormat;
    const fixed_end = std.math.add(usize, position, 36) catch return error.InvalidFormat;
    if (fixed_end > bytes.len) return error.InvalidFormat;
    const chunk_header = readU32(bytes, position) orelse unreachable;
    const kind = readU32(bytes, position + 4) orelse unreachable;
    const chunk_subtype = readU32(bytes, position + 8) orelse unreachable;
    const version = readU32(bytes, position + 12) orelse unreachable;
    if (chunk_header < 36 or kind != image_type or chunk_subtype != subtype or version != 1)
        return error.InvalidFormat;

    const width = readU32(bytes, position + 16) orelse unreachable;
    const height = readU32(bytes, position + 20) orelse unreachable;
    const x_hotspot = readU32(bytes, position + 24) orelse unreachable;
    const y_hotspot = readU32(bytes, position + 28) orelse unreachable;
    const delay = readU32(bytes, position + 32) orelse unreachable;
    if (width == 0 or height == 0 or x_hotspot >= width or y_hotspot >= height)
        return error.InvalidFormat;

    const pixel_count = std.math.mul(usize, width, height) catch return error.InvalidFormat;
    const pixel_bytes = std.math.mul(usize, pixel_count, 4) catch return error.InvalidFormat;
    const pixel_start = std.math.add(usize, position, chunk_header) catch return error.InvalidFormat;
    const pixel_end = std.math.add(usize, pixel_start, pixel_bytes) catch return error.InvalidFormat;

    // A chunk ends at the next chunk position (TOCs need not be sorted).
    var chunk_end = bytes.len;
    var i: usize = 0;
    while (i < toc_count) : (i += 1) {
        const other: usize = readU32(bytes, toc_start + i * 12 + 8) orelse unreachable;
        if (other > position and other < chunk_end) chunk_end = other;
    }
    if (pixel_start < fixed_end or pixel_end != chunk_end) return error.InvalidFormat;

    return .{
        .width = width,
        .height = height,
        .x_hotspot = x_hotspot,
        .y_hotspot = y_hotspot,
        .delay = delay,
        .pixels = bytes[pixel_start..pixel_end],
    };
}

fn closer(candidate: u32, current: u32, requested: u32) bool {
    const candidate_distance = if (candidate > requested) candidate - requested else requested - candidate;
    const current_distance = if (current > requested) current - requested else requested - current;
    return candidate_distance < current_distance or
        (candidate_distance == current_distance and candidate < current);
}

fn readU32(bytes: []const u8, offset: usize) ?u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return null;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}

const Fixture = struct {
    bytes: [512]u8 = [_]u8{0} ** 512,
    len: usize = 0,

    fn init(count: u32) Fixture {
        var fixture: Fixture = .{};
        fixture.putBytes("Xcur");
        fixture.put(16);
        fixture.put(0x0001_0000);
        fixture.put(count);
        return fixture;
    }

    fn put(self: *Fixture, value: u32) void {
        std.mem.writeInt(u32, self.bytes[self.len..][0..4], value, .little);
        self.len += 4;
    }

    fn putBytes(self: *Fixture, value: []const u8) void {
        @memcpy(self.bytes[self.len..][0..value.len], value);
        self.len += value.len;
    }

    fn toc(self: *Fixture, subtype: u32, position: u32) void {
        self.put(image_type);
        self.put(subtype);
        self.put(position);
    }

    fn image(self: *Fixture, subtype: u32, width: u32, height: u32, hot_x: u32, hot_y: u32, delay: u32, pixel: u32) void {
        self.put(36);
        self.put(image_type);
        self.put(subtype);
        self.put(1);
        self.put(width);
        self.put(height);
        self.put(hot_x);
        self.put(hot_y);
        self.put(delay);
        var n: u32 = 0;
        while (n < width * height) : (n += 1) self.put(pixel);
    }

    fn slice(self: *Fixture) []const u8 {
        return self.bytes[0..self.len];
    }
};

test "cursor theme: exact and nearest size with smaller tie" {
    var fixture = Fixture.init(3);
    fixture.toc(24, 52);
    fixture.toc(32, 92);
    fixture.toc(48, 132);
    fixture.image(24, 1, 1, 0, 0, 24, 0xff000018);
    fixture.image(32, 1, 1, 0, 0, 32, 0xff000020);
    fixture.image(48, 1, 1, 0, 0, 48, 0xff000030);
    try std.testing.expectEqual(@as(u32, 32), (try select(fixture.slice(), 32)).delay);
    try std.testing.expectEqual(@as(u32, 32), (try select(fixture.slice(), 40)).delay);
    try std.testing.expectEqual(@as(u32, 48), (try select(fixture.slice(), 46)).delay);
}

test "cursor theme: first frame and renderer byte order" {
    var fixture = Fixture.init(2);
    fixture.toc(24, 40);
    fixture.toc(24, 80);
    fixture.image(24, 1, 1, 0, 0, 7, 0x80402010);
    fixture.image(24, 1, 1, 0, 0, 9, 0xff000000);
    const image = try select(fixture.slice(), 24);
    try std.testing.expectEqual(@as(u32, 7), image.delay);
    try std.testing.expectEqualSlices(u8, &.{ 0x10, 0x20, 0x40, 0x80 }, image.pixels);
}

test "cursor theme: rejects malformed headers, TOCs, and chunks" {
    var fixture = Fixture.init(1);
    fixture.toc(24, 28);
    fixture.image(24, 1, 1, 0, 0, 0, 0);
    try std.testing.expectError(error.InvalidSize, select(fixture.slice(), 0));
    fixture.bytes[0] = 'x';
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    fixture.bytes[0] = 'X';
    std.mem.writeInt(u32, fixture.bytes[12..16], 2, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[12..16], 1, .little);
    std.mem.writeInt(u32, fixture.bytes[24..28], 27, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[24..28], 28, .little);
    std.mem.writeInt(u32, fixture.bytes[32..36], 0, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[32..36], image_type, .little);
    std.mem.writeInt(u32, fixture.bytes[36..40], 23, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[36..40], 24, .little);
    std.mem.writeInt(u32, fixture.bytes[40..44], 2, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
}

test "cursor theme: rejects pixels, hotspot, dimensions, and arithmetic overflow" {
    var fixture = Fixture.init(1);
    fixture.toc(24, 28);
    fixture.image(24, 1, 1, 0, 0, 0, 0);
    fixture.len -= 1;
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    fixture.len += 1;
    std.mem.writeInt(u32, fixture.bytes[52..56], 1, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[52..56], 0, .little);
    std.mem.writeInt(u32, fixture.bytes[44..48], 0, .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
    std.mem.writeInt(u32, fixture.bytes[44..48], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, fixture.bytes[48..52], std.math.maxInt(u32), .little);
    try std.testing.expectError(error.InvalidFormat, select(fixture.slice(), 24));
}
