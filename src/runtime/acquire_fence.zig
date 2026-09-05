//! Commit-owned sync_file waits. Cancellation retains the fd until both CQEs
//! drain; no kernel registration survives an abandoned future timeline point.
const std = @import("std");
const linux = std.os.linux;
const syncobj = @import("../drm_syncobj.zig");
const completion = @import("completion.zig");

pub const Waits = struct {
    const Entry = struct {
        state: syncobj.AcquireWait = .{},
        fd: linux.fd_t,
        poll: ?completion.Token = null,
        cancel: ?completion.Token = null,
        cancel_requested: bool = false,
        next: ?*Entry = null,
    };

    head: ?*Entry = null,
    stopping: bool = false,
    submission_pending: bool = false,

    pub fn ready(self: *Waits, allocator: std.mem.Allocator, router: *completion.Router, ring: *linux.IoUring, commit: *syncobj.Commit) !bool {
        if (commit.acquire_wait) |wait| return wait.signaled;
        if (self.stopping) return false;
        // Transfer fails for a point which has not yet been submitted. Leave
        // it without a wait so the commit timer retries availability later.
        const fd = commit.acquire.exportSyncFile() catch |err| switch (err) {
            error.Unavailable => return false,
            else => return err,
        };
        errdefer _ = linux.close(fd);
        const entry = try self.arm(allocator, router, ring, fd);
        commit.acquire_wait = &entry.state;
        return false;
    }

    /// Takes ownership only on success. Also used by tests with pollable fds.
    fn arm(self: *Waits, allocator: std.mem.Allocator, router: *completion.Router, ring: *linux.IoUring, fd: linux.fd_t) !*Entry {
        const entry = try allocator.create(Entry);
        errdefer allocator.destroy(entry);
        entry.* = .{ .fd = fd, .next = self.head };
        try self.register(entry, router, ring);
        self.head = entry;
        return entry;
    }

    fn register(self: *Waits, entry: *Entry, router: *completion.Router, ring: *linux.IoUring) !void {
        // Reserve cancellation before arming an unsignaled poll. Leave two
        // additional slots for the shared commit timer and its cancellation.
        if (router.available() < 4) return;
        const token = try router.acquire(.renderer_fence);
        errdefer router.retire(token) catch unreachable;
        const cancel = try router.acquire(.renderer_fence);
        errdefer router.retire(cancel) catch unreachable;
        _ = ring.poll_add(token.encode(), entry.fd, linux.POLL.IN) catch {
            try router.retire(cancel);
            try router.retire(token);
            self.submission_pending = true;
            return;
        };
        entry.poll = token;
        entry.cancel = cancel;
        entry.state.registered = true;
    }

    pub fn prepare(self: *Waits, allocator: std.mem.Allocator, router: *completion.Router, ring: *linux.IoUring) !void {
        self.submission_pending = false;
        var link = &self.head;
        while (link.*) |entry| {
            if (!entry.state.registered and entry.state.owned and !self.stopping) {
                try self.register(entry, router, ring);
                link = &entry.next;
                continue;
            }
            if ((!entry.state.owned or self.stopping) and entry.poll != null and !entry.cancel_requested) {
                _ = ring.poll_remove(entry.cancel.?.encode(), entry.poll.?.encode()) catch {
                    self.submission_pending = true;
                    link = &entry.next;
                    continue;
                };
                entry.cancel_requested = true;
            }
            if (entry.poll == null and entry.cancel == null) {
                if (entry.fd >= 0) {
                    _ = linux.close(entry.fd);
                    entry.fd = -1;
                }
                if (!entry.state.owned) {
                    link.* = entry.next;
                    allocator.destroy(entry);
                    continue;
                }
            }
            link = &entry.next;
        }
    }

    pub fn complete(self: *Waits, router: *completion.Router, token: completion.Token, result: i32) !void {
        // A stale generation must never update a replacement commit.
        if (router.route(token.encode()) == null) return;
        var next = self.head;
        while (next) |entry| : (next = entry.next) {
            if (entry.poll) |poll| if (std.meta.eql(poll, token)) {
                try router.retire(token);
                entry.poll = null;
                if (!entry.cancel_requested) {
                    try router.retire(entry.cancel.?);
                    entry.cancel = null;
                }
                entry.state.signaled = result >= 0 and (@as(u32, @intCast(result)) & linux.POLL.IN) != 0;
                if (!entry.state.signaled and !entry.cancel_requested and !self.stopping and entry.state.owned)
                    return error.AcquireFencePollFailed;
                return;
            };
            if (entry.cancel) |cancel| if (std.meta.eql(cancel, token)) {
                try router.retire(token);
                entry.cancel = null;
                // poll_remove may race a completed poll; its terminal CQE is
                // still required before the descriptor can be closed.
                if (result < 0 and result != -@as(i32, @intFromEnum(linux.E.NOENT)))
                    return error.AcquireFenceCancelFailed;
                return;
            };
        }
        return error.UnknownToken;
    }

    pub fn drained(self: *const Waits) bool {
        var next = self.head;
        while (next) |entry| : (next = entry.next) {
            if (entry.poll != null or entry.cancel != null) return false;
        }
        return true;
    }

    pub fn deinit(self: *Waits, allocator: std.mem.Allocator) void {
        std.debug.assert(self.drained());
        while (self.head) |entry| {
            std.debug.assert(!entry.state.owned);
            self.head = entry.next;
            if (entry.fd >= 0) _ = linux.close(entry.fd);
            allocator.destroy(entry);
        }
    }
};

