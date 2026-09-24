//! Peripheral shrink: windows near the sides of a wide output are rendered
//! smaller, as if the sides were peripheral vision. Windows inside a central
//! band keep their full size; beyond it, the visual scale falls linearly with
//! the window's horizontal distance from the band until the output edge, where
//! it reaches `min_scale_percent`. The window shrinks about its own center, so
//! its logical geometry, configured size, and buffer never change: this is a
//! render-and-input transform, not a layout.

const std = @import("std");
const geometry = @import("geometry.zig");
const render = @import("../render/types.zig");

pub const Settings = struct {
    enabled: bool = false,
    /// Width of the full-size central band as a percentage of the output width.
    center_percent: u32 = 50,
    /// Visual scale at the output's left and right edges, in percent.
    min_scale_percent: u32 = 30,

    pub fn validate(settings: Settings) !void {
        if (settings.center_percent > 100) return error.InvalidPeripheralCenter;
        if (settings.min_scale_percent == 0 or settings.min_scale_percent > 100)
            return error.InvalidPeripheralScale;
    }
};

/// Returns the visual transform for a window occupying `window` on an output
/// whose logical extent is `bounds`, or null when the window renders at its
/// natural size. Returns null for identity so callers can skip the mapping.
pub fn transform(
    settings: Settings,
    window: geometry.Rect,
    bounds: geometry.Rect,
) ?render.VisualTransform {
    if (!settings.enabled or bounds.width <= 0) return null;
    settings.validate() catch return null;
    // Work in doubled coordinates so centers of odd-sized rectangles are exact.
    const output_center2 = @as(i64, bounds.x) * 2 + bounds.width;
    const window_center2 = @as(i64, window.x) * 2 + window.width;
    const half_output2: i64 = bounds.width; // half the output width, doubled
    const half_band2 = @divTrunc(@as(i64, bounds.width) * @as(i64, settings.center_percent), 100);
    const distance2 = @abs(window_center2 - output_center2);
    if (distance2 <= half_band2) return null;
    const falloff2 = half_output2 - half_band2;
    if (falloff2 <= 0) return null;
    const progress = @min(@as(i64, @intCast(distance2)) - half_band2, falloff2);
    const min_scale = @divTrunc(@as(i64, render.fixed_one) * @as(i64, settings.min_scale_percent), 100);
    const scale = render.fixed_one - @divTrunc((render.fixed_one - min_scale) * progress, falloff2);
    return .{
        .anchor = .{
            .x = @intCast(@divFloor(window_center2, 2)),
            .y = @intCast(@divFloor(@as(i64, window.y) * 2 + window.height, 2)),
        },
        .scale = @intCast(@max(min_scale, scale)),
    };
}

/// The logical rectangle `rect` as drawn through `visual`.
pub fn renderedRect(visual: render.VisualTransform, rect: geometry.Rect) ?geometry.Rect {
    if (rect.width <= 0 or rect.height <= 0) return null;
    const mapped = visual.mapRect(.{
        .x = rect.x,
        .y = rect.y,
        .width = @intCast(rect.width),
        .height = @intCast(rect.height),
    }) catch return null;
    return .{
        .x = mapped.x,
        .y = mapped.y,
        .width = std.math.cast(i32, mapped.width) orelse return null,
        .height = std.math.cast(i32, mapped.height) orelse return null,
    };
}

/// Maps a pointer position over the drawn window back into the window's
/// logical coordinate space, or null when the pointer misses the drawn
/// window. The result always lies inside `window`, so rounding at the drawn
/// edge cannot leak a hit to a neighbouring logical pixel outside it.
pub fn logicalPoint(
    visual: render.VisualTransform,
    window: geometry.Rect,
    point: geometry.Point,
) ?geometry.Point {
    const drawn = renderedRect(visual, window) orelse return null;
    if (!drawn.contains(point)) return null;
    const unmapped = visual.unmapPoint(.{ .x = point.x, .y = point.y }) orelse return null;
    return .{
        .x = @intCast(std.math.clamp(
            @as(i64, unmapped.x),
            window.x,
            @as(i64, window.x) + window.width - 1,
        )),
        .y = @intCast(std.math.clamp(
            @as(i64, unmapped.y),
            window.y,
            @as(i64, window.y) + window.height - 1,
        )),
    };
}

