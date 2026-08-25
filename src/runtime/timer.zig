//! Bounded one-shot monotonic deadlines prepared on Ouro's shared io_uring.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("completion.zig");

const none = std.math.maxInt(u32);
const max_slots = std.math.maxInt(u32);

pub const Deadline = linux.kernel_timespec;

pub const Handle = struct {
    slot: u32,
    generation: u32,
};

/// `fired` and `canceled` are the only policy-relevant outcomes and occur at
/// most once. The cleanup events only describe the second, cancellation SQE:
/// a handle remains occupied after `pending_cleanup` and is released by the
/// target timeout CQE; `cleanup_complete` releases a handle whose timeout CQE
/// was already observed.
pub const Event = enum {
    fired,
    canceled,
    pending_cleanup,
    cleanup_complete,
};

pub const Completion = struct {
    handle: Handle,
    event: Event,
};

pub const Error = std.mem.Allocator.Error || completion.Error || error{
    InvalidConfig,
    InvalidDeadline,
    Exhausted,
    StaleHandle,
    CancellationPending,
    SubmissionQueueFull,
    UnknownToken,
    UnexpectedResult,
};

pub const Timers = struct {
    const Slot = struct {
        active: bool = false,
        generation: u32 = 1,
        next_free: u32 = none,
        deadline: Deadline = undefined,
        timeout_token: completion.Token = undefined,
        cancel_token: ?completion.Token = null,
        timeout_done: bool = false,
        cancel_done: bool = false,
    };

    slots: []Slot,
    free_head: u32,
    free_count: usize,
    active_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) Error!Timers {
        if (capacity == 0 or capacity > max_slots) return error.InvalidConfig;
        const slots = try allocator.alloc(Slot, capacity);
        for (slots, 0..) |*slot, index| slot.* = .{
            .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
        };
        return .{
            .slots = slots,
            .free_head = 0,
            .free_count = capacity,
        };
    }

    /// All prepared operations must have delivered their terminal CQEs first.
    pub fn deinit(timers: *Timers, allocator: std.mem.Allocator) void {
        std.debug.assert(timers.active_count == 0);
        allocator.free(timers.slots);
        timers.* = undefined;
    }

    pub fn available(timers: Timers) usize {
        return timers.free_count;
    }

    pub fn idle(timers: Timers) bool {
        return timers.active_count == 0;
    }

    /// Prepares, but does not submit, an absolute CLOCK_MONOTONIC timeout.
    /// The deadline and operation state live in fixed storage until the
    /// timeout's terminal CQE, including when cancellation races expiration.
    pub fn arm(
        timers: *Timers,
        router: *completion.Router,
        ring: *linux.IoUring,
        deadline: Deadline,
    ) Error!Handle {
        if (deadline.sec < 0 or deadline.nsec < 0 or deadline.nsec >= std.time.ns_per_s)
            return error.InvalidDeadline;
        if (timers.free_head == none) return error.Exhausted;

        const index = timers.free_head;
        const slot = &timers.slots[index];
        const token = try router.acquire(.timer);
        errdefer router.retire(token) catch unreachable;

        timers.free_head = slot.next_free;
        timers.free_count -= 1;
        timers.active_count += 1;
        slot.active = true;
        slot.deadline = deadline;
        slot.timeout_token = token;
        slot.cancel_token = null;
        slot.timeout_done = false;
        slot.cancel_done = false;
        errdefer timers.release(index);

        _ = try ring.timeout(
            token.encode(),
            &slot.deadline,
            0,
            linux.IORING_TIMEOUT_ABS,
        );
        return .{ .slot = index, .generation = slot.generation };
    }

    /// Prepares, but does not submit, removal of a timeout. Success only means
    /// the removal SQE was queued: both its CQE and the timeout's terminal CQE
    /// must be passed to `complete` before the handle/storage can be reused.
    pub fn cancel(
        timers: *Timers,
        router: *completion.Router,
        ring: *linux.IoUring,
        handle: Handle,
    ) Error!void {
        const slot = try timers.get(handle);
        if (slot.cancel_token != null) return error.CancellationPending;

        const token = try router.acquire(.timer);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.timeout_remove(
            token.encode(),
            slot.timeout_token.encode(),
            0,
        );
        slot.cancel_token = token;
    }

    /// Consumes an R1-routed timer completion. The caller must pass every timer
    /// CQE here, including timeout-remove CQEs. This retires each R1 token only
    /// at its own terminal CQE and releases timer storage only after all
    /// kernel-referenced operations have completed. The returned generational
    /// handle identifies the timer owner even if this completion releases its
    /// slot immediately.
    pub fn complete(
        timers: *Timers,
        router: *completion.Router,
        token: completion.Token,
        result: i32,
    ) Error!Completion {
        for (timers.slots, 0..) |*slot, index| {
            if (!slot.active) continue;
            if (sameToken(slot.timeout_token, token)) {
                if (slot.timeout_done) return error.UnknownToken;
                const handle: Handle = .{
                    .slot = @intCast(index),
                    .generation = slot.generation,
                };
                try router.retire(token);
                slot.timeout_done = true;

                const event: Event = if (result == negativeErrno(.TIME))
                    .fired
                else if (result == negativeErrno(.CANCELED))
                    .canceled
                else
                    return timers.finishUnexpected(@intCast(index));

                if (slot.cancel_token == null or slot.cancel_done)
                    timers.release(@intCast(index));
                return .{ .handle = handle, .event = event };
            }

            if (slot.cancel_token) |cancel_token| {
                if (!sameToken(cancel_token, token)) continue;
                if (slot.cancel_done) return error.UnknownToken;
                const handle: Handle = .{
                    .slot = @intCast(index),
                    .generation = slot.generation,
                };
                try router.retire(token);
                slot.cancel_done = true;

                const valid = result == 0 or
                    result == negativeErrno(.NOENT) or
                    result == negativeErrno(.BUSY);
                if (slot.timeout_done) {
                    timers.release(@intCast(index));
                    if (!valid) return error.UnexpectedResult;
                    return .{ .handle = handle, .event = .cleanup_complete };
                }
                if (!valid) return error.UnexpectedResult;
                return .{ .handle = handle, .event = .pending_cleanup };
            }
        }
        return error.UnknownToken;
    }

    fn finishUnexpected(timers: *Timers, index: u32) Error {
        const slot = &timers.slots[index];
        if (slot.cancel_token == null or slot.cancel_done) timers.release(index);
        return error.UnexpectedResult;
    }

    fn get(timers: *Timers, handle: Handle) Error!*Slot {
        if (handle.slot >= timers.slots.len) return error.StaleHandle;
        const slot = &timers.slots[handle.slot];
        if (!slot.active or slot.generation != handle.generation)
            return error.StaleHandle;
        return slot;
    }

    fn release(timers: *Timers, index: u32) void {
        const slot = &timers.slots[index];
        std.debug.assert(slot.active);
        std.debug.assert(slot.timeout_done or slot.timeout_token.kind == .timer);
        std.debug.assert(slot.cancel_token == null or
            (slot.timeout_done and slot.cancel_done));
        slot.active = false;
        timers.active_count -= 1;
        if (slot.generation != std.math.maxInt(u32)) {
            slot.generation += 1;
            slot.next_free = timers.free_head;
            timers.free_head = index;
            timers.free_count += 1;
        } else {
            slot.next_free = none;
        }
    }
};

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn negativeErrno(errno: linux.E) i32 {
    return -@as(i32, @intFromEnum(errno));
}

