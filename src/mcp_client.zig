//! Bounded, one-shot MCP tool calls. No retries: a lost reply may follow a
//! successful side effect. One stable epoll FD integrates with the main ring.
const std = @import("std");
const mcp = @import("mcp.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/timerfd.h");
    @cInclude("sys/un.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

pub const maximum_frame_size = mcp.maximum_frame_size;
pub const capacity = 16;
const timeout_ms = 5000;

/// Prepared during config validation, then copied into binding snapshots.
/// init borrows address/method and allocates request in the config arena;
/// clone owns all three slices independently.
pub const Call = struct {
    address: []const u8,
    method: []const u8,
    /// Includes the terminating newline. Each call has its own connection/ID.
    request: []const u8,

    pub fn init(allocator: std.mem.Allocator, address: []const u8, method: []const u8, parameters: std.json.Value) !Call {
        _ = try socketAddress(address);
        if (!validMethod(method)) return error.InvalidToolName;
        if (parameters != .object) return error.InvalidCallParameters;
        const request = try mcp.request(allocator, 1, "tools/call", .{ .name = method, .arguments = parameters, ._meta = mcp.meta });
        return .{ .address = address, .method = method, .request = request };
    }

    pub fn clone(self: Call, allocator: std.mem.Allocator) !Call {
        const address = try allocator.dupe(u8, self.address);
        errdefer allocator.free(address);
        const method = try allocator.dupe(u8, self.method);
        errdefer allocator.free(method);
        return .{ .address = address, .method = method, .request = try allocator.dupe(u8, self.request) };
    }

    fn deinit(self: Call, allocator: std.mem.Allocator) void {
        allocator.free(self.address);
        allocator.free(self.method);
        allocator.free(self.request);
    }
};

fn validMethod(method: []const u8) bool {
    if (method.len == 0 or method.len > 128) return false;
    for (method) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

fn socketAddress(text: []const u8) !struct { address: c.struct_sockaddr_un, length: c.socklen_t } {
    if (!std.mem.startsWith(u8, text, "unix:") or std.mem.indexOfScalar(u8, text, 0) != null)
        return error.InvalidMcpAddress;
    const path = text[5..];
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    if (path.len < 2 or (path[0] != '/' and path[0] != '@') or
        path.len > address.sun_path.len or (path[0] == '/' and path.len == address.sun_path.len))
        return error.InvalidMcpAddress;
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0..path.len], path);
    if (path[0] == '@') address.sun_path[0] = 0;
    return .{ .address = address, .length = @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + @as(usize, if (path[0] == '@') 0 else 1)) };
}

