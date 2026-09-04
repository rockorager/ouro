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
    blur_a: std.ArrayListUnmanaged(u32) = .empty,
    blur_b: std.ArrayListUnmanaged(u32) = .empty,

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
        self.blur_b.deinit(self.allocator);
        self.blur_a.deinit(self.allocator);
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

            try self.applyBackdropBlur(
                list,
                plan,
                planned,
                sample,
                destination_bytes,
                destination_stride,
            );

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

    fn applyBackdropBlur(
        self: *Renderer,
        list: render.List,
        plan: render.DamagePlan,
        planned: render.PlannedSample,
        sample: render.SurfaceSample,
        destination: []u8,
        destination_stride: u32,
    ) Error!void {
        if (!render.hasVisibleBlur(sample)) return;
        const clipped = intersection(sample.destination, sample.clip, plan.output) orelse return;
        const visible: render.Rect = .{
            .x = clipped.x,
            .y = clipped.y,
            .width = clipped.width,
            .height = clipped.height,
        };
        if (!damaged(plan, visible)) return;
        const effect = visibleBlurBounds(list, sample, planned, plan, visible) orelse return;

        const scale_x = @as(f64, @floatFromInt(sample.destination.width)) /
            @as(f64, @floatFromInt(sample.effect_size.width));
        const scale_y = @as(f64, @floatFromInt(sample.destination.height)) /
            @as(f64, @floatFromInt(sample.effect_size.height));
        const scale = @max(scale_x, scale_y);
        const radii = [3]u32{
            @max(1, @as(u32, @intFromFloat(@round(7.0 * scale)))),
            @max(1, @as(u32, @intFromFloat(@round(7.0 * scale)))),
            @max(1, @as(u32, @intFromFloat(@round(8.0 * scale)))),
        };
        const support = radii[0] + radii[1] + radii[2];
        const area = expand(effect, support, plan.output);
        const pixel_count = std.math.mul(usize, area.width, area.height) catch
            return error.SourceCapacityExceeded;
        try self.blur_a.resize(self.allocator, pixel_count);
        try self.blur_b.resize(self.allocator, pixel_count);
        copyDestinationRect(
            self.blur_a.items,
            destination,
            destination_stride,
            area,
        );
        for (radii) |radius| {
            boxBlurHorizontal(self.blur_b.items, self.blur_a.items, area.width, area.height, radius);
            boxBlurVertical(self.blur_a.items, self.blur_b.items, area.width, area.height, radius);
        }

        var y = effect.y;
        while (y < effect.y + @as(i32, @intCast(effect.height))) : (y += 1) {
            var x = effect.x;
            while (x < effect.x + @as(i32, @intCast(effect.width))) : (x += 1) {
                const point = inverseOutputPoint(.{ .x = x, .y = y }, list.output, plan.output_transform);
                const local = surfacePoint(point, list.samples[planned.source_index]) orelse continue;
                if (!regionContains(sample.blur_region, local) or
                    (sample.global_alpha == 255 and regionContains(sample.opaque_region, local)) or
                    !pixelDamaged(plan, x, y))
                    continue;
                const source_index = @as(usize, @intCast(y - area.y)) * area.width +
                    @as(usize, @intCast(x - area.x));
                const destination_offset = @as(usize, @intCast(y)) * destination_stride +
                    @as(usize, @intCast(x)) * 4;
                const bytes: *[4]u8 = @ptrCast(destination[destination_offset..][0..4].ptr);
                const value = self.blur_a.items[source_index];
                bytes.* = @bitCast(value);
                if (list.output_format == .xrgb8888) bytes[3] = 255;
            }
        }
    }
};

const EffectPoint = struct { x: i32, y: i32 };

