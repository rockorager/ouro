//! Fixed-capacity publication of validated applied content for renderers.
//!
//! The builder copies source pixels into its own preallocated byte arena. Thus
//! neither Wayring resource handles nor callback-lifetime SHM mappings cross
//! the scene/renderer boundary. Returned lists borrow the builder until the
//! next successful `build` or `deinit`.

const std = @import("std");
const render = @import("../render/types.zig");

pub const AppliedSurface = render.SurfaceSample;

pub const Error = std.mem.Allocator.Error || render.ValidationError || error{
    InvalidConfig,
    SampleCapacityExceeded,
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

    pub fn deinit(self: *Builder) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: Builder) usize {
        return self.samples.len * @sizeOf(render.SurfaceSample) + self.bytes.len;
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
        try render.validateOutput(output);
        if (applied.len > self.samples.len)
            return error.SampleCapacityExceeded;

        var required_bytes: usize = 0;
        for (applied, 0..) |surface, index| {
            const length = try render.validateSample(surface);
            required_bytes = std.math.add(usize, required_bytes, length) catch
                return error.ByteCapacityExceeded;
            if (required_bytes > self.bytes.len)
                return error.ByteCapacityExceeded;
            for (applied[0..index]) |earlier| {
                if (std.meta.eql(earlier.sample, surface.sample))
                    return error.DuplicateSampleIdentity;
            }
        }

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
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, list.samples[0].source.bytes);
}

test "render: list rejects identity geometry byte and sample capacities" {
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
    try std.testing.expectError(error.SampleCapacityExceeded, builder.build(.{ .width = 1, .height = 1 }, .xrgb8888, .{ .r = 0, .g = 0, .b = 0 }, &.{ validSample(&bytes), validSample(&bytes) }));
}
