//! Dynamically-sized publication of validated applied content for renderers.
//!
//! The builder publishes validated sample metadata and can either copy source
//! pixels into its preallocated byte arena or borrow caller-owned stable bytes.
//! Returned lists borrow the builder until its next successful publication or
//! `deinit`; borrowed source bytes must additionally remain stable while used.

const std = @import("std");
const render = @import("../render/types.zig");

pub const AppliedSurface = render.SurfaceSample;

pub const Error = std.mem.Allocator.Error || render.ValidationError || error{
    InvalidConfig,
    ByteCapacityExceeded,
    DuplicateSampleIdentity,
};

pub const Builder = struct {
    allocator: std.mem.Allocator,
    samples: []render.SurfaceSample,
    bytes: []u8,
    sample_count: usize = 0,
    byte_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        sample_capacity: usize,
        byte_capacity: usize,
    ) Error!Builder {
        if (sample_capacity == 0 or byte_capacity == 0)
            return error.InvalidConfig;
        const samples = try allocator.alloc(render.SurfaceSample, sample_capacity);
        errdefer allocator.free(samples);
        const bytes = try allocator.alloc(u8, byte_capacity);
        return .{ .allocator = allocator, .samples = samples, .bytes = bytes };
    }

    pub fn initBorrowed(allocator: std.mem.Allocator, sample_capacity: usize) Error!Builder {
        if (sample_capacity == 0) return error.InvalidConfig;
        const samples = try allocator.alloc(render.SurfaceSample, sample_capacity);
        errdefer allocator.free(samples);
        const bytes = try allocator.alloc(u8, 0);
        return .{ .allocator = allocator, .samples = samples, .bytes = bytes };
    }

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: Builder) usize {
        return self.samples.len * @sizeOf(render.SurfaceSample) + self.bytes.len;
    }

    fn validateCandidate(
        self: Builder,
        output: render.Size,
        applied: []const AppliedSurface,
        copy_sources: bool,
    ) Error!void {
        try render.validateOutput(output);
        var required_bytes: usize = 0;
        for (applied, 0..) |surface, index| {
            const length = try render.validateSample(surface);
            if (copy_sources) {
                required_bytes = std.math.add(usize, required_bytes, length) catch
                    return error.ByteCapacityExceeded;
                if (required_bytes > self.bytes.len)
                    return error.ByteCapacityExceeded;
            }
            for (applied[0..index]) |earlier| {
                if (std.meta.eql(earlier.sample, surface.sample))
                    return error.DuplicateSampleIdentity;
            }
        }
    }

    /// Validates the entire candidate before publishing or copying anything.
    /// Source padding is retained; renderers may not assume tightly packed rows.
    pub fn build(
        self: *Builder,
        output: render.Size,
        output_format: render.PixelFormat,
        clear: render.Color,
        applied: []const AppliedSurface,
    ) Error!render.List {
        try self.validateCandidate(output, applied, true);
        if (applied.len > self.samples.len)
            self.samples = try self.allocator.realloc(self.samples, applied.len);

        var offset: usize = 0;
        for (applied, 0..) |surface, index| {
            const length: usize = @as(usize, surface.source.stride) * surface.source.size.height;
            @memcpy(self.bytes[offset..][0..length], surface.source.bytes[0..length]);
            self.samples[index] = surface;
            self.samples[index].source.bytes = self.bytes[offset..][0..length];
            offset += length;
        }
        self.sample_count = applied.len;
        self.byte_count = offset;
        return .{
            .output = output,
            .output_format = output_format,
            .clear = clear,
            .samples = self.samples[0..self.sample_count],
        };
    }

    /// Publishes validated metadata without copying already-owned source bytes.
    /// The caller must keep every source stable until the renderer has consumed
    /// the returned list.
    pub fn buildBorrowed(
        self: *Builder,
        output: render.Size,
        output_format: render.PixelFormat,
        clear: render.Color,
        applied: []const AppliedSurface,
    ) Error!render.List {
        try self.validateCandidate(output, applied, false);
        if (applied.len > self.samples.len)
            self.samples = try self.allocator.realloc(self.samples, applied.len);
        @memcpy(self.samples[0..applied.len], applied);
        self.sample_count = applied.len;
        self.byte_count = 0;
        return .{
            .output = output,
            .output_format = output_format,
            .clear = clear,
            .samples = self.samples[0..self.sample_count],
        };
    }
};

fn validSample(bytes: []const u8) AppliedSurface {
    return .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .xrgb8888,
            .bytes = bytes,
        },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
}

test "render: list publication copies bytes and is transactional" {
    var builder = try Builder.init(std.testing.allocator, 1, 8);
    defer builder.deinit();
    var source = [_]u8{ 1, 2, 3, 4 };
    const list = try builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{validSample(&source)});
    source = [_]u8{ 9, 9, 9, 9 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, list.samples[0].source.bytes);

    var malformed = validSample(&source);
    malformed.source.stride = 3;
    try std.testing.expectError(error.InvalidSource, builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{malformed}));
    malformed = validSample(&source);
    malformed.upload_damage = .{
        .rects = [_]render.UploadRect{
            .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 },
            .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 },
        } ++ [_]render.UploadRect{.{}} ** (render.upload_damage_rect_capacity - 2),
        .count = 2,
    };
    try std.testing.expectError(error.InvalidSource, builder.build(
        .{ .width = 1, .height = 1 },
        .xrgb8888,
        .{ .r = 0, .g = 0, .b = 0 },
        &.{malformed},
    ));
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, list.samples[0].source.bytes);
}

test "render: borrowed list publication retains stable source bytes" {
    var builder = try Builder.initBorrowed(std.testing.allocator, 1);
    defer builder.deinit();
    var source = [_]u8{ 1, 2, 3, 4 };
    const list = try builder.buildBorrowed(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{validSample(&source)});
    source = [_]u8{ 9, 9, 9, 9 };
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, list.samples[0].source.bytes);

    var malformed = validSample(&source);
    malformed.source.stride = 3;
    try std.testing.expectError(error.InvalidSource, builder.buildBorrowed(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{malformed}));
    try std.testing.expectEqualSlices(u8, &.{ 9, 9, 9, 9 }, list.samples[0].source.bytes);
}

test "render: list rejects identity geometry and byte capacity" {
    var builder = try Builder.init(std.testing.allocator, 1, 4);
    defer builder.deinit();
    const bytes = [_]u8{0} ** 8;
    var sample = validSample(&bytes);
    sample.sample.surface = 0;
    try std.testing.expectError(error.InvalidIdentity, builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{sample}));
    sample = validSample(&bytes);
    sample.crop.width = 2 * render.fixed_one;
    try std.testing.expectError(error.InvalidCrop, builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{sample}));
    sample = validSample(&bytes);
    sample.source.size.height = 2;
    try std.testing.expectError(error.ByteCapacityExceeded, builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{sample}));
}

test "render: list sample metadata grows beyond initial capacity" {
    var builder = try Builder.initBorrowed(std.testing.allocator, 1);
    defer builder.deinit();
    const bytes = [_]u8{ 0, 0, 0, 0 };
    var samples = [_]AppliedSurface{ validSample(&bytes), validSample(&bytes) };
    samples[1].sample.surface = 2;
    const list = try builder.buildBorrowed(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &samples);
    try std.testing.expectEqual(@as(usize, 2), list.samples.len);
    try std.testing.expect(builder.samples.len >= 2);
}
