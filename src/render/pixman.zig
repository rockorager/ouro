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
    @cInclude("string.h");
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
            var clear_damage = c.pixman_region32_t{};
            c.pixman_region32_init(&clear_damage);
            defer c.pixman_region32_fini(&clear_damage);
            if (c.pixman_region32_copy(&clear_damage, &damage) == 0)
                return error.PixmanRegionFailed;
            try subtractOpaqueCoverage(
                list,
                plan,
                &clear_damage,
                if (before_cursor != null) cursor_start else list.samples.len,
            );

            if (c.pixman_region32_not_empty(&clear_damage) != 0) {
                if (c.pixman_image_set_clip_region32(destination, &clear_damage) == 0)
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
            if (c.pixman_image_set_clip_region32(destination, &damage) == 0)
                return error.PixmanRegionFailed;
        }

        if (draws) try self.drawRange(
            list,
            plan,
            destination,
            destination_bytes,
            destination_stride,
            0,
            cursor_start,
        );
        if (before_cursor) |readback| try copyReadback(
            readback,
            destination_bytes,
            destination_stride,
            plan.output,
        );
        if (draws) try self.drawRange(
            list,
            plan,
            destination,
            destination_bytes,
            destination_stride,
            cursor_start,
            list.samples.len,
        );
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
        destination_bytes: []u8,
        destination_stride: u32,
        source_start: usize,
        source_end: usize,
    ) Error!void {
        const prefer_direct_copy = directCopyPreferred(plan.render_full, plan.render_damage);
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

            // Pixman's large SRC fast path batches scanlines more efficiently
            // than one libc memcpy per row. Keep direct copies for bounded
            // damage, where they avoid walking untouched pixels.
            if (prefer_direct_copy and canCopyDirect(sample, list.output_format)) {
                copyDirect(
                    destination_bytes,
                    destination_stride,
                    sample,
                    plan,
                );
                continue;
            }

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

fn subtractOpaqueCoverage(
    list: render.List,
    plan: render.DamagePlan,
    clear_damage: *c.pixman_region32_t,
    source_end: usize,
) Error!void {
    for (plan.samples) |planned| {
        if (planned.source_index >= list.samples.len or planned.source_index >= source_end)
            continue;
        const sample = list.samples[planned.source_index];
        if (!std.meta.eql(planned.sample, sample.sample) or
            !std.meta.eql(planned.presentation, sample.presentation) or
            sample.source.format != .xrgb8888 or planned.global_alpha != 255)
            continue;
        const destination = clipPlanRect(planned.destination, plan.output) orelse continue;
        const clip = clipPlanRect(planned.clip, plan.output) orelse continue;
        const covered = intersection(destination, clip, plan.output) orelse continue;
        var covered_region = c.pixman_region32_t{};
        c.pixman_region32_init_rect(
            &covered_region,
            covered.x,
            covered.y,
            covered.width,
            covered.height,
        );
        defer c.pixman_region32_fini(&covered_region);
        if (c.pixman_region32_subtract(clear_damage, clear_damage, &covered_region) == 0)
            return error.PixmanRegionFailed;
    }
}

fn canCopyDirect(sample: render.SurfaceSample, output_format: render.PixelFormat) bool {
    return sample.source.format == .xrgb8888 and output_format == .xrgb8888 and
        sample.global_alpha == 255 and sample.transform == .normal and
        @rem(sample.crop.x, render.fixed_one) == 0 and
        @rem(sample.crop.y, render.fixed_one) == 0 and
        sample.crop.width == @as(i64, sample.destination.width) * render.fixed_one and
        sample.crop.height == @as(i64, sample.destination.height) * render.fixed_one;
}

fn directCopyPreferred(render_full: bool, render_damage: []const render.Rect) bool {
    if (render_full) return false;
    var pixels: u64 = 0;
    for (render_damage) |rect| {
        pixels +|= @as(u64, rect.width) * rect.height;
    }
    return pixels <= 256 * 256;
}

test "render-pixman: direct copies are limited to bounded damage" {
    try std.testing.expect(directCopyPreferred(false, &.{
        .{ .x = 0, .y = 0, .width = 64, .height = 64 },
        .{ .x = 128, .y = 128, .width = 64, .height = 64 },
    }));
    try std.testing.expect(!directCopyPreferred(false, &.{
        .{ .x = 0, .y = 0, .width = 960, .height = 720 },
    }));
    try std.testing.expect(!directCopyPreferred(true, &.{}));
}

fn copyDirect(
    destination: []u8,
    destination_stride: u32,
    sample: render.SurfaceSample,
    plan: render.DamagePlan,
) void {
    const visible = intersection(sample.destination, sample.clip, plan.output) orelse return;
    if (plan.render_full) {
        copyDirectRect(destination, destination_stride, sample, visible);
        return;
    }
    for (plan.render_damage) |damage| {
        const clipped_damage = intersection(damage, damage, plan.output) orelse continue;
        const clipped = intersectComposite(visible, clipped_damage) orelse continue;
        copyDirectRect(destination, destination_stride, sample, clipped);
    }
}

fn copyDirectRect(
    destination: []u8,
    destination_stride: u32,
    sample: render.SurfaceSample,
    rect: CompositeRect,
) void {
    const source_x: usize = @intCast(@divExact(sample.crop.x, render.fixed_one) +
        (rect.x - sample.destination.x));
    const source_y: usize = @intCast(@divExact(sample.crop.y, render.fixed_one) +
        (rect.y - sample.destination.y));
    const row_bytes: usize = @as(usize, rect.width) * 4;
    for (0..rect.height) |row| {
        const source_start = (@as(usize, sample.source.stride) * (source_y + row)) +
            source_x * 4;
        const destination_start = (@as(usize, destination_stride) *
            (@as(usize, @intCast(rect.y)) + row)) + @as(usize, @intCast(rect.x)) * 4;
        _ = c.memcpy(
            destination[destination_start..].ptr,
            sample.source.bytes[source_start..].ptr,
            row_bytes,
        );
    }
}

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

fn intersectComposite(a: CompositeRect, b: CompositeRect) ?CompositeRect {
    const left = @max(a.x, b.x);
    const top = @max(a.y, b.y);
    const right = @min(
        @as(i64, a.x) + a.width,
        @as(i64, b.x) + b.width,
    );
    const bottom = @min(
        @as(i64, a.y) + a.height,
        @as(i64, b.y) + b.height,
    );
    if (right <= left or bottom <= top) return null;
    return .{
        .x = left,
        .y = top,
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

test "render-pixman: direct XRGB copy touches only damaged sample pixels" {
    const source = [_]u8{
        1,  2,  3,  255, 4,  5,  6,  255, 7,  8,  9,  255, 10, 11, 12, 255,
        13, 14, 15, 255, 16, 17, 18, 255, 19, 20, 21, 255, 22, 23, 24, 255,
        25, 26, 27, 255, 28, 29, 30, 255, 31, 32, 33, 255, 34, 35, 36, 255,
    };
    var destination: [6 * 4 * 4]u8 align(4) = [_]u8{0xaa} ** (6 * 4 * 4);
    const sample = render.SurfaceSample{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 4, .height = 3 },
            .stride = 16,
            .format = .xrgb8888,
            .bytes = &source,
        },
        .crop = render.SourceRect.pixels(0, 0, 4, 3),
        .destination = .{ .x = 1, .y = 1, .width = 4, .height = 3 },
        .clip = .{ .x = 0, .y = 0, .width = 6, .height = 4 },
    };
    const damage = [_]render.Rect{
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
        .{ .x = 4, .y = 3, .width = 1, .height = 1 },
    };
    const plan = render.DamagePlan{
        .output = .{ .width = 6, .height = 4 },
        .samples = &.{},
        .client_damage = &.{},
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = &damage,
        .client_full = false,
        .scene_full = false,
        .repair_full = false,
        .render_full = false,
    };

    try std.testing.expect(canCopyDirect(sample, .xrgb8888));
    copyDirect(&destination, 24, sample, plan);
    try std.testing.expectEqualSlices(u8, source[0..4], destination[28..32]);
    try std.testing.expectEqualSlices(u8, source[44..48], destination[88..92]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 4), destination[32..36]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 4), destination[84..88]);
}

