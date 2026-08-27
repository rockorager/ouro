//! Bounded ext-foreign-toplevel-list-v1 protocol ownership.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
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
        if (c.metadata_capacity > wayring.wire.max_message_len - 16 or
            c.handle_capacity < c.list_capacity or c.outbound_capacity < 2)
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
        const ListSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, stopped: bool = false, finished_queued: bool = false };
        const Top = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, serial: u64 = 0, title_len: usize = 0, app_len: usize = 0 };
        const HSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, list: u32 = 0, top: ToplevelId = undefined, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null, closed: bool = false };
        const Kind = enum { announce, identifier, title, app_id, done, closed, finished };
        const Out = struct { active: bool = false, sequence: u64 = 0, kind: Kind = .done, owner: u32 = 0, text_len: usize = 0 };

        allocator: std.mem.Allocator,
        lists: []ListSlot,
        tops: []Top,
        handles: []HSlot,
        outbound: []Out,
        top_title: []u8,
        top_app: []u8,
        out_text: []u8,
        metadata_capacity: usize,
        list_free: u32 = 0,
        top_free: u32 = 0,
        handle_free: u32 = 0,
        outbound_count: usize = 0,
        sequence: u64 = 1,
        serial: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            try List.info.validateVersion(1);
            const lists = try allocator.alloc(ListSlot, c.list_capacity);
            errdefer allocator.free(lists);
            const tops = try allocator.alloc(Top, c.toplevel_capacity);
            errdefer allocator.free(tops);
            const handles = try allocator.alloc(HSlot, c.handle_capacity);
            errdefer allocator.free(handles);
            const outbound = try allocator.alloc(Out, c.outbound_capacity);
            errdefer allocator.free(outbound);
            const top_metadata_bytes = std.math.mul(
                usize,
                c.toplevel_capacity,
                c.metadata_capacity,
            ) catch return error.InvalidConfig;
            const outbound_metadata_bytes = std.math.mul(
                usize,
                c.outbound_capacity,
                c.metadata_capacity,
            ) catch return error.InvalidConfig;
            const top_title = try allocator.alloc(u8, top_metadata_bytes);
            errdefer allocator.free(top_title);
            const top_app = try allocator.alloc(u8, top_metadata_bytes);
            errdefer allocator.free(top_app);
            const out_text = try allocator.alloc(u8, outbound_metadata_bytes);
            errdefer allocator.free(out_text);
            initFree(ListSlot, lists);
            initFree(Top, tops);
            initFree(HSlot, handles);
            @memset(outbound, .{});
            return .{ .allocator = allocator, .lists = lists, .tops = tops, .handles = handles, .outbound = outbound, .top_title = top_title, .top_app = top_app, .out_text = out_text, .metadata_capacity = c.metadata_capacity };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.out_text);
            self.allocator.free(self.top_app);
            self.allocator.free(self.top_title);
            self.allocator.free(self.outbound);
            self.allocator.free(self.handles);
            self.allocator.free(self.tops);
            self.allocator.free(self.lists);
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
            var needed_h: usize = 0;
            var needed_o: usize = 0;
            for (self.tops) |t| if (t.active) {
                needed_h += 1;
                needed_o += 3 + @as(usize, @intFromBool(t.title_len != 0)) +
                    @as(usize, @intFromBool(t.app_len != 0));
            };
            if (self.list_free == none or freeCount(HSlot, self.handles) < needed_h or self.outbound.len - self.outbound_count < needed_o) return error.OutOfMemory;
            const li = self.list_free;
            self.list_free = self.lists[li].next_free;
            const gen = self.lists[li].generation;
            self.lists[li] = .{ .active = true, .generation = gen, .peer = binding.peer, .resource = binding.resource };
            for (self.tops, 0..) |t, i| if (t.active) self.makeHandle(li, .{ .index = @intCast(i), .generation = t.generation }) catch unreachable;
            return &self.lists[li];
        }

        pub fn publish(self: *Self, title: ?[]const u8, app_id: ?[]const u8) !ToplevelId {
            try self.validText(title);
            try self.validText(app_id);
            var lists: usize = 0;
            for (self.lists) |l| if (l.active and !l.stopped) {
                lists += 1;
            };
            const per: usize = 3 + @as(usize, @intFromBool(title != null and title.?.len != 0)) + @as(usize, @intFromBool(app_id != null and app_id.?.len != 0));
            if (self.serial == 0) return error.IdentifierExhausted;
            if (self.top_free == none or freeCount(HSlot, self.handles) < lists or self.outbound.len - self.outbound_count < lists * per) return error.Exhausted;
            const i = self.top_free;
            const gen = self.tops[i].generation;
            self.top_free = self.tops[i].next_free;
            self.tops[i] = .{ .active = true, .generation = gen, .serial = self.serial };
            self.serial +%= 1;
            const id: ToplevelId = .{ .index = i, .generation = gen };
            if (title) |v| {
                @memcpy(self.topText(self.top_title, i)[0..v.len], v);
                self.tops[i].title_len = v.len;
            }
            if (app_id) |v| {
                @memcpy(self.topText(self.top_app, i)[0..v.len], v);
                self.tops[i].app_len = v.len;
            }
            for (self.lists, 0..) |l, li| if (l.active and !l.stopped) self.makeHandle(@intCast(li), id) catch unreachable;
            return id;
        }
        pub fn updateTitle(self: *Self, id: ToplevelId, value: []const u8) !void {
            try self.update(id, value, .title);
        }
        pub fn updateAppId(self: *Self, id: ToplevelId, value: []const u8) !void {
            try self.update(id, value, .app_id);
        }
        fn update(self: *Self, id: ToplevelId, value: []const u8, kind: Kind) !void {
            try self.validText(value);
            const t = try self.resolveTop(id);
            var n: usize = 0;
            for (self.handles) |h| {
                if (h.active and !h.closed and std.meta.eql(h.top, id)) n += 1;
            }
            if (self.outbound.len - self.outbound_count < n * 2) return error.Exhausted;
            const dst = if (kind == .title) self.topText(self.top_title, id.index) else self.topText(self.top_app, id.index);
            @memcpy(dst[0..value.len], value);
            if (kind == .title) t.title_len = value.len else t.app_len = value.len;
            for (self.handles, 0..) |h, hi| if (h.active and !h.closed and std.meta.eql(h.top, id)) {
                self.enqueue(kind, @intCast(hi), value) catch unreachable;
                self.enqueue(.done, @intCast(hi), "") catch unreachable;
            };
        }
        pub fn close(self: *Self, id: ToplevelId) !void {
            _ = try self.resolveTop(id);
            var n: usize = 0;
            for (self.handles) |h| {
                if (h.active and !h.closed and std.meta.eql(h.top, id)) n += 1;
            }
            if (self.outbound.len - self.outbound_count < n) return error.Exhausted;
            for (self.handles, 0..) |*h, hi| if (h.active and !h.closed and std.meta.eql(h.top, id)) {
                h.closed = true;
                self.enqueue(.closed, @intCast(hi), "") catch unreachable;
            };
            self.releaseTop(id.index);
        }
        pub const unpublish = close;
        pub fn stop(self: *Self, list_index: u32) !void {
            const l = if (list_index < self.lists.len and self.lists[list_index].active) &self.lists[list_index] else return error.StaleList;
            if (l.finished_queued) return;
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            l.stopped = true;
            l.finished_queued = true;
            try self.enqueue(.finished, list_index, "");
        }

        fn makeHandle(self: *Self, li: u32, id: ToplevelId) !void {
            const hi = self.handle_free;
            if (hi == none) return error.Exhausted;
            const g = self.handles[hi].generation;
            self.handle_free = self.handles[hi].next_free;
            const l = self.lists[li];
            self.handles[hi] = .{ .active = true, .generation = g, .list = li, .top = id, .peer = l.peer };
            const t = try self.resolveTop(id);
            try self.enqueue(.announce, hi, "");
            var buf: [32]u8 = undefined;
            const ident = try std.fmt.bufPrint(&buf, "ouro-{x}", .{t.serial});
            try self.enqueue(.identifier, hi, ident);
            if (t.title_len != 0) try self.enqueue(.title, hi, self.topText(self.top_title, id.index)[0..t.title_len]);
            if (t.app_len != 0) try self.enqueue(.app_id, hi, self.topText(self.top_app, id.index)[0..t.app_len]);
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
                const l = from(ListSlot, self.lists, target.object.context) orelse return null;
                if (!std.meta.eql(l.resource, rh) or !samePeer(l.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(List, server_objects, message, fds);
                switch (d.value) {
                    .stop => self.stop(indexOf(ListSlot, self.lists, l)) catch |e| return try self.failure(actor, d.handle.id, e),
                    .destroy => {},
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Handle.info) {
                const h = from(HSlot, self.handles, target.object.context) orelse return null;
                if (h.resource == null or !std.meta.eql(h.resource.?, rh) or !samePeer(h.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Handle, server_objects, message, fds);
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active) {
                if (o.kind == .finished) {
                    if (samePeer(self.lists[o.owner].peer, peer)) return true;
                } else if (samePeer(self.handles[o.owner].peer, peer)) return true;
            };
            return false;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            while (self.oldest(peer)) |o| {
                const oi = indexOf(Out, self.outbound, o);
                if (o.kind == .finished) {
                    const l = &self.lists[o.owner];
                    if (server_objects.namespace.resolve(l.resource) != null) List.encodeEvent(queue, l.resource.id, .{ .finished = .{} }) catch |e| switch (e) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return e,
                    };
                } else {
                    const h = &self.handles[o.owner];
                    if (!h.active) {
                        self.dropOut(o);
                        continue;
                    }
                    if (o.kind == .announce) {
                        const l = &self.lists[h.list];
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
                const h = from(HSlot, self.handles, object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseHandle(indexOf(HSlot, self.handles, h));
                return true;
            }
            if (object.interface == &List.info) {
                const l = from(ListSlot, self.lists, object.context) orelse return false;
                if (!std.meta.eql(l.resource, handle)) return false;
                self.releaseList(indexOf(ListSlot, self.lists, l));
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.handles, 0..) |h, i| if (h.active and samePeer(h.peer, peer)) self.releaseHandle(@intCast(i));
            for (self.lists, 0..) |l, i| if (l.active and samePeer(l.peer, peer)) self.releaseList(@intCast(i));
        }

        fn validText(self: *const Self, v: ?[]const u8) !void {
            if (v) |s| if (s.len > self.metadata_capacity or std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidMetadata;
        }
        fn resolveTop(self: *Self, id: ToplevelId) !*Top {
            if (id.index >= self.tops.len or !self.tops[id.index].active or self.tops[id.index].generation != id.generation) return error.StaleToplevel;
            return &self.tops[id.index];
        }
        fn releaseTop(self: *Self, i: u32) void {
            const g = nextGeneration(self.tops[i].generation);
            self.tops[i] = .{ .generation = g, .next_free = self.top_free };
            self.top_free = i;
        }
        fn releaseHandle(self: *Self, i: u32) void {
            for (self.outbound) |*o| if (o.active and o.kind != .finished and o.owner == i) self.dropOut(o);
            const g = nextGeneration(self.handles[i].generation);
            self.handles[i] = .{ .generation = g, .next_free = self.handle_free };
            self.handle_free = i;
        }
        fn releaseList(self: *Self, i: u32) void {
            for (self.handles, 0..) |h, hi| if (h.active and h.list == i and h.resource == null) self.releaseHandle(@intCast(hi));
            for (self.outbound) |*o| if (o.active and o.kind == .finished and o.owner == i) self.dropOut(o);
            const g = nextGeneration(self.lists[i].generation);
            self.lists[i] = .{ .generation = g, .next_free = self.list_free };
            self.list_free = i;
        }
        fn dropOut(self: *Self, o: *Out) void {
            if (o.active) {
                o.active = false;
                self.outbound_count -= 1;
            }
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Out {
            var best: ?*Out = null;
            for (self.outbound) |*o| if (o.active and ((o.kind == .finished and samePeer(self.lists[o.owner].peer, peer)) or (o.kind != .finished and self.handles[o.owner].active and samePeer(self.handles[o.owner].peer, peer))) and (best == null or o.sequence < best.?.sequence)) {
                best = o;
            };
            return best;
        }
        fn topText(self: *Self, data: []u8, i: u32) []u8 {
            return data[@as(usize, i) * self.metadata_capacity ..][0..self.metadata_capacity];
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

fn initFree(comptime T: type, s: []T) void {
    for (s, 0..) |*v, i| v.* = .{ .next_free = if (i + 1 < s.len) @intCast(i + 1) else none };
}
fn freeCount(comptime T: type, s: []const T) usize {
    var n: usize = 0;
    for (s) |v| if (!v.active) {
        n += 1;
    };
    return n;
}
fn indexOf(comptime T: type, s: []const T, p: *const T) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(s.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, s: []T, c: ?*anyopaque) ?*T {
    const p = c orelse return null;
    const a = @intFromPtr(p);
    const b = @intFromPtr(s.ptr);
    if (a < b or a >= b + s.len * @sizeOf(T) or (a - b) % @sizeOf(T) != 0) return null;
    const v = &s[(a - b) / @sizeOf(T)];
    return if (v.active) v else null;
}
fn nextGeneration(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "foreign toplevel: identifiers, metadata, generations and atomic capacity" {
    const A = Adapter(@import("core_protocol"));
    var a = try A.init(std.testing.allocator, .{ .list_capacity = 1, .toplevel_capacity = 1, .handle_capacity = 1, .outbound_capacity = 6, .metadata_capacity = 32 });
    defer a.deinit();
    const id = try a.publish("title", "app");
    try std.testing.expectError(error.Exhausted, a.publish(null, null));
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
    try std.testing.expect(adapter.lists[0].stopped);
    try std.testing.expect(adapter.lists[0].finished_queued);
    try adapter.stop(0);
    try std.testing.expectEqual(@as(usize, 1), adapter.outbound_count);
    _ = try adapter.publish("ignored", null);
    try std.testing.expectEqual(@as(usize, 1), freeCount(A.HSlot, adapter.handles));
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
        adapter.topText(adapter.top_title, id.index)[0..adapter.tops[id.index].title_len],
    );
    try std.testing.expectError(error.Exhausted, adapter.stop(0));
    try std.testing.expect(!adapter.lists[0].stopped);

    for (adapter.outbound) |*event| adapter.dropOut(event);
    adapter.handles[0].resource = .{ .id = 8, .generation = 3 };
    adapter.releaseList(0);
    try std.testing.expect(adapter.handles[0].active);
    try adapter.updateTitle(id, "new");
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    adapter.disconnected(peer);
    try std.testing.expect(!adapter.handles[0].active);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
}
