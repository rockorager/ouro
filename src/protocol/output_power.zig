//! Backend-independent wlr output-power protocol adapter.
//!
//! Output lookup is deliberately delegated to the compositor.  A resolver
//! must validate the exact, peer-owned `wl_output` object and return a
//! generation-safe output identity and its current mode.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");

pub const Mode = enum(u32) { off = 0, on = 1 };
pub const Completion = enum { succeeded, failed };

pub const Config = struct {
    initial_capacity: usize = 8,
    outbound_capacity: usize = 64,
    command_capacity: usize = 64,

    fn validate(config: Config) !void {
        if (config.initial_capacity == 0 or config.outbound_capacity == 0 or
            config.command_capacity == 0) return error.InvalidConfig;
    }
};

/// `Resolver` supplies:
/// `resolveOutput(peer, handle, object) !struct { id: OutputId, mode: Mode }`.
pub fn Adapter(comptime protocol: type, comptime OutputId: type, comptime Resolver: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_output_power_manager_v1;
        const Power = protocol.zwlr_output_power_v1;
        const Peer = wayring.io_uring.Peer;

        const Slot = struct {
            header: slot_pool.Header = .{},
            peer: Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            output: OutputId = undefined,
            valid: bool = true,
            pending: bool = false,
        };
        const SlotId = packed struct { index: u32, generation: u32 };
        const Event = union(enum) { mode: Mode, failed };
        const Outbound = struct { owner: SlotId, event: Event };
        pub const Command = struct {
            peer: Peer,
            object: objects.Handle,
            output: OutputId,
            mode: Mode,
            token: SlotId,
        };

        allocator: std.mem.Allocator,
        resolver: *Resolver,
        config: Config,
        slots: slot_pool.Pool(Slot),
        outbound: std.ArrayListUnmanaged(Outbound) = .empty,
        commands: std.ArrayListUnmanaged(Command) = .empty,
        command_head: usize = 0,
        outbound_reservations: usize = 0,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, resolver: *Resolver, config: Config) !Self {
            try config.validate();
            return .{
                .allocator = allocator,
                .resolver = resolver,
                .config = config,
                .slots = try slot_pool.Pool(Slot).init(allocator, config.initial_capacity),
            };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit(self.allocator);
            self.outbound.deinit(self.allocator);
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

        pub fn request(self: *Self, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {}, // Children intentionally have no manager dependency.
                    .get_output_power => |value| {
                        const output_handle = server_objects.namespace.lookupHandle(value.output) orelse
                            return try self.protocolError(actor, decoded.handle.id, 0, "invalid wl_output");
                        const output_object = server_objects.namespace.resolve(output_handle) orelse
                            return try self.protocolError(actor, decoded.handle.id, 0, "invalid wl_output");
                        const resolution = self.resolver.resolveOutput(peer, output_handle, output_object) catch
                            return try self.protocolError(actor, decoded.handle.id, 0, "foreign or stale wl_output");
                        try self.ensureOutbound(1);
                        const slot = self.slots.acquire() catch return try self.noMemory(actor);
                        errdefer self.slots.release(slot);
                        const admitted = Manager.admit_get_output_power(server_objects, decoded.handle, value, .{ .id = slot }) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                        slot.peer = peer;
                        slot.resource = admitted.id;
                        slot.output = resolution.id;
                        if (self.findOtherOutput(slot, resolution.id)) {
                            slot.valid = false;
                            self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .failed });
                        } else {
                            self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .{ .mode = resolution.mode } });
                        }
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Power.info) return null;
            const slot = self.slots.fromContext(target.object.context) orelse return null;
            if (!samePeer(slot.peer, peer) or !std.meta.eql(slot.resource, handle)) return null;
            const decoded = try wayring.server.decodeRequest(Power, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => self.release(slot),
                .set_mode => |value| {
                    const mode: Mode = switch (value.mode.value) {
                        0 => .off,
                        1 => .on,
                        else => return try self.protocolError(actor, decoded.handle.id, 1, "invalid output power mode"),
                    };
                    self.submit(slot, mode) catch |err| return try self.failure(actor, decoded.handle.id, err);
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn submit(self: *Self, slot: *Slot, mode: Mode) !void {
            if (!slot.valid) return error.InvalidOutput;
            if (slot.pending) return error.CommandPending;
            if (self.pendingCommandCount() >= self.config.command_capacity) return error.Exhausted;
            if (self.outbound_reservations >= self.config.outbound_capacity -| self.outbound.items.len)
                return error.Exhausted;
            try self.commands.ensureUnusedCapacity(self.allocator, 1);
            try self.outbound.ensureUnusedCapacity(self.allocator, 1);
            self.commands.appendAssumeCapacity(.{ .peer = slot.peer, .object = slot.resource, .output = slot.output, .mode = mode, .token = id(slot) });
            slot.pending = true;
            self.outbound_reservations += 1;
        }

        pub fn peekCommand(self: *const Self) ?Command {
            return if (self.command_head < self.commands.items.len) self.commands.items[self.command_head] else null;
        }

        /// Completes the oldest command. Success publishes the resulting mode;
        /// failure invalidates the control and frees output exclusivity.
        pub fn completeCommand(self: *Self, command: Command, completion: Completion) !void {
            const current = self.peekCommand() orelse return error.NoPendingCommand;
            if (!std.meta.eql(current, command)) return error.WrongCommand;
            const slot = self.resolveId(command.token) orelse return error.StaleCommand;
            std.debug.assert(self.outbound_reservations > 0);
            self.outbound.appendAssumeCapacity(.{ .owner = command.token, .event = switch (completion) {
                .succeeded => .{ .mode = command.mode },
                .failed => .failed,
            } });
            self.outbound_reservations -= 1;
            slot.pending = false;
            if (completion == .failed) slot.valid = false;
            self.advanceCommand();
        }

        /// Invalidates controls for one exact output generation. Queued
        /// commands for them are discarded before exclusivity is reusable.
        pub fn outputRemoved(self: *Self, output: OutputId) !void {
            var count: usize = 0;
            for (self.slots.entries.items) |slot| {
                if (slot.header.active and slot.valid and std.meta.eql(slot.output, output))
                    count += 1;
            }
            try self.ensureOutbound(count);
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.valid and std.meta.eql(slot.output, output)) {
                slot.valid = false;
                slot.pending = false;
                self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .failed });
            };
            self.dropInvalidCommands();
        }

        pub fn flushOn(self: *Self, peer: Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var sent: usize = 0;
            var index: usize = 0;
            while (index < self.outbound.items.len) {
                const out = self.outbound.items[index];
                const slot = self.resolveId(out.owner) orelse {
                    _ = self.outbound.orderedRemove(index);
                    continue;
                };
                if (!samePeer(slot.peer, peer)) {
                    index += 1;
                    continue;
                }
                if (server_objects.namespace.resolve(slot.resource) == null) {
                    _ = self.outbound.orderedRemove(index);
                    continue;
                }
                Power.encodeEvent(queue, slot.resource.id, switch (out.event) {
                    .mode => |mode| .{ .mode = .{ .mode = .fromInt(@intFromEnum(mode)) } },
                    .failed => .{ .failed = .{} },
                }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return sent,
                    else => return err,
                };
                _ = self.outbound.orderedRemove(index);
                sent += 1;
            }
            return sent;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Power.info) if (self.slots.fromContext(object.context)) |slot| {
                if (std.meta.eql(slot.resource, handle)) {
                    self.release(slot);
                    self.dropInvalidCommands();
                    return true;
                }
            };
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn disconnected(self: *Self, peer: Peer) void {
            for (self.slots.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer)) self.release(slot);
            self.dropInvalidCommands();
        }

        pub fn pendingOutbound(self: *const Self, peer: Peer) bool {
            for (self.outbound.items) |out| if (self.resolveIdConst(out.owner)) |slot|
                if (samePeer(slot.peer, peer)) return true;
            return false;
        }

        fn release(self: *Self, slot: *Slot) void {
            if (!slot.header.active) return;
            slot.valid = false;
            slot.pending = false;
            self.slots.release(slot);
        }
        fn findOutput(self: *Self, output: OutputId) ?*Slot {
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.valid and std.meta.eql(slot.output, output)) return slot;
            return null;
        }
        fn findOtherOutput(self: *Self, owner: *const Slot, output: OutputId) bool {
            for (self.slots.entries.items) |slot| {
                if (slot != owner and slot.header.active and slot.valid and std.meta.eql(slot.output, output))
                    return true;
            }
            return false;
        }
        fn resolveId(self: *Self, token: SlotId) ?*Slot {
            const slot = self.slots.at(token.index) orelse return null;
            return if (slot.header.generation == token.generation) slot else null;
        }
        fn resolveIdConst(self: *const Self, token: SlotId) ?*const Slot {
            const slot = @constCast(&self.slots).at(token.index) orelse return null;
            return if (slot.header.generation == token.generation) slot else null;
        }
        fn id(slot: *const Slot) SlotId {
            return .{ .index = slot.header.index, .generation = slot.header.generation };
        }
        fn pendingCommandCount(self: *const Self) usize {
            return self.commands.items.len - self.command_head;
        }
        fn advanceCommand(self: *Self) void {
            self.command_head += 1;
            if (self.command_head == self.commands.items.len) {
                self.commands.clearRetainingCapacity();
                self.command_head = 0;
            }
        }
        fn dropInvalidCommands(self: *Self) void {
            var write = self.command_head;
            var dropped: usize = 0;
            for (self.commands.items[self.command_head..]) |command| {
                if (self.resolveId(command.token)) |slot| {
                    if (!slot.valid) {
                        dropped += 1;
                        continue;
                    }
                    self.commands.items[write] = command;
                    write += 1;
                } else {
                    dropped += 1;
                }
            }
            std.debug.assert(dropped <= self.outbound_reservations);
            self.outbound_reservations -= dropped;
            self.commands.items.len = write;
            if (self.command_head == self.commands.items.len) {
                self.commands.clearRetainingCapacity();
                self.command_head = 0;
            }
        }
        fn ensureOutbound(self: *Self, count: usize) !void {
            if (count > self.config.outbound_capacity -| self.outbound.items.len -| self.outbound_reservations)
                return error.Exhausted;
            try self.outbound.ensureUnusedCapacity(self.allocator, count);
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, object: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, object, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, object: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.OutOfMemory, error.Exhausted => self.noMemory(actor),
                else => self.protocolError(actor, object, 0, @errorName(err)),
            };
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "output power adapter remains core-protocol compile checked when generated" {
    const protocol = @import("core_protocol");
    if (@hasDecl(protocol, "zwlr_output_power_manager_v1")) {
        const Id = packed struct { index: u32, generation: u32 };
        const Resolver = struct {
            pub fn resolveOutput(_: *@This(), _: wayring.io_uring.Peer, _: objects.Handle, _: objects.Object) !struct { id: Id, mode: Mode } {
                return error.InvalidOutput;
            }
        };
        std.testing.refAllDecls(Adapter(protocol, Id, Resolver));
    }
}

