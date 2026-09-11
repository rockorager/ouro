//! Bounded local MCP 2026-07-28 server.  The epoll descriptor remains valid
//! across stop(), so an outstanding io_uring poll can be retired safely.
const std = @import("std");
const mcp = @import("mcp.zig");
const linux = std.os.linux;
const c = @cImport({
    @cDefine("_GNU_SOURCE", "1");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("sys/socket.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/un.h");
    @cInclude("unistd.h");
});

pub const maximum_frame_size = mcp.maximum_frame_size;
pub const maximum_clients = 16;
const maximum_calls = 16;
const maximum_output_size = maximum_frame_size;
const io_chunk = 16 * 1024;
const maximum_events = 32;
const version = "2026-07-28";

pub const Call = struct { name: []const u8, arguments: std.json.Value };

const Client = struct {
    fd: c_int,
    generation: u32,
    input: std.ArrayList(u8) = .empty,
    output: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    subscriptions: [8]?Id = @splat(null),
};
const Id = union(enum) { integer: i64, string: []u8 };
const Pending = struct {
    client: usize,
    generation: u32,
    parsed: std.json.Parsed(std.json.Value),
    id: std.json.Value,
    name: []const u8,
    arguments: std.json.Value,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    epoll_fd: c_int,
    wake_fd: c_int,
    listener: c_int,
    path: []u8,
    device: c.dev_t,
    inode: c.ino_t,
    catalog: []u8,
    clients: [maximum_clients]?Client = @splat(null),
    generations: [maximum_clients]u32 = @splat(0),
    calls: [maximum_calls]?Pending = @splat(null),
    call_count: usize = 0,
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, catalog: []const u8) !Server {
        if (path.len == 0 or path.len >= @sizeOf(@FieldType(c.struct_sockaddr_un, "sun_path")) or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidSocketPath;
        // Refuse non-private parent directories.  The runtime directory itself
        // is intentionally checked, rather than trusting XDG_RUNTIME_DIR text.
        const dir = std.fs.path.dirname(path) orelse return error.InvalidSocketPath;
        const dir_z = try allocator.dupeZ(u8, dir);
        defer allocator.free(dir_z);
        var ds: c.struct_stat = undefined;
        if (c.lstat(dir_z.ptr, &ds) != 0 or ds.st_uid != c.geteuid() or ds.st_mode & 0o077 != 0 or ds.st_mode & c.S_IFMT != c.S_IFDIR) return error.InsecureSocketDirectory;
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        var existing: c.struct_stat = undefined;
        if (c.lstat(path_z.ptr, &existing) == 0) return error.SocketPathExists;
        if (c.__errno_location().* != c.ENOENT) return error.SocketPathFailed;

        // Keep the terminator in the slice so allocator ownership and all C
        // calls use the same allocation extent.
        const owned_path = try std.mem.concat(allocator, u8, &.{ path, "\x00" });
        errdefer allocator.free(owned_path);
        const owned_catalog = try allocator.dupe(u8, catalog);
        errdefer allocator.free(owned_catalog);
        const ep = c.epoll_create1(c.EPOLL_CLOEXEC);
        if (ep < 0) return error.EpollCreateFailed;
        errdefer _ = c.close(ep);
        const wake = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        if (wake < 0) return error.WakeFailed;
        errdefer _ = c.close(wake);
        var wake_event: c.struct_epoll_event = .{ .events = c.EPOLLIN, .data = .{ .u64 = std.math.maxInt(u64) } };
        if (c.epoll_ctl(ep, c.EPOLL_CTL_ADD, wake, &wake_event) != 0) return error.EpollControlFailed;
        const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = c.close(fd);
        var address = std.mem.zeroes(c.struct_sockaddr_un);
        address.sun_family = c.AF_UNIX;
        @memcpy(address.sun_path[0..path.len], path);
        if (c.bind(fd, .{ .__sockaddr_un__ = &address }, @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + path.len + 1)) != 0) return error.BindFailed;
        var bound = true;
        errdefer {
            if (bound) _ = c.unlink(owned_path.ptr);
        }
        if (c.chmod(owned_path.ptr, 0o600) != 0 or c.listen(fd, maximum_clients) != 0) return error.ListenFailed;
        var st: c.struct_stat = undefined;
        if (c.lstat(owned_path.ptr, &st) != 0) return error.SocketPathFailed;
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN, .data = .{ .u64 = 0 } };
        if (c.epoll_ctl(ep, c.EPOLL_CTL_ADD, fd, &event) != 0) return error.EpollControlFailed;
        bound = false;
        return .{ .allocator = allocator, .epoll_fd = ep, .wake_fd = wake, .listener = fd, .path = owned_path, .device = st.st_dev, .inode = st.st_ino, .catalog = owned_catalog };
    }

    pub fn descriptor(self: *const Server) linux.fd_t {
        return self.epoll_fd;
    }
    pub fn hasCalls(self: *const Server) bool {
        for (self.calls[0..self.call_count]) |pending| {
            const client = &self.clients[pending.?.client].?;
            if (client.output.items.len == client.sent) return true;
        }
        return false;
    }

    /// Calls wait for an empty, preallocated response buffer. Skip stalled
    /// peers without changing the ordering of calls from any one peer.
    pub fn peekCall(self: *Server) ?Call {
        for (self.calls[0..self.call_count], 0..) |pending, index| {
            const client = &self.clients[pending.?.client].?;
            if (client.output.items.len != client.sent) continue;
            const selected = pending;
            var j = index;
            while (j > 0) : (j -= 1) self.calls[j] = self.calls[j - 1];
            self.calls[0] = selected;
            client.output.clearRetainingCapacity();
            client.sent = 0;
            return .{ .name = selected.?.name, .arguments = selected.?.arguments };
        }
        return null;
    }

    pub fn completeCall(self: *Server, reply: []const u8) !void {
        if (self.call_count == 0) return error.NoPendingCall;
        const p = self.calls[0].?;
        var id_buffer: [2048]u8 = undefined;
        var id_writer = std.Io.Writer.fixed(&id_buffer);
        try std.json.Stringify.value(p.id, .{}, &id_writer);
        const encoded_id = id_writer.buffered();
        const prefix = "{\"jsonrpc\":\"2.0\",\"id\":";
        const suffix = ",\"result\":";
        const total = prefix.len + encoded_id.len + suffix.len + reply.len + 2;
        if (total > maximum_frame_size) return error.ReplyTooLarge;
        const client = &self.clients[p.client].?;
        std.debug.assert(client.output.items.len == 0);
        client.output.appendSliceAssumeCapacity(prefix);
        client.output.appendSliceAssumeCapacity(encoded_id);
        client.output.appendSliceAssumeCapacity(suffix);
        client.output.appendSliceAssumeCapacity(reply);
        client.output.appendSliceAssumeCapacity("}\n");
        self.dropHead();
        // Best-effort immediate delivery also lets exit acknowledge before
        // shutdown closes sockets. Never retry an executed action on TX error.
        self.writeSome(p.client) catch self.closeClient(p.client);
    }

    pub fn failCall(self: *Server, code: i32, message: []const u8) !void {
        if (self.call_count == 0) return error.NoPendingCall;
        const p = self.calls[0].?;
        var buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{f},\"error\":{{\"code\":{d},\"message\":{f}}}}}\n", .{ std.json.fmt(p.id, .{}), code, std.json.fmt(message, .{}) });
        const client = &self.clients[p.client].?;
        std.debug.assert(client.output.items.len == 0);
        client.output.appendSliceAssumeCapacity(writer.buffered());
        self.dropHead();
        self.writeSome(p.client) catch self.closeClient(p.client);
    }

    pub fn updateCatalog(self: *Server, catalog: []const u8) !void {
        if (std.mem.eql(u8, self.catalog, catalog)) return;
        if (catalog.len > maximum_frame_size - 2048) return error.ReplyTooLarge;
        const replacement = try self.allocator.dupe(u8, catalog);
        errdefer self.allocator.free(replacement);
        var notifications: [maximum_clients]std.ArrayList(u8) = @splat(.empty);
        defer for (&notifications) |*list| list.deinit(self.allocator);
        // Build and reserve all frames before changing the live catalog.
        for (0..maximum_clients) |i| if (self.clients[i]) |*client| {
            for (client.subscriptions) |sub| if (sub) |id| {
                try notifications[i].appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":");
                try appendId(&notifications[i], self.allocator, id);
                try notifications[i].appendSlice(self.allocator, "}}}\n");
            };
            const needed = notifications[i].items.len;
            if (client.output.items.len - client.sent + needed > maximum_output_size) return error.OutputBackpressure;
            compactOutput(client);
            try client.output.ensureUnusedCapacity(self.allocator, needed);
        };
        const old = self.catalog;
        self.catalog = replacement;
        self.allocator.free(old);
        for (0..maximum_clients) |i| if (self.clients[i]) |*client| {
            client.output.appendSliceAssumeCapacity(notifications[i].items);
            self.watch(i) catch self.closeClient(i);
        };
    }

    pub fn dispatch(self: *Server) !void {
        var events: [maximum_events]c.struct_epoll_event = undefined;
        const n = c.epoll_wait(self.epoll_fd, &events, events.len, 0);
        if (n < 0) {
            if (c.__errno_location().* == c.EINTR) return;
            return error.EpollWaitFailed;
        }
        for (events[0..@intCast(n)]) |event| {
            if (event.data.u64 == std.math.maxInt(u64)) {
                var value: u64 = 0;
                _ = c.read(self.wake_fd, &value, @sizeOf(u64));
                continue;
            }
            if (event.data.u64 == 0) {
                if (!self.stopping) self.acceptSome() catch {};
                continue;
            }
            const i: usize = @intCast((event.data.u64 & 0xffffffff) - 1);
            if (i >= maximum_clients or self.clients[i] == null) continue;
            if (@as(u32, @truncate(event.data.u64 >> 32)) != self.clients[i].?.generation) continue;
            if (event.events & c.EPOLLIN != 0) self.readSome(i) catch {
                self.closeClient(i);
                continue;
            };
            if (self.clients[i] != null and event.events & c.EPOLLOUT != 0) self.writeSome(i) catch {
                self.closeClient(i);
                continue;
            };
            if (event.events & (c.EPOLLHUP | c.EPOLLERR | c.EPOLLRDHUP) != 0) self.closeClient(i);
        }
    }

    pub fn stop(self: *Server) !void {
        if (self.stopping) return;
        self.stopping = true;
        _ = c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_DEL, self.listener, null);
        _ = c.close(self.listener);
        self.listener = -1;
        for (0..maximum_clients) |i| self.closeClient(i);
        const one: u64 = 1;
        if (c.write(self.wake_fd, &one, @sizeOf(u64)) != @sizeOf(u64)) return error.WakeFailed;
    }

    pub fn deinit(self: *Server) void {
        for (0..maximum_clients) |i| self.closeClient(i);
        while (self.call_count != 0) self.dropHead();
        if (self.listener >= 0) _ = c.close(self.listener);
        _ = c.close(self.wake_fd);
        _ = c.close(self.epoll_fd);
        var st: c.struct_stat = undefined;
        if (c.lstat(self.path.ptr, &st) == 0 and st.st_dev == self.device and st.st_ino == self.inode) _ = c.unlink(self.path.ptr);
        self.allocator.free(self.path);
        self.allocator.free(self.catalog);
        self.* = undefined;
    }

    fn acceptSome(self: *Server) !void {
        for (0..maximum_clients) |_| {
            const accepted = linux.accept4(self.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) {
                if (linux.errno(accepted) == .AGAIN or linux.errno(accepted) == .INTR) return;
                return error.AcceptFailed;
            }
            const fd: c_int = @intCast(accepted);
            var cred: c.struct_ucred = undefined;
            var len: c.socklen_t = @sizeOf(c.struct_ucred);
            if (c.getsockopt(fd, c.SOL_SOCKET, c.SO_PEERCRED, &cred, &len) != 0 or cred.uid != c.geteuid()) {
                _ = c.close(fd);
                continue;
            }
            const index = for (self.clients, 0..) |slot, i| {
                if (slot == null) break i;
            } else {
                _ = c.close(fd);
                continue;
            };
            self.generations[index] +%= 1;
            self.clients[index] = .{ .fd = fd, .generation = self.generations[index] };
            try self.watch(index);
        }
    }

    fn watch(self: *Server, i: usize) !void {
        const client = &self.clients[i].?;
        var event: c.struct_epoll_event = .{ .events = c.EPOLLIN | c.EPOLLRDHUP | (if (client.sent < client.output.items.len) @as(u32, c.EPOLLOUT) else 0), .data = .{ .u64 = (@as(u64, client.generation) << 32) | (i + 1) } };
        const op = if (c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_MOD, client.fd, &event) == 0) return else c.EPOLL_CTL_ADD;
        if (c.epoll_ctl(self.epoll_fd, op, client.fd, &event) != 0) return error.EpollControlFailed;
    }

    fn readSome(self: *Server, i: usize) !void {
        var budget: usize = 4;
        while (budget > 0) : (budget -= 1) {
            try self.processFrames(i);
            var bytes: [io_chunk]u8 = undefined;
            const n = c.recv(self.clients[i].?.fd, &bytes, bytes.len, 0);
            if (n == 0) return error.Disconnected;
            if (n < 0) {
                if (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR) return;
                return error.ReadFailed;
            }
            try self.clients[i].?.input.appendSlice(self.allocator, bytes[0..@intCast(n)]);
            try self.processFrames(i);
        }
    }

    fn processFrames(self: *Server, i: usize) !void {
        while (true) {
            const input = self.clients[i].?.input.items;
            const end = std.mem.indexOfScalar(u8, input, '\n') orelse {
                if (input.len >= maximum_frame_size) return error.FrameTooLarge;
                return;
            };
            if (end + 1 > maximum_frame_size) return error.FrameTooLarge;
            try self.request(i, input[0..end]);
            const consumed = end + 1;
            const list = &self.clients[i].?.input;
            std.mem.copyForwards(u8, list.items[0 .. list.items.len - consumed], list.items[consumed..]);
            list.items.len -= consumed;
        }
    }

    fn writeSome(self: *Server, i: usize) !void {
        const client = &self.clients[i].?;
        const bytes = client.output.items[client.sent..];
        if (bytes.len != 0) {
            const n = c.send(client.fd, bytes.ptr, @min(bytes.len, io_chunk), c.MSG_NOSIGNAL);
            if (n < 0) {
                if (c.__errno_location().* == c.EAGAIN or c.__errno_location().* == c.EINTR) return;
                return error.WriteFailed;
            }
            client.sent += @intCast(n);
        }
        if (client.sent == client.output.items.len) {
            client.output.clearRetainingCapacity();
            client.sent = 0;
        }
        try self.watch(i);
    }

    fn request(self: *Server, i: usize, frame: []const u8) !void {
        if (!std.unicode.utf8ValidateSlice(frame)) {
            try self.rpcError(i, null, -32700, "Parse error");
            return;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame, .{ .duplicate_field_behavior = .@"error", .allocate = .alloc_always, .max_value_len = maximum_frame_size }) catch {
            try self.rpcError(i, null, -32700, "Parse error");
            return;
        };
        var retained = false;
        defer if (!retained) parsed.deinit();
        const root = parsed.value;
        if (root != .object or root.object.count() > 4 or !isString(field(root, "jsonrpc"), "2.0") or field(root, "method") != .string) {
            try self.rpcError(i, null, -32600, "Invalid request");
            return;
        }
        for (root.object.keys()) |key| if (!oneOf(key, &.{ "jsonrpc", "id", "method", "params" })) {
            try self.rpcError(i, null, -32600, "Invalid request");
            return;
        };
        const method = field(root, "method").string;
        const params = field(root, "params");
        if (!root.object.contains("id")) {
            if (std.mem.eql(u8, method, "notifications/cancelled")) self.cancel(i, field(params, "requestId"));
            return;
        }
        const id = validId(field(root, "id")) orelse {
            try self.rpcError(i, null, -32600, "Invalid request ID");
            return;
        };
        if (self.activeId(i, id)) {
            try self.rpcError(i, id, -32600, "Request ID is already active");
            return;
        }
        const meta = field(params, "_meta");
        if (params != .object or meta != .object or field(meta, "io.modelcontextprotocol/clientCapabilities") != .object or field(meta, "io.modelcontextprotocol/clientInfo") != .object or field(meta, "io.modelcontextprotocol/protocolVersion") != .string) {
            try self.rpcError(i, id, -32602, "Required request metadata missing or invalid");
            return;
        }
        if (!isString(field(meta, "io.modelcontextprotocol/protocolVersion"), version)) {
            try self.rpcError(i, id, -32022, "Unsupported protocol version");
            return;
        }
        if (std.mem.eql(u8, method, "server/discover")) {
            if (!onlyMeta(params)) return self.rpcError(i, id, -32602, "Invalid params");
            try self.result(i, id, "{\"resultType\":\"complete\",\"supportedVersions\":[\"2026-07-28\"],\"capabilities\":{\"tools\":{\"listChanged\":true}},\"_meta\":{\"io.modelcontextprotocol/serverInfo\":{\"name\":\"ouro\",\"version\":\"0.0.0\"}},\"ttlMs\":60000,\"cacheScope\":\"private\"}");
            return;
        }
        if (std.mem.eql(u8, method, "tools/list")) {
            if (!onlyMeta(params)) return self.rpcError(i, id, -32602, "Invalid params");
            try self.result(i, id, self.catalog);
            return;
        }
        if (std.mem.eql(u8, method, "tools/call")) {
            const name = field(params, "name");
            const args = params.object.get("arguments") orelse std.json.Value{ .object = .empty };
            if (!onlyKeys(params, &.{ "_meta", "name", "arguments" }) or name != .string or args != .object or self.call_count == maximum_calls) return self.rpcError(i, id, -32602, "Invalid params");
            for (self.calls[0..self.call_count]) |pending| {
                if (pending.?.client == i) return self.rpcError(i, id, -32000, "Previous tool call is still pending");
            }
            try self.clients[i].?.output.ensureTotalCapacity(self.allocator, maximum_frame_size);
            self.calls[self.call_count] = .{ .client = i, .generation = self.clients[i].?.generation, .parsed = parsed, .id = id, .name = name.string, .arguments = args };
            self.call_count += 1;
            retained = true;
            return;
        }
        if (std.mem.eql(u8, method, "subscriptions/listen")) {
            try self.subscribe(i, id, params);
            return;
        }
        try self.rpcError(i, id, -32601, "Method not found; supported MCP version is 2026-07-28");
    }

    fn subscribe(self: *Server, i: usize, id: std.json.Value, params: std.json.Value) !void {
        const notifications = field(params, "notifications");
        if (!onlyKeys(params, &.{ "_meta", "notifications" }) or !onlyKeys(notifications, &.{"toolsListChanged"}) or field(notifications, "toolsListChanged") != .bool or !field(notifications, "toolsListChanged").bool) return self.rpcError(i, id, -32602, "Invalid params");
        const slot = for (&self.clients[i].?.subscriptions) |*s| {
            if (s.* == null) break s;
        } else return self.rpcError(i, id, -32602, "Subscription limit exceeded");
        const owned = try cloneId(self.allocator, id);
        errdefer freeId(self.allocator, owned);
        const encoded = try stringifyAlloc(self.allocator, id);
        defer self.allocator.free(encoded);
        const ack = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{{\"_meta\":{{\"io.modelcontextprotocol/subscriptionId\":{s}}},\"notifications\":{{\"toolsListChanged\":true}}}}}}\n", .{encoded});
        defer self.allocator.free(ack);
        try self.queue(i, ack);
        slot.* = owned;
    }

    fn result(self: *Server, i: usize, id: std.json.Value, bytes: []const u8) !void {
        const encoded = try stringifyAlloc(self.allocator, id);
        defer self.allocator.free(encoded);
        const frame = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ encoded, bytes });
        defer self.allocator.free(frame);
        try self.queue(i, frame);
    }
    fn rpcError(self: *Server, i: usize, id: ?std.json.Value, code: i32, message: []const u8) !void {
        const encoded = if (id) |v| try stringifyAlloc(self.allocator, v) else try self.allocator.dupe(u8, "null");
        defer self.allocator.free(encoded);
        const msg = try stringifyAlloc(self.allocator, message);
        defer self.allocator.free(msg);
        const frame = try std.fmt.allocPrint(self.allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}\n", .{ encoded, code, msg });
        defer self.allocator.free(frame);
        try self.queue(i, frame);
    }
    fn queue(self: *Server, i: usize, frame: []const u8) !void {
        const cl = &self.clients[i].?;
        if (frame.len > maximum_frame_size or cl.output.items.len - cl.sent + frame.len > maximum_output_size) return error.OutputBackpressure;
        compactOutput(cl);
        try cl.output.ensureUnusedCapacity(self.allocator, frame.len);
        try cl.output.appendSlice(self.allocator, frame);
        try self.watch(i);
    }
    fn cancel(self: *Server, i: usize, value: std.json.Value) void {
        const id = validId(value) orelse return;
        for (&self.clients[i].?.subscriptions) |*s| if (s.*) |owned| {
            if (sameIdValue(owned, id)) {
                freeId(self.allocator, owned);
                s.* = null;
            }
        };
    }
    fn activeId(self: *Server, i: usize, id: std.json.Value) bool {
        for (self.clients[i].?.subscriptions) |s| if (s) |v| if (sameIdValue(v, id)) return true;
        for (self.calls[0..self.call_count]) |p| if (p.?.client == i and p.?.generation == self.clients[i].?.generation and sameValue(p.?.id, id)) return true;
        return false;
    }
    fn closeClient(self: *Server, i: usize) void {
        if (self.clients[i]) |*cl| {
            const generation = cl.generation;
            _ = c.epoll_ctl(self.epoll_fd, c.EPOLL_CTL_DEL, cl.fd, null);
            _ = c.close(cl.fd);
            cl.input.deinit(self.allocator);
            cl.output.deinit(self.allocator);
            for (cl.subscriptions) |s| if (s) |id| freeId(self.allocator, id);
            self.clients[i] = null;
            var n: usize = 0;
            while (n < self.call_count) if (self.calls[n].?.client == i and self.calls[n].?.generation == generation) {
                self.removeCall(n);
            } else {
                n += 1;
            };
        }
    }
    fn removeCall(self: *Server, n: usize) void {
        self.calls[n].?.parsed.deinit();
        var j = n;
        while (j + 1 < self.call_count) : (j += 1) self.calls[j] = self.calls[j + 1];
        self.call_count -= 1;
        self.calls[self.call_count] = null;
    }
    fn dropHead(self: *Server) void {
        self.removeCall(0);
    }
};

