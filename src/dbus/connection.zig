//! D-Bus socket I/O on Ouro's borrowed io_uring. prepare() only queues SQEs;
//! the host submits once per turn and routes every target and cancel CQE back.
//! Codec and address/authentication handling derived from Ourokit; see LICENSE.
const std = @import("std");
const linux = std.os.linux;
const completion = @import("../runtime/completion.zig");
pub const wire = @import("wire.zig");

const max_messages = 256;
const max_queued_bytes = 4 * 1024 * 1024;
const timeout_ms = 5000;
const Phase = enum { idle, connecting, auth_write, auth_read, begin_write, hello_write, hello_read, ready, closing };
const Kind = enum { connect, write, read, timeout };
const Pending = struct { serial: u32, deadline: u64 };
const Frame = struct {
    bytes: []u8,
    offset: usize = 0,
    serial: u32,
    expects_reply: bool,
    tracked: bool = false,
    deadline: u64 = 0,
};

// A cancellation CQE does not release the target's buffers. Either completion
// order is legal; neither this slot nor its storage can be reused until both.
const Operation = struct {
    token: ?completion.Token = null,
    cancel: ?completion.Token = null,
    canceling: bool = false,

    fn idle(self: Operation) bool {
        return self.token == null and self.cancel == null;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    addresses: []u8,
    next_address: usize = 0,
    socket_fd: linux.fd_t = -1,
    phase: Phase = .idle,
    stopping: bool = false,
    failure: ?anyerror = null,
    next_serial: u64 = 2, // Hello reserves serial 1 on each new connection.
    deadline: ?u64 = null,
    operations: [4]Operation = @splat(.{}),
    // All kernel-borrowed storage has a stable address until its terminal CQE.
    address: ParsedAddress = undefined,
    timeout: linux.kernel_timespec = undefined,
    timeout_deadline: u64 = 0,
    recv_buffer: [16384]u8 = undefined,
    auth_out: [160]u8 = undefined,
    auth_len: usize = 0,
    auth_offset: usize = 0,
    auth: std.ArrayList(u8) = .empty,
    receive: std.ArrayList(u8) = .empty,
    outgoing: std.ArrayList(Frame) = .empty,
    outgoing_bytes: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    messages: std.ArrayList(wire.Message) = .empty,
    message_bytes: usize = 0,
    hello: ?Frame = null,

    /// May move the returned value only before the first prepare().
    pub fn init(allocator: std.mem.Allocator, addresses: []const u8) !Client {
        var valid = false;
        var it = std.mem.splitScalar(u8, addresses, ';');
        while (it.next()) |candidate| if (parseAddress(candidate)) |_| {
            valid = true;
        } else |_| {};
        if (!valid) return error.InvalidAddress;
        return .{ .allocator = allocator, .addresses = try allocator.dupe(u8, addresses) };
    }

    /// Copies the request. This does not submit I/O, block, or retry a call.
    pub fn send(self: *Client, metadata: wire.Metadata, body: []const u8) !u32 {
        if (self.stopping) return error.Stopping;
        if (self.phase == .closing or self.failure != null) return error.ConnectionClosing;
        if (self.next_serial > std.math.maxInt(u32)) return error.SerialExhausted;
        if (self.outgoing.items.len + self.pending.items.len >= max_messages) return error.QueueFull;
        const serial: u32 = @intCast(self.next_serial);
        const bytes = try wire.encodeMessage(self.allocator, metadata, serial, body, 0);
        errdefer self.allocator.free(bytes);
        if (bytes.len > max_queued_bytes -| self.outgoing_bytes) return error.QueueFull;
        _ = try wire.parseMessage(self.allocator, bytes, &.{});
        try self.outgoing.append(self.allocator, .{
            .bytes = bytes,
            .serial = serial,
            .expects_reply = metadata.message_type == .method_call and metadata.flags & 1 == 0,
            .deadline = monotonicMs() + timeout_ms,
        });
        self.outgoing_bytes += bytes.len;
        self.next_serial += 1;
        return serial;
    }

    pub fn takeMessage(self: *Client) ?wire.Message {
        if (self.messages.items.len == 0) return null;
        const result = self.messages.orderedRemove(0);
        self.message_bytes -= result.data.len;
        return result;
    }

    pub fn takeFailure(self: *Client) ?anyerror {
        const failure = self.failure;
        self.failure = null;
        return failure;
    }

    /// Returns true only when SQ/router pressure requires another prepare turn.
    /// Never submits or waits; all completions belong to the host's shared ring.
    pub fn prepare(self: *Client, ring: *linux.IoUring, router: *completion.Router) bool {
        self.prepareIo(ring, router) catch |err| switch (err) {
            error.SubmissionQueueFull, error.Exhausted => return true,
            else => {
                self.fail(err);
                return true;
            },
        };
        return false;
    }

    fn prepareIo(self: *Client, ring: *linux.IoUring, router: *completion.Router) !void {
        if (self.phase != .closing) if (self.nextDeadline()) |deadline| {
            if (monotonicMs() >= deadline) self.fail(error.Timeout);
        };
        if (self.phase == .closing) {
            inline for (std.meta.tags(Kind)) |kind| try self.cancelOperation(ring, router, kind);
            if (self.operationsIdle()) self.reset();
            return;
        }
        if (self.stopping) return;
        if (self.phase == .idle and self.outgoing.items.len != 0) {
            try self.openNextAddress();
            self.deadline = monotonicMs() + timeout_ms;
            self.phase = .connecting;
        }
        try self.prepareTimeout(ring, router);
        switch (self.phase) {
            .connecting => {
                const op = self.operation(.connect);
                if (!op.idle()) return;
                const token = try router.acquire(.launcher);
                errdefer router.retire(token) catch unreachable;
                _ = try ring.connect(token.encode(), self.socket_fd, @ptrCast(&self.address.address), self.address.length);
                op.token = token;
            },
            .auth_write, .begin_write, .hello_write => try self.prepareWrite(ring, router),
            .auth_read, .hello_read => try self.prepareRead(ring, router),
            .ready => {
                // Keep receive live during a blocked send, rather than making
                // a large request prevent processing an earlier call's reply.
                try self.prepareRead(ring, router);
                try self.prepareWrite(ring, router);
            },
            .idle, .closing => {},
        }
    }

    pub fn complete(self: *Client, router: *completion.Router, token: completion.Token, result: i32) !void {
        inline for (std.meta.tags(Kind)) |kind| {
            const op = self.operation(kind);
            if (op.cancel) |cancel| if (std.meta.eql(cancel, token)) {
                try router.retire(token);
                op.cancel = null;
                if (op.token == null) op.* = .{};
                if (result != 0 and result != negative(.NOENT) and result != negative(.ALREADY) and result != negative(.BUSY))
                    self.fail(error.CancellationFailed);
                return;
            };
            if (op.token) |target| if (std.meta.eql(target, token)) {
                try router.retire(token);
                const canceled = op.canceling;
                op.token = null;
                if (op.cancel == null) op.* = .{};
                if (self.phase == .closing) return;
                if (kind == .timeout and canceled) return;
                self.handleCompletion(kind, result) catch |err| self.fail(err);
                return;
            };
        }
        return error.UnknownDbusCompletion;
    }

    pub fn stop(self: *Client) void {
        self.stopping = true;
        self.phase = .closing;
        // prepare() cancels all live operations; do not close the socket or
        // release send/receive/address storage while the kernel can use it.
    }

    pub fn drained(self: *const Client) bool {
        return self.phase == .idle and self.operationsIdle() and self.outgoing.items.len == 0;
    }

    pub fn deinit(self: *Client) void {
        std.debug.assert(self.operationsIdle());
        self.reset();
        for (self.messages.items) |*message| message.deinit();
        self.messages.deinit(self.allocator);
        self.outgoing.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.receive.deinit(self.allocator);
        self.auth.deinit(self.allocator);
        self.allocator.free(self.addresses);
        self.* = undefined;
    }

    fn operation(self: *Client, kind: Kind) *Operation {
        return &self.operations[@intFromEnum(kind)];
    }

    fn operationsIdle(self: *const Client) bool {
        for (self.operations) |op| if (!op.idle()) return false;
        return true;
    }

    fn cancelOperation(self: *Client, ring: *linux.IoUring, router: *completion.Router, kind: Kind) !void {
        const op = self.operation(kind);
        const target = op.token orelse return;
        if (op.canceling) return;
        const token = try router.acquire(.launcher);
        errdefer router.retire(token) catch unreachable;
        if (kind == .timeout)
            _ = try ring.timeout_remove(token.encode(), target.encode(), 0)
        else
            _ = try ring.cancel(token.encode(), target.encode(), 0);
        op.cancel = token;
        op.canceling = true;
    }

    fn prepareTimeout(self: *Client, ring: *linux.IoUring, router: *completion.Router) !void {
        const deadline = self.nextDeadline();
        const op = self.operation(.timeout);
        if (!op.idle()) {
            if (deadline == null or deadline.? != self.timeout_deadline) try self.cancelOperation(ring, router, .timeout);
            return;
        }
        const milliseconds = deadline orelse return;
        const token = try router.acquire(.launcher);
        errdefer router.retire(token) catch unreachable;
        self.timeout = .{ .sec = @intCast(milliseconds / 1000), .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms) };
        _ = try ring.timeout(token.encode(), &self.timeout, 0, linux.IORING_TIMEOUT_ABS);
        self.timeout_deadline = milliseconds;
        op.token = token;
    }

    fn prepareRead(self: *Client, ring: *linux.IoUring, router: *completion.Router) !void {
        const op = self.operation(.read);
        if (!op.idle()) return;
        const token = try router.acquire(.launcher);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.recv(token.encode(), self.socket_fd, .{ .buffer = &self.recv_buffer }, 0);
        op.token = token;
    }

    fn prepareWrite(self: *Client, ring: *linux.IoUring, router: *completion.Router) !void {
        const op = self.operation(.write);
        if (!op.idle()) return;
        const bytes = switch (self.phase) {
            .auth_write, .begin_write => self.auth_out[self.auth_offset..self.auth_len],
            .hello_write => self.hello.?.bytes[self.hello.?.offset..],
            .ready => queued: {
                if (self.outgoing.items.len == 0) return;
                const frame = &self.outgoing.items[0];
                if (frame.expects_reply and !frame.tracked) {
                    // A reply can complete before the send CQE is dispatched.
                    try self.pending.append(self.allocator, .{ .serial = frame.serial, .deadline = frame.deadline });
                    frame.tracked = true;
                }
                break :queued frame.bytes[frame.offset..];
            },
            else => unreachable,
        };
        const token = try router.acquire(.launcher);
        errdefer router.retire(token) catch unreachable;
        _ = try ring.send(token.encode(), self.socket_fd, bytes[0..@min(bytes.len, 16384)], linux.MSG.NOSIGNAL);
        op.token = token;
    }

    fn handleCompletion(self: *Client, kind: Kind, result: i32) !void {
        if (kind == .timeout) {
            if (result != negative(.TIME)) return error.UnexpectedTimeoutResult;
            if (self.nextDeadline()) |deadline| if (monotonicMs() >= deadline) return error.Timeout;
            return;
        }
        if (kind == .connect) {
            if (result < 0) {
                _ = linux.close(self.socket_fd);
                self.socket_fd = -1;
                try self.openNextAddress();
                return;
            }
            try self.setExternal();
            self.phase = .auth_write;
            return;
        }
        if (result == negative(.INTR) or result == negative(.AGAIN)) return;
        if (result <= 0) return error.ConnectionClosed;
        const count: usize = @intCast(result);
        if (kind == .read) {
            try self.consumeReceive(self.recv_buffer[0..count]);
            return;
        }
        switch (self.phase) {
            .auth_write, .begin_write => {
                self.auth_offset += count;
                if (self.auth_offset != self.auth_len) return;
                if (self.phase == .auth_write) {
                    self.phase = .auth_read;
                } else {
                    self.hello = .{
                        .bytes = try wire.encodeMessage(self.allocator, .{ .message_type = .method_call, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello", .destination = "org.freedesktop.DBus" }, 1, &.{}, 0),
                        .serial = 1,
                        .expects_reply = true,
                    };
                    self.phase = .hello_write;
                }
            },
            .hello_write => {
                self.hello.?.offset += count;
                if (self.hello.?.offset != self.hello.?.bytes.len) return;
                self.allocator.free(self.hello.?.bytes);
                self.hello = null;
                self.phase = .hello_read;
            },
            .ready => {
                const frame = &self.outgoing.items[0];
                frame.offset += count;
                if (frame.offset != frame.bytes.len) return;
                self.outgoing_bytes -= frame.bytes.len;
                self.allocator.free(frame.bytes);
                _ = self.outgoing.orderedRemove(0);
            },
            else => return error.ProtocolError,
        }
    }

    fn consumeReceive(self: *Client, bytes: []const u8) !void {
        if (self.phase == .auth_read) {
            try self.auth.appendSlice(self.allocator, bytes);
            if (self.auth.items.len > 1024) return error.ProtocolError;
            if (std.mem.indexOf(u8, self.auth.items, "\r\n")) |end| {
                if (!std.mem.startsWith(u8, self.auth.items[0..end], "OK ")) return error.AuthenticationFailed;
                if (end + 2 != self.auth.items.len) return error.ProtocolError;
                self.auth.clearRetainingCapacity();
                @memcpy(self.auth_out[0..7], "BEGIN\r\n");
                self.auth_len = 7;
                self.auth_offset = 0;
                self.phase = .begin_write;
            }
            return;
        }
        if (bytes.len > wire.max_message_size -| self.receive.items.len) return error.ProtocolError;
        try self.receive.appendSlice(self.allocator, bytes);
        while (try wire.messageLength(self.receive.items)) |length| {
            if (self.messages.items.len >= max_messages or length > wire.max_message_size -| self.message_bytes) return error.QueueFull;
            const data = try self.allocator.dupe(u8, self.receive.items[0..length]);
            errdefer self.allocator.free(data);
            const fds = try self.allocator.alloc(std.posix.fd_t, 0);
            errdefer self.allocator.free(fds);
            var message = try wire.parseMessage(self.allocator, data, fds);
            const remain = self.receive.items.len - length;
            std.mem.copyForwards(u8, self.receive.items[0..remain], self.receive.items[length..]);
            self.receive.items.len = remain;
            if (self.phase == .hello_read and message.header.reply_serial == 1) {
                if (message.messageType() != .method_return or !std.mem.eql(u8, message.bodySignature(), "s")) return error.ProtocolError;
                var d = message.bodyDecoder();
                _ = try d.string();
                try d.end();
                self.phase = .ready;
                self.deadline = null;
                message.deinit();
            } else {
                if (message.header.reply_serial) |reply| for (self.pending.items, 0..) |pending, i| if (pending.serial == reply) {
                    _ = self.pending.orderedRemove(i);
                    break;
                };
                try self.messages.append(self.allocator, message);
                self.message_bytes += message.data.len;
            }
        }
    }

    fn openNextAddress(self: *Client) !void {
        while (self.next_address < self.addresses.len) {
            const start = self.next_address;
            const end = std.mem.indexOfScalarPos(u8, self.addresses, start, ';') orelse self.addresses.len;
            self.next_address = end + 1;
            self.address = parseAddress(self.addresses[start..end]) catch continue;
            const fd = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
            if (linux.errno(fd) != .SUCCESS) return error.SystemResources;
            self.socket_fd = @intCast(fd);
            return;
        }
        return error.AddressUnavailable;
    }

    fn setExternal(self: *Client) !void {
        var uid: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&uid, "{d}", .{linux.getuid()});
        var w: std.Io.Writer = .fixed(&self.auth_out);
        try w.writeByte(0);
        try w.writeAll("AUTH EXTERNAL ");
        for (text) |ch| try w.print("{x:0>2}", .{ch});
        try w.writeAll("\r\n");
        self.auth_len = w.buffered().len;
        self.auth_offset = 0;
    }

    fn fail(self: *Client, err: anyerror) void {
        if (self.phase == .closing) return;
        self.failure = err;
        self.phase = .closing;
    }

    fn reset(self: *Client) void {
        std.debug.assert(self.operationsIdle());
        if (self.socket_fd >= 0) _ = linux.close(self.socket_fd);
        self.socket_fd = -1;
        if (self.hello) |h| self.allocator.free(h.bytes);
        self.hello = null;
        for (self.outgoing.items) |frame| self.allocator.free(frame.bytes);
        self.outgoing.clearRetainingCapacity();
        self.outgoing_bytes = 0;
        self.pending.clearRetainingCapacity();
        self.auth.clearRetainingCapacity();
        self.receive.clearRetainingCapacity();
        self.next_address = 0;
        self.phase = .idle;
        self.deadline = null;
    }

    fn nextDeadline(self: *const Client) ?u64 {
        var deadline = self.deadline;
        for (self.outgoing.items) |frame| deadline = @min(deadline orelse frame.deadline, frame.deadline);
        for (self.pending.items) |pending| deadline = @min(deadline orelse pending.deadline, pending.deadline);
        return deadline;
    }
};

const ParsedAddress = struct { address: linux.sockaddr.un, length: linux.socklen_t };
fn parseAddress(text: []const u8) !ParsedAddress {
    if (!std.mem.startsWith(u8, text, "unix:")) return error.InvalidAddress;
    var result: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = @splat(0) };
    var found = false;
    var abstract = false;
    var length: usize = 0;
    var options = std.mem.splitScalar(u8, text[5..], ',');
    while (options.next()) |option| {
        const eq = std.mem.indexOfScalar(u8, option, '=') orelse return error.InvalidAddress;
        const key = option[0..eq];
        if (!std.mem.eql(u8, key, "path") and !std.mem.eql(u8, key, "abstract")) continue;
        if (found) return error.InvalidAddress;
        found = true;
        abstract = std.mem.eql(u8, key, "abstract");
        if (abstract) length = 1;
        var i = eq + 1;
        while (i < option.len) {
            var ch = option[i];
            if (ch == '%') {
                if (i + 2 >= option.len) return error.InvalidAddress;
                ch = std.fmt.parseInt(u8, option[i + 1 .. i + 3], 16) catch return error.InvalidAddress;
                i += 3;
            } else i += 1;
            if (ch == 0 and !abstract) return error.InvalidAddress;
            if (length >= result.path.len - @intFromBool(!abstract)) return error.InvalidAddress;
            result.path[length] = ch;
            length += 1;
        }
    }
    if (!found or length <= @intFromBool(abstract)) return error.InvalidAddress;
    if (!abstract) length += 1;
    return .{ .address = result, .length = @intCast(@offsetOf(linux.sockaddr.un, "path") + length) };
}