test "output power: removal discards a pending command and releases exclusivity" {
    const protocol = @import("core_protocol");
    if (!@hasDecl(protocol, "zwlr_output_power_manager_v1")) return error.SkipZigTest;
    const Id = u32;
    const Resolver = struct {};
    const A = Adapter(protocol, Id, Resolver);
    var resolver = Resolver{};
    var adapter = try A.init(std.testing.allocator, &resolver, .{ .initial_capacity = 2 });
    defer adapter.deinit();
    const slot = try adapter.slots.acquire();
    slot.peer = .{ .slot = 1, .generation = 1 };
    slot.resource = .{ .id = 8, .generation = 2 };
    slot.output = 42;
    try adapter.submit(slot, .off);
    try adapter.outputRemoved(42);
    try std.testing.expect(adapter.peekCommand() == null);
    try std.testing.expect(adapter.findOutput(42) == null);
    const replacement = try adapter.slots.acquire();
    replacement.output = 42;
    try std.testing.expect(adapter.findOutput(42) == null);
}

test "output power: duplicate control fails without taking exclusivity" {
    const protocol = @import("core_protocol");
    if (!@hasDecl(protocol, "zwlr_output_power_manager_v1")) return error.SkipZigTest;
    const Resolver = struct {};
    const A = Adapter(protocol, u32, Resolver);
    var resolver = Resolver{};
    var adapter = try A.init(std.testing.allocator, &resolver, .{ .initial_capacity = 3 });
    defer adapter.deinit();
    const owner = try adapter.slots.acquire();
    owner.output = 42;
    const duplicate = try adapter.slots.acquire();
    duplicate.output = 42;
    try std.testing.expect(adapter.findOtherOutput(duplicate, 42));
    duplicate.valid = false;
    const candidate = try adapter.slots.acquire();
    candidate.output = 42;
    try std.testing.expect(adapter.findOtherOutput(candidate, 42));
    adapter.release(owner);
    try std.testing.expect(!adapter.findOtherOutput(candidate, 42));
}

