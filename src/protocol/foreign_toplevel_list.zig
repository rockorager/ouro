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
    output_capacity: usize = 4,
    wlr_manager_capacity: usize = 8,
    wlr_handle_capacity: usize = 256,
    wlr_outbound_capacity: usize = 1024,
    command_capacity: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.list_capacity, c.toplevel_capacity, c.handle_capacity, c.outbound_capacity, c.metadata_capacity, c.output_capacity, c.wlr_manager_capacity, c.wlr_handle_capacity, c.wlr_outbound_capacity, c.command_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.metadata_capacity > wayring.wire.max_message_len - 16 or
            c.handle_capacity < c.list_capacity or c.wlr_handle_capacity < c.wlr_manager_capacity or
            c.outbound_capacity < 2 or c.wlr_outbound_capacity < 2)
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
        const WManager = protocol.zwlr_foreign_toplevel_manager_v1;
        const WHandle = protocol.zwlr_foreign_toplevel_handle_v1;
        pub const ToplevelId = packed struct { index: u32, generation: u32 };
        pub const OutputId = packed struct { value: u64 };
        pub const State = packed struct {
            maximized: bool = false,
            minimized: bool = false,
            activated: bool = false,
            fullscreen: bool = false,
        };
        const ListSlot = struct { header: slot_pool.Header = .{}, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, stopped: bool = false, finished_queued: bool = false };
        const Top = struct { header: slot_pool.Header = .{}, serial: u64 = 0, title_len: usize = 0, app_len: usize = 0, title: []u8 = &.{}, app: []u8 = &.{}, state: State = .{}, parent: ?ToplevelId = null, output_count: usize = 0 };
        const HSlot = struct { header: slot_pool.Header = .{}, list: u32 = 0, top: ToplevelId = undefined, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null, closed: bool = false };
        const Kind = enum { announce, identifier, title, app_id, done, closed, finished };
        const Out = struct { active: bool = false, sequence: u64 = 0, kind: Kind = .done, owner: u32 = 0, text_len: usize = 0 };
        const WManagerSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, version: u32 = 1, stopped: bool = false };
        const WHandleSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, manager: u32 = 0, top: ToplevelId = undefined, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null, closed: bool = false };
        const WKind = enum { announce, title, app_id, state, parent, output_enter, output_leave, done, closed, finished };
        const WOut = struct { active: bool = false, sequence: u64 = 0, kind: WKind = .done, owner: u32 = 0, text_len: usize = 0, output: OutputId = .{ .value = 0 }, state: State = .{}, parent: ?ToplevelId = null };
        pub const Command = struct {
            peer: wayring.io_uring.Peer,
            toplevel: ToplevelId,
            request: union(enum) {
                set_maximized,
                unset_maximized,
                set_minimized,
                unset_minimized,
                close,
                unset_fullscreen,
                activate: struct { seat: u32 },
                set_rectangle: struct { surface: u32, x: i32, y: i32, width: i32, height: i32 },
                set_fullscreen: struct { output: ?u32 },
            },
        };

        allocator: std.mem.Allocator,
        lists: slot_pool.Pool(ListSlot),
        tops: slot_pool.Pool(Top),
        handles: slot_pool.Pool(HSlot),
        outbound: []Out,
        wmanagers: []WManagerSlot,
        whandles: []WHandleSlot,
        woutbound: []WOut,
        commands: []Command,
        out_text: []u8,
        wout_text: []u8,
        top_outputs: []OutputId,
        metadata_capacity: usize,
        output_capacity: usize,
        outbound_count: usize = 0,
        wmanager_free: u32 = 0,
        whandle_free: u32 = 0,
        woutbound_count: usize = 0,
        command_head: usize = 0,
        command_count: usize = 0,
        sequence: u64 = 1,
        serial: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        wglobal: ?objects.Handle = null,
        output_resolver_context: ?*anyopaque = null,
        output_resolver: ?*const fn (?*anyopaque, wayring.io_uring.Peer, OutputId) ?u32 = null,

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
            const wmanagers = try allocator.alloc(WManagerSlot, c.wlr_manager_capacity);
            errdefer allocator.free(wmanagers);
            const whandles = try allocator.alloc(WHandleSlot, c.wlr_handle_capacity);
            errdefer allocator.free(whandles);
            const woutbound = try allocator.alloc(WOut, c.wlr_outbound_capacity);
            errdefer allocator.free(woutbound);
            const commands = try allocator.alloc(Command, c.command_capacity);
            errdefer allocator.free(commands);
            const outbound_metadata_bytes = std.math.mul(
                usize,
                c.outbound_capacity,
                c.metadata_capacity,
            ) catch return error.InvalidConfig;
            const woutbound_metadata_bytes = std.math.mul(
                usize,
                c.wlr_outbound_capacity,
                c.metadata_capacity,
            ) catch return error.InvalidConfig;
            const out_text = try allocator.alloc(u8, outbound_metadata_bytes);
            errdefer allocator.free(out_text);
            const wout_text = try allocator.alloc(u8, woutbound_metadata_bytes);
            errdefer allocator.free(wout_text);
            const output_count = std.math.mul(usize, c.toplevel_capacity, c.output_capacity) catch return error.InvalidConfig;
            const top_outputs = try allocator.alloc(OutputId, output_count);
            errdefer allocator.free(top_outputs);
            initFree(WManagerSlot, wmanagers);
            initFree(WHandleSlot, whandles);
            @memset(outbound, .{});
            @memset(woutbound, .{});
            return .{ .allocator = allocator, .lists = lists, .tops = tops, .handles = handles, .outbound = outbound, .wmanagers = wmanagers, .whandles = whandles, .woutbound = woutbound, .commands = commands, .out_text = out_text, .wout_text = wout_text, .top_outputs = top_outputs, .metadata_capacity = c.metadata_capacity, .output_capacity = c.output_capacity };
        }
        pub fn deinit(self: *Self) void {
            for (self.tops.entries.items) |top| {
                if (top.title.len != 0) self.allocator.free(top.title);
                if (top.app.len != 0) self.allocator.free(top.app);
            }
            self.allocator.free(self.top_outputs);
            self.allocator.free(self.wout_text);
            self.allocator.free(self.out_text);
            self.allocator.free(self.outbound);
            self.handles.deinit();
            self.tops.deinit();
            self.lists.deinit();
            self.allocator.free(self.commands);
            self.allocator.free(self.woutbound);
            self.allocator.free(self.whandles);
            self.allocator.free(self.wmanagers);
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&List.info, 1, self, bind);
            return self.global.?;
        }
        pub fn installWlr(self: *Self) !objects.Handle {
            const runtime = self.runtime orelse return error.NotInstalled;
            if (self.wglobal != null) return error.AlreadyInstalled;
            self.wglobal = try runtime.addGlobalWithBinder(&WManager.info, 3, self, bindWlr);
            return self.wglobal.?;
        }
        pub fn setOutputResolver(self: *Self, context: ?*anyopaque, resolver: ?*const fn (?*anyopaque, wayring.io_uring.Peer, OutputId) ?u32) void {
            self.output_resolver_context = context;
            self.output_resolver = resolver;
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
        fn bindWlr(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            var count: usize = 0;
            var events: usize = 0;
            for (self.tops.entries.items) |t| if (t.header.active) {
                count += 1;
                events += 5 + t.output_count + @as(usize, @intFromBool(binding.version >= 3));
            };
            if (self.wmanager_free == none or freeCount(WHandleSlot, self.whandles) < count or self.woutbound.len - self.woutbound_count < events) return error.OutOfMemory;
            const mi = self.wmanager_free;
            self.wmanager_free = self.wmanagers[mi].next_free;
            const generation = self.wmanagers[mi].generation;
            self.wmanagers[mi] = .{ .active = true, .generation = generation, .peer = binding.peer, .resource = binding.resource, .version = binding.version };
            for (self.tops.entries.items) |t| if (t.header.active)
                self.makeWHandle(mi, .{ .index = t.header.index, .generation = t.header.generation }) catch unreachable;
            return &self.wmanagers[mi];
        }

        pub fn publish(self: *Self, title: ?[]const u8, app_id: ?[]const u8) !ToplevelId {
            try self.validText(title);
            try self.validText(app_id);
            var lists: usize = 0;
            for (self.lists.entries.items) |l| if (l.header.active and !l.stopped) {
                lists += 1;
            };
            var wmanagers: usize = 0;
            var wevents: usize = 0;
            for (self.wmanagers) |m| if (m.active and !m.stopped) {
                wmanagers += 1;
                wevents += 5 + @as(usize, @intFromBool(m.version >= 3));
            };
            const per: usize = 3 + @as(usize, @intFromBool(title != null and title.?.len != 0)) + @as(usize, @intFromBool(app_id != null and app_id.?.len != 0));
            if (self.serial == 0) return error.IdentifierExhausted;
            if (self.outbound.len - self.outbound_count < lists * per or
                freeCount(WHandleSlot, self.whandles) < wmanagers or
                self.woutbound.len - self.woutbound_count < wevents) return error.Exhausted;
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
            for (self.wmanagers, 0..) |m, mi| if (m.active and !m.stopped) self.makeWHandle(@intCast(mi), id) catch unreachable;
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
        pub fn state(self: *Self, id: ToplevelId) !State {
            return (try self.resolveTop(id)).state;
        }
        pub fn updateState(self: *Self, id: ToplevelId, value: State) !bool {
            const top = try self.resolveTop(id);
            if (std.meta.eql(top.state, value)) return false;
            const n = self.wHandleCount(id);
            if (self.woutbound.len - self.woutbound_count < n * 2) return error.Exhausted;
            top.state = value;
            self.queueWUpdate(id, .state, null);
            return true;
        }
        pub fn parent(self: *Self, id: ToplevelId) !?ToplevelId {
            return (try self.resolveTop(id)).parent;
        }
        pub fn updateParent(self: *Self, id: ToplevelId, value: ?ToplevelId) !bool {
            const top = try self.resolveTop(id);
            if (value) |parent_id| {
                _ = try self.resolveTop(parent_id);
                if (std.meta.eql(id, parent_id)) return error.InvalidParent;
            }
            if (std.meta.eql(top.parent, value)) return false;
            const n = self.wHandleCount(id);
            if (self.woutbound.len - self.woutbound_count < n * 2) return error.Exhausted;
            top.parent = value;
            self.queueWUpdate(id, .parent, null);
            return true;
        }
        pub fn outputs(self: *Self, id: ToplevelId) ![]const OutputId {
            const top = try self.resolveTop(id);
            return self.topOutputs(id.index)[0..top.output_count];
        }
        pub fn addOutput(self: *Self, id: ToplevelId, output: OutputId) !bool {
            const top = try self.resolveTop(id);
            const values = self.topOutputs(id.index);
            for (values[0..top.output_count]) |value| if (std.meta.eql(value, output)) return false;
            if (top.output_count == values.len) return error.Exhausted;
            values[top.output_count] = output;
            top.output_count += 1;
            const n = self.wHandleCount(id);
            if (self.woutbound.len - self.woutbound_count < n * 2) {
                top.output_count -= 1;
                return error.Exhausted;
            }
            self.queueWUpdate(id, .output_enter, output);
            return true;
        }
        pub fn removeOutput(self: *Self, id: ToplevelId, output: OutputId) !bool {
            const top = try self.resolveTop(id);
            const values = self.topOutputs(id.index);
            for (values[0..top.output_count], 0..) |value, i| if (std.meta.eql(value, output)) {
                if (i + 1 < top.output_count) values[i] = values[top.output_count - 1];
                const n = self.wHandleCount(id);
                if (self.woutbound.len - self.woutbound_count < n * 2) return error.Exhausted;
                top.output_count -= 1;
                self.queueWUpdate(id, .output_leave, output);
                return true;
            };
            return false;
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
            const wn = self.wHandleCount(id);
            if (self.woutbound.len - self.woutbound_count < wn * 2) return error.Exhausted;
            const dst = if (kind == .title) t.title else t.app;
            @memcpy(dst[0..value.len], value);
            if (kind == .title) t.title_len = value.len else t.app_len = value.len;
            for (self.handles.entries.items) |h| if (h.header.active and !h.closed and std.meta.eql(h.top, id)) {
                self.enqueue(kind, h.header.index, value) catch unreachable;
                self.enqueue(.done, h.header.index, "") catch unreachable;
            };
            self.queueWUpdate(id, if (kind == .title) .title else .app_id, null);
        }
        pub fn close(self: *Self, id: ToplevelId) !void {
            _ = try self.resolveTop(id);
            var n: usize = 0;
            for (self.handles.entries.items) |h| {
                if (h.header.active and !h.closed and std.meta.eql(h.top, id)) n += 1;
            }
            if (self.outbound.len - self.outbound_count < n) return error.Exhausted;
            const wn = self.wHandleCount(id);
            var parent_events: usize = 0;
            for (self.tops.entries.items) |top| {
                if (top.header.active and top.parent != null and std.meta.eql(top.parent.?, id))
                    parent_events += self.wHandleCount(.{ .index = top.header.index, .generation = top.header.generation }) * 2;
            }
            if (self.woutbound.len - self.woutbound_count < wn + parent_events) return error.Exhausted;
            for (self.handles.entries.items) |h| if (h.header.active and !h.closed and std.meta.eql(h.top, id)) {
                h.closed = true;
                self.enqueue(.closed, h.header.index, "") catch unreachable;
            };
            for (self.whandles, 0..) |*h, hi| if (h.active and !h.closed and std.meta.eql(h.top, id)) {
                h.closed = true;
                self.enqueueW(.closed, @intCast(hi), null) catch unreachable;
            };
            for (self.tops.entries.items) |top| if (top.header.active and top.parent != null and std.meta.eql(top.parent.?, id)) {
                const child: ToplevelId = .{ .index = top.header.index, .generation = top.header.generation };
                top.parent = null;
                self.queueWUpdate(child, .parent, null);
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
        fn wHandleCount(self: *Self, id: ToplevelId) usize {
            var n: usize = 0;
            for (self.whandles) |h| if (h.active and !h.closed and std.meta.eql(h.top, id)) {
                n += 1;
            };
            return n;
        }
        fn enqueueW(self: *Self, kind: WKind, owner: u32, output: ?OutputId) !void {
            if (self.woutbound_count == self.woutbound.len) return error.Exhausted;
            for (self.woutbound, 0..) |*o, i| if (!o.active) {
                var text: []const u8 = "";
                var state_snapshot: State = .{};
                var parent_snapshot: ?ToplevelId = null;
                if (kind != .finished) {
                    const h = &self.whandles[owner];
                    const top = try self.resolveTop(h.top);
                    switch (kind) {
                        .title => text = top.title[0..top.title_len],
                        .app_id => text = top.app[0..top.app_len],
                        .state => state_snapshot = top.state,
                        .parent => parent_snapshot = top.parent,
                        else => {},
                    }
                }
                o.* = .{ .active = true, .sequence = self.sequence, .kind = kind, .owner = owner, .text_len = text.len, .output = output orelse .{ .value = 0 }, .state = state_snapshot, .parent = parent_snapshot };
                @memcpy(self.woutText(@intCast(i))[0..text.len], text);
                self.sequence +%= 1;
                self.woutbound_count += 1;
                return;
            };
            unreachable;
        }
        fn makeWHandle(self: *Self, mi: u32, id: ToplevelId) !void {
            const hi = self.whandle_free;
            if (hi == none) return error.Exhausted;
            const generation = self.whandles[hi].generation;
            self.whandle_free = self.whandles[hi].next_free;
            const manager = self.wmanagers[mi];
            self.whandles[hi] = .{ .active = true, .generation = generation, .manager = mi, .top = id, .peer = manager.peer };
            const top = try self.resolveTop(id);
            try self.enqueueW(.announce, hi, null);
            try self.enqueueW(.title, hi, null);
            try self.enqueueW(.app_id, hi, null);
            for (self.topOutputs(id.index)[0..top.output_count]) |output| try self.enqueueW(.output_enter, hi, output);
            try self.enqueueW(.state, hi, null);
            if (manager.version >= 3) try self.enqueueW(.parent, hi, null);
            try self.enqueueW(.done, hi, null);
        }
        fn queueWUpdate(self: *Self, id: ToplevelId, kind: WKind, output: ?OutputId) void {
            for (self.whandles, 0..) |h, hi| if (h.active and !h.closed and std.meta.eql(h.top, id)) {
                if (kind != .parent or self.wmanagers[h.manager].version >= 3) {
                    self.enqueueW(kind, @intCast(hi), output) catch unreachable;
                    self.enqueueW(.done, @intCast(hi), null) catch unreachable;
                }
            };
        }
        pub fn pendingCommands(self: *const Self) usize {
            return self.command_count;
        }
        pub fn peekCommand(self: *const Self) ?Command {
            return if (self.command_count == 0) null else self.commands[self.command_head];
        }
        pub fn dropCommand(self: *Self) void {
            if (self.command_count != 0) {
                self.command_head = (self.command_head + 1) % self.commands.len;
                self.command_count -= 1;
            }
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
            if (target.object.interface == &WManager.info) {
                const m = from(WManagerSlot, self.wmanagers, target.object.context) orelse return null;
                if (!std.meta.eql(m.resource, rh) or !samePeer(m.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(WManager, server_objects, message, fds);
                switch (d.value) {
                    .stop => {
                        if (!m.stopped) {
                            if (self.woutbound_count == self.woutbound.len) return try self.failure(actor, d.handle.id, error.Exhausted);
                            m.stopped = true;
                            try self.enqueueW(.finished, indexOf(WManagerSlot, self.wmanagers, m), null);
                        }
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &WHandle.info) {
                const h = from(WHandleSlot, self.whandles, target.object.context) orelse return null;
                if (h.resource == null or !std.meta.eql(h.resource.?, rh) or !samePeer(h.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(WHandle, server_objects, message, fds);
                if (!h.closed and d.value != .destroy) {
                    if (self.command_count == self.commands.len) return try self.failure(actor, d.handle.id, error.Exhausted);
                    const command: Command = .{ .peer = peer, .toplevel = h.top, .request = switch (d.value) {
                        .set_maximized => .set_maximized,
                        .unset_maximized => .unset_maximized,
                        .set_minimized => .set_minimized,
                        .unset_minimized => .unset_minimized,
                        .close => .close,
                        .unset_fullscreen => .unset_fullscreen,
                        .activate => |v| .{ .activate = .{ .seat = v.seat } },
                        .set_fullscreen => |v| .{ .set_fullscreen = .{ .output = v.output } },
                        .set_rectangle => |v| blk: {
                            if (v.width < 0 or v.height < 0) {
                                try ProtocolCore.postError(actor, d.handle.id, 0, "invalid rectangle");
                                try d.finish(protocol, server_objects, &actor.transmit);
                                return .stop;
                            }
                            break :blk .{ .set_rectangle = .{ .surface = v.surface, .x = v.x, .y = v.y, .width = v.width, .height = v.height } };
                        },
                        .destroy => unreachable,
                    } };
                    self.commands[(self.command_head + self.command_count) % self.commands.len] = command;
                    self.command_count += 1;
                }
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
            for (self.woutbound) |o| if (o.active) {
                if (o.kind == .finished) {
                    if (samePeer(self.wmanagers[o.owner].peer, peer)) return true;
                } else if (self.whandles[o.owner].active and samePeer(self.whandles[o.owner].peer, peer)) return true;
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
            while (self.oldestW(peer)) |o| {
                if (o.kind == .finished) {
                    const m = &self.wmanagers[o.owner];
                    WManager.encodeEvent(queue, m.resource.id, .{ .finished = .{} }) catch |e| switch (e) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return e,
                    };
                } else {
                    const h = &self.whandles[o.owner];
                    if (!h.active) {
                        self.dropWOut(o);
                        continue;
                    }
                    if (o.kind == .announce) {
                        const m = &self.wmanagers[h.manager];
                        const made = WManager.construct_event_toplevel(protocol, server_objects, queue, m.resource, .{ .toplevel = .{ .context = h } }) catch |e| switch (e) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return e,
                        };
                        h.resource = made.toplevel;
                    } else if (h.resource != null and server_objects.namespace.resolve(h.resource.?) != null) {
                        var states: [16]u8 = undefined;
                        var state_len: usize = 0;
                        inline for (.{ .{ o.state.maximized, 0 }, .{ o.state.minimized, 1 }, .{ o.state.activated, 2 }, .{ o.state.fullscreen and self.wmanagers[h.manager].version >= 2, 3 } }) |entry| if (entry[0]) {
                            std.mem.writeInt(u32, states[state_len..][0..4], entry[1], .little);
                            state_len += 4;
                        };
                        const ev: WHandle.Event = switch (o.kind) {
                            .title => .{ .title = .{ .title = self.woutText(indexOf(WOut, self.woutbound, o))[0..o.text_len] } },
                            .app_id => .{ .app_id = .{ .app_id = self.woutText(indexOf(WOut, self.woutbound, o))[0..o.text_len] } },
                            .state => .{ .state = .{ .state = states[0..state_len] } },
                            .parent => .{ .parent = .{ .parent = self.wParentResource(h, o.parent) } },
                            .done => .{ .done = .{} },
                            .closed => .{ .closed = .{} },
                            .output_enter => if (self.resolveWOutput(h.peer, o.output)) |output| .{ .output_enter = .{ .output = output } } else {
                                self.dropWOut(o);
                                continue;
                            },
                            .output_leave => if (self.resolveWOutput(h.peer, o.output)) |output| .{ .output_leave = .{ .output = output } } else {
                                self.dropWOut(o);
                                continue;
                            },
                            else => unreachable,
                        };
                        WHandle.encodeEvent(queue, h.resource.?.id, ev) catch |e| switch (e) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return e,
                        };
                    }
                }
                self.dropWOut(o);
                count += 1;
            }
            return count;
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &WHandle.info) {
                const h = from(WHandleSlot, self.whandles, object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseWHandle(indexOf(WHandleSlot, self.whandles, h));
                return true;
            }
            if (object.interface == &WManager.info) {
                const m = from(WManagerSlot, self.wmanagers, object.context) orelse return false;
                if (!std.meta.eql(m.resource, handle)) return false;
                self.releaseWManager(indexOf(WManagerSlot, self.wmanagers, m));
                return true;
            }
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
            self.removePeerCommands(peer);
            for (self.whandles, 0..) |h, i| if (h.active and samePeer(h.peer, peer)) self.releaseWHandle(@intCast(i));
            for (self.wmanagers, 0..) |m, i| if (m.active and samePeer(m.peer, peer)) self.releaseWManager(@intCast(i));
            for (self.handles.entries.items) |h| if (h.header.active and samePeer(h.peer, peer)) self.releaseHandle(h.header.index);
            for (self.lists.entries.items) |l| if (l.header.active and samePeer(l.peer, peer)) self.releaseList(l.header.index);
        }

        fn removePeerCommands(self: *Self, peer: wayring.io_uring.Peer) void {
            var retained: usize = 0;
            const count = self.command_count;
            for (0..count) |offset| {
                const command = self.commands[(self.command_head + offset) % self.commands.len];
                if (samePeer(command.peer, peer)) continue;
                self.commands[(self.command_head + retained) % self.commands.len] = command;
                retained += 1;
            }
            self.command_count = retained;
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
        fn releaseWHandle(self: *Self, i: u32) void {
            for (self.woutbound) |*o| if (o.active and o.kind != .finished and o.owner == i) self.dropWOut(o);
            const generation = nextGeneration(self.whandles[i].generation);
            self.whandles[i] = .{ .generation = generation, .next_free = self.whandle_free };
            self.whandle_free = i;
        }
        fn releaseWManager(self: *Self, i: u32) void {
            for (self.whandles, 0..) |h, hi| if (h.active and h.manager == i and h.resource == null) self.releaseWHandle(@intCast(hi));
            for (self.woutbound) |*o| if (o.active and o.kind == .finished and o.owner == i) self.dropWOut(o);
            const generation = nextGeneration(self.wmanagers[i].generation);
            self.wmanagers[i] = .{ .generation = generation, .next_free = self.wmanager_free };
            self.wmanager_free = i;
        }
        fn dropWOut(self: *Self, o: *WOut) void {
            if (o.active) {
                o.active = false;
                self.woutbound_count -= 1;
            }
        }
        fn oldestW(self: *Self, peer: wayring.io_uring.Peer) ?*WOut {
            var best: ?*WOut = null;
            for (self.woutbound) |*o| {
                if (o.active and ((o.kind == .finished and samePeer(self.wmanagers[o.owner].peer, peer)) or (o.kind != .finished and self.whandles[o.owner].active and samePeer(self.whandles[o.owner].peer, peer))) and (best == null or o.sequence < best.?.sequence)) best = o;
            }
            return best;
        }
        fn wParentResource(self: *Self, child: *WHandleSlot, parent_snapshot: ?ToplevelId) ?u32 {
            const parent_id = parent_snapshot orelse return null;
            for (self.whandles) |h| if (h.active and h.manager == child.manager and std.meta.eql(h.top, parent_id)) return if (h.resource) |resource| resource.id else null;
            return null;
        }
        fn resolveWOutput(self: *Self, peer: wayring.io_uring.Peer, output: OutputId) ?u32 {
            return if (self.output_resolver) |resolver| resolver(self.output_resolver_context, peer, output) else null;
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
        fn woutText(self: *Self, i: u32) []u8 {
            return self.wout_text[@as(usize, i) * self.metadata_capacity ..][0..self.metadata_capacity];
        }
        fn topOutputs(self: *Self, i: u32) []OutputId {
            return self.top_outputs[@as(usize, i) * self.output_capacity ..][0..self.output_capacity];
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

test "foreign toplevel: state and parent inventory is generation safe" {
    const A = Adapter(@import("core_protocol"));
    var a = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 3,
        .handle_capacity = 1,
        .outbound_capacity = 2,
        .metadata_capacity = 8,
    });
    defer a.deinit();
    const parent = try a.publish(null, null);
    const child = try a.publish(null, null);
    try std.testing.expectEqual(A.State{}, try a.state(child));
    try std.testing.expect(try a.updateState(child, .{ .activated = true }));
    try std.testing.expect(!(try a.updateState(child, .{ .activated = true })));
    try std.testing.expect((try a.state(child)).activated);

    try std.testing.expectError(error.InvalidParent, a.updateParent(child, child));
    try std.testing.expect(try a.updateParent(child, parent));
    try std.testing.expect(!(try a.updateParent(child, parent)));
    try a.close(parent);
    try std.testing.expectEqual(@as(?A.ToplevelId, null), try a.parent(child));
    try std.testing.expectError(error.StaleToplevel, a.updateParent(child, parent));
    try std.testing.expectError(error.StaleToplevel, a.state(parent));
}

test "foreign toplevel: output membership is bounded and reset on reuse" {
    const A = Adapter(@import("core_protocol"));
    var a = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 1,
        .handle_capacity = 1,
        .outbound_capacity = 2,
        .metadata_capacity = 8,
        .output_capacity = 2,
    });
    defer a.deinit();
    const first = try a.publish(null, null);
    const one: A.OutputId = .{ .value = 11 };
    const two: A.OutputId = .{ .value = 22 };
    try std.testing.expect(try a.addOutput(first, one));
    try std.testing.expect(!(try a.addOutput(first, one)));
    try std.testing.expect(try a.addOutput(first, two));
    try std.testing.expectError(error.Exhausted, a.addOutput(first, .{ .value = 33 }));
    try std.testing.expectEqual(@as(usize, 2), (try a.outputs(first)).len);
    try std.testing.expect(try a.removeOutput(first, one));
    try std.testing.expect(!(try a.removeOutput(first, one)));
    try a.close(first);
    try std.testing.expectError(error.StaleToplevel, a.addOutput(first, one));
    const next = try a.publish(null, null);
    try std.testing.expectEqual(@as(usize, 0), (try a.outputs(next)).len);
    try std.testing.expectError(error.StaleToplevel, a.outputs(first));
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

test "foreign toplevel: wlr bind ordering, version gates, updates and stop isolation" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{ .list_capacity = 1, .toplevel_capacity = 2, .handle_capacity = 2, .outbound_capacity = 8, .metadata_capacity = 16, .wlr_manager_capacity = 2, .wlr_handle_capacity = 4, .wlr_outbound_capacity = 24, .command_capacity = 2 });
    defer adapter.deinit();
    const id = try adapter.publish("", "app");
    const peer: wayring.io_uring.Peer = .{ .slot = 4, .generation = 9 };
    _ = try A.bindWlr(&adapter, .{ .peer = peer, .credentials = .{ .pid = 1, .uid = 2, .gid = 3 }, .global = .{ .id = 3, .generation = 1 }, .resource = .{ .id = 4, .generation = 1 }, .version = 3 });
    const expected = [_]A.WKind{ .announce, .title, .app_id, .state, .parent, .done };
    for (expected) |kind| {
        const event = adapter.oldestW(peer).?;
        try std.testing.expectEqual(kind, event.kind);
        adapter.dropWOut(event);
    }
    try std.testing.expect(try adapter.updateState(id, .{ .fullscreen = true }));
    try std.testing.expectEqual(A.WKind.state, adapter.oldestW(peer).?.kind);
    adapter.wmanagers[0].stopped = true;
    _ = try adapter.publish("later", null);
    try std.testing.expectEqual(@as(usize, 3), freeCount(A.WHandleSlot, adapter.whandles));
}

test "foreign toplevel: wlr outbound metadata state and parent are snapshots" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 3,
        .handle_capacity = 1,
        .outbound_capacity = 2,
        .metadata_capacity = 16,
        .wlr_manager_capacity = 1,
        .wlr_handle_capacity = 3,
        .wlr_outbound_capacity = 40,
    });
    defer adapter.deinit();
    const first_parent = try adapter.publish(null, null);
    const second_parent = try adapter.publish(null, null);
    const child = try adapter.publish("initial", "initial-app");
    const peer: wayring.io_uring.Peer = .{ .slot = 14, .generation = 2 };
    _ = try A.bindWlr(&adapter, .{ .peer = peer, .credentials = .{ .pid = 1, .uid = 2, .gid = 3 }, .global = .{ .id = 3, .generation = 1 }, .resource = .{ .id = 4, .generation = 1 }, .version = 3 });
    for (adapter.woutbound) |*event| adapter.dropWOut(event);

    try adapter.updateTitle(child, "first");
    try adapter.updateTitle(child, "second");
    try adapter.updateAppId(child, "app-one");
    try adapter.updateAppId(child, "app-two");
    try std.testing.expect(try adapter.updateState(child, .{ .activated = true }));
    try std.testing.expect(try adapter.updateState(child, .{ .minimized = true }));
    try std.testing.expect(try adapter.updateParent(child, first_parent));
    try std.testing.expect(try adapter.updateParent(child, second_parent));
    try adapter.close(child);

    const expected_text = [_][]const u8{ "first", "second", "app-one", "app-two" };
    var text_index: usize = 0;
    var state_index: usize = 0;
    var parent_index: usize = 0;
    while (adapter.oldestW(peer)) |event| {
        switch (event.kind) {
            .title, .app_id => {
                const index = indexOf(A.WOut, adapter.woutbound, event);
                try std.testing.expectEqualStrings(expected_text[text_index], adapter.woutText(index)[0..event.text_len]);
                text_index += 1;
            },
            .state => {
                if (state_index == 0) {
                    try std.testing.expect(event.state.activated);
                    try std.testing.expect(!event.state.minimized);
                } else {
                    try std.testing.expect(!event.state.activated);
                    try std.testing.expect(event.state.minimized);
                }
                state_index += 1;
            },
            .parent => {
                try std.testing.expectEqual(if (parent_index == 0) first_parent else second_parent, event.parent.?);
                parent_index += 1;
            },
            else => {},
        }
        adapter.dropWOut(event);
    }
    try std.testing.expectEqual(@as(usize, 4), text_index);
    try std.testing.expectEqual(@as(usize, 2), state_index);
    try std.testing.expectEqual(@as(usize, 2), parent_index);
}

test "foreign toplevel: wlr publication backpressure is atomic" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{ .list_capacity = 1, .toplevel_capacity = 1, .handle_capacity = 1, .outbound_capacity = 4, .metadata_capacity = 8, .wlr_manager_capacity = 1, .wlr_handle_capacity = 1, .wlr_outbound_capacity = 5, .command_capacity = 1 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 1 };
    _ = try A.bindWlr(&adapter, .{ .peer = peer, .credentials = .{ .pid = 1, .uid = 2, .gid = 3 }, .global = .{ .id = 2, .generation = 1 }, .resource = .{ .id = 3, .generation = 1 }, .version = 3 });
    try std.testing.expectError(error.Exhausted, adapter.publish("x", "y"));
    try std.testing.expectEqual(@as(usize, 0), adapter.woutbound_count);
    try std.testing.expectEqual(@as(usize, 0), adapter.tops.entries.items.len);
}

test "foreign toplevel: disconnect drops only that peer's queued controls" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .list_capacity = 1,
        .toplevel_capacity = 1,
        .handle_capacity = 1,
        .outbound_capacity = 2,
        .metadata_capacity = 8,
        .command_capacity = 4,
    });
    defer adapter.deinit();
    const id = try adapter.publish(null, null);
    const first: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const second: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    adapter.commands[0] = .{ .peer = first, .toplevel = id, .request = .close };
    adapter.commands[1] = .{ .peer = second, .toplevel = id, .request = .set_maximized };
    adapter.commands[2] = .{ .peer = first, .toplevel = id, .request = .unset_maximized };
    adapter.command_count = 3;

    adapter.disconnected(first);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCommands());
    const retained = adapter.peekCommand().?;
    try std.testing.expectEqual(second, retained.peer);
    try std.testing.expectEqual(.set_maximized, retained.request);
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