fn negative(err: linux.E) i32 {
    return -@as(i32, @intFromEnum(err));
}

fn monotonicMs() u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) unreachable;
    return @as(u64, @intCast(now.sec)) * 1000 + @as(u64, @intCast(now.nsec)) / std.time.ns_per_ms;
}

const test_c = @cImport({
    @cInclude("sys/socket.h");
    @cInclude("unistd.h");
    @cInclude("errno.h");
});
const test_method: wire.Metadata = .{ .message_type = .method_call, .path = "/test", .member = "Test", .destination = "org.example.Test" };

const Harness = struct {
    client: Client,
    ring: linux.IoUring,
    router: completion.Router,
    peer: linux.fd_t,
    expires: u64,

    fn init(allocator: std.mem.Allocator, entries: u16) !Harness {
        var ring = try linux.IoUring.init(entries, 0);
        errdefer ring.deinit();
        var router = try completion.Router.init(std.testing.allocator, 16);
        errdefer router.deinit(std.testing.allocator);
        var client = try Client.init(allocator, "unix:path=/unused");
        errdefer client.deinit();
        var pair: [2]c_int = undefined;
        if (test_c.socketpair(test_c.AF_UNIX, test_c.SOCK_STREAM | test_c.SOCK_CLOEXEC, 0, &pair) != 0) return error.SocketFailed;
        client.socket_fd = pair[0];
        client.phase = .ready;
        return .{ .client = client, .ring = ring, .router = router, .peer = pair[1], .expires = monotonicMs() + 2000 };
    }

    fn tick(self: *Harness) !void {
        if (monotonicMs() >= self.expires) return error.TestTimeout;
        _ = self.client.prepare(&self.ring, &self.router);
        _ = try self.ring.submit();
        var cqes: [16]linux.io_uring_cqe = undefined;
        const n = try self.ring.copy_cqes(&cqes, 0);
        for (cqes[0..n]) |cqe| {
            if (cqe.user_data == 0) { // Test SQ-pressure NOPs.
                try std.testing.expectEqual(@as(i32, 0), cqe.res);
                continue;
            }
            const token = self.router.route(cqe.user_data) orelse return error.UnroutedCompletion;
            try self.client.complete(&self.router, token, cqe.res);
        }
    }

    fn drain(self: *Harness) !void {
        self.expires = monotonicMs() + 2000;
        self.client.stop();
        while (!self.client.drained()) try self.tick();
        try std.testing.expectEqual(@as(usize, 0), self.router.active_count);
    }

    fn deinit(self: *Harness) void {
        self.drain() catch @panic("D-Bus test failed to drain kernel-owned storage");
        self.client.deinit();
        self.router.deinit(std.testing.allocator);
        self.ring.deinit();
        if (self.peer >= 0) _ = test_c.close(self.peer);
    }

    fn expectBytes(self: *Harness, expected: []const u8) !void {
        const received = try std.testing.allocator.alloc(u8, expected.len);
        defer std.testing.allocator.free(received);
        var count: usize = 0;
        while (count < received.len) {
            try self.tick();
            const n = test_c.recv(self.peer, received[count..].ptr, received.len - count, test_c.MSG_DONTWAIT);
            if (n < 0) {
                if (test_c.__errno_location().* == test_c.EAGAIN) continue;
                return error.PeerReadFailed;
            }
            if (n == 0) return error.PeerClosed;
            count += @intCast(n);
        }
        try std.testing.expectEqualSlices(u8, expected, received);
    }

    fn send(self: *Harness, bytes: []const u8) !void {
        try std.testing.expectEqual(@as(isize, @intCast(bytes.len)), test_c.send(self.peer, bytes.ptr, bytes.len, test_c.MSG_NOSIGNAL | test_c.MSG_DONTWAIT));
    }
};

