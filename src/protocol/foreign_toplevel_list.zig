//! Bounded ext-foreign-toplevel-list-v1 protocol ownership.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    list_capacity: usize = 8,
    toplevel_capacity: usize = 64,
    handle_capacity: usize = 256,
    outbound_capacity: usize = 1024,
    metadata_capacity: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.list_capacity, c.toplevel_capacity, c.handle_capacity, c.outbound_capacity, c.metadata_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.metadata_capacity > wayring.wire.max_message_len - 16 or c.outbound_capacity < 2)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const List = protocol.ext_foreign_toplevel_list_v1;
        const Handle = protocol.ext_foreign_toplevel_handle_v1;
        pub const ToplevelId = packed struct { index: u32, generation: u32 };
        const ListSlot = struct { header: slot_pool.Header = .{}, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, stopped: bool = false, finished_queued: bool = false };
        const Top = struct { header: slot_pool.Header = .{}, serial: u64 = 0, title_len: usize = 0, app_len: usize = 0, title: []u8 = &.{}, app: []u8 = &.{} };
        const HSlot = struct { header: slot_pool.Header = .{}, list: u32 = 0, top: ToplevelId = undefined, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null, closed: bool = false };
        const Kind = enum { announce, identifier, title, app_id, done, closed, finished };
        const Out = struct { active: bool = false, sequence: u64 = 0, kind: Kind = .done, owner: u32 = 0, text_len: usize = 0 };

        allocator: std.mem.Allocator,
        lists: slot_pool.Pool(ListSlot),
        tops: slot_pool.Pool(Top),
        handles: slot_pool.Pool(HSlot),
        outbound: []Out,
        out_text: []u8,
        metadata_capacity: usize,
        outbound_count: usize = 0,
        sequence: u64 = 1,
        serial: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            try List.info.validateVersion(1);
            var lists = try slot_pool.Pool(ListSlot).init(allocator, c.list_capacity);
            errdefer lists.deinit();
            var tops = try slot_pool.Pool(Top).init(allocator, c.toplevel_capacity);
            errdefer tops.deinit();
            var handles = try slot_pool.Pool(HSlot).init(allocator, c.handle_capacity);
            errdefer handles.deinit();
            const outbound = try allocator.alloc(Out, c.outbound_capacity);
            errdefer allocator.free(outbound);
            const outbound_metadata_bytes = std.math.mul(
                usize,
                c.outbound_capacity,
                c.metadata_capacity,
            ) catch return error.InvalidConfig;
            const out_text = try allocator.alloc(u8, outbound_metadata_bytes);
            errdefer allocator.free(out_text);
            @memset(outbound, .{});
            return .{ .allocator = allocator, .lists = lists, .tops = tops, .handles = handles, .outbound = outbound, .out_text = out_text, .metadata_capacity = c.metadata_capacity };
        }
        pub fn deinit(self: *Self) void {
            for (self.tops.entries.items) |top| {
                if (top.title.len != 0) self.allocator.free(top.title);
                if (top.app.len != 0) self.allocator.free(top.app);
            }
            self.allocator.free(self.out_text);
            self.allocator.free(self.outbound);
            self.handles.deinit();
            self.tops.deinit();
            self.lists.deinit();
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&List.info, 1, self, bind);
            return self.global.?;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            var needed_o: usize = 0;
            for (self.tops.entries.items) |t| if (t.header.active) {
                needed_o += 3 + @as(usize, @intFromBool(t.title_len != 0)) +
                    @as(usize, @intFromBool(t.app_len != 0));
            };
            if (self.outbound.len - self.outbound_count < needed_o) return error.OutOfMemory;
            const list = try self.lists.acquire();
            errdefer self.releaseList(list.header.index);
            list.peer = binding.peer;
            list.resource = binding.resource;
            for (self.tops.entries.items) |t| if (t.header.active) try self.makeHandle(list.header.index, .{ .index = t.header.index, .generation = t.header.generation });
            return list;
        }

        pub fn publish(self: *Self, title: ?[]const u8, app_id: ?[]const u8) !ToplevelId {
            try self.validText(title);
            try self.validText(app_id);
            var lists: usize = 0;
            for (self.lists.entries.items) |l| if (l.header.active and !l.stopped) {
                lists += 1;
            };
            const per: usize = 3 + @as(usize, @intFromBool(title != null and title.?.len != 0)) + @as(usize, @intFromBool(app_id != null and app_id.?.len != 0));
            if (self.serial == 0) return error.IdentifierExhausted;
            if (self.outbound.len - self.outbound_count < lists * per) return error.Exhausted;
            const top = try self.tops.acquire();
            errdefer self.releaseTop(top.header.index);
            top.title = try self.allocator.alloc(u8, self.metadata_capacity);
            top.app = try self.allocator.alloc(u8, self.metadata_capacity);
            const i = top.header.index;
            const gen = top.header.generation;
            top.serial = self.serial;
            self.serial +%= 1;
            const id: ToplevelId = .{ .index = i, .generation = gen };
            errdefer for (self.handles.entries.items) |h| if (h.header.active and std.meta.eql(h.top, id)) self.releaseHandle(h.header.index);
            if (title) |v| {
                @memcpy(top.title[0..v.len], v);
                top.title_len = v.len;
            }
            if (app_id) |v| {
                @memcpy(top.app[0..v.len], v);
                top.app_len = v.len;
            }
            for (self.lists.entries.items) |l| if (l.header.active and !l.stopped) try self.makeHandle(l.header.index, id);
            return id;
        }
        pub fn updateTitle(self: *Self, id: ToplevelId, value: []const u8) !void {
            try self.update(id, value, .title);
        }
        pub fn updateAppId(self: *Self, id: ToplevelId, value: []const u8) !void {
            try self.update(id, value, .app_id);
        }
        pub const Metadata = struct {
            title: []const u8,
            app_id: []const u8,
        };
        pub fn metadata(self: *Self, id: ToplevelId) !Metadata {
            const top = try self.resolveTop(id);
            return .{
                .title = top.title[0..top.title_len],
                .app_id = top.app[0..top.app_len],
            };
        }
        pub fn toplevelForResource(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            object_id: u32,
        ) ?ToplevelId {
            const resource = server_objects.namespace.lookupHandle(object_id) orelse return null;
            const object = server_objects.namespace.resolve(resource) orelse return null;
            if (object.interface != &Handle.info) return null;
            const handle = self.handles.fromContext(object.context) orelse return null;
            if (handle.closed or handle.resource == null or
                !std.meta.eql(handle.resource.?, resource) or !samePeer(handle.peer, peer)) return null;
            return handle.top;
        }
        fn update(self: *Self, id: ToplevelId, value: []const u8, kind: Kind) !void {
            try self.validText(value);
            const t = try self.resolveTop(id);
            var n: usize = 0;
            for (self.handles.entries.items) |h| {
                if (h.header.active and !h.closed and std.meta.eql(h.top, id)) n += 1;
            }
            if (self.outbound.len - self.outbound_count < n * 2) return error.Exhausted;
            const dst = if (kind == .title) t.title else t.app;
            @memcpy(dst[0..value.len], value);
            if (kind == .title) t.title_len = value.len else t.app_len = value.len;
            for (self.handles.entries.items) |h| if (h.header.active and !h.closed and std.meta.eql(h.top, id)) {
                self.enqueue(kind, h.header.index, value) catch unreachable;
                self.enqueue(.done, h.header.index, "") catch unreachable;
            };
        }
        pub fn close(self: *Self, id: ToplevelId) !void {
            _ = try self.resolveTop(id);
            var n: usize = 0;
            for (self.handles.entries.items) |h| {
                if (h.header.active and !h.closed and std.meta.eql(h.top, id)) n += 1;
            }
            if (self.outbound.len - self.outbound_count < n) return error.Exhausted;
            for (self.handles.entries.items) |h| if (h.header.active and !h.closed and std.meta.eql(h.top, id)) {
                h.closed = true;
                self.enqueue(.closed, h.header.index, "") catch unreachable;
            };
            self.releaseTop(id.index);
        }
        pub const unpublish = close;
        pub fn stop(self: *Self, list_index: u32) !void {
            const l = self.lists.at(list_index) orelse return error.StaleList;
            if (l.finished_queued) return;
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            l.stopped = true;
            l.finished_queued = true;
            try self.enqueue(.finished, list_index, "");
        }

        fn makeHandle(self: *Self, li: u32, id: ToplevelId) !void {
            const h = try self.handles.acquire();
            errdefer self.releaseHandle(h.header.index);
            const hi = h.header.index;
            const l = self.lists.at(li) orelse return error.StaleList;
            h.list = li;
            h.top = id;
            h.peer = l.peer;
            const t = try self.resolveTop(id);
            try self.enqueue(.announce, hi, "");
            var buf: [32]u8 = undefined;
            const ident = try std.fmt.bufPrint(&buf, "ouro-{x}", .{t.serial});
            try self.enqueue(.identifier, hi, ident);
            if (t.title_len != 0) try self.enqueue(.title, hi, t.title[0..t.title_len]);
            if (t.app_len != 0) try self.enqueue(.app_id, hi, t.app[0..t.app_len]);
            try self.enqueue(.done, hi, "");
        }
        fn enqueue(self: *Self, kind: Kind, owner: u32, text: []const u8) !void {
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            for (self.outbound, 0..) |*o, i| if (!o.active) {
                o.* = .{ .active = true, .sequence = self.sequence, .kind = kind, .owner = owner, .text_len = text.len };
                @memcpy(self.outText(@intCast(i))[0..text.len], text);
                self.sequence +%= 1;
                self.outbound_count += 1;
                return;
            };
            unreachable;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try r.clients.reactor.getActor(peer), try r.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const rh = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &List.info) {
                const l = self.lists.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(l.resource, rh) or !samePeer(l.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(List, server_objects, message, fds);
                switch (d.value) {
                    .stop => self.stop(l.header.index) catch |e| return try self.failure(actor, d.handle.id, e),
                    .destroy => {},
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Handle.info) {
                const h = self.handles.fromContext(target.object.context) orelse return null;
                if (h.resource == null or !std.meta.eql(h.resource.?, rh) or !samePeer(h.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Handle, server_objects, message, fds);
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.outbound_count == 0) return false;
            for (self.outbound) |o| if (o.active) {
                if (o.kind == .finished) {
                    if (o.owner < self.lists.entries.items.len) {
                        const l = self.lists.entries.items[o.owner];
                        if (l.header.active and samePeer(l.peer, peer)) return true;
                    }
                } else if (o.owner < self.handles.entries.items.len) {
                    const h = self.handles.entries.items[o.owner];
                    if (h.header.active and samePeer(h.peer, peer)) return true;
                }
            };
            return false;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            while (self.oldest(peer)) |o| {
                const oi = indexOf(Out, self.outbound, o);
                if (o.kind == .finished) {
                    const l = self.lists.at(o.owner) orelse {
                        self.dropOut(o);
                        continue;
                    };
                    if (server_objects.namespace.resolve(l.resource) != null) List.encodeEvent(queue, l.resource.id, .{ .finished = .{} }) catch |e| switch (e) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return e,
                    };
                } else {
                    const h = self.handles.at(o.owner) orelse {
                        self.dropOut(o);
                        continue;
                    };
                    if (o.kind == .announce) {
                        const l = self.lists.at(h.list) orelse {
                            self.dropOut(o);
                            continue;
                        };
                        const made = List.construct_event_toplevel(protocol, server_objects, queue, l.resource, .{ .toplevel = .{ .context = h } }) catch |e| switch (e) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return e,
                        };
                        h.resource = made.toplevel;
                    } else if (h.resource != null and server_objects.namespace.resolve(h.resource.?) != null) {
                        const text = self.outText(oi)[0..o.text_len];
                        const ev: Handle.Event = switch (o.kind) {
                            .identifier => .{ .identifier = .{ .identifier = text } },
                            .title => .{ .title = .{ .title = text } },
                            .app_id => .{ .app_id = .{ .app_id = text } },
                            .done => .{ .done = .{} },
                            .closed => .{ .closed = .{} },
                            else => unreachable,
                        };
                        Handle.encodeEvent(queue, h.resource.?.id, ev) catch |e| switch (e) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return e,
                        };
                    }
                }
                self.dropOut(o);
                count += 1;
            }
            return count;
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Handle.info) {
                const h = self.handles.fromContext(object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseHandle(h.header.index);
                return true;
            }
            if (object.interface == &List.info) {
                const l = self.lists.fromContext(object.context) orelse return false;
                if (!std.meta.eql(l.resource, handle)) return false;
                self.releaseList(l.header.index);
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.handles.entries.items) |h| if (h.header.active and samePeer(h.peer, peer)) self.releaseHandle(h.header.index);
            for (self.lists.entries.items) |l| if (l.header.active and samePeer(l.peer, peer)) self.releaseList(l.header.index);
        }

        fn validText(self: *const Self, v: ?[]const u8) !void {
            if (v) |s| if (s.len > self.metadata_capacity or std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidMetadata;
        }
        fn resolveTop(self: *Self, id: ToplevelId) !*Top {
            const top = self.tops.at(id.index) orelse return error.StaleToplevel;
            if (top.header.generation != id.generation) return error.StaleToplevel;
            return top;
        }
        fn releaseTop(self: *Self, i: u32) void {
            const top = self.tops.at(i) orelse return;
            if (top.title.len != 0) self.allocator.free(top.title);
            if (top.app.len != 0) self.allocator.free(top.app);
            self.tops.release(top);
        }
        fn releaseHandle(self: *Self, i: u32) void {
            for (self.outbound) |*o| if (o.active and o.kind != .finished and o.owner == i) self.dropOut(o);
            if (self.handles.at(i)) |handle| self.handles.release(handle);
        }
        fn releaseList(self: *Self, i: u32) void {
            for (self.handles.entries.items) |h| if (h.header.active and h.list == i and h.resource == null) self.releaseHandle(h.header.index);
            for (self.outbound) |*o| if (o.active and o.kind == .finished and o.owner == i) self.dropOut(o);
            if (self.lists.at(i)) |list| self.lists.release(list);
        }
        fn dropOut(self: *Self, o: *Out) void {
            if (o.active) {
                o.active = false;
                self.outbound_count -= 1;
            }
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Out {
            var best: ?*Out = null;
            for (self.outbound) |*o| if (o.active and ((o.kind == .finished and self.lists.at(o.owner) != null and samePeer(self.lists.at(o.owner).?.peer, peer)) or (o.kind != .finished and self.handles.at(o.owner) != null and samePeer(self.handles.at(o.owner).?.peer, peer))) and (best == null or o.sequence < best.?.sequence)) {
                best = o;
            };
            return best;
        }
        fn outText(self: *Self, i: u32) []u8 {
            return self.out_text[@as(usize, i) * self.metadata_capacity ..][0..self.metadata_capacity];
        }
        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, e: anyerror) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, @errorName(e));
            return .stop;
        }
    };
}

