//! Allocation-free double-buffered crop and scale state.

const std = @import("std");

pub const Error = error{
    InvalidValue,
    InvalidSize,
    OutOfBuffer,
};

pub const fixed_one: i32 = 256;

pub const Size = struct {
    width: u32,
    height: u32,
};

/// Source coordinates use Wayland's signed 24.8 fixed-point representation.
pub const Source = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const unset_source: Source = .{
    .x = -fixed_one,
    .y = -fixed_one,
    .width = -fixed_one,
    .height = -fixed_one,
};

pub const State = struct {
    source_rect: Source = unset_source,
    destination_size: Size = .{ .width = 0, .height = 0 },

    pub fn source(state: State) ?Source {
        return if (state.source_rect.width > 0) state.source_rect else null;
    }

    pub fn destination(state: State) ?Size {
        return if (state.destination_size.width != 0) state.destination_size else null;
    }

    pub fn validate(state: State, content_size: ?Size) Error!void {
        if ((state.destination_size.width == 0) != (state.destination_size.height == 0))
            return error.InvalidValue;
        const rectangle = state.source() orelse return;
        if (rectangle.x < 0 or rectangle.y < 0 or rectangle.width <= 0 or rectangle.height <= 0)
            return error.InvalidValue;
        if (state.destination() == null and
            (@rem(rectangle.width, fixed_one) != 0 or @rem(rectangle.height, fixed_one) != 0))
            return error.InvalidSize;
        const size = content_size orelse return;
        const right = @as(i64, rectangle.x) + rectangle.width;
        const bottom = @as(i64, rectangle.y) + rectangle.height;
        if (right > @as(i64, size.width) * fixed_one or
            bottom > @as(i64, size.height) * fixed_one)
            return error.OutOfBuffer;
    }

    pub fn surfaceSize(state: State, content_size: ?Size) Size {
        if (content_size == null) return .{ .width = 0, .height = 0 };
        if (state.destination()) |size| return size;
        if (state.source()) |rectangle| return .{
            .width = @intCast(@divExact(rectangle.width, fixed_one)),
            .height = @intCast(@divExact(rectangle.height, fixed_one)),
        };
        return content_size.?;
    }
};

pub const Viewport = struct {
    current: State = .{},
    pending: State = .{},

    pub fn setSource(
        viewport: *Viewport,
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) Error!void {
        if (x == -fixed_one and y == -fixed_one and
            width == -fixed_one and height == -fixed_one)
        {
            viewport.pending.source_rect = unset_source;
            return;
        }
        if (x < 0 or y < 0 or width <= 0 or height <= 0)
            return error.InvalidValue;
        viewport.pending.source_rect = .{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
        };
    }

    pub fn setDestination(viewport: *Viewport, width: i32, height: i32) Error!void {
        if (width == -1 and height == -1) {
            viewport.pending.destination_size = .{ .width = 0, .height = 0 };
            return;
        }
        if (width <= 0 or height <= 0) return error.InvalidValue;
        viewport.pending.destination_size = .{
            .width = @intCast(width),
            .height = @intCast(height),
        };
    }

    /// Removes both properties from the next committed state, as destroying a
    /// wp_viewport object does.
    pub fn clear(viewport: *Viewport) void {
        viewport.pending = .{};
    }

    pub fn validateCommit(viewport: Viewport, content_size: ?Size) Error!void {
        try viewport.pending.validate(content_size);
    }

    pub fn publishCommit(viewport: *Viewport) State {
        viewport.current = viewport.pending;
        return viewport.current;
    }
};

test "viewport requests preserve valid pending state" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(State));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Viewport));
    var viewport: Viewport = .{};
    try std.testing.expectError(error.InvalidValue, viewport.setSource(0, 0, 0, fixed_one));
    try std.testing.expectError(error.InvalidValue, viewport.setDestination(10, -1));
    try std.testing.expectEqual(State{}, viewport.pending);

    try viewport.setSource(fixed_one, 2 * fixed_one, 3 * fixed_one, 4 * fixed_one);
    try viewport.setDestination(7, 8);
    try viewport.validateCommit(.{ .width = 4, .height = 6 });
    try std.testing.expectEqual(viewport.pending, viewport.publishCommit());

    try viewport.setSource(-fixed_one, -fixed_one, -fixed_one, -fixed_one);
    try viewport.setDestination(-1, -1);
    try std.testing.expectEqual(State{}, viewport.pending);
}

test "viewport validates source against effective content" {
    var viewport: Viewport = .{};
    try viewport.setSource(0, 0, fixed_one + 1, fixed_one);
    try std.testing.expectError(
        error.InvalidSize,
        viewport.validateCommit(.{ .width = 2, .height = 1 }),
    );
    try viewport.setDestination(3, 2);
    try viewport.validateCommit(.{ .width = 2, .height = 1 });
    try viewport.setSource(0, 0, 2 * fixed_one + 1, fixed_one);
    try std.testing.expectError(
        error.OutOfBuffer,
        viewport.validateCommit(.{ .width = 2, .height = 1 }),
    );
    try viewport.validateCommit(null);
    try std.testing.expectEqual(Size{ .width = 0, .height = 0 }, viewport.pending.surfaceSize(null));
}