test "D-Bus addresses decode escaped paths and abstract names" {
    const path = try parseAddress("unix:path=/tmp/a%2cb%25c,guid=123");
    try std.testing.expectEqualStrings("/tmp/a,b%c", std.mem.sliceTo(&path.address.path, 0));
    const abstract = try parseAddress("unix:abstract=a%00b");
    try std.testing.expectEqualSlices(u8, &.{ 0, 'a', 0, 'b' }, abstract.address.path[0..4]);
    for ([_][]const u8{ "tcp:host=localhost", "unix:path=", "unix:path=/a%00b", "unix:path=%gg", "unix:path=/a,abstract=b" }) |address|
        try std.testing.expectError(error.InvalidAddress, parseAddress(address));
}

test "D-Bus native recv handles fragmented auth and coalesced replies" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 8);
    defer h.deinit();
    h.client.phase = .auth_read;
    try h.send("OK 0123\r");
    while (h.client.auth.items.len == 0) try h.tick();
    try std.testing.expectEqual(Phase.auth_read, h.client.phase);
    try h.send("\n");
    try h.expectBytes("BEGIN\r\n");
    const hello = try wire.encodeMessage(a, .{ .message_type = .method_call, .path = "/org/freedesktop/DBus", .interface = "org.freedesktop.DBus", .member = "Hello", .destination = "org.freedesktop.DBus" }, 1, &.{}, 0);
    defer a.free(hello);
    try h.expectBytes(hello);
    var body = wire.Encoder.init(a);
    defer body.deinit();
    try body.string(":1.42");
    const reply = try wire.encodeMessage(a, .{ .message_type = .method_return, .reply_serial = 1, .signature = "s" }, 91, body.bytes(), 0);
    defer a.free(reply);
    try h.send(reply[0..7]);
    while (h.client.receive.items.len == 0) try h.tick();
    try std.testing.expectEqual(Phase.hello_read, h.client.phase);
    try h.send(reply[7..]);
    while (h.client.phase != .ready) try h.tick();
    try std.testing.expect(h.client.takeMessage() == null);
    const serial = try h.client.send(test_method, &.{});
    const request = try wire.encodeMessage(a, test_method, serial, &.{}, 0);
    defer a.free(request);
    try h.expectBytes(request);
    const result = try wire.encodeMessage(a, .{ .message_type = .method_return, .reply_serial = serial }, 92, &.{}, 0);
    defer a.free(result);
    const twice = try std.mem.concat(a, u8, &.{ result, result });
    defer a.free(twice);
    try h.send(twice);
    while (h.client.messages.items.len != 2) try h.tick();
    try std.testing.expectEqual(@as(usize, 0), h.client.pending.items.len);
    try std.testing.expectEqual(serial, h.client.messages.items[0].header.reply_serial.?);
    try std.testing.expectEqual(serial, h.client.messages.items[1].header.reply_serial.?);
}

