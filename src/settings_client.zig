//! Non-blocking Varlink transport for the ourosettings WatchPath stream.
const std = @import("std");
const linux = std.os.linux;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("poll.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/un.h");
    @cInclude("stdlib.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const maximum_frame_size = 262144;
const request = "{\"method\":\"dev.rockorager.ouro.Settings.WatchPath\",\"parameters\":{\"path\":\"/compositor\"},\"more\":true}\x00";
const retry_first: u32 = 250;
const retry_max: u32 = 5000;
const handshake_ms: u32 = 5000;

pub const Update = struct {
    revision: []u8,
    exists: bool,
    json: []u8,
    pub fn deinit(self: *Update, allocator: std.mem.Allocator) void {
        allocator.free(self.revision);
        allocator.free(self.json);
        self.* = undefined;
    }
};
const State = enum { waiting, connecting, sending, subscribed };

pub const Client = struct {
    allocator: std.mem.Allocator,
    path: [:0]u8,
    epoll_fd: linux.fd_t,
    timer_fd: linux.fd_t,
    socket_fd: linux.fd_t = -1,
    socket_generation: u64 = 1,
    state: State = .waiting,
    partial_frame: bool = false,
    sent: usize = 0,
    input: std.ArrayListUnmanaged(u8) = .empty,
    queued: ?Update = null,
    retry_ms: u32 = retry_first,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Client {
        if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null or
            path.len >= @sizeOf(c.struct_sockaddr_un) - @offsetOf(c.struct_sockaddr_un, "sun_path")) return error.InvalidSocketPath;
        const owned = try allocator.dupeZ(u8, path);
        errdefer allocator.free(owned);
        const ep = c.epoll_create1(c.EPOLL_CLOEXEC);
        if (ep < 0) return error.EpollCreateFailed;
        errdefer _ = c.close(ep);
        const timer = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_NONBLOCK | c.TFD_CLOEXEC);
        if (timer < 0) return error.TimerCreateFailed;
        errdefer _ = c.close(timer);
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN, .data = .{ .u64 = 1 } };
        if (c.epoll_ctl(ep, c.EPOLL_CTL_ADD, timer, &event) != 0) return error.EpollControlFailed;
        var self: Client = .{ .allocator = allocator, .path = owned, .epoll_fd = ep, .timer_fd = timer };
        try self.arm(1);
        return self;
    }
    pub fn deinit(self: *Client) void {
        self.closeSocket();
        if (self.queued) |*u| u.deinit(self.allocator);
        self.input.deinit(self.allocator);
        _ = c.close(self.timer_fd);
        _ = c.close(self.epoll_fd);
        self.allocator.free(self.path);
        self.* = undefined;
    }
    pub fn descriptor(self: *const Client) linux.fd_t {
        return self.epoll_fd;
    }
    pub fn take(self: *Client) ?Update {
        const result = self.queued;
        self.queued = null;
        return result;
    }
    pub fn stop(self: *Client) !void {
        self.stopping = true;
        self.closeSocket();
        try self.arm(1);
    }

    pub fn dispatch(self: *Client) !void {
        // One batch and at most 256 KiB of socket reads per compositor turn.
        var events: [2]c.struct_epoll_event = undefined;
        const n = c.epoll_wait(self.epoll_fd, &events, events.len, 0);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) return;
            return error.EpollWaitFailed;
        }
        for (events[0..@intCast(n)]) |event| {
            if (event.data.u64 == 1) {
                // A preceding socket event may have disarmed the timer.
                if (!self.drainTimer()) continue;
                if (!self.stopping) {
                    if (self.state == .waiting) try self.connect() else try self.reconnect("reply timeout");
                }
            } else if (!self.stopping and self.socket_fd >= 0 and event.data.u64 == self.socket_generation) {
                try self.socketEvent(event.events);
            }
        }
    }

    pub fn waitInitial(self: *Client, shutdown_fd: linux.fd_t, timeout_ms: u32) !Update {
        const deadline = monotonicMs() + timeout_ms;
        while (true) {
            try self.dispatch();
            if (self.take()) |u| return u;
            const now = monotonicMs();
            if (now >= deadline) return error.StartupTimeout;
            var fds = [_]linux.pollfd{ .{ .fd = self.epoll_fd, .events = linux.POLL.IN, .revents = 0 }, .{ .fd = shutdown_fd, .events = linux.POLL.IN, .revents = 0 } };
            const n = linux.poll(&fds, fds.len, @intCast(@min(deadline - now, @as(u64, std.math.maxInt(i32)))));
            if (linux.errno(n) != .SUCCESS) {
                if (linux.errno(n) == .INTR) continue;
                return error.PollFailed;
            }
            if (fds[1].revents != 0) return error.StartupInterrupted;
        }
    }

    fn connect(self: *Client) !void {
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return self.scheduleReconnect("socket failed");
        self.socket_fd = fd;
        var address = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        @memcpy(address.sun_path[0..self.path.len], self.path);
        const result = linux.connect(fd, &address, @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + self.path.len + 1));
        if (linux.errno(result) != .SUCCESS and linux.errno(result) != .INPROGRESS) return self.scheduleReconnect("connect failed");
        self.socket_generation += 1;
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN | c.EPOLLOUT | c.EPOLLRDHUP, .data = .{ .u64 = self.socket_generation } };
        if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_ADD, fd, &event) != 0) return error.EpollControlFailed;
        // Even an immediately completed connect passes through SO_PEERCRED
        // verification before any request bytes are trusted or sent.
        self.state = .connecting;
        self.sent = 0;
        try self.arm(handshake_ms);
    }

    fn socketEvent(self: *Client, flags: u32) !void {
        if (self.state == .connecting and flags & c.EPOLLOUT != 0) {
            var e: c_int = 0;
            var len: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(self.socket_fd, c.SOL_SOCKET, c.SO_ERROR, &e, &len) != 0 or e != 0) return self.reconnect("connect failed");
            var cred: c.struct_ucred = undefined;
            len = @sizeOf(c.struct_ucred);
            if (c.getsockopt(self.socket_fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0 or cred.uid != c.geteuid()) return self.reconnect("peer uid rejected");
            self.state = .sending;
        }
        if (self.state == .sending and flags & c.EPOLLOUT != 0) try self.sendRequest();
        if ((self.state == .sending or self.state == .subscribed) and flags & c.EPOLLIN != 0) try self.readSocket();
        if (self.socket_fd >= 0 and flags & (c.EPOLLERR | c.EPOLLHUP | c.EPOLLRDHUP) != 0) try self.reconnect("server disconnected");
    }

    fn sendRequest(self: *Client) !void {
        while (self.sent < request.len) {
            const n = c.send(self.socket_fd, request.ptr + self.sent, request.len - self.sent, c.MSG_NOSIGNAL);
            if (n > 0) self.sent += @intCast(n) else if (n < 0 and c.__errno_location().* == c.EINTR) continue else if (n < 0 and c.__errno_location().* == c.EAGAIN) return else return self.reconnect("write failed");
        }
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN | c.EPOLLRDHUP, .data = .{ .u64 = self.socket_generation } };
        if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_MOD, self.socket_fd, &event) != 0) return error.EpollControlFailed;
    }

    fn readSocket(self: *Client) !void {
        var bytes: [16384]u8 = undefined;
        var count: usize = 0;
        while (count < 16) : (count += 1) {
            const n = c.recv(self.socket_fd, &bytes, bytes.len, 0);
            if (n > 0) {
                // One read may contain the end of a maximum-sized frame and
                // the beginning of the next. Keep at most one scratch read of
                // slop, then parse immediately below.
                if (self.input.items.len + @as(usize, @intCast(n)) > maximum_frame_size + bytes.len) return self.reconnect("frame too large");
                try self.input.appendSlice(self.allocator, bytes[0..@intCast(n)]);
                try self.processFrames();
                if (self.socket_fd < 0) return;
                if (self.input.items.len >= maximum_frame_size and std.mem.indexOfScalar(u8, self.input.items, 0) == null)
                    return self.reconnect("frame too large");
                if (self.input.items.len != 0 and self.state == .subscribed and !self.partial_frame) {
                    self.partial_frame = true;
                    try self.arm(handshake_ms);
                }
            } else if (n == 0) return self.reconnect("server closed") else if (c.__errno_location().* == c.EINTR) continue else if (c.__errno_location().* == c.EAGAIN) return else return self.reconnect("read failed");
        }
    }

    fn processFrames(self: *Client) !void {
        // Consume every complete frame from this bounded read. Otherwise a
        // coalesced tail could be stranded when the socket is no longer ready.
        var used: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.input.items, used, 0)) |end| {
            if (end - used + 1 > maximum_frame_size) return self.reconnect("frame too large");
            self.parseFrame(self.input.items[used..end]) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return self.reconnect("invalid reply"),
            };
            used = end + 1;
        }
        if (used != 0) {
            std.mem.copyForwards(u8, self.input.items[0 .. self.input.items.len - used], self.input.items[used..]);
            self.input.items.len -= used;
        }
    }

    const Reply = struct {
        parameters: Parameters,
        continues: bool,
        const Parameters = struct { revision: []const u8, exists: bool, value_json: []const u8 };
    };

    fn parseFrame(self: *Client, frame: []const u8) !void {
        var parsed = try std.json.parseFromSlice(Reply, self.allocator, frame, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
            .duplicate_field_behavior = .@"error",
            .max_value_len = maximum_frame_size,
        });
        defer parsed.deinit();
        const reply = parsed.value;
        if (!reply.continues or reply.parameters.revision.len == 0 or reply.parameters.revision.len > 128 or
            !std.unicode.utf8ValidateSlice(reply.parameters.revision) or
            !std.unicode.utf8ValidateSlice(reply.parameters.value_json)) return error.InvalidReply;
        try self.disarm();
        const revision = try self.allocator.dupe(u8, reply.parameters.revision);
        errdefer self.allocator.free(revision);
        const json = try self.allocator.dupe(u8, reply.parameters.value_json);
        const update: Update = .{ .revision = revision, .exists = reply.parameters.exists, .json = json };
        if (self.queued) |*old| old.deinit(self.allocator);
        self.queued = update;
        self.state = .subscribed;
        self.partial_frame = false;
        self.retry_ms = retry_first;
    }

    fn reconnect(self: *Client, reason: []const u8) !void {
        std.log.warn("settings transport: {s}; reconnecting", .{reason});
        self.closeSocket();
        if (!self.stopping) try self.scheduleReconnect(null);
    }

    fn scheduleReconnect(self: *Client, reason: ?[]const u8) !void {
        if (reason) |message| std.log.warn("settings transport: {s}; reconnecting", .{message});
        self.closeSocket();
        self.state = .waiting;
        try self.arm(self.retry_ms);
        self.retry_ms = @min(self.retry_ms * 2, retry_max);
    }

    fn closeSocket(self: *Client) void {
        if (self.socket_fd >= 0) {
            _ = c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_DEL, self.socket_fd, null);
            _ = c.close(self.socket_fd);
        }
        self.socket_fd = -1;
        self.state = .waiting;
        self.sent = 0;
        self.partial_frame = false;
        self.input.clearRetainingCapacity();
    }
    fn arm(self: *Client, milliseconds: u32) !void {
        const spec: c.struct_itimerspec = .{ .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 }, .it_value = .{
            .tv_sec = @intCast(milliseconds / 1000),
            .tv_nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
        } };
        if (c.timerfd_settime(self.timer_fd, 0, &spec, null) != 0) return error.TimerArmFailed;
    }
    fn disarm(self: *Client) !void {
        const spec = std.mem.zeroes(c.struct_itimerspec);
        if (c.timerfd_settime(self.timer_fd, 0, &spec, null) != 0) return error.TimerArmFailed;
    }
    fn drainTimer(self: *Client) bool {
        var expirations: u64 = 0;
        while (true) {
            const n = c.read(self.timer_fd, &expirations, @sizeOf(u64));
            if (n < 0 and c.__errno_location().* == c.EINTR) continue;
            return n == @sizeOf(u64);
        }
    }
};

