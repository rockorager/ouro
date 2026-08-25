//! Shared bounded per-commit wp_presentation_feedback ownership.

const std = @import("std");
const objects = @import("wayring").objects;

const none = std.math.maxInt(u32);

const Node = struct {
    callback: objects.Handle = undefined,
    next: u32 = none,
    output_cursor: usize = 0,
};

pub const Pool = struct {
    nodes: []Node,
    free_head: u32,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Pool {
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

    fn acquire(pool: *Pool, callback: objects.Handle) !u32 {
        if (pool.free_head == none) return error.Exhausted;
        const index = pool.free_head;
        pool.free_head = pool.nodes[index].next;
        pool.nodes[index] = .{ .callback = callback };
        pool.active_count += 1;
        return index;
    }

    fn release(pool: *Pool, index: u32) void {
        pool.nodes[index].next = pool.free_head;
        pool.free_head = index;
        pool.active_count -= 1;
    }
};

pub const Pending = struct {
    pool: *Pool,
    head: u32 = none,
    tail: u32 = none,
    count: usize = 0,

    pub fn init(pool: *Pool) Pending {
        return .{ .pool = pool };
    }

    pub fn deinit(pending: *Pending) void {
        while (pending.head != none) {
            const index = pending.head;
            pending.head = pending.pool.nodes[index].next;
            pending.pool.release(index);
        }
        pending.* = undefined;
    }

    pub fn request(pending: *Pending, callback: objects.Handle) !void {
        const index = try pending.pool.acquire(callback);
        if (pending.tail == none) pending.head = index else pending.pool.nodes[pending.tail].next = index;
        pending.tail = index;
        pending.count += 1;
    }

    pub fn publishCommit(pending: *Pending) ?Batch {
        if (pending.count == 0) return null;
        const batch: Batch = .{
            .pool = pending.pool,
            .head = pending.head,
            .tail = pending.tail,
            .count = pending.count,
        };
        pending.head = none;
        pending.tail = none;
        pending.count = 0;
        return batch;
    }

    pub fn absorb(pending: *Pending, batch: *Batch) void {
        std.debug.assert(pending.pool == batch.pool);
        if (batch.count == 0) return;
        if (pending.tail == none) pending.head = batch.head else pending.pool.nodes[pending.tail].next = batch.head;
        pending.tail = batch.tail;
        pending.count += batch.count;
        batch.head = none;
        batch.tail = none;
        batch.count = 0;
    }

    pub fn moveTo(pending: *Pending, destination: *Pending) void {
        var batch = pending.publishCommit() orelse return;
        destination.absorb(&batch);
    }

    pub fn peek(pending: Pending) ?objects.Handle {
        if (pending.head == none) return null;
        return pending.pool.nodes[pending.head].callback;
    }

    pub fn consume(pending: *Pending, callback: objects.Handle) !void {
        if (pending.head == none) return error.Empty;
        const index = pending.head;
        if (!std.meta.eql(pending.pool.nodes[index].callback, callback)) return error.WrongCallback;
        pending.head = pending.pool.nodes[index].next;
        pending.count -= 1;
        if (pending.head == none) pending.tail = none;
        pending.pool.release(index);
    }
};

pub const Item = struct {
    callback: objects.Handle,
    output_cursor: usize,
};

pub const Batch = struct {
    pool: *Pool,
    head: u32,
    tail: u32,
    count: usize,

    pub fn deinit(batch: *Batch) void {
        while (batch.head != none) {
            const index = batch.head;
            batch.head = batch.pool.nodes[index].next;
            batch.pool.release(index);
        }
        batch.tail = none;
        batch.count = 0;
    }

    pub fn peek(batch: Batch) ?Item {
        if (batch.head == none) return null;
        const node = batch.pool.nodes[batch.head];
        return .{ .callback = node.callback, .output_cursor = node.output_cursor };
    }

    pub fn advanceOutput(batch: *Batch, callback: objects.Handle, cursor: usize) !void {
        if (batch.head == none or !std.meta.eql(batch.pool.nodes[batch.head].callback, callback))
            return error.WrongCallback;
        batch.pool.nodes[batch.head].output_cursor = cursor;
    }

    pub fn consume(batch: *Batch, callback: objects.Handle) !void {
        if (batch.head == none) return error.Empty;
        const index = batch.head;
        if (!std.meta.eql(batch.pool.nodes[index].callback, callback)) return error.WrongCallback;
        batch.head = batch.pool.nodes[index].next;
        batch.count -= 1;
        if (batch.head == none) batch.tail = none;
        batch.pool.release(index);
    }
};

test "presentation feedback remains commit-owned across partial output publication" {
    var pool = try Pool.init(std.testing.allocator, 2);
    defer pool.deinit(std.testing.allocator);
    var pending = Pending.init(&pool);
    defer pending.deinit();
    const first: objects.Handle = .{ .id = 3, .generation = 1 };
    const second: objects.Handle = .{ .id = 4, .generation = 2 };
    try pending.request(first);
    try pending.request(second);
    var batch = pending.publishCommit().?;
    defer batch.deinit();
    try batch.advanceOutput(first, 2);
    try std.testing.expectEqual(@as(usize, 2), batch.peek().?.output_cursor);
    try batch.consume(first);
    try std.testing.expectEqual(second, batch.peek().?.callback);
}