test "peripheral: windows inside the central band keep their size" {
    const settings: Settings = .{ .enabled = true, .center_percent = 50, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    // Center band spans x in [1000, 3000); a window centered at 2000 is full size.
    try std.testing.expect(transform(settings, .{ .x = 1500, .y = 100, .width = 1000, .height = 500 }, bounds) == null);
    // Exactly on the band edge is still full size.
    try std.testing.expect(transform(settings, .{ .x = 500, .y = 100, .width = 1000, .height = 500 }, bounds) == null);
    try std.testing.expect(transform(.{}, .{ .x = 0, .y = 0, .width = 10, .height = 10 }, bounds) == null);
}

test "peripheral: scale falls linearly to the minimum at the output edge" {
    const settings: Settings = .{ .enabled = true, .center_percent = 50, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    // Falloff spans centers from 3000 to 4000. A center at 3500 is halfway:
    // scale = 1 - 0.5 * (1 - 0.25) = 0.625.
    const half = transform(settings, .{ .x = 3000, .y = 200, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 3500), half.anchor.x);
    try std.testing.expectEqual(@as(i32, 400), half.anchor.y);
    try std.testing.expectEqual(@as(i32, 40960), half.scale);
    const mapped = try half.mapRect(.{ .x = 3000, .y = 200, .width = 1000, .height = 400 });
    try std.testing.expectEqual(render.Rect{ .x = 3188, .y = 275, .width = 625, .height = 250 }, mapped);

    // The left side mirrors the right, and centers past the edge clamp.
    const left = transform(settings, .{ .x = 0, .y = 200, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 40960), left.scale);
    const beyond = transform(settings, .{ .x = -2000, .y = 0, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 16384), beyond.scale);
    const edge = transform(settings, .{ .x = 3500, .y = 0, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 16384), edge.scale);
}

test "peripheral: output offsets and odd sizes do not bias the center" {
    const settings: Settings = .{ .enabled = true, .center_percent = 0, .min_scale_percent = 50 };
    const bounds: geometry.Rect = .{ .x = 1000, .y = 300, .width = 2001, .height = 999 };
    // A window centered on the output center is full size even with a zero band.
    try std.testing.expect(transform(settings, .{ .x = 1900, .y = 400, .width = 201, .height = 100 }, bounds) == null);
    const shifted = transform(settings, .{ .x = 2500, .y = 400, .width = 201, .height = 101 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 2600), shifted.anchor.x);
    try std.testing.expectEqual(@as(i32, 450), shifted.anchor.y);
    try std.testing.expect(shifted.scale < render.fixed_one and shifted.scale > render.fixed_one / 2);
}

test "peripheral: mapping and unmapping round trip through the window" {
    const settings: Settings = .{ .enabled = true, .center_percent = 50, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    const window: geometry.Rect = .{ .x = 3000, .y = 200, .width = 1000, .height = 400 };
    const visual = transform(settings, window, bounds).?;
    // Every rendered pixel inside the mapped rectangle unmaps into the window.
    const mapped = try visual.mapRect(.{ .x = window.x, .y = window.y, .width = 1000, .height = 400 });
    var x: i32 = mapped.x;
    while (x < mapped.x + @as(i32, @intCast(mapped.width))) : (x += 1) {
        const logical = visual.unmapPoint(.{ .x = x, .y = mapped.y }).?;
        try std.testing.expect(window.contains(.{ .x = logical.x, .y = logical.y }));
    }
    // Adjacent logical edges stay adjacent after mapping.
    const a = try visual.mapRect(.{ .x = 3000, .y = 200, .width = 333, .height = 400 });
    const b = try visual.mapRect(.{ .x = 3333, .y = 200, .width = 667, .height = 400 });
    try std.testing.expectEqual(a.x + @as(i32, @intCast(a.width)), b.x);
    // The anchor maps to itself and unmaps to itself.
    try std.testing.expectEqual(visual.anchor, try visual.mapPoint(visual.anchor));
    try std.testing.expectEqual(visual.anchor, visual.unmapPoint(visual.anchor).?);
}

test "peripheral: pointer over the drawn window maps into logical space" {
    const settings: Settings = .{ .enabled = true, .center_percent = 50, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    const window: geometry.Rect = .{ .x = 3000, .y = 200, .width = 1000, .height = 400 };
    const visual = transform(settings, window, bounds).?;
    // Drawn at {3188, 275, 625, 250}: the logical area outside that is a miss
    // even though it lies inside the window's logical geometry.
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3100, .y = 300 }) == null);
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3187, .y = 300 }) == null);
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3813, .y = 300 }) == null);
    // The drawn top-left pixel covers logical columns 3000.8..3002.4 and rows
    // 200..201.6, so it maps to the nearest logical pixel inside the window.
    try std.testing.expectEqual(geometry.Point{ .x = 3001, .y = 200 }, logicalPoint(visual, window, .{ .x = 3188, .y = 275 }).?);
    // The center stays put; a drawn pixel 100 to the right is 160 logical pixels.
    try std.testing.expectEqual(geometry.Point{ .x = 3500, .y = 400 }, logicalPoint(visual, window, .{ .x = 3500, .y = 400 }).?);
    try std.testing.expectEqual(geometry.Point{ .x = 3660, .y = 400 }, logicalPoint(visual, window, .{ .x = 3600, .y = 400 }).?);
    // The last drawn pixel stays inside the window (drawn row 524 covers
    // logical rows 598.4..600 and rounds to 598).
    try std.testing.expectEqual(geometry.Point{ .x = 3999, .y = 598 }, logicalPoint(visual, window, .{ .x = 3812, .y = 524 }).?);
    // One past the drawn bottom-right corner is a miss.
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3812, .y = 525 }) == null);
}

test "peripheral: settings reject impossible percentages" {
    try (Settings{}).validate();
    try (Settings{ .enabled = true, .center_percent = 100, .min_scale_percent = 100 }).validate();
    try std.testing.expectError(error.InvalidPeripheralCenter, (Settings{ .center_percent = 101 }).validate());
    try std.testing.expectError(error.InvalidPeripheralScale, (Settings{ .min_scale_percent = 0 }).validate());
    try std.testing.expectError(error.InvalidPeripheralScale, (Settings{ .min_scale_percent = 101 }).validate());
    // A full-width band never shrinks anything, even when enabled.
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    try std.testing.expect(transform(
        .{ .enabled = true, .center_percent = 100 },
        .{ .x = 3900, .y = 0, .width = 100, .height = 100 },
        bounds,
    ) == null);
}
