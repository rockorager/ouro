//! Bounded xdg-toplevel-drag-v1 source reservation and attachment lifecycle.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    drag_capacity: usize = 32,

    fn validate(config: Config) !void {
        if (config.drag_capacity == 0 or config.drag_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Shell: type, comptime DataDevice: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xdg_toplevel_drag_manager_v1;
        const ToplevelDrag = protocol.xdg_toplevel_drag_v1;

        pub const Attachment = struct {
            toplevel: Shell.ToplevelId,
            x_offset: i32,
            y_offset: i32,
            initially_mapped: bool,
            mapped_once: bool,
        };

        const Slot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            source: DataDevice.DragSourceId = undefined,
            attachment: ?Attachment = null,
        };

        allocator: std.mem.Allocator,
        shell: *Shell,
        data_device: *DataDevice,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: []Slot,
        free_head: u32 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            shell: *Shell,
            data_device: *DataDevice,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.drag_capacity);
            for (slots, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none,
            };
            return .{
                .allocator = allocator,
                .shell = shell,
                .data_device = data_device,
                .slots = slots,
            };
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

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                peer,
                target,
                message,
                fds,
            );
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
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_xdg_toplevel_drag => |payload| {
                        const source = self.data_device.reserveToplevelDragSource(
                            peer,
                            server_objects,
                            payload.data_source,
                        ) catch {
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                Manager.@"error".invalid_source.value,
                                "data source is already used or belongs to another client",
                            );
                        };
                        const slot = self.acquire() catch {
                            self.data_device.releaseToplevelDragSource(source);
                            return try self.noMemory(actor);
                        };
                        slot.peer = peer;
                        slot.source = source;
                        const admitted = Manager.admit_get_xdg_toplevel_drag(
                            server_objects,
                            decoded.handle,
                            payload,
                            .{ .id = slot },
                        ) catch |err| {
                            self.release(self.index(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &ToplevelDrag.info) {
                const slot = self.fromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(ToplevelDrag, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => switch (self.data_device.toplevelDragSourceState(slot.source)) {
                        .reserved, .active => return try self.protocolError(
                            actor,
                            decoded.handle.id,
                            ToplevelDrag.@"error".ongoing_drag.value,
                            "underlying drag has not ended",
                        ),
                        .ended, .gone => {},
                    },
                    .attach => |payload| {
                        const toplevel = self.shell.toplevelIdOn(server_objects, payload.toplevel) catch {
                            try decoded.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        };
                        if (slot.attachment != null)
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                ToplevelDrag.@"error".toplevel_attached.value,
                                "a valid toplevel is already attached",
                            );
                        const mapped = self.shell.toplevelMapped(toplevel);
                        slot.attachment = .{
                            .toplevel = toplevel,
                            .x_offset = payload.x_offset,
                            .y_offset = payload.y_offset,
                            .initially_mapped = mapped,
                            .mapped_once = mapped,
                        };
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        /// Returns the mapped toplevel moved by the currently active DnD.
        pub fn activeAttachment(self: *Self) ?Attachment {
            for (self.slots) |*slot| {
                if (!slot.active or slot.attachment == null) continue;
                const attachment = slot.attachment.?;
                if (self.shell.toplevelMapped(attachment.toplevel)) {
                    slot.attachment.?.mapped_once = true;
                } else {
                    if (attachment.mapped_once) slot.attachment = null;
                    continue;
                }
                if (self.data_device.toplevelDragSourceState(slot.source) == .active)
                    return slot.attachment.?;
            }
            return null;
        }

        /// Called before Shell retires or unmaps an xdg_toplevel.
        pub fn toplevelRemoved(self: *Self, handle: objects.Handle, object: objects.Object) void {
            const id = self.shell.toplevelIdResource(handle, &object) catch return;
            self.detach(id);
        }

        pub fn toplevelUnmapped(self: *Self, id: Shell.ToplevelId) void {
            self.detach(id);
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &ToplevelDrag.info) {
                const slot = self.fromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.release(self.index(slot));
                return true;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn detach(self: *Self, id: Shell.ToplevelId) void {
            for (self.slots) |*slot| {
                if (!slot.active or slot.attachment == null) continue;
                if (std.meta.eql(slot.attachment.?.toplevel, id)) slot.attachment = null;
            }
        }

        fn acquire(self: *Self) !*Slot {
            if (self.free_head == none) return error.Exhausted;
            const i = self.free_head;
            const slot = &self.slots[i];
            self.free_head = slot.next_free;
            slot.* = .{ .active = true, .generation = slot.generation };
            return slot;
        }

        fn release(self: *Self, i: u32) void {
            const slot = &self.slots[i];
            if (!slot.active) return;
            self.data_device.releaseToplevelDragSource(slot.source);
            const generation = slot.generation +% 1;
            slot.* = .{
                .generation = if (generation == 0) 1 else generation,
                .next_free = self.free_head,
            };
            self.free_head = i;
        }

        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            const ptr = object.context orelse return null;
            const address = @intFromPtr(ptr);
            const start = @intFromPtr(self.slots.ptr);
            const end = start + self.slots.len * @sizeOf(Slot);
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
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

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, message);
            return .stop;
        }

        fn failure(
            self: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            err: anyerror,
        ) !wayring.dispatch.Control {
            return self.protocolError(actor, id, 0, @errorName(err));
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg toplevel drag attachment follows active mapped source lifecycle" {
    const protocol = @import("core_protocol");
    const FakeShell = struct {
        pub const ToplevelId = packed struct { index: u32, generation: u32 };
        mapped: bool = true,

        pub fn toplevelMapped(self: *@This(), _: ToplevelId) bool {
            return self.mapped;
        }
    };
    const FakeDataDevice = struct {
        pub const DragSourceId = packed struct { index: u32, generation: u32 };
        pub const DragSourceState = enum { reserved, active, ended, gone };
        state: DragSourceState = .reserved,
        releases: usize = 0,

        pub fn toplevelDragSourceState(self: *@This(), _: DragSourceId) DragSourceState {
            return self.state;
        }
        pub fn releaseToplevelDragSource(self: *@This(), _: DragSourceId) void {
            self.releases += 1;
        }
    };
    const A = Adapter(protocol, FakeShell, FakeDataDevice);
    var shell: FakeShell = .{};
    var data_device: FakeDataDevice = .{};
    var adapter = try A.init(std.testing.allocator, &shell, &data_device, .{ .drag_capacity = 1 });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.source = .{ .index = 2, .generation = 3 };
    slot.attachment = .{
        .toplevel = .{ .index = 4, .generation = 5 },
        .x_offset = 6,
        .y_offset = 7,
        .initially_mapped = true,
        .mapped_once = true,
    };

    try std.testing.expect(adapter.activeAttachment() == null);
    data_device.state = .active;
    try std.testing.expect(adapter.activeAttachment() != null);
    shell.mapped = false;
    try std.testing.expect(adapter.activeAttachment() == null);
    try std.testing.expect(slot.attachment == null);
    shell.mapped = true;
    try std.testing.expect(adapter.activeAttachment() == null);
    adapter.release(0);
    try std.testing.expectEqual(@as(usize, 1), data_device.releases);
    const replacement = try adapter.acquire();
    try std.testing.expect(replacement.generation != 1);
}
