//! Experimental, explicitly enabled global hotkeys. No raw input is forwarded.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const pool = @import("slot_pool.zig");
const input = @import("../backend/input/backend.zig");
const config = @import("../config.zig");
const Keymap = @import("../input/keymap.zig").State;
const SeatValidator = @import("keyboard_shortcuts_inhibit.zig").SeatValidator;

const Trigger = struct { button: bool = false, code: u32, modifiers: u32 };
const State = struct { trigger: ?Trigger = null, seat: ?objects.Handle = null };

// Deliberately narrower than the specification's suggested policy: modifier
// taps, primary buttons, typing/navigation keys without Ctrl/Alt/Super are not
// admitted. This avoids observing text and stealing desktop pointer gestures.
fn permitted(t: Trigger) bool {
    if (t.button) return t.code >= 275 and t.code <= 279;
    if (t.code >= 0xffe1 and t.code <= 0xffee) return false;
    if (t.code == 0xff7e or t.code == 0xff7f or t.code == 0xff14 or
        (t.code >= 0xfe01 and t.code <= 0xfe13)) return false;
    return t.modifiers & 14 != 0 or
        (t.code >= 0xffbe and t.code <= 0xffe0) or // F1..F35
        (t.code >= 0x1008ff11 and t.code <= 0x1008ff17); // audio controls
}

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xx_hotkey_manager_v1;
        const Hotkey = protocol.xx_hotkey_v1;
        const ManagerSlot = struct {
            header: pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            app_id: ?[]const u8 = null,
            committed: bool = false,
            destroyed: bool = false,
            children: usize = 0,
        };
        const Slot = struct {
            header: pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            manager: *ManagerSlot = undefined,
            pending: State = .{},
            current: ?State = null,
            events: std.ArrayList(Hotkey.Event) = .empty,
            revoked: bool = false,
            serials: [2]u32 = .{ 0, 0 },
            authorization_ns: [2]u64 = .{ 0, 0 },
        };
        const Held = struct {
            device: input.DeviceId,
            button: bool,
            code: u32,
            slot: ?*Slot,
            consumed: bool,
        };

        allocator: std.mem.Allocator,
        validator: SeatValidator,
        managers: pool.Pool(ManagerSlot),
        slots: pool.Pool(Slot),
        held: std.ArrayList(Held) = .empty,
        bindings: []const config.Binding = &.{},
        keymap: ?*const Keymap = null,
        enabled: bool = false,
        blocked: bool = false,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        publishing: bool = false,

        pub fn init(allocator: std.mem.Allocator, validator: SeatValidator) !Self {
            var managers = try pool.Pool(ManagerSlot).init(allocator, 4);
            errdefer managers.deinit();
            return .{ .allocator = allocator, .validator = validator, .managers = managers, .slots = try pool.Pool(Slot).init(allocator, 16) };
        }

        pub fn deinit(self: *Self) void {
            for (self.slots.entries.items) |slot| if (slot.header.active) slot.events.deinit(self.allocator);
            for (self.managers.entries.items) |manager| if (manager.app_id) |id| self.allocator.free(id);
            self.held.deinit(self.allocator);
            self.slots.deinit();
            self.managers.deinit();
        }

        /// Enabled policy publishes the experimental factory. Existing objects
        /// become inert on opt-out; global withdrawal alone is not a boundary.
        pub fn syncGlobal(self: *Self, runtime: *Runtime) !void {
            self.runtime = runtime;
            if (self.publishing) return;
            if (self.enabled and self.global == null) {
                self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
                self.publishing = true;
            } else if (!self.enabled and self.global != null) {
                try runtime.removeGlobal(self.global.?);
                self.global = null;
                self.publishing = true;
            }
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const manager = try self.managers.acquire();
            manager.resource = binding.resource;
            manager.peer = binding.peer;
            return manager;
        }

        pub fn configure(self: *Self, enabled: bool, bindings: []const config.Binding) !void {
            // Reserve before changing policy, so configuration failure leaves
            // the previous bindings and enabled state intact.
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.current != null)
                try slot.events.ensureUnusedCapacity(self.allocator, 1);
            self.enabled = enabled;
            self.bindings = bindings;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active) continue;
                if (slot.current) |state| if (!enabled or self.conflicts(state.trigger.?)) self.revoke(slot);
            }
        }

        fn conflicts(self: *const Self, trigger: Trigger) bool {
            if (trigger.button) return false;
            for (self.bindings) |binding| if (self.overlaps(trigger, .{
                .code = binding.trigger.keysym,
                .modifiers = @as(u4, @bitCast(binding.trigger.modifiers)),
            })) return true;
            return false;
        }

        fn overlaps(self: *const Self, a: Trigger, b: Trigger) bool {
            if (a.button != b.button or a.modifiers != b.modifiers) return false;
            if (a.code == b.code) return true;
            if (!a.button) if (self.keymap) |keymap| return keymap.overlaps(a.code, b.code);
            return false;
        }

        pub fn setBlocked(self: *Self, blocked: bool) !void {
            if (blocked) {
                for (self.slots.entries.items) |slot| if (slot.header.active and slot.current != null)
                    try slot.events.ensureUnusedCapacity(self.allocator, 1);
                // Revoke held bindings, rather than sending their release into
                // a lock/grab or leaving push-to-talk logically held forever.
                for (self.held.items) |held| if (held.slot) |slot| self.revoke(slot);
                for (self.slots.entries.items) |slot| slot.serials = .{ 0, 0 };
            }
            self.blocked = blocked;
        }

        fn revoke(self: *Self, slot: *Slot) void {
            if (slot.current == null) return;
            slot.events.appendAssumeCapacity(.{ .revoked = .{ .message = "Hotkey withdrawn by compositor policy" } });
            slot.current = null;
            slot.revoked = true;
            slot.serials = .{ 0, 0 };
            for (self.held.items) |*held| if (held.slot == slot) {
                held.slot = null;
            };
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return null;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managers.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !std.meta.eql(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_app_id => |v| {
                        if (v.app_id.len == 0 or manager.app_id != null or manager.committed)
                            return try self.protocolError(actor, handle.id, 0, "invalid hotkey app id");
                        manager.app_id = try self.allocator.dupe(u8, v.app_id);
                    },
                    .create_hotkey => |v| {
                        const slot = try self.slots.acquire();
                        errdefer self.slots.release(slot);
                        const admitted = try Manager.admit_create_hotkey(server, handle, v, .{ .id = slot });
                        slot.resource = admitted.id;
                        slot.peer = peer;
                        slot.manager = manager;
                        manager.children += 1;
                    },
                }
                try decoded.finish(protocol, server, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Hotkey.info) return null;
            const slot = self.slots.fromContext(target.object.context) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !std.meta.eql(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Hotkey, server, message, fds);
            switch (decoded.value) {
                .destroy, .set_description => {}, // Advisory metadata is not an authorization source.
                .set_seat => |v| slot.pending.seat = if (v.seat) |seat| server.namespace.lookupHandle(seat) else null,
                .set_key_trigger => |v| {
                    if (v.keysym == 0 or v.modifiers.value & ~@as(u32, 15) != 0)
                        return try self.protocolError(actor, handle.id, 0, "invalid hotkey trigger");
                    slot.pending.trigger = .{ .code = v.keysym, .modifiers = v.modifiers.value };
                },
                .set_button_trigger => |v| {
                    if (v.modifiers.value & ~@as(u32, 15) != 0)
                        return try self.protocolError(actor, handle.id, 0, "invalid hotkey modifiers");
                    slot.pending.trigger = .{ .button = true, .code = v.button, .modifiers = v.modifiers.value };
                },
                .commit => {
                    if (slot.pending.trigger == null) return try self.protocolError(actor, handle.id, 1, "missing hotkey trigger");
                    try self.commit(slot);
                },
            }
            try decoded.finish(protocol, server, &actor.transmit);
            return .continue_dispatch;
        }

        fn commit(self: *Self, slot: *Slot) !void {
            try slot.events.ensureUnusedCapacity(self.allocator, 1);
            slot.manager.committed = true;
            const trigger = slot.pending.trigger.?;
            var reason: ?Hotkey.deny_reason = null;
            if (!self.enabled or self.blocked or slot.revoked or !permitted(trigger)) reason = Hotkey.deny_reason.not_permitted;
            if (slot.pending.seat) |seat| if (!self.validator.validate(slot.peer, seat.id)) {
                reason = Hotkey.deny_reason.not_permitted;
            };
            for (self.held.items) |held| if (held.slot == slot and !std.meta.eql(slot.current.?, slot.pending)) {
                reason = Hotkey.deny_reason.not_permitted;
            };
            if (self.conflicts(trigger)) reason = Hotkey.deny_reason.already_bound;
            for (self.slots.entries.items) |other| {
                if (other == slot or !other.header.active) continue;
                if (other.current) |state| if (self.overlaps(state.trigger.?, trigger)) {
                    reason = Hotkey.deny_reason.already_bound;
                };
            }
            if (reason) |value| {
                slot.events.appendAssumeCapacity(.{ .denied = .{ .reason = value, .message = "Trigger unavailable under compositor policy" } });
            } else {
                slot.current = slot.pending;
                slot.events.appendAssumeCapacity(.bound);
            }
        }

        /// Called once per normalized event before compositor/client delivery.
        /// All down edges are remembered, including inhibited/unbound input, so
        /// repeats and mid-press commits cannot create a new trigger.
        pub fn consume(self: *Self, event: input.Event, keymap: *const Keymap, seat: anytype, now_ns: u64) !bool {
            if (event == .device_removed) {
                var i: usize = 0;
                while (i < self.held.items.len) {
                    const held = self.held.items[i];
                    if (!std.meta.eql(held.device, event.device_removed)) {
                        i += 1;
                        continue;
                    }
                    if (held.slot) |slot| {
                        try slot.events.ensureUnusedCapacity(self.allocator, 1);
                        self.revoke(slot);
                    }
                    _ = self.held.swapRemove(i);
                }
                return false;
            }
            const button = event == .pointer_button;
            const v = switch (event) {
                .keyboard_key => |v| .{ v.device, v.key, v.pressed, v.time_usec },
                .pointer_button => |v| .{ v.device, v.button, v.pressed, v.time_usec },
                else => return false,
            };
            for (self.held.items, 0..) |held, i| {
                if (!std.meta.eql(held.device, v[0]) or held.button != button or held.code != v[1]) continue;
                if (v[2]) return held.consumed;
                if (held.slot) |slot| try self.emit(slot, false, @truncate(v[3] / 1000), seat, now_ns);
                _ = self.held.swapRemove(i);
                return held.consumed;
            }
            if (!v[2]) return false;
            try self.held.ensureUnusedCapacity(self.allocator, 1);
            var selected: ?*Slot = null;
            const modifiers: u4 = @bitCast(keymap.trigger(0).modifiers);
            var compositor_conflict = false;
            if (!button) for (self.bindings) |binding| {
                if (@as(u4, @bitCast(binding.trigger.modifiers)) == modifiers and keymap.matches(v[1], binding.trigger.keysym)) compositor_conflict = true;
            };
            if (self.enabled and !self.blocked and !compositor_conflict) for (self.slots.entries.items) |slot| {
                if (!slot.header.active) continue;
                const state = slot.current orelse continue;
                const trigger = state.trigger.?;
                if (trigger.button != button or trigger.modifiers != modifiers) continue;
                if (if (button) trigger.code != v[1] else !keymap.matches(v[1], trigger.code)) continue;
                if (!button and keymap.changesModifiers(v[1])) continue;
                try self.emit(slot, true, @truncate(v[3] / 1000), seat, now_ns);
                selected = slot;
                break;
            };
            self.held.appendAssumeCapacity(.{ .device = v[0], .button = button, .code = v[1], .slot = selected, .consumed = selected != null });
            return selected != null;
        }

        fn emit(self: *Self, slot: *Slot, pressed: bool, time: u32, seat: anytype, now_ns: u64) !void {
            try slot.events.ensureUnusedCapacity(self.allocator, 1);
            const serial = seat.nextSerial();
            const i: usize = if (pressed) 0 else 1;
            slot.serials[i] = serial;
            slot.authorization_ns[i] = now_ns;
            slot.events.appendAssumeCapacity(if (pressed) .{ .triggered = .{ .serial = serial, .time = time } } else .{ .released = .{ .serial = serial, .time = time } });
        }

        /// Separate, one-shot activation grant. It never authorizes selection,
        /// popup, move/resize, or any ordinary focused-input operation.
        pub fn authorizeActivation(self: *Self, peer: wayring.io_uring.Peer, seat: u32, serial: u32, now_ns: u64) bool {
            if (!self.enabled or self.blocked or serial == 0 or !self.validator.validate(peer, seat)) return false;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or slot.current == null or !std.meta.eql(slot.peer, peer)) continue;
                if (slot.current.?.seat) |specific| if (specific.id != seat) continue;
                for (&slot.serials, slot.authorization_ns) |*grant, time| {
                    if (grant.* != serial) continue;
                    if (now_ns -| time > 5 * std.time.ns_per_s) return false;
                    grant.* = 0;
                    return true;
                }
            }
            return false;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.slots.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.peer, peer) and slot.events.items.len != 0) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, _: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.peer, peer)) continue;
                while (slot.events.items.len != 0) {
                    Hotkey.encodeEvent(queue, slot.resource.id, slot.events.items[0]) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    _ = slot.events.orderedRemove(0);
                    count += 1;
                }
            }
            return count;
        }

        fn releaseManager(self: *Self, manager: *ManagerSlot) void {
            if (!manager.destroyed or manager.children != 0) return;
            if (manager.app_id) |id| self.allocator.free(id);
            self.managers.release(manager);
        }

        fn release(self: *Self, slot: *Slot) void {
            for (self.held.items) |*held| if (held.slot == slot) {
                held.slot = null;
            };
            slot.manager.children -= 1;
            self.releaseManager(slot.manager);
            slot.events.deinit(self.allocator);
            self.slots.release(slot);
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Hotkey.info) {
                const slot = self.slots.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(slot);
                return true;
            }
            if (object.interface == &Manager.info) {
                const manager = self.managers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                manager.destroyed = true;
                self.releaseManager(manager);
                return true;
            }
            // wl_seat.release is not physical seat removal. Ouro's primary
            // seat lives for the session; isolated transient seats are denied.
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.peer, peer)) self.release(slot);
            for (self.managers.entries.items) |manager| if (manager.header.active and std.meta.eql(manager.peer, peer)) {
                manager.destroyed = true;
                self.releaseManager(manager);
            };
        }

        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, message);
            return .stop;
        }
    };
}

