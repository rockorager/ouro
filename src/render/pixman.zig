//! Cached Pixman objects for deterministic CPU composition.
//!
//! Ouro allocates all cache records and source backing during `init`; `draw`
//! performs no Ouro allocator calls. Pixman allocates its image wrappers
//! internally: source and alpha-mask wrappers live for the renderer lifetime,
//! while one destination wrapper is necessarily created around each transient
//! R10 mapping and released before unmap. Sampling is nearest-neighbour.

const std = @import("std");
const render = @import("types.zig");

const c = @cImport({
    @cInclude("pixman.h");
});

pub const Config = struct {
    max_samples: usize,
    max_source_width: u32,
    max_source_height: u32,
};

pub const Error = std.mem.Allocator.Error || render.ValidationError || error{
    InvalidConfig,
    SampleCapacityExceeded,
    SourceCapacityExceeded,
    InvalidTarget,
    PixmanImageFailed,
    PixmanTransformFailed,
    PixmanFilterFailed,
};

const Cache = struct {
    argb: *c.pixman_image_t,
    xrgb: *c.pixman_image_t,
    mask: *c.pixman_image_t,
    mask_value: *u32,
    pixels: []u32,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    caches: []Cache,
    source_pixels: []u32,
    mask_values: []u32,
    max_source_width: u32,
    max_source_height: u32,
    source_stride: u32,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Renderer {
        if (config.max_samples == 0 or config.max_source_width == 0 or
            config.max_source_height == 0 or config.max_samples > std.math.maxInt(u32) or
            config.max_source_width > std.math.maxInt(i32) or
            config.max_source_height > std.math.maxInt(i32))
            return error.InvalidConfig;
        const pixels_per_source = std.math.mul(
            usize,
            config.max_source_width,
            config.max_source_height,
        ) catch return error.InvalidConfig;
        const pixel_count = std.math.mul(usize, pixels_per_source, config.max_samples) catch
            return error.InvalidConfig;
        const stride = std.math.mul(u32, config.max_source_width, 4) catch
            return error.InvalidConfig;
        if (stride > std.math.maxInt(i32)) return error.InvalidConfig;

        const caches = try allocator.alloc(Cache, config.max_samples);
        errdefer allocator.free(caches);
        const pixels = try allocator.alloc(u32, pixel_count);
        errdefer allocator.free(pixels);
        const masks = try allocator.alloc(u32, config.max_samples);
        errdefer allocator.free(masks);
        @memset(pixels, 0);
        @memset(masks, 255);

        var initialized: usize = 0;
        errdefer deinitCaches(caches[0..initialized]);
        while (initialized < caches.len) : (initialized += 1) {
            const slot_pixels = pixels[initialized * pixels_per_source .. (initialized + 1) * pixels_per_source];
            const argb = c.pixman_image_create_bits(
                c.PIXMAN_a8r8g8b8,
                @intCast(config.max_source_width),
                @intCast(config.max_source_height),
                slot_pixels.ptr,
                @intCast(stride),
            ) orelse return error.PixmanImageFailed;
            errdefer _ = c.pixman_image_unref(argb);
            const xrgb = c.pixman_image_create_bits(
                c.PIXMAN_x8r8g8b8,
                @intCast(config.max_source_width),
                @intCast(config.max_source_height),
                slot_pixels.ptr,
                @intCast(stride),
            ) orelse return error.PixmanImageFailed;
            errdefer _ = c.pixman_image_unref(xrgb);
            const mask = c.pixman_image_create_bits(
                c.PIXMAN_a8,
                1,
                1,
                @ptrCast(&masks[initialized]),
                4,
            ) orelse return error.PixmanImageFailed;
            c.pixman_image_set_repeat(mask, c.PIXMAN_REPEAT_NORMAL);
            caches[initialized] = .{
                .argb = argb,
                .xrgb = xrgb,
                .mask = mask,
                .mask_value = &masks[initialized],
                .pixels = slot_pixels,
            };
        }
        return .{
            .allocator = allocator,
            .caches = caches,
            .source_pixels = pixels,
            .mask_values = masks,
            .max_source_width = config.max_source_width,
            .max_source_height = config.max_source_height,
            .source_stride = stride,
        };
    }

    pub fn deinit(self: *Renderer) void {
        deinitCaches(self.caches);
        self.allocator.free(self.mask_values);
        self.allocator.free(self.source_pixels);
        self.allocator.free(self.caches);
        self.* = undefined;
    }

    pub fn draw(
        self: *Renderer,
        list: render.List,
        destination_bytes: []u8,
        destination_stride: u32,
    ) Error!void {
        if (list.samples.len > self.caches.len)
            return error.SampleCapacityExceeded;
        try render.validateList(list);
        for (list.samples) |sample| {
            if (sample.source.size.width > self.max_source_width or
                sample.source.size.height > self.max_source_height)
                return error.SourceCapacityExceeded;
        }
        const row_bytes = std.math.mul(u32, list.output.width, 4) catch
            return error.InvalidTarget;
        const destination_length = std.math.mul(usize, destination_stride, list.output.height) catch
            return error.InvalidTarget;
        if (destination_stride < row_bytes or destination_bytes.len < destination_length or
            @intFromPtr(destination_bytes.ptr) % @alignOf(u32) != 0 or
            list.output.width > std.math.maxInt(i32) or
            list.output.height > std.math.maxInt(i32) or
            destination_stride > std.math.maxInt(i32))
            return error.InvalidTarget;

        const destination = c.pixman_image_create_bits(
            pixmanFormat(list.output_format),
            @intCast(list.output.width),
            @intCast(list.output.height),
            @ptrCast(@alignCast(destination_bytes.ptr)),
            @intCast(destination_stride),
        ) orelse return error.PixmanImageFailed;
        defer _ = c.pixman_image_unref(destination);

        clearTarget(
            destination_bytes,
            destination_stride,
            list.output,
            list.output_format,
            list.clear,
        );

        for (list.samples, 0..) |sample, index| {
            const cache = &self.caches[index];
            copySource(cache, self.source_stride, sample.source);
            cache.mask_value.* = sample.global_alpha;
            const source = switch (sample.source.format) {
                .argb8888_premultiplied => cache.argb,
                .xrgb8888 => cache.xrgb,
            };
            var transform = sampleTransform(sample);
            if (c.pixman_image_set_transform(source, &transform) == 0)
                return error.PixmanTransformFailed;
            if (c.pixman_image_set_filter(source, c.PIXMAN_FILTER_NEAREST, null, 0) == 0)
                return error.PixmanFilterFailed;

            const clipped = intersection(sample.destination, sample.clip, list.output) orelse
                continue;
            c.pixman_image_composite32(
                c.PIXMAN_OP_OVER,
                source,
                cache.mask,
                destination,
                clipped.x - sample.destination.x,
                clipped.y - sample.destination.y,
                0,
                0,
                clipped.x,
                clipped.y,
                @intCast(clipped.width),
                @intCast(clipped.height),
            );
        }
    }
};

