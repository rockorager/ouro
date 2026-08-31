//! Standalone bounded input-method-unstable-v2 adapter.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const linux = std.os.linux;
const slot_pool = @import("slot_pool.zig");
const surface_state = @import("../surface.zig");
const none = std.math.maxInt(u32);
const popup_role_id: surface_state.RoleId = 0x696d_5f70_6f70_7570;

pub const GrabId = packed struct { index: u32, generation: u32 };
pub const PopupId = packed struct { index: u32, generation: u32 };
pub const PopupRectangle = struct { x: i32, y: i32, width: i32, height: i32 };
pub const Modifiers = struct { serial: u32 = 0, depressed: u32 = 0, latched: u32 = 0, locked: u32 = 0, group: u32 = 0 };
pub const KeyboardSnapshot = struct {
    keymap_size: u32,
    repeat_rate: i32,
    repeat_delay: i32,
    modifiers: Modifiers,
};
pub const KeyboardProvider = struct {
    context: ?*anyopaque = null,
    snapshotFn: *const fn (?*anyopaque, u32) KeyboardSnapshot,
    duplicateKeymapFn: *const fn (?*anyopaque, u32) anyerror!linux.fd_t,
    pub fn snapshot(self: @This(), seat: u32) KeyboardSnapshot {
        return self.snapshotFn(self.context, seat);
    }
    pub fn duplicateKeymap(self: @This(), seat: u32) !linux.fd_t {
        return self.duplicateKeymapFn(self.context, seat);
    }
};

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

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type, comptime TextInput: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_input_method_manager_v2;
        const Method = protocol.zwp_input_method_v2;
        const Popup = protocol.zwp_input_popup_surface_v2;
        const Grab = protocol.zwp_input_method_keyboard_grab_v2;
        const ManagerSlot = struct { header: slot_pool.Header = .{}, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined };
        const MethodId = packed struct { index: u32, generation: u32 };
        const MethodSlot = struct { header: slot_pool.Header = .{}, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, seat_key: u32 = 0, available: bool = false, enabled: bool = false, target: ?TextInput.DeviceId = null, done_serial: u32 = 0, pending: PendingEdit = .{} };
        const Child = struct { header: slot_pool.Header = .{}, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, parent: MethodId = undefined, surface: ?CoreSurface.SurfaceId = null, order: u64 = 0, eligible: bool = true };
        const OutKind = enum { unavailable, activate, deactivate, surrounding, cause, content, done, popup_rectangle, grab_keymap, grab_repeat, grab_modifiers, grab_key };
        const Out = struct { active: bool = false, sequence: u64 = 0, peer: wayring.io_uring.Peer = undefined, method: MethodId = undefined, popup: PopupId = .{ .index = none, .generation = 0 }, grab: GrabId = .{ .index = none, .generation = 0 }, kind: OutKind = .unavailable, text_len: usize = 0, cursor: u32 = 0, anchor: u32 = 0, cause: u32 = 0, hints: u32 = 0, purpose: u32 = 0, x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0, serial: u32 = 0, time: u32 = 0, key: u32 = 0, state: u32 = 0, modifiers: Modifiers = .{}, rate: i32 = 0, delay: i32 = 0, size: u32 = 0, storage: []u8 = &.{} };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        validator: SeatValidator,
        text_input: *TextInput,
        managers: slot_pool.Pool(ManagerSlot),
        methods: slot_pool.Pool(MethodSlot),
        popups: slot_pool.Pool(Child),
        grabs: slot_pool.Pool(Child),
        outbound: []Out,
        out_text: []u8,
        string_bytes: usize,
        out_len: usize = 0,
        next_sequence: u64 = 1,
        provider: ?KeyboardProvider = null,
        active_grab: ?GrabId = null,
        grab_inhibited: bool = false,
        grab_clock: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(a: std.mem.Allocator, core: *CoreSurface, ti: *TextInput, validator: SeatValidator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(1);
            var managers = try slot_pool.Pool(ManagerSlot).init(a, c.manager_capacity);
            errdefer managers.deinit();
            var methods = try slot_pool.Pool(MethodSlot).init(a, c.method_capacity);
            errdefer methods.deinit();
            var popups = try slot_pool.Pool(Child).init(a, c.popup_capacity);
            errdefer popups.deinit();
            var grabs = try slot_pool.Pool(Child).init(a, c.grab_capacity);
            errdefer grabs.deinit();
            const outbound = try a.alloc(Out, c.outbound_capacity);
            errdefer a.free(outbound);
            const ot = try a.alloc(u8, try std.math.mul(usize, c.outbound_capacity, c.string_bytes));
            errdefer a.free(ot);
            for (outbound, 0..) |*o, i| {
                o.* = .{};
                o.storage = ot[i * c.string_bytes ..][0..c.string_bytes];
            }
            return .{ .allocator = a, .core = core, .validator = validator, .text_input = ti, .managers = managers, .methods = methods, .popups = popups, .grabs = grabs, .outbound = outbound, .out_text = ot, .string_bytes = c.string_bytes };
        }
        pub fn deinit(self: *Self) void {
            for (self.outbound) |*o| self.dropOut(o);
            for (self.popups.entries.items) |popup| if (popup.header.active) self.releasePopup(popup);
            self.allocator.free(self.out_text);
            self.allocator.free(self.outbound);
            self.grabs.deinit();
            self.popups.deinit();
            self.methods.deinit();
            self.managers.deinit();
            self.* = undefined;
        }
        pub fn setKeyboardProvider(self: *Self, provider: ?KeyboardProvider) void {
            if (provider == null) {
                if (self.active_grab) |id| self.retireGrabOutbound(id);
                self.active_grab = null;
            }
            self.provider = provider;
            self.promoteGrab();
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
            const manager = self.managers.acquire() catch return error.OutOfMemory;
            manager.resource = b.resource;
            manager.peer = b.peer;
            return manager;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try r.clients.reactor.getActor(peer), try r.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = so.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managers.fromContext(target.object.context) orelse return null;
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
                            self.releaseMethod(m);
                            return try self.noMemory(actor);
                        }
                        const admitted = Manager.admit_get_input_method(so, d.handle, q, .{ .input_method = m }) catch |e| {
                            self.releaseMethod(m);
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
                const m = self.methods.fromContext(target.object.context) orelse return null;
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
                        const surface_handle = so.namespace.lookupHandle(q.surface) orelse
                            return try self.protocolError(actor, d.handle.id, Method.@"error".role.value, "invalid wl_surface");
                        const surface_object = so.namespace.resolve(surface_handle) orelse
                            return try self.protocolError(actor, d.handle.id, Method.@"error".role.value, "invalid wl_surface");
                        const surface = self.core.getSurfaceObject(surface_handle, surface_object) catch
                            return try self.protocolError(actor, d.handle.id, Method.@"error".role.value, "foreign wl_surface");
                        const surface_id = self.core.surfaceIdObject(surface_handle, surface_object) catch unreachable;
                        if (!same(try self.core.surfacePeer(surface_id), peer) or surface.role.id != 0)
                            return try self.protocolError(actor, d.handle.id, Method.@"error".role.value, "surface already has a role");
                        const c = self.popups.acquire() catch return try self.noMemory(actor);
                        c.peer = peer;
                        c.parent = self.methodId(m);
                        c.surface = surface_id;
                        surface.role.assign(popup_role_id, true) catch {
                            self.popups.release(c);
                            return try self.protocolError(actor, d.handle.id, Method.@"error".role.value, "surface role conflict");
                        };
                        const admitted = Method.admit_get_input_popup_surface(so, d.handle, q, .{ .id = c }) catch |e| {
                            surface.role.deactivateObject(popup_role_id) catch {};
                            self.popups.release(c);
                            return try self.failure(actor, d.handle.id, e);
                        };
                        c.resource = admitted.id;
                    },
                    .grab_keyboard => |q| {
                        const order = self.issueGrabOrder() catch return try self.noMemory(actor);
                        const c = self.grabs.acquire() catch return try self.noMemory(actor);
                        c.peer = peer;
                        c.parent = self.methodId(m);
                        const admitted = Method.admit_grab_keyboard(so, d.handle, q, .{ .keyboard = c }) catch |e| {
                            self.grabs.release(c);
                            return try self.failure(actor, d.handle.id, e);
                        };
                        c.resource = admitted.keyboard;
                        c.order = order;
                        self.promoteGrab();
                    },
                }
                try d.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Popup.info) return self.childRequest(Popup, &self.popups, peer, target, handle, actor, so, message, fds);
            if (target.object.interface == &Grab.info) {
                const c = self.grabs.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(c.resource, handle) or !same(c.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Grab, so, message, fds);
                try d.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        fn childRequest(self: *Self, comptime I: type, pool: *slot_pool.Pool(Child), peer: wayring.io_uring.Peer, target: objects.Dispatch, handle: objects.Handle, actor: *wayring.connection.Actor, so: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const c = pool.fromContext(target.object.context) orelse return null;
            if (!std.meta.eql(c.resource, handle) or !same(c.peer, peer)) return null;
            const d = try wayring.server.decodeRequest(I, so, message, fds);
            try d.finish(protocol, so, &actor.transmit);
            _ = self;
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
        /// Returns the exact generation physical input should pin pressed keys to.
        pub fn activeGrab(self: *const Self) ?GrabId {
            return if (self.grab_inhibited) null else self.active_grab;
        }
        pub fn activeGrabSeat(self: *Self, id: GrabId) ?u32 {
            if (self.grab_inhibited) return null;
            const c = self.resolveGrab(id) orelse return null;
            const m = self.resolveMethod(c.parent) orelse return null;
            return if (self.active_grab != null and std.meta.eql(self.active_grab.?, id)) m.seat_key else null;
        }
        pub fn queueKey(self: *Self, id: GrabId, serial: u32, time: u32, key: u32, state: u32) !void {
            const c = self.liveActiveGrab(id) orelse return error.StaleGrab;
            try self.enqueueGrab(c, id, .grab_key, .{ .serial = serial, .time = time, .key = key, .state = state });
        }
        pub fn queueModifiers(self: *Self, id: GrabId, modifiers: Modifiers) !void {
            const c = self.liveActiveGrab(id) orelse return error.StaleGrab;
            try self.enqueueGrab(c, id, .grab_modifiers, .{ .modifiers = modifiers });
        }
        pub fn canQueueGrab(self: *const Self, id: GrabId, count: usize) bool {
            if (self.grab_inhibited or self.active_grab == null or !std.meta.eql(self.active_grab.?, id)) return false;
            return self.canEnqueue(count);
        }
        pub fn setGrabInhibited(self: *Self, inhibited: bool) !void {
            if (self.grab_inhibited == inhibited) return;
            if (!inhibited) if (self.active_grab) |id| {
                const c = self.resolveGrab(id) orelse return;
                const m = self.resolveMethod(c.parent) orelse return;
                if (!self.canEnqueue(1)) return error.Exhausted;
                const modifiers = self.provider.?.snapshot(m.seat_key).modifiers;
                try self.enqueueGrab(c, id, .grab_modifiers, .{ .modifiers = modifiers });
            };
            self.grab_inhibited = inhibited;
        }
        pub fn canQueueKeymapUpdate(self: *Self) bool {
            const id = self.active_grab orelse return true;
            for (self.outbound) |out| {
                if (out.active and out.kind == .grab_keymap and std.meta.eql(out.grab, id)) return true;
            }
            return self.canEnqueue(1);
        }
        pub fn keymapUpdated(self: *Self) !void {
            const id = self.active_grab orelse return;
            const child = self.resolveGrab(id) orelse return;
            const method = self.resolveMethod(child.parent) orelse return;
            const size = self.provider.?.snapshot(method.seat_key).keymap_size;
            for (self.outbound) |*out| {
                if (out.active and out.kind == .grab_keymap and std.meta.eql(out.grab, id)) {
                    out.size = size;
                    return;
                }
            }
            try self.enqueueGrab(child, id, .grab_keymap, .{ .size = size });
        }
        const GrabPayload = struct { serial: u32 = 0, time: u32 = 0, key: u32 = 0, state: u32 = 0, modifiers: Modifiers = .{}, rate: i32 = 0, delay: i32 = 0, size: u32 = 0 };
        fn enqueueGrab(self: *Self, c: *Child, id: GrabId, kind: OutKind, p: GrabPayload) !void {
            if (!self.canEnqueue(1)) return error.Exhausted;
            self.normalizeSequence(1);
            self.enqueueGrabAssumeCapacity(c, id, kind, p);
        }
        fn enqueueGrabAssumeCapacity(self: *Self, c: *Child, id: GrabId, kind: OutKind, p: GrabPayload) void {
            var o: *Out = undefined;
            for (self.outbound) |*x| if (!x.active) {
                o = x;
                break;
            };
            const storage = o.storage;
            o.* = .{ .active = true, .sequence = self.next_sequence, .peer = c.peer, .grab = id, .kind = kind, .serial = p.serial, .time = p.time, .key = p.key, .state = p.state, .modifiers = p.modifiers, .rate = p.rate, .delay = p.delay, .size = p.size, .storage = storage };
            self.next_sequence += 1;
            self.out_len += 1;
        }
        /// First-created eligible grab wins; the oldest surviving waiter is promoted.
        fn promoteGrab(self: *Self) void {
            if (self.active_grab != null or self.provider == null or !self.canEnqueue(3)) return;
            var best: ?*Child = null;
            for (self.grabs.entries.items) |c| {
                if (c.header.active and c.eligible and self.resolveMethod(c.parent) != null and self.resolveMethod(c.parent).?.available and (best == null or c.order < best.?.order)) best = c;
            }
            const c = best orelse return;
            const m = self.resolveMethod(c.parent).?;
            const snap = self.provider.?.snapshot(m.seat_key);
            const id: GrabId = .{ .index = c.header.index, .generation = c.header.generation };
            self.normalizeSequence(3);
            self.enqueueGrabAssumeCapacity(c, id, .grab_keymap, .{ .size = snap.keymap_size });
            self.enqueueGrabAssumeCapacity(c, id, .grab_repeat, .{ .rate = snap.repeat_rate, .delay = snap.repeat_delay });
            self.enqueueGrabAssumeCapacity(c, id, .grab_modifiers, .{ .modifiers = snap.modifiers });
            self.active_grab = id;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, so: anytype, queue: *wayring.tx.Queue) !usize {
            // Flushing is the only asynchronous transition which can make
            // room for a previously blocked keyboard-grab promotion. All
            // other promotion producers retry synchronously at mutation time.
            defer self.promoteGrab();
            var count: usize = 0;
            while (self.oldest(peer)) |o| {
                if (o.kind == .popup_rectangle) {
                    const popup = self.resolvePopup(o.popup) orelse {
                        self.dropOut(o);
                        continue;
                    };
                    wayring.server.sendEvent(protocol, Popup, so, queue, popup.resource, .{
                        .text_input_rectangle = .{
                            .x = o.x,
                            .y = o.y,
                            .width = o.width,
                            .height = o.height,
                        },
                    }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    self.dropOut(o);
                    count += 1;
                    continue;
                }
                if (o.kind == .grab_keymap or o.kind == .grab_repeat or o.kind == .grab_modifiers or o.kind == .grab_key) {
                    const c = self.resolveGrab(o.grab) orelse {
                        self.dropOut(o);
                        continue;
                    };
                    var keymap_fd: linux.fd_t = -1;
                    if (o.kind == .grab_keymap) {
                        const m = self.resolveMethod(c.parent) orelse {
                            self.dropOut(o);
                            continue;
                        };
                        keymap_fd = try self.provider.?.duplicateKeymap(m.seat_key);
                    }
                    var owns_keymap = keymap_fd >= 0;
                    defer if (owns_keymap) {
                        _ = linux.close(keymap_fd);
                    };
                    const event: Grab.Event = switch (o.kind) {
                        .grab_keymap => .{ .keymap = .{ .format = protocol.wl_keyboard.keymap_format.xkb_v1, .fd = keymap_fd, .size = o.size } },
                        .grab_repeat => .{ .repeat_info = .{ .rate = o.rate, .delay = o.delay } },
                        .grab_modifiers => .{ .modifiers = .{ .serial = o.modifiers.serial, .mods_depressed = o.modifiers.depressed, .mods_latched = o.modifiers.latched, .mods_locked = o.modifiers.locked, .group = o.modifiers.group } },
                        .grab_key => .{ .key = .{ .serial = o.serial, .time = o.time, .key = o.key, .state = protocol.wl_keyboard.key_state.fromInt(o.state) } },
                        else => unreachable,
                    };
                    wayring.server.sendEvent(protocol, Grab, so, queue, c.resource, event) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    owns_keymap = false;
                    self.dropOut(o);
                    count += 1;
                    continue;
                }
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
                    else => unreachable,
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
        pub fn advance(self: *Self) void {
            self.promoteGrab();
        }
        pub fn activePopupSurfaces(self: *Self, output: []CoreSurface.SurfaceId) ![]const CoreSurface.SurfaceId {
            var len: usize = 0;
            for (self.popups.entries.items) |popup| {
                if (!popup.header.active or popup.surface == null) continue;
                const method = self.resolveMethod(popup.parent) orelse continue;
                if (!method.available or !method.enabled) continue;
                if (len == output.len) return error.Exhausted;
                output[len] = popup.surface.?;
                len += 1;
            }
            return output[0..len];
        }
        pub fn queuePopupRectangle(self: *Self, surface: CoreSurface.SurfaceId, rectangle: PopupRectangle) !usize {
            var needed: usize = 0;
            for (self.popups.entries.items) |popup| {
                if (!popup.header.active or popup.surface == null or
                    !std.meta.eql(popup.surface.?, surface)) continue;
                const method = self.resolveMethod(popup.parent) orelse continue;
                if (!method.available or !method.enabled) continue;
                const id = self.popupId(popup);
                var pending = false;
                for (self.outbound) |out| {
                    if (out.active and out.kind == .popup_rectangle and
                        std.meta.eql(out.popup, id))
                    {
                        pending = true;
                        break;
                    }
                }
                if (!pending) needed += 1;
            }
            if (!self.canEnqueue(needed)) return error.Exhausted;
            self.normalizeSequence(needed);
            for (self.popups.entries.items) |popup| {
                if (!popup.header.active or popup.surface == null or
                    !std.meta.eql(popup.surface.?, surface)) continue;
                const method = self.resolveMethod(popup.parent) orelse continue;
                if (!method.available or !method.enabled) continue;
                const id = self.popupId(popup);
                var pending: ?*Out = null;
                for (self.outbound) |*out| {
                    if (out.active and out.kind == .popup_rectangle and
                        std.meta.eql(out.popup, id))
                    {
                        pending = out;
                        break;
                    }
                }
                if (pending) |out| {
                    out.x = rectangle.x;
                    out.y = rectangle.y;
                    out.width = rectangle.width;
                    out.height = rectangle.height;
                    continue;
                }
                var out: *Out = undefined;
                for (self.outbound) |*candidate| if (!candidate.active) {
                    out = candidate;
                    break;
                };
                const storage = out.storage;
                out.* = .{
                    .active = true,
                    .sequence = self.next_sequence,
                    .peer = popup.peer,
                    .method = popup.parent,
                    .popup = id,
                    .kind = .popup_rectangle,
                    .x = rectangle.x,
                    .y = rectangle.y,
                    .width = rectangle.width,
                    .height = rectangle.height,
                    .storage = storage,
                };
                self.next_sequence += 1;
                self.out_len += 1;
            }
            return needed;
        }
        pub fn pendingOutboundOn(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active and same(o.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, h: objects.Handle, o: objects.Object) bool {
            if (o.interface == &Method.info) {
                const m = self.methods.fromContext(o.context) orelse return false;
                if (!std.meta.eql(m.resource, h)) return false;
                self.releaseMethod(m);
                return true;
            }
            if (o.interface == &Manager.info) {
                const m = self.managers.fromContext(o.context) orelse return false;
                if (!std.meta.eql(m.resource, h)) return false;
                self.managers.release(m);
                return true;
            }
            if (o.interface == &Popup.info) {
                const popup = self.popups.fromContext(o.context) orelse return false;
                if (!std.meta.eql(popup.resource, h)) return false;
                self.releasePopup(popup);
                return true;
            }
            if (o.interface == &Grab.info) {
                const c = self.grabs.fromContext(o.context) orelse return false;
                if (!std.meta.eql(c.resource, h)) return false;
                self.releaseGrab(c);
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.methods.entries.items) |m| if (m.header.active and same(m.peer, peer)) self.releaseMethod(m);
            for (self.managers.entries.items) |m| if (m.header.active and same(m.peer, peer)) self.managers.release(m);
            for (self.popups.entries.items) |c| if (c.header.active and same(c.peer, peer)) self.releasePopup(c);
            for (self.grabs.entries.items) |c| if (c.header.active and same(c.peer, peer)) self.releaseGrab(c);
            for (self.outbound) |*o| if (o.active and same(o.peer, peer)) self.dropOut(o);
        }

        pub fn surfaceRemoved(self: *Self, id: CoreSurface.SurfaceId) void {
            for (self.popups.entries.items) |popup| {
                if (popup.header.active and popup.surface != null and
                    std.meta.eql(popup.surface.?, id))
                {
                    const popup_id = self.popupId(popup);
                    for (self.outbound) |*out| if (out.active and
                        std.meta.eql(out.popup, popup_id)) self.dropOut(out);
                    popup.surface = null;
                }
            }
        }

        fn acquireMethod(self: *Self) !*MethodSlot {
            return self.methods.acquire();
        }
        fn releaseMethod(self: *Self, m: *MethodSlot) void {
            if (!m.header.active) return;
            for (self.outbound) |*o| if (o.active and std.meta.eql(o.method, self.methodId(m))) self.dropOut(o);
            for (self.popups.entries.items) |c| {
                if (c.header.active and std.meta.eql(c.parent, self.methodId(m))) c.parent.generation = 0;
            }
            for (self.grabs.entries.items) |c| {
                if (c.header.active and std.meta.eql(c.parent, self.methodId(m))) {
                    const id: GrabId = .{ .index = c.header.index, .generation = c.header.generation };
                    self.retireGrabOutbound(id);
                    if (self.active_grab != null and std.meta.eql(self.active_grab.?, id)) self.active_grab = null;
                    c.parent.generation = 0;
                }
            }
            self.methods.release(m);
            self.promoteGrab();
        }
        fn resolveGrab(self: *Self, id: GrabId) ?*Child {
            if (id.index >= self.grabs.entries.items.len) return null;
            const c = self.grabs.entries.items[id.index];
            return if (c.header.active and c.header.generation == id.generation) c else null;
        }
        fn liveActiveGrab(self: *Self, id: GrabId) ?*Child {
            if (self.active_grab == null or !std.meta.eql(self.active_grab.?, id)) return null;
            return self.resolveGrab(id);
        }
        fn retireGrabOutbound(self: *Self, id: GrabId) void {
            for (self.outbound) |*o| if (o.active and std.meta.eql(o.grab, id)) self.dropOut(o);
        }
        fn releaseGrab(self: *Self, c: *Child) void {
            if (!c.header.active) return;
            const id: GrabId = .{ .index = c.header.index, .generation = c.header.generation };
            self.retireGrabOutbound(id);
            if (self.active_grab != null and std.meta.eql(self.active_grab.?, id)) self.active_grab = null;
            self.grabs.release(c);
            self.promoteGrab();
        }
        fn releasePopup(self: *Self, popup: *Child) void {
            if (!popup.header.active) return;
            const id = self.popupId(popup);
            for (self.outbound) |*out| if (out.active and std.meta.eql(out.popup, id)) self.dropOut(out);
            if (popup.surface) |surface_id| if (self.core.getSurfaceById(surface_id)) |surface|
                surface.role.deactivateObject(popup_role_id) catch {}
            else |_| {};
            self.popups.release(popup);
        }
        fn popupId(_: *const Self, popup: *const Child) PopupId {
            return .{ .index = popup.header.index, .generation = popup.header.generation };
        }
        fn resolvePopup(self: *Self, id: PopupId) ?*Child {
            if (id.index >= self.popups.entries.items.len) return null;
            const popup = self.popups.entries.items[id.index];
            return if (popup.header.active and popup.header.generation == id.generation) popup else null;
        }
        fn findAvailable(self: *Self, seat_key: u32) ?*MethodSlot {
            for (self.methods.entries.items) |m| if (m.header.active and m.available and m.seat_key == seat_key) return m;
            return null;
        }
        fn methodId(self: *const Self, m: *const MethodSlot) MethodId {
            _ = self;
            return .{ .index = m.header.index, .generation = m.header.generation };
        }
        fn resolveMethod(self: *Self, id: MethodId) ?*MethodSlot {
            if (id.index >= self.methods.entries.items.len) return null;
            const m = self.methods.entries.items[id.index];
            return if (m.header.active and m.header.generation == id.generation) m else null;
        }
        fn canEnqueue(self: *const Self, n: usize) bool {
            return self.outbound.len - self.out_len >= n and (self.next_sequence <= std.math.maxInt(u64) - n or self.out_len == 0);
        }
        fn normalizeSequence(self: *Self, n: usize) void {
            if (self.next_sequence > std.math.maxInt(u64) - n) {
                std.debug.assert(self.out_len == 0);
                self.next_sequence = 1;
            }
        }
        fn issueGrabOrder(self: *Self) !u64 {
            if (self.grab_clock == std.math.maxInt(u64)) return error.Exhausted;
            const order = self.grab_clock;
            self.grab_clock += 1;
            return order;
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
    const S = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        pub fn getSurfaceById(_: *@This(), _: SurfaceId) error{StaleSurface}!*surface_state.Surface {
            return error.StaleSurface;
        }
    };
    const T = struct {
        pub const DeviceId = packed struct { index: u32, generation: u32 };
        pub const Event = struct { device: DeviceId, peer: wayring.io_uring.Peer, seat: u32, state: struct { enabled: bool, has_surrounding: bool = false, cursor: i32 = 0, anchor: i32 = 0, cause: u32 = 0, has_content_type: bool = false, hints: u32 = 0, purpose: u32 = 0 }, surrounding: []const u8 = "", serial: u32 = 0 };
        calls: usize = 0,
        pub fn queueEdit(self: *@This(), _: DeviceId, _: anytype) !void {
            self.calls += 1;
        }
    };
    const A = Adapter(@import("core_protocol"), S, T);
    var surfaces: S = .{};
    var ti: T = .{};
    const validator: SeatValidator = .{ .resolveFn = struct {
        fn f(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) ?u32 {
            return 7;
        }
    }.f };
    var a = try A.init(std.testing.allocator, &surfaces, &ti, validator, .{ .manager_capacity = 1, .method_capacity = 1, .popup_capacity = 1, .grab_capacity = 1, .outbound_capacity = 12, .string_bytes = 16 });
    defer a.deinit();
    const manager_one = try a.managers.acquire();
    const manager_two = try a.managers.acquire();
    try std.testing.expect(a.managers.fromContext(manager_one) == manager_one);
    try std.testing.expect(manager_one != manager_two);
    const popup_one = try a.popups.acquire();
    const popup_two = try a.popups.acquire();
    try std.testing.expect(a.popups.fromContext(popup_one) == popup_one);
    try std.testing.expect(popup_one != popup_two);
    const one = try a.acquireMethod();
    one.peer = .{ .slot = 1, .generation = 1 };
    one.seat_key = 7;
    one.available = true;
    const old = a.methodId(one);
    const two = try a.acquireMethod();
    try std.testing.expect(a.methods.fromContext(one) == one);
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
    a.releaseMethod(one);
    const reused = try a.acquireMethod();
    try std.testing.expect(old.generation != a.methodId(reused).generation);
    a.disconnected(one.peer);
}

test "input method keyboard grab orders sync, excludes stale generations, and promotes oldest waiter" {
    const S = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        pub fn getSurfaceById(_: *@This(), _: SurfaceId) error{StaleSurface}!*surface_state.Surface {
            return error.StaleSurface;
        }
    };
    const T = struct {
        pub const DeviceId = packed struct { index: u32, generation: u32 };
        pub const Event = struct { device: DeviceId, state: struct { enabled: bool }, surrounding: []const u8 = "" };
        pub fn queueEdit(_: *@This(), _: DeviceId, _: anytype) !void {}
    };
    const A = Adapter(@import("core_protocol"), S, T);
    var surfaces: S = .{};
    var ti: T = .{};
    var a = try A.init(std.testing.allocator, &surfaces, &ti, .{ .resolveFn = struct {
        fn f(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) ?u32 {
            return 9;
        }
    }.f }, .{ .manager_capacity = 1, .method_capacity = 1, .popup_capacity = 1, .grab_capacity = 1, .outbound_capacity = 8, .string_bytes = 8 });
    defer a.deinit();

    const method = try a.acquireMethod();
    method.available = true;
    method.seat_key = 9;
    method.peer = .{ .slot = 1, .generation = 1 };
    const first = try a.grabs.acquire();
    first.parent = a.methodId(method);
    first.peer = method.peer;
    first.order = 1;
    const second = try a.grabs.acquire();
    try std.testing.expect(a.grabs.fromContext(first) == first);
    second.parent = a.methodId(method);
    second.peer = method.peer;
    second.order = 2;
    a.setKeyboardProvider(.{
        .snapshotFn = struct {
            fn snapshot(_: ?*anyopaque, seat: u32) KeyboardSnapshot {
                std.debug.assert(seat == 9);
                return .{ .keymap_size = 12, .repeat_rate = 25, .repeat_delay = 600, .modifiers = .{ .serial = 4 } };
            }
        }.snapshot,
        .duplicateKeymapFn = struct {
            fn duplicate(_: ?*anyopaque, _: u32) !linux.fd_t {
                const duplicated = linux.dup(0);
                if (linux.errno(duplicated) != .SUCCESS) return error.DuplicateFailed;
                return @intCast(duplicated);
            }
        }.duplicate,
    });
    const old = a.activeGrab().?;
    try std.testing.expectEqual(@as(u32, 0), old.index);
    try std.testing.expectEqual(A.OutKind.grab_keymap, a.oldest(method.peer).?.kind);
    try a.queueKey(old, 7, 8, 30, 1);
    a.releaseGrab(first);
    const promoted = a.activeGrab().?;
    try std.testing.expectEqual(@as(u32, 1), promoted.index);
    try std.testing.expectError(error.StaleGrab, a.queueKey(old, 9, 10, 30, 0));
    try a.queueModifiers(promoted, .{ .serial = 11, .depressed = 2 });
    a.releaseGrab(second);
    try std.testing.expect(a.activeGrab() == null);
}