const TestAdapter = Adapter(@import("core_protocol"));
const test_peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 7 };
const test_device: input.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 1 };
const TestSeat = struct {
    serial: u32 = 100,
    pub fn nextSerial(self: *@This()) u32 {
        self.serial += 1;
        return self.serial;
    }
};

fn testValidator(_: ?*anyopaque, peer: wayring.io_uring.Peer, seat: u32) bool {
    return std.meta.eql(peer, test_peer) and seat == 9;
}

fn testSlot(adapter: *TestAdapter, trigger: Trigger) !*TestAdapter.Slot {
    const manager = try adapter.managers.acquire();
    manager.peer = test_peer;
    manager.children = 1;
    const slot = try adapter.slots.acquire();
    slot.peer = test_peer;
    slot.manager = manager;
    slot.pending.trigger = trigger;
    return slot;
}

fn testKey(key: u32, pressed: bool) input.Event {
    return .{ .keyboard_key = .{ .device = test_device, .key = key, .pressed = pressed, .time_usec = 123_456 } };
}

test "hotkey: opt-in, safe trigger policy, exclusivity and rejected reconfiguration" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .validateFn = testValidator });
    defer adapter.deinit();
    const slot = try testSlot(&adapter, .{ .code = 'p', .modifiers = 6 });
    try adapter.commit(slot);
    try std.testing.expect(slot.current == null);
    try std.testing.expectEqual(@as(u32, 1), slot.events.items[0].denied.reason.value);
    try adapter.configure(true, &.{});
    try adapter.commit(slot);
    try std.testing.expect(slot.events.items[1] == .bound);
    for ([_]Trigger{
        .{ .code = 'p', .modifiers = 0 },                 .{ .code = 'p', .modifiers = 1 },
        .{ .code = 0xffe3, .modifiers = 8 },              .{ .code = 0xfe51, .modifiers = 0 },
        .{ .code = 272, .modifiers = 8, .button = true },
    }) |trigger| {
        slot.pending.trigger = trigger;
        try adapter.commit(slot);
        try std.testing.expect(slot.events.items[slot.events.items.len - 1] == .denied);
        try std.testing.expectEqual(@as(u32, 'p'), slot.current.?.trigger.?.code);
    }
    const duplicate = try testSlot(&adapter, .{ .code = 'p', .modifiers = 6 });
    try adapter.commit(duplicate);
    try std.testing.expectEqual(@as(u32, 0), duplicate.events.items[0].denied.reason.value);
    try adapter.configure(true, &.{.{ .trigger = .{ .keysym = 'p', .modifiers = .{ .control = true, .alt = true } }, .action = .close }});
    try std.testing.expect(slot.current == null and slot.revoked);
    try std.testing.expect(slot.events.items[slot.events.items.len - 1] == .revoked);
    try adapter.configure(false, &.{});
    try adapter.commit(duplicate);
    try std.testing.expect(duplicate.current == null);
}