fn setupState(
    timers: *Timers,
    router: *completion.Router,
    with_cancel: bool,
) !struct { Handle, completion.Token, ?completion.Token } {
    const slot = &timers.slots[0];
    const timeout_token = try router.acquire(.timer);
    timers.free_head = none;
    timers.free_count = 0;
    timers.active_count = 1;
    slot.active = true;
    slot.timeout_token = timeout_token;
    slot.timeout_done = false;
    slot.cancel_done = false;
    slot.cancel_token = if (with_cancel) try router.acquire(.timer) else null;
    return .{
        .{ .slot = 0, .generation = slot.generation },
        timeout_token,
        slot.cancel_token,
    };
}

test "expiration retires the token and generation protects reuse" {
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var timers = try Timers.init(std.testing.allocator, 1);
    defer timers.deinit(std.testing.allocator);

    const handle, const token, _ = try setupState(&timers, &router, false);
    try std.testing.expectEqual(Completion{ .handle = handle, .event = .fired }, try timers.complete(
        &router,
        token,
        negativeErrno(.TIME),
    ));
    try std.testing.expect(router.route(token.encode()) == null);
    try std.testing.expectError(error.StaleHandle, timers.get(handle));
    try std.testing.expectEqual(@as(usize, 1), timers.available());
}