fn compactOutput(client: *Client) void {
    std.mem.copyForwards(u8, client.output.items, client.output.items[client.sent..]);
    client.output.items.len -= client.sent;
    client.sent = 0;
}

fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}
fn isString(v: std.json.Value, s: []const u8) bool {
    return v == .string and std.mem.eql(u8, v.string, s);
}
fn oneOf(s: []const u8, values: []const []const u8) bool {
    for (values) |v| if (std.mem.eql(u8, s, v)) return true;
    return false;
}
fn onlyKeys(v: std.json.Value, keys: []const []const u8) bool {
    if (v != .object) return false;
    for (v.object.keys()) |key| if (!oneOf(key, keys)) return false;
    return true;
}
fn onlyMeta(v: std.json.Value) bool {
    return onlyKeys(v, &.{"_meta"});
}
fn validId(v: std.json.Value) ?std.json.Value {
    return switch (v) {
        .string => if (v.string.len <= 255) v else null,
        .integer => v,
        else => null,
    };
}
fn sameValue(a: std.json.Value, b: std.json.Value) bool {
    return if (a == .string and b == .string) std.mem.eql(u8, a.string, b.string) else a == .integer and b == .integer and a.integer == b.integer;
}
fn sameIdValue(a: Id, b: std.json.Value) bool {
    return switch (a) {
        .integer => |x| b == .integer and x == b.integer,
        .string => |x| b == .string and std.mem.eql(u8, x, b.string),
    };
}
fn cloneId(a: std.mem.Allocator, v: std.json.Value) !Id {
    return switch (v) {
        .integer => |x| .{ .integer = x },
        .string => |x| .{ .string = try a.dupe(u8, x) },
        else => unreachable,
    };
}
fn freeId(a: std.mem.Allocator, id: Id) void {
    switch (id) {
        .string => |s| a.free(s),
        else => {},
    }
}
fn appendId(list: *std.ArrayList(u8), a: std.mem.Allocator, id: Id) !void {
    switch (id) {
        inline .integer, .string => |x| {
            const bytes = try stringifyAlloc(a, x);
            defer a.free(bytes);
            try list.appendSlice(a, bytes);
        },
    }
}
fn stringifyAlloc(a: std.mem.Allocator, value: anytype) ![]u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}