test "hotkey: exact modifiers, physical pairing, duplicate edges and one-shot activation" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .validateFn = testValidator });
    defer adapter.deinit();
    try adapter.configure(true, &.{});
    const slot = try testSlot(&adapter, .{ .code = 'p', .modifiers = 6 });
    try adapter.commit(slot);
    var keymap = try Keymap.init();
    defer keymap.deinit();
    var seat: TestSeat = .{};
    keymap.update(29, true); // Control
    keymap.update(56, true); // Alt
    keymap.update(42, true); // extra Shift must not match
    try std.testing.expect(!try adapter.consume(testKey(25, true), &keymap, &seat, 1));
    try std.testing.expect(!try adapter.consume(testKey(25, false), &keymap, &seat, 2));
    keymap.update(42, false);
    try std.testing.expect(try adapter.consume(testKey(25, true), &keymap, &seat, 3));
    try std.testing.expect(try adapter.consume(testKey(25, true), &keymap, &seat, 4));
    try std.testing.expectEqual(@as(usize, 2), slot.events.items.len);
    const serial = slot.events.items[1].triggered.serial;
    try std.testing.expectEqual(@as(u32, 123), slot.events.items[1].triggered.time);
    keymap.update(29, false);
    keymap.update(56, false);
    try std.testing.expect(try adapter.consume(testKey(25, false), &keymap, &seat, 5));
    try std.testing.expectEqual(@as(usize, 3), slot.events.items.len);
    try std.testing.expect(slot.events.items[2] == .released);
    try std.testing.expect(!adapter.authorizeActivation(.{ .slot = 2, .generation = 8 }, 9, serial, 6));
    try std.testing.expect(!adapter.authorizeActivation(test_peer, 10, serial, 6));
    // Press serial remains valid even when the matching release was queued
    // before the client could process triggered.
    try std.testing.expect(adapter.authorizeActivation(test_peer, 9, serial, 6));
    try std.testing.expect(!adapter.authorizeActivation(test_peer, 9, serial, 7));
    try std.testing.expect(!adapter.authorizeActivation(test_peer, 9, slot.events.items[2].released.serial, 5 * std.time.ns_per_s + 6));
}