fn indexOf(comptime T: type, s: []const T, p: *const T) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(s.ptr)) / @sizeOf(T));
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "foreign toplevel: identifiers, metadata, generations and growable ownership" {
    const A = Adapter(@import("core_protocol"));
    var a = try A.init(std.testing.allocator, .{ .list_capacity = 1, .toplevel_capacity = 1, .handle_capacity = 1, .outbound_capacity = 6, .metadata_capacity = 32 });
    defer a.deinit();
    const id = try a.publish("title", "app");
    const grown = try a.publish(null, null);
    try std.testing.expectEqual(@as(u32, 1), grown.index);
    try std.testing.expect((try a.metadata(id)).title.ptr == a.tops.entries.items[0].title.ptr);
    try a.close(id);
    try std.testing.expectError(error.StaleToplevel, a.updateTitle(id, "x"));
    const next = try a.publish(null, null);
    try std.testing.expect(next.generation != id.generation);
    try std.testing.expectError(error.InvalidMetadata, a.updateTitle(next, "abcdefghijklmnopqrstuvwxyz1234567"));
}

test "foreign toplevel: bind retains ordered initial state and stop is atomic" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 2,
        .handle_capacity = 2,
        .outbound_capacity = 8,
        .metadata_capacity = 32,
    });
    defer adapter.deinit();
    const first = try adapter.publish("terminal", "org.example.Terminal");
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 7 };
    _ = try A.bind(&adapter, .{
        .peer = peer,
        .credentials = .{ .pid = 1, .uid = 2, .gid = 3 },
        .global = .{ .id = 4, .generation = 1 },
        .resource = .{ .id = 5, .generation = 2 },
        .version = 1,
    });
    try std.testing.expectEqual(@as(usize, 5), adapter.outbound_count);
    const expected = [_]A.Kind{ .announce, .identifier, .title, .app_id, .done };
    for (expected) |kind| {
        const event = adapter.oldest(peer).?;
        try std.testing.expectEqual(kind, event.kind);
        if (kind == .identifier) {
            const index = indexOf(A.Out, adapter.outbound, event);
            try std.testing.expectEqualStrings(
                "ouro-1",
                adapter.outText(index)[0..event.text_len],
            );
        }
        adapter.dropOut(event);
    }
    try adapter.stop(0);
    try std.testing.expect(adapter.lists.entries.items[0].stopped);
    try std.testing.expect(adapter.lists.entries.items[0].finished_queued);
    try adapter.stop(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.outbound_count);
    _ = try adapter.publish("ignored", null);
    try std.testing.expectEqual(@as(usize, 1), adapter.handles.entries.items.len);
    try adapter.close(first);
}