const test_meta = "\"_meta\":{\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{},\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}";

fn testServer(tmp: *std.testing.TmpDir) !Server {
    var cwd: [4096]u8 = undefined;
    const cwd_z = c.getcwd(&cwd, cwd.len) orelse return error.GetCwdFailed;
    const dir = std.mem.span(cwd_z);
    const path = try std.fs.path.join(std.testing.allocator, &.{ dir, ".zig-cache", "tmp", &tmp.sub_path, "mcp.sock" });
    defer std.testing.allocator.free(path);
    const parent = try std.fs.path.joinZ(std.testing.allocator, &.{ dir, ".zig-cache", "tmp", &tmp.sub_path });
    defer std.testing.allocator.free(parent);
    if (c.chmod(parent.ptr, 0o700) != 0) return error.ChmodFailed;
    return Server.init(std.testing.allocator, path, "{\"tools\":[]}");
}

fn testConnect(server: *Server) !c_int {
    const fd = c.socket(c.AF_UNIX, c.SOCK_STREAM | c.SOCK_NONBLOCK | c.SOCK_CLOEXEC, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = c.close(fd);
    var address = std.mem.zeroes(c.struct_sockaddr_un);
    address.sun_family = c.AF_UNIX;
    @memcpy(address.sun_path[0 .. server.path.len - 1], server.path[0 .. server.path.len - 1]);
    if (c.connect(fd, .{ .__sockaddr_un__ = &address }, @intCast(@offsetOf(c.struct_sockaddr_un, "sun_path") + server.path.len)) != 0 and c.__errno_location().* != c.EINPROGRESS) return error.ConnectFailed;
    try server.dispatch();
    return fd;
}

fn testSend(fd: c_int, bytes: []const u8) !void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = c.send(fd, bytes[sent..].ptr, bytes.len - sent, c.MSG_NOSIGNAL);
        if (n > 0) sent += @intCast(n) else if (c.__errno_location().* != c.EAGAIN) return error.SendFailed;
    }
}