test "hotkey: block, opt-out, destruction and device loss retain consumed releases" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .validateFn = testValidator });
    defer adapter.deinit();
    var keymap = try Keymap.init();
    defer keymap.deinit();
    var seat: TestSeat = .{};
    try adapter.configure(true, &.{});
    const slot = try testSlot(&adapter, .{ .button = true, .code = 275, .modifiers = 0 });
    try adapter.commit(slot);
    var event: input.Event = .{ .pointer_button = .{ .device = test_device, .button = 275, .pressed = true, .time_usec = 1_000 } };
    try std.testing.expect(try adapter.consume(event, &keymap, &seat, 1));
    try adapter.setBlocked(true);
    try std.testing.expect(slot.revoked);
    try std.testing.expect(!adapter.authorizeActivation(test_peer, 9, seat.serial, 2));
    event.pointer_button.pressed = false;
    try std.testing.expect(try adapter.consume(event, &keymap, &seat, 3));
    try std.testing.expect(slot.events.items[slot.events.items.len - 1] == .revoked);
    try adapter.setBlocked(false);
    const next = try testSlot(&adapter, .{ .code = 0xffbf, .modifiers = 0 }); // F2
    try adapter.commit(next);
    try std.testing.expect(try adapter.consume(testKey(60, true), &keymap, &seat, 4));
    adapter.release(next);
    try std.testing.expect(try adapter.consume(testKey(60, false), &keymap, &seat, 5));
    const removed = try testSlot(&adapter, .{ .code = 0xffbf, .modifiers = 0 });
    try adapter.commit(removed);
    try std.testing.expect(try adapter.consume(testKey(60, true), &keymap, &seat, 6));
    _ = try adapter.consume(.{ .device_removed = test_device }, &keymap, &seat, 7);
    try std.testing.expect(removed.revoked);
    try std.testing.expectEqual(@as(usize, 0), adapter.held.items.len);
    const disabled = try testSlot(&adapter, .{ .code = 0xffc0, .modifiers = 0 });
    try adapter.commit(disabled);
    try std.testing.expect(try adapter.consume(testKey(61, true), &keymap, &seat, 8));
    try adapter.configure(false, &.{});
    try std.testing.expect(disabled.revoked);
    try std.testing.expect(try adapter.consume(testKey(61, false), &keymap, &seat, 9));
    try std.testing.expect(disabled.events.items[disabled.events.items.len - 1] == .revoked);
    adapter.disconnected(test_peer);
    try std.testing.expect(!adapter.pendingOutbound(test_peer));
}

