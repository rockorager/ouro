//! Static renderer-neutral nine-slice tiled-drop preview.

const std = @import("std");
const geometry = @import("geometry.zig");
const render = @import("../render/types.zig");
const damage = @import("damage.zig");

pub const max_samples = 9;
pub const State = [max_samples]?damage.SurfaceState;
pub const empty_state: State = @splat(null);
pub const synthetic_surface_index = std.math.maxInt(u32) - 1;
pub const synthetic_presentation_slot = std.math.maxInt(u32) - 1;
pub const source_width = 65;
pub const source_height = 65;
pub const source_size_bytes = source_width * source_height * 4;

const border: i32 = 32; // 20px falloff plus the 12px corner radius.
const padding: i32 = 20;
const center_alpha: u8 = 0x70;

const texture align(16) = makeTexture();

fn makeTexture() [source_size_bytes]u8 {
    @setEvalBranchQuota(100_000);
    var result: [source_size_bytes]u8 = undefined;
    for (0..source_height) |y| for (0..source_width) |x| {
        // Signed distance to a radius-12 rounded rectangle at [20,45).
        // Its one-pixel center strip stretches without scaling the corners.
        const dx = @abs(@as(f64, @floatFromInt(x)) - 32.0) - 0.5;
        const dy = @abs(@as(f64, @floatFromInt(y)) - 32.0) - 0.5;
        const distance = @max(0, @sqrt(@max(dx, 0) * @max(dx, 0) + @max(dy, 0) * @max(dy, 0)) +
            @min(@max(dx, dy), 0) - 12);
        const alpha: u8 = if (distance >= 20) 0 else @intFromFloat(
            @as(f64, center_alpha) * (1.0 - distance / 20.0) * (1.0 - distance / 20.0),
        );
        const offset = (y * source_width + x) * 4;
        result[offset] = premultiply(0xf5, alpha);
        result[offset + 1] = premultiply(0x9e, alpha);
        result[offset + 2] = premultiply(0x47, alpha);
        result[offset + 3] = alpha;
    };
    return result;
}

fn premultiply(channel: u8, alpha: u8) u8 {
    return @intCast((@as(u16, channel) * alpha + 127) / 255);
}

fn generation(slice: usize) u32 {
    return std.math.maxInt(u32) - 1 - @as(u32, @intCast(slice));
}

fn identity(slice: usize) render.SampleIdentity {
    return .{
        .surface = @as(u64, generation(slice)) << 32 | synthetic_surface_index,
        .commit_sequence = 1,
    };
}

/// Forms the structural binding expected by physical without importing it.
pub fn sampleBinding(sample: render.SurfaceSample, comptime Binding: type) Binding {
    const SurfaceId = @TypeOf(@as(Binding, undefined).surface);
    return .{
        .surface = SurfaceId{
            .index = synthetic_surface_index,
            .generation = @truncate(sample.sample.surface >> 32),
        },
        .sample = sample.sample,
        .presentation = sample.presentation,
    };
}

/// Each current damage entry must describe one exact renderer sample, not the
/// union of the nine pieces. Retain the returned state only after submission.
pub fn damageChanges(previous: State, values: []const render.SurfaceSample, storage: *[max_samples]damage.Change) State {
    var current = empty_state;
    for (values, 0..) |sample, index| current[index] = damage.SurfaceState.fromSample(sample, sample.source.size);
    for (previous, current, storage) |before, after, *change| change.* = .{
        .previous = before,
        .current = after,
    };
    return current;
}