fn testReceive(server: *Server, fd: c_int, lines: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(std.testing.allocator);
    var attempts: usize = 0;
    while (std.mem.count(u8, out.items, "\n") < lines and attempts < 1000) : (attempts += 1) {
        try server.dispatch();
        var buf: [4096]u8 = undefined;
        const n = c.recv(fd, &buf, buf.len, 0);
        if (n > 0) try out.appendSlice(std.testing.allocator, buf[0..@intCast(n)]) else if (n < 0 and c.__errno_location().* != c.EAGAIN) return error.ReceiveFailed;
    }
    if (std.mem.count(u8, out.items, "\n") != lines) return error.MissingReply;
    return out.toOwnedSlice(std.testing.allocator);
}

test "MCP server production catalog is one complete newline-delimited frame" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = try testServer(&tmp);
    defer server.deinit();
    const control = @import("control.zig");
    var catalog: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer catalog.deinit();
    try control.writeCatalog(&catalog.writer);
    try server.updateCatalog(catalog.written());
    const fd = try testConnect(&server);
    defer _ = c.close(fd);
    try testSend(fd, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ test_meta ++ "}}\n");
    const reply = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(reply);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, reply, .{});
    defer parsed.deinit();
    const tools = field(field(parsed.value, "result"), "tools").array.items;
    try std.testing.expectEqual(control.actions.len + 2, tools.len);
    try std.testing.expectEqualStrings("reload-config", field(tools[tools.len - 1], "name").string);
}