test "foreign toplevel: update backpressure preserves metadata and list removal preserves live handles" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 1,
        .handle_capacity = 1,
        .outbound_capacity = 5,
        .metadata_capacity = 16,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 9, .generation = 4 };
    _ = try A.bind(&adapter, .{
        .peer = peer,
        .credentials = .{ .pid = 1, .uid = 2, .gid = 3 },
        .global = .{ .id = 4, .generation = 1 },
        .resource = .{ .id = 6, .generation = 2 },
        .version = 1,
    });
    const id = try adapter.publish("old", "app");
    try std.testing.expectError(error.Exhausted, adapter.updateTitle(id, "new"));
    try std.testing.expectEqualStrings(
        "old",
        adapter.tops.entries.items[id.index].title[0..adapter.tops.entries.items[id.index].title_len],
    );
    try std.testing.expectError(error.Exhausted, adapter.stop(0));
    try std.testing.expect(!adapter.lists.entries.items[0].stopped);

    for (adapter.outbound) |*event| adapter.dropOut(event);
    adapter.handles.entries.items[0].resource = .{ .id = 8, .generation = 3 };
    adapter.releaseList(0);
    try std.testing.expect(adapter.handles.entries.items[0].header.active);
    try adapter.updateTitle(id, "new");
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    adapter.disconnected(peer);
    try std.testing.expect(!adapter.handles.entries.items[0].header.active);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
}

