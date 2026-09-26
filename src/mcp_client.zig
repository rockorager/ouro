//! Bounded, one-shot MCP tool calls on the host's borrowed io_uring. No
//! retries: a lost reply may follow a successful side effect.
//! Socket state and cancellation follow Ourokit lua/mcp_client.zig at
//! 13abbebbee43c439dfc39c7f50b052718cadba22, without Lua; see mcp.LICENSE.
const std = @import("std");
const mcp = @import("mcp.zig");
const completion = @import("runtime/completion.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/un.h");
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
    const Phase = enum { queued, connecting, sending, reading, closing };
    const OpKind = enum { io, timeout };
    const Operation = struct {
        token: ?completion.Token = null,
        cancel: ?completion.Token = null,
        canceling: bool = false,
        fn idle(self: Operation) bool {
            return self.token == null and self.cancel == null;
        }
    };
    const Pending = struct {
        fd: linux.fd_t = -1,
        call: Call,
        address: c.struct_sockaddr_un,
        address_length: c.socklen_t,
        phase: Phase = .queued,
        sent: usize = 0,
        input: std.ArrayList(u8) = .empty,
        recv_buffer: [16384]u8 = undefined,
        deadline: u64,
        timeout: linux.kernel_timespec = undefined,
        operations: [2]Operation = @splat(.{}),
    };

    allocator: std.mem.Allocator,
    pending: [capacity]?Pending = @splat(null),
    stopping: bool = false,

    /// May move the returned value only before the first prepare().
    pub fn init(allocator: std.mem.Allocator) !Client {
        return .{ .allocator = allocator };
    }

    pub fn enqueue(self: *Client, call: Call) !void {
        if (self.stopping) return error.Stopping;
        const index = for (self.pending, 0..) |pending, i| {
            if (pending == null) break i;
        } else return error.TooManyCalls;
        const address = try socketAddress(call.address);
        const owned = try call.clone(self.allocator);
        errdefer owned.deinit(self.allocator);
        self.pending[index] = .{
            .call = owned,
            .address = address.address,
            .address_length = address.length,
            .deadline = monotonicMs() + timeout_ms,
        };
    }

    /// Queues only; true means SQ/router pressure requires another turn.
    pub fn prepare(self: *Client, ring: *linux.IoUring, router: *completion.Router) bool {
        for (0..capacity) |i| self.prepareOne(i, ring, router) catch |err| switch (err) {
            error.SubmissionQueueFull, error.Exhausted => return true,
            else => {
                self.fail(i, err);
                return true;
            },
        };
        return false;
    }

    fn prepareOne(self: *Client, index: usize, ring: *linux.IoUring, router: *completion.Router) !void {
        const p = if (self.pending[index]) |*value| value else return;
        if (p.phase != .closing and monotonicMs() >= p.deadline) self.fail(index, error.Timeout);
        if (self.stopping and p.phase != .closing) p.phase = .closing;
        if (p.phase == .closing) {
            try self.cancel(index, ring, router, .io);
            try self.cancel(index, ring, router, .timeout);
            if (p.operations[0].idle() and p.operations[1].idle()) self.finish(index);
            return;
        }
        try self.prepareTimeout(p, ring, router);
        const op = &p.operations[@intFromEnum(OpKind.io)];
        if (!op.idle()) return;
        if (p.phase == .queued) {
            const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(fd) != .SUCCESS) return error.SocketFailed;
            p.fd = @intCast(fd);
            p.phase = .connecting;
        }
        const token = try router.acquire(.mcp);
        errdefer router.retire(token) catch unreachable;
        switch (p.phase) {
            .connecting => _ = try ring.connect(token.encode(), p.fd, @ptrCast(&p.address), p.address_length),
            .sending => {
                const bytes = p.call.request[p.sent..];
                _ = try ring.send(token.encode(), p.fd, bytes[0..@min(bytes.len, 16384)], linux.MSG.NOSIGNAL);
            },
            .reading => _ = try ring.recv(token.encode(), p.fd, .{ .buffer = &p.recv_buffer }, 0),
            else => unreachable,
        }
        op.token = token;
    }

    fn prepareTimeout(self: *Client, p: *Pending, ring: *linux.IoUring, router: *completion.Router) !void {
        _ = self;
        const op = &p.operations[@intFromEnum(OpKind.timeout)];
        if (!op.idle()) return;
        const token = try router.acquire(.mcp);
        errdefer router.retire(token) catch unreachable;
        p.timeout = .{ .sec = @intCast(p.deadline / 1000), .nsec = @intCast((p.deadline % 1000) * std.time.ns_per_ms) };
        _ = try ring.timeout(token.encode(), &p.timeout, 0, linux.IORING_TIMEOUT_ABS);
        op.token = token;
    }

    fn cancel(self: *Client, index: usize, ring: *linux.IoUring, router: *completion.Router, kind: OpKind) !void {
        const op = &self.pending[index].?.operations[@intFromEnum(kind)];
        const target = op.token orelse return;
        if (op.canceling) return;
        const token = try router.acquire(.mcp);
        errdefer router.retire(token) catch unreachable;
        if (kind == .timeout) _ = try ring.timeout_remove(token.encode(), target.encode(), 0) else _ = try ring.cancel(token.encode(), target.encode(), 0);
        op.cancel = token;
        op.canceling = true;
    }

    pub fn complete(self: *Client, router: *completion.Router, token: completion.Token, result: i32) !void {
        for (0..capacity) |i| if (self.pending[i]) |*p| {
            inline for (std.meta.tags(OpKind)) |kind| {
                const op = &p.operations[@intFromEnum(kind)];
                if (op.cancel) |cancel_token| if (std.meta.eql(cancel_token, token)) {
                    try router.retire(token);
                    op.cancel = null;
                    if (op.token == null) op.* = .{};
                    if (result != 0 and result != negative(.NOENT) and result != negative(.ALREADY) and result != negative(.BUSY)) self.fail(i, error.CancellationFailed);
                    return;
                };
                if (op.token) |target| if (std.meta.eql(target, token)) {
                    const canceled = op.canceling;
                    try router.retire(token);
                    op.token = null;
                    if (op.cancel == null) op.* = .{};
                    if (p.phase == .closing or (kind == .timeout and canceled)) return;
                    self.handle(i, kind, result) catch |err| self.fail(i, err);
                    return;
                };
            }
        };
        return error.UnknownMcpCompletion;
    }

    fn handle(self: *Client, index: usize, kind: OpKind, result: i32) !void {
        const p = &self.pending[index].?;
        if (kind == .timeout) {
            if (result != negative(.TIME)) return error.UnexpectedTimeoutResult;
            return error.Timeout;
        }
        if (result == negative(.INTR) or result == negative(.AGAIN)) return;
        switch (p.phase) {
            .connecting => {
                if (result < 0) return error.ConnectFailed;
                p.phase = .sending;
            },
            .sending => {
                if (result <= 0) return error.SendFailed;
                p.sent += @intCast(result);
                if (p.sent == p.call.request.len) p.phase = .reading;
            },
            .reading => {
                if (result <= 0) return error.Disconnected;
                const bytes = p.recv_buffer[0..@intCast(result)];
                const end = std.mem.indexOfScalar(u8, bytes, '\n');
                const frame = bytes[0 .. end orelse bytes.len];
                if (p.input.items.len + frame.len >= maximum_frame_size) return error.ReplyTooLarge;
                try p.input.appendSlice(self.allocator, frame);
                if (end != null) {
                    try self.parseReply(p.call, p.input.items);
                    p.phase = .closing;
                }
            },
            else => unreachable,
        }
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

    fn fail(self: *Client, index: usize, err: anyerror) void {
        const p = if (self.pending[index]) |*value| value else return;
        if (p.phase == .closing) return;
        std.log.warn("MCP call {s} at {s} failed: {t}; not retrying", .{ p.call.method, p.call.address, err });
        p.phase = .closing;
    }

    fn finish(self: *Client, index: usize) void {
        if (self.pending[index]) |*p| {
            std.debug.assert(p.operations[0].idle() and p.operations[1].idle());
            if (p.fd >= 0) _ = linux.close(p.fd);
            p.call.deinit(self.allocator);
            p.input.deinit(self.allocator);
            self.pending[index] = null;
        }
    }

    pub fn stop(self: *Client) void {
        self.stopping = true;
        for (0..capacity) |i| {
            if (self.pending[i]) |*p| {
                if (p.phase == .queued)
                    self.finish(i)
                else
                    p.phase = .closing;
            }
        }
    }
    pub fn drained(self: *const Client) bool {
        for (self.pending) |p| if (p != null) return false;
        return true;
    }
    pub fn deinit(self: *Client) void {
        for (0..capacity) |i| self.finish(i);
        self.* = undefined;
    }
};