test "MCP server coalesced integer and string IDs, call completion and failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = try testServer(&tmp);
    defer server.deinit();
    try std.testing.expect(server.descriptor() >= 0);
    const fd = try testConnect(&server);
    defer _ = c.close(fd);
    const requests =
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{" ++ test_meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":\"two\",\"method\":\"server/discover\",\"params\":{" ++ test_meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/list\",\"params\":{" ++ test_meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/list\",\"params\":{" ++ test_meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/list\",\"params\":{" ++ test_meta ++ "}}\n" ++
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{" ++ test_meta ++ ",\"name\":\"echo\",\"arguments\":{\"x\":1}}}\n";
    try testSend(fd, requests[0..37]);
    try server.dispatch();
    try testSend(fd, requests[37..]);
    const first = try testReceive(&server, fd, 5);
    defer std.testing.allocator.free(first);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"id\":1,\"result\":{\"tools\":[]}") != null);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"id\":\"two\"") != null);
    try std.testing.expect(server.hasCalls());
    const call = server.peekCall().?;
    try std.testing.expectEqualStrings("echo", call.name);
    try std.testing.expectEqual(@as(i64, 1), field(call.arguments, "x").integer);
    try server.completeCall("{\"content\":[]}");
    const completed = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(completed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":6,\"result\":{\"content\":[]}}\n", completed);

    const call2 = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{" ++ test_meta ++ ",\"name\":\"bad\"}}\n";
    try testSend(fd, call2);
    try server.dispatch();
    try std.testing.expectEqual(@as(usize, 0), server.peekCall().?.arguments.object.count());
    try server.failCall(-32602, "bad args");
    const failed = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(failed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"bad args\"}}\n", failed);
}