pub const Client = struct {
    const Pending = struct {
        fd: c_int,
        call: Call,
        state: enum { connecting, sending, reading } = .connecting,
        sent: usize = 0,
        input: std.ArrayList(u8) = .empty,
        deadline: u64,
    };

    allocator: std.mem.Allocator,
    epoll_fd: c_int,
    timer_fd: c_int,
    pending: [capacity]?Pending = @splat(null),
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator) !Client {
        const ep = c.epoll_create1(c.EPOLL_CLOEXEC);
        if (ep < 0) return error.EpollCreateFailed;
        errdefer _ = c.close(ep);
        const timer = c.timerfd_create(c.CLOCK_MONOTONIC, c.TFD_NONBLOCK | c.TFD_CLOEXEC);
        if (timer < 0) return error.TimerCreateFailed;
        errdefer _ = c.close(timer);
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN, .data = .{ .u64 = 0 } };
        if (c.epoll_ctl(ep, c.EPOLL_CTL_ADD, timer, &event) != 0) return error.EpollControlFailed;
        return .{ .allocator = allocator, .epoll_fd = ep, .timer_fd = timer };
    }

    pub fn deinit(self: *Client) void {
        for (0..capacity) |i| self.finish(i);
        _ = c.close(self.timer_fd);
        _ = c.close(self.epoll_fd);
        self.* = undefined;
    }

    pub fn descriptor(self: *const Client) linux.fd_t {
        return self.epoll_fd;
    }

    pub fn enqueue(self: *Client, call: Call) !void {
        if (self.stopping) return error.Stopping;
        const index = for (self.pending, 0..) |pending, i| {
            if (pending == null) break i;
        } else return error.TooManyCalls;
        const address = try socketAddress(call.address);
        const owned = try call.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        const result = linux.connect(fd, &address.address, address.length);
        if (linux.errno(result) != .SUCCESS and linux.errno(result) != .INPROGRESS) return error.ConnectFailed;
        var event: c.struct_epoll_event = .{ .events = c.EPOLLOUT | c.EPOLLRDHUP, .data = .{ .u64 = index + 1 } };
        if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_ADD, fd, &event) != 0) return error.EpollControlFailed;
        errdefer _ = c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_DEL, fd, null);
        self.pending[index] = .{ .fd = fd, .call = owned, .deadline = monotonicMs() + timeout_ms };
        errdefer self.pending[index] = null;
        try self.armTimer();
    }

    pub fn stop(self: *Client) !void {
        self.stopping = true;
        for (0..capacity) |i| self.finish(i);
        // Wake, rather than close, the descriptor borrowed by the ring poll.
        try self.armTimer();
    }

    pub fn dispatch(self: *Client) !void {
        var events: [capacity + 1]c.struct_epoll_event = undefined;
        const n = c.epoll_wait(self.epoll_fd, &events, events.len, 0);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) return;
            return error.EpollWaitFailed;
        }
        for (events[0..@intCast(n)]) |event| {
            if (event.data.u64 == 0) {
                var expirations: u64 = 0;
                _ = c.read(self.timer_fd, &expirations, @sizeOf(u64));
            } else {
                const index: usize = @intCast(event.data.u64 - 1);
                if (self.pending[index] != null) self.socketEvent(index, event.events) catch |err| {
                    const call = self.pending[index].?.call;
                    std.log.warn("MCP call {s} at {s} failed: {t}", .{ call.method, call.address, err });
                    self.finish(index);
                };
            }
        }
        const now = monotonicMs();
        for (self.pending, 0..) |pending, i| if (pending) |p| {
            if (p.deadline <= now) {
                std.log.warn("MCP call {s} at {s} timed out; not retrying", .{ p.call.method, p.call.address });
                self.finish(i);
            }
        };
        if (!self.stopping) try self.armTimer();
    }

    fn socketEvent(self: *Client, index: usize, flags: u32) !void {
        const p = &self.pending[index].?;
        if (p.state == .connecting and flags & c.EPOLLOUT != 0) {
            var socket_error: c_int = 0;
            var length: c.socklen_t = @sizeOf(c_int);
            if (c.getsockopt(p.fd, c.SOL_SOCKET, c.SO_ERROR, &socket_error, &length) != 0 or socket_error != 0)
                return error.ConnectFailed;
            p.state = .sending;
        }
        if (p.state == .sending and flags & c.EPOLLOUT != 0) {
            const bytes = p.call.request[p.sent..];
            const n = c.send(p.fd, bytes.ptr, @min(bytes.len, 16384), c.MSG_NOSIGNAL);
            if (n > 0) p.sent += @intCast(n) else if (n < 0 and (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR)) return else return error.SendFailed;
            if (p.sent == p.call.request.len) {
                p.state = .reading;
                var event: c.struct_epoll_event = .{ .events = c.EPOLLIN | c.EPOLLRDHUP, .data = .{ .u64 = index + 1 } };
                if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_MOD, p.fd, &event) != 0) return error.EpollControlFailed;
            }
        }
        if (p.state == .reading and flags & (c.EPOLLIN | c.EPOLLHUP | c.EPOLLRDHUP) != 0) {
            var bytes: [16384]u8 = undefined;
            const n = c.recv(p.fd, &bytes, bytes.len, 0);
            if (n > 0) {
                const received = bytes[0..@intCast(n)];
                const end = std.mem.indexOfScalar(u8, received, '\n');
                const frame = received[0 .. end orelse received.len];
                if (p.input.items.len + frame.len >= maximum_frame_size) return error.ReplyTooLarge;
                try p.input.appendSlice(self.allocator, frame);
                if (end != null) {
                    try self.parseReply(p.call, p.input.items);
                    self.finish(index);
                }
                // Drain buffered data over later turns, even with HUP set.
                return;
            } else if (n < 0 and (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR)) return;
            return error.Disconnected;
        }
        if (flags & (c.EPOLLERR | c.EPOLLHUP | c.EPOLLRDHUP) != 0) return error.Disconnected;
    }

    fn parseReply(self: *Client, call: Call, frame: []const u8) !void {
        _ = call;
        const parsed = try mcp.parse(self.allocator, frame);
        defer parsed.deinit();
        const result = try mcp.complete(parsed.value, 1);
        if ((try mcp.field(result, "content")) != .array) return error.InvalidReply;
        if (result.object.get("isError")) |is_error| {
            if (is_error != .bool) return error.InvalidReply;
            if (is_error.bool) return error.ToolError;
        }
    }

    fn finish(self: *Client, index: usize) void {
        if (self.pending[index]) |*p| {
            _ = c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_DEL, p.fd, null);
            _ = c.close(p.fd);
            p.call.deinit(self.allocator);
            p.input.deinit(self.allocator);
            self.pending[index] = null;
        }
    }

    fn armTimer(self: *Client) !void {
        var deadline: ?u64 = if (self.stopping) monotonicMs() + 1 else null;
        for (self.pending) |pending| if (pending) |p| {
            deadline = @min(deadline orelse p.deadline, p.deadline);
        };
        const milliseconds = deadline orelse 0;
        const spec: c.struct_itimerspec = .{ .it_interval = .{ .tv_sec = 0, .tv_nsec = 0 }, .it_value = .{
            .tv_sec = @intCast(milliseconds / 1000),
            .tv_nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
        } };
        if (c.timerfd_settime(self.timer_fd, c.TFD_TIMER_ABSTIME, &spec, null) != 0) return error.TimerArmFailed;
    }
};