fn monotonicMs() u64 {
    var now: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) return 0;
    return @as(u64, @intCast(now.tv_sec)) * 1000 + @as(u64, @intCast(now.tv_nsec)) / std.time.ns_per_ms;
}

test "invalid paths and stop readiness" {
    try std.testing.expectError(error.InvalidSocketPath, Client.init(std.testing.allocator, "relative"));
    var client = try Client.init(std.testing.allocator, "/tmp/ouro-settings-test-does-not-exist");
    defer client.deinit();
    try client.stop();
    var pollfds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expect(linux.poll(&pollfds, 1, 100) == 1);
}

// Real Unix sockets, with explicit protocol handshakes instead of sleep-based
// timing. Test storage is private and never touches the user's settings socket.
const TestServer = struct {
    directory: [25:0]u8,
    path: [:0]u8,
    listener: c_int,
    peer: c_int = -1,

    fn init() !TestServer {
        var directory: [25:0]u8 = "/tmp/ouro-settings-XXXXXX".*;
        if (c.mkdtemp(&directory) == null) return error.TempFailed;
        errdefer _ = c.rmdir(&directory);
        const path = try std.fmt.allocPrintSentinel(std.testing.allocator, "{s}/socket", .{directory}, 0);
        errdefer std.testing.allocator.free(path);
        const listener = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (listener < 0) return error.SocketFailed;
        errdefer _ = c.close(listener);
        var address = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        @memcpy(address.sun_path[0..path.len], path);
        if (linux.errno(linux.bind(listener, @ptrCast(&address), @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1))) != .SUCCESS) return error.BindFailed;
        if (c.listen(listener, 4) != 0) return error.ListenFailed;
        return .{ .directory = directory, .path = path, .listener = listener };
    }

    fn deinit(self: *TestServer) void {
        if (self.peer >= 0) _ = c.close(self.peer);
        _ = c.close(self.listener);
        _ = c.unlink(self.path);
        _ = c.rmdir(&self.directory);
        std.testing.allocator.free(self.path);
    }

    fn attach(self: *TestServer, client: *Client) !void {
        if (self.peer >= 0) _ = c.close(self.peer);
        self.peer = -1;
        var received: [request.len]u8 = undefined;
        var count: usize = 0;
        const deadline = monotonicMs() + 2000;
        while (count < request.len and monotonicMs() < deadline) {
            try client.dispatch();
            if (self.peer < 0) {
                const fd = linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
                if (linux.errno(fd) == .SUCCESS) self.peer = @intCast(fd);
            }
            if (self.peer >= 0) {
                const n = c.recv(self.peer, received[count..].ptr, received.len - count, 0);
                if (n > 0) count += @intCast(n);
            }
            if (count == request.len) break;
            var fds = [_]linux.pollfd{ .{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }, .{ .fd = self.peer, .events = linux.POLL.IN, .revents = 0 } };
            _ = linux.poll(&fds, fds.len, 10);
        }
        try std.testing.expectEqualStrings(request, received[0..count]);
    }

    fn send(self: *TestServer, client: *Client, bytes: []const u8) !void {
        var offset: usize = 0;
        const deadline = monotonicMs() + 2000;
        while (offset < bytes.len and monotonicMs() < deadline) {
            const n = c.send(self.peer, bytes[offset..].ptr, bytes.len - offset, c.MSG_NOSIGNAL);
            if (n > 0) offset += @intCast(n) else if (c.__errno_location().* != c.EAGAIN) return error.SendFailed;
            try client.dispatch();
        }
        try std.testing.expectEqual(bytes.len, offset);
        try client.dispatch();
    }
};

