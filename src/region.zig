//! Shared allocation-free exact region operation storage.

const std = @import("std");

const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    InvalidRectangle,
};

pub const Rectangle = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

pub const Operation = union(enum) {
    add: Rectangle,
    subtract: Rectangle,
};

const Node = struct {
    operation: Operation = undefined,
    next: u32 = none,
};

/// Physical command nodes shared by every mutable region and surface snapshot
/// in one compositor shard.
pub const Pool = struct {
    nodes: []Node,
    free_head: u32,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Pool {
        if (capacity == 0 or capacity >= none) return error.InvalidConfig;
        const nodes = try allocator.alloc(Node, capacity);
        for (nodes, 0..) |*node, index| node.next = if (index + 1 < nodes.len)
            @intCast(index + 1)
        else
            none;
        return .{ .nodes = nodes, .free_head = 0 };
    }

    pub fn deinit(pool: *Pool, allocator: std.mem.Allocator) void {
        std.debug.assert(pool.active_count == 0);
        allocator.free(pool.nodes);
        pool.* = undefined;
    }

    pub fn available(pool: Pool) usize {
        return pool.nodes.len - pool.active_count;
    }

    pub fn allocatedBytes(pool: Pool) usize {
        return pool.nodes.len * @sizeOf(Node);
    }

    fn acquire(pool: *Pool, operation: Operation) Error!u32 {
        if (pool.free_head == none) return error.Exhausted;
        const index = pool.free_head;
        pool.free_head = pool.nodes[index].next;
        pool.nodes[index] = .{ .operation = operation };
        pool.active_count += 1;
        return index;
    }

    fn release(pool: *Pool, index: u32) void {
        pool.nodes[index].next = pool.free_head;
        pool.free_head = index;
        pool.active_count -= 1;
    }
};

/// An exact ordered union/subtraction program. Starting from empty and applying
/// its operations produces the Wayland region without canonicalization or
/// geometry allocation.
pub const Region = struct {
    pool: *Pool,
    head: u32 = none,
    tail: u32 = none,
    count: usize = 0,

    pub const Iterator = struct {
        region: *const Region,
        next_index: u32,

        pub fn next(self: *Iterator) ?Operation {
            if (self.next_index == none) return null;
            const node = self.region.pool.nodes[self.next_index];
            self.next_index = node.next;
            return node.operation;
        }
    };

    pub fn init(pool: *Pool) Region {
        return .{ .pool = pool };
    }

    pub fn deinit(region: *Region) void {
        region.clear();
        region.* = undefined;
    }

    pub fn clear(region: *Region) void {
        var index = region.head;
        while (index != none) {
            const next = region.pool.nodes[index].next;
            region.pool.release(index);
            index = next;
        }
        region.head = none;
        region.tail = none;
        region.count = 0;
    }

    pub fn add(region: *Region, rectangle: Rectangle) Error!void {
        try region.append(.{ .add = try validate(rectangle) });
    }

    pub fn subtract(region: *Region, rectangle: Rectangle) Error!void {
        try region.append(.{ .subtract = try validate(rectangle) });
    }

    pub fn iterator(region: *const Region) Iterator {
        return .{ .region = region, .next_index = region.head };
    }

    /// Replaces this region with an exact copy. Exhaustion leaves it unchanged.
    pub fn cloneFrom(region: *Region, source: *const Region) Error!void {
        if (region == source) return;
        var replacement = Region.init(region.pool);
        errdefer replacement.clear();
        var operations = source.iterator();
        while (operations.next()) |operation| try replacement.append(operation);
        std.mem.swap(Region, region, &replacement);
        replacement.clear();
    }

    fn append(region: *Region, operation: Operation) Error!void {
        const index = try region.pool.acquire(operation);
        if (region.tail == none) {
            region.head = index;
        } else {
            region.pool.nodes[region.tail].next = index;
        }
        region.tail = index;
        region.count += 1;
    }
};

fn validate(rectangle: Rectangle) Error!Rectangle {
    if (rectangle.width <= 0 or rectangle.height <= 0)
        return error.InvalidRectangle;
    return rectangle;
}