fn monotonicMs() u64 {
    var now: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &now) != 0) unreachable;
    return @as(u64, @intCast(now.tv_sec)) * 1000 + @as(u64, @intCast(now.tv_nsec)) / std.time.ns_per_ms;
}

// Linux autobinds a unique abstract socket when only sun_family is supplied.
// The tests use real nonblocking sockets, not mocks or the user's services.
const TestServer = struct {
    listener: c_int,
    address: []u8,

    fn init() !TestServer {
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var address = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        if (linux.errno(linux.bind(fd, @ptrCast(&address), @offsetOf(c.struct_sockaddr_un, "sun_path"))) != .SUCCESS) return error.BindFailed;
        if (c.listen(fd, capacity) != 0) return error.ListenFailed;
        var length: c.socklen_t = @sizeOf(c.struct_sockaddr_un);
        if (c.getsockname(fd, @ptrCast(&address), &length) != 0) return error.AddressFailed;
        const name = address.sun_path[1 .. length - @offsetOf(c.struct_sockaddr_un, "sun_path")];
        return .{ .listener = fd, .address = try std.fmt.allocPrint(std.testing.allocator, "unix:@{s}", .{name}) };
    }

    fn deinit(self: TestServer) void {
        _ = c.close(self.listener);
        std.testing.allocator.free(self.address);
    }

    fn call(self: TestServer) Call {
        return .{ .address = self.address, .method = "org.example.Shell.Toggle", .request = test_request };
    }

    fn accept(self: TestServer) !c_int {
        const fd = linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        if (linux.errno(fd) != .SUCCESS) return error.AcceptFailed;
        return @intCast(fd);
    }
};

const test_request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"org.example.Shell.Toggle\",\"arguments\":{\"output\":\"DP-2\",\"enabled\":false},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"ouro\",\"version\":\"0.0.0\"}}}}\n";
const test_reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[]}}\n";

fn expectRequest(client: *Client, peer: c_int, expected: []const u8) !void {
    const received = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(received);
    var count: usize = 0;
    const deadline = monotonicMs() + 2000;
    while (count < received.len and monotonicMs() < deadline) {
        try client.dispatch();
        const n = c.recv(peer, received[count..].ptr, received.len - count, 0);
        if (n > 0) count += @intCast(n) else if (n < 0 and c.__errno_location().* == c.EAGAIN) continue else return error.ReadFailed;
    }
    try std.testing.expectEqualStrings(expected, received[0..count]);
}

fn sendReply(peer: c_int, bytes: []const u8) !void {
    try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), c.send(peer, bytes.ptr, bytes.len, c.MSG_NOSIGNAL));
}

fn expectIdle(client: *Client) !void {
    for (client.pending) |pending| try std.testing.expect(pending == null);
    var fds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 0), linux.poll(&fds, 1, 0));
}

