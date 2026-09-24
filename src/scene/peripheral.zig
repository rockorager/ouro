//! Peripheral shrink: windows near the sides of a wide output are rendered
//! smaller, as if the sides were peripheral vision. Windows inside a central
//! band keep their full size; beyond it, the visual scale decays exponentially
//! with horizontal distance from the band until the output edge, where
//! it reaches `min_scale_percent`. The window shrinks about its own center, so
//! its logical geometry, configured size, and buffer never change during the
//! transform. Tiled windows use separate center/side layout regions below.

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

pub const Region = enum { center, left, right };

/// Reserved tiling bands inside the work area. Outer gaps belong to the output;
/// inner gaps separate the bands, including when a side band is empty.
pub const Regions = struct {
    areas: [3]geometry.Rect,
    center_start: i32,
    center_end: i32,

    pub fn at(regions: Regions, point: geometry.Point) Region {
        return if (point.x < regions.center_start) .left else if (point.x >= regions.center_end) .right else .center;
    }
};

pub fn tileRegions(settings: Settings, bounds: geometry.Rect, inner: u32, outer: u32) ?Regions {
    if (!settings.enabled or settings.center_percent == 0 or settings.center_percent >= 100) return null;
    const center_width = @divTrunc(@as(i64, bounds.width) * settings.center_percent, 100);
    const left_width = @divTrunc(bounds.width - center_width, 2);
    const center_start = @as(i64, bounds.x) + left_width;
    const center_end = center_start + center_width;
    const before = @divTrunc(inner, 2);
    const after = inner - before;
    const starts = [3]i64{ center_start + after, @as(i64, bounds.x) + outer, center_end + after };
    const ends = [3]i64{ center_end - before, center_start - before, @as(i64, bounds.x) + bounds.width - outer };
    const height = @as(i64, bounds.height) - @as(i64, outer) * 2;
    if (height <= 0) return null;
    var areas: [3]geometry.Rect = undefined;
    for (starts, ends, &areas) |start, end, *area| {
        if (end <= start) return null;
        area.* = .{
            .x = @intCast(start),
            .y = @intCast(@as(i64, bounds.y) + outer),
            .width = @intCast(end - start),
            .height = @intCast(height),
        };
    }
    return .{ .areas = areas, .center_start = @intCast(center_start), .center_end = @intCast(center_end) };
}

/// Side windows keep the center's logical size and are drawn scaled into a
/// grid. The grid is as square as `count` allows (two rows for three or four
/// windows, three for five to nine), oriented so full cells give the larger
/// scale. Every row divides the area width between the windows it holds, so
/// a short last row draws its windows larger. Rows are packed with exactly
/// `inner` between them and the block is centered in the area. No window is
/// drawn above 1:1.
pub const Grid = struct {
    columns: usize,
    rows: usize,
    count: usize,
    area: geometry.Rect,
    window: geometry.Rect,
    inner: i32,

    /// Windows in `row`; only the last row can be short.
    pub fn rowCount(layout: Grid, row: usize) usize {
        return if (row + 1 == layout.rows) layout.count - row * layout.columns else layout.columns;
    }

    /// Width of one window's share of `row`.
    fn spanWidth(layout: Grid, row: usize) i64 {
        const held: i64 = @intCast(layout.rowCount(row));
        return @divTrunc(@as(i64, layout.area.width) - layout.inner * (held - 1), held);
    }

    /// Scale of every window in `row`: bound by its share of the row width and
    /// by an equal share of the area height, never above 1:1.
    pub fn rowScale(layout: Grid, row: usize) i32 {
        const rows: i64 = @intCast(layout.rows);
        const cell_height = @divTrunc(@as(i64, layout.area.height) - layout.inner * (rows - 1), rows);
        const scale = @min(
            @as(i64, render.fixed_one),
            @divTrunc(layout.spanWidth(row) * render.fixed_one, layout.window.width),
            @divTrunc(cell_height * render.fixed_one, layout.window.height),
        );
        return @intCast(@max(scale, 0));
    }

    fn scaledAboutCenter(layout: Grid, scale: i32) render.VisualTransform {
        return .{
            .anchor = .{
                .x = @intCast(@divFloor(@as(i64, layout.window.x) * 2 + layout.window.width, 2)),
                .y = @intCast(@divFloor(@as(i64, layout.window.y) * 2 + layout.window.height, 2)),
            },
            .scale = scale,
        };
    }

    /// Height of `row`: the drawn height of its windows.
    fn rowHeight(layout: Grid, row: usize) ?i32 {
        const drawn = renderedRect(layout.scaledAboutCenter(layout.rowScale(row)), layout.window) orelse return null;
        return drawn.height;
    }

    /// The area window `index` is centered in: its share of the row width by
    /// the row's drawn height, with rows packed and the block centered.
    pub fn slot(layout: Grid, index: usize) ?geometry.Rect {
        const row = index / layout.columns;
        const column: i64 = @intCast(index % layout.columns);
        var total: i64 = 0;
        var top: i64 = 0;
        for (0..layout.rows) |candidate| {
            const height = layout.rowHeight(candidate) orelse return null;
            if (candidate == row) top = total;
            total += height + if (candidate + 1 < layout.rows) layout.inner else 0;
        }
        const held: i64 = @intCast(layout.rowCount(row));
        const span = layout.spanWidth(row);
        const used_width = span * held + layout.inner * (held - 1);
        return .{
            .x = std.math.cast(i32, layout.area.x + @divTrunc(layout.area.width - used_width, 2) + column * (span + layout.inner)) orelse return null,
            .y = std.math.cast(i32, layout.area.y + @divTrunc(layout.area.height - total, 2) + top) orelse return null,
            .width = std.math.cast(i32, span) orelse return null,
            .height = layout.rowHeight(row) orelse return null,
        };
    }

    /// Draws window `index` at its row's scale, centered in its slot.
    pub fn visual(layout: Grid, index: usize) ?render.VisualTransform {
        var transform_value = layout.scaledAboutCenter(layout.rowScale(index / layout.columns));
        const drawn = renderedRect(transform_value, layout.window) orelse return null;
        const target = layout.slot(index) orelse return null;
        transform_value.translation = .{
            .x = std.math.cast(i32, @as(i64, target.x) + @divFloor(target.width - drawn.width, 2) - drawn.x) orelse return null,
            .y = std.math.cast(i32, @as(i64, target.y) + @divFloor(target.height - drawn.height, 2) - drawn.y) orelse return null,
        };
        return transform_value;
    }
};