test "cancel CQE first keeps timeout token and state alive" {
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var timers = try Timers.init(std.testing.allocator, 1);
    defer timers.deinit(std.testing.allocator);

    const handle, const timeout_token, const cancel_token =
        try setupState(&timers, &router, true);
    try std.testing.expectEqual(Completion{ .handle = handle, .event = .pending_cleanup }, try timers.complete(
        &router,
        cancel_token.?,
        0,
    ));
    try std.testing.expect(router.route(cancel_token.?.encode()) == null);
    try std.testing.expect(router.route(timeout_token.encode()) != null);
    try std.testing.expectEqual(@as(usize, 0), timers.available());
    _ = try timers.get(handle);

    try std.testing.expectEqual(Completion{ .handle = handle, .event = .canceled }, try timers.complete(
        &router,
        timeout_token,
        negativeErrno(.CANCELED),
    ));
    try std.testing.expectEqual(@as(usize, 1), timers.available());
}

test "expiration race reports once then awaits cancel cleanup" {
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var timers = try Timers.init(std.testing.allocator, 1);
    defer timers.deinit(std.testing.allocator);

    const handle, const timeout_token, const cancel_token =
        try setupState(&timers, &router, true);
    try std.testing.expectEqual(Completion{ .handle = handle, .event = .fired }, try timers.complete(
        &router,
        timeout_token,
        negativeErrno(.TIME),
    ));
    try std.testing.expectEqual(@as(usize, 0), timers.available());
    _ = try timers.get(handle);

    try std.testing.expectEqual(Completion{ .handle = handle, .event = .cleanup_complete }, try timers.complete(
        &router,
        cancel_token.?,
        negativeErrno(.NOENT),
    ));
    try std.testing.expectError(error.StaleHandle, timers.get(handle));
}

test "real io_uring absolute timeout fires" {
    var ring = linux.IoUring.init(4, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var timers = try Timers.init(std.testing.allocator, 1);
    defer timers.deinit(std.testing.allocator);

    const deadline = try monotonicAfter(2 * std.time.ns_per_ms);
    const handle = try timers.arm(&router, &ring, deadline);
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    const token = router.route(cqe.user_data) orelse return error.UnknownToken;
    try std.testing.expectEqual(
        Completion{ .handle = handle, .event = .fired },
        try timers.complete(&router, token, cqe.res),
    );
}

test "real io_uring cancellation consumes both operations" {
    var ring = linux.IoUring.init(4, 0) catch |err| switch (err) {
        error.PermissionDenied, error.SystemOutdated => return error.SkipZigTest,
        else => return err,
    };
    defer ring.deinit();
    var router = try completion.Router.init(std.testing.allocator, 2);
    defer router.deinit(std.testing.allocator);
    var timers = try Timers.init(std.testing.allocator, 1);
    defer timers.deinit(std.testing.allocator);

    const handle = try timers.arm(
        &router,
        &ring,
        try monotonicAfter(10 * std.time.ns_per_s),
    );
    try timers.cancel(&router, &ring, handle);
    _ = try ring.submit_and_wait(2);

    var saw_canceled = false;
    var completions: usize = 0;
    while (completions < 2) : (completions += 1) {
        const cqe = try ring.copy_cqe();
        const token = router.route(cqe.user_data) orelse return error.UnknownToken;
        const completed = try timers.complete(&router, token, cqe.res);
        try std.testing.expectEqual(handle, completed.handle);
        if (completed.event == .canceled) saw_canceled = true;
    }
    try std.testing.expect(saw_canceled);
    try std.testing.expectEqual(@as(usize, 1), timers.available());
    try std.testing.expectEqual(@as(usize, 2), router.available());
}

fn monotonicAfter(delta_ns: i64) !Deadline {
    var now: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &now);
    if (linux.errno(rc) != .SUCCESS) return error.ClockUnavailable;
    const total_nsec = now.nsec + delta_ns;
    return .{
        .sec = now.sec + @divFloor(total_nsec, std.time.ns_per_s),
        .nsec = @mod(total_nsec, std.time.ns_per_s),
    };
}
