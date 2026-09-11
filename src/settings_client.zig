//! Nonblocking MCP subscription and snapshot reads for ourosettings.
const std = @import("std");
const mcp = @import("mcp.zig");
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

pub const maximum_frame_size = mcp.maximum_frame_size;
const uri = "ouro://settings/compositor";
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
const State = enum { waiting, connecting, listening, subscribed };

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
    output: []const u8 = "",
    next_id: u64 = 1,
    subscription_id: u64 = 0,
    read_id: ?u64 = null,
    dirty: bool = false,
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
        self.subscription_id = self.next_id;
        self.next_id += 1;
        self.output = try mcp.request(self.allocator, self.subscription_id, "subscriptions/listen", .{
            .notifications = .{ .resourceSubscriptions = .{uri} },
            ._meta = mcp.meta,
        });
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
            self.state = .listening;
        }
        if (self.output.len != 0 and flags & c.EPOLLOUT != 0) try self.sendRequest();
        if ((self.state == .listening or self.state == .subscribed) and flags & c.EPOLLIN != 0) try self.readSocket();
        if (self.socket_fd >= 0 and flags & (c.EPOLLERR | c.EPOLLHUP | c.EPOLLRDHUP) != 0) try self.reconnect("server disconnected");
    }

    fn sendRequest(self: *Client) !void {
        while (self.sent < self.output.len) {
            const n = c.send(self.socket_fd, self.output.ptr + self.sent, self.output.len - self.sent, c.MSG_NOSIGNAL);
            if (n > 0) self.sent += @intCast(n) else if (n < 0 and c.__errno_location().* == c.EINTR) continue else if (n < 0 and c.__errno_location().* == c.EAGAIN) return else return self.reconnect("write failed");
        }
        self.allocator.free(self.output);
        self.output = "";
        self.sent = 0;
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
                if (self.input.items.len >= maximum_frame_size and std.mem.indexOfScalar(u8, self.input.items, '\n') == null)
                    return self.reconnect("frame too large");
                if (self.input.items.len != 0 and self.state == .subscribed and !self.partial_frame) {
                    self.partial_frame = true;
                    // Partial notifications must not extend an outstanding read.
                    if (self.read_id == null) try self.arm(handshake_ms);
                }
            } else if (n == 0) return self.reconnect("server closed") else if (c.__errno_location().* == c.EINTR) continue else if (c.__errno_location().* == c.EAGAIN) return else return self.reconnect("read failed");
        }
    }

    fn processFrames(self: *Client) !void {
        // Consume every complete frame from this bounded read. Otherwise a
        // coalesced tail could be stranded when the socket is no longer ready.
        var used: usize = 0;
        while (std.mem.indexOfScalarPos(u8, self.input.items, used, '\n')) |end| {
            if (end - used + 1 > maximum_frame_size) return self.reconnect("frame too large");
            self.parseFrame(self.input.items[used..end]) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return self.reconnect("invalid reply"),
            };
            used = end + 1;
            self.partial_frame = false;
        }
        if (used != 0) {
            std.mem.copyForwards(u8, self.input.items[0 .. self.input.items.len - used], self.input.items[used..]);
            self.input.items.len -= used;
        }
        if (self.input.items.len == 0) {
            self.partial_frame = false;
            if (self.state == .subscribed and self.read_id == null) try self.disarm();
        }
    }

    fn requestRead(self: *Client) !void {
        std.debug.assert(self.read_id == null and self.output.len == 0);
        const id = self.next_id;
        self.next_id += 1;
        self.output = try mcp.request(self.allocator, id, "resources/read", .{ .uri = uri, ._meta = mcp.meta });
        self.read_id = id;
        self.dirty = false;
        self.sent = 0;
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN | c.EPOLLOUT | c.EPOLLRDHUP, .data = .{ .u64 = self.socket_generation } };
        if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_MOD, self.socket_fd, &event) != 0) return error.EpollControlFailed;
        try self.arm(handshake_ms);
    }

    fn parseFrame(self: *Client, frame: []const u8) !void {
        const parsed = try mcp.parse(self.allocator, frame);
        defer parsed.deinit();
        const reply = parsed.value;
        if (reply.object.get("method")) |method| {
            if (reply.object.contains("id") or reply.object.contains("result") or reply.object.contains("error")) return error.InvalidReply;
            const params = try mcp.field(reply, "params");
            const meta = try mcp.field(params, "_meta");
            if (!mcp.isId(try mcp.field(meta, "io.modelcontextprotocol/subscriptionId"), self.subscription_id)) return error.InvalidReply;
            if (mcp.isString(method, "notifications/subscriptions/acknowledged")) {
                if (self.state != .listening or self.output.len != 0) return error.InvalidReply;
                const filter = try mcp.field(try mcp.field(params, "notifications"), "resourceSubscriptions");
                if (filter != .array) return error.InvalidReply;
                var accepted = false;
                for (filter.array.items) |item| {
                    if (item != .string) return error.InvalidReply;
                    if (mcp.isString(item, uri)) accepted = true;
                }
                if (!accepted) return error.InvalidReply;
                self.state = .subscribed;
                return self.requestRead();
            }
            if (!mcp.isString(method, "notifications/resources/updated") or self.state != .subscribed or
                !mcp.isString(try mcp.field(params, "uri"), uri)) return error.InvalidReply;
            if (self.read_id != null) self.dirty = true else try self.requestRead();
            return;
        }
        const result = try mcp.complete(reply, self.read_id orelse return error.InvalidReply);
        // Reject a response before its corresponding request has been sent.
        if (self.output.len != 0) return error.InvalidReply;
        const contents = try mcp.field(result, "contents");
        if (contents != .array) return error.InvalidReply;
        var selection: ?std.json.Value = null;
        for (contents.array.items) |entry| {
            if (mcp.isString(try mcp.field(entry, "uri"), uri)) {
                if (selection != null or !mcp.isString(try mcp.field(entry, "mimeType"), "application/json")) return error.InvalidReply;
                selection = try mcp.field(entry, "text");
            }
        }
        const text = selection orelse return error.InvalidReply;
        if (text != .string or !std.unicode.utf8ValidateSlice(text.string)) return error.InvalidReply;
        // Preserve number lexemes: 1, 1.0 and 1e0 differ to config validation.
        // This applies only to the resource text, not outer JSON-RPC IDs.
        const snapshot = try std.json.parseFromSlice(std.json.Value, self.allocator, text.string, .{
            .duplicate_field_behavior = .@"error",
            .parse_numbers = false,
        });
        defer snapshot.deinit();
        const token = try mcp.field(snapshot.value, "revision");
        const exists = try mcp.field(snapshot.value, "exists");
        const value = try mcp.field(snapshot.value, "value");
        if (token != .string or token.string.len == 0 or token.string.len > 128 or
            !std.unicode.utf8ValidateSlice(token.string) or exists != .bool or
            (!exists.bool and value != .null)) return error.InvalidReply;
        const update: Update = owned: {
            const revision = try self.allocator.dupe(u8, token.string);
            errdefer self.allocator.free(revision);
            const json = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
            break :owned .{ .revision = revision, .exists = exists.bool, .json = json };
        };
        if (self.queued) |*old| old.deinit(self.allocator);
        self.queued = update;
        self.read_id = null;
        self.retry_ms = retry_first;
        if (self.dirty) try self.requestRead() else try self.disarm();
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
        self.allocator.free(self.output);
        self.output = "";
        self.read_id = null;
        self.dirty = false;
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
        const id = try self.receive(client, "subscriptions/listen");
        try std.testing.expectEqual(client.subscription_id, id);
        // No read may precede the acknowledgment.
        var byte: u8 = undefined;
        try std.testing.expectEqual(@as(isize, -1), c.recv(self.peer, &byte, 1, 0));
        try std.testing.expectEqual(c.EAGAIN, c.__errno_location().*);
    }

    fn receive(self: *TestServer, client: *Client, method: []const u8) !u64 {
        var received: [1024]u8 = undefined;
        var count: usize = 0;
        const deadline = monotonicMs() + 2000;
        while (count < received.len and monotonicMs() < deadline) {
            try client.dispatch();
            if (self.peer < 0) {
                const fd = linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
                if (linux.errno(fd) == .SUCCESS) self.peer = @intCast(fd);
            }
            if (self.peer >= 0) {
                const n = c.recv(self.peer, received[count..].ptr, received.len - count, 0);
                if (n > 0) count += @intCast(n);
            }
            if (std.mem.indexOfScalar(u8, received[0..count], '\n') != null) break;
            var fds = [_]linux.pollfd{ .{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }, .{ .fd = self.peer, .events = linux.POLL.IN, .revents = 0 } };
            _ = linux.poll(&fds, fds.len, 10);
        }
        try std.testing.expect(count != 0 and received[count - 1] == '\n');
        const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, received[0..count], .{});
        defer parsed.deinit();
        const object = parsed.value.object;
        try std.testing.expectEqualStrings("2.0", object.get("jsonrpc").?.string);
        try std.testing.expectEqualStrings(method, object.get("method").?.string);
        const params = object.get("params").?.object;
        const meta = params.get("_meta").?.object;
        try std.testing.expectEqualStrings("2026-07-28", meta.get("io.modelcontextprotocol/protocolVersion").?.string);
        try std.testing.expectEqual(@as(usize, 0), meta.get("io.modelcontextprotocol/clientCapabilities").?.object.count());
        try std.testing.expectEqualStrings("ouro", meta.get("io.modelcontextprotocol/clientInfo").?.object.get("name").?.string);
        if (std.mem.eql(u8, method, "resources/read")) {
            try std.testing.expectEqualStrings("ouro://settings/compositor", params.get("uri").?.string);
        } else {
            const subscriptions = params.get("notifications").?.object.get("resourceSubscriptions").?.array.items;
            try std.testing.expectEqual(@as(usize, 1), subscriptions.len);
            try std.testing.expectEqualStrings("ouro://settings/compositor", subscriptions[0].string);
        }
        return @intCast(object.get("id").?.integer);
    }

    fn acknowledge(self: *TestServer, client: *Client) !u64 {
        const bytes = try std.fmt.allocPrint(std.testing.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{d}}},\"notifications\":{{\"resourceSubscriptions\":[\"ouro://settings/compositor\"]}}}}}}\n", .{client.subscription_id});
        defer std.testing.allocator.free(bytes);
        try self.send(client, bytes);
        return self.receive(client, "resources/read");
    }

    fn reply(self: *TestServer, client: *Client, id: u64, text: []const u8) !void {
        const bytes = try replyBytes(id, text);
        defer std.testing.allocator.free(bytes);
        try self.send(client, bytes);
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

fn replyBytes(id: u64, text: []const u8) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .result = .{ .resultType = "complete", .contents = .{.{ .uri = "ouro://settings/compositor", .mimeType = "application/json", .text = text }} },
    }, .{});
    defer std.testing.allocator.free(json);
    return std.mem.concat(std.testing.allocator, u8, &.{ json, "\n" });
}

