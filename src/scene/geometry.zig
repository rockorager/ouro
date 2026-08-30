//! Protocol- and renderer-neutral validated logical scene geometry.

const std = @import("std");

pub const Point = struct {
    x: i32,
    y: i32,
};

/// Output scale in the fractional-scale protocol's 1/120 units. Compositor
/// geometry stays logical; render destinations are converted by scaling both
/// rectangle edges so adjacent logical rectangles remain adjacent physically.
pub const OutputScale = struct {
    value_120: u32,

    pub fn init(value_120: u32) !OutputScale {
        if (value_120 == 0) return error.InvalidScale;
        return .{ .value_120 = value_120 };
    }

    /// Converts a physical mode dimension to compositor-logical units using
    /// the protocol-defined floor operation.
    pub fn logicalDimension(scale: OutputScale, physical: u32) !i32 {
        if (physical == 0) return error.InvalidDimension;
        const result = @divTrunc(@as(u64, physical) * 120, scale.value_120);
        if (result == 0 or result > std.math.maxInt(i32)) return error.InvalidDimension;
        return @intCast(result);
    }

    /// Maps one signed logical edge to physical pixels using round-half-away
    /// from zero, matching Keywork's scene transform and avoiding a directional
    /// bias for windows that extend left or above the output origin.
    pub fn physicalEdge(scale: OutputScale, logical: i64) !i64 {
        const numerator = std.math.mul(i64, logical, scale.value_120) catch
            return error.InvalidGeometry;
        var result = @divTrunc(numerator, 120);
        const remainder = @rem(numerator, 120);
        if (@abs(remainder) >= 60) result = std.math.add(
            i64,
            result,
            if (numerator < 0) -1 else 1,
        ) catch return error.InvalidGeometry;
        return result;
    }
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

test "desktop: output scale floors dimensions and rounds signed edges" {
    const fractional = try OutputScale.init(156);
    try std.testing.expectEqual(@as(i32, 1476), try fractional.logicalDimension(1920));
    try std.testing.expectEqual(@as(i32, 923), try fractional.logicalDimension(1200));
    try std.testing.expectEqual(@as(i64, 1), try fractional.physicalEdge(1));
    try std.testing.expectEqual(@as(i64, 3), try fractional.physicalEdge(2));
    try std.testing.expectEqual(@as(i64, -1), try fractional.physicalEdge(-1));
    try std.testing.expectEqual(@as(i64, -3), try fractional.physicalEdge(-2));

    const half = try OutputScale.init(60);
    try std.testing.expectEqual(@as(i64, 1), try half.physicalEdge(1));
    try std.testing.expectEqual(@as(i64, -1), try half.physicalEdge(-1));
    try std.testing.expectError(error.InvalidScale, OutputScale.init(0));
    try std.testing.expectError(
        error.InvalidDimension,
        (try OutputScale.init(121)).logicalDimension(1),
    );
}
