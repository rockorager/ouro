//! Backend-independent, bounded wlr gamma-control protocol adapter.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("sys/stat.h");
});

pub const max_gamma_size: u32 = 1 << 20;

pub fn readPayload(allocator: std.mem.Allocator, fd: linux.fd_t, gamma_size: u32) ![]u16 {
    if (gamma_size == 0 or gamma_size > max_gamma_size) return error.InvalidGamma;
    const elements = std.math.mul(usize, gamma_size, 3) catch return error.InvalidGamma;
    const byte_len = std.math.mul(usize, elements, @sizeOf(u16)) catch return error.InvalidGamma;
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0) return error.GammaIo;
    if ((stat.st_mode & c.S_IFMT) != c.S_IFREG or stat.st_size < 0 or
        @as(u64, @intCast(stat.st_size)) != byte_len) return error.InvalidGamma;
    const ramps = try allocator.alloc(u16, elements);
    errdefer allocator.free(ramps);
    const bytes = std.mem.sliceAsBytes(ramps);
    var done: usize = 0;
    while (done < bytes.len) {
        const result = linux.pread(fd, bytes[done..].ptr, bytes.len - done, @intCast(done));
        if (linux.errno(result) != .SUCCESS) return error.GammaIo;
        if (result == 0) return error.InvalidGamma;
        done += result;
    }
    return ramps;
}

pub const Config = struct {
    control_capacity: usize = 64,
    outbound_capacity: usize = 64,
    fn validate(config: Config) !void {
        if (config.control_capacity == 0 or config.control_capacity >= slot_pool.none or
            config.outbound_capacity == 0) return error.InvalidConfig;
    }
};