test "D-Bus partial native send does not block receiving an earlier reply" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 8);
    defer h.deinit();
    const size: c_int = 1024;
    try std.testing.expectEqual(@as(c_int, 0), test_c.setsockopt(h.client.socket_fd, test_c.SOL_SOCKET, test_c.SO_SNDBUF, &size, @sizeOf(c_int)));
    const first = try h.client.send(test_method, &.{});
    const request = try wire.encodeMessage(a, test_method, first, &.{}, 0);
    defer a.free(request);
    try h.expectBytes(request);
    while (h.client.outgoing.items.len != 0) try h.tick();
    var body = wire.Encoder.init(a);
    defer body.deinit();
    try body.string("0123456789" ** 10000);
    var method = test_method;
    method.signature = "s";
    const second = try h.client.send(method, body.bytes());
    for (0..100) |_| try h.tick();
    try std.testing.expect(h.client.outgoing.items[0].offset < h.client.outgoing.items[0].bytes.len);
    const reply = try wire.encodeMessage(a, .{ .message_type = .method_return, .reply_serial = first }, 72, &.{}, 0);
    defer a.free(reply);
    try h.send(reply);
    while (h.client.messages.items.len == 0) try h.tick();
    try std.testing.expectEqual(first, h.client.messages.items[0].header.reply_serial.?);
    try std.testing.expectEqual(@as(usize, 1), h.client.outgoing.items.len);
    const expected = try wire.encodeMessage(a, method, second, body.bytes(), 0);
    defer a.free(expected);
    try h.expectBytes(expected);
    while (h.client.outgoing.items.len != 0) try h.tick();
    try std.testing.expectEqual(@as(usize, 1), h.client.pending.items.len);
    try std.testing.expectEqual(second, h.client.pending.items[0].serial);
}

