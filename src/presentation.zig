//! Bounded ownership of imported buffers awaiting presentation completion.

const std = @import("std");
const objects = @import("wayring").objects;
const buffer_import = @import("buffer_import.zig");
const release = @import("release.zig");

const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    MissingLease,
    StalePresentation,
    ReleasesPending,
};

pub const QueueRelease = *const fn (
    context: ?*anyopaque,
    callback: objects.Handle,
) anyerror!void;

/// Fixed-capacity in-flight presentation storage. An admitted entry owns the
/// renderer/importer handle, source backing lease, and per-commit release batch
/// until successful completion or explicit discard. The queue must remain at a
/// stable address while entries are active.
pub fn Queue(comptime Imported: type) type {
    return struct {
        const Self = @This();
        const Dispose = *const fn (?*anyopaque, Imported) void;

        pub const Token = struct {
            queue: *Self,
            index: u32,
            generation: u32,
        };

        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            imported: Imported = undefined,
            lease: buffer_import.Lease = undefined,
            release_callbacks: ?release.Batch = null,
        };

        slots: []Slot,
        free_head: u32,
        active_count: usize = 0,
        dispose_context: ?*anyopaque,
        dispose: Dispose,

        pub fn init(
            allocator: std.mem.Allocator,
            capacity: usize,
            dispose_context: ?*anyopaque,
            dispose: Dispose,
        ) Error!Self {
            if (capacity == 0 or capacity >= none) return error.InvalidConfig;
            const slots = try allocator.alloc(Slot, capacity);
            for (slots, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
            };
            return .{
                .slots = slots,
                .free_head = 0,
                .dispose_context = dispose_context,
                .dispose = dispose,
            };
        }

        /// Discards every in-flight presentation during connection or
        /// compositor teardown, when callbacks can no longer be delivered.
        pub fn deinit(queue: *Self, allocator: std.mem.Allocator) void {
            for (queue.slots, 0..) |slot, index| {
                if (slot.active) queue.releaseSlot(@intCast(index));
            }
            allocator.free(queue.slots);
            queue.* = undefined;
        }

        pub fn available(queue: Self) usize {
            return queue.slots.len - queue.active_count;
        }

        /// Transactionally takes ownership from an applied content update.
        /// Exhaustion or a missing lease leaves both source optionals unchanged
        /// and leaves ownership of `imported` with the caller.
        pub fn admit(
            queue: *Self,
            imported: Imported,
            lease: *?buffer_import.Lease,
            release_callbacks: *?release.Batch,
        ) Error!Token {
            if (queue.free_head == none) return error.Exhausted;
            const owned_lease = lease.* orelse return error.MissingLease;
            const index = queue.free_head;
            const slot = &queue.slots[index];
            queue.free_head = slot.next_free;
            slot.* = .{
                .active = true,
                .generation = slot.generation,
                .imported = imported,
                .lease = owned_lease,
                .release_callbacks = release_callbacks.*,
            };
            lease.* = null;
            release_callbacks.* = null;
            queue.active_count += 1;
            return .{ .queue = queue, .index = index, .generation = slot.generation };
        }

        pub fn getImported(queue: *Self, token: Token) Error!*Imported {
            return &(try queue.resolve(token)).imported;
        }

        /// Queues callbacks in request order and consumes each only after the
        /// queue function succeeds. A failure leaves the current and remaining
        /// callbacks, imported handle, and backing lease available for retry.
        pub fn queueReleases(
            queue: *Self,
            token: Token,
            context: ?*anyopaque,
            queue_release: QueueRelease,
        ) anyerror!usize {
            const slot = try queue.resolve(token);
            const batch = if (slot.release_callbacks) |*value| value else return 0;
            var queued: usize = 0;
            while (batch.peek()) |callback| {
                try queue_release(context, callback);
                batch.consume(callback) catch unreachable;
                queued += 1;
            }
            return queued;
        }

        /// Completes presentation only after every release callback was queued.
        /// The imported handle is disposed before its source lease is dropped.
        pub fn finish(queue: *Self, token: Token) Error!void {
            const slot = try queue.resolve(token);
            if (slot.release_callbacks) |batch| if (batch.count != 0)
                return error.ReleasesPending;
            queue.releaseSlot(token.index);
        }

        /// Abandons an in-flight presentation without signaling release when
        /// its client connection is already terminal.
        pub fn discard(queue: *Self, token: Token) Error!void {
            _ = try queue.resolve(token);
            queue.releaseSlot(token.index);
        }

        fn resolve(queue: *Self, token: Token) Error!*Slot {
            if (token.queue != queue or token.index >= queue.slots.len)
                return error.StalePresentation;
            const slot = &queue.slots[token.index];
            if (!slot.active or slot.generation != token.generation)
                return error.StalePresentation;
            return slot;
        }

        fn releaseSlot(queue: *Self, index: u32) void {
            const slot = &queue.slots[index];
            if (slot.release_callbacks) |*batch| batch.deinit();
            queue.dispose(queue.dispose_context, slot.imported);
            slot.lease.deinit();
            slot.active = false;
            slot.generation +%= 1;
            slot.next_free = queue.free_head;
            slot.release_callbacks = null;
            queue.free_head = index;
            queue.active_count -= 1;
        }
    };
}

