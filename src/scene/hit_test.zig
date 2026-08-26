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

/// Returns the topmost committed surface across rooted subsurface trees.
/// `scene.order` supplies each tree in renderer back-to-front order and
/// `scene.placement` supplies child offsets relative to the root surface.
pub fn topmostTree(
    comptime Window: type,
    windows: []const Window,
    point: geometry.Point,
    scene: anytype,
) ?Hit(Window) {
    var window_index = windows.len;
    while (window_index != 0) {
        window_index -= 1;
        const window = windows[window_index];
        if (!window.visible or !window.content_ready) continue;
        const surfaces = scene.order(window.surface) catch continue;
        var surface_index = surfaces.len;
        while (surface_index != 0) {
            surface_index -= 1;
            const surface = surfaces[surface_index];
            const root = std.meta.eql(surface, window.surface);
            const local: geometry.Point = if (root) root_local: {
                if (!window.geometry.contains(point)) continue;
                break :root_local .{
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
            } else child_local: {
                const placement = scene.placement(surface) catch continue;
                const root_x = if (window.has_window_geometry)
                    alignedOrigin(window.geometry.x, window.surface_offset.x)
                else
                    window.geometry.x;
                const root_y = if (window.has_window_geometry)
                    alignedOrigin(window.geometry.y, window.surface_offset.y)
                else
                    window.geometry.y;
                const surface_x = std.math.add(i32, root_x, placement.x) catch continue;
                const surface_y = std.math.add(i32, root_y, placement.y) catch continue;
                break :child_local .{
                    .x = std.math.sub(i32, point.x, surface_x) catch continue,
                    .y = std.math.sub(i32, point.y, surface_y) catch continue,
                };
            };
            if (!(scene.inputContains(surface, local) catch continue)) continue;
            return .{ .toplevel = window.id, .surface = surface, .local = local };
        }
    }
    return null;
}

fn alignedOrigin(target: i32, geometry_offset: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, target) - geometry_offset,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

const TestId = packed struct { index: u32, generation: u32 };
const TestWindow = struct {
    id: TestId,
    surface: TestId,
    geometry: geometry.Rect,
    has_window_geometry: bool = false,
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

test "interaction: subsurface hit test follows stacking placement and input regions" {
    const root = TestId{ .index = 1, .generation = 1 };
    const below = TestId{ .index = 2, .generation = 1 };
    const above = TestId{ .index = 3, .generation = 1 };
    const Scene = struct {
        order_storage: [3]TestId = .{ below, root, above },
        hole: ?TestId = null,

        pub fn order(self: *@This(), _: TestId) ![]const TestId {
            return &self.order_storage;
        }

        pub fn placement(_: *@This(), surface: TestId) !geometry.Point {
            if (std.meta.eql(surface, below)) return .{ .x = -4, .y = 2 };
            if (std.meta.eql(surface, above)) return .{ .x = 6, .y = 3 };
            return error.NotSubsurface;
        }

        pub fn inputContains(self: *@This(), surface: TestId, point: geometry.Point) !bool {
            if (self.hole != null and std.meta.eql(self.hole.?, surface)) return false;
            return point.x >= 0 and point.y >= 0 and point.x < 8 and point.y < 8;
        }
    };
    const window = TestWindow{
        .id = .{ .index = 10, .generation = 1 },
        .surface = root,
        .geometry = .{ .x = 10, .y = 10, .width = 8, .height = 8 },
        .visible = true,
        .content_ready = true,
    };
    var scene = Scene{};

    const child = topmostTree(TestWindow, &.{window}, .{ .x = 17, .y = 14 }, &scene).?;
    try std.testing.expectEqual(above, child.surface);
    try std.testing.expectEqual(geometry.Point{ .x = 1, .y = 1 }, child.local);

    scene.hole = above;
    const root_hit = topmostTree(TestWindow, &.{window}, .{ .x = 17, .y = 14 }, &scene).?;
    try std.testing.expectEqual(root, root_hit.surface);

    const outside_root = topmostTree(TestWindow, &.{window}, .{ .x = 7, .y = 13 }, &scene).?;
    try std.testing.expectEqual(below, outside_root.surface);
    try std.testing.expectEqual(geometry.Point{ .x = 1, .y = 1 }, outside_root.local);

    const offset_window = TestWindow{
        .id = window.id,
        .surface = root,
        .geometry = .{ .x = 20, .y = 20, .width = 8, .height = 8 },
        .has_window_geometry = true,
        .surface_offset = .{ .x = 3, .y = 4 },
        .visible = true,
        .content_ready = true,
    };
    scene.hole = null;
    const offset_child = topmostTree(
        TestWindow,
        &.{offset_window},
        .{ .x = 24, .y = 20 },
        &scene,
    ).?;
    try std.testing.expectEqual(above, offset_child.surface);
    try std.testing.expectEqual(geometry.Point{ .x = 1, .y = 1 }, offset_child.local);
}
