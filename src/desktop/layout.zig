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

pub fn plan(items: []const Item, work_area: geometry.Rect, output: []Placement) ![]Placement {
    try work_area.validate();
    if (output.len < items.len) return error.Exhausted;
    if (items.len == 0) return output[0..0];
    if (items.len == 1) {
        output[0] = .{ .slot = items[0].slot, .rect = work_area };
        return output[0..1];
    }

    if (work_area.width < 2 or work_area.height < items.len - 1)
        return error.WorkAreaTooSmall;
    const master_width = @divTrunc(work_area.width + 1, 2);
    output[0] = .{
        .slot = items[0].slot,
        .rect = .{
            .x = work_area.x,
            .y = work_area.y,
            .width = master_width,
            .height = work_area.height,
        },
    };

    const stack_count: i32 = @intCast(items.len - 1);
    const base_height = @divTrunc(work_area.height, stack_count);
    const remainder = @mod(work_area.height, stack_count);
    var y = work_area.y;
    for (items[1..], 1..) |item, index| {
        const extra: i32 = if (index - 1 < remainder) 1 else 0;
        const height = base_height + extra;
        output[index] = .{
            .slot = item.slot,
            .rect = .{
                .x = work_area.x + master_width,
                .y = y,
                .width = work_area.width - master_width,
                .height = height,
            },
        };
        y += height;
    }
    return output[0..items.len];
}

test "desktop: basic layout is exact and deterministic" {
    const items = [_]Item{ .{ .slot = 7 }, .{ .slot = 2 }, .{ .slot = 9 }, .{ .slot = 4 } };
    var storage: [items.len]Placement = undefined;
    const result = try plan(
        &items,
        .{ .x = 10, .y = 20, .width = 101, .height = 50 },
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
        plan(&items, .{ .x = 0, .y = 0, .width = 1, .height = 10 }, &storage),
    );
    try std.testing.expectEqual(@as(u32, 99), storage[0].slot);
}