const test_reply = "{\"parameters\":{\"revision\":\"first\",\"exists\":true,\"value_json\":\"{}\"},\"continues\":true}";

test "settings transport fragments, coalesces all frames, and sleeps when idle" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try server.attach(&client);
    try server.send(&client, test_reply[0..13]);
    try std.testing.expect(client.take() == null);
    try server.send(&client, test_reply[13..] ++ "\x00");
    var first = try client.waitInitial(-1, 500);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", first.revision);
    try std.testing.expectEqualStrings("{}", first.json);
    try std.testing.expect(first.exists);
    // More than the former 32-frame budget, followed by a distinguishable tail.
    const tail = "{\"parameters\":{\"revision\":\"last\",\"exists\":false,\"value_json\":\"null\"},\"continues\":true}\x00";
    try server.send(&client, (test_reply ++ "\x00") ** 80 ++ tail);
    var last = try client.waitInitial(-1, 500);
    defer last.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("last", last.revision);
    try std.testing.expect(!last.exists);
    try std.testing.expectEqualStrings("null", last.json);
    var fds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&fds, 1, 20));
    try std.testing.expect(client.take() == null);
}

test "settings transport rejects bad replies and discards partial data on reconnect" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    const bad = [_][]const u8{
        "not JSON\x00",
        "{\"error\":\"org.varlink.service.MethodNotFound\",\"parameters\":{}}\x00",
        "{\"parameters\":{\"revision\":\"x\",\"exists\":true,\"value_json\":\"{}\"},\"continues\":false}\x00",
        "{\"parameters\":{\"revision\":\"x\",\"exists\":true,\"exists\":false,\"value_json\":\"{}\"},\"continues\":true}\x00",
        "{\"parameters\":{\"revision\":\"x\",\"exists\":true,\"value_json\":{}},\"continues\":true}\x00",
    };
    for (bad) |bytes| {
        try server.attach(&client);
        try server.send(&client, bytes);
        try std.testing.expect(client.take() == null);
        try std.testing.expectEqual(State.waiting, client.state);
        try client.arm(1);
    }
    try server.attach(&client);
    try server.send(&client, "{\"parameters\":");
    _ = c.close(server.peer);
    server.peer = -1;
    try client.dispatch();
    try std.testing.expectEqual(@as(usize, 0), client.input.items.len);
    try client.arm(1); // Backoff has reached five seconds after the bad replies.
    try server.attach(&client);
    try server.send(&client, test_reply ++ "\x00");
    var update = try client.waitInitial(-1, 500);
    defer update.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", update.json);
}

