//! Protocol- and renderer-neutral validated logical scene geometry.

const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn validate(rect: Rect) !void {
        if (rect.width <= 0 or rect.height <= 0) return error.InvalidGeometry;
        _ = std.math.add(i32, rect.x, rect.width) catch return error.InvalidGeometry;
        _ = std.math.add(i32, rect.y, rect.height) catch return error.InvalidGeometry;
    }

    pub fn contains(rect: Rect, point: Point) bool {
        return point.x >= rect.x and point.y >= rect.y and
            @as(i64, point.x) < @as(i64, rect.x) + rect.width and
            @as(i64, point.y) < @as(i64, rect.y) + rect.height;
    }
};

test "desktop: scene rectangles reject empty and overflowing geometry" {
    try Rect.validate(.{ .x = -10, .y = 4, .width = 20, .height = 30 });
    try std.testing.expectError(
        error.InvalidGeometry,
        Rect.validate(.{ .x = 0, .y = 0, .width = 0, .height = 1 }),
    );
    try std.testing.expectError(
        error.InvalidGeometry,
        Rect.validate(.{ .x = std.math.maxInt(i32), .y = 0, .width = 1, .height = 1 }),
    );
    const rect: Rect = .{ .x = -2, .y = 3, .width = 4, .height = 2 };
    try std.testing.expect(rect.contains(.{ .x = -2, .y = 3 }));
    try std.testing.expect(rect.contains(.{ .x = 1, .y = 4 }));
    try std.testing.expect(!rect.contains(.{ .x = 2, .y = 4 }));
}
