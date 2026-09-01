//! Process signal boundary for graceful shutdown and configuration reload.
//! Handlers only mark a lock-free word and write an eventfd. io_uring polls
//! that descriptor so all work remains in the normal event-loop path.

const std = @import("std");

const linux = std.os.linux;
const posix = std.posix;

var wake_fd: std.c.sig_atomic_t = -1;
var pending: u32 = 0;
const shutdown_bit: u32 = 1 << 0;
const reload_bit: u32 = 1 << 1;

pub const Events = packed struct(u2) {
    shutdown: bool = false,
    reload: bool = false,
};

pub const Watcher = struct {
    fd: linux.fd_t,
    old_term: posix.Sigaction,
    old_int: posix.Sigaction,
    old_hup: posix.Sigaction,
    old_chld: posix.Sigaction,

    pub fn install() !Watcher {
        _ = @atomicRmw(u32, &pending, .Xchg, 0, .seq_cst);
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.EventFdUnavailable;
        const fd: linux.fd_t = @intCast(result);
        errdefer _ = linux.close(fd);
        storeWakeFd(fd);
        errdefer storeWakeFd(-1);
        const shutdown_action: posix.Sigaction = .{
            .handler = .{ .handler = notifyShutdown },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        const reload_action: posix.Sigaction = .{
            .handler = .{ .handler = notifyReload },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        const child_action: posix.Sigaction = .{
            // Ouro only starts short-lived systemd-run helpers. Linux reaps
            // children automatically while SIGCHLD is explicitly ignored.
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        var watcher: Watcher = .{
            .fd = fd,
            .old_term = undefined,
            .old_int = undefined,
            .old_hup = undefined,
            .old_chld = undefined,
        };
        posix.sigaction(.TERM, &shutdown_action, &watcher.old_term);
        posix.sigaction(.INT, &shutdown_action, &watcher.old_int);
        posix.sigaction(.HUP, &reload_action, &watcher.old_hup);
        posix.sigaction(.CHLD, &child_action, &watcher.old_chld);
        return watcher;
    }

    pub fn deinit(watcher: *Watcher) void {
        posix.sigaction(.CHLD, &watcher.old_chld, null);
        posix.sigaction(.HUP, &watcher.old_hup, null);
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
        _ = @atomicRmw(u32, &pending, .Or, shutdown_bit, .seq_cst);
        writeWake(watcher.fd);
    }

    pub fn consume(watcher: *const Watcher) !Events {
        var blocked = posix.sigemptyset();
        posix.sigaddset(&blocked, .TERM);
        posix.sigaddset(&blocked, .INT);
        posix.sigaddset(&blocked, .HUP);
        var previous: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, &blocked, &previous);
        defer posix.sigprocmask(posix.SIG.SETMASK, &previous, null);
        var count: u64 = 0;
        const result = linux.read(watcher.fd, std.mem.asBytes(&count).ptr, @sizeOf(u64));
        return switch (linux.errno(result)) {
            .SUCCESS => if (result == @sizeOf(u64) and count != 0) events: {
                const bits = @atomicRmw(u32, &pending, .Xchg, 0, .seq_cst);
                break :events .{
                    .shutdown = bits & shutdown_bit != 0,
                    .reload = bits & reload_bit != 0,
                };
            } else error.InvalidWakeup,
            .AGAIN => .{},
            else => error.WakeupReadFailed,
        };
    }
};

fn notifyShutdown(_: posix.SIG) callconv(.c) void {
    notify(shutdown_bit);
}

fn notifyReload(_: posix.SIG) callconv(.c) void {
    notify(reload_bit);
}

fn notify(bit: u32) void {
    _ = @atomicRmw(u32, &pending, .Or, bit, .seq_cst);
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

    try std.testing.expectEqual(Events{}, try watcher.consume());
    _ = try ring.poll_add(7, watcher.descriptor(), linux.POLL.IN);
    try posix.kill(std.os.linux.getpid(), .TERM);
    _ = try ring.submit_and_wait(1);
    var cqes: [1]linux.io_uring_cqe = undefined;
    try std.testing.expectEqual(@as(u32, 1), try ring.copy_cqes(&cqes, 0));
    try std.testing.expectEqual(@as(u64, 7), cqes[0].user_data);
    try std.testing.expect(@as(u32, @intCast(cqes[0].res)) & linux.POLL.IN != 0);
    try std.testing.expect((try watcher.consume()).shutdown);
    try std.testing.expectEqual(Events{}, try watcher.consume());
}

test "installed HUP handler requests reload without shutdown" {
    var watcher = try Watcher.install();
    defer watcher.deinit();

    try posix.kill(std.os.linux.getpid(), .HUP);
    const events = try watcher.consume();
    try std.testing.expect(events.reload);
    try std.testing.expect(!events.shutdown);
}
