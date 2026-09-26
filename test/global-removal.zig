//! Adapter lifetimes against Wayring's retained per-registry global offers.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");
const linux = std.os.linux;
const Handle = wayring.objects.Handle;
const Runtime = wayring.server.Runtime(protocol);
const Seat = ouro.seat.Adapter(protocol, FakeCore);

test "global removal: fixes v2 accepts ack and reports duplicate ack on the fixes object" {
    var adapter: ouro.wayland_fixes.Adapter(protocol) = .{};
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.track(&adapter);
    const global = try adapter.install(&f.runtime);
    try std.testing.expectEqual(@as(u32, 2), (try f.runtime.globals.get(global.id)).version);
    try f.publish();
    const registry = try f.registry(2);
    try f.publish();
    const v1 = try f.bind(protocol.wl_fixes, global, 1, 3);
    const v2 = try f.bind(protocol.wl_fixes, global, 2, 4);
    const ack: protocol.wl_fixes.Request = .{ .ack_global_remove = .{ .registry = registry.id, .name = global.id } };
    try std.testing.expectError(error.UnsupportedVersion, f.request(&adapter, protocol.wl_fixes, v1.id, ack));
    try f.runtime.removeGlobal(global);
    try f.publish();
    try f.request(&adapter, protocol.wl_fixes, v2.id, ack);
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try f.requestControl(&adapter, protocol.wl_fixes, v2.id, ack));
    const err = (try f.pop(protocol.wl_display)).@"error";
    try std.testing.expectEqual(@as(?u32, v2.id), err.object_id);
    try std.testing.expectEqual(protocol.wl_fixes.@"error".invalid_ack_remove.value, err.code);
    try std.testing.expectEqual(.draining, (try f.actor()).lifecycle);
}

test "global removal: transient seat waits for offers even with no resources or devices" {
    var core: FakeCore = .{};
    var adapter = try ouro.transient_seat.Adapter(protocol, Seat).init(std.testing.allocator, .{ .seat_capacity = 1 }, &core, initSeat);
    defer adapter.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.track(&adapter);
    const manager_global = try adapter.install(&f.runtime);
    try f.publish();
    const first = try f.registry(2);
    const second = try f.registry(7);
    try f.publish();
    const manager = try f.bind(protocol.ext_transient_seat_manager_v1, manager_global, 1, 3);
    try f.request(&adapter, protocol.ext_transient_seat_manager_v1, manager.id, .{ .create = .{ .seat = 4 } });
    const add = (try adapter.nextMutation()).?;
    try f.publish();
    try adapter.mutationPublished(add);
    const global = adapter.seats[0].adapter.global.?;
    try f.request(&adapter, protocol.ext_transient_seat_v1, 4, .{ .destroy = .{} });
    try f.drain();
    const remove = (try adapter.nextMutation()).?;
    try f.publish();
    try adapter.mutationPublished(remove);
    try adapter.advance();
    try std.testing.expect(adapter.seats[0].initialized);
    try std.testing.expectEqual(@as(usize, 0), adapter.seats[0].adapter.resourceCount());
    try std.testing.expectEqual(@as(usize, 0), adapter.seats[0].adapter.deviceCount());
    const racing = try f.bind(protocol.wl_seat, global, 9, 5);
    _ = try adapter.flushSeatsOn(f.peer, try f.objects(), &(try f.actor()).transmit);
    try std.testing.expectEqual(@as(u32, 0), (try f.pop(protocol.wl_seat)).capabilities.capabilities.value);
    try f.drain();
    try f.runtime.ackGlobalRemove(f.peer, first, global.id);
    try f.request(&adapter, protocol.wl_seat, racing.id, .{ .release = .{} });
    try f.drain();
    try adapter.advance();
    try std.testing.expect(adapter.seats[0].initialized);
    // A v1 client can release its offer by destroying the other registry.
    _ = try f.runtime.removeRegistry(f.peer, second);
    try f.drain();
    try adapter.advance();
    try std.testing.expect(!adapter.seats[0].initialized);
    try f.request(&adapter, protocol.ext_transient_seat_manager_v1, manager.id, .{ .create = .{ .seat = 4 } });
    const replacement = (try adapter.nextMutation()).?;
    try f.publish();
    try adapter.mutationPublished(replacement);
    try std.testing.expect(adapter.seats[0].adapter.global.?.id != global.id);
    try std.testing.expectError(error.UnknownGlobal, f.bind(protocol.wl_seat, global, 9, 5));
}

