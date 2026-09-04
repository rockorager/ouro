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

pub const Snapshot = struct {
    infinite: bool,
    operations: []const Operation,
};

const Node = struct {
    operation: Operation = undefined,
    next: u32 = none,
};

/// Physical command nodes shared by every mutable region and surface snapshot
/// in one compositor shard.
pub const Pool = struct {
    allocator: std.mem.Allocator,
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
        return .{ .allocator = allocator, .nodes = nodes, .free_head = 0 };
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
        if (pool.free_head == none) try pool.grow();
        const index = pool.free_head;
        pool.free_head = pool.nodes[index].next;
        pool.nodes[index] = .{ .operation = operation };
        pool.active_count += 1;
        return index;
    }

    fn grow(pool: *Pool) Error!void {
        const old_len = pool.nodes.len;
        const new_len = @min(@as(usize, none), std.math.mul(usize, old_len, 2) catch none);
        if (new_len <= old_len) return error.OutOfMemory;
        pool.nodes = try pool.allocator.realloc(pool.nodes, new_len);
        for (pool.nodes[old_len..], old_len..) |*node, index| node.* = .{
            .next = if (index + 1 < new_len) @intCast(index + 1) else none,
        };
        pool.free_head = @intCast(old_len);
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

    /// Copies the exact ordered operation program into caller-owned storage.
    /// Insufficient capacity leaves `destination` untouched.
    pub fn copyOperations(region: *const Region, destination: []Operation) Error![]const Operation {
        if (destination.len < region.count) return error.Exhausted;
        var operations = region.iterator();
        var count: usize = 0;
        while (operations.next()) |operation| : (count += 1)
            destination[count] = operation;
        return destination[0..count];
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
    current_blur: Region,
    pending_blur: Region,
    current_input_infinite: bool = true,
    pending_input_infinite: bool = true,
    opaque_dirty: bool = false,
    input_dirty: bool = false,
    blur_dirty: bool = false,

    pub const Changes = struct {
        opaque_changed: bool = false,
        input_changed: bool = false,
        blur_changed: bool = false,
    };

    /// Versioned effect geometry retained by one content update. This prevents
    /// a later wl_surface commit from changing the regions of an older queued
    /// update before the compositor applies it.
    pub const EffectSnapshot = struct {
        allocator: std.mem.Allocator,
        opaque_operations: []Operation,
        blur_operations: []Operation,

        /// Transfers allocation ownership while leaving this snapshot safe to
        /// deinitialize with the rest of its originating content update.
        pub fn take(snapshot: *EffectSnapshot) EffectSnapshot {
            const owned = snapshot.*;
            snapshot.opaque_operations = snapshot.opaque_operations[0..0];
            snapshot.blur_operations = snapshot.blur_operations[0..0];
            return owned;
        }

        pub fn deinit(snapshot: *EffectSnapshot) void {
            snapshot.allocator.free(snapshot.blur_operations);
            snapshot.allocator.free(snapshot.opaque_operations);
            snapshot.* = undefined;
        }
    };

    pub const Prepared = struct {
        owner: *SurfaceRegions,
        next_opaque: Region,
        next_input: Region,
        next_blur: Region,
        changes: Changes,

        /// Releases prepared snapshots when a later preflight check fails.
        /// Calling this after `publish` is also valid; both temporaries are
        /// empty by then.
        pub fn deinit(prepared: *Prepared) void {
            prepared.next_opaque.clear();
            prepared.next_input.clear();
            prepared.next_blur.clear();
        }

        /// Copies the effective post-commit regions before publication, so a
        /// fallible snapshot allocation cannot partially publish a commit.
        pub fn effectSnapshot(prepared: *const Prepared) Error!EffectSnapshot {
            const opaque_source = if (prepared.changes.opaque_changed)
                &prepared.next_opaque
            else
                &prepared.owner.current_opaque;
            const blur_source = if (prepared.changes.blur_changed)
                &prepared.next_blur
            else
                &prepared.owner.current_blur;
            const allocator = prepared.owner.current_opaque.pool.allocator;
            const opaque_operations = try allocator.alloc(Operation, opaque_source.count);
            errdefer allocator.free(opaque_operations);
            const blur_operations = try allocator.alloc(Operation, blur_source.count);
            errdefer allocator.free(blur_operations);
            _ = opaque_source.copyOperations(opaque_operations) catch unreachable;
            _ = blur_source.copyOperations(blur_operations) catch unreachable;
            return .{
                .allocator = allocator,
                .opaque_operations = opaque_operations,
                .blur_operations = blur_operations,
            };
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
            if (prepared.changes.blur_changed) {
                std.mem.swap(Region, &regions.current_blur, &prepared.next_blur);
                prepared.next_blur.clear();
                regions.blur_dirty = false;
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
            .current_blur = Region.init(pool),
            .pending_blur = Region.init(pool),
        };
    }

    pub fn deinit(regions: *SurfaceRegions) void {
        regions.current_opaque.deinit();
        regions.pending_opaque.deinit();
        regions.current_input.deinit();
        regions.pending_input.deinit();
        regions.current_blur.deinit();
        regions.pending_blur.deinit();
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

    pub fn setBlur(regions: *SurfaceRegions, source: ?*const Region) Error!void {
        if (source) |value| {
            try regions.pending_blur.cloneFrom(value);
        } else {
            regions.pending_blur.clear();
        }
        regions.blur_dirty = true;
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

    /// Copies the committed input-region program. The returned slice belongs
    /// to the caller, so no mutable surface storage escapes this query.
    pub fn copyCurrentInput(
        regions: *const SurfaceRegions,
        destination: []Operation,
    ) Error!Snapshot {
        return .{
            .infinite = regions.current_input_infinite,
            .operations = try regions.current_input.copyOperations(destination),
        };
    }

    /// Prepares dirty region replacements without mutating current snapshots or
    /// dirty flags. This composes with other fallible commit preflight work.
    pub fn prepareCommit(regions: *SurfaceRegions) Error!Prepared {
        var next_opaque = Region.init(regions.current_opaque.pool);
        errdefer next_opaque.clear();
        var input = Region.init(regions.current_input.pool);
        errdefer input.clear();
        var blur = Region.init(regions.current_blur.pool);
        errdefer blur.clear();
        if (regions.opaque_dirty) try next_opaque.cloneFrom(&regions.pending_opaque);
        if (regions.input_dirty) try input.cloneFrom(&regions.pending_input);
        if (regions.blur_dirty) try blur.cloneFrom(&regions.pending_blur);
        return .{
            .owner = regions,
            .next_opaque = next_opaque,
            .next_input = input,
            .next_blur = blur,
            .changes = .{
                .opaque_changed = regions.opaque_dirty,
                .input_changed = regions.input_dirty,
                .blur_changed = regions.blur_dirty,
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

test "shared regions grow while preserving ordered exact operations" {
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
    try copy.cloneFrom(&source);
    try std.testing.expectEqual(@as(usize, 3), copy.count);
    try std.testing.expect(pool.nodes.len > 5);
}

test "committed input snapshot copies exact operations transactionally" {
    var pool = try Pool.init(std.testing.allocator, 6);
    defer pool.deinit(std.testing.allocator);
    var source = Region.init(&pool);
    defer source.deinit();
    try source.add(.{ .x = 1, .y = 2, .width = 10, .height = 20 });
    try source.subtract(.{ .x = 3, .y = 4, .width = 5, .height = 6 });
    var regions = SurfaceRegions.init(&pool);
    defer regions.deinit();
    try regions.setInput(&source);
    _ = try regions.commit();

    var too_small = [_]Operation{
        .{ .add = .{ .x = 99, .y = 98, .width = 2, .height = 1 } },
    };
    const sentinel = too_small[0];
    try std.testing.expectError(error.Exhausted, regions.copyCurrentInput(&too_small));
    try std.testing.expectEqual(sentinel, too_small[0]);

    var copied: [2]Operation = undefined;
    const snapshot = try regions.copyCurrentInput(&copied);
    try std.testing.expect(!snapshot.infinite);
    try std.testing.expectEqualSlices(Operation, &.{
        .{ .add = .{ .x = 1, .y = 2, .width = 10, .height = 20 } },
        .{ .subtract = .{ .x = 3, .y = 4, .width = 5, .height = 6 } },
    }, snapshot.operations);
}

test "surface region commit grows shared pool atomically" {
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
    const changes = try regions.commit();
    try std.testing.expect(changes.opaque_changed and changes.input_changed);
    try std.testing.expectEqual(@as(usize, 1), regions.current_opaque.count);
    try std.testing.expectEqual(@as(usize, 1), regions.current_input.count);
    try std.testing.expect(!regions.current_input_infinite);
    try std.testing.expect(pool.nodes.len > 5);
    blocker.clear();

    try regions.setInput(null);
    const null_change = try regions.commit();
    try std.testing.expect(null_change.input_changed);
    try std.testing.expect(regions.current_input_infinite);
}

test "blur regions are double buffered and content snapshots remain immutable" {
    var pool = try Pool.init(std.testing.allocator, 8);
    defer pool.deinit(std.testing.allocator);
    var first = Region.init(&pool);
    defer first.deinit();
    try first.add(.{ .x = 1, .y = 2, .width = 30, .height = 20 });
    try first.subtract(.{ .x = 5, .y = 6, .width = 7, .height = 8 });
    var second = Region.init(&pool);
    defer second.deinit();
    try second.add(.{ .x = 40, .y = 50, .width = 9, .height = 10 });

    var regions = SurfaceRegions.init(&pool);
    defer regions.deinit();
    try regions.setBlur(&first);
    try std.testing.expectEqual(@as(usize, 0), regions.current_blur.count);
    var prepared = try regions.prepareCommit();
    var snapshot = try prepared.effectSnapshot();
    var retained = snapshot.take();
    defer retained.deinit();
    snapshot.deinit();
    _ = prepared.publish();
    prepared.deinit();

    try regions.setBlur(&second);
    _ = try regions.commit();
    try std.testing.expectEqualSlices(Operation, &.{
        .{ .add = .{ .x = 1, .y = 2, .width = 30, .height = 20 } },
        .{ .subtract = .{ .x = 5, .y = 6, .width = 7, .height = 8 } },
    }, retained.blur_operations);
    var current: [1]Operation = undefined;
    try std.testing.expectEqualSlices(
        Operation,
        &.{.{ .add = .{ .x = 40, .y = 50, .width = 9, .height = 10 } }},
        try regions.current_blur.copyOperations(&current),
    );
}