test "hotkey: generated malformed requests return the specified protocol error" {
    const protocol = @import("core_protocol");
    for (0..6) |case| {
        var adapter = try TestAdapter.init(std.testing.allocator, .{ .validateFn = testValidator });
        defer adapter.deinit();
        const slot = try testSlot(&adapter, .{ .code = 'p', .modifiers = 6 });
        var server = try objects.ServerObjects.init(std.testing.allocator, 8, 4, &protocol.wl_display.info, null);
        defer server.deinit(std.testing.allocator);
        slot.manager.resource = try server.insertClient(2, &protocol.xx_hotkey_manager_v1.info, 1, slot.manager);
        slot.resource = try server.insertClient(3, &protocol.xx_hotkey_v1.info, 1, slot);
        var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 8);
        defer blocks.deinit(std.testing.allocator);
        var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
        defer descriptors.deinit(std.testing.allocator);
        var fragment: [64]u8 = undefined;
        var actor = wayring.connection.Actor.init(2, 7, &fragment, &descriptors, 0, &blocks, 512, 0);
        defer actor.deinit();
        var requests = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
        defer requests.deinit();
        switch (case) {
            0, 1, 2 => {
                if (case == 1) slot.manager.app_id = try std.testing.allocator.dupe(u8, "first");
                if (case == 2) try adapter.commit(slot);
                try protocol.xx_hotkey_manager_v1.encodeRequest(&requests, 2, .{ .set_app_id = .{ .app_id = if (case == 0) "" else "second" } });
            },
            3 => {
                slot.pending.trigger = null;
                try protocol.xx_hotkey_v1.encodeRequest(&requests, 3, .{ .commit = .{} });
            },
            4, 5 => try protocol.xx_hotkey_v1.encodeRequest(&requests, 3, .{ .set_key_trigger = .{ .keysym = if (case == 4) 0 else 'p', .modifiers = .{ .value = if (case == 5) 16 else 0 } } }),
            else => unreachable,
        }
        var scratch: [1]std.os.linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        const message = (try wayring.wire.Message.decode((try requests.snapshot(&scratch, &control)).first)).?;
        const target = try server.namespace.request(message.header.object_id, message.header.opcode);
        try std.testing.expectEqual(wayring.dispatch.Control.stop, (try adapter.requestOn(&actor, &server, test_peer, target, message, &requests.descriptors)).?);
        const response = (try wayring.wire.Message.decode((try actor.transmit.snapshot(&scratch, &control)).first)).?;
        const decoded = try protocol.wl_display.decodeEvent(response, &actor.transmit.descriptors);
        try std.testing.expectEqual(@as(u32, if (case == 3) 1 else 0), decoded.@"error".code);
        try std.testing.expectEqual(message.header.object_id, decoded.@"error".object_id);
    }
}