/// Lays out `count` windows of `window` size inside `area`. Returns null when
/// the area cannot hold a one-pixel cell for every window.
pub fn grid(area: geometry.Rect, count: usize, window: geometry.Rect, inner: u32) ?Grid {
    if (count == 0 or area.width <= 0 or area.height <= 0 or window.width <= 0 or window.height <= 0) return null;
    const gap: i64 = inner;
    const side = ceilSqrt(count);
    const across = (count + side - 1) / side;
    var best: ?Grid = null;
    var best_scale: i64 = 0;
    // Stacked first so a tie keeps the taller arrangement.
    for ([_][2]usize{ .{ side, across }, .{ across, side } }) |shape| {
        const rows = shape[0];
        const columns = shape[1];
        const cell_width = @divTrunc(@as(i64, area.width) - gap * @as(i64, @intCast(columns - 1)), @as(i64, @intCast(columns)));
        const cell_height = @divTrunc(@as(i64, area.height) - gap * @as(i64, @intCast(rows - 1)), @as(i64, @intCast(rows)));
        if (cell_width <= 0 or cell_height <= 0) continue;
        const scale = @min(
            @as(i64, render.fixed_one),
            @divTrunc(cell_width * render.fixed_one, window.width),
            @divTrunc(cell_height * render.fixed_one, window.height),
        );
        if (scale <= 0 or scale <= best_scale) continue;
        best_scale = scale;
        best = .{
            .columns = columns,
            .rows = rows,
            .count = count,
            .area = area,
            .window = window,
            .inner = @intCast(inner),
        };
    }
    return best;
}

fn ceilSqrt(value: usize) usize {
    var root: usize = 1;
    while (root * root < value) root += 1;
    return root;
}

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
    const t = @as(f64, @floatFromInt(progress)) / @as(f64, @floatFromInt(falloff2));
    // Four half-lives: shrink quickly after leaving center, then taper off.
    // Normalize the decay so the center is exactly 1 and the edge exactly min.
    const remaining = (@exp2(-4.0 * t) - 0.0625) / 0.9375;
    const scale: i64 = @intFromFloat(@round(@as(f64, @floatFromInt(min_scale)) +
        @as(f64, @floatFromInt(render.fixed_one - min_scale)) * remaining));
    return .{
        .anchor = .{
            .x = @intCast(@divFloor(window_center2, 2)),
            .y = @intCast(@divFloor(@as(i64, window.y) * 2 + window.height, 2)),
        },
        .scale = @intCast(@max(min_scale, scale)),
    };
}

