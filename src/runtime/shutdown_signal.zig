//! Process signal boundary for graceful compositor shutdown. The handler only
//! writes an eventfd. io_uring polls that descriptor so TERM/INT wake the
//! blocking event loop and all teardown remains in its normal command path.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

var wake_fd: std.c.sig_atomic_t = -1;

pub const Watcher = struct {
    fd: linux.fd_t,
    old_term: posix.Sigaction,
    old_int: posix.Sigaction,

    pub fn install() !Watcher {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.EventFdUnavailable;
        const fd: linux.fd_t = @intCast(result);
        errdefer _ = linux.close(fd);
        storeWakeFd(fd);
        errdefer storeWakeFd(-1);
        const action: posix.Sigaction = .{
            .handler = .{ .handler = notify },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        var watcher: Watcher = .{
            .fd = fd,
            .old_term = undefined,
            .old_int = undefined,
        };
        posix.sigaction(.TERM, &action, &watcher.old_term);
        posix.sigaction(.INT, &action, &watcher.old_int);
        return watcher;
    }

    pub fn deinit(watcher: *Watcher) void {
        posix.sigaction(.INT, &watcher.old_int, null);
        posix.sigaction(.TERM, &watcher.old_term, null);
        storeWakeFd(-1);
        _ = linux.close(watcher.fd);
        watcher.* = undefined;
    }

    pub fn descriptor(watcher: *const Watcher) linux.fd_t {
        return watcher.fd;
    }

    pub fn request(watcher: *const Watcher) void {
        writeWake(watcher.fd);
    }

    pub fn consume(watcher: *const Watcher) !bool {
        var count: u64 = 0;
        const result = linux.read(watcher.fd, std.mem.asBytes(&count).ptr, @sizeOf(u64));
        return switch (linux.errno(result)) {
            .SUCCESS => if (result == @sizeOf(u64) and count != 0)
                true
            else
                error.InvalidWakeup,
            .AGAIN => false,
            else => error.WakeupReadFailed,
        };
    }
};

fn notify(_: posix.SIG) callconv(.c) void {
    const pointer: *const volatile std.c.sig_atomic_t = &wake_fd;
    const fd = pointer.*;
    if (fd >= 0) writeWake(fd);
}

fn storeWakeFd(value: std.c.sig_atomic_t) void {
    const pointer: *volatile std.c.sig_atomic_t = &wake_fd;
    pointer.* = value;
}

fn writeWake(fd: linux.fd_t) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
}

test "installed TERM handler wakes an io_uring poll" {
    var watcher = try Watcher.install();
    defer watcher.deinit();
    var ring = try linux.IoUring.init(8, 0);
    defer ring.deinit();

    try std.testing.expect(!(try watcher.consume()));
    _ = try ring.poll_add(7, watcher.descriptor(), linux.POLL.IN);
    try posix.kill(std.os.linux.getpid(), .TERM);
    _ = try ring.submit_and_wait(1);
    var cqes: [1]linux.io_uring_cqe = undefined;
    try std.testing.expectEqual(@as(u32, 1), try ring.copy_cqes(&cqes, 0));
    try std.testing.expectEqual(@as(u64, 7), cqes[0].user_data);
    try std.testing.expect(@as(u32, @intCast(cqes[0].res)) & linux.POLL.IN != 0);
    try std.testing.expect(try watcher.consume());
    try std.testing.expect(!(try watcher.consume()));
}
