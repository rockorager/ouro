//! Allocation-free parsing and size selection for Xcursor image files.

const std = @import("std");

/// A bounded, allocator-owned cache of parsed Xcursor files. Cache hits are
/// identified by the exact path bytes; returned images borrow retained files.
pub const Cache = struct {
    pub const Config = struct {
        file_capacity: usize,
        path_capacity: usize,
        max_file_bytes: usize,
        max_total_bytes: usize,
    };

    const Slot = struct {
        path_len: usize = 0,
        bytes: ?[]u8 = null,
    };

    allocator: std.mem.Allocator,
    config: Config,
    slots: []Slot,
    paths: []u8,
    file_count: usize = 0,
    byte_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Cache {
        if (config.file_capacity == 0 or config.path_capacity == 0 or
            config.max_file_bytes == 0 or config.max_total_bytes == 0)
            return error.InvalidConfig;
        const path_bytes = std.math.mul(usize, config.file_capacity, config.path_capacity) catch
            return error.InvalidConfig;
        const slots = try allocator.alloc(Slot, config.file_capacity);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const paths = try allocator.alloc(u8, path_bytes);
        return .{ .allocator = allocator, .config = config, .slots = slots, .paths = paths };
    }

    pub fn deinit(self: *Cache) void {
        for (self.slots) |slot| if (slot.bytes) |bytes| self.allocator.free(bytes);
        self.allocator.free(self.paths);
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn retainedFiles(self: *const Cache) usize {
        return self.file_count;
    }

    pub fn retainedBytes(self: *const Cache) usize {
        return self.byte_count;
    }

    pub fn load(self: *Cache, path: []const u8, requested_size: u32) !Image {
        if (path.len == 0) return error.EmptyPath;
        if (path.len > self.config.path_capacity) return error.PathTooLong;
        for (self.slots, 0..) |slot, i| {
            if (slot.bytes != null and std.mem.eql(u8, path, self.slotPath(i)))
                return select(slot.bytes.?, requested_size);
        }
        const slot_index = for (self.slots, 0..) |slot, i| {
            if (slot.bytes == null) break i;
        } else return error.CacheFull;

        const io = std.Io.Threaded.global_single_threaded.io();
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_only, .allow_directory = true });
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotRegularFile;
        if (stat.size == 0) return error.EmptyFile;
        const len = std.math.cast(usize, stat.size) orelse return error.FileTooLarge;
        if (len > self.config.max_file_bytes) return error.FileTooLarge;
        const new_total = std.math.add(usize, self.byte_count, len) catch return error.TotalBytesExceeded;
        if (new_total > self.config.max_total_bytes) return error.TotalBytesExceeded;

        const bytes = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(bytes);
        var offset: usize = 0;
        while (offset < len) {
            const n = try file.readPositional(io, &.{bytes[offset..]}, offset);
            if (n == 0) return error.UnexpectedEndOfFile;
            offset += n;
        }
        const image = try select(bytes, requested_size);

        const path_start = slot_index * self.config.path_capacity;
        @memcpy(self.paths[path_start..][0..path.len], path);
        self.slots[slot_index] = .{ .path_len = path.len, .bytes = bytes };
        self.file_count += 1;
        self.byte_count = new_total;
        return image;
    }

    fn slotPath(self: *const Cache, index: usize) []const u8 {
        const start = index * self.config.path_capacity;
        return self.paths[start..][0..self.slots[index].path_len];
    }
};

pub const Store = Cache;

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

fn fixtureFile(dir: std.Io.Dir, name: []const u8, fixture: *Fixture) !void {
    const io = std.testing.io;
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, fixture.slice());
}

fn temporaryPath(tmp: *const std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "cursor theme cache: hits retain bytes and sizes share a file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var fixture = Fixture.init(2);
    fixture.toc(24, 40);
    fixture.toc(48, 80);
    fixture.image(24, 1, 1, 0, 0, 24, 0xff000018);
    fixture.image(48, 1, 1, 0, 0, 48, 0xff000030);
    try fixtureFile(tmp.dir, "cursor", &fixture);
    var path_buffer: [128]u8 = undefined;
    const path = try temporaryPath(&tmp, "cursor", &path_buffer);

    var cache = try Cache.init(std.testing.allocator, .{
        .file_capacity = 2,
        .path_capacity = 128,
        .max_file_bytes = 512,
        .max_total_bytes = 512,
    });
    defer cache.deinit();
    const first = try cache.load(path, 24);
    try tmp.dir.deleteFile(std.testing.io, "cursor");
    const second = try cache.load(path, 48);
    try std.testing.expectEqual(@as(u32, 24), first.delay);
    try std.testing.expectEqual(@as(u32, 48), second.delay);
    try std.testing.expectEqual(@as(usize, 1), cache.retainedFiles());
    try std.testing.expectEqual(fixture.len, cache.retainedBytes());
}

test "cursor theme cache: bounds and failed files are transactional" {
    try std.testing.expectError(error.InvalidConfig, Cache.init(std.testing.allocator, .{
        .file_capacity = std.math.maxInt(usize),
        .path_capacity = 2,
        .max_file_bytes = 1,
        .max_total_bytes = 1,
    }));
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var valid = Fixture.init(1);
    valid.toc(24, 28);
    valid.image(24, 1, 1, 0, 0, 24, 0xff000018);
    try fixtureFile(tmp.dir, "one", &valid);
    try fixtureFile(tmp.dir, "two", &valid);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "empty", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad", .data = "bad" });
    var buffer: [128]u8 = undefined;

    var cache = try Cache.init(std.testing.allocator, .{
        .file_capacity = 2,
        .path_capacity = 128,
        .max_file_bytes = 512,
        .max_total_bytes = valid.len,
    });
    defer cache.deinit();
    try std.testing.expectError(error.EmptyPath, cache.load("", 24));
    try std.testing.expectError(error.EmptyFile, cache.load(try temporaryPath(&tmp, "empty", &buffer), 24));
    try std.testing.expectError(error.InvalidFormat, cache.load(try temporaryPath(&tmp, "bad", &buffer), 24));
    try std.testing.expectError(error.NotRegularFile, cache.load(try temporaryPath(&tmp, ".", &buffer), 24));
    try std.testing.expectEqual(@as(usize, 0), cache.retainedFiles());
    _ = try cache.load(try temporaryPath(&tmp, "one", &buffer), 24);
    try std.testing.expectError(error.TotalBytesExceeded, cache.load(try temporaryPath(&tmp, "two", &buffer), 24));
    try std.testing.expectEqual(@as(usize, 1), cache.retainedFiles());
    try std.testing.expectEqual(valid.len, cache.retainedBytes());
}