fn negative(err: linux.E) i32 {
    return -@as(i32, @intFromEnum(err));
}
fn monotonicMs() u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) unreachable;
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
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

const test_io = @import("runtime/socket_test.zig");
const test_request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\"}\n";
const test_reply = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"resultType\":\"complete\",\"content\":[]}}\n";

// Ourokit's client tests also use a real abstract Unix listener. This peer
// stays nonblocking so the test thread can drive the borrowed ring itself.
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
        return .{ .address = self.address, .method = "org.example.Toggle", .request = test_request };
    }
    fn accept(self: TestServer, client: *Client, io: *test_io.Loop) !c_int {
        const deadline = monotonicMs() + 2000;
        while (monotonicMs() < deadline) {
            try io.tick(client);
            const fd = linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(fd) == .SUCCESS) return @intCast(fd);
            if (linux.errno(fd) != .AGAIN) return error.AcceptFailed;
        }
        return error.AcceptTimeout;
    }
};

fn expectRequest(client: *Client, io: *test_io.Loop, peer: c_int, expected: []const u8) !void {
    const bytes = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(bytes);
    var count: usize = 0;
    const deadline = monotonicMs() + 2000;
    while (count < bytes.len and monotonicMs() < deadline) {
        try io.tick(client);
        const n = c.recv(peer, bytes[count..].ptr, bytes.len - count, 0);
        if (n > 0) count += @intCast(n) else if (n < 0 and c.__errno_location().* == c.EAGAIN) continue else return error.ReadFailed;
    }
    try std.testing.expectEqualStrings(expected, bytes[0..count]);
}
fn sendReply(peer: c_int, bytes: []const u8) !void {
    try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), c.send(peer, bytes.ptr, bytes.len, c.MSG_NOSIGNAL));
}
fn waitIdle(client: *Client, io: *test_io.Loop) !void {
    const deadline = monotonicMs() + 2000;
    while (!client.drained()) {
        if (monotonicMs() >= deadline) return error.CallTimeout;
        try io.tick(client);
    }
    try std.testing.expectEqual(@as(usize, 0), io.router.active_count);
}