test "global removal: old seat binds and children stay inert across reinstall" {
    var core: FakeCore = .{};
    var adapter: Seat = undefined;
    try initSeat(&core, std.testing.allocator, &adapter);
    defer adapter.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.track(&adapter);
    const old = try adapter.install(&f.runtime);
    try f.publish();
    const registry = try f.registry(2);
    try f.publish();
    const device: ouro.input_backend.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 1 };
    const added: ouro.input_backend.Event = .{ .device_added = .{ .device = device, .info = .{ .capabilities = .{ .pointer = true, .keyboard = true, .touch = true } } } };
    try adapter.consume(added);
    try adapter.removeGlobal();
    try f.publish();
    const current = try adapter.install(&f.runtime);
    try f.publish();
    const old_resource = try f.bind(protocol.wl_seat, old, 9, 3);
    const live_resource = try f.bind(protocol.wl_seat, current, 9, 4);
    _ = try adapter.flushOn(f.peer, try f.objects(), &(try f.actor()).transmit);
    try std.testing.expectEqual(@as(u32, 0), (try f.pop(protocol.wl_seat)).capabilities.capabilities.value);
    _ = try f.pop(protocol.wl_seat); // name
    try std.testing.expectEqual(@as(u32, 7), (try f.pop(protocol.wl_seat)).capabilities.capabilities.value);
    try f.drain();
    try std.testing.expect(!adapter.ownsSeat(f.peer, old_resource.id));
    try std.testing.expect(adapter.ownsSeat(f.peer, live_resource.id));
    // Even a focused client must not receive enter/modifier events on children
    // obtained through the retired name.
    const focus: Seat.FocusTarget = .{ .client = .{ .slot = f.peer.slot, .generation = f.peer.generation }, .surface = .{ .index = 0, .generation = 1 } };
    adapter.pointer_delivery = focus;
    adapter.keyboard_focus = focus;
    try f.request(&adapter, protocol.wl_seat, old_resource.id, .{ .get_pointer = .{ .id = 5 } });
    try f.request(&adapter, protocol.wl_seat, old_resource.id, .{ .get_keyboard = .{ .id = 6 } });
    try f.request(&adapter, protocol.wl_seat, old_resource.id, .{ .get_touch = .{ .id = 7 } });
    for (adapter.outbound) |out| if (out.active) {
        try std.testing.expect(out.value == .keyboard_keymap or out.value == .keyboard_repeat);
    };
    try std.testing.expectEqual(@as(u32, 0), adapter.pointers.entries.items[0].capability_generation);
    try std.testing.expectEqual(@as(u32, 0), adapter.keyboards.entries.items[0].capability_generation);
    try std.testing.expectEqual(@as(u32, 0), adapter.touches.entries.items[0].capability_generation);
    // Retiring a second installation must not lose the first callback debt.
    try adapter.removeGlobal();
    try f.publish();
    try std.testing.expectEqual(@as(usize, 2), adapter.pending_global_removals);
    try f.runtime.ackGlobalRemove(f.peer, registry, current.id);
    try std.testing.expect(adapter.globalBindingsPending());
    try f.runtime.ackGlobalRemove(f.peer, registry, old.id);
    try std.testing.expect(!adapter.globalBindingsPending());
    try std.testing.expectEqual(@as(usize, 5), adapter.resourceCount());
    try adapter.consume(.{ .device_removed = device });
    try adapter.consume(added);
    try std.testing.expectEqual(@as(u32, 0), adapter.pointers.entries.items[0].capability_generation);
    for (adapter.outbound) |out| if (out.active and out.value == .seat_capabilities) {
        try std.testing.expect(out.value.seat_capabilities.seat.index != 0);
    };
}