/// A dragged floating window stays visibly on its cursor-selected output even
/// when its logical center has crossed the boundary. Keep the shrink computed
/// above (including its minimum) and translate the drawn rectangle back inside.
pub fn boundedTransform(settings: Settings, window: geometry.Rect, bounds: geometry.Rect) ?render.VisualTransform {
    if (!settings.enabled) return null;
    var visual = transform(settings, window, bounds) orelse render.VisualTransform{
        .anchor = .{ .x = window.x, .y = window.y },
        .scale = render.fixed_one,
    };
    const drawn = renderedRect(visual, window) orelse return null;
    const x = std.math.clamp(@as(i64, drawn.x), bounds.x, @as(i64, bounds.x) + @max(0, bounds.width - drawn.width));
    const y = std.math.clamp(@as(i64, drawn.y), bounds.y, @as(i64, bounds.y) + @max(0, bounds.height - drawn.height));
    visual.translation = .{
        .x = std.math.cast(i32, x - drawn.x) orelse return null,
        .y = std.math.cast(i32, y - drawn.y) orelse return null,
    };
    return if (visual.identity()) null else visual;
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

test "peripheral: exponential decay shrinks fast then approaches the edge minimum" {
    const settings: Settings = .{ .enabled = true, .center_percent = 50, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 4000, .height = 1000 };
    // Four half-lives produce 60%, 40%, 30%, 25% at quarter intervals:
    // successive reductions are 40, 20, 10, and 5 percentage points.
    for ([_]i32{ 3250, 3500, 3750, 4000 }, [_]i32{ 39322, 26214, 19661, 16384 }) |center, expected| {
        try std.testing.expectEqual(expected, transform(settings, .{ .x = center - 500, .y = 200, .width = 1000, .height = 400 }, bounds).?.scale);
    }
    const half = transform(settings, .{ .x = 3000, .y = 200, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 3500), half.anchor.x);
    try std.testing.expectEqual(@as(i32, 400), half.anchor.y);
    try std.testing.expectEqual(@as(i32, 26214), half.scale);
    const mapped = try half.mapRect(.{ .x = 3000, .y = 200, .width = 1000, .height = 400 });
    try std.testing.expectEqual(render.Rect{ .x = 3300, .y = 320, .width = 400, .height = 160 }, mapped);

    // The left side mirrors the right, and centers past the edge clamp.
    const left = transform(settings, .{ .x = 0, .y = 200, .width = 1000, .height = 400 }, bounds).?;
    try std.testing.expectEqual(@as(i32, 26214), left.scale);
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
    // Drawn at {3300, 320, 400, 160}: the logical area outside that is a miss
    // even though it lies inside the window's logical geometry.
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3100, .y = 300 }) == null);
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3299, .y = 400 }) == null);
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3700, .y = 400 }) == null);
    try std.testing.expectEqual(geometry.Point{ .x = 3000, .y = 200 }, logicalPoint(visual, window, .{ .x = 3300, .y = 320 }).?);
    // The center stays put; a drawn pixel 100 to the right is 250 logical pixels.
    try std.testing.expectEqual(geometry.Point{ .x = 3500, .y = 400 }, logicalPoint(visual, window, .{ .x = 3500, .y = 400 }).?);
    try std.testing.expectEqual(geometry.Point{ .x = 3750, .y = 400 }, logicalPoint(visual, window, .{ .x = 3600, .y = 400 }).?);
    // The last drawn pixel remains inside the window after rounding.
    try std.testing.expectEqual(geometry.Point{ .x = 3998, .y = 598 }, logicalPoint(visual, window, .{ .x = 3699, .y = 479 }).?);
    // One past the drawn bottom-right corner is a miss.
    try std.testing.expect(logicalPoint(visual, window, .{ .x = 3699, .y = 480 }) == null);
}

test "peripheral: reserved bands keep odd gaps and offset boundaries exact" {
    const bounds: geometry.Rect = .{ .x = -700, .y = 40, .width = 1003, .height = 403 };
    const regions = tileRegions(.{ .enabled = true, .center_percent = 40 }, bounds, 11, 7).?;
    try std.testing.expectEqual(geometry.Rect{ .x = -393, .y = 47, .width = 390, .height = 389 }, regions.areas[0]);
    try std.testing.expectEqual(geometry.Rect{ .x = -693, .y = 47, .width = 289, .height = 389 }, regions.areas[1]);
    try std.testing.expectEqual(geometry.Rect{ .x = 8, .y = 47, .width = 288, .height = 389 }, regions.areas[2]);
    try std.testing.expectEqual(Region.left, regions.at(.{ .x = -400, .y = 100 }));
    try std.testing.expectEqual(Region.center, regions.at(.{ .x = -399, .y = 100 }));
    try std.testing.expectEqual(Region.center, regions.at(.{ .x = 1, .y = 100 }));
    try std.testing.expectEqual(Region.right, regions.at(.{ .x = 2, .y = 100 }));
    try std.testing.expect(tileRegions(.{}, bounds, 11, 7) == null);
    try std.testing.expect(tileRegions(.{ .enabled = true, .center_percent = 100 }, bounds, 11, 7) == null);
    try std.testing.expect(tileRegions(.{ .enabled = true, .center_percent = 0 }, bounds, 11, 7) == null);
    try std.testing.expect(tileRegions(.{ .enabled = true }, .{ .x = 0, .y = 0, .width = 3, .height = 5 }, 12, 12) == null);
}

