//! Bounded xdg-activation-v1 owner with one-shot, unguessable tokens.
//!
//! Tokens are only effective when committed with the exact focused surface
//! and most recent user-action serial. Invalid requests still receive an
//! opaque token, as required by the protocol, but that token is never admitted
//! to the activation table. Valid tokens may cross client connections and are
//! consumed by the first matching activate request.

const std = @import("std");
const wayring = @import("wayring");

const linux = std.os.linux;
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);
const token_bytes = 32;

pub const Config = struct {
    manager_capacity: usize = 4,
    token_resource_capacity: usize = 16,
    issued_token_capacity: usize = 16,
    event_capacity: usize = 16,
    global_version: u32 = 1,

    fn validate(config: Config) !void {
        inline for (.{
            config.manager_capacity,
            config.token_resource_capacity,
            config.issued_token_capacity,
            config.event_capacity,
        }) |capacity| if (capacity == 0 or capacity >= none) return error.InvalidConfig;
        if (config.global_version != 1) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Activation = protocol.xdg_activation_v1;
        const Token = protocol.xdg_activation_token_v1;

        pub const SurfaceId = CoreSurface.SurfaceId;
        pub const Event = union(enum) {
            activate: SurfaceId,
        };
        pub const SerialValidator = struct {
            context: *anyopaque,
            validate: *const fn (
                *anyopaque,
                wayring.io_uring.Peer,
                u32,
                u32,
                SurfaceId,
            ) bool,
        };

        const ManagerSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        const Serial = struct { value: u32, seat_object: u32 };
        const TokenSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            serial: ?Serial = null,
            surface: ?SurfaceId = null,
            committed: bool = false,
            done_pending: bool = false,
            token: [token_bytes]u8 = undefined,
        };
        const IssuedSlot = struct {
            header: slot_pool.Header = .{},
            sequence: u64 = 0,
            token: [token_bytes]u8 = undefined,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        managers: slot_pool.Pool(ManagerSlot),
        tokens: slot_pool.Pool(TokenSlot),
        issued: slot_pool.Pool(IssuedSlot),
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        done_pending_len: usize = 0,
        next_sequence: u64 = 1,
        validator: ?SerialValidator = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            try config.validate();
            try Activation.info.validateVersion(config.global_version);
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, config.manager_capacity);
            errdefer managers.deinit();
            var tokens = try slot_pool.Pool(TokenSlot).init(allocator, config.token_resource_capacity);
            errdefer tokens.deinit();
            var issued = try slot_pool.Pool(IssuedSlot).init(allocator, config.issued_token_capacity);
            errdefer issued.deinit();
            const events = try allocator.alloc(Event, config.event_capacity);
            errdefer allocator.free(events);
            return .{
                .allocator = allocator,
                .core = core,
                .global_version = config.global_version,
                .managers = managers,
                .tokens = tokens,
                .issued = issued,
                .events = events,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.issued.deinit();
            self.tokens.deinit();
            self.managers.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Activation.info,
                self.global_version,
                self,
                bind,
            );
            self.global = global;
            return global;
        }

        pub fn setSerialValidator(self: *Self, validator: SerialValidator) void {
            self.validator = validator;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = self.managers.acquire() catch
                return error.OutOfMemory;
            slot.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return self.requestOn(actor, server_objects, peer, target, message, fds);
        }

        pub fn requestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
                return null;
            if (target.object.interface == &Activation.info) {
                const manager = self.managers.fromContext(target.object.context) orelse
                    return null;
                if (!std.meta.eql(manager.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(
                    Activation,
                    server_objects,
                    message,
                    fds,
                );
                switch (decoded.value) {
                    .destroy => {},
                    .get_activation_token => |payload| {
                        const slot = self.tokens.acquire() catch
                            return try self.noMemory(actor);
                        slot.peer = manager.peer;
                        const admitted = Activation.admit_get_activation_token(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .id = slot },
                        ) catch |err| {
                            self.tokens.release(slot);
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                    },
                    .activate => |payload| {
                        const target_id = self.surfaceId(server_objects, payload.surface) catch null;
                        if (target_id) |surface| self.consume(payload.token, surface);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Token.info) {
                const slot = self.tokens.fromContext(target.object.context) orelse
                    return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer))
                    return null;
                const decoded = try wayring.server.decodeRequest(Token, server_objects, message, fds);
                if (slot.committed and decoded.value != .destroy)
                    return try self.protocolError(
                        actor,
                        decoded.handle.id,
                        Token.@"error".already_used.value,
                        "activation token has already been committed",
                    );
                switch (decoded.value) {
                    .set_serial => |payload| slot.serial = .{
                        .value = payload.serial,
                        .seat_object = payload.seat,
                    },
                    .set_surface => |payload| slot.surface = self.surfaceId(
                        server_objects,
                        payload.surface,
                    ) catch null,
                    .set_app_id => {},
                    .commit => try self.commitToken(slot),
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn commitToken(self: *Self, slot: *TokenSlot) !void {
            try fillToken(&slot.token);
            slot.committed = true;
            slot.done_pending = true;
            self.done_pending_len += 1;
            const serial = slot.serial orelse return;
            const surface = slot.surface orelse return;
            const validator = self.validator orelse return;
            if (!validator.validate(
                validator.context,
                slot.peer,
                serial.seat_object,
                serial.value,
                surface,
            )) return;
            self.admitIssued(slot.token);
        }

        fn admitIssued(self: *Self, token: [token_bytes]u8) void {
            const selected = self.issued.acquire() catch return;
            selected.sequence = self.next_sequence;
            selected.token = token;
            self.next_sequence +%= 1;
            if (self.next_sequence == 0) self.next_sequence = 1;
        }

        fn consume(self: *Self, token: []const u8, surface: SurfaceId) void {
            if (token.len != token_bytes) return;
            for (self.issued.entries.items) |slot| {
                if (!slot.header.active or !std.mem.eql(u8, &slot.token, token)) continue;
                self.issued.release(slot);
                if (self.event_len == self.events.len) return;
                const tail = (self.event_head + self.event_len) % self.events.len;
                self.events[tail] = .{ .activate = surface };
                self.event_len += 1;
                return;
            }
        }

        pub fn popEvent(self: *Self) ?Event {
            if (self.event_len == 0) return null;
            const event = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_len -= 1;
            return event;
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (self.done_pending_len == 0) return completed;
            for (self.tokens.entries.items) |slot| {
                if (!slot.header.active or !samePeer(slot.peer, peer) or !slot.done_pending)
                    continue;
                wayring.server.sendEvent(
                    protocol,
                    Token,
                    server_objects,
                    queue,
                    slot.resource,
                    .{ .done = .{ .token = &slot.token } },
                ) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.done_pending = false;
                self.done_pending_len -= 1;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.done_pending_len == 0) return false;
            for (self.tokens.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and slot.done_pending)
                    return true;
            return false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Activation.info) {
                const slot = self.managers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.managers.release(slot);
                return true;
            }
            if (object.interface == &Token.info) {
                const slot = self.tokens.fromContext(object.context) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                if (slot.done_pending) self.done_pending_len -= 1;
                self.tokens.release(slot);
                return true;
            }
            return false;
        }

        fn surfaceId(self: *Self, server_objects: anytype, object_id: u32) !SurfaceId {
            const handle = server_objects.namespace.lookupHandle(object_id) orelse
                return error.UnknownSurface;
            const object = server_objects.namespace.resolve(handle) orelse
                return error.UnknownSurface;
            return self.core.surfaceIdObject(handle, object);
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn failure(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, @errorName(cause));
            return .stop;
        }

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
    };
}

fn fillToken(token: *[token_bytes]u8) !void {
    var random: [token_bytes / 2]u8 = undefined;
    var filled: usize = 0;
    while (filled < random.len) {
        const result = linux.getrandom(random[filled..].ptr, random.len - filled, 0);
        switch (linux.errno(result)) {
            .SUCCESS => filled += result,
            .INTR => continue,
            else => return error.RandomUnavailable,
        }
    }
    const hex = "0123456789abcdef";
    for (random, 0..) |byte, index| {
        token[index * 2] = hex[byte >> 4];
        token[index * 2 + 1] = hex[byte & 0x0f];
    }
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg-activation: generated adapter initializes bounded ownership" {
    const protocol = @import("core_protocol");
    const CoreSurface = @import("core_surface.zig").Adapter(protocol);
    var core: CoreSurface = undefined;
    const TestAdapter = Adapter(protocol, CoreSurface);
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{});
    adapter.deinit();
}