test "foreign toplevel: lists and per-list handles grow beyond initial reservations" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 1,
        .handle_capacity = 1,
        .outbound_capacity = 32,
        .metadata_capacity = 16,
    });
    defer adapter.deinit();

    var first_context: ?*anyopaque = null;
    for (0..3) |i| {
        const context = try A.bind(&adapter, .{
            .peer = .{ .slot = @intCast(i + 1), .generation = 1 },
            .credentials = .{ .pid = 1, .uid = 2, .gid = 3 },
            .global = .{ .id = 4, .generation = 1 },
            .resource = .{ .id = @intCast(i + 5), .generation = 2 },
            .version = 1,
        });
        if (i == 0) first_context = context;
    }
    try std.testing.expect(@intFromPtr(first_context.?) == @intFromPtr(adapter.lists.entries.items[0]));

    const id = try adapter.publish("one", "app");
    const first_handle = adapter.handles.entries.items[0];
    _ = try adapter.publish("two", null);
    try std.testing.expectEqual(@as(usize, 6), adapter.handles.entries.items.len);
    try std.testing.expect(first_handle == adapter.handles.entries.items[0]);
    try std.testing.expect(adapter.handles.fromContext(first_handle) == first_handle);
    try adapter.close(id);
    try std.testing.expectError(error.StaleToplevel, adapter.metadata(id));
}
