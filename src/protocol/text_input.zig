//! Standalone bounded text-input-unstable-v3 adapter.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Focus = struct { peer: wayring.io_uring.Peer, surface: u32 };
pub const SeatValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) bool,
    pub fn validate(v: @This(), p: wayring.io_uring.Peer, seat: u32) bool {
        return v.validateFn(v.context, p, seat);
    }
};
pub const Config = struct {
    manager_capacity: usize = 4,
    device_capacity: usize = 8,
    event_capacity: usize = 16,
    outbound_capacity: usize = 32,
    surrounding_bytes: usize = 4000,
    edit_string_bytes: usize = 4000,
    language_bytes: usize = 64,
    fn validate(c: @This()) !void {
        inline for (.{ c.manager_capacity, c.device_capacity, c.event_capacity, c.outbound_capacity, c.surrounding_bytes, c.edit_string_bytes, c.language_bytes }) |n| if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.surrounding_bytes > 4000) return error.InvalidConfig;
    }
};
pub const Rectangle = struct { x: i32 = 0, y: i32 = 0, width: i32 = 0, height: i32 = 0 };
pub const State = struct {
    enabled: bool = false,
    has_surrounding: bool = false,
    surrounding_len: usize = 0,
    cursor: i32 = 0,
    anchor: i32 = 0,
    cause: u32 = 0,
    has_content_type: bool = false,
    hints: u32 = 0,
    purpose: u32 = 0,
    has_rectangle: bool = false,
    rectangle: Rectangle = .{},
    submit_available: bool = false,
    input_panel_visible: bool = false,
};
pub const PreeditHintKind = enum(u32) { whole = 1, selection, prediction, prefix, suffix, spelling_error, compose_error };
pub const PreeditHint = struct { start: u32, end: u32, hint: PreeditHintKind };
pub const Edit = struct { preedit: ?[]const u8 = null, cursor_begin: i32 = 0, cursor_end: i32 = 0, hints: []const PreeditHint = &.{}, commit: ?[]const u8 = null, delete_before: u32 = 0, delete_after: u32 = 0 };

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_text_input_manager_v3;
        const Input = protocol.zwp_text_input_v3;
        pub const DeviceId = packed struct { index: u32, generation: u32 };
        pub const Event = struct { device: DeviceId, peer: wayring.io_uring.Peer, seat: u32, state: State, surrounding: []const u8, serial: u32 };
        const ManagerSlot = struct { header: slot_pool.Header = .{}, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, version: u32 = 1 };
        const Device = struct { header: slot_pool.Header = .{}, focused: bool = false, resource: objects.Handle = .{ .id = 0, .generation = 0 }, peer: wayring.io_uring.Peer = undefined, seat: u32 = 0, version: u32 = 1, pending: State = .{}, current: State = .{}, serial: u32 = 0, text: []u8 = &.{}, pending_text: []u8 = &.{} };
        const EventSlot = struct { event: Event = undefined, text: []u8 = &.{} };
        const OutKind = enum { enter, leave, preedit, preedit_hint, commit, delete, action, language, done };
        const Out = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            device: DeviceId = undefined,
            kind: OutKind = .enter,
            surface: u32 = 0,
            text_len: usize = 0,
            cursor_begin: i32 = 0,
            cursor_end: i32 = 0,
            delete_before: u32 = 0,
            delete_after: u32 = 0,
            serial: u32 = 0,
            start: u32 = 0,
            end: u32 = 0,
            value: u32 = 0,
            storage: []u8 = &.{},
        };
        allocator: std.mem.Allocator,
        validator: SeatValidator,
        managers: slot_pool.Pool(ManagerSlot),
        devices: slot_pool.Pool(Device),
        events: []EventSlot,
        outbound: []Out,
        all_event_text: []u8,
        all_out_text: []u8,
        language: []u8,
        language_len: usize = 0,
        language_known: bool = false,
        surrounding_bytes: usize,
        edit_bytes: usize,
        event_head: usize = 0,
        event_len: usize = 0,
        out_len: usize = 0,
        next_sequence: u64 = 1,
        focus: ?Focus = null,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        pub fn init(a: std.mem.Allocator, v: SeatValidator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(2);
            var ms = try slot_pool.Pool(ManagerSlot).init(a, c.manager_capacity);
            errdefer ms.deinit();
            var ds = try slot_pool.Pool(Device).init(a, c.device_capacity);
            errdefer ds.deinit();
            const es = try a.alloc(EventSlot, c.event_capacity);
            errdefer a.free(es);
            const os = try a.alloc(Out, c.outbound_capacity);
            errdefer a.free(os);
            const event_text_bytes = try std.math.mul(usize, c.event_capacity, c.surrounding_bytes);
            const outbound_text_bytes = try std.math.mul(usize, c.outbound_capacity, c.edit_string_bytes);
            const et = try a.alloc(u8, event_text_bytes);
            errdefer a.free(et);
            const ot = try a.alloc(u8, outbound_text_bytes);
            errdefer a.free(ot);
            const language = try a.alloc(u8, c.language_bytes);
            errdefer a.free(language);
            for (es, 0..) |*s, i| s.text = et[i * c.surrounding_bytes ..][0..c.surrounding_bytes];
            for (os, 0..) |*s, i| {
                s.* = .{};
                s.storage = ot[i * c.edit_string_bytes ..][0..c.edit_string_bytes];
            }
            return .{ .allocator = a, .validator = v, .managers = ms, .devices = ds, .events = es, .outbound = os, .all_event_text = et, .all_out_text = ot, .language = language, .surrounding_bytes = c.surrounding_bytes, .edit_bytes = c.edit_string_bytes };
        }
        pub fn deinit(s: *Self) void {
            s.allocator.free(s.all_out_text);
            s.allocator.free(s.all_event_text);
            s.allocator.free(s.language);
            for (s.devices.entries.items) |device| {
                if (device.text.len != 0) s.allocator.free(device.text);
                if (device.pending_text.len != 0) s.allocator.free(device.pending_text);
            }
            s.allocator.free(s.outbound);
            s.allocator.free(s.events);
            s.devices.deinit();
            s.managers.deinit();
            s.* = undefined;
        }
        pub fn install(s: *Self, r: *Runtime) !objects.Handle {
            if (s.runtime != null) return error.AlreadyInstalled;
            s.runtime = r;
            errdefer s.runtime = null;
            const g = try r.addGlobalWithBinder(&Manager.info, 2, s, bind);
            s.global = g;
            return g;
        }
        fn bind(ctx: ?*anyopaque, b: wayring.server.Binding) !?*anyopaque {
            const s: *Self = @ptrCast(@alignCast(ctx.?));
            const manager = try s.managers.acquire();
            manager.resource = b.resource;
            manager.peer = b.peer;
            manager.version = b.version;
            return manager;
        }
        pub fn request(s: *Self, p: wayring.io_uring.Peer, t: objects.Dispatch, m: wayring.wire.Message, f: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = s.runtime orelse return error.NotInstalled;
            return s.requestOn(try r.clients.reactor.getActor(p), try r.clients.get(p), p, t, m, f);
        }
        pub fn requestOn(s: *Self, a: *wayring.connection.Actor, so: anytype, p: wayring.io_uring.Peer, t: objects.Dispatch, m: wayring.wire.Message, f: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const h = so.namespace.lookupHandle(m.header.object_id) orelse return null;
            if (t.object.interface == &Manager.info) {
                const x = s.managers.fromContext(t.object.context) orelse return null;
                if (!std.meta.eql(x.resource, h) or !same(x.peer, p)) return null;
                const d = try wayring.server.decodeRequest(Manager, so, m, f);
                switch (d.value) {
                    .destroy => {},
                    .get_text_input => |q| {
                        if (!s.validator.validate(p, q.seat)) return try s.protocolError(a, d.handle.id, 0, "invalid wl_seat");
                        const outbound_needed = @as(usize, @intFromBool(s.focus != null and same(s.focus.?.peer, p))) +
                            @as(usize, @intFromBool(x.version >= 2 and s.language_known));
                        if (!s.canEnqueue(outbound_needed))
                            return try s.noMemory(a);
                        const z = s.acquire() catch return try s.noMemory(a);
                        z.peer = p;
                        z.seat = q.seat;
                        z.version = x.version;
                        const admitted = Manager.admit_get_text_input(so, d.handle, q, .{ .id = z }) catch |e| {
                            s.release(z);
                            return try s.failure(a, d.handle.id, e);
                        };
                        z.resource = admitted.id;
                        if (s.focus != null and same(s.focus.?.peer, p)) {
                            z.focused = true;
                            try s.enqueue(z, .enter, s.focus.?.surface, null);
                        }
                        if (z.version >= 2 and s.language_known)
                            try s.enqueue(z, .language, 0, .{ .text = s.language[0..s.language_len] });
                    },
                }
                try d.finish(protocol, so, &a.transmit);
                return .continue_dispatch;
            }
            if (t.object.interface == &Input.info) {
                const z = s.devices.fromContext(t.object.context) orelse return null;
                if (!std.meta.eql(z.resource, h) or !same(z.peer, p)) return null;
                const d = try wayring.server.decodeRequest(Input, so, m, f);
                switch (d.value) {
                    .destroy => {},
                    .enable => {
                        if (!z.focused) {
                            try d.finish(protocol, so, &a.transmit);
                            return .continue_dispatch;
                        }
                        z.pending = .{};
                        z.pending.enabled = true;
                        z.current.input_panel_visible = false;
                    },
                    .disable => {
                        if (z.focused) {
                            z.pending.enabled = false;
                            z.pending.input_panel_visible = false;
                            z.current.input_panel_visible = false;
                        }
                    },
                    .set_surrounding_text => |q| {
                        if (!z.focused) {
                            try d.finish(protocol, so, &a.transmit);
                            return .continue_dispatch;
                        }
                        s.setSurrounding(z, q.text, q.cursor, q.anchor) catch return try s.protocolError(a, d.handle.id, 0, "invalid surrounding text");
                    },
                    .set_text_change_cause => |q| if (z.focused) {
                        z.pending.cause = q.cause.value;
                    },
                    .set_content_type => |q| {
                        if (z.focused) {
                            z.pending.has_content_type = true;
                            z.pending.hints = q.hint.value;
                            z.pending.purpose = q.purpose.value;
                        }
                    },
                    .set_cursor_rectangle => |q| {
                        if (z.focused) {
                            z.pending.has_rectangle = true;
                            z.pending.rectangle = .{ .x = q.x, .y = q.y, .width = q.width, .height = q.height };
                        }
                    },
                    .commit => s.commit(z) catch return try s.noMemory(a),
                    .set_available_actions => |q| {
                        const submit = parseAvailableActions(q.available_actions) catch
                            return try s.protocolError(
                                a,
                                d.handle.id,
                                Input.@"error".invalid_action.value,
                                "invalid or duplicate text-input action",
                            );
                        if (z.focused) z.pending.submit_available = submit;
                    },
                    .show_input_panel => if (z.focused) {
                        setInputPanelVisible(z, true);
                    },
                    .hide_input_panel => if (z.focused) {
                        setInputPanelVisible(z, false);
                    },
                }
                try d.finish(protocol, so, &a.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        fn setInputPanelVisible(z: *Device, visible: bool) void {
            z.pending.input_panel_visible = visible;
            z.current.input_panel_visible = visible;
        }
        fn setSurrounding(s: *Self, z: *Device, text: []const u8, c: i32, a: i32) !void {
            if (text.len > s.surrounding_bytes or text.len > 4000 or !std.unicode.utf8ValidateSlice(text) or c < 0 or a < 0 or c > text.len or a > text.len or !boundary(text, @intCast(c)) or !boundary(text, @intCast(a))) return error.Invalid;
            @memcpy(z.pending_text[0..text.len], text);
            z.pending.has_surrounding = true;
            z.pending.surrounding_len = text.len;
            z.pending.cursor = c;
            z.pending.anchor = a;
        }
        fn commit(s: *Self, z: *Device) !void {
            z.serial +%= 1;
            if (!z.focused) return;
            if (s.event_len == s.events.len) return error.Exhausted;
            if (z.pending.enabled) {
                for (s.devices.entries.items) |other| {
                    if (other != z and other.header.active and other.focused and other.current.enabled and
                        same(other.peer, z.peer) and other.seat == z.seat)
                    {
                        z.pending.enabled = false;
                        break;
                    }
                }
            }
            z.current = z.pending;
            if (!z.current.enabled) {
                z.current = .{};
                z.pending = .{};
            }
            @memcpy(z.text[0..z.current.surrounding_len], z.pending_text[0..z.current.surrounding_len]);
            const e = &s.events[(s.event_head + s.event_len) % s.events.len];
            @memcpy(e.text[0..z.current.surrounding_len], z.text[0..z.current.surrounding_len]);
            e.event = .{ .device = s.id(z), .peer = z.peer, .seat = z.seat, .state = z.current, .surrounding = e.text[0..z.current.surrounding_len], .serial = z.serial };
            s.event_len += 1;
            z.pending.cause = 0;
        }
        pub fn peekEvent(s: *const Self) ?*const Event {
            return if (s.event_len == 0) null else &s.events[s.event_head].event;
        }
        pub fn dropEvent(s: *Self) void {
            if (s.event_len > 0) {
                s.event_head = (s.event_head + 1) % s.events.len;
                s.event_len -= 1;
            }
        }
        pub fn validateFocus(s: *const Self, f: ?Focus) !void {
            if (focusEq(s.focus, f)) return;
            var need: usize = 0;
            for (s.devices.entries.items) |z| if (z.header.active) {
                if (s.focus != null and same(z.peer, s.focus.?.peer)) need += 1;
                if (f != null and same(z.peer, f.?.peer)) need += 1;
            };
            if (!s.canEnqueue(need)) return error.Exhausted;
        }
        pub fn setFocus(s: *Self, f: ?Focus) !void {
            if (focusEq(s.focus, f)) return;
            try s.validateFocus(f);
            if (s.focus) |old| {
                for (s.devices.entries.items) |z| {
                    if (z.header.active and same(z.peer, old.peer)) {
                        try s.enqueue(z, .leave, old.surface, null);
                        z.focused = false;
                        z.pending = .{};
                        z.current = .{};
                    }
                }
            }
            s.focus = f;
            if (f) |new| {
                for (s.devices.entries.items) |z| {
                    if (z.header.active and same(z.peer, new.peer)) {
                        try s.enqueue(z, .enter, new.surface, null);
                        z.focused = true;
                        z.pending = .{};
                        z.current = .{};
                    }
                }
            }
        }
        pub fn queueEdit(s: *Self, device_id: DeviceId, e: Edit) !void {
            const z = s.resolve(device_id) orelse return error.StaleDevice;
            if (!z.focused or !z.current.enabled or s.focus == null or !same(z.peer, s.focus.?.peer))
                return error.NotFocused;
            if ((e.preedit != null and e.preedit.?.len > s.edit_bytes) or
                (e.commit != null and e.commit.?.len > s.edit_bytes)) return error.StringTooLong;
            var valid_hints: usize = 0;
            if (z.version >= 2 and e.preedit != null) {
                for (e.hints) |hint|
                    valid_hints += @intFromBool(validPreeditHint(e.preedit.?, hint));
            }
            const need: usize = @as(usize, @intFromBool(e.preedit != null)) +
                valid_hints +
                @as(usize, @intFromBool(e.commit != null)) +
                @as(usize, @intFromBool(e.delete_before != 0 or e.delete_after != 0)) + 1;
            if (!s.canEnqueue(need)) return error.Exhausted;
            if (e.preedit) |text| try s.enqueue(z, .preedit, 0, .{
                .text = text,
                .cursor_begin = e.cursor_begin,
                .cursor_end = e.cursor_end,
            });
            if (z.version >= 2 and e.preedit != null) for (e.hints) |hint| {
                if (!validPreeditHint(e.preedit.?, hint)) continue;
                try s.enqueue(z, .preedit_hint, 0, .{
                    .start = hint.start,
                    .end = hint.end,
                    .value = @intFromEnum(hint.hint),
                });
            };
            if (e.commit) |text| try s.enqueue(z, .commit, 0, .{ .text = text });
            if (e.delete_before != 0 or e.delete_after != 0) try s.enqueue(z, .delete, 0, .{
                .delete_before = e.delete_before,
                .delete_after = e.delete_after,
            });
            try s.enqueue(z, .done, 0, .{ .serial = z.serial });
        }

        pub fn queueSubmit(s: *Self, device_id: DeviceId, serial: u32) !void {
            const z = s.resolve(device_id) orelse return error.StaleDevice;
            if (z.version < 2 or !z.focused or !z.current.enabled or
                !z.current.submit_available) return error.ActionUnavailable;
            if (serial == 0) return error.InvalidSerial;
            if (!s.canEnqueue(2)) return error.Exhausted;
            try s.enqueue(z, .action, 0, .{
                .value = Input.action.submit.value,
                .serial = serial,
            });
            try s.enqueue(z, .done, 0, .{ .serial = z.serial });
        }

        pub fn setLanguage(s: *Self, language: []const u8) !void {
            if (language.len > s.language.len or std.mem.indexOfScalar(u8, language, 0) != null)
                return error.InvalidLanguage;
            var needed: usize = 0;
            for (s.devices.entries.items) |z|
                needed += @intFromBool(z.header.active and z.version >= 2);
            if (!s.canEnqueue(needed)) return error.Exhausted;
            @memcpy(s.language[0..language.len], language);
            s.language_len = language.len;
            s.language_known = true;
            for (s.devices.entries.items) |z| {
                if (!z.header.active or z.version < 2) continue;
                try s.enqueue(z, .language, 0, .{ .text = language });
            }
        }

        pub fn state(s: *Self, device_id: DeviceId) !State {
            const z = s.resolve(device_id) orelse return error.StaleDevice;
            return z.current;
        }
        const OutPayload = struct {
            text: ?[]const u8 = null,
            cursor_begin: i32 = 0,
            cursor_end: i32 = 0,
            delete_before: u32 = 0,
            delete_after: u32 = 0,
            serial: u32 = 0,
            start: u32 = 0,
            end: u32 = 0,
            value: u32 = 0,
        };
        fn enqueue(s: *Self, z: *Device, k: OutKind, surface: u32, payload: ?OutPayload) !void {
            if (s.out_len == s.outbound.len) return error.Exhausted;
            if (s.next_sequence == std.math.maxInt(u64)) {
                if (s.out_len != 0) return error.SequenceExhausted;
                s.next_sequence = 1;
            }
            var o: *Out = undefined;
            for (s.outbound) |*x| {
                if (!x.active) {
                    o = x;
                    break;
                }
            }
            const storage = o.storage;
            o.* = .{ .active = true, .sequence = s.next_sequence, .peer = z.peer, .device = s.id(z), .kind = k, .surface = surface, .storage = storage };
            s.next_sequence +%= 1;
            if (payload) |value| {
                if (value.text) |text| {
                    @memcpy(o.storage[0..text.len], text);
                    o.text_len = text.len;
                }
                o.cursor_begin = value.cursor_begin;
                o.cursor_end = value.cursor_end;
                o.delete_before = value.delete_before;
                o.delete_after = value.delete_after;
                o.serial = value.serial;
                o.start = value.start;
                o.end = value.end;
                o.value = value.value;
            }
            s.out_len += 1;
        }
        pub fn flushOn(s: *Self, p: wayring.io_uring.Peer, so: anytype, q: *wayring.tx.Queue) !usize {
            var n: usize = 0;
            while (s.oldest(p)) |o| {
                const z = s.resolve(o.device) orelse {
                    s.dropOut(o);
                    continue;
                };
                const ev: Input.Event = switch (o.kind) {
                    .enter => .{ .enter = .{ .surface = o.surface } },
                    .leave => .{ .leave = .{ .surface = o.surface } },
                    .preedit => .{ .preedit_string = .{
                        .text = o.storage[0..o.text_len],
                        .cursor_begin = o.cursor_begin,
                        .cursor_end = o.cursor_end,
                    } },
                    .preedit_hint => .{ .preedit_hint = .{
                        .start = o.start,
                        .end = o.end,
                        .hint = Input.preedit_hint.fromInt(o.value),
                    } },
                    .commit => .{ .commit_string = .{ .text = o.storage[0..o.text_len] } },
                    .delete => .{ .delete_surrounding_text = .{
                        .before_length = o.delete_before,
                        .after_length = o.delete_after,
                    } },
                    .action => .{ .action = .{
                        .action = Input.action.fromInt(o.value),
                        .serial = o.serial,
                    } },
                    .language => .{ .language = .{ .language = o.storage[0..o.text_len] } },
                    .done => .{ .done = .{ .serial = o.serial } },
                };
                wayring.server.sendEvent(protocol, Input, so, q, z.resource, ev) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return n,
                    else => return err,
                };
                s.dropOut(o);
                n += 1;
            }
            return n;
        }
        pub fn pendingOutboundOn(s: *const Self, p: wayring.io_uring.Peer) bool {
            for (s.outbound) |o| if (o.active and same(o.peer, p)) return true;
            return false;
        }
        pub fn resourceRemoved(s: *Self, h: objects.Handle, o: objects.Object) bool {
            if (o.interface == &Input.info) {
                const z = s.devices.fromContext(o.context) orelse return false;
                if (!std.meta.eql(z.resource, h)) return false;
                s.release(z);
                return true;
            }
            if (o.interface == &Manager.info) {
                const z = s.managers.fromContext(o.context) orelse return false;
                if (!std.meta.eql(z.resource, h)) return false;
                s.releaseManager(z);
                return true;
            }
            return false;
        }
        pub fn disconnected(s: *Self, p: wayring.io_uring.Peer) void {
            for (s.devices.entries.items) |z| if (z.header.active and same(z.peer, p)) s.release(z);
            for (s.managers.entries.items) |z| {
                if (z.header.active and same(z.peer, p)) s.releaseManager(z);
            }
            if (s.focus) |f| {
                if (same(f.peer, p)) s.focus = null;
            }
            s.removePeerEvents(p);
            for (s.outbound) |*o| if (o.active and same(o.peer, p)) s.dropOut(o);
        }
        fn acquire(s: *Self) !*Device {
            const z = try s.devices.acquire();
            if (z.text.len == 0) {
                z.text = s.allocator.alloc(u8, s.surrounding_bytes) catch |err| {
                    s.devices.release(z);
                    return err;
                };
                z.pending_text = s.allocator.alloc(u8, s.surrounding_bytes) catch |err| {
                    s.allocator.free(z.text);
                    z.text = &.{};
                    s.devices.release(z);
                    return err;
                };
            }
            return z;
        }
        fn releaseManager(s: *Self, z: *ManagerSlot) void {
            if (z.header.active) s.managers.release(z);
        }
        fn release(s: *Self, z: *Device) void {
            if (!z.header.active) return;
            for (s.outbound) |*o| if (o.active and o.device.index == z.header.index and o.device.generation == z.header.generation) s.dropOut(o);
            s.allocator.free(z.text);
            s.allocator.free(z.pending_text);
            s.devices.release(z);
        }
        fn id(s: *const Self, z: *const Device) DeviceId {
            _ = s;
            return .{ .index = z.header.index, .generation = z.header.generation };
        }
        fn resolve(s: *Self, device_id: DeviceId) ?*Device {
            const z = s.devices.at(device_id.index) orelse return null;
            return if (z.header.generation == device_id.generation) z else null;
        }
        fn oldest(s: *Self, p: wayring.io_uring.Peer) ?*Out {
            var result: ?*Out = null;
            for (s.outbound) |*o| {
                if (o.active and same(o.peer, p) and (result == null or o.sequence < result.?.sequence)) result = o;
            }
            return result;
        }
        fn availableOutbound(s: *const Self) usize {
            return s.outbound.len - s.out_len;
        }
        fn canEnqueue(s: *const Self, count: usize) bool {
            return s.availableOutbound() >= count and
                (s.next_sequence != std.math.maxInt(u64) or s.out_len == 0);
        }
        fn dropOut(s: *Self, o: *Out) void {
            if (o.active) {
                o.active = false;
                s.out_len -= 1;
            }
        }
        fn removePeerEvents(s: *Self, p: wayring.io_uring.Peer) void {
            var n: usize = 0;
            for (0..s.event_len) |i| {
                const source = &s.events[(s.event_head + i) % s.events.len];
                if (!same(source.event.peer, p)) {
                    const destination = &s.events[(s.event_head + n) % s.events.len];
                    const len = source.event.surrounding.len;
                    if (destination != source) @memcpy(destination.text[0..len], source.event.surrounding);
                    destination.event = source.event;
                    destination.event.surrounding = destination.text[0..len];
                    n += 1;
                }
            }
            s.event_len = n;
        }
        fn noMemory(_: *Self, a: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(a, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, a: *wayring.connection.Actor, id_: u32, code: u32, msg: []const u8) !wayring.dispatch.Control {
            try Core.postError(a, id_, code, msg);
            return .stop;
        }
        fn failure(s: *Self, a: *wayring.connection.Actor, id_: u32, e: anyerror) !wayring.dispatch.Control {
            _ = s;
            try Core.postError(a, id_, 0, @errorName(e));
            return .stop;
        }
    };
}
fn same(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn focusEq(a: ?Focus, b: ?Focus) bool {
    if (a == null or b == null) return a == null and b == null;
    return same(a.?.peer, b.?.peer) and a.?.surface == b.?.surface;
}
fn boundary(s: []const u8, i: usize) bool {
    return i == s.len or (s[i] & 0xc0) != 0x80;
}
fn parseAvailableActions(bytes: []const u8) !bool {
    if (bytes.len % @sizeOf(u32) != 0) return error.InvalidAction;
    var submit = false;
    var offset: usize = 0;
    while (offset < bytes.len) : (offset += @sizeOf(u32)) {
        const action = std.mem.readInt(
            u32,
            bytes[offset..][0..@sizeOf(u32)],
            @import("builtin").cpu.arch.endian(),
        );
        if (action == 0) return error.InvalidAction;
        var prior: usize = 0;
        while (prior < offset) : (prior += @sizeOf(u32)) {
            if (action == std.mem.readInt(
                u32,
                bytes[prior..][0..@sizeOf(u32)],
                @import("builtin").cpu.arch.endian(),
            )) return error.InvalidAction;
        }
        submit = submit or action == 1;
    }
    return submit;
}
fn validPreeditHint(text: []const u8, hint: PreeditHint) bool {
    return hint.start <= hint.end and hint.end <= text.len and
        boundary(text, hint.start) and boundary(text, hint.end);
}
test "text input transactional bounded state" {
    const A = Adapter(@import("core_protocol"));
    const v: SeatValidator = .{ .validateFn = struct {
        fn f(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.f };
    var a = try A.init(std.testing.allocator, v, .{ .device_capacity = 1, .event_capacity = 1, .manager_capacity = 1, .outbound_capacity = 2, .surrounding_bytes = 8, .edit_string_bytes = 8 });
    defer a.deinit();
    const z = try a.acquire();
    z.peer = .{ .slot = 1, .generation = 2 };
    z.seat = 3;
    z.focused = true;
    z.pending.enabled = true;
    try a.setSurrounding(z, "hé", 3, 1);
    try std.testing.expectEqual(@as(usize, 0), z.current.surrounding_len);
    try a.commit(z);
    try std.testing.expectEqualStrings("hé", a.peekEvent().?.surrounding);
    try std.testing.expectEqual(@as(u32, 1), a.peekEvent().?.serial);
    try std.testing.expectError(error.Exhausted, a.commit(z));
    a.dropEvent();
    try std.testing.expectError(error.Invalid, a.setSurrounding(z, "hé", 2, 0));
}
test "text input focus edits and stale generation" {
    const A = Adapter(@import("core_protocol"));
    const v: SeatValidator = .{ .validateFn = struct {
        fn f(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.f };
    var a = try A.init(std.testing.allocator, v, .{ .device_capacity = 1, .event_capacity = 1, .manager_capacity = 1, .outbound_capacity = 3, .surrounding_bytes = 8, .edit_string_bytes = 8 });
    defer a.deinit();
    const z = try a.acquire();
    z.peer = .{ .slot = 1, .generation = 2 };
    const id = a.id(z);
    try a.setFocus(.{ .peer = z.peer, .surface = 9 });
    z.current.enabled = true;
    try a.queueEdit(id, .{ .commit = "x" });
    try std.testing.expect(a.pendingOutboundOn(z.peer));
    a.release(z);
    try std.testing.expect(!a.pendingOutboundOn(z.peer));
    const n = try a.acquire();
    try std.testing.expect(id.generation != a.id(n).generation);
}

test "text input focus replacement preflights every leave and enter" {
    const A = Adapter(@import("core_protocol"));
    const validator: SeatValidator = .{ .validateFn = struct {
        fn validate(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.validate };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .device_capacity = 2,
        .event_capacity = 1,
        .manager_capacity = 1,
        .outbound_capacity = 2,
        .surrounding_bytes = 8,
        .edit_string_bytes = 8,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    for (0..2) |_| {
        const device = try adapter.acquire();
        device.peer = peer;
    }
    try adapter.setFocus(.{ .peer = peer, .surface = 10 });
    for (adapter.outbound) |*out| adapter.dropOut(out);
    try std.testing.expectError(
        error.Exhausted,
        adapter.setFocus(.{ .peer = peer, .surface = 11 }),
    );
    try std.testing.expectEqual(@as(u32, 10), adapter.focus.?.surface);
    try std.testing.expectEqual(@as(usize, 0), adapter.out_len);
    for (adapter.devices.entries.items) |device| try std.testing.expect(device.focused);
}

test "text input manager and device reservations grow without moving contexts" {
    const A = Adapter(@import("core_protocol"));
    const validator: SeatValidator = .{ .validateFn = struct {
        fn validate(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.validate };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .device_capacity = 1,
        .event_capacity = 1,
        .manager_capacity = 1,
        .outbound_capacity = 2,
        .surrounding_bytes = 8,
        .edit_string_bytes = 8,
    });
    defer adapter.deinit();
    const first_device = try adapter.acquire();
    const first_manager = try adapter.managers.acquire();
    const device_address = @intFromPtr(first_device);
    const manager_address = @intFromPtr(first_manager);
    _ = try adapter.acquire();
    _ = try adapter.managers.acquire();
    try std.testing.expectEqual(device_address, @intFromPtr(first_device));
    try std.testing.expectEqual(manager_address, @intFromPtr(first_manager));
}

test "text input edit transaction retains event order and commit serial" {
    const A = Adapter(@import("core_protocol"));
    const validator: SeatValidator = .{ .validateFn = struct {
        fn validate(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.validate };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .device_capacity = 1,
        .event_capacity = 1,
        .manager_capacity = 1,
        .outbound_capacity = 4,
        .surrounding_bytes = 8,
        .edit_string_bytes = 8,
    });
    defer adapter.deinit();
    const device = try adapter.acquire();
    device.peer = .{ .slot = 5, .generation = 6 };
    device.focused = true;
    device.current.enabled = true;
    device.serial = 7;
    adapter.focus = .{ .peer = device.peer, .surface = 12 };
    try adapter.queueEdit(adapter.id(device), .{
        .preedit = "pr",
        .cursor_begin = 1,
        .cursor_end = 2,
        .commit = "c",
        .delete_before = 3,
        .delete_after = 4,
    });
    try std.testing.expectEqual(@as(usize, 4), adapter.out_len);
    const expected = [_]A.OutKind{ .preedit, .commit, .delete, .done };
    for (expected) |kind| {
        const out = adapter.oldest(device.peer).?;
        try std.testing.expectEqual(kind, out.kind);
        if (kind == .done) try std.testing.expectEqual(@as(u32, 7), out.serial);
        adapter.dropOut(out);
    }
}

test "text input disconnect compacts copied event text" {
    const A = Adapter(@import("core_protocol"));
    const validator: SeatValidator = .{ .validateFn = struct {
        fn validate(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.validate };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .device_capacity = 2,
        .event_capacity = 2,
        .manager_capacity = 1,
        .outbound_capacity = 2,
        .surrounding_bytes = 8,
        .edit_string_bytes = 8,
    });
    defer adapter.deinit();
    const removed = try adapter.acquire();
    removed.peer = .{ .slot = 1, .generation = 1 };
    removed.focused = true;
    removed.pending.enabled = true;
    try adapter.setSurrounding(removed, "gone", 4, 4);
    try adapter.commit(removed);
    const retained = try adapter.acquire();
    retained.peer = .{ .slot = 2, .generation = 1 };
    retained.focused = true;
    retained.pending.enabled = true;
    try adapter.setSurrounding(retained, "kept", 4, 4);
    try adapter.commit(retained);
    adapter.disconnected(removed.peer);
    try std.testing.expectEqual(@as(usize, 1), adapter.event_len);
    try std.testing.expectEqualStrings("kept", adapter.peekEvent().?.surrounding);
    @memset(adapter.events[1].text, 0xaa);
    try std.testing.expectEqualStrings("kept", adapter.peekEvent().?.surrounding);
}

test "text input version two actions validate native arrays" {
    var actions = [_]u32{ 9, 1, 12 };
    try std.testing.expect(try parseAvailableActions(std.mem.asBytes(&actions)));
    actions = .{ 9, 12, 13 };
    try std.testing.expect(!try parseAvailableActions(std.mem.asBytes(&actions)));
    actions = .{ 9, 0, 12 };
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(std.mem.asBytes(&actions)));
    actions = .{ 9, 9, 12 };
    try std.testing.expectError(error.InvalidAction, parseAvailableActions(std.mem.asBytes(&actions)));
    try std.testing.expectError(error.InvalidAction, parseAvailableActions("x"));
}

test "text input version two stages language hints panel and submit" {
    const A = Adapter(@import("core_protocol"));
    const validator: SeatValidator = .{ .validateFn = struct {
        fn validate(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
            return true;
        }
    }.validate };
    var adapter = try A.init(std.testing.allocator, validator, .{
        .device_capacity = 1,
        .event_capacity = 1,
        .manager_capacity = 1,
        .outbound_capacity = 8,
        .surrounding_bytes = 8,
        .edit_string_bytes = 8,
    });
    defer adapter.deinit();
    const device = try adapter.acquire();
    device.peer = .{ .slot = 7, .generation = 3 };
    device.version = 2;
    device.focused = true;
    device.current.enabled = true;
    device.current.submit_available = true;
    adapter.focus = .{ .peer = device.peer, .surface = 11 };

    A.setInputPanelVisible(device, true);
    try std.testing.expect((try adapter.state(adapter.id(device))).input_panel_visible);
    A.setInputPanelVisible(device, false);
    try adapter.setLanguage("en-US");
    try adapter.queueEdit(adapter.id(device), .{
        .preedit = "hé",
        .hints = &.{
            .{ .start = 1, .end = 3, .hint = .selection },
            .{ .start = 2, .end = 3, .hint = .prediction },
        },
    });
    try std.testing.expectError(error.InvalidSerial, adapter.queueSubmit(adapter.id(device), 0));
    try adapter.queueSubmit(adapter.id(device), 42);

    const expected = [_]A.OutKind{ .language, .preedit, .preedit_hint, .done, .action, .done };
    for (expected) |kind| {
        const out = adapter.oldest(device.peer).?;
        try std.testing.expectEqual(kind, out.kind);
        switch (kind) {
            .language => try std.testing.expectEqualStrings("en-US", out.storage[0..out.text_len]),
            .preedit_hint => {
                try std.testing.expectEqual(@as(u32, 1), out.start);
                try std.testing.expectEqual(@as(u32, 3), out.end);
                try std.testing.expectEqual(@as(u32, @intFromEnum(PreeditHintKind.selection)), out.value);
            },
            .action => {
                try std.testing.expectEqual(@as(u32, 1), out.value);
                try std.testing.expectEqual(@as(u32, 42), out.serial);
            },
            else => {},
        }
        adapter.dropOut(out);
    }
}