test "MCP native fragmented replies and owned requests progress independently" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    var io = try test_io.Loop.init(8);
    defer io.deinit(&client);
    const server = try TestServer.init();
    defer server.deinit();
    var owned = try server.call().clone(std.testing.allocator);
    try client.enqueue(owned);
    @memset(@constCast(owned.request), '!');
    owned.deinit(std.testing.allocator);
    const stalled = try server.accept(&client, &io);
    defer _ = c.close(stalled);
    try expectRequest(&client, &io, stalled, test_request);
    try client.enqueue(server.call());
    const peer = try server.accept(&client, &io);
    defer _ = c.close(peer);
    try expectRequest(&client, &io, peer, test_request);
    try sendReply(peer, test_reply[0..25]);
    const deadline = monotonicMs() + 2000;
    while (client.pending[1].?.input.items.len != 25) {
        if (monotonicMs() >= deadline) return error.FragmentTimeout;
        try io.tick(&client);
    }
    try sendReply(peer, test_reply[25..]);
    _ = c.shutdown(peer, c.SHUT_WR);
    while (client.pending[1] != null) {
        if (monotonicMs() >= deadline) return error.FragmentTimeout;
        try io.tick(&client);
    }
    try std.testing.expect(client.pending[0] != null);
    try sendReply(stalled, test_reply);
    try waitIdle(&client, &io);
}

test "MCP reply validation and terminal errors never replay a call" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    var io = try test_io.Loop.init(8);
    defer io.deinit(&client);
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
        .{ .reply = "{\"jsonrpc\":" },
    };
    for (cases) |case| {
        const frame = std.mem.sliceTo(case.reply, '\n');
        if (case.err) |err| try std.testing.expectError(err, client.parseReply(server.call(), frame)) else try client.parseReply(server.call(), frame);
        try client.enqueue(server.call());
        const peer = try server.accept(&client, &io);
        try expectRequest(&client, &io, peer, test_request);
        try sendReply(peer, case.reply);
        _ = c.close(peer);
        try waitIdle(&client, &io);
        const extra = linux.accept4(server.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
        try std.testing.expectEqual(linux.E.AGAIN, linux.errno(extra));
    }
}