test "xdg-activation: validated tokens are opaque, one-shot, and cross-client" {
    const protocol = @import("core_protocol");
    const CoreSurface = @import("core_surface.zig").Adapter(protocol);
    const TestAdapter = Adapter(protocol, CoreSurface);
    var core: CoreSurface = undefined;
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .manager_capacity = 1,
        .token_resource_capacity = 1,
        .issued_token_capacity = 2,
        .event_capacity = 2,
    });
    defer adapter.deinit();
    adapter.setSerialValidator(.{ .context = &adapter, .validate = struct {
        fn validate(
            _: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat: u32,
            serial: u32,
            surface: TestAdapter.SurfaceId,
        ) bool {
            return samePeer(peer, .{ .slot = 1, .generation = 3 }) and seat == 7 and
                serial == 41 and std.meta.eql(surface, TestAdapter.SurfaceId{ .index = 2, .generation = 5 });
        }
    }.validate });
    const slot = try adapter.tokens.acquire();
    const grown = try adapter.tokens.acquire();
    try std.testing.expect(grown != slot);
    adapter.tokens.release(grown);
    slot.peer = .{ .slot = 1, .generation = 3 };
    slot.serial = .{ .seat_object = 7, .value = 41 };
    slot.surface = .{ .index = 2, .generation = 5 };

    try adapter.commitToken(slot);

    try std.testing.expect(slot.committed and slot.done_pending);
    for (slot.token) |byte| try std.testing.expect(std.ascii.isHex(byte) and !std.ascii.isUpper(byte));
    adapter.consume(&slot.token, .{ .index = 9, .generation = 4 });
    try std.testing.expectEqual(
        TestAdapter.Event{ .activate = .{ .index = 9, .generation = 4 } },
        adapter.popEvent().?,
    );
    adapter.consume(&slot.token, .{ .index = 8, .generation = 2 });
    try std.testing.expectEqual(@as(?TestAdapter.Event, null), adapter.popEvent());
}