test "peripheral: minimum-size window stays inside its selected monitor with invertible input" {
    const settings: Settings = .{ .enabled = true, .min_scale_percent = 25 };
    const bounds: geometry.Rect = .{ .x = -500, .y = 50, .width = 500, .height = 400 };
    // Both logical centers have crossed x=0, but the cursor still owns the
    // left monitor. The drawn window stops at its edge at the same minimum.
    for ([_]i32{ -50, 50 }) |x| {
        const window: geometry.Rect = .{ .x = x, .y = 100, .width = 200, .height = 120 };
        const visual = boundedTransform(settings, window, bounds).?;
        try std.testing.expectEqual(@as(i32, 16384), visual.scale);
        try std.testing.expectEqual(geometry.Rect{ .x = -50, .y = 145, .width = 50, .height = 30 }, renderedRect(visual, window).?);
        try std.testing.expectEqual(geometry.Point{ .x = x + 100, .y = 160 }, logicalPoint(visual, window, .{ .x = -25, .y = 160 }).?);
        try std.testing.expect(logicalPoint(visual, window, .{ .x = 0, .y = 160 }) == null);
    }
    // Selecting the other monitor changes the scale/bounds, not the configured
    // client geometry. Its top edge remains contained on the destination.
    const window: geometry.Rect = .{ .x = -50, .y = -120, .width = 200, .height = 120 };
    const right = boundedTransform(settings, window, .{ .x = 0, .y = 0, .width = 800, .height = 600 }).?;
    try std.testing.expect(right.scale > 16384);
    const drawn = renderedRect(right, window).?;
    try std.testing.expectEqual(@as(i32, 20), drawn.x);
    try std.testing.expectEqual(@as(i32, 0), drawn.y);
    try std.testing.expect(!right.identity());
}

test "peripheral: side grid orients itself and centers windows in slots" {
    const window: geometry.Rect = .{ .x = 300, .y = 100, .width = 400, .height = 600 };
    // One window in a 200x600 side: width-bound at exactly half size, centered vertically.
    const single = grid(.{ .x = 0, .y = 0, .width = 200, .height = 600 }, 1, window, 12).?;
    try std.testing.expectEqual(@as(usize, 1), single.columns);
    try std.testing.expectEqual(render.fixed_one / 2, single.rowScale(0));
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 150, .width = 200, .height = 300 }, renderedRect(single.visual(0).?, window).?);

    // Two portrait windows in a wide side: side by side beats stacked because
    // stacking halves the height (300 -> 0.5) while columns keep 0.735.
    const area: geometry.Rect = .{ .x = 1000, .y = 50, .width = 600, .height = 600 };
    const pair = grid(area, 2, window, 12).?;
    try std.testing.expectEqual(@as(usize, 2), pair.columns);
    try std.testing.expectEqual(@as(usize, 1), pair.rows);
    try std.testing.expectEqual(@as(i32, 294), pair.slot(0).?.width);
    try std.testing.expectEqual(@divTrunc(294 * render.fixed_one, 400), pair.rowScale(0));
    const first = renderedRect(pair.visual(0).?, window).?;
    const second = renderedRect(pair.visual(1).?, window).?;
    try std.testing.expectEqual(geometry.Rect{ .x = 1000, .y = 130, .width = 294, .height = 440 }, first);
    try std.testing.expectEqual(@as(i32, 1306), second.x);
    try std.testing.expectEqual(first.y, second.y);
    try std.testing.expectEqual(first.width, second.width);
    // The gap between the drawn windows is exactly the inner gap.
    try std.testing.expectEqual(@as(i32, 12), second.x - (first.x + first.width));

    // The same pair in a tall side stacks instead.
    const stacked = grid(.{ .x = 0, .y = 0, .width = 300, .height = 1400 }, 2, window, 12).?;
    try std.testing.expectEqual(@as(usize, 1), stacked.columns);
    try std.testing.expectEqual(@as(usize, 2), stacked.rows);
}