test "MCP preparation enforces exact address tool name and request size limits" {
    const path = try socketAddress("unix:/" ++ "a" ** 106);
    try std.testing.expectEqual(@as(u8, 0), path.address.sun_path[107]);
    try std.testing.expectEqual(@as(c.socklen_t, 110), path.length);
    try std.testing.expectError(error.InvalidMcpAddress, socketAddress("unix:/" ++ "a" ** 107));
    try std.testing.expectError(error.InvalidMcpAddress, socketAddress("unix:/" ++ "a" ** 106 ++ ";"));
    const abstract = try socketAddress("unix:@" ++ "a" ** 107);
    try std.testing.expectEqual(@as(u8, 0), abstract.address.sun_path[0]);
    try std.testing.expectEqual(@as(u8, 'a'), abstract.address.sun_path[107]);
    try std.testing.expectEqual(@as(c.socklen_t, 110), abstract.length);
    try std.testing.expectError(error.InvalidMcpAddress, socketAddress("unix:@" ++ "a" ** 108));
    try std.testing.expectError(error.InvalidMcpAddress, socketAddress("unix:@" ++ "a" ** 107 ++ ";"));

    const literal_path = "/tmp/service;extension=literal";
    const literal = try socketAddress("unix:" ++ literal_path);
    try std.testing.expectEqualStrings(literal_path, literal.address.sun_path[0..literal_path.len]);
    try std.testing.expectEqual(@as(c.socklen_t, @offsetOf(c.struct_sockaddr_un, "sun_path") + literal_path.len + 1), literal.length);
    const literal_name = "service;v=2";
    const named = try socketAddress("unix:@" ++ literal_name);
    try std.testing.expectEqual(@as(u8, 0), named.address.sun_path[0]);
    try std.testing.expectEqualStrings(literal_name, named.address.sun_path[1 .. 1 + literal_name.len]);
    try std.testing.expectEqual(@as(c.socklen_t, @offsetOf(c.struct_sockaddr_un, "sun_path") + 1 + literal_name.len), named.length);

    for ([_][]const u8{ "toggle_launcher", "getUser", "DATA_EXPORT_v2", "admin.tools.list", "a" ** 128 }) |name|
        try std.testing.expect(validMethod(name));
    for ([_][]const u8{ "", "a" ** 129, "bad name", "bad/name", "bad\x00name" }) |name|
        try std.testing.expect(!validMethod(name));

    const prefix = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"org.example.Ping\",\"arguments\":{\"text\":\"";
    const suffix = "\"},\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"ouro\",\"version\":\"0.0.0\"}}}}\n";
    const bytes = try std.testing.allocator.alloc(u8, maximum_frame_size - prefix.len - suffix.len + 1);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');
    var parameters: std.json.Value = .{ .object = .empty };
    defer parameters.object.deinit(std.testing.allocator);
    try parameters.object.put(std.testing.allocator, "text", .{ .string = bytes[0 .. bytes.len - 1] });
    const call = try Call.init(std.testing.allocator, "unix:/tmp/s", "org.example.Ping", parameters);
    defer std.testing.allocator.free(call.request);
    try std.testing.expectEqual(maximum_frame_size, call.request.len);
    try std.testing.expectEqualStrings(prefix, call.request[0..prefix.len]);
    try std.testing.expectEqualStrings(suffix, call.request[call.request.len - suffix.len ..]);
    try parameters.object.put(std.testing.allocator, "text", .{ .string = bytes });
    try std.testing.expectError(error.CallTooLarge, Call.init(std.testing.allocator, "unix:/tmp/s", "org.example.Ping", parameters));
}

test "MCP fragmented reply, owned request, independent calls and idle readiness" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    const server = try TestServer.init();
    defer server.deinit();
    var owned = try server.call().clone(std.testing.allocator);
    try client.enqueue(owned);
    @memset(@constCast(owned.request), '!');
    owned.deinit(std.testing.allocator);
    const stalled = try server.accept();
    defer _ = c.close(stalled);
    try expectRequest(&client, stalled, test_request);
    try client.enqueue(server.call());
    const peer = try server.accept();
    defer _ = c.close(peer);
    try expectRequest(&client, peer, test_request);
    try sendReply(peer, test_reply[0..25]);
    try client.dispatch();
    try std.testing.expect(client.pending[1] != null);
    try sendReply(peer, test_reply[25..]);
    _ = c.shutdown(peer, c.SHUT_WR);
    try client.dispatch();
    try std.testing.expect(client.pending[0] != null);
    try std.testing.expect(client.pending[1] == null);
    try sendReply(stalled, test_reply);
    try client.dispatch();
    try expectIdle(&client);
}