const test_snapshot = "{\"revision\":\"first\",\"exists\":true,\"value\":{}}";
const test_ack = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"resourceSubscriptions\":[\"ouro://settings/compositor\"]}}}\n";
const test_change = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"uri\":\"ouro://settings/compositor\"}}\n";

test "settings acknowledgment plus changes before and during read are coalesced without loss" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try server.attach(&client);
    try server.send(&client, test_ack[0..13]);
    try std.testing.expect(client.take() == null);
    // Ack and changes arrive in one recv, before the client sends its read.
    try server.send(&client, test_ack[13..] ++ test_change ** 80);
    const first_id = try server.receive(&client, "resources/read");
    try std.testing.expectEqual(@as(u64, 2), first_id);
    try std.testing.expect(client.dirty);
    const bytes = try replyBytes(first_id, test_snapshot);
    defer std.testing.allocator.free(bytes);
    try server.send(&client, bytes[0..31]);
    try std.testing.expect(client.take() == null);
    try server.send(&client, bytes[31..]);
    var first = try client.waitInitial(-1, 500);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("first", first.revision);
    try std.testing.expectEqualStrings("{}", first.json);
    try std.testing.expect(first.exists);
    const second_id = try server.receive(&client, "resources/read");
    try std.testing.expectEqual(@as(u64, 3), second_id);
    // An invalidation interleaved immediately before a read response also wins.
    const second = try replyBytes(second_id, "{\"revision\":\"middle\",\"exists\":true,\"value\":{\"general\":{\"inner_gap\":17}}}");
    defer std.testing.allocator.free(second);
    const interleaved = try std.mem.concat(std.testing.allocator, u8, &.{ test_change, second });
    defer std.testing.allocator.free(interleaved);
    try server.send(&client, interleaved);
    const third_id = try server.receive(&client, "resources/read");
    try std.testing.expectEqual(@as(u64, 4), third_id);
    try server.reply(&client, third_id, "{\"revision\":\"last\",\"exists\":false,\"value\":null}");
    var last = try client.waitInitial(-1, 500);
    defer last.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("last", last.revision);
    try std.testing.expect(!last.exists);
    try std.testing.expectEqualStrings("null", last.json);
    var fds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&fds, 1, 20));
    try std.testing.expect(client.take() == null);
}