test "MCP server invalid requests, subscriptions, catalog changes and cancellation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = try testServer(&tmp);
    defer server.deinit();
    const fd = try testConnect(&server);
    defer _ = c.close(fd);
    try testSend(fd, "not json\n{\"jsonrpc\":\"2.0\",\"method\":\"bogus\",\"params\":{}}\n");
    const invalid = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(invalid);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"Parse error\"}}\n", invalid);
    const listen = "{\"jsonrpc\":\"2.0\",\"id\":\"sub\",\"method\":\"subscriptions/listen\",\"params\":{" ++ test_meta ++ ",\"notifications\":{\"toolsListChanged\":true}}}\n";
    try testSend(fd, listen);
    const ack = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(ack);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/subscriptions/acknowledged\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"sub\"},\"notifications\":{\"toolsListChanged\":true}}}\n", ack);
    try server.updateCatalog("{\"tools\":[]}");
    try std.testing.expectEqual(@as(usize, 0), server.clients[0].?.output.items.len);
    try server.updateCatalog("{\"tools\":[{\"name\":\"x\"}]}");
    const changed = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(changed);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/subscriptionId\":\"sub\"}}}\n", changed);
    try testSend(fd, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":\"sub\"}}\n");
    try server.dispatch();
    try server.updateCatalog("{\"tools\":[]}");
    try std.testing.expectEqual(@as(usize, 0), server.clients[0].?.output.items.len);
    try server.stop();
    try std.testing.expect(server.stopping);
    var pollfd = [_]linux.pollfd{.{ .fd = server.descriptor(), .events = linux.POLL.IN, .revents = 0 }};
    try std.testing.expectEqual(@as(usize, 1), linux.poll(&pollfd, 1, 0));
    try server.dispatch();
}

