//! Bounded virtual-keyboard-unstable-v1 adapter.
const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const objects = wayring.objects;
const linux = std.os.linux;
const c = @cImport(@cInclude("sys/stat.h"));
const none = std.math.maxInt(u32);
const key_count = 0x300;
const key_words = key_count / 64;

pub const Config = struct {
    manager_capacity: usize = 4,
    device_capacity: usize = 16,

    fn validate(config: Config) !void {
        if (config.manager_capacity == 0 or config.manager_capacity >= none or
            config.device_capacity == 0 or config.device_capacity >= none)
            return error.InvalidConfig;
    }
};

pub const KeymapObserver = struct {
    context: ?*anyopaque = null,
    canUpdateFn: *const fn (?*anyopaque) bool,
    updatedFn: *const fn (?*anyopaque) void,
};

pub fn Adapter(comptime protocol: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_virtual_keyboard_manager_v1;
        const Keyboard = protocol.zwp_virtual_keyboard_v1;
        const ManagerSlot = struct {
            active: bool = false,
            next: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        pub const DeviceId = packed struct { index: u32, generation: u32 };
        const Device = struct {
            active: bool = false,
            generation: u32 = 1,
            next: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            seat_valid: bool = false,
            keymap: bool = false,
            registered: bool = false,
            deferred_fd: linux.fd_t = -1,
            deferred_size: u32 = 0,
            pressed: [key_words]u64 = [_]u64{0} ** key_words,
        };

        allocator: std.mem.Allocator,
        seat: *Seat,
        managers: []ManagerSlot,
        devices: []Device,
        manager_free: u32 = 0,
        device_free: u32 = 0,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        modifier_owner: ?DeviceId = null,
        inhibited: bool = false,
        keymap_observer: ?KeymapObserver = null,

        pub fn init(allocator: std.mem.Allocator, seat: *Seat, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(1);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const devices = try allocator.alloc(Device, config.device_capacity);
            initFree(ManagerSlot, managers);
            initFree(Device, devices);
            return .{ .allocator = allocator, .seat = seat, .managers = managers, .devices = devices };
        }

        pub fn deinit(self: *Self) void {
            for (self.devices, 0..) |device, i| if (device.active) self.releaseDevice(@intCast(i));
            self.allocator.free(self.devices);
            self.allocator.free(self.managers);
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

        pub fn setKeymapObserver(self: *Self, observer: ?KeymapObserver) void {
            self.keymap_observer = observer;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (self.manager_free == none) return error.OutOfMemory;
            const i = self.manager_free;
            self.manager_free = self.managers[i].next;
            self.managers[i] = .{ .active = true, .resource = binding.resource, .peer = binding.peer };
            return &self.managers[i];
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !same(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .create_virtual_keyboard => |payload| {
                        const device = self.acquireDevice() catch return try self.noMemory(actor);
                        device.peer = peer;
                        device.seat_valid = self.seat.ownsSeat(peer, payload.seat);
                        const admitted = Manager.admit_create_virtual_keyboard(server_objects, decoded.handle, payload, .{ .id = device }) catch |err| {
                            self.releaseDevice(self.deviceIndex(device));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        device.resource = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Keyboard.info) {
                const device = from(Device, self.devices, target.object.context) orelse return null;
                if (!std.meta.eql(device.resource, handle) or !same(device.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Keyboard, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .keymap => |payload| {
                        var fd = payload.fd;
                        defer {
                            if (fd >= 0) _ = linux.close(fd);
                        }
                        if (!device.seat_valid) {
                            try decoded.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        }
                        if (payload.format.value != protocol.wl_keyboard.keymap_format.xkb_v1.value)
                            return try self.protocolError(actor, decoded.handle.id, Keyboard.@"error".invalid_keymap_format.value, "invalid keymap format");
                        validateKeymap(fd, payload.size) catch
                            return try self.failure(actor, decoded.handle.id, error.InvalidKeymap);
                        if (!self.inhibited) if (self.keymap_observer) |observer| {
                            if (!observer.canUpdateFn(observer.context)) return try self.noMemory(actor);
                        };
                        const id = self.inputId(device);
                        const added = !device.registered;
                        if (added) {
                            self.seat.addVirtualKeyboard(id) catch return try self.noMemory(actor);
                            device.registered = true;
                        }
                        if (self.inhibited) {
                            if (device.deferred_fd >= 0) _ = linux.close(device.deferred_fd);
                            device.deferred_fd = fd;
                            device.deferred_size = payload.size;
                            fd = -1;
                        } else {
                            self.seat.setKeymapOwned(fd, payload.size) catch |err| {
                                if (added) {
                                    self.seat.removeVirtualKeyboard(id) catch {};
                                    device.registered = false;
                                }
                                return try self.failure(actor, decoded.handle.id, err);
                            };
                            fd = -1;
                            if (self.keymap_observer) |observer| observer.updatedFn(observer.context);
                        }
                        device.keymap = true;
                    },
                    .key => |payload| {
                        if (!device.seat_valid) {
                            try decoded.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        }
                        if (!device.keymap) return try self.noKeymap(actor, decoded.handle.id);
                        if (payload.state > 1) return try self.failure(actor, decoded.handle.id, error.InvalidKeyState);
                        if (device.registered and !self.inhibited) {
                            if (payload.key >= key_count)
                                return try self.failure(actor, decoded.handle.id, error.InvalidKeyCode);
                            const mask = @as(u64, 1) << @intCast(payload.key & 63);
                            const word = &device.pressed[payload.key / 64];
                            const pressed = payload.state == 1;
                            if ((word.* & mask != 0) != pressed) {
                                if (pressed) word.* |= mask else word.* &= ~mask;
                                self.seat.virtualKeyboardKey(self.inputId(device), payload.time, payload.key, pressed) catch |err|
                                    return try self.failure(actor, decoded.handle.id, err);
                            }
                        }
                    },
                    .modifiers => |payload| {
                        if (!device.seat_valid) {
                            try decoded.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        }
                        if (!device.keymap) return try self.noKeymap(actor, decoded.handle.id);
                        if (device.registered and !self.inhibited) {
                            self.seat.virtualModifiers(.{ .depressed = payload.mods_depressed, .latched = payload.mods_latched, .locked = payload.mods_locked, .group = payload.group }) catch |err|
                                return try self.failure(actor, decoded.handle.id, err);
                            self.modifier_owner = self.deviceId(device);
                        }
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn clearModifierOwnerOnPhysicalInput(self: *Self) void {
            self.modifier_owner = null;
        }

        pub fn setInhibited(self: *Self, inhibited: bool) !void {
            if (inhibited) {
                self.inhibited = true;
                for (self.devices) |*device| if (device.active) try self.releasePressed(device);
                if (self.modifier_owner != null) {
                    try self.seat.restoreDerivedModifiers();
                    self.modifier_owner = null;
                }
                return;
            }
            if (!self.inhibited) return;
            for (self.devices) |*device| {
                if (!device.active or device.deferred_fd < 0) continue;
                if (self.keymap_observer) |observer| {
                    if (!observer.canUpdateFn(observer.context)) return error.Exhausted;
                }
                try self.seat.setKeymapOwned(device.deferred_fd, device.deferred_size);
                device.deferred_fd = -1;
                device.deferred_size = 0;
                if (self.keymap_observer) |observer| observer.updatedFn(observer.context);
            }
            self.inhibited = false;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Keyboard.info) {
                const device = from(Device, self.devices, object.context) orelse return false;
                if (!std.meta.eql(device.resource, handle)) return false;
                self.releaseDevice(self.deviceIndex(device));
                return true;
            }
            if (object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                const i = indexOf(ManagerSlot, self.managers, manager);
                manager.* = .{ .next = self.manager_free };
                self.manager_free = i;
                return true;
            }
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.devices, 0..) |device, i| if (device.active and same(device.peer, peer)) self.releaseDevice(@intCast(i));
            for (self.managers) |*manager| if (manager.active and same(manager.peer, peer)) {
                const i = indexOf(ManagerSlot, self.managers, manager);
                manager.* = .{ .next = self.manager_free };
                self.manager_free = i;
            };
        }

        fn acquireDevice(self: *Self) !*Device {
            if (self.device_free == none) return error.Exhausted;
            const i = self.device_free;
            const device = &self.devices[i];
            self.device_free = device.next;
            device.* = .{ .active = true, .generation = device.generation };
            return device;
        }

        fn releaseDevice(self: *Self, i: u32) void {
            const device = &self.devices[i];
            if (!device.active) return;
            const id = self.deviceId(device);
            self.releasePressed(device) catch {};
            if (device.registered) self.seat.removeVirtualKeyboard(self.inputId(device)) catch {};
            if (self.modifier_owner != null and std.meta.eql(self.modifier_owner.?, id)) {
                self.modifier_owner = null;
                self.seat.restoreDerivedModifiers() catch {};
            }
            if (device.deferred_fd >= 0) _ = linux.close(device.deferred_fd);
            const generation = device.generation +% 1;
            device.* = .{ .generation = if (generation == 0) 1 else generation, .next = self.device_free };
            self.device_free = i;
        }

        fn releasePressed(self: *Self, device: *Device) !void {
            if (device.registered) for (&device.pressed, 0..) |*word, wi| {
                var bits = word.*;
                while (bits != 0) {
                    const bit: u6 = @intCast(@ctz(bits));
                    try self.seat.virtualKeyboardKey(self.inputId(device), 0, @intCast(wi * 64 + bit), false);
                    bits &= bits - 1;
                }
                word.* = 0;
            };
        }

        fn inputId(self: *Self, device: *const Device) input.DeviceId {
            const index = self.deviceIndex(device);
            return .{ .slot = 0x8000_0000 | index, .generation = device.generation, .seat_generation = 0x564b_0001 };
        }
        fn deviceId(self: *Self, device: *const Device) DeviceId {
            return .{ .index = self.deviceIndex(device), .generation = device.generation };
        }
        fn deviceIndex(self: *const Self, device: *const Device) u32 {
            return indexOf(Device, self.devices, device);
        }
        fn noKeymap(self: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            return self.protocolError(actor, id, Keyboard.@"error".no_keymap.value, "keymap must be set first");
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            try Core.postError(actor, id, 0, @errorName(err));
            return .stop;
        }
    };
}

pub fn validateKeymap(fd: linux.fd_t, size: u32) !void {
    if (size == 0 or size > 16 * 1024 * 1024) return error.InvalidKeymap;
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_size < size) return error.InvalidKeymap;
    var last: [1]u8 = undefined;
    const read = linux.pread(fd, &last, 1, size - 1);
    if (linux.errno(read) != .SUCCESS or read != 1 or last[0] != 0) return error.InvalidKeymap;
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, i| slot.* = .{ .next = if (i + 1 < slots.len) @intCast(i + 1) else none };
}
fn indexOf(comptime T: type, slots: []const T, pointer: *const T) u32 {
    return @intCast((@intFromPtr(pointer) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active) slot else null;
}
fn same(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return std.meta.eql(a, b);
}

const TestSeat = struct {
    owned_keymap: linux.fd_t = -1,
    keymap_updates: usize = 0,
    releases: usize = 0,
    removals: usize = 0,
    modifier_updates: usize = 0,
    restores: usize = 0,

    fn deinit(self: *@This()) void {
        if (self.owned_keymap >= 0) _ = linux.close(self.owned_keymap);
    }
    pub fn ownsSeat(_: *@This(), _: wayring.io_uring.Peer, _: u32) bool {
        return true;
    }
    pub fn addVirtualKeyboard(_: *@This(), _: input.DeviceId) !void {}
    pub fn removeVirtualKeyboard(self: *@This(), _: input.DeviceId) !void {
        self.removals += 1;
    }
    pub fn setKeymapOwned(self: *@This(), fd: linux.fd_t, _: u32) !void {
        if (self.owned_keymap >= 0) _ = linux.close(self.owned_keymap);
        self.owned_keymap = fd;
        self.keymap_updates += 1;
    }
    pub fn virtualKeyboardKey(self: *@This(), _: input.DeviceId, _: u32, _: u32, pressed: bool) !void {
        if (!pressed) self.releases += 1;
    }
    pub fn virtualModifiers(self: *@This(), _: anytype) !void {
        self.modifier_updates += 1;
    }
    pub fn restoreDerivedModifiers(self: *@This()) !void {
        self.restores += 1;
    }
};

test "keymap validation requires bounds, backing size, and final nul" {
    const fd = try testKeymapFd();
    defer _ = linux.close(fd);
    try validateKeymap(fd, 4);
    try std.testing.expectError(error.InvalidKeymap, validateKeymap(fd, 0));
    try std.testing.expectError(error.InvalidKeymap, validateKeymap(fd, 3));
    try std.testing.expectError(error.InvalidKeymap, validateKeymap(fd, 5));
    try std.testing.expectError(error.InvalidKeymap, validateKeymap(fd, 16 * 1024 * 1024 + 1));
}

test "inhibition releases keys and applies the latest deferred keymap on resume" {
    const protocol = @import("core_protocol");
    const A = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    defer seat.deinit();
    var adapter = try A.init(std.testing.allocator, &seat, .{ .manager_capacity = 1, .device_capacity = 1 });
    defer adapter.deinit();
    const device = try adapter.acquireDevice();
    device.seat_valid = true;
    device.keymap = true;
    device.registered = true;
    device.pressed[30 / 64] |= @as(u64, 1) << (30 & 63);
    adapter.modifier_owner = adapter.deviceId(device);

    try adapter.setInhibited(true);
    try std.testing.expect(adapter.inhibited);
    try std.testing.expectEqual(@as(usize, 1), seat.releases);
    try std.testing.expectEqual(@as(usize, 1), seat.restores);
    try std.testing.expectEqual(@as(u64, 0), device.pressed[30 / 64]);

    const fd = try testKeymapFd();
    defer _ = linux.close(fd);
    const duplicated = linux.dup(fd);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(duplicated));
    device.deferred_fd = @intCast(duplicated);
    device.deferred_size = 4;
    try adapter.setInhibited(false);
    try std.testing.expect(!adapter.inhibited);
    try std.testing.expectEqual(@as(usize, 1), seat.keymap_updates);
    try std.testing.expectEqual(@as(linux.fd_t, -1), device.deferred_fd);
}

test "only the exact modifier owner restores derived state on removal" {
    const protocol = @import("core_protocol");
    const A = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    defer seat.deinit();
    var adapter = try A.init(std.testing.allocator, &seat, .{ .manager_capacity = 1, .device_capacity = 2 });
    defer adapter.deinit();
    const first = try adapter.acquireDevice();
    first.registered = true;
    const first_index = adapter.deviceIndex(first);
    const second = try adapter.acquireDevice();
    second.registered = true;
    const second_index = adapter.deviceIndex(second);
    adapter.modifier_owner = adapter.deviceId(second);

    adapter.releaseDevice(first_index);
    try std.testing.expectEqual(@as(usize, 0), seat.restores);
    adapter.releaseDevice(second_index);
    try std.testing.expectEqual(@as(usize, 1), seat.restores);
}

fn testKeymapFd() !linux.fd_t {
    const result = linux.memfd_create("ouro-virtual-keyboard-test", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.MemfdCreateFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.write(fd, "xkb\x00", 4)) != .SUCCESS) return error.KeymapWriteFailed;
    return fd;
}
