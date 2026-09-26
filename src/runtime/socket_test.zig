//! Real-ring host for transport tests. Production transports never submit.
const std = @import("std");
const linux = std.os.linux;
const completion = @import("completion.zig");

pub const Loop = struct {
    ring: linux.IoUring,
    router: completion.Router,

    pub fn init(entries: u16) !Loop {
        var ring = try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();
        return .{ .ring = ring, .router = try completion.Router.init(std.testing.allocator, 160) };
    }

    pub fn tick(self: *Loop, transport: anytype) !void {
        var cqes: [64]linux.io_uring_cqe = undefined;
        const count = try self.ring.copy_cqes(&cqes, 0);
        for (cqes[0..count]) |cqe| {
            if (cqe.user_data == 0) {
                try std.testing.expectEqual(@as(i32, 0), cqe.res);
                continue;
            }
            const token = self.router.route(cqe.user_data) orelse return error.UnroutedCompletion;
            try transport.complete(&self.router, token, cqe.res);
        }
        _ = transport.prepare(&self.ring, &self.router);
        _ = try self.ring.submit();
    }

    pub fn drain(self: *Loop, transport: anytype) !void {
        transport.stop();
        const end = milliseconds() + 2000;
        while (!transport.drained()) {
            if (milliseconds() >= end) return error.DrainTimeout;
            try self.tick(transport);
        }
        try std.testing.expectEqual(@as(usize, 0), self.router.active_count);
    }

    pub fn deinit(self: *Loop, transport: anytype) void {
        self.drain(transport) catch @panic("transport test failed to drain kernel-owned storage");
        self.router.deinit(std.testing.allocator);
        self.ring.deinit();
    }
};

pub fn milliseconds() u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) unreachable;
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}
