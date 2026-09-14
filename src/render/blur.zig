//! Dual Kawase geometry shared by damage propagation and the Vulkan renderer.
//! Pyramid coordinates are output-global, never relative to damage rectangles.
const std = @import("std");
const render = @import("types.zig");

pub const levels = 3;
pub const passes = levels * 2;

pub fn offset(scale: f32) f32 {
    return 0.75 * scale;
}

pub fn levelSize(output: render.Size, level: usize) render.Size {
    const divisor = @as(u32, 1) << @intCast(level);
    return .{ .width = 1 + (output.width - 1) / divisor, .height = 1 + (output.height - 1) / divisor };
}

pub fn sourceLevel(pass: usize) usize {
    return if (pass < levels) pass else passes - pass;
}

pub fn targetLevel(pass: usize) usize {
    return if (pass < levels) pass + 1 else passes - pass - 1;
}

/// Conservative full-resolution influence radius. A down pass reaches offset
/// source texels and an up pass reaches 2*offset, plus bilinear support. The
/// sums of source-level spacings are 7 and 14; seven extra pixels cover the
/// pyramid's sampling phase. Ceil-sized odd levels never exceed these ratios.
pub fn radius(scale: f32) u32 {
    return @intFromFloat(@ceil(35.0 * @as(f64, offset(scale)) + 28.0));
}

/// All source texels that a destination rectangle may fetch, including the
/// bilinear neighbour even when its weight is zero. Clamp at the logical level
/// edge, not the backing allocation edge (scratch images are reused).
pub fn sourceBounds(rect: render.Rect, source: render.Size, target: render.Size, up: bool, scale: f32) render.Rect {
    const reach = @as(f64, offset(scale)) * @as(f64, if (up) 2 else 1);
    const x = axisBounds(rect.x, rect.width, source.width, target.width, reach);
    const y = axisBounds(rect.y, rect.height, source.height, target.height, reach);
    return .{ .x = @intCast(x[0]), .y = @intCast(y[0]), .width = x[1] - x[0], .height = y[1] - y[0] };
}

fn axisBounds(start: i32, length: u32, source: u32, target: u32, reach: f64) [2]u32 {
    const ratio = @as(f64, @floatFromInt(source)) / @as(f64, @floatFromInt(target));
    const first = (@as(f64, @floatFromInt(start)) + 0.5) * ratio - 0.5;
    const last = (@as(f64, @floatFromInt(@as(i64, start) + length - 1)) + 0.5) * ratio - 0.5;
    // One extra texel also covers FP32 coordinate rounding at integer borders.
    const low = @floor(first - reach) - 1;
    const high = @floor(last + reach) + 3;
    return .{ @intFromFloat(std.math.clamp(low, 0, source - 1)), @intFromFloat(std.math.clamp(high, 1, source)) };
}

test "Dual Kawase odd pyramid sizes and bounded source coordinates" {
    const output = render.Size{ .width = 101, .height = 57 };
    try std.testing.expectEqualDeep(render.Size{ .width = 13, .height = 8 }, levelSize(output, 3));
    try std.testing.expectEqualDeep(render.Size{ .width = 1, .height = 1 }, levelSize(.{ .width = 1, .height = 1 }, 3));
    // Downsample pixel (7, 5): centers are 14.35, 10.31 at the source.
    try std.testing.expectEqualDeep(render.Rect{ .x = 12, .y = 8, .width = 6, .height = 6 }, sourceBounds(
        .{ .x = 7, .y = 5, .width = 1, .height = 1 },
        output,
        levelSize(output, 1),
        false,
        1,
    ));
    try std.testing.expectEqualDeep(render.Rect{ .x = 0, .y = 0, .width = 1, .height = 1 }, sourceBounds(
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .{ .width = 1, .height = 1 },
        .{ .width = 1, .height = 1 },
        true,
        1.5,
    ));
}