fn visibleBlurBounds(
    list: render.List,
    sample: render.SurfaceSample,
    planned: render.PlannedSample,
    plan: render.DamagePlan,
    visible: render.Rect,
) ?render.Rect {
    var left: i64 = std.math.maxInt(i64);
    var top: i64 = std.math.maxInt(i64);
    var right: i64 = std.math.minInt(i64);
    var bottom: i64 = std.math.minInt(i64);
    var y = visible.y;
    while (y < @as(i64, visible.y) + visible.height) : (y += 1) {
        var x = visible.x;
        while (x < @as(i64, visible.x) + visible.width) : (x += 1) {
            if (!pixelDamaged(plan, x, y)) continue;
            const point = inverseOutputPoint(.{ .x = x, .y = y }, list.output, plan.output_transform);
            const local = surfacePoint(point, list.samples[planned.source_index]) orelse continue;
            if (!regionContains(sample.blur_region, local) or
                (sample.global_alpha == 255 and regionContains(sample.opaque_region, local)))
                continue;
            left = @min(left, x);
            top = @min(top, y);
            right = @max(right, @as(i64, x) + 1);
            bottom = @max(bottom, @as(i64, y) + 1);
        }
    }
    if (left >= right or top >= bottom) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn damaged(plan: render.DamagePlan, rect: render.Rect) bool {
    if (plan.render_full) return true;
    for (plan.render_damage) |value| if (intersection(rect, value, plan.output) != null)
        return true;
    return false;
}

fn pixelDamaged(plan: render.DamagePlan, x: i32, y: i32) bool {
    if (plan.render_full) return true;
    for (plan.render_damage) |value| if (x >= value.x and y >= value.y and
        @as(i64, x) < @as(i64, value.x) + value.width and
        @as(i64, y) < @as(i64, value.y) + value.height) return true;
    return false;
}

fn expand(value: render.Rect, radius: u32, output: render.Size) render.Rect {
    const left = @max(@as(i64, 0), @as(i64, value.x) - radius);
    const top = @max(@as(i64, 0), @as(i64, value.y) - radius);
    const right = @min(@as(i64, output.width), @as(i64, value.x) + value.width + radius);
    const bottom = @min(@as(i64, output.height), @as(i64, value.y) + value.height + radius);
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn inverseOutputPoint(point: EffectPoint, output: render.Size, transform: render.Transform) EffectPoint {
    const width: i32 = @intCast(output.width);
    const height: i32 = @intCast(output.height);
    return switch (transform) {
        .normal => point,
        .@"90" => .{ .x = width - 1 - point.y, .y = point.x },
        .@"180" => .{ .x = width - 1 - point.x, .y = height - 1 - point.y },
        .@"270" => .{ .x = point.y, .y = height - 1 - point.x },
        .flipped => .{ .x = width - 1 - point.x, .y = point.y },
        .flipped_90 => .{ .x = point.y, .y = point.x },
        .flipped_180 => .{ .x = point.x, .y = height - 1 - point.y },
        .flipped_270 => .{ .x = width - 1 - point.y, .y = height - 1 - point.x },
    };
}

fn surfacePoint(point: EffectPoint, sample: render.SurfaceSample) ?EffectPoint {
    const dx = @as(i64, point.x) - sample.destination.x;
    const dy = @as(i64, point.y) - sample.destination.y;
    if (dx < 0 or dy < 0 or dx >= sample.destination.width or dy >= sample.destination.height)
        return null;
    return .{
        .x = @intCast(@divFloor(dx * sample.effect_size.width, sample.destination.width)),
        .y = @intCast(@divFloor(dy * sample.effect_size.height, sample.destination.height)),
    };
}

fn regionContains(operations: []const render.RegionOperation, point: EffectPoint) bool {
    var contains = false;
    for (operations) |operation| {
        const result = switch (operation) {
            .add => |value| .{ value, true },
            .subtract => |value| .{ value, false },
        };
        const rectangle = result[0];
        const inside = point.x >= rectangle.x and point.y >= rectangle.y and
            @as(i64, point.x) < @as(i64, rectangle.x) + rectangle.width and
            @as(i64, point.y) < @as(i64, rectangle.y) + rectangle.height;
        if (!inside) continue;
        contains = result[1];
    }
    return contains;
}

fn copyDestinationRect(
    output: []u32,
    destination: []const u8,
    stride: u32,
    area: render.Rect,
) void {
    for (0..area.height) |row| {
        for (0..area.width) |column| {
            const offset = (@as(usize, @intCast(area.y)) + row) * stride +
                (@as(usize, @intCast(area.x)) + column) * 4;
            output[row * area.width + column] = @bitCast(destination[offset..][0..4].*);
        }
    }
}

fn boxBlurHorizontal(output: []u32, input: []const u32, width: u32, height: u32, radius: u32) void {
    const divisor = radius * 2 + 1;
    for (0..height) |y| {
        var sums: [4]u64 = @splat(0);
        var offset: i64 = -@as(i64, radius);
        while (offset <= radius) : (offset += 1)
            addPixel(&sums, input[y * width + clampCoordinate(offset, width)]);
        for (0..width) |x| {
            output[y * width + x] = averagePixel(sums, divisor);
            if (x + 1 == width) continue;
            subtractPixel(&sums, input[y * width + clampCoordinate(@as(i64, @intCast(x)) - radius, width)]);
            addPixel(&sums, input[y * width + clampCoordinate(@as(i64, @intCast(x)) + radius + 1, width)]);
        }
    }
}

fn boxBlurVertical(output: []u32, input: []const u32, width: u32, height: u32, radius: u32) void {
    const divisor = radius * 2 + 1;
    for (0..width) |x| {
        var sums: [4]u64 = @splat(0);
        var offset: i64 = -@as(i64, radius);
        while (offset <= radius) : (offset += 1)
            addPixel(&sums, input[clampCoordinate(offset, height) * width + x]);
        for (0..height) |y| {
            output[y * width + x] = averagePixel(sums, divisor);
            if (y + 1 == height) continue;
            subtractPixel(&sums, input[clampCoordinate(@as(i64, @intCast(y)) - radius, height) * width + x]);
            addPixel(&sums, input[clampCoordinate(@as(i64, @intCast(y)) + radius + 1, height) * width + x]);
        }
    }
}

fn clampCoordinate(value: i64, extent: u32) usize {
    return @intCast(std.math.clamp(value, 0, @as(i64, extent) - 1));
}

fn addPixel(sums: *[4]u64, pixel: u32) void {
    inline for (0..4) |channel| sums[channel] += (pixel >> @intCast(channel * 8)) & 0xff;
}

fn subtractPixel(sums: *[4]u64, pixel: u32) void {
    inline for (0..4) |channel| sums[channel] -= (pixel >> @intCast(channel * 8)) & 0xff;
}

fn averagePixel(sums: [4]u64, divisor: u32) u32 {
    var pixel: u32 = 0;
    inline for (0..4) |channel| {
        const value: u32 = @intCast((sums[channel] + divisor / 2) / divisor);
        pixel |= value << @intCast(channel * 8);
    }
    return pixel;
}

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

test "render-pixman: backdrop blur smooths transparency and skips opaque coverage" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 2,
        .max_source_width = 64,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    var background: [64 * 4]u8 align(4) = undefined;
    var foreground: [64 * 4]u8 align(4) = undefined;
    for (0..64) |x| {
        const value: u8 = if (x < 32) 0 else 255;
        background[x * 4 ..][0..4].* = .{ value, value, value, 255 };
        foreground[x * 4 ..][0..4].* = if (x < 32)
            .{ 0, 0, 0, 0 }
        else
            .{ 0, 0, 255, 255 };
    }
    const blur_region = [_]render.RegionOperation{.{
        .add = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
    }};
    const opaque_right = [_]render.RegionOperation{.{
        .add = .{ .x = 32, .y = 0, .width = 32, .height = 1 },
    }};
    const samples = [_]render.SurfaceSample{
        .{
            .sample = .{ .surface = 1, .commit_sequence = 1 },
            .presentation = .{ .slot = 0, .generation = 1 },
            .source = .{ .size = .{ .width = 64, .height = 1 }, .stride = 256, .format = .xrgb8888, .bytes = &background },
            .crop = render.SourceRect.pixels(0, 0, 64, 1),
            .destination = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
        },
        .{
            .sample = .{ .surface = 2, .commit_sequence = 1 },
            .presentation = .{ .slot = 1, .generation = 1 },
            .source = .{ .size = .{ .width = 64, .height = 1 }, .stride = 256, .format = .argb8888_premultiplied, .bytes = &foreground },
            .crop = render.SourceRect.pixels(0, 0, 64, 1),
            .destination = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .effect_size = .{ .width = 64, .height = 1 },
            .opaque_region = &opaque_right,
            .blur_region = &blur_region,
        },
    };
    const planned = [_]render.PlannedSample{
        .{
            .source_index = 0,
            .sample = samples[0].sample,
            .presentation = samples[0].presentation,
            .crop = samples[0].crop,
            .destination = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .transform = .normal,
            .global_alpha = 255,
        },
        .{
            .source_index = 1,
            .sample = samples[1].sample,
            .presentation = samples[1].presentation,
            .crop = samples[1].crop,
            .destination = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .clip = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
            .transform = .normal,
            .global_alpha = 255,
        },
    };
    const list: render.List = .{
        .output = .{ .width = 64, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &samples,
    };
    const plan: render.DamagePlan = .{
        .output = list.output,
        .samples = &planned,
        .client_damage = &.{},
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = &.{},
        .client_full = false,
        .scene_full = false,
        .repair_full = false,
        .render_full = true,
    };
    var destination: [64 * 4]u8 align(4) = undefined;
    try renderer.draw(list, plan, &destination, 256);
    try std.testing.expect(destination[31 * 4] > 0 and destination[31 * 4] < 255);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, destination[32 * 4 ..][0..4]);
    try std.testing.expectEqual(@as(usize, 54), renderer.blur_a.items.len);

    var opaque_renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 2,
        .max_source_width = 64,
        .max_source_height = 1,
    });
    defer opaque_renderer.deinit();
    var opaque_samples = samples;
    const opaque_all = [_]render.RegionOperation{.{
        .add = .{ .x = 0, .y = 0, .width = 64, .height = 1 },
    }};
    opaque_samples[1].opaque_region = &opaque_all;
    try std.testing.expect(!render.hasVisibleBlur(opaque_samples[1]));
    try std.testing.expect(render.hasVisibleBlur(samples[1]));
    try opaque_renderer.draw(.{
        .output = list.output,
        .output_format = list.output_format,
        .clear = list.clear,
        .samples = &opaque_samples,
    }, plan, &destination, 256);
    try std.testing.expectEqual(@as(usize, 0), opaque_renderer.blur_a.items.len);
}
