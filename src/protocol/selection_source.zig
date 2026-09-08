//! Protocol-neutral clipboard source identity and operations.
//!
//! The owner keeps the backing resource alive and uses `token` to reject stale
//! slot generations. A successful `send` takes ownership of the descriptor;
//! on failure ownership remains with the caller.

const std = @import("std");
const linux = std.os.linux;

pub const Source = struct {
    owner: *anyopaque,
    token: u64,
    vtable: *const VTable,

    pub const VTable = struct {
        mimeCount: *const fn (*anyopaque, u64) anyerror!usize,
        mime: *const fn (*anyopaque, u64, usize) anyerror![]const u8,
        send: *const fn (*anyopaque, u64, usize, linux.fd_t) anyerror!void,
        cancel: *const fn (*anyopaque, u64) anyerror!void,
    };

    pub fn eql(a: Source, b: Source) bool {
        return a.owner == b.owner and a.token == b.token and a.vtable == b.vtable;
    }

    pub fn mimeCount(self: Source) !usize {
        return self.vtable.mimeCount(self.owner, self.token);
    }

    pub fn mime(self: Source, index: usize) ![]const u8 {
        return self.vtable.mime(self.owner, self.token, index);
    }

    pub fn findMime(self: Source, value: []const u8) !?usize {
        for (0..try self.mimeCount()) |index| {
            if (std.mem.eql(u8, try self.mime(index), value)) return index;
        }
        return null;
    }

    pub fn send(self: Source, mime_index: usize, fd: linux.fd_t) !void {
        return self.vtable.send(self.owner, self.token, mime_index, fd);
    }

    /// Takes ownership of a receive FD. A vanished source or unavailable
    /// format fails the transfer with EOF, not the recipient's connection.
    pub fn receive(self: Source, mime_type: []const u8, fd: linux.fd_t) void {
        const index = (self.findMime(mime_type) catch null) orelse {
            _ = linux.close(fd);
            return;
        };
        self.send(index, fd) catch {
            _ = linux.close(fd);
        };
    }

    pub fn cancel(self: Source) !void {
        return self.vtable.cancel(self.owner, self.token);
    }
};

test "selection source identity includes owner, generation token, and implementation" {
    const Testing = struct {
        fn mimeCount(_: *anyopaque, _: u64) !usize {
            return 0;
        }
        fn mime(_: *anyopaque, _: u64, _: usize) ![]const u8 {
            return error.Stale;
        }
        fn send(_: *anyopaque, _: u64, _: usize, _: linux.fd_t) !void {
            return error.Stale;
        }
        fn cancel(_: *anyopaque, _: u64) !void {
            return error.Stale;
        }
        const vtable: Source.VTable = .{
            .mimeCount = mimeCount,
            .mime = mime,
            .send = send,
            .cancel = cancel,
        };
    };
    var a: u8 = 0;
    var b: u8 = 0;
    const first: Source = .{ .owner = &a, .token = 7, .vtable = &Testing.vtable };
    try std.testing.expect(first.eql(first));
    try std.testing.expect(!first.eql(.{ .owner = &b, .token = 7, .vtable = &Testing.vtable }));
    try std.testing.expect(!first.eql(.{ .owner = &a, .token = 8, .vtable = &Testing.vtable }));
}

test "selection receive closes the transfer when its source cannot send" {
    const Testing = struct {
        fn mimeCount(_: *anyopaque, _: u64) !usize {
            return 1;
        }
        fn mime(_: *anyopaque, _: u64, _: usize) ![]const u8 {
            return "text/plain";
        }
        fn send(_: *anyopaque, token: u64, _: usize, _: linux.fd_t) !void {
            return if (token == 0) error.Stale else error.OutOfMemory;
        }
        fn cancel(_: *anyopaque, _: u64) !void {}
        const vtable: Source.VTable = .{
            .mimeCount = mimeCount,
            .mime = mime,
            .send = send,
            .cancel = cancel,
        };
    };
    var owner: u8 = 0;
    for (0..2) |token| {
        var pipe: [2]linux.fd_t = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
        defer _ = linux.close(pipe[0]);
        const source: Source = .{ .owner = &owner, .token = token, .vtable = &Testing.vtable };
        source.receive("text/plain", pipe[1]);
        try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(pipe[1], linux.F.GETFD, 0)));
        var byte: [1]u8 = undefined;
        try std.testing.expectEqual(@as(usize, 0), linux.read(pipe[0], &byte, byte.len));
    }
}
