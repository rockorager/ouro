//! Process signal boundary for graceful compositor shutdown. The handler only
//! performs one signal-safe scalar store; the owner loop observes it and keeps
//! all teardown work in its normal command path.

const std = @import("std");

const posix = std.posix;

var stop_requested: std.c.sig_atomic_t = 0;

pub const Watcher = struct {
    old_term: posix.Sigaction,
    old_int: posix.Sigaction,

    pub fn install() Watcher {
        storeRequested(0);
        const action: posix.Sigaction = .{
            .handler = .{ .handler = notify },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART,
        };
        var watcher: Watcher = undefined;
        posix.sigaction(.TERM, &action, &watcher.old_term);
        posix.sigaction(.INT, &action, &watcher.old_int);
        return watcher;
    }

    pub fn deinit(watcher: *Watcher) void {
        posix.sigaction(.INT, &watcher.old_int, null);
        posix.sigaction(.TERM, &watcher.old_term, null);
        watcher.* = undefined;
    }

    pub fn requested(_: *const Watcher) bool {
        const pointer: *const volatile std.c.sig_atomic_t = &stop_requested;
        return pointer.* != 0;
    }
};

fn notify(_: posix.SIG) callconv(.c) void {
    storeRequested(1);
}

fn storeRequested(value: std.c.sig_atomic_t) void {
    const pointer: *volatile std.c.sig_atomic_t = &stop_requested;
    pointer.* = value;
}

test "installed TERM handler records a sticky shutdown request" {
    var watcher = Watcher.install();
    defer watcher.deinit();
    try std.testing.expect(!watcher.requested());
    try posix.kill(std.os.linux.getpid(), .TERM);
    for (0..1_000_000) |_| {
        if (watcher.requested()) break;
        _ = std.os.linux.sched_yield();
    }
    try std.testing.expect(watcher.requested());
    try std.testing.expect(watcher.requested());
}