test "output power: completion capacity is reserved and commands are FIFO" {
    const protocol = @import("core_protocol");
    if (!@hasDecl(protocol, "zwlr_output_power_manager_v1")) return error.SkipZigTest;
    const Resolver = struct {};
    const A = Adapter(protocol, u32, Resolver);
    var resolver = Resolver{};
    var adapter = try A.init(std.testing.allocator, &resolver, .{
        .initial_capacity = 3,
        .outbound_capacity = 2,
    });
    defer adapter.deinit();
    const first = try adapter.slots.acquire();
    first.peer = .{ .slot = 1, .generation = 1 };
    first.resource = .{ .id = 8, .generation = 1 };
    first.output = 1;
    const second = try adapter.slots.acquire();
    second.peer = .{ .slot = 2, .generation = 1 };
    second.resource = .{ .id = 9, .generation = 1 };
    second.output = 2;
    const blocked = try adapter.slots.acquire();
    blocked.peer = .{ .slot = 3, .generation = 1 };
    blocked.resource = .{ .id = 10, .generation = 1 };
    blocked.output = 3;
    try adapter.submit(first, .off);
    try adapter.submit(second, .on);
    try std.testing.expectError(error.Exhausted, adapter.submit(blocked, .off));
    const command = adapter.peekCommand().?;
    try adapter.completeCommand(command, .succeeded);
    try std.testing.expectEqual(@as(u32, 2), adapter.peekCommand().?.output);
    try std.testing.expectEqual(@as(usize, 1), adapter.outbound_reservations);
}