/// Double-buffered opaque and input region snapshots for one surface. Null
/// input is represented by `input_infinite`; null opaque is an empty region.
pub const SurfaceRegions = struct {
    current_opaque: Region,
    pending_opaque: Region,
    current_input: Region,
    pending_input: Region,
    current_input_infinite: bool = true,
    pending_input_infinite: bool = true,
    opaque_dirty: bool = false,
    input_dirty: bool = false,

    pub const Changes = struct {
        opaque_changed: bool,
        input_changed: bool,
    };

    pub const Prepared = struct {
        owner: *SurfaceRegions,
        next_opaque: Region,
        next_input: Region,
        changes: Changes,

        /// Releases prepared snapshots when a later preflight check fails.
        /// Calling this after `publish` is also valid; both temporaries are
        /// empty by then.
        pub fn deinit(prepared: *Prepared) void {
            prepared.next_opaque.clear();
            prepared.next_input.clear();
        }

        pub fn publish(prepared: *Prepared) Changes {
            const regions = prepared.owner;
            if (prepared.changes.opaque_changed) {
                std.mem.swap(Region, &regions.current_opaque, &prepared.next_opaque);
                prepared.next_opaque.clear();
                regions.opaque_dirty = false;
            }
            if (prepared.changes.input_changed) {
                std.mem.swap(Region, &regions.current_input, &prepared.next_input);
                prepared.next_input.clear();
                regions.current_input_infinite = regions.pending_input_infinite;
                regions.input_dirty = false;
            }
            return prepared.changes;
        }
    };

    pub fn init(pool: *Pool) SurfaceRegions {
        return .{
            .current_opaque = Region.init(pool),
            .pending_opaque = Region.init(pool),
            .current_input = Region.init(pool),
            .pending_input = Region.init(pool),
        };
    }

    pub fn deinit(regions: *SurfaceRegions) void {
        regions.current_opaque.deinit();
        regions.pending_opaque.deinit();
        regions.current_input.deinit();
        regions.pending_input.deinit();
        regions.* = undefined;
    }

    pub fn setOpaque(regions: *SurfaceRegions, source: ?*const Region) Error!void {
        if (source) |value| {
            try regions.pending_opaque.cloneFrom(value);
        } else {
            regions.pending_opaque.clear();
        }
        regions.opaque_dirty = true;
    }

    pub fn setInput(regions: *SurfaceRegions, source: ?*const Region) Error!void {
        if (source) |value| {
            try regions.pending_input.cloneFrom(value);
            regions.pending_input_infinite = false;
        } else {
            regions.pending_input.clear();
            regions.pending_input_infinite = true;
        }
        regions.input_dirty = true;
    }

    /// Evaluates the exact committed Wayland input-region program at one
    /// surface-local point. Surface bounds remain the caller's responsibility.
    pub fn inputContains(regions: *const SurfaceRegions, point: RectanglePoint) bool {
        var contains = regions.current_input_infinite;
        var operations = regions.current_input.iterator();
        while (operations.next()) |operation| switch (operation) {
            .add => |rectangle| if (rectangleContains(rectangle, point)) {
                contains = true;
            },
            .subtract => |rectangle| if (rectangleContains(rectangle, point)) {
                contains = false;
            },
        };
        return contains;
    }

    /// Prepares dirty region replacements without mutating current snapshots or
    /// dirty flags. This composes with other fallible commit preflight work.
    pub fn prepareCommit(regions: *SurfaceRegions) Error!Prepared {
        var next_opaque = Region.init(regions.current_opaque.pool);
        errdefer next_opaque.clear();
        var input = Region.init(regions.current_input.pool);
        errdefer input.clear();
        if (regions.opaque_dirty) try next_opaque.cloneFrom(&regions.pending_opaque);
        if (regions.input_dirty) try input.cloneFrom(&regions.pending_input);
        return .{
            .owner = regions,
            .next_opaque = next_opaque,
            .next_input = input,
            .changes = .{
                .opaque_changed = regions.opaque_dirty,
                .input_changed = regions.input_dirty,
            },
        };
    }

    /// Copies dirty pending regions atomically. Pool exhaustion leaves both
    /// current snapshots and dirty flags unchanged for retry or protocol error.
    pub fn commit(regions: *SurfaceRegions) Error!Changes {
        var prepared = try regions.prepareCommit();
        defer prepared.deinit();
        return prepared.publish();
    }
};