test "acquire fence early readiness is cached and stale completions cannot signal replacement" {
    const allocator = std.testing.allocator;
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();
    var router = try completion.Router.init(allocator, 4);
    defer router.deinit(allocator);
    var waits: Waits = .{};
    defer waits.deinit(allocator);
    const fd = try testEventFd(1);
    const entry = try waits.arm(allocator, &router, &ring, fd);
    const stale = entry.poll.?;
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    try waits.complete(&router, router.route(cqe.user_data).?, cqe.res);
    try std.testing.expect(entry.state.signaled);
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    // No point access is needed after export: an undefined point is safe here.
    var commit: syncobj.Commit = .{ .acquire = undefined, .release = undefined, .acquire_wait = &entry.state };
    try std.testing.expect(try waits.ready(allocator, &router, &ring, &commit));
    entry.state.owned = false;
    try waits.prepare(allocator, &router, &ring);
    const replacement = try waits.arm(allocator, &router, &ring, try testEventFd(0));
    try std.testing.expect(router.route(stale.encode()) == null);
    try waits.complete(&router, stale, linux.POLL.IN);
    try std.testing.expect(!replacement.state.signaled);
    replacement.state.owned = false;
    try waits.prepare(allocator, &router, &ring);
    _ = try ring.submit_and_wait(2);
    for (0..2) |_| {
        const done = try ring.copy_cqe();
        try waits.complete(&router, router.route(done.user_data).?, done.res);
    }
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(waits.head == null);
}

test "acquire fence abandonment and shutdown drain both CQEs in either order before closing" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |shutdown| {
        for ([_]bool{ false, true }) |early_signal| {
            for ([_]bool{ false, true }) |cancel_first| {
                var ring = try linux.IoUring.init(8, 0);
                defer ring.deinit();
                var router = try completion.Router.init(allocator, 4);
                defer router.deinit(allocator);
                var waits: Waits = .{};
                defer waits.deinit(allocator);
                const fd = try testEventFd(if (early_signal) 1 else 0);
                const entry = try waits.arm(allocator, &router, &ring, fd);
                _ = try ring.submit();
                if (early_signal) _ = try ring.submit_and_wait(1);
                // Disconnect/discard releases the commit, whereas shutdown
                // must also cancel waits whose commits are still retained.
                entry.state.owned = shutdown;
                waits.stopping = shutdown;
                try waits.prepare(allocator, &router, &ring);
                const cancel = entry.cancel.?;
                _ = try ring.submit_and_wait(2);
                var cqes = [_]linux.io_uring_cqe{ try ring.copy_cqe(), try ring.copy_cqe() };
                if ((cqes[0].user_data == cancel.encode()) != cancel_first)
                    std.mem.swap(linux.io_uring_cqe, &cqes[0], &cqes[1]);
                try waits.complete(&router, router.route(cqes[0].user_data).?, cqes[0].res);
                try waits.prepare(allocator, &router, &ring);
                try std.testing.expect(!waits.drained());
                try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
                try std.testing.expectEqual(@as(usize, 1), router.active_count);
                try waits.complete(&router, router.route(cqes[1].user_data).?, cqes[1].res);
                entry.state.owned = false;
                try waits.prepare(allocator, &router, &ring);
                try std.testing.expect(waits.drained());
                try std.testing.expect(waits.head == null);
                try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
            }
        }
    }
}

