//! Allocation-free exact pointer confinement geometry.
//!
//! Motions are clipped to the first fixed-point coordinate outside the
//! intersection of the committed surface input region, the constraint region,
//! and the committed surface bounds. Rectangle boundaries partition a segment
//! into intervals with constant membership; probing those intervals avoids the
//! incorrect endpoint-only clamp which could jump across holes.

const std = @import("std");
const region = @import("../region.zig");

const parameter_one: u64 = 1 << 32;

pub const FixedPoint = struct {
    x: i64,
    y: i64,
};

pub const Size = struct {
    width: u32,
    height: u32,
};

pub const Program = struct {
    infinite: bool,
    operations: []const region.Operation,
};

/// The scratch requirement is at most four surface edges plus four edges per
/// operation across both programs, plus the endpoint.
pub fn scratchCapacity(input_operations: usize, constraint_operations: usize) !usize {
    const operation_count = try std.math.add(usize, input_operations, constraint_operations);
    const operation_edges = try std.math.mul(usize, operation_count, 4);
    return try std.math.add(usize, operation_edges, 5);
}

/// Clips `end` to the last representable 24.8 coordinate in the first
/// contiguous allowed portion of the segment beginning at `start`.
pub fn clip(
    start: FixedPoint,
    end: FixedPoint,
    size: Size,
    input: Program,
    constraint: Program,
    scratch: []u64,
) !FixedPoint {
    if (!contains(start, size, input, constraint)) return error.StartOutside;
    if (std.meta.eql(start, end)) return start;
    const required = try scratchCapacity(input.operations.len, constraint.operations.len);
    if (scratch.len < required) return error.Exhausted;

    var count: usize = 0;
    appendRectangleBoundaries(start, end, .{
        .x = 0,
        .y = 0,
        .width = std.math.cast(i32, size.width) orelse return error.InvalidSize,
        .height = std.math.cast(i32, size.height) orelse return error.InvalidSize,
    }, scratch, &count);
    appendProgramBoundaries(start, end, input.operations, scratch, &count);
    appendProgramBoundaries(start, end, constraint.operations, scratch, &count);
    scratch[count] = parameter_one;
    count += 1;
    sortAndDeduplicate(scratch, &count);

    var last_allowed: u64 = 0;
    var last_probed: ?u64 = null;
    for (scratch[0..count]) |boundary| {
        const first = if (boundary == 0) 0 else boundary - 1;
        const probes = [_]u64{ first, boundary, @min(boundary +| 1, parameter_one) };
        for (probes) |parameter| {
            if (last_probed != null and parameter <= last_probed.?) continue;
            last_probed = parameter;
            const point = pointAt(start, end, parameter);
            if (!contains(point, size, input, constraint))
                return pointAt(start, end, lastAllowedParameter(
                    start,
                    end,
                    size,
                    input,
                    constraint,
                    last_allowed,
                    parameter,
                ));
            last_allowed = parameter;
        }
    }
    return end;
}

pub fn contains(point: FixedPoint, size: Size, input: Program, constraint: Program) bool {
    const width_fixed = @as(i64, size.width) * 256;
    const height_fixed = @as(i64, size.height) * 256;
    if (point.x < 0 or point.y < 0 or point.x >= width_fixed or point.y >= height_fixed)
        return false;
    return programContains(input, point) and programContains(constraint, point);
}

fn lastAllowedParameter(
    start: FixedPoint,
    end: FixedPoint,
    size: Size,
    input: Program,
    constraint: Program,
    known_allowed: u64,
    known_outside: u64,
) u64 {
    var low = known_allowed;
    var high = known_outside;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        if (contains(pointAt(start, end, middle), size, input, constraint))
            low = middle
        else
            high = middle;
    }
    return low;
}

fn programContains(program: Program, point: FixedPoint) bool {
    var inside = program.infinite;
    for (program.operations) |operation| switch (operation) {
        .add => |rectangle| if (rectangleContains(rectangle, point)) {
            inside = true;
        },
        .subtract => |rectangle| if (rectangleContains(rectangle, point)) {
            inside = false;
        },
    };
    return inside;
}

fn rectangleContains(rectangle: region.Rectangle, point: FixedPoint) bool {
    const left = @as(i64, rectangle.x) * 256;
    const top = @as(i64, rectangle.y) * 256;
    const right = (@as(i64, rectangle.x) + rectangle.width) * 256;
    const bottom = (@as(i64, rectangle.y) + rectangle.height) * 256;
    return point.x >= left and point.y >= top and point.x < right and point.y < bottom;
}

fn appendProgramBoundaries(
    start: FixedPoint,
    end: FixedPoint,
    operations: []const region.Operation,
    scratch: []u64,
    count: *usize,
) void {
    for (operations) |operation| switch (operation) {
        inline else => |rectangle| appendRectangleBoundaries(start, end, rectangle, scratch, count),
    };
}

fn appendRectangleBoundaries(
    start: FixedPoint,
    end: FixedPoint,
    rectangle: region.Rectangle,
    scratch: []u64,
    count: *usize,
) void {
    const left = @as(i64, rectangle.x) * 256;
    const top = @as(i64, rectangle.y) * 256;
    const right = (@as(i64, rectangle.x) + rectangle.width) * 256;
    const bottom = (@as(i64, rectangle.y) + rectangle.height) * 256;
    inline for (.{ left, right }) |edge|
        if (boundaryParameter(start.x, end.x, edge)) |parameter| {
            scratch[count.*] = parameter;
            count.* += 1;
        };
    inline for (.{ top, bottom }) |edge|
        if (boundaryParameter(start.y, end.y, edge)) |parameter| {
            scratch[count.*] = parameter;
            count.* += 1;
        };
}