/// Returns borrowed samples valid until process exit. `storage` is caller-owned
/// so producing a frame performs no allocation.
pub fn samples(
    rect: geometry.Rect,
    output: geometry.Rect,
    storage: *[max_samples]render.SurfaceSample,
) ![]const render.SurfaceSample {
    try rect.validate();
    try output.validate();
    // Do not spill the glow onto a neighbouring output without a drop target.
    if (rect.x >= output.x + output.width or rect.y >= output.y + output.height or
        rect.x + rect.width <= output.x or rect.y + rect.height <= output.y) return storage[0..0];
    const left = std.math.sub(i32, rect.x, padding) catch return error.InvalidGeometry;
    const top = std.math.sub(i32, rect.y, padding) catch return error.InvalidGeometry;
    const width = std.math.add(i32, rect.width, padding * 2) catch return error.InvalidGeometry;
    const height = std.math.add(i32, rect.height, padding * 2) catch return error.InvalidGeometry;
    _ = std.math.add(i32, left, width) catch return error.InvalidGeometry;
    _ = std.math.add(i32, top, height) catch return error.InvalidGeometry;

    const bx = @min(border, @divTrunc(width, 2));
    const by = @min(border, @divTrunc(height, 2));
    const xs = [4]i32{ left, left + bx, left + width - bx, left + width };
    const ys = [4]i32{ top, top + by, top + height - by, top + height };
    const source_edges = [4]i32{ 0, border, border + 1, source_width };
    const out_right: i64 = @as(i64, output.x) + output.width;
    const out_bottom: i64 = @as(i64, output.y) + output.height;
    var count: usize = 0;
    for (0..3) |row| for (0..3) |column| {
        if (xs[column + 1] <= xs[column] or ys[row + 1] <= ys[row]) continue;
        const clip_left = @max(@as(i64, xs[column]), output.x);
        const clip_top = @max(@as(i64, ys[row]), output.y);
        const clip_right = @min(@as(i64, xs[column + 1]), out_right);
        const clip_bottom = @min(@as(i64, ys[row + 1]), out_bottom);
        if (clip_right <= clip_left or clip_bottom <= clip_top) continue;
        const slice = row * 3 + column;
        storage[count] = .{
            .sample = identity(slice),
            .presentation = .{ .slot = synthetic_presentation_slot, .generation = generation(slice) },
            .source = .{
                .size = .{ .width = source_width, .height = source_height },
                .stride = source_width * 4,
                .format = .argb8888_premultiplied,
                .bytes = &texture,
            },
            .crop = render.SourceRect.pixels(
                source_edges[column],
                source_edges[row],
                source_edges[column + 1] - source_edges[column],
                source_edges[row + 1] - source_edges[row],
            ),
            .destination = .{
                .x = xs[column],
                .y = ys[row],
                .width = @intCast(xs[column + 1] - xs[column]),
                .height = @intCast(ys[row + 1] - ys[row]),
            },
            .clip = .{
                .x = @intCast(clip_left),
                .y = @intCast(clip_top),
                .width = @intCast(clip_right - clip_left),
                .height = @intCast(clip_bottom - clip_top),
            },
        };
        _ = try render.validateSample(storage[count]);
        count += 1;
    };
    return storage[0..count];
}

test "drop preview: asymmetric negative target clips and tiles without overlaps" {
    var storage: [max_samples]render.SurfaceSample = undefined;
    const result = try samples(.{ .x = -7, .y = 11, .width = 101, .height = 53 }, .{ .x = -10, .y = 0, .width = 80, .height = 70 }, &storage);
    try std.testing.expect(result.len > 0);
    for (result, 0..) |sample, i| {
        try std.testing.expectEqual(source_size_bytes, try render.validateSample(sample));
        try std.testing.expect(sample.clip.x >= -10 and sample.clip.y >= 0);
        for (result[0..i]) |other| try std.testing.expect(
            @as(i64, sample.destination.x) >= @as(i64, other.destination.x) + other.destination.width or
                @as(i64, other.destination.x) >= @as(i64, sample.destination.x) + sample.destination.width or
                @as(i64, sample.destination.y) >= @as(i64, other.destination.y) + other.destination.height or
                @as(i64, other.destination.y) >= @as(i64, sample.destination.y) + sample.destination.height,
        );
    }
}

test "drop preview: texture is premultiplied with center and soft falloff" {
    const center = (32 * source_width + 32) * 4;
    const edge = (32 * source_width + 13) * 4;
    const outside = (32 * source_width + 1) * 4;
    try std.testing.expectEqual(center_alpha, texture[center + 3]);
    // A square fill would leave this corner fully opaque relative to center.
    try std.testing.expect(texture[(20 * source_width + 20) * 4 + 3] < center_alpha);
    try std.testing.expect(texture[edge + 3] > texture[outside + 3]);
    try std.testing.expect(texture[outside + 3] < center_alpha);
    for (0..source_width * source_height) |pixel| for (0..3) |channel|
        try std.testing.expect(texture[pixel * 4 + channel] <= texture[pixel * 4 + 3]);
}