test "settings transport rejects malformed subscription IDs filters and premature reads" {
    var server = try TestServer.init();
    defer server.deinit();
    const bad = [_][]const u8{
        "not JSON\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":null}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"1\"}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"notifications\":{\"resourceSubscriptions\":[]}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":1},\"notifications\":{\"resourceSubscriptions\":[\"ouro://settings/appearance\"]}}}\n",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":2},\"notifications\":{\"resourceSubscriptions\":[\"ouro://settings/compositor\"]}}}\n",
        test_change,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"contents\":[]}}\n",
    };
    for (bad) |bytes| {
        var client = try Client.init(std.testing.allocator, server.path);
        defer client.deinit();
        try server.attach(&client);
        try server.send(&client, bytes);
        try std.testing.expect(client.take() == null);
        try std.testing.expectEqual(State.waiting, client.state);
    }
}

test "settings reconnect discards partial frames and stale results but retains owned updates" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try server.attach(&client);
    const id = try server.acknowledge(&client);
    try server.reply(&client, id, test_snapshot);
    // Hold an owned, last-good update while the socket is retired.
    try server.send(&client, "{\"jsonrpc\":");
    _ = c.close(server.peer);
    server.peer = -1;
    try client.dispatch();
    try std.testing.expectEqual(@as(usize, 0), client.input.items.len);
    try client.arm(1);
    try server.attach(&client);
    const new_id = try server.acknowledge(&client);
    try std.testing.expect(new_id > id);
    var update = try client.waitInitial(-1, 500);
    defer update.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("{}", update.json);
    // A stale response from a retired connection cannot publish on this one.
    try server.reply(&client, id, "{\"revision\":\"stale\",\"exists\":true,\"value\":{}}");
    try std.testing.expect(client.take() == null);
    try std.testing.expectEqual(State.waiting, client.state);
    try client.arm(1);
    try server.attach(&client);
    const final_id = try server.acknowledge(&client);
    try server.reply(&client, final_id, "{\"revision\":\"reconnected\",\"exists\":true,\"value\":{\"general\":{\"inner_gap\":29}}}");
    var latest = try client.waitInitial(-1, 500);
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("reconnected", latest.revision);
    try std.testing.expectEqualStrings("{\"general\":{\"inner_gap\":29}}", latest.json);
}