test "settings transport enforces exact frame boundary and partial reply timeout" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try server.attach(&client);
    const bytes = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0..test_reply.len], test_reply);
    bytes[bytes.len - 1] = 0;
    try server.send(&client, bytes);
    var update = try client.waitInitial(-1, 500);
    defer update.deinit(std.testing.allocator);
    bytes[bytes.len - 1] = ' ';
    try server.send(&client, bytes);
    try std.testing.expectEqual(State.waiting, client.state);
    try std.testing.expect(client.take() == null);
    try server.attach(&client);
    try server.send(&client, test_reply ++ "\x00");
    var next = try client.waitInitial(-1, 500);
    defer next.deinit(std.testing.allocator);
    try server.send(&client, "{");
    try std.testing.expect(client.partial_frame);
    try client.arm(1); // Exercise the real timer expiry without a five-second test.
    var fds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&fds, 1, 500));
    try client.dispatch();
    try std.testing.expectEqual(State.waiting, client.state);
}

test "settings startup is bounded and interruptible without consuming shutdown" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try std.testing.expectError(error.StartupTimeout, client.waitInitial(-1, 20));
    const event = linux.eventfd(1, linux.EFD.NONBLOCK | linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(event));
    defer _ = linux.close(@intCast(event));
    try std.testing.expectError(error.StartupInterrupted, client.waitInitial(@intCast(event), 500));
    var count: u64 = 0;
    try std.testing.expectEqual(@as(usize, 8), linux.read(@intCast(event), std.mem.asBytes(&count).ptr, 8));
    try std.testing.expectEqual(@as(u64, 1), count);
}