fn testEventFd(value: u32) !linux.fd_t {
    const result = linux.eventfd(value, linux.EFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.EventFdFailed;
    return @intCast(result);
}

test "acquire fence registration retains fd through tiny SQ and router pressure" {
    const allocator = std.testing.allocator;
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    var router = try completion.Router.init(allocator, 4);
    defer router.deinit(allocator);
    var waits: Waits = .{};
    defer waits.deinit(allocator);
    _ = try ring.nop(0);
    _ = try ring.nop(0);
    const fd = try testEventFd(1);
    const entry = try waits.arm(allocator, &router, &ring, fd);
    try std.testing.expect(!entry.state.registered);
    try std.testing.expect(waits.submission_pending);
    try std.testing.expectEqual(@as(usize, 0), router.active_count);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    _ = try ring.submit_and_wait(2);
    _ = try ring.copy_cqe();
    _ = try ring.copy_cqe();
    const blocker = try router.acquire(.copy);
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(!entry.state.registered);
    try std.testing.expect(!waits.submission_pending); // await resource completion, don't spin
    var commit: syncobj.Commit = .{ .acquire = undefined, .release = undefined, .acquire_wait = &entry.state };
    try std.testing.expect(!try waits.ready(allocator, &router, &ring, &commit));
    try router.retire(blocker);
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(entry.state.registered);
    try std.testing.expectEqual(@as(usize, 2), router.available());
    _ = try ring.submit_and_wait(1);
    const cqe = try ring.copy_cqe();
    try waits.complete(&router, router.route(cqe.user_data).?, cqe.res);
    try std.testing.expect(entry.state.signaled);
    entry.state.owned = false;
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 0), router.active_count);
}

test "acquire fence shutdown cancellation progresses with full SQ and no free router slots" {
    const allocator = std.testing.allocator;
    var ring = try linux.IoUring.init(2, 0);
    defer ring.deinit();
    var router = try completion.Router.init(allocator, 4);
    defer router.deinit(allocator);
    var waits: Waits = .{};
    defer waits.deinit(allocator);
    const fd = try testEventFd(0);
    const entry = try waits.arm(allocator, &router, &ring, fd);
    // The spare pair is enough for a fallback timer plus cancellation, even
    // while the acquire poll holds its own cancellation reservation.
    const timer_api = @import("timer.zig");
    var timers = try timer_api.Timers.init(allocator, 1);
    defer timers.deinit(allocator);
    const timer_handle = try timers.arm(&router, &ring, .{ .sec = std.math.maxInt(i64), .nsec = 0 });
    waits.stopping = true;
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(waits.submission_pending);
    try std.testing.expect(!entry.cancel_requested);
    // Flush without waiting: both SQEs are deliberately long-lived waits.
    _ = try ring.submit();
    try timers.cancel(&router, &ring, timer_handle);
    try std.testing.expectEqual(@as(usize, 0), router.available());
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(entry.cancel_requested);
    try std.testing.expect(!waits.submission_pending);
    _ = try ring.submit_and_wait(4);
    for (0..4) |_| {
        const cqe = try ring.copy_cqe();
        const token = router.route(cqe.user_data).?;
        if (token.kind == .timer) {
            _ = try timers.complete(&router, token, cqe.res);
        } else try waits.complete(&router, token, cqe.res);
    }
    entry.state.owned = false;
    try waits.prepare(allocator, &router, &ring);
    try std.testing.expect(waits.drained());
    try std.testing.expect(timers.idle());
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 0), router.active_count);
}

test "acquire fence deferred registration can be abandoned or shut down without tokens" {
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |shutdown| {
        var ring = try linux.IoUring.init(2, 0);
        defer ring.deinit();
        var router = try completion.Router.init(allocator, 1);
        defer router.deinit(allocator);
        const blocker = try router.acquire(.copy);
        var waits: Waits = .{};
        defer waits.deinit(allocator);
        const fd = try testEventFd(0);
        const entry = try waits.arm(allocator, &router, &ring, fd);
        try std.testing.expect(!entry.state.registered);
        entry.state.owned = shutdown;
        waits.stopping = shutdown;
        try waits.prepare(allocator, &router, &ring);
        try std.testing.expect(waits.drained());
        try std.testing.expectEqual(@as(u32, 0), ring.sq_ready());
        try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
        if (shutdown) {
            entry.state.owned = false;
            try waits.prepare(allocator, &router, &ring);
        }
        try std.testing.expect(waits.head == null);
        try router.retire(blocker);
    }
}