test "MCP distinguishes RPC tool and interim errors and never retries ambiguous calls" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    const server = try TestServer.init();
    defer server.deinit();
    const cases = [_]struct { reply: []const u8, err: ?anyerror = error.InvalidReply }{
        .{ .reply = "not JSON\n" },
        .{ .reply = "[]\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"resultType\":\"complete\",\"content\":[]}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"result\":{\"resultType\":\"complete\",\"content\":[]}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[]}}\n", .err = null },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":null,\"content\":[]}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":3,\"content\":[]}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"input_required\"}}\n", .err = error.UnsupportedResult },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"future\"}}\n", .err = error.UnsupportedResult },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":true}}\n", .err = error.ToolError },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-32602,\"message\":\"unknown tool\"}}\n", .err = error.RpcError },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[],\"isError\":\"false\"}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{},\"result\":{}}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":4}\n" },
        .{ .reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1,\"message\":\"bad\"},\"result\":{}}\n" },
        .{ .reply = test_reply, .err = null },
        .{ .reply = "{\"jsonrpc\":" }, // EOF after a side effect is terminal too.
    };
    for (cases) |case| {
        const frame = std.mem.sliceTo(case.reply, '\n');
        if (case.err) |err| {
            try std.testing.expectError(err, client.parseReply(server.call(), frame));
        } else {
            try client.parseReply(server.call(), frame);
        }
        try client.enqueue(server.call());
        const peer = try server.accept();
        try expectRequest(&client, peer, test_request);
        try sendReply(peer, case.reply);
        _ = c.close(peer);
        for (0..3) |_| try client.dispatch();
        try expectIdle(&client);
        try std.testing.expectError(error.AcceptFailed, server.accept());
    }
}

test "MCP partial writes resume exactly and frame limit includes newline" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    const server = try TestServer.init();
    defer server.deinit();
    const request = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(request);
    @memset(request, ' ');
    @memcpy(request[0 .. test_request.len - 1], test_request[0 .. test_request.len - 1]);
    request[request.len - 1] = '\n';
    var call = server.call();
    call.request = request;
    try client.enqueue(call);
    const peer = try server.accept();
    defer _ = c.close(peer);
    const buffer_size: c_int = 1024;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(client.pending[0].?.fd, c.SOL_SOCKET, c.SO_SNDBUF, &buffer_size, @sizeOf(c_int)));
    try client.dispatch();
    try std.testing.expect(client.pending[0].?.sent > 0 and client.pending[0].?.sent < request.len);
    const sent = client.pending[0].?.sent;
    try client.dispatch();
    try std.testing.expectEqual(sent, client.pending[0].?.sent);
    try expectRequest(&client, peer, request);
    const reply = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(reply);
    @memset(reply, ' ');
    @memcpy(reply[0 .. test_reply.len - 1], test_reply[0 .. test_reply.len - 1]);
    reply[reply.len - 1] = '\n';
    // Each chunk is consumed separately; the final newline is its own read.
    var offset: usize = 0;
    while (offset < reply.len - 1) {
        const end = @min(offset + 8192, reply.len - 1);
        try sendReply(peer, reply[offset..end]);
        try client.dispatch();
        offset = end;
    }
    try std.testing.expect(client.pending[0] != null);
    try sendReply(peer, "\n");
    try client.dispatch();
    try expectIdle(&client);
    try client.enqueue(server.call());
    const oversized = try server.accept();
    defer _ = c.close(oversized);
    try expectRequest(&client, oversized, test_request);
    reply[reply.len - 1] = ' ';
    offset = 0;
    while (offset < reply.len) : (offset += 8192) {
        try sendReply(oversized, reply[offset .. offset + 8192]);
        try client.dispatch();
    }
    try expectIdle(&client);
}

test "MCP call limit, real timeout readiness and stop discard outstanding calls" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    const server = try TestServer.init();
    defer server.deinit();
    for (0..capacity) |_| try client.enqueue(server.call());
    try std.testing.expectError(error.TooManyCalls, client.enqueue(server.call()));
    // Send every request, leaving only replies and the timer able to wake us.
    try client.dispatch();
    client.pending[7].?.deadline = monotonicMs() + 2;
    try client.armTimer();
    var fds = [_]linux.pollfd{.{ .fd = client.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&fds, 1, 500));
    try client.dispatch();
    for (client.pending, 0..) |pending, i| try std.testing.expectEqual(i == 7, pending == null);
    // The server still has the original connections, never replacement calls.
    for (0..capacity) |_| _ = c.close(try server.accept());
    try std.testing.expectError(error.AcceptFailed, server.accept());
    try client.stop();
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&fds, 1, 500));
    try client.dispatch();
    try std.testing.expectError(error.Stopping, client.enqueue(server.call()));
    try expectIdle(&client);
}
