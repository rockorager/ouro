//! Pure deterministic tiling policy. The first tiled window is the master; remaining
//! windows share a stack. Integer remainders are assigned from the start so
//! every pixel in the work area has exactly one owner.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");

pub const Item = struct {
    slot: u32,
};

pub const Placement = struct {
    slot: u32,
    rect: geometry.Rect,
};

pub fn validate(items_len: usize, work_area: geometry.Rect, inner: u32, outer: u32) !void {
    try work_area.validate();
    const inner_i32 = std.math.cast(i32, inner) orelse return error.WorkAreaTooSmall;
    const outer_i32 = std.math.cast(i32, outer) orelse return error.WorkAreaTooSmall;
    const outer_total = std.math.mul(i32, outer_i32, 2) catch return error.WorkAreaTooSmall;
    const width = std.math.sub(i32, work_area.width, outer_total) catch return error.WorkAreaTooSmall;
    const height = std.math.sub(i32, work_area.height, outer_total) catch return error.WorkAreaTooSmall;
    if (width < 1 or height < 1) return error.WorkAreaTooSmall;
    if (items_len < 2) return;

    const stack_count = items_len - 1;
    const stack_gaps = std.math.mul(usize, inner, stack_count - 1) catch
        return error.WorkAreaTooSmall;
    const stack_gaps_i32 = std.math.cast(i32, stack_gaps) orelse
        return error.WorkAreaTooSmall;
    if (width - inner_i32 < 2 or height - stack_gaps_i32 < stack_count)
        return error.WorkAreaTooSmall;
}

pub fn plan(items: []const Item, work_area: geometry.Rect, inner: u32, outer: u32, output: []Placement) ![]Placement {
    if (output.len < items.len) return error.Exhausted;
    try validate(items.len, work_area, inner, outer);
    if (items.len == 0) return output[0..0];

    const inner_i32: i32 = @intCast(inner);
    const outer_i32: i32 = @intCast(outer);
    const area = geometry.Rect{
        .x = work_area.x + outer_i32,
        .y = work_area.y + outer_i32,
        .width = work_area.width - outer_i32 * 2,
        .height = work_area.height - outer_i32 * 2,
    };
    if (items.len == 1) {
        output[0] = .{ .slot = items[0].slot, .rect = area };
        return output[0..1];
    }

    const usable_width = area.width - inner_i32;
    const master_width = @divTrunc(usable_width + 1, 2);
    output[0] = .{
        .slot = items[0].slot,
        .rect = .{
            .x = area.x,
            .y = area.y,
            .width = master_width,
            .height = area.height,
        },
    };

    const stack_count: i32 = @intCast(items.len - 1);
    const usable_height = area.height - inner_i32 * (stack_count - 1);
    const base_height = @divTrunc(usable_height, stack_count);
    const remainder = @mod(usable_height, stack_count);
    var y = area.y;
    for (items[1..], 1..) |item, index| {
        const extra: i32 = if (index - 1 < remainder) 1 else 0;
        const height = base_height + extra;
        output[index] = .{
            .slot = item.slot,
            .rect = .{
                .x = area.x + master_width + inner_i32,
                .y = y,
                .width = usable_width - master_width,
                .height = height,
            },
        };
        y += height + inner_i32;
    }
    return output[0..items.len];
}

test "desktop: basic layout is exact and deterministic" {
    const items = [_]Item{ .{ .slot = 7 }, .{ .slot = 2 }, .{ .slot = 9 }, .{ .slot = 4 } };
    var storage: [items.len]Placement = undefined;
    const result = try plan(
        &items,
        .{ .x = 10, .y = 20, .width = 101, .height = 50 },
        0,
        0,
        &storage,
    );
    try std.testing.expectEqualSlices(Placement, &.{
        .{ .slot = 7, .rect = .{ .x = 10, .y = 20, .width = 51, .height = 50 } },
        .{ .slot = 2, .rect = .{ .x = 61, .y = 20, .width = 50, .height = 17 } },
        .{ .slot = 9, .rect = .{ .x = 61, .y = 37, .width = 50, .height = 17 } },
        .{ .slot = 4, .rect = .{ .x = 61, .y = 54, .width = 50, .height = 16 } },
    }, result);
}

test "desktop: layout failure does not touch caller output" {
    const items = [_]Item{ .{ .slot = 1 }, .{ .slot = 2 } };
    var storage = [_]Placement{
        .{ .slot = 99, .rect = .{ .x = 1, .y = 2, .width = 3, .height = 4 } },
        undefined,
    };
    try std.testing.expectError(
        error.WorkAreaTooSmall,
        plan(&items, .{ .x = 0, .y = 0, .width = 1, .height = 10 }, 0, 0, &storage),
    );
    try std.testing.expectEqual(@as(u32, 99), storage[0].slot);
}

test "desktop: layout applies exact inner and outer gaps" {
    const items = [_]Item{ .{ .slot = 1 }, .{ .slot = 2 }, .{ .slot = 3 } };
    var storage: [items.len]Placement = undefined;
    const result = try plan(&items, .{ .x = 10, .y = 20, .width = 100, .height = 60 }, 3, 4, &storage);
    try std.testing.expectEqualSlices(Placement, &.{
        .{ .slot = 1, .rect = .{ .x = 14, .y = 24, .width = 45, .height = 52 } },
        .{ .slot = 2, .rect = .{ .x = 62, .y = 24, .width = 44, .height = 25 } },
        .{ .slot = 3, .rect = .{ .x = 62, .y = 52, .width = 44, .height = 24 } },
    }, result);
    try std.testing.expectError(error.WorkAreaTooSmall, validate(items.len, .{ .x = 0, .y = 0, .width = 20, .height = 10 }, 5, 3));
}