test "D-Bus reply before send CQE survives EOF without retaining a pending call" {
    const a = std.testing.allocator;
    var h = try Harness.init(a, 8);
    defer h.deinit();
    const serial = try h.client.send(test_method, &.{});
    try std.testing.expect(!h.client.prepare(&h.ring, &h.router));
    const write_token = h.client.operation(.write).token.?;
    _ = try h.ring.submit();
    const reply = try wire.encodeMessage(a, .{ .message_type = .method_return, .reply_serial = serial }, 73, &.{}, 0);
    defer a.free(reply);
    // Do not dispatch send completions yet. Let the peer receive the complete
    // request, reply, and close, then explicitly deliver recv before send.
    const expected = h.client.outgoing.items[0].bytes;
    const received = try a.alloc(u8, expected.len);
    defer a.free(received);
    var count: usize = 0;
    while (count < received.len) {
        if (monotonicMs() >= h.expires) return error.TestTimeout;
        const n = test_c.recv(h.peer, received[count..].ptr, received.len - count, test_c.MSG_DONTWAIT);
        if (n < 0 and test_c.__errno_location().* == test_c.EAGAIN) continue;
        if (n <= 0) return error.PeerReadFailed;
        count += @intCast(n);
    }
    try std.testing.expectEqualSlices(u8, expected, received);
    try h.send(reply);
    _ = test_c.close(h.peer);
    h.peer = -1;
    var write_result: ?i32 = null;
    while (write_result == null or h.client.messages.items.len == 0) {
        if (monotonicMs() >= h.expires) return error.TestTimeout;
        var cqes: [8]linux.io_uring_cqe = undefined;
        const n = try h.ring.copy_cqes(&cqes, 0);
        for (cqes[0..n]) |cqe| {
            if (cqe.user_data == write_token.encode()) {
                write_result = cqe.res;
            } else try h.client.complete(&h.router, h.router.route(cqe.user_data).?, cqe.res);
        }
    }
    try std.testing.expectEqual(@as(usize, 0), h.client.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), h.client.outgoing.items.len);
    try h.client.complete(&h.router, write_token, write_result.?);
    try std.testing.expectEqual(@as(usize, 0), h.client.pending.items.len);
    while (!h.client.drained()) try h.tick();
    try std.testing.expectEqual(error.ConnectionClosed, h.client.takeFailure().?);
    var message = h.client.takeMessage() orelse return error.MissingReply;
    defer message.deinit();
    try std.testing.expectEqual(serial, message.header.reply_serial.?);
    try std.testing.expect(h.client.takeMessage() == null);
}