pub const RectanglePoint = struct { x: i32, y: i32 };

fn rectangleContains(rectangle: Rectangle, point: RectanglePoint) bool {
    return point.x >= rectangle.x and point.y >= rectangle.y and
        @as(i64, point.x) < @as(i64, rectangle.x) + rectangle.width and
        @as(i64, point.y) < @as(i64, rectangle.y) + rectangle.height;
}

test "interaction: committed input region preserves ordered add and subtract semantics" {
    var pool = try Pool.init(std.testing.allocator, 9);
    defer pool.deinit(std.testing.allocator);
    var source = Region.init(&pool);
    defer source.deinit();
    try source.add(.{ .x = 2, .y = 2, .width = 8, .height = 8 });
    try source.subtract(.{ .x = 4, .y = 4, .width = 4, .height = 4 });
    try source.add(.{ .x = 5, .y = 5, .width = 1, .height = 1 });
    var regions = SurfaceRegions.init(&pool);
    defer regions.deinit();
    try regions.setInput(&source);
    _ = try regions.commit();
    try std.testing.expect(!regions.inputContains(.{ .x = 1, .y = 1 }));
    try std.testing.expect(regions.inputContains(.{ .x = 3, .y = 3 }));
    try std.testing.expect(!regions.inputContains(.{ .x = 4, .y = 4 }));
    try std.testing.expect(regions.inputContains(.{ .x = 5, .y = 5 }));
}

test "shared regions preserve ordered exact operations and copy transactionally" {
    var pool = try Pool.init(std.testing.allocator, 5);
    defer pool.deinit(std.testing.allocator);
    var source = Region.init(&pool);
    defer source.deinit();
    var copy = Region.init(&pool);
    defer copy.deinit();
    try source.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });
    try source.subtract(.{ .x = 2, .y = 3, .width = 1, .height = 1 });
    try copy.cloneFrom(&source);
    try std.testing.expectEqual(@as(usize, 2), copy.count);
    try std.testing.expectError(error.InvalidRectangle, source.add(.{
        .x = 0,
        .y = 0,
        .width = 0,
        .height = 1,
    }));

    try source.add(.{ .x = 8, .y = 9, .width = 1, .height = 1 });
    try std.testing.expectError(error.Exhausted, copy.cloneFrom(&source));
    try std.testing.expectEqual(@as(usize, 2), copy.count);
}

test "surface region commit is atomic under shared pool pressure" {
    var pool = try Pool.init(std.testing.allocator, 5);
    defer pool.deinit(std.testing.allocator);
    var source = Region.init(&pool);
    defer source.deinit();
    try source.add(.{ .x = 1, .y = 2, .width = 3, .height = 4 });

    var regions = SurfaceRegions.init(&pool);
    defer regions.deinit();
    try regions.setOpaque(&source);
    try regions.setInput(&source);
    var blocker = Region.init(&pool);
    defer blocker.deinit();
    try blocker.add(.{ .x = 9, .y = 9, .width = 1, .height = 1 });
    try std.testing.expectError(error.Exhausted, regions.commit());
    try std.testing.expectEqual(@as(usize, 0), regions.current_opaque.count);
    try std.testing.expectEqual(@as(usize, 0), regions.current_input.count);
    try std.testing.expect(regions.opaque_dirty and regions.input_dirty);
    blocker.clear();

    const changes = try regions.commit();
    try std.testing.expect(changes.opaque_changed and changes.input_changed);
    try std.testing.expectEqual(@as(usize, 1), regions.current_opaque.count);
    try std.testing.expectEqual(@as(usize, 1), regions.current_input.count);
    try std.testing.expect(!regions.current_input_infinite);

    try regions.setInput(null);
    const null_change = try regions.commit();
    try std.testing.expect(null_change.input_changed);
    try std.testing.expect(regions.current_input_infinite);
}