test "hotkey: outbound backpressure retains commit and input event order" {
    const protocol = @import("core_protocol");
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .validateFn = testValidator });
    defer adapter.deinit();
    var keymap = try Keymap.init();
    defer keymap.deinit();
    var seat: TestSeat = .{};
    try adapter.configure(true, &.{});
    const slot = try testSlot(&adapter, .{ .code = 0xffbf, .modifiers = 0 });
    slot.resource = .{ .id = 3, .generation = 1 };
    try adapter.commit(slot);
    _ = try adapter.consume(testKey(60, true), &keymap, &seat, 1);
    _ = try adapter.consume(testKey(60, false), &keymap, &seat, 2);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var small = wayring.tx.Queue.init(&blocks, 8, &descriptors, 0);
    defer small.deinit();
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(test_peer, {}, &small));
    try std.testing.expect(adapter.pendingOutbound(test_peer));
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(test_peer, {}, &small));
    var large = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer large.deinit();
    try std.testing.expectEqual(@as(usize, 2), try adapter.flushOn(test_peer, {}, &large));
    try std.testing.expect(!adapter.pendingOutbound(test_peer));
    var scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const bytes = (try large.snapshot(&scratch, &control)).first;
    const first = (try wayring.wire.Message.decode(bytes)).?;
    try std.testing.expect((try protocol.xx_hotkey_v1.decodeEvent(first, &large.descriptors)) == .triggered);
    const second = (try wayring.wire.Message.decode(bytes[first.header.size..])).?;
    try std.testing.expect((try protocol.xx_hotkey_v1.decodeEvent(second, &large.descriptors)) == .released);
}