test "global removal: retired output racing bind is inert and releasable" {
    var adapter = try ouro.protocol_output.Adapter(protocol).init(std.testing.allocator, .{});
    defer adapter.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.track(&adapter);
    _ = try adapter.install(&f.runtime);
    try f.publish();
    const registry = try f.registry(2);
    try f.publish();
    const id = try adapter.addOutput(.{ .name = "retiring", .description = "Retiring output" });
    const old = adapter.outputs[id.index].global.?;
    try f.publish();
    try adapter.retireOutput(id);
    try f.publish();
    const resource = try f.bind(protocol.wl_output, old, 4, 3);
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(f.peer, try f.objects(), &(try f.actor()).transmit));
    try std.testing.expectEqual(@as(usize, 0), (try f.actor()).transmit.queuedBytes());
    try std.testing.expectError(error.OutputRetired, adapter.publishOutput(id));
    try f.runtime.ackGlobalRemove(f.peer, registry, old.id);
    try std.testing.expect((try f.objects()).namespace.resolve(resource) != null);
    try f.request(&adapter, protocol.wl_output, resource.id, .{ .release = .{} });
    try std.testing.expect((try f.objects()).namespace.resolve(resource) == null);
    const replacement = try adapter.addOutput(.{ .name = "replacement", .description = "Replacement" });
    try f.drain();
    try f.publish();
    try std.testing.expect(adapter.outputs[replacement.index].global.?.id != old.id);
    try std.testing.expectError(error.UnknownGlobal, f.bind(protocol.wl_output, old, 4, 3));
}

test "global removal: old DRM device names never reopen hardware after reinstall" {
    var resolver: LeaseResolver = .{};
    var adapter = try ouro.drm_lease.Adapter(protocol, u32, u32, u32, LeaseResolver).init(std.testing.allocator, &resolver, .{});
    defer adapter.deinit();
    var f: Fixture = undefined;
    try f.init();
    defer f.deinit();
    try f.track(&adapter);
    const old = try adapter.install(&f.runtime);
    try f.publish();
    const registry = try f.registry(2);
    try f.publish();
    try adapter.removeGlobal();
    try f.publish();
    const old_resource = try f.bind(protocol.wp_drm_lease_device_v1, old, 1, 3);
    const current = try adapter.install(&f.runtime);
    try f.publish();
    const old_after_install = try f.bind(protocol.wp_drm_lease_device_v1, old, 1, 4);
    try adapter.addConnector(1, 42, 1, "DP-1", "Lease connector", 42);
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(f.peer, try f.objects(), &(try f.actor()).transmit));
    try std.testing.expectEqual(@as(usize, 0), resolver.opens);
    try std.testing.expectEqual(@as(usize, 0), resolver.allowed);
    _ = try f.bind(protocol.wp_drm_lease_device_v1, current, 1, 5);
    try std.testing.expectEqual(@as(usize, 1), resolver.opens);
    try std.testing.expectEqual(@as(usize, 1), resolver.allowed);
    try f.request(&adapter, protocol.wp_drm_lease_device_v1, old_resource.id, .{ .create_lease_request = .{ .id = 6 } });
    try std.testing.expect(adapter.requests[0].invalid);
    try f.runtime.ackGlobalRemove(f.peer, registry, old.id);
    try f.request(&adapter, protocol.wp_drm_lease_device_v1, old_resource.id, .{ .release = .{} });
    try f.request(&adapter, protocol.wp_drm_lease_device_v1, old_after_install.id, .{ .release = .{} });
    try std.testing.expect((try f.objects()).namespace.resolve(old_resource) == null);
    try std.testing.expect((try f.objects()).namespace.resolve(old_after_install) == null);
    try std.testing.expectEqual(@as(usize, 0), resolver.grants);
}