test "peripheral: side grid stays square and lets a short last row draw larger" {
    // A tall side band beside a 1280x1400 center: three windows would fit a
    // single column at 0.327, but the grid stays two by two so the pair on
    // top shares the width and the odd window below takes the whole row.
    const window: geometry.Rect = .{ .x = 650, .y = 40, .width = 1280, .height = 1400 };
    const area: geometry.Rect = .{ .x = 0, .y = 40, .width = 620, .height = 1400 };
    const trio = grid(area, 3, window, 12).?;
    try std.testing.expectEqual(@as(usize, 2), trio.columns);
    try std.testing.expectEqual(@as(usize, 2), trio.rows);
    try std.testing.expectEqual(@as(usize, 2), trio.rowCount(0));
    try std.testing.expectEqual(@as(usize, 1), trio.rowCount(1));
    try std.testing.expectEqual(@divTrunc(304 * render.fixed_one, 1280), trio.rowScale(0));
    try std.testing.expectEqual(@divTrunc(620 * render.fixed_one, 1280), trio.rowScale(1));
    const a = renderedRect(trio.visual(0).?, window).?;
    const b = renderedRect(trio.visual(1).?, window).?;
    const c = renderedRect(trio.visual(2).?, window).?;
    // Top pair: equal, exactly one gap apart, filling the row width.
    try std.testing.expectEqual(a.y, b.y);
    try std.testing.expectEqual(a.width, b.width);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(@as(i32, 12), b.x - (a.x + a.width));
    try std.testing.expect(a.x >= area.x and b.x + b.width <= area.x + area.width);
    try std.testing.expect(a.width >= 303 and a.width <= 304);
    // Bottom window: full width, one gap below the pair, centered.
    try std.testing.expect(c.width >= 619 and c.width <= 620);
    try std.testing.expect(c.width > 2 * a.width);
    try std.testing.expectEqual(@as(i32, 12), c.y - (a.y + a.height));
    try std.testing.expect(c.x >= area.x and c.x + c.width <= area.x + area.width);
    // The block is centered vertically with one pixel of rounding slack.
    const top_margin = a.y - area.y;
    const bottom_margin = area.y + area.height - (c.y + c.height);
    try std.testing.expect(@abs(top_margin - bottom_margin) <= 1);
    try std.testing.expect(top_margin > 100);

    // Four windows form a two by two block at one scale.
    const quad = grid(area, 4, window, 12).?;
    try std.testing.expectEqual(@as(usize, 2), quad.columns);
    try std.testing.expectEqual(@as(usize, 2), quad.rows);
    try std.testing.expectEqual(quad.rowScale(0), quad.rowScale(1));
    const q0 = renderedRect(quad.visual(0).?, window).?;
    const q1 = renderedRect(quad.visual(1).?, window).?;
    const q2 = renderedRect(quad.visual(2).?, window).?;
    const q3 = renderedRect(quad.visual(3).?, window).?;
    try std.testing.expectEqual(q0.x, q2.x);
    try std.testing.expectEqual(q1.x, q3.x);
    try std.testing.expectEqual(q2.y, q3.y);
    try std.testing.expectEqual(@as(i32, 12), q2.y - (q0.y + q0.height));
    try std.testing.expectEqual(@as(i32, 12), q1.x - (q0.x + q0.width));
    try std.testing.expectEqual(a.width, q0.width);

    // Five windows: three rows of two with a lone last row.
    const five = grid(area, 5, window, 12).?;
    try std.testing.expectEqual(@as(usize, 2), five.columns);
    try std.testing.expectEqual(@as(usize, 3), five.rows);
    try std.testing.expectEqual(@as(usize, 1), five.rowCount(2));
    try std.testing.expect(five.rowScale(2) > five.rowScale(0));
}

test "peripheral: side grid never upscales and rejects impossible areas" {
    const window: geometry.Rect = .{ .x = 0, .y = 0, .width = 16, .height = 16 };
    const roomy = grid(.{ .x = 0, .y = 0, .width = 24, .height = 16 }, 1, window, 0).?;
    try std.testing.expectEqual(render.fixed_one, roomy.rowScale(0));
    try std.testing.expectEqual(geometry.Rect{ .x = 4, .y = 0, .width = 16, .height = 16 }, renderedRect(roomy.visual(0).?, window).?);
    try std.testing.expect(grid(.{ .x = 0, .y = 0, .width = 24, .height = 16 }, 0, window, 0) == null);
    try std.testing.expect(grid(.{ .x = 0, .y = 0, .width = 3, .height = 3 }, 4, window, 4) == null);
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