test "MCP server frame boundary, oversized frame and socket collision" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = try testServer(&tmp);
    defer server.deinit();
    try std.testing.expectError(error.SocketPathExists, Server.init(std.testing.allocator, server.path[0 .. server.path.len - 1], "{}"));
    const fd = try testConnect(&server);
    var exact = try std.testing.allocator.alloc(u8, maximum_frame_size);
    defer std.testing.allocator.free(exact);
    @memset(exact, ' ');
    exact[0] = '{';
    exact[1] = '}';
    exact[maximum_frame_size - 1] = '\n';
    var exact_offset: usize = 0;
    while (exact_offset < exact.len) {
        const n = c.send(fd, exact[exact_offset..].ptr, @min(16 * 1024, exact.len - exact_offset), c.MSG_NOSIGNAL);
        if (n > 0) exact_offset += @intCast(n);
        try server.dispatch();
    }
    const reply = try testReceive(&server, fd, 1);
    defer std.testing.allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "\"code\":-32600") != null);
    _ = c.close(fd);
    try server.dispatch();
    const fd2 = try testConnect(&server);
    defer _ = c.close(fd2);
    const oversized = try std.testing.allocator.alloc(u8, maximum_frame_size + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    var offset: usize = 0;
    var attempts: usize = 0;
    while (offset < oversized.len and attempts < 1000) : (attempts += 1) {
        const n = c.send(fd2, oversized[offset..].ptr, @min(16 * 1024, oversized.len - offset), c.MSG_NOSIGNAL);
        if (n > 0) offset += @intCast(n);
        try server.dispatch();
        if (n < 0 and c.__errno_location().* != c.EAGAIN) break;
    }
    try std.testing.expect(attempts < 1000);
    try std.testing.expect(!server.hasCalls());
}