test "presentation admission and release queuing are transactional" {
    const Backings = buffer_import.Registry(u8);
    const Presentations = Queue(u16);
    var backing_disposals: usize = 0;
    var imported_disposals: usize = 0;
    const Dispose = struct {
        fn backing(context: ?*anyopaque, _: u8) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }

        fn imported(context: ?*anyopaque, _: u16) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var backings = try Backings.init(
        std.testing.allocator,
        2,
        &backing_disposals,
        Dispose.backing,
    );
    defer backings.deinit(std.testing.allocator);
    var presentations = try Presentations.init(
        std.testing.allocator,
        1,
        &imported_disposals,
        Dispose.imported,
    );
    defer presentations.deinit(std.testing.allocator);
    var release_pool = try release.Pool.init(std.testing.allocator, 2);
    defer release_pool.deinit(std.testing.allocator);
    var pending_releases = release.Queue.init(&release_pool);
    defer pending_releases.deinit();
    const first_callback: objects.Handle = .{ .id = 2, .generation = 1 };
    const second_callback: objects.Handle = .{ .id = 3, .generation = 1 };
    try pending_releases.request(first_callback);
    try pending_releases.request(second_callback);
    var callbacks = try pending_releases.commit(true);
    var lease: ?buffer_import.Lease = try backings.acquire(1);
    const presentation = try presentations.admit(7, &lease, &callbacks);
    try std.testing.expect(lease == null);
    try std.testing.expect(callbacks == null);
    try std.testing.expectEqual(@as(u16, 7), (try presentations.getImported(presentation)).*);

    var rejected_lease: ?buffer_import.Lease = try backings.acquire(2);
    var no_callbacks: ?release.Batch = null;
    try std.testing.expectError(
        error.Exhausted,
        presentations.admit(8, &rejected_lease, &no_callbacks),
    );
    try std.testing.expect(rejected_lease != null);
    rejected_lease.?.deinit();
    Dispose.imported(&imported_disposals, 8);

    const ReleaseState = struct {
        calls: usize = 0,
        fail_on: usize,

        fn queue(context: ?*anyopaque, _: objects.Handle) !void {
            const state: *@This() = @ptrCast(@alignCast(context.?));
            state.calls += 1;
            if (state.calls == state.fail_on) return error.Backpressure;
        }
    };
    var release_state: ReleaseState = .{ .fail_on = 2 };
    try std.testing.expectError(
        error.Backpressure,
        presentations.queueReleases(presentation, &release_state, ReleaseState.queue),
    );
    try std.testing.expectError(error.ReleasesPending, presentations.finish(presentation));
    release_state.fail_on = 0;
    try std.testing.expectEqual(
        @as(usize, 1),
        try presentations.queueReleases(presentation, &release_state, ReleaseState.queue),
    );
    try presentations.finish(presentation);
    try std.testing.expectError(error.StalePresentation, presentations.finish(presentation));
    try std.testing.expectEqual(@as(usize, 2), backing_disposals);
    try std.testing.expectEqual(@as(usize, 2), imported_disposals);
    try std.testing.expectEqual(@as(usize, 2), release_pool.available());
}

test "output removal completes and terminal teardown discards in-flight ownership" {
    const Backings = buffer_import.Registry(u8);
    const Presentations = Queue(u8);
    var disposals: usize = 0;
    const Dispose = struct {
        fn value(context: ?*anyopaque, _: u8) void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var backings = try Backings.init(std.testing.allocator, 1, &disposals, Dispose.value);
    defer backings.deinit(std.testing.allocator);
    var release_pool = try release.Pool.init(std.testing.allocator, 1);
    defer release_pool.deinit(std.testing.allocator);
    var pending_releases = release.Queue.init(&release_pool);
    defer pending_releases.deinit();
    try pending_releases.request(.{ .id = 2, .generation = 1 });
    var callbacks = try pending_releases.commit(true);
    var lease: ?buffer_import.Lease = try backings.acquire(1);
    var presentations = try Presentations.init(
        std.testing.allocator,
        1,
        &disposals,
        Dispose.value,
    );
    const removed_output = try presentations.admit(1, &lease, &callbacks);

    const Completion = struct {
        fn queue(context: ?*anyopaque, _: objects.Handle) !void {
            const count: *usize = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    var queued: usize = 0;
    try std.testing.expectEqual(
        @as(usize, 1),
        try presentations.queueReleases(removed_output, &queued, Completion.queue),
    );
    try presentations.finish(removed_output);
    try std.testing.expectEqual(@as(usize, 1), queued);
    try std.testing.expectEqual(@as(usize, 2), disposals);
    try std.testing.expectEqual(@as(usize, 1), release_pool.available());

    var disconnected_lease: ?buffer_import.Lease = try backings.acquire(2);
    var disconnected_callbacks: ?release.Batch = null;
    _ = try presentations.admit(2, &disconnected_lease, &disconnected_callbacks);
    presentations.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), disposals);
    try std.testing.expectEqual(@as(usize, 1), release_pool.available());
    try std.testing.expectEqual(@as(usize, 1), backings.available());
}