const LeaseResolver = struct {
    opens: usize = 0,
    allowed: usize = 0,
    grants: usize = 0,
    pub fn allowDrmLease(self: *@This(), _: wayring.server.Binding) bool {
        self.allowed += 1;
        return true;
    }
    pub fn resolveDrmLeaseDevice(_: *@This(), _: wayring.server.Binding) u32 {
        return 1;
    }
    pub fn openDrmLeaseDevice(self: *@This(), _: u32) !linux.fd_t {
        self.opens += 1;
        const result = linux.memfd_create("lease-test", 0);
        if (linux.errno(result) != .SUCCESS) return error.OpenFailed;
        return @intCast(result);
    }
    pub fn grantDrmLease(self: *@This(), _: u32, _: []const u32) !?struct { token: u32, fd: linux.fd_t } {
        self.grants += 1;
        return null;
    }
    pub fn revokeDrmLease(_: *@This(), _: u32) bool {
        return true;
    }
};

const FakeCore = struct {
    pub const SurfaceId = struct { index: u32, generation: u32 };
    surface: ouro.surface.Surface = .{},
    pub fn getSurfaceById(self: *@This(), _: SurfaceId) !*ouro.surface.Surface {
        return &self.surface;
    }
    pub fn getSurfaceObject(self: *@This(), handle: Handle, _: *const wayring.objects.Object) !*ouro.surface.Surface {
        if (handle.id != 30) return error.StaleSurface;
        return &self.surface;
    }
    pub fn surfaceHandle(_: *@This(), _: SurfaceId) !Handle {
        return .{ .id = 30, .generation = 1 };
    }
    pub fn surfaceIdObject(_: *@This(), _: Handle, _: *const wayring.objects.Object) !SurfaceId {
        return .{ .index = 0, .generation = 1 };
    }
};

fn initSeat(context: ?*anyopaque, allocator: std.mem.Allocator, seat: *Seat) !void {
    seat.* = try Seat.init(allocator, @ptrCast(@alignCast(context.?)), .{
        .seat_capacity = 2,
        .pointer_capacity = 2,
        .keyboard_capacity = 2,
        .device_capacity = 2,
        .outbound_capacity = 32,
        .event_capacity = 8,
        .keymap = ouro.seat.default_keymap,
    });
}

