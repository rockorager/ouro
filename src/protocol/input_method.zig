//! Standalone bounded input-method-unstable-v2 adapter.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const max_string_bytes = 4000;
pub const SeatValidator = struct {
    context: ?*anyopaque = null,
    resolveFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) ?u32,
    pub fn resolve(self: @This(), peer: wayring.io_uring.Peer, seat: u32) ?u32 {
        return self.resolveFn(self.context, peer, seat);
    }
};
pub const Config = struct {
    manager_capacity: usize = 4,
    method_capacity: usize = 4,
    popup_capacity: usize = 4,
    grab_capacity: usize = 4,
    outbound_capacity: usize = 32,
    string_bytes: usize = max_string_bytes,
    fn validate(self: @This()) !void {
        inline for (.{ self.manager_capacity, self.method_capacity, self.popup_capacity, self.grab_capacity, self.outbound_capacity, self.string_bytes }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (self.string_bytes > max_string_bytes) return error.InvalidConfig;
    }
};

pub const Edit = struct {
    preedit: ?[]const u8 = null,
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    commit: ?[]const u8 = null,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
};
pub const PendingEdit = struct {
    preedit_len: ?usize = null,
    cursor_begin: i32 = 0,
    cursor_end: i32 = 0,
    commit_len: ?usize = null,
    delete_before: u32 = 0,
    delete_after: u32 = 0,
    preedit_storage: [max_string_bytes]u8 = undefined,
    commit_storage: [max_string_bytes]u8 = undefined,
    pub fn reset(self: *@This()) void {
        self.preedit_len = null;
        self.commit_len = null;
        self.cursor_begin = 0;
        self.cursor_end = 0;
        self.delete_before = 0;
        self.delete_after = 0;
    }
    pub fn setCommit(self: *@This(), text: []const u8) !void {
        try validString(text);
        @memcpy(self.commit_storage[0..text.len], text);
        self.commit_len = text.len;
    }
    pub fn setPreedit(self: *@This(), text: []const u8, begin: i32, end: i32) !void {
        try validString(text);
        if (!validCursor(text, begin, end)) return error.InvalidCursor;
        @memcpy(self.preedit_storage[0..text.len], text);
        self.preedit_len = text.len;
        self.cursor_begin = begin;
        self.cursor_end = end;
    }
    pub fn value(self: *const @This()) Edit {
        return .{ .preedit = if (self.preedit_len) |n| self.preedit_storage[0..n] else null, .cursor_begin = self.cursor_begin, .cursor_end = self.cursor_end, .commit = if (self.commit_len) |n| self.commit_storage[0..n] else null, .delete_before = self.delete_before, .delete_after = self.delete_after };
    }
};

pub fn Adapter(comptime protocol: type, comptime TextInput: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_input_method_manager_v2;
        const Method = protocol.zwp_input_method_v2;
        const Popup = protocol.zwp_input_popup_surface_v2;
        const Grab = protocol.zwp_input_method_keyboard_grab_v2;
        const ManagerSlot = struct { active: bool = false, next: u32 = none, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined };
        const MethodId = packed struct { index: u32, generation: u32 };
        const MethodSlot = struct { active: bool = false, retired: bool = false, generation: u32 = 1, next: u32 = none, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, seat_key: u32 = 0, available: bool = false, enabled: bool = false, target: ?TextInput.DeviceId = null, done_serial: u32 = 0, pending: PendingEdit = .{} };
        const Child = struct { active: bool = false, retired: bool = false, generation: u32 = 1, next: u32 = none, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, parent: MethodId = undefined };
        const OutKind = enum { unavailable, activate, deactivate, surrounding, cause, content, done };
        const Out = struct { active: bool = false, sequence: u64 = 0, peer: wayring.io_uring.Peer = undefined, method: MethodId = undefined, kind: OutKind = .unavailable, text_len: usize = 0, cursor: u32 = 0, anchor: u32 = 0, cause: u32 = 0, hints: u32 = 0, purpose: u32 = 0, storage: []u8 = &.{} };

        allocator: std.mem.Allocator,
        validator: SeatValidator,
        text_input: *TextInput,
        managers: []ManagerSlot,
        methods: []MethodSlot,
        popups: []Child,
        grabs: []Child,
        outbound: []Out,
        out_text: []u8,
        string_bytes: usize,
        manager_free: u32 = 0,
        method_free: u32 = 0,
        popup_free: u32 = 0,
        grab_free: u32 = 0,
        out_len: usize = 0,
        next_sequence: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(a: std.mem.Allocator, ti: *TextInput, validator: SeatValidator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(1);
            const managers = try a.alloc(ManagerSlot, c.manager_capacity);
            errdefer a.free(managers);
            const methods = try a.alloc(MethodSlot, c.method_capacity);
            errdefer a.free(methods);
            const popups = try a.alloc(Child, c.popup_capacity);
            errdefer a.free(popups);
            const grabs = try a.alloc(Child, c.grab_capacity);
            errdefer a.free(grabs);
            const outbound = try a.alloc(Out, c.outbound_capacity);
            errdefer a.free(outbound);
            const ot = try a.alloc(u8, try std.math.mul(usize, c.outbound_capacity, c.string_bytes));
            errdefer a.free(ot);
            initFree(ManagerSlot, managers);
            initFree(MethodSlot, methods);
            initFree(Child, popups);
            initFree(Child, grabs);
            for (outbound, 0..) |*o, i| {
                o.* = .{};
                o.storage = ot[i * c.string_bytes ..][0..c.string_bytes];
            }
            return .{ .allocator = a, .validator = validator, .text_input = ti, .managers = managers, .methods = methods, .popups = popups, .grabs = grabs, .outbound = outbound, .out_text = ot, .string_bytes = c.string_bytes };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.out_text);
            self.allocator.free(self.outbound);
            self.allocator.free(self.grabs);
            self.allocator.free(self.popups);
            self.allocator.free(self.methods);
            self.allocator.free(self.managers);
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const g = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            self.global = g;
            return g;
        }
        fn bind(ctx: ?*anyopaque, b: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx.?));
            if (self.manager_free == none) return error.OutOfMemory;
            const i = self.manager_free;
            self.manager_free = self.managers[i].next;
            self.managers[i] = .{ .active = true, .resource = b.resource, .peer = b.peer };
            return &self.managers[i];
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try r.clients.reactor.getActor(peer), try r.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = so.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !same(manager.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Manager, so, message, fds);
                switch (d.value) {
                    .destroy => {},
                    .get_input_method => |q| {
                        const m = self.acquireMethod() catch return try self.noMemory(actor);
                        m.peer = peer;
                        const seat_key = self.validator.resolve(peer, q.seat);
                        m.seat_key = seat_key orelse 0;
                        m.available = seat_key != null and self.findAvailable(m.seat_key) == null;
                        if (!m.available and !self.canEnqueue(1)) {
                            self.releaseMethod(self.methodIndex(m));
                            return try self.noMemory(actor);
                        }
                        const admitted = Manager.admit_get_input_method(so, d.handle, q, .{ .input_method = m }) catch |e| {
                            self.releaseMethod(self.methodIndex(m));
                            return try self.failure(actor, d.handle.id, e);
                        };
                        m.resource = admitted.input_method;
                        if (!m.available) try self.enqueue(m, .unavailable, null);
                    },
                }
                try d.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Method.info) {
                const m = from(MethodSlot, self.methods, target.object.context) orelse return null;
                if (!std.meta.eql(m.resource, handle) or !same(m.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Method, so, message, fds);
                switch (d.value) {
                    .destroy => {},
                    .commit_string => |q| if (m.available) {
                        if (q.text.len > self.string_bytes) return try self.protocolError(actor, d.handle.id, 0, "commit string too long");
                        m.pending.setCommit(q.text) catch return try self.protocolError(actor, d.handle.id, 0, "invalid commit string");
                    },
                    .set_preedit_string => |q| if (m.available) {
                        if (q.text.len > self.string_bytes) return try self.protocolError(actor, d.handle.id, 0, "preedit string too long");
                        m.pending.setPreedit(q.text, q.cursor_begin, q.cursor_end) catch return try self.protocolError(actor, d.handle.id, 0, "invalid preedit string or cursor");
                    },
                    .delete_surrounding_text => |q| {
                        if (m.available) {
                            m.pending.delete_before = q.before_length;
                            m.pending.delete_after = q.after_length;
                        }
                    },
                    .commit => |q| self.commit(m, q.serial) catch return try self.noMemory(actor),
                    .get_input_popup_surface => |q| {
                        const c = self.acquireChild(self.popups, &self.popup_free) catch return try self.noMemory(actor);
                        c.peer = peer;
                        c.parent = self.methodId(m);
                        const admitted = Method.admit_get_input_popup_surface(so, d.handle, q, .{ .id = c }) catch |e| {
                            self.releaseChild(self.popups, &self.popup_free, self.childIndex(self.popups, c));
                            return try self.failure(actor, d.handle.id, e);
                        };
                        c.resource = admitted.id;
                    },
                    .grab_keyboard => |q| {
                        const c = self.acquireChild(self.grabs, &self.grab_free) catch return try self.noMemory(actor);
                        c.peer = peer;
                        c.parent = self.methodId(m);
                        const admitted = Method.admit_grab_keyboard(so, d.handle, q, .{ .keyboard = c }) catch |e| {
                            self.releaseChild(self.grabs, &self.grab_free, self.childIndex(self.grabs, c));
                            return try self.failure(actor, d.handle.id, e);
                        };
                        c.resource = admitted.keyboard;
                    },
                }
                try d.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Popup.info) return self.childRequest(Popup, self.popups, peer, target, handle, actor, so, message, fds, &self.popup_free);
            if (target.object.interface == &Grab.info) return self.childRequest(Grab, self.grabs, peer, target, handle, actor, so, message, fds, &self.grab_free);
            return null;
        }
        fn childRequest(self: *Self, comptime I: type, slots: []Child, peer: wayring.io_uring.Peer, target: objects.Dispatch, handle: objects.Handle, actor: *wayring.connection.Actor, so: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue, free: *u32) !?wayring.dispatch.Control {
            const c = from(Child, slots, target.object.context) orelse return null;
            if (!std.meta.eql(c.resource, handle) or !same(c.peer, peer)) return null;
            const d = try wayring.server.decodeRequest(I, so, message, fds);
            try d.finish(protocol, so, &actor.transmit);
            _ = self;
            _ = free;
            return .continue_dispatch;
        }

        fn commit(self: *Self, m: *MethodSlot, serial: u32) !void {
            if (!m.available or !m.enabled or serial != m.done_serial or m.target == null) {
                m.pending.reset();
                return;
            }
            const e = m.pending.value();
            self.text_input.queueEdit(m.target.?, .{ .preedit = e.preedit, .cursor_begin = e.cursor_begin, .cursor_end = e.cursor_end, .commit = e.commit, .delete_before = e.delete_before, .delete_after = e.delete_after }) catch |err| switch (err) {
                error.Exhausted => return error.Exhausted,
                else => {
                    m.pending.reset();
                    return;
                },
            };
            m.pending.reset();
        }
        pub fn synchronize(self: *Self, seat_key: u32, event: TextInput.Event) !void {
            const m = self.findAvailable(seat_key) orelse return;
            if (event.state.has_surrounding and
                (event.surrounding.len > self.string_bytes or
                    event.surrounding.len > max_string_bytes or
                    !std.unicode.utf8ValidateSlice(event.surrounding))) return error.InvalidState;
            const active = event.state.enabled;
            if (!active and m.target != null and !std.meta.eql(m.target.?, event.device)) return;
            const replacing = m.enabled and active and (m.target == null or !std.meta.eql(m.target.?, event.device));
            var need: usize = 1;
            if (active) need += 1 + @as(usize, @intFromBool(event.state.has_surrounding)) + @as(usize, @intFromBool(event.state.has_content_type));
            if (!active or (!m.enabled and active)) need += 1;
            if (replacing) need += 2;
            if (!self.canEnqueue(need)) return error.Exhausted;
            if (!active or replacing) try self.enqueue(m, .deactivate, null);
            if (!m.enabled and active or replacing) try self.enqueue(m, .activate, null);
            m.enabled = active;
            m.target = if (active) event.device else null;
            m.pending.reset();
            if (active) {
                if (event.state.has_surrounding) try self.enqueue(m, .surrounding, .{ .text = event.surrounding, .cursor = @intCast(event.state.cursor), .anchor = @intCast(event.state.anchor) });
                try self.enqueue(m, .cause, .{ .cause = event.state.cause });
                if (event.state.has_content_type) try self.enqueue(m, .content, .{ .hints = event.state.hints, .purpose = event.state.purpose });
            }
            try self.enqueue(m, .done, null);
        }
        const Payload = struct { text: ?[]const u8 = null, cursor: u32 = 0, anchor: u32 = 0, cause: u32 = 0, hints: u32 = 0, purpose: u32 = 0 };
        fn enqueue(self: *Self, m: *MethodSlot, kind: OutKind, payload: ?Payload) !void {
            if (!self.canEnqueue(1)) return error.Exhausted;
            if (self.next_sequence == std.math.maxInt(u64)) self.next_sequence = 1;
            var o: *Out = undefined;
            for (self.outbound) |*x| if (!x.active) {
                o = x;
                break;
            };
            const storage = o.storage;
            o.* = .{ .active = true, .sequence = self.next_sequence, .peer = m.peer, .method = self.methodId(m), .kind = kind, .storage = storage };
            self.next_sequence += 1;
            if (payload) |p| {
                if (p.text) |text| {
                    if (text.len > self.string_bytes) return error.StringTooLong;
                    @memcpy(o.storage[0..text.len], text);
                    o.text_len = text.len;
                }
                o.cursor = p.cursor;
                o.anchor = p.anchor;
                o.cause = p.cause;
                o.hints = p.hints;
                o.purpose = p.purpose;
            }
            self.out_len += 1;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, so: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            while (self.oldest(peer)) |o| {
                const m = self.resolveMethod(o.method) orelse {
                    self.dropOut(o);
                    continue;
                };
                const event: Method.Event = switch (o.kind) {
                    .unavailable => .{ .unavailable = .{} },
                    .activate => .{ .activate = .{} },
                    .deactivate => .{ .deactivate = .{} },
                    .surrounding => .{ .surrounding_text = .{ .text = o.storage[0..o.text_len], .cursor = o.cursor, .anchor = o.anchor } },
                    .cause => .{ .text_change_cause = .{ .cause = protocol.zwp_text_input_v3.change_cause.fromInt(o.cause) } },
                    .content => .{ .content_type = .{
                        .hint = protocol.zwp_text_input_v3.content_hint.fromInt(o.hints),
                        .purpose = protocol.zwp_text_input_v3.content_purpose.fromInt(o.purpose),
                    } },
                    .done => .{ .done = .{} },
                };
                wayring.server.sendEvent(protocol, Method, so, queue, m.resource, event) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return err,
                };
                if (o.kind == .done) m.done_serial +%= 1;
                self.dropOut(o);
                count += 1;
            }
            return count;
        }
        pub fn pendingOutbound(self: *const Self) usize {
            return self.out_len;
        }
        pub fn pendingOutboundOn(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active and same(o.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, h: objects.Handle, o: objects.Object) bool {
            if (o.interface == &Method.info) {
                const m = from(MethodSlot, self.methods, o.context) orelse return false;
                if (!std.meta.eql(m.resource, h)) return false;
                self.releaseMethod(self.methodIndex(m));
                return true;
            }
            if (o.interface == &Manager.info) {
                const m = from(ManagerSlot, self.managers, o.context) orelse return false;
                if (!std.meta.eql(m.resource, h)) return false;
                const i = indexOf(ManagerSlot, self.managers, m);
                m.* = .{ .next = self.manager_free };
                self.manager_free = i;
                return true;
            }
            if (o.interface == &Popup.info) return self.removeChild(self.popups, &self.popup_free, h, o);
            if (o.interface == &Grab.info) return self.removeChild(self.grabs, &self.grab_free, h, o);
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.methods) |*m| if (m.active and same(m.peer, peer)) self.releaseMethod(self.methodIndex(m));
            for (self.managers) |*m| if (m.active and same(m.peer, peer)) {
                const i = indexOf(ManagerSlot, self.managers, m);
                m.* = .{ .next = self.manager_free };
                self.manager_free = i;
            };
            for (self.popups) |*c| if (c.active and same(c.peer, peer)) self.releaseChild(self.popups, &self.popup_free, self.childIndex(self.popups, c));
            for (self.grabs) |*c| if (c.active and same(c.peer, peer)) self.releaseChild(self.grabs, &self.grab_free, self.childIndex(self.grabs, c));
            for (self.outbound) |*o| if (o.active and same(o.peer, peer)) self.dropOut(o);
        }

        fn acquireMethod(self: *Self) !*MethodSlot {
            if (self.method_free == none) return error.Exhausted;
            const i = self.method_free;
            const m = &self.methods[i];
            self.method_free = m.next;
            const g = m.generation;
            m.* = .{ .active = true, .generation = g };
            return m;
        }
        fn releaseMethod(self: *Self, i: u32) void {
            const m = &self.methods[i];
            if (!m.active) return;
            for (self.outbound) |*o| if (o.active and std.meta.eql(o.method, self.methodId(m))) self.dropOut(o);
            for (self.popups) |*c| {
                if (c.active and std.meta.eql(c.parent, self.methodId(m))) c.parent.generation = 0;
            }
            for (self.grabs) |*c| {
                if (c.active and std.meta.eql(c.parent, self.methodId(m))) c.parent.generation = 0;
            }
            if (m.generation == std.math.maxInt(u32)) {
                m.* = .{ .retired = true, .generation = m.generation };
                return;
            }
            m.* = .{ .generation = m.generation + 1, .next = self.method_free };
            self.method_free = i;
        }
        fn acquireChild(_: *Self, slots: []Child, free: *u32) !*Child {
            if (free.* == none) return error.Exhausted;
            const i = free.*;
            const c = &slots[i];
            free.* = c.next;
            const g = c.generation;
            c.* = .{ .active = true, .generation = g };
            return c;
        }
        fn releaseChild(_: *Self, slots: []Child, free: *u32, i: u32) void {
            const c = &slots[i];
            if (!c.active) return;
            if (c.generation == std.math.maxInt(u32)) {
                c.* = .{ .retired = true, .generation = c.generation };
                return;
            }
            c.* = .{ .generation = c.generation + 1, .next = free.* };
            free.* = i;
        }
        fn removeChild(self: *Self, slots: []Child, free: *u32, h: objects.Handle, o: objects.Object) bool {
            const c = from(Child, slots, o.context) orelse return false;
            if (!std.meta.eql(c.resource, h)) return false;
            self.releaseChild(slots, free, self.childIndex(slots, c));
            return true;
        }
        fn findAvailable(self: *Self, seat_key: u32) ?*MethodSlot {
            for (self.methods) |*m| if (m.active and m.available and m.seat_key == seat_key) return m;
            return null;
        }
        fn methodIndex(self: *const Self, m: *const MethodSlot) u32 {
            return indexOf(MethodSlot, self.methods, m);
        }
        fn childIndex(_: *const Self, slots: []Child, c: *const Child) u32 {
            return indexOf(Child, slots, c);
        }
        fn methodId(self: *const Self, m: *const MethodSlot) MethodId {
            return .{ .index = self.methodIndex(m), .generation = m.generation };
        }
        fn resolveMethod(self: *Self, id: MethodId) ?*MethodSlot {
            if (id.index >= self.methods.len) return null;
            const m = &self.methods[id.index];
            return if (m.active and m.generation == id.generation) m else null;
        }
        fn canEnqueue(self: *const Self, n: usize) bool {
            return self.outbound.len - self.out_len >= n and (self.next_sequence <= std.math.maxInt(u64) - n or self.out_len == 0);
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Out {
            var result: ?*Out = null;
            for (self.outbound) |*o| if (o.active and same(o.peer, peer) and (result == null or o.sequence < result.?.sequence)) {
                result = o;
            };
            return result;
        }
        fn dropOut(self: *Self, o: *Out) void {
            if (o.active) {
                o.active = false;
                self.out_len -= 1;
            }
        }
        fn noMemory(_: *Self, a: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(a, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, a: *wayring.connection.Actor, id: u32, code: u32, msg: []const u8) !wayring.dispatch.Control {
            try Core.postError(a, id, code, msg);
            return .stop;
        }
        fn failure(_: *Self, a: *wayring.connection.Actor, id: u32, e: anyerror) !wayring.dispatch.Control {
            try Core.postError(a, id, 0, @errorName(e));
            return .stop;
        }
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*s, i| s.* = .{ .next = if (i + 1 < slots.len) @intCast(i + 1) else none };
}
fn indexOf(comptime T: type, slots: []const T, p: *const T) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const p = context orelse return null;
    const a = @intFromPtr(p);
    const start = @intFromPtr(slots.ptr);
    if (a < start or a >= start + slots.len * @sizeOf(T) or (a - start) % @sizeOf(T) != 0) return null;
    const s = &slots[(a - start) / @sizeOf(T)];
    return if (s.active) s else null;
}
fn same(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
pub fn validString(text: []const u8) !void {
    if (text.len > max_string_bytes) return error.StringTooLong;
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
}
fn validCursor(text: []const u8, begin: i32, end: i32) bool {
    if (begin == -1 or end == -1) return begin == -1 and end == -1;
    if (begin < 0 or end < 0 or begin > text.len or end > text.len) return false;
    return boundary(text, @intCast(begin)) and boundary(text, @intCast(end));
}
fn boundary(text: []const u8, i: usize) bool {
    return i == text.len or (text[i] & 0xc0) != 0x80;
}

test "input method validates bounded UTF-8 and preedit cursors transactionally" {
    var p: PendingEdit = .{};
    try p.setCommit("old");
    try p.setPreedit("hé", 1, 3);
    try std.testing.expectError(error.InvalidCursor, p.setPreedit("hé", 2, 3));
    try std.testing.expectEqualStrings("hé", p.value().preedit.?);
    try std.testing.expectError(error.InvalidUtf8, p.setCommit("\xff"));
    try std.testing.expectEqualStrings("old", p.value().commit.?);
    var oversized: [max_string_bytes + 1]u8 = @splat('x');
    try std.testing.expectError(error.StringTooLong, p.setCommit(&oversized));
}

test "input method arbitration state edits generation and disconnect" {
    const T = struct {
        pub const DeviceId = packed struct { index: u32, generation: u32 };
        pub const Event = struct { device: DeviceId, peer: wayring.io_uring.Peer, seat: u32, state: struct { enabled: bool, has_surrounding: bool = false, cursor: i32 = 0, anchor: i32 = 0, cause: u32 = 0, has_content_type: bool = false, hints: u32 = 0, purpose: u32 = 0 }, surrounding: []const u8 = "", serial: u32 = 0 };
        calls: usize = 0,
        pub fn queueEdit(self: *@This(), _: DeviceId, _: anytype) !void {
            self.calls += 1;
        }
    };
    const A = Adapter(@import("core_protocol"), T);
    var ti: T = .{};
    const validator: SeatValidator = .{ .resolveFn = struct {
        fn f(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) ?u32 {
            return 7;
        }
    }.f };
    var a = try A.init(std.testing.allocator, &ti, validator, .{ .manager_capacity = 1, .method_capacity = 2, .popup_capacity = 1, .grab_capacity = 1, .outbound_capacity = 12, .string_bytes = 16 });
    defer a.deinit();
    const one = try a.acquireMethod();
    one.peer = .{ .slot = 1, .generation = 1 };
    one.seat_key = 7;
    one.available = true;
    const old = a.methodId(one);
    const two = try a.acquireMethod();
    two.seat_key = 7;
    two.available = a.findAvailable(7) == null;
    try std.testing.expect(!two.available);
    try a.synchronize(7, .{ .device = .{ .index = 2, .generation = 3 }, .peer = one.peer, .seat = 19, .state = .{ .enabled = true, .has_surrounding = true, .cursor = 1, .anchor = 1 }, .surrounding = "x" });
    try std.testing.expectEqual(@as(usize, 4), a.pendingOutbound());
    one.done_serial = 1;
    try one.pending.setCommit("ok");
    try a.commit(one, 0);
    try std.testing.expectEqual(@as(usize, 0), ti.calls);
    try one.pending.setCommit("ok");
    try a.commit(one, 1);
    try std.testing.expectEqual(@as(usize, 1), ti.calls);
    a.releaseMethod(old.index);
    const reused = try a.acquireMethod();
    try std.testing.expect(old.generation != a.methodId(reused).generation);
    a.disconnected(one.peer);
}