test "D-Bus native timeout drops uncertain requests without replay" {
    var h = try Harness.init(std.testing.allocator, 8);
    defer h.deinit();
    try h.client.pending.append(h.client.allocator, .{ .serial = 43, .deadline = monotonicMs() + 20 });
    try std.testing.expect(!h.client.prepare(&h.ring, &h.router));
    _ = try h.ring.submit();
    const cqe = try h.ring.copy_cqe();
    try std.testing.expectEqual(h.client.operation(.timeout).token.?.encode(), cqe.user_data);
    try std.testing.expectEqual(negative(.TIME), cqe.res);
    try h.client.complete(&h.router, h.router.route(cqe.user_data).?, cqe.res);
    try std.testing.expectEqual(error.Timeout, h.client.takeFailure().?);
    while (!h.client.drained()) try h.tick();
    try std.testing.expectEqual(@as(usize, 0), h.client.pending.items.len);
    for (0..3) |_| try h.tick();
    try std.testing.expectEqual(@as(linux.fd_t, -1), h.client.socket_fd);
    try std.testing.expectEqual(@as(usize, 0), h.router.active_count);
}

test "D-Bus SQ pressure and shutdown before submission retain kernel buffers" {
    var h = try Harness.init(std.testing.allocator, 2);
    defer h.deinit();
    _ = try h.client.send(test_method, &.{});
    _ = try h.ring.nop(0);
    _ = try h.ring.nop(0);
    try std.testing.expect(h.client.prepare(&h.ring, &h.router));
    try std.testing.expectEqual(@as(usize, 0), h.router.active_count);
    try h.tick(); // Submit only the unrelated NOPs.
    try std.testing.expect(h.client.prepare(&h.ring, &h.router));
    try std.testing.expectEqual(@as(usize, 2), h.router.active_count);
    // Timeout/receive SQEs have not been submitted yet. Cancellation itself
    // must retry SQ pressure without freeing either target's storage early.
    try h.drain();
    try std.testing.expectEqual(@as(usize, 0), h.client.outgoing.items.len);
    try std.testing.expectError(error.Stopping, h.client.send(test_method, &.{}));
}