test "render-pixman: direct copy rejects compositing work" {
    const pixels = [_]u8{0} ** 16;
    var sample = render.SurfaceSample{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 2, .height = 2 },
            .stride = 8,
            .format = .xrgb8888,
            .bytes = &pixels,
        },
        .crop = render.SourceRect.pixels(0, 0, 2, 2),
        .destination = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .clip = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
    };
    try std.testing.expect(canCopyDirect(sample, .xrgb8888));
    sample.transform = .@"90";
    try std.testing.expect(!canCopyDirect(sample, .xrgb8888));
    sample.transform = .normal;
    sample.global_alpha = 128;
    try std.testing.expect(!canCopyDirect(sample, .xrgb8888));
    sample.global_alpha = 255;
    sample.crop.width = render.fixed_one;
    try std.testing.expect(!canCopyDirect(sample, .xrgb8888));
    sample.crop.width = 2 * render.fixed_one;
    sample.source.format = .argb8888_premultiplied;
    try std.testing.expect(!canCopyDirect(sample, .xrgb8888));
}

test "render-pixman: opaque coverage replaces stale pixels and leaves clear background" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 2,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    const source: [8]u8 align(4) = .{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const sample = render.SurfaceSample{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 2, .height = 1 },
            .stride = 8,
            .format = .xrgb8888,
            .bytes = &source,
        },
        .crop = render.SourceRect.pixels(0, 0, 2, 1),
        .destination = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
    };
    const list = render.List{
        .output = .{ .width = 3, .height = 2 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{sample},
    };
    const plan = render.DamagePlan{
        .output = list.output,
        .samples = &.{.{
            .source_index = 0,
            .sample = sample.sample,
            .presentation = sample.presentation,
            .crop = sample.crop,
            .destination = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
            .transform = .normal,
            .global_alpha = 255,
        }},
        .client_damage = &.{},
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = &.{},
        .client_full = false,
        .scene_full = false,
        .repair_full = false,
        .render_full = true,
    };
    var destination: [24]u8 align(4) = [_]u8{0xaa} ** 24;

    try renderer.draw(list, plan, &destination, 12);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, destination[0..4]);
    try std.testing.expectEqualSlices(u8, &source, destination[4..12]);
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{ 0, 0, 0, 255 } ** 3),
        destination[12..24],
    );
}

test "render-pixman: opaque cursor does not suppress pre-cursor clear" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 1,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    const source: [4]u8 align(4) = .{ 1, 2, 3, 255 };
    const sample = render.SurfaceSample{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .xrgb8888,
            .bytes = &source,
        },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    const list = render.List{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{sample},
    };
    const plan = render.DamagePlan{
        .output = list.output,
        .samples = &.{.{
            .source_index = 0,
            .sample = sample.sample,
            .presentation = sample.presentation,
            .crop = sample.crop,
            .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .transform = .normal,
            .global_alpha = 255,
        }},
        .client_damage = &.{},
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = &.{},
        .client_full = false,
        .scene_full = false,
        .repair_full = false,
        .render_full = true,
    };
    var destination: [4]u8 align(4) = [_]u8{0xaa} ** 4;
    var before: [4]u8 align(4) = undefined;
    var after: [4]u8 align(4) = undefined;

    try renderer.drawPhased(
        list,
        plan,
        &destination,
        4,
        0,
        .{ .bytes = &before, .stride = 4 },
        .{ .bytes = &after, .stride = 4 },
    );
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &before);
    try std.testing.expectEqualSlices(u8, &source, &after);
}