test "settings read validates IDs and result types including absent complete fallback" {
    const content = "\"contents\":[{\"uri\":\"ouro://settings/compositor\",\"mimeType\":\"application/json\",\"text\":\"{\\\"revision\\\":\\\"opaque-token\\\",\\\"exists\\\":true,\\\"value\\\":null}\"}]";
    const cases = [_]struct { frame: []const u8, valid: bool = false }{
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{" ++ content ++ "}}\n", .valid = true },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":null," ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":1," ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"input_required\"," ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"future\"," ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":null,\"result\":{" ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":\"2\",\"result\":{" ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{" ++ content ++ "}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"error\":{\"code\":-32602,\"message\":\"bad URI\"}}\n" },
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"contents\":[]}}\n" },
        .{ .frame = test_ack }, // Duplicate acknowledgment is not a snapshot.
        .{ .frame = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/resources/updated\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":2},\"uri\":\"ouro://settings/compositor\"}}\n" },
    };
    for (cases) |case| {
        var server = try TestServer.init();
        defer server.deinit();
        var client = try Client.init(std.testing.allocator, server.path);
        defer client.deinit();
        try server.attach(&client);
        try std.testing.expectEqual(@as(u64, 2), try server.acknowledge(&client));
        try server.send(&client, case.frame);
        if (case.valid) {
            var update = client.take() orelse return error.MissingUpdate;
            defer update.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings("opaque-token", update.revision);
            try std.testing.expect(update.exists);
            try std.testing.expectEqualStrings("null", update.json);
        } else {
            try std.testing.expectEqual(State.waiting, client.state);
            try std.testing.expect(client.take() == null);
        }
    }
}

