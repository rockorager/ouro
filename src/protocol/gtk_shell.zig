//! Bounded gtk-shell v5 compatibility metadata and configure adapter.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 16,
    string_bytes: usize = 4096,
    fn validate(c: Config) !void {
        if (c.resource_capacity == 0 or c.resource_capacity >= none or c.string_bytes == 0)
            return error.InvalidConfig;
        _ = std.math.mul(usize, c.resource_capacity, c.string_bytes) catch return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Shell = protocol.gtk_shell1;
        const Surface = protocol.gtk_surface1;
        pub const GestureValidator = struct {
            context: *anyopaque,
            validateFn: *const fn (*anyopaque, wayring.io_uring.Peer, u32, u32, CoreSurface.SurfaceId) bool,
            pub fn validate(v: @This(), peer: wayring.io_uring.Peer, seat: u32, serial: u32, surface: CoreSurface.SurfaceId) bool {
                return v.validateFn(v.context, peer, seat, serial, surface);
            }
        };
        const Kind = enum { shell, surface };
        const Text = struct { offset: usize = 0, len: usize = 0 };
        const Slot = struct {
            header: slot_pool.Header = .{},
            kind: Kind = .shell,
            handle: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            version: u32 = 1,
            surface: ?CoreSurface.SurfaceId = null,
            strings: [7]Text = .{Text{}} ** 7,
            used: usize = 0,
            modal: bool = false,
            capabilities_pending: bool = false,
            configure_pending: bool = false,
            states: [5]bool = .{false} ** 5,
            floating: bool = true,
            text: ?[]u8 = null,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        slots: slot_pool.Pool(Slot),
        string_bytes: usize,
        validator: ?GestureValidator = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            try config.validate();
            const slots = try slot_pool.Pool(Slot).init(allocator, config.resource_capacity);
            return .{ .allocator = allocator, .core = core, .slots = slots, .string_bytes = config.string_bytes };
        }
        pub fn deinit(self: *Self) void {
            for (self.slots.entries.items) |slot| if (slot.text) |text| self.allocator.free(text);
            self.slots.deinit();
            self.* = undefined;
        }
        pub fn setGestureValidator(self: *Self, validator: GestureValidator) void {
            self.validator = validator;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            return runtime.addGlobalWithBinder(&Shell.info, 5, self, bind);
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = try self.acquire(.shell, binding.resource, binding.peer, binding.version, null);
            slot.capabilities_pending = true;
            return slot;
        }
        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const slot = self.fromObject(target.object) orelse return null;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (!std.meta.eql(slot.handle, handle) or !samePeer(slot.peer, peer)) return null;
            if (slot.kind == .shell and target.object.interface == &Shell.info) {
                const d = try wayring.server.decodeRequest(Shell, server_objects, message, fds);
                switch (d.value) {
                    .get_gtk_surface => |v| {
                        const sid = self.core.surfaceIdOn(server_objects, v.surface) catch return try self.failure(actor, d.handle.id, error.InvalidSurface);
                        if (self.findSurface(sid) != null) return try self.failure(actor, d.handle.id, error.SurfaceAlreadyHasGtkSurface);
                        const child = self.acquire(.surface, undefined, peer, slot.version, sid) catch return try self.noMemory(actor);
                        const admitted = Shell.admit_get_gtk_surface(server_objects, d.handle, v, .{ .gtk_surface = child }) catch |e| {
                            self.release(child);
                            return try self.failure(actor, d.handle.id, e);
                        };
                        child.handle = admitted.gtk_surface;
                    },
                    .set_startup_id => |v| self.replaceAll(slot, &.{v.startup_id}) catch |e| return try self.failure(actor, d.handle.id, e),
                    .system_bell => |v| if (v.surface) |id| if (!self.validSurfaceObject(server_objects, peer, id)) return try self.failure(actor, d.handle.id, error.InvalidGtkSurface),
                    .notify_launch => |v| if (v.startup_id.len > self.string_bytes) return try self.failure(actor, d.handle.id, error.StringTooLong),
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (slot.kind == .surface and target.object.interface == &Surface.info) {
                const d = try wayring.server.decodeRequest(Surface, server_objects, message, fds);
                switch (d.value) {
                    .release => {}, // Destructor remains valid after wl_surface destruction.
                    .set_dbus_properties => |v| if (slot.surface != null) self.replaceAll(slot, &.{ v.application_id, v.app_menu_path, v.menubar_path, v.window_object_path, v.application_object_path, v.unique_bus_name }) catch |e| return try self.failure(actor, d.handle.id, e),
                    .set_modal => if (slot.surface != null) {
                        slot.modal = true;
                    },
                    .unset_modal => if (slot.surface != null) {
                        slot.modal = false;
                    },
                    .present => {},
                    .request_focus => |v| if (slot.surface != null) if (v.startup_id) |id| if (id.len > self.string_bytes) return try self.failure(actor, d.handle.id, error.StringTooLong),
                    .titlebar_gesture => |v| {
                        if (v.gesture.value < 1 or v.gesture.value > 3) return try self.protocolError(actor, d.handle.id, Surface.@"error".invalid_gesture.value, "invalid titlebar gesture");
                        if (slot.surface) |sid| {
                            if (self.validator) |validator| _ = validator.validate(peer, v.seat, v.serial, sid);
                        }
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        pub fn queueConfigure(self: *Self, surface: CoreSurface.SurfaceId, states: anytype) void {
            if (self.findSurface(surface)) |slot| {
                const tiled = states.tiled_left or states.tiled_right or states.tiled_top or states.tiled_bottom;
                slot.states = .{ tiled, states.tiled_top, states.tiled_right, states.tiled_bottom, states.tiled_left };
                slot.floating = !tiled;
                slot.configure_pending = true;
            }
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.slots.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer) and server_objects.namespace.resolve(slot.handle) != null) {
                if (slot.capabilities_pending) {
                    try Shell.encodeEvent(queue, slot.handle.id, .{ .capabilities = .{ .capabilities = 0 } });
                    slot.capabilities_pending = false;
                    count += 1;
                }
                if (slot.configure_pending) {
                    var sb: [20]u8 = undefined;
                    var eb: [16]u8 = undefined;
                    try Surface.encodeEvent(queue, slot.handle.id, .{ .configure = .{ .states = encodeSet(slot.states[0..], &sb) } });
                    if (slot.version >= 2) {
                        const edges = [_]bool{slot.floating} ** 4;
                        try Surface.encodeEvent(queue, slot.handle.id, .{ .configure_edges = .{ .constraints = encodeSet(&edges, &eb) } });
                    }
                    slot.configure_pending = false;
                    count += 1;
                }
            };
            return count;
        }
        pub fn pendingOutbound(self: *Self, peer: wayring.io_uring.Peer) bool {
            for (self.slots.entries.items) |s| if (s.header.active and samePeer(s.peer, peer) and (s.capabilities_pending or s.configure_pending)) return true;
            return false;
        }
        pub fn surfaceRemoved(self: *Self, id: CoreSurface.SurfaceId) void {
            if (self.findSurface(id)) |s| {
                s.surface = null;
                s.configure_pending = false;
            }
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            const s = self.fromObject(&object) orelse return false;
            if (!std.meta.eql(s.handle, handle)) return false;
            self.release(s);
            return true;
        }
        fn acquire(self: *Self, kind: Kind, handle: objects.Handle, peer: wayring.io_uring.Peer, version: u32, surface: ?CoreSurface.SurfaceId) !*Slot {
            const s = try self.slots.acquire();
            s.kind = kind;
            s.handle = handle;
            s.peer = peer;
            s.version = version;
            s.surface = surface;
            return s;
        }
        fn release(self: *Self, s: *Slot) void {
            if (!s.header.active) return;
            if (s.text) |text| self.allocator.free(text);
            s.text = null;
            self.slots.release(s);
        }
        fn replaceAll(self: *Self, s: *Slot, values: []const ?[]const u8) !void {
            var needed: usize = 0;
            for (values) |v| if (v) |text| {
                needed = std.math.add(usize, needed, text.len) catch return error.StringTooLong;
            };
            if (needed > self.string_bytes) return error.StringTooLong;
            if (s.text == null) s.text = try self.allocator.alloc(u8, self.string_bytes);
            const storage = s.text.?;
            var at: usize = 0;
            for (values, 0..) |v, i| {
                s.strings[i] = .{ .offset = at, .len = if (v) |text| text.len else 0 };
                if (v) |text| {
                    @memcpy(storage[at..][0..text.len], text);
                    at += text.len;
                }
            }
            s.used = needed;
        }
        fn findSurface(self: *Self, id: CoreSurface.SurfaceId) ?*Slot {
            for (self.slots.entries.items) |s| if (s.header.active and s.kind == .surface and s.surface != null and std.meta.eql(s.surface.?, id)) return s;
            return null;
        }
        fn fromObject(self: *Self, object: *const objects.Object) ?*Slot {
            return self.slots.fromContext(object.context);
        }
        fn validSurfaceObject(self: *Self, server_objects: anytype, peer: wayring.io_uring.Peer, id: u32) bool {
            const h = server_objects.namespace.lookupHandle(id) orelse return false;
            const o = server_objects.namespace.resolve(h) orelse return false;
            const s = self.fromObject(o) orelse return false;
            return s.kind == .surface and samePeer(s.peer, peer) and std.meta.eql(s.handle, h);
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
fn encodeSet(values: []const bool, storage: []u8) []const u8 {
    var offset: usize = 0;
    for (values, 0..) |set, i| if (set) {
        std.mem.writeInt(u32, storage[offset..][0..4], @intCast(i + 1), .little);
        offset += 4;
    };
    return storage[0..offset];
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "gtk slots recycle generation-safely and metadata replacement is atomic" {
    const Fake = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const A = Adapter(@import("core_protocol"), Fake);
    var core: Fake = .{};
    var a = try A.init(std.testing.allocator, &core, .{ .resource_capacity = 1, .string_bytes = 5 });
    defer a.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const s = try a.acquire(.surface, .{ .id = 3, .generation = 4 }, peer, 5, .{ .index = 1, .generation = 1 });
    try a.replaceAll(s, &.{"abc"});
    const old = s.text.?[0..3].*;
    try std.testing.expectError(error.StringTooLong, a.replaceAll(s, &.{ "abc", "def" }));
    try std.testing.expectEqualSlices(u8, &old, s.text.?[0..3]);
    const generation = s.header.generation;
    const grown = try a.acquire(.shell, .{ .id = 8, .generation = 1 }, peer, 5, null);
    try std.testing.expect(grown != s);
    a.release(grown);
    a.release(s);
    const reused = try a.acquire(.shell, .{ .id = 4, .generation = 5 }, peer, 5, null);
    try std.testing.expect(reused.header.generation != generation);
    try std.testing.expect(a.fromObject(&.{ .interface = &@import("core_protocol").gtk_shell1.info, .version = 5, .context = s }) == reused);
}

test "gtk configure arrays match v5 wire values" {
    var b: [20]u8 = undefined;
    const values = [_]bool{ true, true, false, false, true };
    const bytes = encodeSet(&values, &b);
    try std.testing.expectEqual(@as(usize, 12), bytes.len);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, bytes[8..12], .little));
}
