//! Bounded XDG decoration negotiation.
//!
//! Ouro does not draw server-side window frames yet, so every negotiation
//! resolves honestly to client-side decoration. Each mode event is ordered
//! before the corresponding xdg_surface configure by the physical runtime.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 16,
    event_capacity: usize = 16,
    global_version: u32 = 2,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none or
            config.event_capacity == 0 or config.event_capacity >= none or
            config.global_version == 0 or config.global_version > 2)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Shell: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zxdg_decoration_manager_v1;
        const Decoration = protocol.zxdg_toplevel_decoration_v1;

        pub const Event = union(enum) {
            reconfigure: Shell.ToplevelId,
        };

        const Id = packed struct { index: u32, generation: u32 };
        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            toplevel: Shell.ToplevelId = undefined,
            configure_pending: bool = false,
        };

        allocator: std.mem.Allocator,
        shell: *Shell,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        slots: []Slot,
        events: []Id,
        free_head: u32 = 0,
        event_head: usize = 0,
        event_len: usize = 0,
        configure_pending_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, shell: *Shell, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const slots = try allocator.alloc(Slot, config.resource_capacity);
            errdefer allocator.free(slots);
            const events = try allocator.alloc(Id, config.event_capacity);
            for (slots, 0..) |*slot, slot_index| slot.* = .{
                .next_free = if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else none,
            };
            return .{
                .allocator = allocator,
                .shell = shell,
                .global_version = config.global_version,
                .slots = slots,
                .events = events,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Manager.info,
                self.global_version,
                self,
                bind,
            );
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
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
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_toplevel_decoration => |payload| {
                        const toplevel = self.shell.toplevelIdOn(server_objects, payload.toplevel) catch
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                Decoration.@"error".orphaned.value,
                                "invalid xdg_toplevel",
                            );
                        if (self.findToplevel(toplevel) != null)
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                Decoration.@"error".already_constructed.value,
                                "xdg_toplevel already has a decoration object",
                            );
                        if (self.event_len == self.events.len) return try self.noMemory(actor);
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.toplevel = toplevel;
                        const admitted = Manager.admit_get_toplevel_decoration(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .id = slot },
                        ) catch |err| {
                            self.release(self.slotIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        self.queueConfigure(slot);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Decoration.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Decoration, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_mode => |payload| {
                        const mode = payload.mode.value;
                        if (mode != Decoration.mode.client_side.value and
                            mode != Decoration.mode.server_side.value)
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                Decoration.@"error".invalid_mode.value,
                                "invalid decoration mode",
                            );
                        if (!slot.configure_pending) {
                            if (self.event_len == self.events.len) return try self.noMemory(actor);
                            self.queueConfigure(slot);
                        }
                    },
                    .unset_mode => if (!slot.configure_pending) {
                        if (self.event_len == self.events.len) return try self.noMemory(actor);
                        self.queueConfigure(slot);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn peekEvent(self: *Self) ?Event {
            while (self.event_len != 0) {
                const event_id = self.events[self.event_head];
                const slot = self.resolve(event_id) catch {
                    self.dropEvent();
                    continue;
                };
                return .{ .reconfigure = slot.toplevel };
            }
            return null;
        }

        pub fn dropEvent(self: *Self) void {
            std.debug.assert(self.event_len != 0);
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_len -= 1;
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (self.configure_pending_len == 0) return completed;
            for (self.slots) |*slot| {
                if (!slot.active or !samePeer(slot.peer, peer) or !slot.configure_pending)
                    continue;
                if (self.eventQueued(self.slotId(slot))) continue;
                wayring.server.sendEvent(
                    protocol,
                    Decoration,
                    server_objects,
                    queue,
                    slot.resource,
                    .{ .configure = .{ .mode = Decoration.mode.client_side } },
                ) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.configure_pending = false;
                self.configure_pending_len -= 1;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.configure_pending_len == 0) return false;
            for (self.slots) |slot|
                if (slot.active and samePeer(slot.peer, peer) and slot.configure_pending)
                    return true;
            return false;
        }

        pub fn readyOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.configure_pending_len == 0) return false;
            for (self.slots) |*slot| {
                if (slot.active and samePeer(slot.peer, peer) and slot.configure_pending and
                    !self.eventQueued(self.slotId(slot))) return true;
            }
            return false;
        }

        pub fn toplevelRemoved(self: *Self, handle: objects.Handle, object: objects.Object) void {
            const toplevel = self.shell.toplevelIdResource(handle, &object) catch return;
            const slot = self.findToplevel(toplevel) orelse return;
            if (self.runtime) |runtime| {
                const actor = runtime.clients.reactor.getActor(slot.peer) catch null;
                if (actor) |value| ProtocolCore.postError(
                    value,
                    slot.resource.id,
                    Decoration.@"error".orphaned.value,
                    "xdg_toplevel destroyed before its decoration object",
                ) catch {};
            }
            self.release(self.slotIndex(slot));
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Decoration.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(self.slotIndex(slot));
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn queueConfigure(self: *Self, slot: *Slot) void {
            std.debug.assert(!slot.configure_pending and self.event_len < self.events.len);
            slot.configure_pending = true;
            self.configure_pending_len += 1;
            const tail = (self.event_head + self.event_len) % self.events.len;
            self.events[tail] = self.slotId(slot);
            self.event_len += 1;
        }

        fn eventQueued(self: *const Self, id_value: Id) bool {
            for (0..self.event_len) |offset| {
                const index_value = (self.event_head + offset) % self.events.len;
                if (std.meta.eql(self.events[index_value], id_value)) return true;
            }
            return false;
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const index_value = self.free_head;
            const slot = &self.slots[index_value];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true, .generation = slot.generation };
            return slot;
        }

        fn release(self: *Self, index_value: u32) void {
            const slot = &self.slots[index_value];
            if (!slot.active) return;
            if (slot.configure_pending) self.configure_pending_len -= 1;
            const generation = slot.generation +% 1;
            slot.* = .{
                .generation = if (generation == 0) 1 else generation,
                .next_free = self.free_head,
            };
            self.free_head = index_value;
        }

        fn resolve(self: *Self, slot_id: Id) !*Slot {
            if (slot_id.index >= self.slots.len) return error.Stale;
            const slot = &self.slots[slot_id.index];
            if (!slot.active or slot.generation != slot_id.generation) return error.Stale;
            return slot;
        }

        fn findToplevel(self: *Self, toplevel: Shell.ToplevelId) ?*Slot {
            for (self.slots) |*slot|
                if (slot.active and std.meta.eql(slot.toplevel, toplevel)) return slot;
            return null;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(self.slots.ptr);
            const size = std.math.mul(usize, self.slots.len, @sizeOf(Slot)) catch return null;
            const end = std.math.add(usize, start, size) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
            const slot = &self.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active and @intFromPtr(slot) == address) slot else null;
        }

        fn slotId(self: *const Self, slot: *const Slot) Id {
            return .{ .index = self.slotIndex(slot), .generation = slot.generation };
        }

        fn slotIndex(self: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id_value: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id_value, code, message);
            return .stop;
        }

        fn failure(
            self: *Self,
            actor: *wayring.connection.Actor,
            id_value: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return self.protocolError(actor, id_value, 0, @errorName(cause));
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg decoration: bounded negotiation stays client-side and coalesces requests" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const ToplevelId = packed struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(protocol, FakeShell);
    var shell: FakeShell = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &shell, .{
        .resource_capacity = 1,
        .event_capacity = 1,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const slot = try adapter.acquire();
    slot.peer = .{ .slot = 1, .generation = 2 };
    slot.toplevel = .{ .index = 3, .generation = 4 };
    slot.resource = try server_objects.insertClient(
        4,
        &protocol.zxdg_toplevel_decoration_v1.info,
        2,
        slot,
    );
    adapter.queueConfigure(slot);

    try std.testing.expect(adapter.pendingOutbound(slot.peer));
    try std.testing.expect(!adapter.readyOutbound(slot.peer));
    try std.testing.expectEqual(TestAdapter.Event{ .reconfigure = slot.toplevel }, adapter.peekEvent().?);
    try std.testing.expectError(error.Exhausted, adapter.acquire());
    adapter.dropEvent();
    try std.testing.expect(adapter.readyOutbound(slot.peer));
    try std.testing.expectEqual(@as(?TestAdapter.Event, null), adapter.peekEvent());

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 128, &descriptors, 1);
    defer output.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(slot.peer, &server_objects, &output),
    );
    try std.testing.expect(!adapter.pendingOutbound(slot.peer));
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    const event = try protocol.zxdg_toplevel_decoration_v1.decodeEvent(message, &fds);
    try std.testing.expectEqual(
        protocol.zxdg_toplevel_decoration_v1.mode.client_side,
        event.configure.mode,
    );
}
