//! Renderer- and protocol-neutral hit testing over one desktop scene snapshot.
//!
//! Windows are copied values ordered back-to-front. Surface input queries are
//! synchronous and receive the exact generational surface identity; stale or
//! concurrently destroyed candidates are skipped rather than retargeted.

const std = @import("std");
const geometry = @import("geometry.zig");

pub fn Hit(comptime Window: type) type {
    return struct {
        toplevel: @TypeOf(@as(Window, undefined).id),
        surface: @TypeOf(@as(Window, undefined).surface),
        local: geometry.Point,
    };
}

/// Returns the exact topmost visible, content-ready surface whose committed
/// input region contains `point`. `windows` must be ordered back-to-front.
pub fn topmost(
    comptime Window: type,
    windows: []const Window,
    point: geometry.Point,
    surfaces: anytype,
) ?Hit(Window) {
    var index = windows.len;
    while (index != 0) {
        index -= 1;
        const window = windows[index];
        if (!window.visible or !window.content_ready or !window.geometry.contains(point))
            continue;
        const local: geometry.Point = .{
            .x = std.math.add(
                i32,
                std.math.sub(i32, point.x, window.geometry.x) catch continue,
                window.surface_offset.x,
            ) catch continue,
            .y = std.math.add(
                i32,
                std.math.sub(i32, point.y, window.geometry.y) catch continue,
                window.surface_offset.y,
            ) catch continue,
        };
        if (!(surfaces.inputContains(window.surface, local) catch continue)) continue;
        return .{ .toplevel = window.id, .surface = window.surface, .local = local };
    }
    return null;
}

const TestId = packed struct { index: u32, generation: u32 };
const TestWindow = struct {
    id: TestId,
    surface: TestId,
    geometry: geometry.Rect,
    surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
    visible: bool,
    content_ready: bool,
};
const TestSurfaces = struct {
    stale: ?TestId = null,
    hole: ?geometry.Point = null,

    pub fn inputContains(self: *@This(), surface: TestId, point: geometry.Point) !bool {
        if (self.stale != null and std.meta.eql(self.stale.?, surface))
            return error.StaleSurface;
        return self.hole == null or !std.meta.eql(self.hole.?, point);
    }
};

test "interaction: hit test selects exact topmost visible committed identity" {
    const bottom = TestWindow{
        .id = .{ .index = 1, .generation = 4 },
        .surface = .{ .index = 11, .generation = 7 },
        .geometry = .{ .x = 0, .y = 0, .width = 20, .height = 20 },
        .visible = true,
        .content_ready = true,
    };
    const top = TestWindow{
        .id = .{ .index = 2, .generation = 8 },
        .surface = .{ .index = 12, .generation = 9 },
        .geometry = .{ .x = 5, .y = 5, .width = 20, .height = 20 },
        .surface_offset = .{ .x = 1, .y = 2 },
        .visible = true,
        .content_ready = true,
    };
    var surfaces = TestSurfaces{};
    const hit = topmost(TestWindow, &.{ bottom, top }, .{ .x = 7, .y = 8 }, &surfaces).?;
    try std.testing.expectEqual(top.id, hit.toplevel);
    try std.testing.expectEqual(top.surface, hit.surface);
    try std.testing.expectEqual(geometry.Point{ .x = 3, .y = 5 }, hit.local);

    surfaces.hole = .{ .x = 3, .y = 5 };
    const through_hole = topmost(TestWindow, &.{ bottom, top }, .{ .x = 7, .y = 8 }, &surfaces).?;
    try std.testing.expectEqual(bottom.surface, through_hole.surface);
}

test "interaction: hit test ignores hidden unready and stale topmost windows" {
    var windows = [_]TestWindow{
        .{
            .id = .{ .index = 1, .generation = 1 },
            .surface = .{ .index = 10, .generation = 2 },
            .geometry = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
            .visible = true,
            .content_ready = true,
        },
        .{
            .id = .{ .index = 2, .generation = 1 },
            .surface = .{ .index = 20, .generation = 3 },
            .geometry = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
            .visible = false,
            .content_ready = true,
        },
    };
    var surfaces = TestSurfaces{};
    try std.testing.expectEqual(
        windows[0].surface,
        topmost(TestWindow, &windows, .{ .x = 1, .y = 1 }, &surfaces).?.surface,
    );
    windows[1].visible = true;
    surfaces.stale = windows[1].surface;
    try std.testing.expectEqual(
        windows[0].surface,
        topmost(TestWindow, &windows, .{ .x = 1, .y = 1 }, &surfaces).?.surface,
    );
    windows[0].content_ready = false;
    try std.testing.expect(topmost(TestWindow, &windows, .{ .x = 1, .y = 1 }, &surfaces) == null);
}