/// Resolver validates exact peer ownership and current backend support.
pub fn Adapter(comptime protocol: type, comptime OutputId: type, comptime Resolver: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_gamma_control_manager_v1;
        const Control = protocol.zwlr_gamma_control_v1;
        const Peer = wayring.io_uring.Peer;
        const SlotId = packed struct { index: u32, generation: u32 };
        const Slot = struct {
            header: slot_pool.Header = .{},
            peer: Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            output: OutputId = undefined,
            size: u32 = 0,
            valid: bool = false,
        };
        const Event = union(enum) { gamma_size: u32, failed };
        const Outbound = struct { owner: SlotId, event: Event };

        allocator: std.mem.Allocator,
        resolver: *Resolver,
        config: Config,
        slots: slot_pool.Pool(Slot),
        outbound: std.ArrayListUnmanaged(Outbound) = .empty,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, resolver: *Resolver, config: Config) !Self {
            try config.validate();
            return .{ .allocator = allocator, .resolver = resolver, .config = config, .slots = try slot_pool.Pool(Slot).init(allocator, @min(config.control_capacity, 8)) };
        }
        pub fn deinit(self: *Self) void {
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
                    .destroy => {},
                    .get_gamma_control => |value| {
                        self.ensureOutbound(1) catch return try self.noMemory(actor);
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        errdefer self.slots.release(slot);
                        const admitted = Manager.admit_get_gamma_control(server_objects, decoded.handle, value, .{ .id = slot }) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                        slot.peer = peer;
                        slot.resource = admitted.id;
                        const resolution = resolution: {
                            const oh = server_objects.namespace.lookupHandle(value.output) orelse break :resolution null;
                            const oo = server_objects.namespace.resolve(oh) orelse break :resolution null;
                            break :resolution self.resolver.resolveGammaOutput(peer, oh, oo) catch null;
                        };
                        if (resolution) |resolved| {
                            slot.output = resolved.id;
                            slot.size = resolved.size;
                            if (resolved.size != 0 and resolved.size <= max_gamma_size and !self.hasOther(slot, resolved.id)) {
                                slot.valid = true;
                                self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .{ .gamma_size = resolved.size } });
                            } else self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .failed });
                        } else self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .failed });
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Control.info) return null;
            const slot = self.slots.fromContext(target.object.context) orelse return null;
            if (!samePeer(slot.peer, peer) or !std.meta.eql(slot.resource, handle)) return null;
            const decoded = try wayring.server.decodeRequest(Control, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => self.release(slot),
                .set_gamma => |value| {
                    defer _ = linux.close(value.fd);
                    if (slot.valid) {
                        self.ensureOutbound(1) catch return try self.noMemory(actor); // permanent failure must always be publishable
                        const ramps = readPayload(self.allocator, value.fd, slot.size) catch |err| switch (err) {
                            error.InvalidGamma => return try self.protocolError(actor, decoded.handle.id, 1, "invalid gamma ramp"),
                            error.OutOfMemory => return try self.noMemory(actor),
                            else => {
                                self.fail(slot);
                                try decoded.finish(protocol, server_objects, &actor.transmit);
                                return .continue_dispatch;
                            },
                        };
                        if (slot.valid) {
                            defer self.allocator.free(ramps);
                            self.resolver.applyGamma(slot.output, ramps) catch self.fail(slot);
                        }
                    }
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }
        pub fn outputRemoved(self: *Self, output: OutputId) !void {
            var count: usize = 0;
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.valid and std.meta.eql(slot.output, output)) {
                count += 1;
            };
            try self.ensureOutbound(count);
            for (self.slots.entries.items) |slot| if (slot.header.active and slot.valid and std.meta.eql(slot.output, output)) self.fail(slot);
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
                Control.encodeEvent(queue, slot.resource.id, switch (out.event) {
                    .gamma_size => |size| .{ .gamma_size = .{ .size = size } },
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
            if (object.interface == &Control.info) if (self.slots.fromContext(object.context)) |slot| if (std.meta.eql(slot.resource, handle)) {
                self.release(slot);
                return true;
            };
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }
        pub fn disconnected(self: *Self, peer: Peer) void {
            for (self.slots.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer)) self.release(slot);
        }
        pub fn pendingOutbound(self: *const Self, peer: Peer) bool {
            for (self.outbound.items) |out| if (self.resolveIdConst(out.owner)) |slot| if (samePeer(slot.peer, peer)) return true;
            return false;
        }
        fn fail(self: *Self, slot: *Slot) void {
            std.debug.assert(slot.valid);
            slot.valid = false;
            self.resolver.resetGamma(slot.output) catch {};
            self.outbound.appendAssumeCapacity(.{ .owner = id(slot), .event = .failed });
        }
        fn release(self: *Self, slot: *Slot) void {
            if (!slot.header.active) return;
            if (slot.valid) {
                slot.valid = false;
                self.resolver.resetGamma(slot.output) catch {};
            }
            self.slots.release(slot);
        }
        fn acquire(self: *Self) !*Slot {
            var active: usize = 0;
            for (self.slots.entries.items) |slot| if (slot.header.active) {
                active += 1;
            };
            if (active >= self.config.control_capacity) return error.Exhausted;
            return self.slots.acquire();
        }
        fn hasOther(self: *Self, owner: *Slot, output: OutputId) bool {
            for (self.slots.entries.items) |slot| if (slot != owner and slot.header.active and slot.valid and std.meta.eql(slot.output, output)) return true;
            return false;
        }
        fn ensureOutbound(self: *Self, count: usize) !void {
            if (count > self.config.outbound_capacity -| self.outbound.items.len) return error.Exhausted;
            try self.outbound.ensureUnusedCapacity(self.allocator, count);
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

test "gamma control: exact regular payload is read from offset zero" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("ramps", .{ .read = true });
    defer file.close();
    const expected = [_]u16{ 1, 2, 3, 4, 5, 6 };
    try file.writeAll(std.mem.sliceAsBytes(&expected));
    try file.seekTo(5);
    const actual = try readPayload(std.testing.allocator, file.handle, 2);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u16, &expected, actual);
}
test "gamma control: rejects malformed payloads" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("ramps", .{ .read = true });
    defer file.close();
    try file.writeAll(&([_]u8{0} ** 11));
    try std.testing.expectError(error.InvalidGamma, readPayload(std.testing.allocator, file.handle, 2));
    try file.setEndPos(13);
    try std.testing.expectError(error.InvalidGamma, readPayload(std.testing.allocator, file.handle, 2));
    const descriptors = try std.posix.pipe();
    defer _ = linux.close(descriptors[0]);
    defer _ = linux.close(descriptors[1]);
    try std.testing.expectError(error.InvalidGamma, readPayload(std.testing.allocator, descriptors[0], 1));
}
test "gamma adapter is compile checked and reset is exactly once" {
    const protocol = @import("core_protocol");
    const Resolver = struct {
        resets: usize = 0,
        pub fn resolveGammaOutput(_: *@This(), _: wayring.io_uring.Peer, _: objects.Handle, _: objects.Object) !struct { id: u32, size: u32 } {
            return error.Unsupported;
        }
        pub fn applyGamma(_: *@This(), _: u32, _: []const u16) !void {}
        pub fn resetGamma(self: *@This(), _: u32) !void {
            self.resets += 1;
        }
    };
    const A = Adapter(protocol, u32, Resolver);
    std.testing.refAllDecls(A);
    var resolver = Resolver{};
    var adapter = try A.init(std.testing.allocator, &resolver, .{ .control_capacity = 2 });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.peer = .{ .slot = 1, .generation = 1 };
    slot.output = 7;
    slot.valid = true;
    try adapter.outputRemoved(7);
    try adapter.outputRemoved(7);
    adapter.disconnected(slot.peer);
    try std.testing.expectEqual(@as(usize, 1), resolver.resets);
}
test "gamma adapter duplicate, backpressure, and stale generation" {
    const protocol = @import("core_protocol");
    const Resolver = struct {
        pub fn applyGamma(_: *@This(), _: u32, _: []const u16) !void {}
        pub fn resetGamma(_: *@This(), _: u32) !void {}
    };
    const A = Adapter(protocol, u32, Resolver);
    var resolver = Resolver{};
    var adapter = try A.init(std.testing.allocator, &resolver, .{ .control_capacity = 2, .outbound_capacity = 1 });
    defer adapter.deinit();
    const owner = try adapter.acquire();
    owner.output = 9;
    owner.valid = true;
    const duplicate = try adapter.acquire();
    duplicate.output = 9;
    try std.testing.expect(adapter.hasOther(duplicate, 9));
    adapter.outbound.appendAssumeCapacity(.{ .owner = A.id(owner), .event = .failed });
    try std.testing.expectError(error.Exhausted, adapter.outputRemoved(9));
    try std.testing.expect(owner.valid);
    adapter.outbound.clearRetainingCapacity();
    const old = A.id(owner);
    adapter.release(owner);
    try std.testing.expect(adapter.resolveId(old) == null);
}
