//! Process signal boundary for graceful shutdown and configuration reload.
//! TERM, INT, and HUP are blocked before worker creation and consumed through
//! signalfd so signal delivery is part of the ordinary io_uring event loop.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

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