const Fixture = struct {
    reactor: wayring.io_uring.Reactor,
    runtime: Runtime,
    peer: wayring.io_uring.Peer,
    remote: linux.fd_t,
    listener_remote: linux.fd_t,

    fn init(self: *Fixture) !void {
        try self.reactor.initOwned(std.testing.allocator, .{ .entries = 16 }, .{
            .receive_buffer_size = 4096,
            .receive_buffer_count = 4,
            .receive_control_capacity = 64,
            .fragment_block_size = 64,
            .fragment_block_count = 2,
            .transmit_block_size = 4096,
            .transmit_block_count = 2,
            .descriptor_count = 16,
            .send_descriptor_capacity = 8,
        });
        var sockets: [2]linux.fd_t = undefined;
        try pair(&sockets);
        self.listener_remote = sockets[1];
        self.runtime = try Runtime.init(std.testing.allocator, &self.reactor, sockets[0], .{
            .actor = .{ .received_fd_budget = 8, .transmit_byte_budget = 4096, .transmit_fd_budget = 8 },
            .object_capacity = 32,
            .object_quota = 32,
            .buckets_per_client = 32,
            .max_globals = 8,
            .registry_capacity = 2,
        });
        try pair(&sockets);
        self.remote = sockets[1];
        self.peer = try self.runtime.clients.admit(.{ .fd = sockets[0], .more = true }, self.runtime.actor_config, null);
        _ = try self.reactor.ring.submit();
    }
    fn deinit(self: *Fixture) void {
        const a = self.actor() catch unreachable;
        _ = self.runtime.clients.prepareClose(self.peer) catch unreachable;
        _ = self.reactor.ring.submit() catch unreachable;
        while (!a.canDeinit()) {
            const cqe = self.reactor.ring.copy_cqe() catch unreachable;
            const routed = self.reactor.route(null, cqe).?.connection;
            const event = a.completeRouted(routed.operation, cqe) catch unreachable;
            if (event == .received) (self.reactor.getReceiver(self.peer) catch unreachable).buffers.put(cqe) catch unreachable;
        }
        self.runtime.destroyClient(self.peer) catch unreachable;
        self.runtime.deinit(std.testing.allocator) catch unreachable;
        self.reactor.deinit(std.testing.allocator);
        _ = linux.close(self.remote);
        _ = linux.close(self.listener_remote);
    }
    fn track(self: *Fixture, adapter: anytype) !void {
        const Hook = struct {
            fn removed(context: ?*anyopaque, h: Handle, object: wayring.objects.Object) void {
                const a: @TypeOf(adapter) = @ptrCast(@alignCast(context.?));
                _ = a.resourceRemoved(h, object);
            }
        };
        try self.runtime.setRemovalHook(self.peer, .{ .context = adapter, .notify = Hook.removed });
    }
    fn actor(self: *Fixture) !*wayring.connection.Actor {
        return self.reactor.getActor(self.peer);
    }
    fn objects(self: *Fixture) !*wayring.objects.SharedServerObjects {
        return self.runtime.clients.get(self.peer);
    }
    fn registry(self: *Fixture, id: u32) !Handle {
        var bytes: [12]u8 = undefined;
        try (wayring.wire.Header{ .object_id = 1, .opcode = 1, .size = 12 }).encode(bytes[0..8]);
        std.mem.writeInt(u32, bytes[8..], id, @import("builtin").cpu.arch.endian());
        return (try self.runtime.decodeDisplayRequest(self.peer, (try wayring.wire.Message.decode(&bytes)).?, &(try self.actor()).received_fds, null)).get_registry;
    }
    fn bind(self: *Fixture, comptime Interface: type, global: Handle, version: u32, id: u32) !Handle {
        return self.runtime.bindGlobal(self.peer, .{ .bind = .{ .name = global.id, .id = .{ .interface = Interface.info.name, .version = version, .id = id } } });
    }
    fn request(self: *Fixture, adapter: anytype, comptime Interface: type, id: u32, value: Interface.Request) !void {
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try self.requestControl(adapter, Interface, id, value));
    }
    fn requestControl(self: *Fixture, adapter: anytype, comptime Interface: type, id: u32, value: Interface.Request) !wayring.dispatch.Control {
        var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 1);
        defer blocks.deinit(std.testing.allocator);
        var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
        defer descriptors.deinit(std.testing.allocator);
        var queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 0);
        defer queue.deinit();
        try Interface.encodeRequest(&queue, id, value);
        var scratch: [1]linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try queue.snapshot(&scratch, &control);
        const message = (try wayring.wire.Message.decode(snapshot.first)).?;
        const target = try (try self.objects()).namespace.request(id, message.header.opcode);
        return (try adapter.request(self.peer, target, message, &(try self.actor()).received_fds)).?;
    }
    fn publish(self: *Fixture) !void {
        while (true) switch (try self.runtime.publishNext()) {
            .sent => try self.drain(),
            .complete => return,
            .blocked => return error.UnexpectedBackpressure,
        };
    }
    fn drain(self: *Fixture) !void {
        const queue = &(try self.actor()).transmit;
        while (queue.queuedBytes() != 0) {
            var scratch: [8]linux.fd_t = undefined;
            var control: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
            const snapshot = try queue.snapshot(&scratch, &control);
            try queue.begin(snapshot);
            try queue.complete(snapshot.byteCount());
        }
    }
    fn pop(self: *Fixture, comptime Interface: type) !Interface.Event {
        const a = try self.actor();
        var scratch: [8]linux.fd_t = undefined;
        var control: [128]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try a.transmit.snapshot(&scratch, &control);
        const message = (try wayring.wire.Message.decode(snapshot.first)).?;
        const event = try Interface.decodeEvent(message, &a.received_fds);
        try a.transmit.begin(snapshot);
        try a.transmit.complete(message.header.size);
        return event;
    }
};

fn pair(sockets: *[2]linux.fd_t) !void {
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, sockets)));
}