test "drop preview: tiny hidden and invalid targets" {
    var storage: [max_samples]render.SurfaceSample = undefined;
    const tiny = try samples(.{ .x = -2, .y = -3, .width = 1, .height = 1 }, .{ .x = -50, .y = -50, .width = 100, .height = 100 }, &storage);
    try std.testing.expect(tiny.len > 0 and tiny.len <= max_samples);
    const hidden = try samples(.{ .x = 100, .y = 100, .width = 20, .height = 20 }, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, &storage);
    try std.testing.expectEqual(@as(usize, 0), hidden.len);
    const adjacent = try samples(.{ .x = 10, .y = 0, .width = 20, .height = 20 }, .{ .x = 0, .y = 0, .width = 10, .height = 20 }, &storage);
    try std.testing.expectEqual(@as(usize, 0), adjacent.len);
    try std.testing.expectError(error.InvalidGeometry, samples(.{ .x = 0, .y = 0, .width = 0, .height = 1 }, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, &storage));
}

test "drop preview: bindings retain distinct reserved identities" {
    const Id = packed struct { index: u32, generation: u32 };
    const Binding = struct { surface: Id, sample: render.SampleIdentity, presentation: render.PresentationIdentity };
    var storage: [max_samples]render.SurfaceSample = undefined;
    const result = try samples(.{ .x = 0, .y = 0, .width = 100, .height = 100 }, .{ .x = -30, .y = -30, .width = 160, .height = 160 }, &storage);
    try std.testing.expectEqual(max_samples, result.len);
    for (result, 0..) |sample, i| {
        const binding = sampleBinding(sample, Binding);
        try std.testing.expectEqual(synthetic_surface_index, binding.surface.index);
        if (i != 0) try std.testing.expect(sample.sample.surface != result[0].sample.surface);
    }
}

test "render: tiled drop preview repaints its slices and erases old pixels" {
    const pixman = @import("../render/pixman.zig");
    var renderer = try pixman.Renderer.init(std.testing.allocator, .{
        .max_samples = max_samples,
        .max_source_width = source_width,
        .max_source_height = source_height,
    });
    defer renderer.deinit();
    const output: geometry.Rect = .{ .x = 0, .y = 0, .width = 128, .height = 96 };
    var planner = try damage.Planner.init(std.testing.allocator, .{ .width = 128, .height = 96 }, .normal, .{
        .image_count = 1,
        .max_samples = max_samples,
        .max_client_rects = 16,
        .max_scene_rects = 16,
        .max_repair_rects = 16,
        .max_render_rects = 16,
    });
    defer planner.deinit();
    var pixels: [128 * 96 * 4]u8 align(16) = undefined;
    var previous = empty_state;
    const targets = [_]?geometry.Rect{
        .{ .x = 10, .y = 12, .width = 32, .height = 36 },
        .{ .x = 75, .y = 42, .width = 32, .height = 36 },
        null, // release/cancellation must erase every previously drawn slice
        null, // no damage remains once the overlay has disappeared
    };
    for (targets, 0..) |target, frame| {
        var storage: [max_samples]render.SurfaceSample = undefined;
        const values = if (target) |rect| try samples(rect, output, &storage) else &.{};
        var changes: [max_samples]damage.Change = undefined;
        const next = damageChanges(previous, values, &changes);
        const list: render.List = .{
            .output = .{ .width = 128, .height = 96 },
            .output_format = .xrgb8888,
            .clear = .{ .r = 20, .g = 30, .b = 40 },
            .samples = values,
        };
        const plan = try planner.prepare(.{ .slot = 0, .generation = @intCast(frame + 1) }, list, &changes);
        if (frame == 3) try std.testing.expectEqual(@as(usize, 0), plan.render_damage.len);
        try renderer.draw(list, plan, &pixels, 128 * 4);
        try planner.publish();
        previous = next;
        if (target) |rect| {
            const center: usize = @intCast(((rect.y + 18) * 128 + rect.x + 16) * 4);
            // Independent premultiplied blue-over-background result.
            try std.testing.expectEqualSlices(u8, &.{ 130, 86, 42 }, pixels[center..][0..3]);
        }
        if (frame == 1) try std.testing.expectEqualSlices(u8, &.{ 40, 30, 20 }, pixels[(30 * 128 + 26) * 4 ..][0..3]);
        if (target == null) for (0..128 * 96) |pixel|
            try std.testing.expectEqualSlices(u8, &.{ 40, 30, 20 }, pixels[pixel * 4 ..][0..3]);
    }
}
