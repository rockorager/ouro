//! Bounded xdg-dialog-v1 lifecycle and metadata adapter.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 16,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Shell: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xdg_wm_dialog_v1;
        const Dialog = protocol.xdg_dialog_v1;

        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            toplevel: ?Shell.ToplevelId = null,
            modal: bool = false,
        };

        allocator: std.mem.Allocator,
        shell: *Shell,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: []Slot,
        free_head: u32 = 0,

        pub fn init(allocator: std.mem.Allocator, shell: *Shell, config: Config) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.resource_capacity);
            for (slots, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none,
            };
            return .{ .allocator = allocator, .shell = shell, .slots = slots };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.slots);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            self.global = global;
            return global;
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
                    .get_xdg_dialog => |payload| {
                        const id = self.shell.toplevelIdOn(server_objects, payload.toplevel) catch
                            return try self.failure(actor, decoded.handle.id, error.InvalidToplevel);
                        if (self.find(id) != null)
                            return try self.protocolError(actor, decoded.handle.id, Manager.@"error".already_used.value, "xdg_toplevel already has a dialog object");
                        const metadata_changed = self.shell.prepareDialogState(id, true, false) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.toplevel = id;
                        const admitted = Manager.admit_get_xdg_dialog(server_objects, decoded.handle, payload, .{ .id = slot }) catch |err| {
                            self.release(self.index(slot), false);
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        if (metadata_changed) self.shell.setDialogStatePrepared(id, true, false);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Dialog.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Dialog, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .set_modal => if (!slot.modal) {
                        if (slot.toplevel) |id| _ = self.shell.setDialogState(id, true, true) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                        slot.modal = true;
                    },
                    .unset_modal => if (slot.modal) {
                        if (slot.toplevel) |id| _ = self.shell.setDialogState(id, true, false) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                        slot.modal = false;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        /// Called before Shell handles xdg_toplevel removal.
        pub fn toplevelRemoved(self: *Self, handle: objects.Handle, object: objects.Object) void {
            const id = self.shell.toplevelIdResource(handle, &object) catch return;
            if (self.find(id)) |slot| slot.toplevel = null;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Dialog.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(self.index(slot), true);
                return true;
            }
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const i = self.free_head;
            const slot = &self.slots[i];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true, .generation = slot.generation };
            return slot;
        }

        fn release(self: *Self, i: u32, clear: bool) void {
            const slot = &self.slots[i];
            if (!slot.active) return;
            if (clear) {
                if (slot.toplevel) |id| _ = self.shell.setDialogState(id, false, false) catch {};
            }
            const generation = slot.generation +% 1;
            slot.* = .{ .generation = if (generation == 0) 1 else generation, .next_free = self.free_head };
            self.free_head = i;
        }

        fn find(self: *Self, id: Shell.ToplevelId) ?*Slot {
            for (self.slots) |*slot| if (slot.active and slot.toplevel != null and std.meta.eql(slot.toplevel.?, id)) return slot;
            return null;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const ptr = object.context orelse return null;
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(self.slots.ptr);
            const end = start + self.slots.len * @sizeOf(Slot);
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0) return null;
            const slot = &self.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active) slot else null;
        }

        fn index(self: *Self, slot: *Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return self.protocolError(actor, id, 0, @errorName(err));
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg dialog slots are bounded, independent, inert, and generation safe" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const ToplevelId = packed struct { index: u32, generation: u32 };
        states: [2]struct { dialog: bool = false, modal: bool = false } = .{ .{}, .{} },
        pub fn setDialogState(self: *@This(), id: ToplevelId, dialog: bool, modal: bool) !bool {
            const changed = try self.prepareDialogState(id, dialog, modal);
            if (changed) self.setDialogStatePrepared(id, dialog, modal);
            return changed;
        }
        pub fn prepareDialogState(self: *@This(), id: ToplevelId, dialog: bool, modal: bool) !bool {
            if (id.index >= self.states.len) return error.StaleToplevel;
            const state = &self.states[id.index];
            return state.dialog != (dialog or modal) or state.modal != modal;
        }
        pub fn setDialogStatePrepared(self: *@This(), id: ToplevelId, dialog: bool, modal: bool) void {
            const state = &self.states[id.index];
            state.* = .{ .dialog = dialog or modal, .modal = modal };
        }
    };
    const A = Adapter(protocol, FakeShell);
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &shell, .{ .resource_capacity = 1 });
    defer adapter.deinit();
    const first = try adapter.acquire();
    first.toplevel = .{ .index = 0, .generation = 1 };
    _ = try shell.setDialogState(first.toplevel.?, true, false);
    try std.testing.expect(adapter.find(first.toplevel.?) != null);
    try std.testing.expectError(error.Exhausted, adapter.acquire());
    adapter.release(0, true);
    try std.testing.expect(!shell.states[0].dialog);
    const second = try adapter.acquire();
    try std.testing.expect(second.generation != 1);
    second.toplevel = .{ .index = 1, .generation = 2 };
    second.modal = true;
    _ = try shell.setDialogState(second.toplevel.?, true, true);
    second.toplevel = null;
    adapter.release(0, true);
    try std.testing.expect(shell.states[1].dialog and shell.states[1].modal);
}
