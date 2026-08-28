//! Focus-driven keyboard-shortcuts-inhibit-unstable-v1 adapter.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const SeatValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, u32) bool,

    pub fn validate(self: SeatValidator, peer: wayring.io_uring.Peer, seat: u32) bool {
        return self.validateFn(self.context, peer, seat);
    }
};

pub const Config = struct {
    inhibitor_capacity: usize = 16,

    fn validate(config: Config) !void {
        if (config.inhibitor_capacity == 0 or config.inhibitor_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_keyboard_shortcuts_inhibit_manager_v1;
        const Inhibitor = protocol.zwp_keyboard_shortcuts_inhibitor_v1;

        pub const Focus = struct {
            peer: wayring.io_uring.Peer,
            surface: CoreSurface.SurfaceId,
        };

        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            surface: CoreSurface.SurfaceId = undefined,
            effective: bool = false,
            active_pending: bool = false,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        validator: SeatValidator,
        slots: slot_pool.Pool(Slot),
        focus: ?Focus = null,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, validator: SeatValidator, config: Config) !Self {
            try config.validate();
            const slots = try slot_pool.Pool(Slot).init(allocator, config.inhibitor_capacity);
            return .{ .allocator = allocator, .core = core, .validator = validator, .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            self.slots.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .inhibit_shortcuts => |value| {
                        const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                            return try self.protocolError(actor, decoded.handle.id, "invalid shortcut-inhibitor surface");
                        const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                            return try self.protocolError(actor, decoded.handle.id, "invalid shortcut-inhibitor surface");
                        const surface = self.core.surfaceIdObject(surface_handle, surface_object) catch
                            return try self.protocolError(actor, decoded.handle.id, "invalid shortcut-inhibitor surface");
                        if (!samePeer(try self.core.surfacePeer(surface), peer) or
                            !self.validator.validate(peer, value.seat))
                            return try self.protocolError(actor, decoded.handle.id, "invalid shortcut-inhibitor seat or surface");
                        for (self.slots.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer) and
                            std.meta.eql(slot.surface, surface))
                            return try self.protocolError(actor, decoded.handle.id, "shortcuts already inhibited");
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        const admitted = Manager.admit_inhibit_shortcuts(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |err| {
                            self.release(self.index(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        slot.peer = peer;
                        slot.surface = surface;
                        slot.effective = focusMatches(self.focus, peer, surface);
                        slot.active_pending = slot.effective;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Inhibitor.info) return null;
            const slot = self.fromObject(target.object) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Inhibitor, server_objects, message, fds);
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        /// Focus loss makes an inhibitor irrelevant without an inactive event,
        /// as required by the protocol. Regaining focus queues active again.
        pub fn setFocus(self: *Self, focus: ?Focus) void {
            self.focus = focus;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active) continue;
                const effective = focusMatches(focus, slot.peer, slot.surface);
                if (effective and !slot.effective) slot.active_pending = true;
                if (!effective) slot.active_pending = false;
                slot.effective = effective;
            }
        }

        pub fn shortcutsInhibited(self: *const Self) bool {
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.effective) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, _: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (!slot.header.active or !slot.active_pending or !samePeer(slot.peer, peer)) continue;
                Inhibitor.encodeEvent(queue, slot.resource.id, .active) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.active_pending = false;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and slot.active_pending and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Inhibitor.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(slot.header.index);
                return true;
            }
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer)) self.release(slot.header.index);
            if (self.focus) |focus| if (samePeer(focus.peer, peer)) self.setFocus(null);
        }

        fn acquire(self: *Self) !*Slot {
            return self.slots.acquire();
        }

        fn release(self: *Self, i: u32) void {
            const slot = self.slots.at(i) orelse return;
            self.slots.release(slot);
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            return self.slots.fromContext(object.context);
        }

        fn index(self: *const Self, slot: *const Slot) u32 {
            _ = self;
            return slot.header.index;
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, Manager.@"error".already_inhibited.value, message);
            return .stop;
        }

        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.Exhausted, error.OutOfMemory => self.noMemory(actor),
                else => self.protocolError(actor, id, @errorName(err)),
            };
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn focusMatches(focus: anytype, peer: wayring.io_uring.Peer, surface: anytype) bool {
    const value = focus orelse return false;
    return samePeer(value.peer, peer) and std.meta.eql(value.surface, surface);
}

fn acceptSeat(_: ?*anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
    return true;
}

test "keyboard shortcuts inhibit: focus activation and loss are exact" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const A = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try A.init(std.testing.allocator, &core, .{ .validateFn = acceptSeat }, .{ .inhibitor_capacity = 2 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const surface: FakeCore.SurfaceId = .{ .index = 3, .generation = 4 };
    const slot = try adapter.acquire();
    slot.peer = peer;
    slot.surface = surface;

    adapter.setFocus(.{ .peer = peer, .surface = surface });
    try std.testing.expect(adapter.shortcutsInhibited());
    try std.testing.expect(slot.active_pending);
    slot.active_pending = false;
    adapter.setFocus(null);
    try std.testing.expect(!adapter.shortcutsInhibited());
    try std.testing.expect(!slot.active_pending);
    adapter.setFocus(.{ .peer = peer, .surface = surface });
    try std.testing.expect(slot.active_pending);
    adapter.disconnected(peer);
    try std.testing.expect(!adapter.shortcutsInhibited());
}

test "keyboard shortcut ownership grows without moving original context" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const A = Adapter(protocol, FakeCore);
    var core: FakeCore = .{};
    var adapter = try A.init(std.testing.allocator, &core, .{ .validateFn = acceptSeat }, .{ .inhibitor_capacity = 1 });
    defer adapter.deinit();
    const first = try adapter.acquire();
    _ = try adapter.acquire();
    try std.testing.expect(adapter.slots.fromContext(first) == first);
}