test "xdg-activation: ineffective requests still produce opaque done tokens" {
    const protocol = @import("core_protocol");
    const CoreSurface = @import("core_surface.zig").Adapter(protocol);
    const TestAdapter = Adapter(protocol, CoreSurface);
    var core: CoreSurface = undefined;
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .manager_capacity = 1,
        .token_resource_capacity = 1,
        .issued_token_capacity = 1,
        .event_capacity = 1,
    });
    defer adapter.deinit();
    const slot = try adapter.tokens.acquire();
    slot.peer = .{ .slot = 1, .generation = 3 };

    try adapter.commitToken(slot);

    try std.testing.expect(slot.committed and slot.done_pending);
    try std.testing.expectEqual(@as(usize, 0), adapter.issued.entries.items.len);
    adapter.consume(&slot.token, .{ .index = 1, .generation = 1 });
    try std.testing.expectEqual(@as(?TestAdapter.Event, null), adapter.popEvent());
}

test "xdg-activation: issued token reservation grows without invalidating tokens" {
    const protocol = @import("core_protocol");
    const CoreSurface = @import("core_surface.zig").Adapter(protocol);
    const TestAdapter = Adapter(protocol, CoreSurface);
    var core: CoreSurface = undefined;
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .manager_capacity = 1,
        .token_resource_capacity = 1,
        .issued_token_capacity = 1,
        .event_capacity = 3,
    });
    defer adapter.deinit();
    const first: [token_bytes]u8 = @splat('a');
    const second: [token_bytes]u8 = @splat('b');
    const third: [token_bytes]u8 = @splat('c');
    adapter.admitIssued(first);
    adapter.admitIssued(second);
    adapter.admitIssued(third);

    try std.testing.expectEqual(@as(usize, 3), adapter.issued.entries.items.len);
    adapter.consume(&first, .{ .index = 1, .generation = 1 });
    adapter.consume(&second, .{ .index = 2, .generation = 1 });
    adapter.consume(&third, .{ .index = 3, .generation = 1 });
    try std.testing.expectEqual(
        TestAdapter.Event{ .activate = .{ .index = 1, .generation = 1 } },
        adapter.popEvent().?,
    );
    try std.testing.expectEqual(
        TestAdapter.Event{ .activate = .{ .index = 2, .generation = 1 } },
        adapter.popEvent().?,
    );
    try std.testing.expectEqual(TestAdapter.Event{ .activate = .{ .index = 3, .generation = 1 } }, adapter.popEvent().?);
}
