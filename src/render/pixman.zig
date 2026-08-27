//! Pixman CPU composition over renderer-owned source bytes.
//!
//! Source bytes are immutable for the synchronous draw call, so Pixman wraps
//! them directly instead of copying every sample into a maximum-sized cache.
//! Only bounded alpha-mask wrappers live for the renderer lifetime. Source and
//! destination wrappers are released before their borrowed storage can change.
//! Sampling is nearest-neighbour and output writes are clipped to R13 damage.

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

/// Compositor-owned tightly described readback storage. Protocol buffers are
/// never passed to a renderer; the output path copies this result into guarded
/// client storage only after the matching frame is presented.
pub const Readback = struct {
    bytes: []u8,
    stride: u32,
};

pub const Error = std.mem.Allocator.Error || render.ValidationError || error{
    InvalidConfig,
    SampleCapacityExceeded,
    SourceCapacityExceeded,
    InvalidSourceIndex,
    PlannedIdentityMismatch,
    InvalidTarget,
    PixmanImageFailed,
    PixmanRegionFailed,
    PixmanTransformFailed,
    PixmanFilterFailed,
};

const Cache = struct {
    mask: *c.pixman_image_t,
    mask_value: u32,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    caches: []Cache,
    max_source_width: u32,
    max_source_height: u32,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!Renderer {
        if (config.max_samples == 0 or config.max_source_width == 0 or
            config.max_source_height == 0 or config.max_samples > std.math.maxInt(u32) or
            config.max_source_width > std.math.maxInt(i32) or
            config.max_source_height > std.math.maxInt(i32))
            return error.InvalidConfig;
        const stride = std.math.mul(u32, config.max_source_width, 4) catch
            return error.InvalidConfig;
        if (stride > std.math.maxInt(i32)) return error.InvalidConfig;

        const caches = try allocator.alloc(Cache, config.max_samples);
        errdefer allocator.free(caches);

        var initialized: usize = 0;
        errdefer deinitCaches(caches[0..initialized]);
        while (initialized < caches.len) : (initialized += 1) {
            caches[initialized].mask_value = 255;
            const mask = c.pixman_image_create_bits(
                c.PIXMAN_a8,
                1,
                1,
                @ptrCast(&caches[initialized].mask_value),
                4,
            ) orelse return error.PixmanImageFailed;
            c.pixman_image_set_repeat(mask, c.PIXMAN_REPEAT_NORMAL);
            caches[initialized].mask = mask;
        }
        return .{
            .allocator = allocator,
            .caches = caches,
            .max_source_width = config.max_source_width,
            .max_source_height = config.max_source_height,
        };
    }

    pub fn deinit(self: *Renderer) void {
        deinitCaches(self.caches);
        self.allocator.free(self.caches);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: Renderer) usize {
        return self.caches.len * @sizeOf(Cache);
    }

    pub fn draw(
        self: *Renderer,
        list: render.List,
        plan: render.DamagePlan,
        destination_bytes: []u8,
        destination_stride: u32,
    ) Error!void {
        try self.drawPhased(
            list,
            plan,
            destination_bytes,
            destination_stride,
            list.samples.len,
            null,
            null,
        );
    }

    /// Draws samples below `cursor_start`, snapshots that exact composition,
    /// then draws the remaining cursor samples and optionally snapshots again.
    /// Both snapshots are full-output copies even when this frame repairs only
    /// a damaged subset: unchanged target pixels contain the prior frame.
    pub fn drawPhased(
        self: *Renderer,
        list: render.List,
        plan: render.DamagePlan,
        destination_bytes: []u8,
        destination_stride: u32,
        cursor_start: usize,
        before_cursor: ?Readback,
        after_cursor: ?Readback,
    ) Error!void {
        if (list.samples.len > self.caches.len or plan.samples.len > self.caches.len)
            return error.SampleCapacityExceeded;
        if (cursor_start > list.samples.len) return error.InvalidSourceIndex;
        try render.validateList(list);
        try render.validateOutput(plan.output);
        for (list.samples) |sample| {
            if (sample.source.size.width > self.max_source_width or
                sample.source.size.height > self.max_source_height)
                return error.SourceCapacityExceeded;
        }
        const row_bytes = std.math.mul(u32, plan.output.width, 4) catch
            return error.InvalidTarget;
        const destination_length = std.math.mul(usize, destination_stride, plan.output.height) catch
            return error.InvalidTarget;
        if (destination_stride < row_bytes or destination_bytes.len < destination_length or
            @intFromPtr(destination_bytes.ptr) % @alignOf(u32) != 0 or
            plan.output.width > std.math.maxInt(i32) or
            plan.output.height > std.math.maxInt(i32) or
            destination_stride > std.math.maxInt(i32))
            return error.InvalidTarget;
        if (before_cursor) |readback| try validateReadback(readback, plan.output);
        if (after_cursor) |readback| try validateReadback(readback, plan.output);

        const destination = c.pixman_image_create_bits(
            pixmanFormat(list.output_format),
            @intCast(plan.output.width),
            @intCast(plan.output.height),
            @ptrCast(@alignCast(destination_bytes.ptr)),
            @intCast(destination_stride),
        ) orelse return error.PixmanImageFailed;
        defer _ = c.pixman_image_unref(destination);

        var damage = c.pixman_region32_t{};
        c.pixman_region32_init(&damage);
        defer c.pixman_region32_fini(&damage);
        if (plan.render_full) {
            if (c.pixman_region32_union_rect(
                &damage,
                &damage,
                0,
                0,
                plan.output.width,
                plan.output.height,
            ) == 0) return error.PixmanRegionFailed;
        } else for (plan.render_damage) |value| {
            const clipped = intersection(value, value, plan.output) orelse continue;
            if (c.pixman_region32_union_rect(
                &damage,
                &damage,
                clipped.x,
                clipped.y,
                clipped.width,
                clipped.height,
            ) == 0) return error.PixmanRegionFailed;
        }
        const draws = c.pixman_region32_not_empty(&damage) != 0;
        if (draws) {
            if (c.pixman_image_set_clip_region32(destination, &damage) == 0)
                return error.PixmanRegionFailed;

            const alpha: u8 = if (list.output_format == .xrgb8888) 255 else list.clear.a;
            var clear_color = c.pixman_color_t{
                .red = @as(u16, premultiply(list.clear.r, alpha)) * 257,
                .green = @as(u16, premultiply(list.clear.g, alpha)) * 257,
                .blue = @as(u16, premultiply(list.clear.b, alpha)) * 257,
                .alpha = @as(u16, alpha) * 257,
            };
            const clear = c.pixman_image_create_solid_fill(&clear_color) orelse
                return error.PixmanImageFailed;
            defer _ = c.pixman_image_unref(clear);
            c.pixman_image_composite32(
                c.PIXMAN_OP_SRC,
                clear,
                null,
                destination,
                0,
                0,
                0,
                0,
                0,
                0,
                @intCast(plan.output.width),
                @intCast(plan.output.height),
            );
        }

        if (draws) try self.drawRange(list, plan, destination, 0, cursor_start);
        if (before_cursor) |readback| try copyReadback(
            readback,
            destination_bytes,
            destination_stride,
            plan.output,
        );
        if (draws) try self.drawRange(list, plan, destination, cursor_start, list.samples.len);
        if (after_cursor) |readback| try copyReadback(
            readback,
            destination_bytes,
            destination_stride,
            plan.output,
        );
    }

    fn drawRange(
        self: *Renderer,
        list: render.List,
        plan: render.DamagePlan,
        destination: *c.pixman_image_t,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        for (plan.samples, 0..) |planned, index| {
            if (planned.source_index >= list.samples.len) return error.InvalidSourceIndex;
            if (planned.source_index < source_start or planned.source_index >= source_end) continue;
            var sample = list.samples[planned.source_index];
            if (!std.meta.eql(planned.sample, sample.sample) or
                !std.meta.eql(planned.presentation, sample.presentation))
                return error.PlannedIdentityMismatch;
            sample.crop = planned.crop;
            sample.destination = clipPlanRect(planned.destination, plan.output) orelse continue;
            sample.clip = clipPlanRect(planned.clip, plan.output) orelse continue;
            sample.transform = planned.transform;
            sample.global_alpha = planned.global_alpha;
            _ = try render.validateSample(sample);

            var scratch: ?[]u32 = null;
            defer if (scratch) |pixels| self.allocator.free(pixels);
            var source_bytes = sample.source.bytes;
            var source_stride = sample.source.stride;
            if (@intFromPtr(source_bytes.ptr) % @alignOf(u32) != 0) {
                const pixel_count = std.math.mul(
                    usize,
                    sample.source.size.width,
                    sample.source.size.height,
                ) catch return error.SourceCapacityExceeded;
                const packed_stride = std.math.mul(u32, sample.source.size.width, 4) catch
                    return error.SourceCapacityExceeded;
                scratch = try self.allocator.alloc(u32, pixel_count);
                const packed_bytes = std.mem.sliceAsBytes(scratch.?);
                copySource(packed_bytes, packed_stride, sample.source);
                source_bytes = packed_bytes;
                source_stride = packed_stride;
            }

            const cache = &self.caches[index];
            cache.mask_value = sample.global_alpha;
            const source = c.pixman_image_create_bits(
                pixmanFormat(sample.source.format),
                @intCast(sample.source.size.width),
                @intCast(sample.source.size.height),
                @ptrCast(@alignCast(@constCast(source_bytes.ptr))),
                @intCast(source_stride),
            ) orelse return error.PixmanImageFailed;
            defer _ = c.pixman_image_unref(source);
            var transform = sampleTransform(sample);
            if (c.pixman_image_set_transform(source, &transform) == 0)
                return error.PixmanTransformFailed;
            if (c.pixman_image_set_filter(source, c.PIXMAN_FILTER_NEAREST, null, 0) == 0)
                return error.PixmanFilterFailed;

            const clipped = intersection(sample.destination, sample.clip, plan.output) orelse
                continue;
            c.pixman_image_composite32(
                if (sample.source.format == .xrgb8888 and sample.global_alpha == 255)
                    c.PIXMAN_OP_SRC
                else
                    c.PIXMAN_OP_OVER,
                source,
                if (sample.global_alpha == 255) null else cache.mask,
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

fn copyReadback(
    readback: Readback,
    source: []const u8,
    source_stride: u32,
    output: render.Size,
) Error!void {
    try validateReadback(readback, output);
    const row_bytes = std.math.mul(u32, output.width, 4) catch return error.InvalidTarget;
    for (0..output.height) |row| {
        const source_start = @as(usize, source_stride) * row;
        const destination_start = @as(usize, readback.stride) * row;
        @memcpy(
            readback.bytes[destination_start..][0..row_bytes],
            source[source_start..][0..row_bytes],
        );
    }
}

fn validateReadback(readback: Readback, output: render.Size) Error!void {
    const row_bytes = std.math.mul(u32, output.width, 4) catch return error.InvalidTarget;
    const length = std.math.mul(usize, readback.stride, output.height) catch
        return error.InvalidTarget;
    if (readback.stride < row_bytes or readback.bytes.len < length)
        return error.InvalidTarget;
}

fn deinitCaches(caches: []Cache) void {
    var index = caches.len;
    while (index != 0) {
        index -= 1;
        _ = c.pixman_image_unref(caches[index].mask);
    }
}

fn copySource(destination: []u8, destination_stride: u32, source: render.Source) void {
    const row_bytes: usize = @as(usize, source.size.width) * 4;
    for (0..source.size.height) |row| {
        const source_start = @as(usize, source.stride) * row;
        const destination_start = @as(usize, destination_stride) * row;
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

fn clipPlanRect(value: render.PlanRect, output: render.Size) ?render.Rect {
    const left = @max(value.x, 0);
    const top = @max(value.y, 0);
    const right = @min(value.x +| value.width, output.width);
    const bottom = @min(value.y +| value.height, output.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

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
