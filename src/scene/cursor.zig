//! Composited cursor placement without renderer or protocol ownership.
//!
//! The cursor retains only an exact generational surface identity and value
//! geometry. Composition relocates an already imported committed sample, so
//! its surface/commit and presentation generations remain unchanged.

const std = @import("std");
const geometry = @import("geometry.zig");
const render = @import("../render/types.zig");

pub fn Cursor(comptime SurfaceId: type) type {
    return struct {
        const Self = @This();

        pub const Source = struct {
            surface: SurfaceId,
            sample: render.SurfaceSample,
        };

        surface: ?SurfaceId = null,
        hotspot: geometry.Point = .{ .x = 0, .y = 0 },
        position: geometry.Point = .{ .x = 0, .y = 0 },
        pointer_available: bool = false,

        pub fn request(self: *Self, surface: ?SurfaceId, hotspot: geometry.Point) void {
            self.surface = surface;
            self.hotspot = hotspot;
        }

        pub fn move(self: *Self, position: geometry.Point) void {
            self.position = position;
        }

        pub fn surfaceDestroyed(self: *Self, surface: SurfaceId) void {
            if (self.surface) |current| {
                if (std.meta.eql(current, surface)) self.surface = null;
            }
        }

        /// Places a committed cursor sample last in the caller's render list.
        /// A stale source identity, hidden cursor, or fully clipped cursor
        /// returns null and never fabricates a render identity.
        pub fn composite(
            self: Self,
            source: Source,
            output: geometry.Rect,
        ) !?render.SurfaceSample {
            const surface = self.surface orelse return null;
            if (!self.pointer_available or !std.meta.eql(surface, source.surface)) return null;
            try output.validate();
            _ = try render.validateSample(source.sample);

            var sample = source.sample;
            sample.destination.x = std.math.sub(i32, self.position.x, self.hotspot.x) catch
                return error.InvalidDestination;
            sample.destination.y = std.math.sub(i32, self.position.y, self.hotspot.y) catch
                return error.InvalidDestination;
            const right = @min(
                @as(i64, output.x) + output.width,
                @as(i64, sample.destination.x) + sample.destination.width,
            );
            const bottom = @min(
                @as(i64, output.y) + output.height,
                @as(i64, sample.destination.y) + sample.destination.height,
            );
            const left = @max(@as(i64, output.x), sample.destination.x);
            const top = @max(@as(i64, output.y), sample.destination.y);
            if (right <= left or bottom <= top) return null;
            sample.clip = .{
                .x = @intCast(left),
                .y = @intCast(top),
                .width = @intCast(right - left),
                .height = @intCast(bottom - top),
            };
            _ = try render.validateSample(sample);
            return sample;
        }
    };
}

const TestId = packed struct { index: u32, generation: u32 };
const TestCursor = Cursor(TestId);

fn testSample() render.SurfaceSample {
    return .{
        .sample = .{ .surface = 0x0000_0007_0000_0002, .commit_sequence = 11 },
        .presentation = .{ .slot = 3, .generation = 9 },
        .source = .{
            .size = .{ .width = 4, .height = 3 },
            .stride = 16,
            .format = .argb8888_premultiplied,
            .bytes = &([_]u8{0xff} ** 48),
        },
        .crop = render.SourceRect.pixels(0, 0, 4, 3),
        .destination = .{ .x = 0, .y = 0, .width = 4, .height = 3 },
        .clip = .{ .x = 0, .y = 0, .width = 4, .height = 3 },
    };
}

test "interaction: composited cursor preserves exact committed identities" {
    const id: TestId = .{ .index = 2, .generation = 7 };
    var cursor = TestCursor{ .pointer_available = true };
    cursor.request(id, .{ .x = 1, .y = 1 });
    cursor.move(.{ .x = 8, .y = 6 });
    const original = testSample();
    const placed = (try cursor.composite(
        .{ .surface = id, .sample = original },
        .{ .x = 0, .y = 0, .width = 20, .height = 10 },
    )).?;
    try std.testing.expectEqual(original.sample, placed.sample);
    try std.testing.expectEqual(original.presentation, placed.presentation);
    try std.testing.expectEqual(render.Rect{ .x = 7, .y = 5, .width = 4, .height = 3 }, placed.destination);
    try std.testing.expectEqual(render.Rect{ .x = 7, .y = 5, .width = 4, .height = 3 }, placed.clip);
}

test "interaction: cursor clips at output edges and rejects stale surfaces" {
    const id: TestId = .{ .index = 2, .generation = 7 };
    var cursor = TestCursor{ .pointer_available = true };
    cursor.request(id, .{ .x = 2, .y = 2 });
    cursor.move(.{ .x = 1, .y = 1 });
    const placed = (try cursor.composite(
        .{ .surface = id, .sample = testSample() },
        .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    )).?;
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 0, .width = 3, .height = 2 }, placed.clip);
    try std.testing.expect((try cursor.composite(.{
        .surface = .{ .index = 2, .generation = 8 },
        .sample = testSample(),
    }, .{ .x = 0, .y = 0, .width = 10, .height = 10 })) == null);
    cursor.surfaceDestroyed(id);
    try std.testing.expect(cursor.surface == null);
}

test "interaction: cursor rejects relocated destination overflow" {
    const id: TestId = .{ .index = 2, .generation = 7 };
    var cursor = TestCursor{ .pointer_available = true };
    cursor.request(id, .{ .x = 0, .y = 0 });
    cursor.move(.{ .x = std.math.maxInt(i32) - 1, .y = 0 });
    try std.testing.expectError(error.InvalidDestination, cursor.composite(.{
        .surface = id,
        .sample = testSample(),
    }, .{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = 10 }));
}

test "interaction: composited cursor clips in global displaced output coordinates" {
    const id: TestId = .{ .index = 2, .generation = 7 };
    var cursor = TestCursor{ .pointer_available = true };
    cursor.request(id, .{ .x = 1, .y = 1 });
    cursor.move(.{ .x = 101, .y = -9 });
    const placed = (try cursor.composite(
        .{ .surface = id, .sample = testSample() },
        .{ .x = 100, .y = -10, .width = 20, .height = 10 },
    )).?;
    try std.testing.expectEqual(
        render.Rect{ .x = 100, .y = -10, .width = 4, .height = 3 },
        placed.destination,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 100, .y = -10, .width = 4, .height = 3 },
        placed.clip,
    );
}