fn boundaryParameter(start: i64, end: i64, edge: i64) ?u64 {
    const delta = @as(i128, end) - start;
    const distance = @as(i128, edge) - start;
    if (delta == 0 or distance == 0) return null;
    if ((delta > 0) != (distance > 0)) return null;
    const magnitude: u128 = @intCast(if (distance < 0) -distance else distance);
    const total: u128 = @intCast(if (delta < 0) -delta else delta);
    if (magnitude > total) return null;
    return @intCast((magnitude * parameter_one) / total);
}

fn pointAt(start: FixedPoint, end: FixedPoint, parameter: u64) FixedPoint {
    return .{
        .x = interpolate(start.x, end.x, parameter),
        .y = interpolate(start.y, end.y, parameter),
    };
}

fn interpolate(start: i64, end: i64, parameter: u64) i64 {
    const delta = @as(i128, end) - start;
    const offset = @divFloor(delta * parameter, parameter_one);
    return @intCast(@as(i128, start) + offset);
}

fn sortAndDeduplicate(values: []u64, count: *usize) void {
    for (values[0..count.*], 0..) |value, index| {
        var destination = index;
        while (destination != 0 and values[destination - 1] > value) : (destination -= 1)
            values[destination] = values[destination - 1];
        values[destination] = value;
    }
    var unique: usize = 0;
    for (values[0..count.*]) |value| {
        if (unique != 0 and values[unique - 1] == value) continue;
        values[unique] = value;
        unique += 1;
    }
    count.* = unique;
}

fn fixed(integer: i64) i64 {
    return integer * 256;
}

test "confinement clips to committed surface bounds in both directions" {
    var scratch: [5]u64 = undefined;
    const unrestricted: Program = .{ .infinite = true, .operations = &.{} };
    try std.testing.expectEqual(
        FixedPoint{ .x = fixed(10) - 1, .y = fixed(5) },
        try clip(
            .{ .x = fixed(5), .y = fixed(5) },
            .{ .x = fixed(15), .y = fixed(5) },
            .{ .width = 10, .height = 10 },
            unrestricted,
            unrestricted,
            &scratch,
        ),
    );
    try std.testing.expectEqual(
        FixedPoint{ .x = 0, .y = fixed(5) },
        try clip(
            .{ .x = fixed(5), .y = fixed(5) },
            .{ .x = fixed(-5), .y = fixed(5) },
            .{ .width = 10, .height = 10 },
            unrestricted,
            unrestricted,
            &scratch,
        ),
    );
}

test "confinement stops at first hole instead of jumping to allowed endpoint" {
    const operations = [_]region.Operation{
        .{ .add = .{ .x = 0, .y = 0, .width = 20, .height = 10 } },
        .{ .subtract = .{ .x = 8, .y = 0, .width = 4, .height = 10 } },
    };
    var scratch: [13]u64 = undefined;
    const unrestricted: Program = .{ .infinite = true, .operations = &.{} };
    try std.testing.expectEqual(
        FixedPoint{ .x = fixed(8) - 1, .y = fixed(5) },
        try clip(
            .{ .x = fixed(5), .y = fixed(5) },
            .{ .x = fixed(15), .y = fixed(5) },
            .{ .width = 20, .height = 10 },
            unrestricted,
            .{ .infinite = false, .operations = &operations },
            &scratch,
        ),
    );
}

test "confinement intersects input and constraint regions exactly" {
    const input_operations = [_]region.Operation{
        .{ .add = .{ .x = 0, .y = 0, .width = 15, .height = 10 } },
    };
    const constraint_operations = [_]region.Operation{
        .{ .add = .{ .x = 2, .y = 0, .width = 8, .height = 10 } },
    };
    var scratch: [13]u64 = undefined;
    try std.testing.expectEqual(
        FixedPoint{ .x = fixed(2), .y = fixed(5) },
        try clip(
            .{ .x = fixed(3), .y = fixed(5) },
            .{ .x = fixed(-5), .y = fixed(5) },
            .{ .width = 20, .height = 10 },
            .{ .infinite = false, .operations = &input_operations },
            .{ .infinite = false, .operations = &constraint_operations },
            &scratch,
        ),
    );
}

test "confinement validates start and bounded scratch" {
    const unrestricted: Program = .{ .infinite = true, .operations = &.{} };
    var short: [4]u64 = undefined;
    try std.testing.expectError(error.StartOutside, clip(
        .{ .x = fixed(-1), .y = 0 },
        .{ .x = 0, .y = 0 },
        .{ .width = 10, .height = 10 },
        unrestricted,
        unrestricted,
        &short,
    ));
    try std.testing.expectError(error.Exhausted, clip(
        .{ .x = fixed(1), .y = fixed(1) },
        .{ .x = fixed(2), .y = fixed(2) },
        .{ .width = 10, .height = 10 },
        unrestricted,
        unrestricted,
        &short,
    ));
}
