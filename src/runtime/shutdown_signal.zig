//! Process signal boundary for graceful shutdown and configuration reload.
//! TERM, INT, and HUP are blocked before worker creation and consumed through
//! signalfd so signal delivery is part of the ordinary io_uring event loop.

const std = @import("std");
const c = @cImport({
    @cInclude("signal.h");
    @cInclude("time.h");
});

const linux = std.os.linux;
const posix = std.posix;

/// Bounds fatal-error cleanup even if the event loop or a destructor blocks.
/// Deliberately remains armed until process exit: releasing DRM ownership must
/// not depend on another event-loop turn or successful userspace teardown.
pub const ExitDeadline = struct {
    armed: bool = false,

    pub fn arm(self: *ExitDeadline, grace_ns: u64) void {
        if (self.armed) return;
        std.debug.assert(grace_ns != 0);
        var event = std.mem.zeroes(c.struct_sigevent);
        event.sigev_notify = c.SIGEV_SIGNAL;
        // SIGKILL cannot be caught or blocked by the inherited signalfd mask.
        event.sigev_signo = c.SIGKILL;
        var timer: c.timer_t = undefined;
        if (c.timer_create(c.CLOCK_MONOTONIC, &event, &timer) != 0)
            linux.exit_group(1);
        const spec: c.struct_itimerspec = .{
            .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 },
            .it_value = .{
                .tv_sec = @intCast(grace_ns / std.time.ns_per_s),
                .tv_nsec = @intCast(grace_ns % std.time.ns_per_s),
            },
        };
        if (c.timer_settime(timer, 0, &spec, null) != 0)
            linux.exit_group(1);
        self.armed = true;
    }
};

pub const Events = struct {
    shutdown: bool = false,
    reload: bool = false,
    sender_pid: u32 = 0,
    sender_uid: u32 = 0,
};

pub const Watcher = struct {
    fd: linux.fd_t,
    mask: posix.sigset_t,
    old_mask: posix.sigset_t,

    /// Blocks watched signals in the calling thread. Call this before creating
    /// workers so every descendant inherits the mask and signalfd remains the
    /// process's sole delivery boundary.
    pub fn install() !Watcher {
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, .TERM);
        posix.sigaddset(&mask, .INT);
        posix.sigaddset(&mask, .HUP);
        var old_mask: posix.sigset_t = undefined;
        posix.sigprocmask(linux.SIG.BLOCK, &mask, &old_mask);
        errdefer posix.sigprocmask(linux.SIG.SETMASK, &old_mask, null);

        const fd = try posix.signalfd(
            -1,
            &mask,
            linux.SFD.CLOEXEC | linux.SFD.NONBLOCK,
        );
        errdefer _ = linux.close(fd);
        return .{
            .fd = fd,
            .mask = mask,
            .old_mask = old_mask,
        };
    }

    pub fn deinit(watcher: *Watcher) void {
        _ = linux.close(watcher.fd);
        posix.sigprocmask(linux.SIG.SETMASK, &watcher.old_mask, null);
        watcher.* = undefined;
    }

    pub fn descriptor(watcher: *const Watcher) linux.fd_t {
        return watcher.fd;
    }

    pub fn request(_: *const Watcher) void {
        posix.kill(linux.getpid(), .TERM) catch {};
    }

    pub fn consume(watcher: *const Watcher) !Events {
        var events: Events = .{};
        var info: linux.signalfd_siginfo = undefined;
        while (true) {
            const result = linux.read(
                watcher.fd,
                std.mem.asBytes(&info).ptr,
                @sizeOf(linux.signalfd_siginfo),
            );
            switch (linux.errno(result)) {
                .SUCCESS => {
                    if (result != @sizeOf(linux.signalfd_siginfo))
                        return error.InvalidSignalRecord;
                    switch (info.signo) {
                        @intFromEnum(linux.SIG.TERM), @intFromEnum(linux.SIG.INT) => events.shutdown = true,
                        @intFromEnum(linux.SIG.HUP) => events.reload = true,
                        else => return error.UnexpectedSignal,
                    }
                    events.sender_pid = info.pid;
                    events.sender_uid = info.uid;
                },
                .AGAIN => return events,
                else => return error.SignalReadFailed,
            }
        }
    }
};

test "signalfd wakes io_uring and reports TERM" {
    var watcher = try Watcher.install();
    defer watcher.deinit();
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();

    try std.testing.expectEqual(Events{}, try watcher.consume());
    _ = try ring.poll_add(7, watcher.descriptor(), linux.POLL.IN);
    try posix.kill(linux.getpid(), .TERM);
    _ = try ring.submit_and_wait(1);
    var cqes: [1]linux.io_uring_cqe = undefined;
    try std.testing.expectEqual(@as(u32, 1), try ring.copy_cqes(&cqes, 0));
    try std.testing.expectEqual(@as(u64, 7), cqes[0].user_data);
    try std.testing.expect(@as(u32, @intCast(cqes[0].res)) & linux.POLL.IN != 0);
    try std.testing.expect((try watcher.consume()).shutdown);
    try std.testing.expectEqual(Events{}, try watcher.consume());
}

test "signalfd reports HUP as reload without shutdown" {
    var watcher = try Watcher.install();
    defer watcher.deinit();

    try posix.kill(linux.getpid(), .HUP);
    const events = try watcher.consume();
    try std.testing.expect(events.reload);
    try std.testing.expect(!events.shutdown);
}

test "fatal exit deadline kills blocked cleanup without extending on rearm" {
    const child = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(child));
    if (child == 0) {
        // Use only signal/timer syscalls in the child, not inherited runtime
        // locks or allocators. No event loop consumes the blocked TERM signal.
        _ = Watcher.install() catch linux.exit_group(2);
        var deadline: ExitDeadline = .{};
        deadline.arm(20 * std.time.ns_per_ms);
        deadline.arm(5 * std.time.ns_per_s);
        _ = linux.nanosleep(&.{ .sec = 0, .nsec = 150 * std.time.ns_per_ms }, null);
        linux.exit_group(42);
    }
    var status: u32 = 0;
    while (true) {
        const result = linux.wait4(@intCast(child), &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        try std.testing.expectEqual(child, result);
        break;
    }
    try std.testing.expect(linux.W.IFSIGNALED(status));
    try std.testing.expectEqual(linux.SIG.KILL, linux.W.TERMSIG(status));
}

test "fatal exit deadline allows prompt process exit" {
    const child = linux.fork();
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(child));
    if (child == 0) {
        var deadline: ExitDeadline = .{};
        deadline.arm(5 * std.time.ns_per_s);
        linux.exit_group(0);
    }
    var status: u32 = 0;
    while (true) {
        const result = linux.wait4(@intCast(child), &status, 0, null);
        if (linux.errno(result) == .INTR) continue;
        try std.testing.expectEqual(child, result);
        break;
    }
    try std.testing.expect(linux.W.IFEXITED(status));
    try std.testing.expectEqual(@as(u32, 0), linux.W.EXITSTATUS(status));
}