test "settings resource text preserves number lexemes and bounded opaque revisions" {
    const value = "{\"general\":{\"inner_gap\":1.0},\"numbers\":[1,1e0,9007199254740993,123456789012345678901234567890,1e999,-3.50e-12]}";
    for ([_][]const u8{ "r" ** 128, "", "r" ** 129 }) |revision| {
        var server = try TestServer.init();
        defer server.deinit();
        var client = try Client.init(std.testing.allocator, server.path);
        defer client.deinit();
        try server.attach(&client);
        const id = try server.acknowledge(&client);
        const text = try std.fmt.allocPrint(std.testing.allocator, "{{\"revision\":\"{s}\",\"exists\":true,\"value\":{s}}}", .{ revision, value });
        defer std.testing.allocator.free(text);
        try server.reply(&client, id, text);
        if (revision.len == 128) {
            var update = client.take() orelse return error.MissingUpdate;
            defer update.deinit(std.testing.allocator);
            try std.testing.expectEqualStrings(revision, update.revision);
            try std.testing.expectEqualStrings(value, update.json);
        } else {
            try std.testing.expectEqual(State.waiting, client.state);
            try std.testing.expect(client.take() == null);
        }
    }
}

test "settings transport enforces exact frame boundary and partial reply timeout" {
    var server = try TestServer.init();
    defer server.deinit();
    var client = try Client.init(std.testing.allocator, server.path);
    defer client.deinit();
    try server.attach(&client);
    const id = try server.acknowledge(&client);
    const reply = try replyBytes(id, test_snapshot);
    defer std.testing.allocator.free(reply);
    const bytes = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, ' ');
    @memcpy(bytes[0 .. reply.len - 1], reply[0 .. reply.len - 1]);
    bytes[bytes.len - 1] = '\n';
    try server.send(&client, bytes);
    var update = try client.waitInitial(-1, 500);
    defer update.deinit(std.testing.allocator);
    bytes[bytes.len - 1] = ' ';
    try server.send(&client, bytes);
    try std.testing.expectEqual(State.waiting, client.state);
    try std.testing.expect(client.take() == null);
    try server.attach(&client);
    const next_id = try server.acknowledge(&client);
    try server.reply(&client, next_id, test_snapshot);
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
