//! Shared allocation-free wl_surface callback queue storage.

const std = @import("std");
const objects = @import("wayring").objects;

const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    Empty,
    WrongCallback,
};

const Node = struct {
    callback: objects.Handle = undefined,
    next: u32 = none,
};

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

    fn acquire(pool: *Pool, callback: objects.Handle) Error!u32 {
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

/// Frame callbacks owned by one content update until that update applies.
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
};

/// Pending callbacks become ready atomically with the next surface commit.
/// Ready callbacks preserve request and commit order. Callers peek, enqueue
/// callback.done/delete_id transactionally, then consume only after success.
pub const Queue = struct {
    pool: *Pool,
    pending_head: u32 = none,
    pending_tail: u32 = none,
    ready_head: u32 = none,
    ready_tail: u32 = none,
    pending_count: usize = 0,
    ready_count: usize = 0,

    pub fn init(pool: *Pool) Queue {
        return .{ .pool = pool };
    }

    pub fn deinit(queue: *Queue) void {
        queue.clearList(queue.pending_head);
        queue.clearList(queue.ready_head);
        queue.* = undefined;
    }

    pub fn addPending(queue: *Queue, callback: objects.Handle) Error!void {
        const index = try queue.pool.acquire(callback);
        if (queue.pending_tail == none) {
            queue.pending_head = index;
        } else {
            queue.pool.nodes[queue.pending_tail].next = index;
        }
        queue.pending_tail = index;
        queue.pending_count += 1;
    }

    /// Detaches pending callbacks into per-content-update ownership in O(1).
    pub fn detachPending(queue: *Queue) ?Batch {
        if (queue.pending_count == 0) return null;
        const batch: Batch = .{
            .pool = queue.pool,
            .head = queue.pending_head,
            .tail = queue.pending_tail,
            .count = queue.pending_count,
        };
        queue.pending_head = none;
        queue.pending_tail = none;
        queue.pending_count = 0;
        return batch;
    }

    /// Makes callbacks ready when their owning content update applies.
    pub fn activate(queue: *Queue, batch: *Batch) usize {
        std.debug.assert(batch.pool == queue.pool);
        const activated = batch.count;
        if (activated == 0) return 0;
        if (queue.ready_tail == none) {
            queue.ready_head = batch.head;
        } else {
            queue.pool.nodes[queue.ready_tail].next = batch.head;
        }
        queue.ready_tail = batch.tail;
        queue.ready_count += activated;
        batch.head = none;
        batch.tail = none;
        batch.count = 0;
        return activated;
    }

    /// Splices all pending callbacks onto the ready queue in O(1).
    pub fn commit(queue: *Queue) usize {
        var batch = queue.detachPending() orelse return 0;
        return queue.activate(&batch);
    }

    pub fn peekReady(queue: Queue) ?objects.Handle {
        if (queue.ready_head == none) return null;
        return queue.pool.nodes[queue.ready_head].callback;
    }

    pub fn consumeReady(queue: *Queue, callback: objects.Handle) Error!void {
        if (queue.ready_head == none) return error.Empty;
        const index = queue.ready_head;
        const actual = queue.pool.nodes[index].callback;
        if (!std.meta.eql(actual, callback)) return error.WrongCallback;
        queue.ready_head = queue.pool.nodes[index].next;
        queue.ready_count -= 1;
        if (queue.ready_head == none) queue.ready_tail = none;
        queue.pool.release(index);
    }

    fn clearList(queue: *Queue, head: u32) void {
        var index = head;
        while (index != none) {
            const next = queue.pool.nodes[index].next;
            queue.pool.release(index);
            index = next;
        }
    }
};

test "frame callbacks preserve request and commit order" {
    var pool = try Pool.init(std.testing.allocator, 3);
    defer pool.deinit(std.testing.allocator);
    var queue = Queue.init(&pool);
    defer queue.deinit();
    const first: objects.Handle = .{ .id = 2, .generation = 1 };
    const second: objects.Handle = .{ .id = 3, .generation = 1 };
    const third: objects.Handle = .{ .id = 4, .generation = 1 };

    try queue.addPending(first);
    try queue.addPending(second);
    try std.testing.expectEqual(@as(?objects.Handle, null), queue.peekReady());
    try std.testing.expectEqual(@as(usize, 2), queue.commit());
    try queue.addPending(third);
    try std.testing.expectEqual(first, queue.peekReady().?);
    try std.testing.expectEqual(@as(usize, 1), queue.commit());
    try std.testing.expectError(error.WrongCallback, queue.consumeReady(second));
    try queue.consumeReady(first);
    try queue.consumeReady(second);
    try queue.consumeReady(third);
    try std.testing.expectError(error.Empty, queue.consumeReady(third));
}

test "frame callback capacity is shared" {
    var pool = try Pool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var first = Queue.init(&pool);
    defer first.deinit();
    var second = Queue.init(&pool);
    defer second.deinit();
    const callback: objects.Handle = .{ .id = 2, .generation = 1 };
    try first.addPending(callback);
    try std.testing.expectError(error.Exhausted, second.addPending(callback));
    try std.testing.expectEqual(@as(usize, 0), second.pending_count);
}

test "frame callbacks remain owned by a content update until activation" {
    var pool = try Pool.init(std.testing.allocator, 2);
    defer pool.deinit(std.testing.allocator);
    var queue = Queue.init(&pool);
    defer queue.deinit();
    const callback: objects.Handle = .{ .id = 2, .generation = 1 };
    try queue.addPending(callback);
    var batch = queue.detachPending().?;
    defer batch.deinit();
    try std.testing.expectEqual(@as(?objects.Handle, null), queue.peekReady());
    try std.testing.expectEqual(@as(usize, 1), queue.activate(&batch));
    try std.testing.expectEqual(callback, queue.peekReady().?);
    try queue.consumeReady(callback);
}