test "D-Bus router pressure retries without duplicating pending requests" {
    var h = try Harness.init(std.testing.allocator, 8);
    defer h.deinit();
    var held: [14]completion.Token = undefined;
    for (&held) |*token| token.* = try h.router.acquire(.copy);
    const serial = try h.client.send(test_method, &.{});
    // Timeout and recv fit, but send has no routing slot yet.
    try std.testing.expect(h.client.prepare(&h.ring, &h.router));
    try std.testing.expect(h.client.operation(.write).token == null);
    for (0..3) |_| try std.testing.expect(h.client.prepare(&h.ring, &h.router));
    try std.testing.expectEqual(@as(usize, 1), h.client.pending.items.len);
    try std.testing.expectEqual(serial, h.client.pending.items[0].serial);
    for (held) |token| try h.router.retire(token);
    try std.testing.expect(!h.client.prepare(&h.ring, &h.router));
    try std.testing.expect(h.client.operation(.write).token != null);
    try h.drain();
}

test "D-Bus target and cancel CQEs can arrive in either order" {
    const a = std.testing.allocator;
    for ([_]bool{ false, true }) |cancel_first| {
        var client = try Client.init(a, "unix:path=/unused");
        defer client.deinit();
        var router = try completion.Router.init(a, 2);
        defer router.deinit(a);
        const target = try router.acquire(.launcher);
        const cancel = try router.acquire(.launcher);
        client.operation(.read).* = .{ .token = target, .cancel = cancel, .canceling = true };
        client.stop();
        try client.complete(&router, if (cancel_first) cancel else target, if (cancel_first) 0 else negative(.CANCELED));
        try std.testing.expect(!client.operationsIdle());
        try std.testing.expect(!client.drained());
        try std.testing.expectEqual(@as(usize, 1), router.active_count);
        try client.complete(&router, if (cancel_first) target else cancel, if (cancel_first) negative(.CANCELED) else negative(.NOENT));
        try std.testing.expect(client.operationsIdle());
        try std.testing.expectEqual(@as(usize, 0), router.active_count);
    }
}

fn allocationFailureRoundTrip(allocator: std.mem.Allocator) !void {
    var h = try Harness.init(allocator, 8);
    defer h.deinit();
    const serial = try h.client.send(test_method, &.{});
    while (h.client.outgoing.items.len != 0) {
        try h.tick();
        if (h.client.takeFailure()) |err| return err;
    }
    const reply = try wire.encodeMessage(std.testing.allocator, .{ .message_type = .method_return, .reply_serial = serial }, 7, &.{}, 0);
    defer std.testing.allocator.free(reply);
    try h.send(reply);
    while (h.client.messages.items.len == 0) {
        try h.tick();
        if (h.client.takeFailure()) |err| return err;
    }
    try std.testing.expectEqual(serial, h.client.messages.items[0].header.reply_serial.?);
}

test "D-Bus allocation failure cancels live I/O before freeing frames" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureRoundTrip, .{});
}