fn deinitCaches(caches: []Cache) void {
    var index = caches.len;
    while (index != 0) {
        index -= 1;
        _ = c.pixman_image_unref(caches[index].mask);
        _ = c.pixman_image_unref(caches[index].xrgb);
        _ = c.pixman_image_unref(caches[index].argb);
    }
}

fn copySource(cache: *Cache, cache_stride: u32, source: render.Source) void {
    const row_bytes: usize = @as(usize, source.size.width) * 4;
    for (0..source.size.height) |row| {
        const source_start = @as(usize, source.stride) * row;
        const destination_start = @as(usize, cache_stride) * row;
        const destination: [*]u8 = @ptrCast(cache.pixels.ptr);
        @memcpy(
            destination[destination_start..][0..row_bytes],
            source.bytes[source_start..][0..row_bytes],
        );
    }
}

fn pixmanFormat(format: render.PixelFormat) c.pixman_format_code_t {
    return switch (format) {
        .argb8888_premultiplied => c.PIXMAN_a8r8g8b8,
        .xrgb8888 => c.PIXMAN_x8r8g8b8,
    };
}

fn clearTarget(
    bytes: []u8,
    stride: u32,
    size: render.Size,
    format: render.PixelFormat,
    color: render.Color,
) void {
    const alpha: u8 = if (format == .xrgb8888) 255 else color.a;
    const red = premultiply(color.r, alpha);
    const green = premultiply(color.g, alpha);
    const blue = premultiply(color.b, alpha);
    for (0..size.height) |row| {
        const start = @as(usize, stride) * row;
        for (0..size.width) |column| {
            const offset = start + column * 4;
            bytes[offset] = blue;
            bytes[offset + 1] = green;
            bytes[offset + 2] = red;
            bytes[offset + 3] = alpha;
        }
    }
}

fn premultiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

fn sampleTransform(sample: render.SurfaceSample) c.pixman_transform_t {
    const swaps_axes = switch (sample.transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
    const source_x_denominator = if (swaps_axes)
        sample.destination.height
    else
        sample.destination.width;
    const source_y_denominator = if (swaps_axes)
        sample.destination.width
    else
        sample.destination.height;
    const sx = @divTrunc(@as(i64, sample.crop.width), source_x_denominator);
    const sy = @divTrunc(@as(i64, sample.crop.height), source_y_denominator);
    const x = sample.crop.x;
    const y = sample.crop.y;
    const right = x + sample.crop.width;
    const bottom = y + sample.crop.height;
    var result: c.pixman_transform_t = undefined;
    c.pixman_transform_init_identity(&result);
    switch (sample.transform) {
        .normal => setAffine(&result, sx, 0, x, 0, sy, y),
        .@"90" => setAffine(&result, 0, -sx, right, sy, 0, y),
        .@"180" => setAffine(&result, -sx, 0, right, 0, -sy, bottom),
        .@"270" => setAffine(&result, 0, sx, x, -sy, 0, bottom),
        .flipped => setAffine(&result, -sx, 0, right, 0, sy, y),
        .flipped_90 => setAffine(&result, 0, sx, x, sy, 0, y),
        .flipped_180 => setAffine(&result, sx, 0, x, 0, -sy, bottom),
        .flipped_270 => setAffine(&result, 0, -sx, right, -sy, 0, bottom),
    }
    return result;
}

fn setAffine(
    transform: *c.pixman_transform_t,
    xx: i64,
    xy: i64,
    x0: i64,
    yx: i64,
    yy: i64,
    y0: i64,
) void {
    transform.matrix[0][0] = @intCast(xx);
    transform.matrix[0][1] = @intCast(xy);
    transform.matrix[0][2] = @intCast(x0);
    transform.matrix[1][0] = @intCast(yx);
    transform.matrix[1][1] = @intCast(yy);
    transform.matrix[1][2] = @intCast(y0);
}

const CompositeRect = struct { x: i32, y: i32, width: u32, height: u32 };

fn intersection(destination: render.Rect, clip: render.Rect, output: render.Size) ?CompositeRect {
    const left = @max(destination.x, clip.x, 0);
    const top = @max(destination.y, clip.y, 0);
    const right = @min(
        @as(i64, destination.x) + destination.width,
        @as(i64, clip.x) + clip.width,
        output.width,
    );
    const bottom = @min(
        @as(i64, destination.y) + destination.height,
        @as(i64, clip.y) + clip.height,
        output.height,
    );
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}