test "MCP native partial writes and exact newline-inclusive frame boundary" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    var io = try test_io.Loop.init(8);
    defer io.deinit(&client);
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
    const peer = try server.accept(&client, &io);
    defer _ = c.close(peer);
    const size: c_int = 1024;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(client.pending[0].?.fd, c.SOL_SOCKET, c.SO_SNDBUF, &size, @sizeOf(c_int)));
    for (0..32) |_| try io.tick(&client);
    try std.testing.expect(client.pending[0].?.sent < request.len);
    try expectRequest(&client, &io, peer, request);
    const reply = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(reply);
    @memset(reply, ' ');
    @memcpy(reply[0 .. test_reply.len - 1], test_reply[0 .. test_reply.len - 1]);
    reply[reply.len - 1] = '\n';
    var offset: usize = 0;
    const deadline = monotonicMs() + 3000;
    while (offset < reply.len - 1) {
        if (monotonicMs() >= deadline) return error.ReplyTimeout;
        const n = c.send(peer, reply[offset..].ptr, @min(8192, reply.len - 1 - offset), c.MSG_NOSIGNAL);
        if (n > 0) offset += @intCast(n) else if (c.__errno_location().* != c.EAGAIN) return error.SendFailed;
        try io.tick(&client);
    }
    while (client.pending[0].?.input.items.len != reply.len - 1) {
        if (monotonicMs() >= deadline) return error.ReplyTimeout;
        try io.tick(&client);
    }
    try sendReply(peer, "\n");
    try waitIdle(&client, &io);
    try client.enqueue(server.call());
    const oversized = try server.accept(&client, &io);
    defer _ = c.close(oversized);
    try expectRequest(&client, &io, oversized, test_request);
    reply[reply.len - 1] = ' ';
    offset = 0;
    while (offset < reply.len) {
        if (monotonicMs() >= deadline) return error.ReplyTimeout;
        const n = c.send(oversized, reply[offset..].ptr, @min(8192, reply.len - offset), c.MSG_NOSIGNAL);
        if (n > 0) offset += @intCast(n) else if (c.__errno_location().* != c.EAGAIN) return error.SendFailed;
        try io.tick(&client);
    }
    try waitIdle(&client, &io);
}

test "MCP native deadline, capacity and cancellation under SQ pressure" {
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    var io = try test_io.Loop.init(2);
    defer io.deinit(&client);
    const server = try TestServer.init();
    defer server.deinit();
    for (0..capacity) |_| try client.enqueue(server.call());
    try std.testing.expectError(error.TooManyCalls, client.enqueue(server.call()));
    client.pending[7].?.deadline = monotonicMs() + 20;
    const deadline = monotonicMs() + 2000;
    while (client.pending[7] != null) {
        if (monotonicMs() >= deadline) return error.TimeoutNotObserved;
        try io.tick(&client);
    }
    for (client.pending, 0..) |pending, i| try std.testing.expectEqual(i == 7, pending == null);
    try io.drain(&client);
    try std.testing.expectError(error.Stopping, client.enqueue(server.call()));
}

test "MCP stop before submission retains storage for both cancellation CQE orders" {
    for ([_]bool{ false, true }) |cancel_first| {
        var client = try Client.init(std.testing.allocator);
        defer client.deinit();
        var io = try test_io.Loop.init(2);
        defer io.deinit(&client);
        try client.enqueue(.{ .address = "unix:/unused", .method = "test", .request = test_request });
        const target = try io.router.acquire(.mcp);
        const cancel = try io.router.acquire(.mcp);
        const p = &client.pending[0].?;
        p.phase = .reading;
        p.operations[0] = .{ .token = target, .cancel = cancel, .canceling = true };
        client.stop();
        try client.complete(&io.router, if (cancel_first) cancel else target, if (cancel_first) 0 else negative(.CANCELED));
        try std.testing.expect(!client.prepare(&io.ring, &io.router));
        try std.testing.expect(client.pending[0] != null);
        try client.complete(&io.router, if (cancel_first) target else cancel, if (cancel_first) negative(.CANCELED) else negative(.NOENT));
        try std.testing.expect(!client.prepare(&io.ring, &io.router));
        try std.testing.expect(client.drained());
    }
    var client = try Client.init(std.testing.allocator);
    defer client.deinit();
    var io = try test_io.Loop.init(2);
    defer io.deinit(&client);
    try client.enqueue(.{ .address = "unix:/unused", .method = "test", .request = test_request });
    try std.testing.expect(!client.prepare(&io.ring, &io.router));
    // Both SQEs exist but the host has not submitted either yet.
    client.stop();
    try std.testing.expect(client.prepare(&io.ring, &io.router));
    try io.drain(&client);
}