test "MCP server backpressure skips a stalled peer and disconnect discards queued calls" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var server = try testServer(&tmp);
    defer server.deinit();
    const stalled = try testConnect(&server);
    const responsive = try testConnect(&server);
    defer _ = c.close(responsive);
    var stat: c.struct_stat = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.lstat(server.path.ptr, &stat));
    try std.testing.expectEqual(@as(c.mode_t, 0o600), stat.st_mode & 0o777);
    const size: c_int = 1024;
    try std.testing.expectEqual(@as(c_int, 0), c.setsockopt(server.clients[0].?.fd, c.SOL_SOCKET, c.SO_SNDBUF, &size, @sizeOf(c_int)));
    const full = try std.testing.allocator.alloc(u8, maximum_output_size);
    defer std.testing.allocator.free(full);
    @memset(full, ' ');
    full[full.len - 1] = '\n';
    try server.queue(0, full);
    try std.testing.expectError(error.OutputBackpressure, server.queue(0, "\n"));
    const request_bytes = "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{" ++ test_meta ++ ",\"name\":\"focus-next\",\"arguments\":{}}}\n";
    try testSend(stalled, request_bytes);
    try testSend(responsive, request_bytes);
    for (0..4) |_| try server.dispatch();
    try std.testing.expectEqual(@as(usize, 2), server.call_count);
    _ = server.peekCall() orelse return error.MissingCall;
    try std.testing.expectEqual(@as(usize, 1), server.calls[0].?.client);
    try server.completeCall("{\"content\":[]}");
    const response = try testReceive(&server, responsive, 1);
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":17,\"result\":{\"content\":[]}}\n", response);
    try std.testing.expect(!server.hasCalls());
    const old_generation = server.clients[0].?.generation;
    _ = c.close(stalled);
    for (0..4) |_| try server.dispatch();
    try std.testing.expectEqual(@as(usize, 0), server.call_count);
    const replacement = try testConnect(&server);
    defer _ = c.close(replacement);
    try std.testing.expect(server.clients[0].?.generation != old_generation);
    try testSend(replacement, request_bytes);
    try server.dispatch();
    _ = server.peekCall() orelse return error.MissingCall;
    try server.failCall(-32602, "rejected");
    const rejected = try testReceive(&server, replacement, 1);
    defer std.testing.allocator.free(rejected);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":17,\"error\":{\"code\":-32602,\"message\":\"rejected\"}}\n", rejected);
}
