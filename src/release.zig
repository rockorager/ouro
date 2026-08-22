//! Shared allocation-free per-content-update buffer release callbacks.

const std = @import("std");
const objects = @import("wayring").objects;

const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    MissingBuffer,
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

/// Callbacks detached from one surface commit. Embed this value in the content
/// update payload, then complete it only after the compositor no longer uses
/// that commit's underlying buffer storage.
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

    pub fn peek(batch: Batch) ?objects.Handle {
        if (batch.head == none) return null;
        return batch.pool.nodes[batch.head].callback;
    }

    /// Consume only after callback.done(0) and delete_id are successfully
    /// queued, so transport backpressure cannot lose release notification.
    pub fn consume(batch: *Batch, callback: objects.Handle) Error!void {
        if (batch.head == none) return error.Empty;
        const index = batch.head;
        if (!std.meta.eql(batch.pool.nodes[index].callback, callback))
            return error.WrongCallback;
        batch.head = batch.pool.nodes[index].next;
        batch.count -= 1;
        if (batch.head == none) batch.tail = none;
        batch.pool.release(index);
    }
};

/// Pending `wl_surface.get_release` requests for one surface. `commit` detaches
/// them in O(1), producing independently releasable per-content-update state.
pub const Queue = struct {
    pool: *Pool,
    head: u32 = none,
    tail: u32 = none,
    count: usize = 0,

    pub fn init(pool: *Pool) Queue {
        return .{ .pool = pool };
    }

    pub fn deinit(queue: *Queue) void {
        while (queue.head != none) {
            const index = queue.head;
            queue.head = queue.pool.nodes[index].next;
            queue.pool.release(index);
        }
        queue.* = undefined;
    }

    pub fn request(queue: *Queue, callback: objects.Handle) Error!void {
        const index = try queue.pool.acquire(callback);
        if (queue.tail == none) queue.head = index else queue.pool.nodes[queue.tail].next = index;
        queue.tail = index;
        queue.count += 1;
    }

    pub fn validateCommit(queue: Queue, has_attached_buffer: bool) Error!void {
        if (queue.count != 0 and !has_attached_buffer) return error.MissingBuffer;
    }

    /// Detaches validated pending callbacks without a failure path.
    pub fn publishCommit(queue: *Queue) ?Batch {
        if (queue.count == 0) return null;
        const batch: Batch = .{
            .pool = queue.pool,
            .head = queue.head,
            .tail = queue.tail,
            .count = queue.count,
        };
        queue.head = none;
        queue.tail = none;
        queue.count = 0;
        return batch;
    }

    /// The non-null attachment requirement and detachment are transactional.
    /// A protocol-error caller can still deinitialize the unchanged queue.
    pub fn commit(queue: *Queue, has_attached_buffer: bool) Error!?Batch {
        try queue.validateCommit(has_attached_buffer);
        return queue.publishCommit();
    }
};

test "release callbacks detach per commit and preserve order" {
    var pool = try Pool.init(std.testing.allocator, 3);
    defer pool.deinit(std.testing.allocator);
    var queue = Queue.init(&pool);
    defer queue.deinit();
    const first: objects.Handle = .{ .id = 2, .generation = 1 };
    const second: objects.Handle = .{ .id = 3, .generation = 1 };
    const third: objects.Handle = .{ .id = 4, .generation = 1 };
    try queue.request(first);
    try queue.request(second);
    var first_commit = (try queue.commit(true)).?;
    defer first_commit.deinit();
    try queue.request(third);
    var second_commit = (try queue.commit(true)).?;
    defer second_commit.deinit();

    try std.testing.expectEqual(first, first_commit.peek().?);
    try std.testing.expectEqual(third, second_commit.peek().?);
    try std.testing.expectError(error.WrongCallback, first_commit.consume(second));
    try first_commit.consume(first);
    try first_commit.consume(second);
    try std.testing.expectError(error.Empty, first_commit.consume(second));
    try second_commit.consume(third);
    try std.testing.expectEqual(@as(usize, 3), pool.available());
}

test "missing buffers and shared pool pressure are transactional" {
    var pool = try Pool.init(std.testing.allocator, 1);
    defer pool.deinit(std.testing.allocator);
    var first = Queue.init(&pool);
    defer first.deinit();
    var second = Queue.init(&pool);
    defer second.deinit();
    const callback: objects.Handle = .{ .id = 2, .generation = 1 };
    try first.request(callback);
    try std.testing.expectError(error.Exhausted, second.request(callback));
    try std.testing.expectError(error.MissingBuffer, first.commit(false));
    try std.testing.expectEqual(@as(usize, 1), first.count);
    var batch = (try first.commit(true)).?;
    defer batch.deinit();
    try std.testing.expectEqual(@as(?Batch, null), try first.commit(false));
}
