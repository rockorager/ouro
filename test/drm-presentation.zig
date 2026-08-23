//! Deterministic physical-display vertical integration coverage.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");

const linux = std.os.linux;
const ClientConnection = wayring.client.Connection(protocol);
const ClientDriver = wayring.client.Driver(protocol);
const ClientCore = wayring.client.Core(protocol);
const Compositor = ouro.compositor.Compositor(protocol);
const Loop = ouro.loop.Loop(protocol);
const Coordinator = ouro.physical.Coordinator(protocol);

const pixels = [_]u8{
    0x04, 0x03, 0x02, 0xff, 0x14, 0x13, 0x12, 0xff, 0x24, 0x23, 0x22, 0xff, 0, 0, 0, 0,
    0x34, 0x33, 0x32, 0xff, 0x44, 0x43, 0x42, 0xff, 0x54, 0x53, 0x52, 0xff, 0, 0, 0, 0,
};
const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

test "generated ordinary SHM traverses the physical coordinator exactly once and drains" {
    try runVertical(.session_disable);
}

test "client disconnect before render deadline abandons pending presentation" {
    try runVertical(.client_disconnect);
}

test "no discovered DRM card fails startup and drains honestly" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.discover_cards = false;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-nocard-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    try waitReady(&root.ring);
    try std.testing.expectError(error.DrmHardwareUnavailable, loop.turn(coordinator));
    try std.testing.expect(coordinator.output == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.device_closes);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.seat_closes);
}

test "post-Session coordinator creation failure closes seat exactly once" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-create-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    var config = coordinatorConfig();
    config.drm.card_capacity = 0;
    try std.testing.expectError(error.InvalidConfig, Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
        config,
    ));
    try std.testing.expectEqual(@as(usize, 1), fixture.seat_closes);
    try root.deinit();
}

test "output readiness exhaustion destroys output and releases device" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-ready-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    var config = coordinatorConfig();
    config.router_capacity = 2;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    const initial_area = coordinator.desktop.workArea();
    const initial_pointer = coordinator.interaction.pointerPosition();
    const initial_commands = coordinator.desktop.pendingCommands();
    const injected = try coordinator.router.acquire(.copy);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    try waitReady(&root.ring);
    try std.testing.expectError(error.Exhausted, loop.turn(coordinator));
    try std.testing.expect(coordinator.output == null);
    try std.testing.expectEqual(initial_area, coordinator.desktop.workArea());
    try std.testing.expectEqual(initial_pointer, coordinator.interaction.pointerPosition());
    try std.testing.expectEqual(initial_commands, coordinator.desktop.pendingCommands());
    try std.testing.expectEqual(@as(?u32, 1), coordinator.next_output_generation);
    try std.testing.expectEqual(@as(usize, 1), fixture.device_closes);
    try std.testing.expectEqual(@as(usize, 2), fixture.framebuffer_removed);
    try std.testing.expectEqual(@as(usize, 2), fixture.bo_destroyed);
    try std.testing.expectEqual(@as(usize, 2), fixture.request_destroyed);
    try std.testing.expectEqual(@as(usize, 1), fixture.gbm_destroyed);

    try coordinator.router.retire(injected);
    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.seat_closes);
}

const TerminalTrigger = enum { session_disable, client_disconnect };

fn runVertical(trigger: TerminalTrigger) !void {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var client_reactor: wayring.io_uring.Reactor = undefined;
    try client_reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &client_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    var client_driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var client_handler: ClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    _ = try client_driver.schedule();
    _ = try client_driver.prepare(&client_handler);
    _ = try client_reactor.ring.submit();

    _ = try loop.turn(coordinator); // sole server submitter publishes accept + Session poll
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var observed_identity = false;
    var first_frame: ?ouro.headless_output.FrameId = null;
    for (0..256) |_| {
        client_progress = try drainClient(&client_reactor, &client_driver, &client_handler);
        var cursor_assigned = false;
        if (coordinator.surface_id) |id| if (coordinator.interaction.cursor.surface == null) {
            try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .device_added = .{
                .device = .{ .slot = 0, .generation = 1, .seat_generation = 1 },
                .capabilities = .{ .pointer = true },
            } }));
            coordinator.interaction.cursorRequest(id, .{ .x = 0, .y = 0 });
            cursor_assigned = true;
        };
        if (coordinator.stats.submitted == 1 and !observed_identity) {
            first_frame = coordinator.output.?.currentFrameId().?;
            const sample = coordinator.cursor_layer.sample.?;
            const binding = coordinator.cursor_layer.binding.?;
            try std.testing.expectEqual(binding.sample, sample.sample);
            try std.testing.expectEqual(binding.presentation, sample.presentation);
            try std.testing.expectEqual(@as(u64, 1), sample.sample.commit_sequence);
            try std.testing.expectEqual(
                (@as(u64, coordinator.surface_id.?.generation) << 32) |
                    coordinator.surface_id.?.index,
                sample.sample.surface,
            );
            observed_identity = true;
        }
        if (client_handler.complete()) break;
        if (!cursor_assigned and root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expect(client_handler.complete());
    try std.testing.expect(observed_identity);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.selected_outputs);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.releases);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.imported_disposals);
    try std.testing.expectEqual(@as(usize, 1), fixture.page_flips);
    try std.testing.expectEqual(@as(u32, 10), coordinator.output.?.kms_output.connector.id);
    try std.testing.expectEqual(@as(u32, 30), coordinator.output.?.kms_output.crtc.id);
    try std.testing.expectEqual(@as(u32, 40), coordinator.output.?.kms_output.plane.id);

    // Admit a second ordinary SHM commit, but replace its exact generational
    // surface before the render deadline. Disable then proves that an applied
    // presentation with no possible physical outcome is abandoned exactly
    // once and cannot target the replacement surface.
    const first_surface_id = coordinator.cursor_layer.id.?;
    try client_handler.replaceCommittedSurface();
    try submitClient(&client_reactor, &client_driver, &client_handler);
    for (0..128) |_| {
        _ = try drainClient(&client_reactor, &client_driver, &client_handler);
        _ = try loop.turn(coordinator);
        if (coordinator.surface_id) |id| if (!std.meta.eql(id, first_surface_id) and
            coordinator.interaction.cursor.surface == null)
        {
            coordinator.interaction.cursorRequest(id, .{ .x = 0, .y = 0 });
            _ = try loop.turn(coordinator);
        };
        if (coordinator.stats.applied == 2 and coordinator.cursor_layer.content != null) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.submitted);
    const abandoned_surface = coordinator.cursor_layer.surface.?;

    try client_handler.replaceWithEmptySurface();
    try submitClient(&client_reactor, &client_driver, &client_handler);
    for (0..64) |_| {
        _ = try drainClient(&client_reactor, &client_driver, &client_handler);
        _ = try loop.turn(coordinator);
        if (coordinator.surface != null and
            !std.meta.eql(coordinator.surface.?, abandoned_surface)) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(coordinator.surface != null);
    try std.testing.expect(!std.meta.eql(coordinator.surface.?, abandoned_surface));

    if (trigger == .session_disable) {
        // Session disable quiesces R11, renderer, R10, then releases the DRM
        // device before libseat acknowledgement. The client remains connected.
        try fixture.signalSession(.disable);
        for (0..128) |_| {
            if (coordinator.output == null and coordinator.session.state == .disabled) break;
            if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
            _ = try loop.turn(coordinator);
        }
        try std.testing.expect(coordinator.output == null);
        try std.testing.expectEqual(ouro.session.State.disabled, coordinator.session.state);
        try std.testing.expectEqual(@as(usize, 0), coordinator.session.deviceCount());
        try std.testing.expectEqual(@as(usize, 1), coordinator.stats.output_drains);

        try fixture.signalSession(.enable);
        for (0..128) |_| {
            if (coordinator.output != null) break;
            if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
            _ = try loop.turn(coordinator);
        }
        const replacement = coordinator.output orelse return error.OutputNotRecreated;
        try std.testing.expectEqual(@as(usize, 2), coordinator.stats.selected_outputs);
        try std.testing.expect(replacement.outputId().generation != first_frame.?.output.generation);
        try replacement.request(.damage, 1);
        const request_value = (try replacement.timerRequest(1)).?;
        const replacement_timer: ouro.timer.Handle = .{ .slot = 0, .generation = 1 };
        try replacement.timerArmed(request_value, replacement_timer, 1);
        const replacement_frame = (try replacement.timerEvent(
            replacement_timer,
            .fired,
            request_value.frame.sequence + 6,
        )).?.frame;
        try std.testing.expectEqual(replacement.outputId(), replacement_frame.output);
        try std.testing.expect(replacement_frame.output.generation != first_frame.?.output.generation);
        try std.testing.expectError(
            error.StaleFrame,
            replacement.renderFrame(first_frame.?, &.{}, &.{}, &.{}, 1),
        );
    } else {
        coordinator.disconnected(coordinator.peer.?);
    }

    _ = try client.prepareClose();
    _ = try client_driver.schedule();
    client_progress = try client_driver.prepare(&client_handler);
    _ = try client_reactor.ring.submit();
    if (trigger == .session_disable) try coordinator.requestStop();
    var wayring_drained = false;
    for (0..256) |_| {
        client_progress = try drainClient(&client_reactor, &client_driver, &client_handler);
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and client_progress.quiescent and coordinator.backendDrainComplete()) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(wayring_drained);
    try std.testing.expect(client_progress.quiescent);
    try std.testing.expect(coordinator.backendDrainComplete());
    try std.testing.expect(coordinator.cursor_layer.content == null);
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.imports.available());
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.frame_pool.available());
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.release_pool.available());
    try std.testing.expectEqual(@as(usize, 2), coordinator.presentations.available());
    try std.testing.expectEqual(@as(usize, 1), client_handler.frame_done);
    try std.testing.expectEqual(@as(usize, 1), client_handler.release_done);
    try std.testing.expectEqual(@as(usize, 1), client_handler.frame_deleted);
    try std.testing.expectEqual(@as(usize, 1), client_handler.release_deleted);
    try std.testing.expectEqual(
        @as(usize, if (trigger == .session_disable) 2 else 1),
        fixture.device_closes,
    );
    try std.testing.expect(fixture.framebuffer_removal_before_bo);

    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const ClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    release: ?wayring.objects.Handle = null,
    queued: bool = false,
    frame_done: usize = 0,
    release_done: usize = 0,
    frame_deleted: usize = 0,
    release_deleted: usize = 0,

    fn complete(self: ClientHandler) bool {
        return self.frame_done == 1 and self.release_done == 1 and
            self.frame_deleted == 1 and self.release_deleted == 1;
    }

    pub fn event(self: *ClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name))
                        self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_compositor.info, @min(global.version, 7), null);
                    if (std.mem.eql(u8, global.interface, protocol.wl_shm.info.name))
                        self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_shm.info, @min(global.version, 2), null);
                    if (self.compositor != null and self.shm != null and !self.queued) try self.queueWork();
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_shm, self.objects, self.shm.?, message, fds);
        } else if (target.object.interface == &ClientCore.Callback.info) {
            const callback = self.objects.namespace.lookupHandle(message.header.object_id) orelse return error.MissingCallback;
            const callback_event = try ClientCore.decodeCallbackEvent(self.objects, callback, message, fds);
            if (message.header.object_id == self.frame.?.id) {
                try std.testing.expect(callback_event.done.callback_data != 0);
                self.frame_done += 1;
            } else if (message.header.object_id == self.release.?.id) {
                try std.testing.expectEqual(@as(u32, 0), callback_event.done.callback_data);
                self.release_done += 1;
            } else return error.UnexpectedCallback;
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => |deleted| {
                    if (deleted.id == self.frame.?.id) self.frame_deleted += 1;
                    if (deleted.id == self.release.?.id) self.release_deleted += 1;
                },
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn queueWork(self: *ClientHandler) !void {
        try self.queueCommittedSurface();
        self.queued = true;
    }

    fn replaceCommittedSurface(self: *ClientHandler) !void {
        try self.destroySurface();
        try self.queueCommittedSurface();
    }

    fn replaceWithEmptySurface(self: *ClientHandler) !void {
        try self.destroySurface();
        self.surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
    }

    fn destroySurface(self: *ClientHandler) !void {
        if (self.surface) |surface|
            try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .destroy = .{} });
        self.surface = null;
    }

    fn queueCommittedSurface(self: *ClientHandler) !void {
        const surface = (try protocol.wl_compositor.construct_create_surface(self.objects, self.queue, self.compositor.?, .{})).id;
        self.surface = surface;
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(self.objects, self.queue, self.shm.?, .{ .fd = descriptor, .size = 4096 });
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(self.objects, self.queue, pool.id, .{
            .offset = 16,
            .width = 3,
            .height = 2,
            .stride = 16,
            .format = .argb8888,
        })).id;
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } });
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 } });
        self.frame = (try protocol.wl_surface.construct_frame(self.objects, self.queue, surface, .{})).callback;
        self.release = (try protocol.wl_surface.construct_get_release(self.objects, self.queue, surface, .{})).callback;
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .commit = .{} });
        try wayring.client.sendRequest(protocol.wl_buffer, self.objects, self.queue, buffer, .{ .destroy = .{} });
        try wayring.client.sendRequest(protocol.wl_shm_pool, self.objects, self.queue, pool.id, .{ .destroy = .{} });
    }
};

pub const SessionCommand = enum { enable, disable };

pub const Fixture = struct {
    session_fd: linux.fd_t,
    drm_fd: linux.fd_t,
    callback: ?*ouro.backend_platform.CallbackContext = null,
    command: SessionCommand = .enable,
    bo_bytes: [4][32]u8 align(4) = .{[_]u8{0} ** 32} ** 4,
    bo_count: usize = 0,
    bo_destroyed: usize = 0,
    framebuffer_removed: usize = 0,
    framebuffer_removal_before_bo: bool = false,
    requests: [4]u8 = .{0} ** 4,
    request_count: usize = 0,
    flip_userdata: ?*anyopaque = null,
    page_flips: usize = 0,
    device_closes: usize = 0,
    seat_closes: usize = 0,
    request_destroyed: usize = 0,
    gbm_destroyed: usize = 0,
    discover_cards: bool = true,

    pub fn init() !Fixture {
        return .{ .session_fd = try eventFd(), .drm_fd = try eventFd() };
    }

    pub fn deinit(self: *Fixture) void {
        if (self.session_fd >= 0) _ = linux.close(self.session_fd);
        if (self.drm_fd >= 0) _ = linux.close(self.drm_fd);
    }

    pub fn signalSession(self: *Fixture, command: SessionCommand) !void {
        self.command = command;
        try signalFd(self.session_fd);
    }

    pub fn platforms(self: *Fixture) Coordinator.Platforms {
        return .{
            .session = .{ .context = self, .vtable = &session_vtable },
            .drm = .{ .context = self, .vtable = &drm_vtable },
            .output = .{
                .gbm = .{ .context = self, .vtable = &gbm_vtable },
                .framebuffer = .{ .context = self, .vtable = &framebuffer_vtable },
                .atomic = .{ .context = self, .vtable = &atomic_vtable },
            },
        };
    }

    pub fn signalOutput(self: *Fixture) !void {
        try signalFd(self.drm_fd);
    }

    const session_vtable: ouro.backend_platform.Platform.VTable = .{
        .open_seat = openSeat,
        .close_seat = closeSeat,
        .get_fd = getSeatFd,
        .dispatch = dispatchSeat,
        .disable_seat = disableSeat,
        .open_device = openDevice,
        .close_device = closeDevice,
        .close_fd = closeFd,
    };
    const drm_vtable: ouro.drm_platform.Platform.VTable = .{
        .discover = discover,
        .enable_client_caps = enableCaps,
        .read_topology = topology,
    };
    const gbm_vtable: ouro.gbm.Platform.VTable = .{
        .create_device = createGbm,
        .destroy_device = destroyGbm,
        .create_bo = createBo,
        .destroy_bo = destroyBo,
        .metadata = metadata,
        .export_plane_fd = exportPlane,
        .map = mapBo,
        .unmap = unmapBo,
    };
    const framebuffer_vtable: ouro.drm_framebuffer.Platform.VTable = .{ .add = addFb, .remove = removeFb };
    const atomic_vtable: ouro.drm_atomic.Platform.VTable = .{
        .create_blob = createBlob,
        .destroy_blob = destroyBlob,
        .create_request = createRequest,
        .destroy_request = destroyRequest,
        .reset_request = resetRequest,
        .add_property = addProperty,
        .commit = atomicCommit,
        .handle_events = handleEvents,
    };

    fn openSeat(context: *anyopaque, callback: *ouro.backend_platform.CallbackContext) !*anyopaque {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.callback = callback;
        return self;
    }
    fn closeSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.seat_closes += 1;
        _ = linux.close(self.session_fd);
        self.session_fd = -1;
    }
    fn getSeatFd(context: *anyopaque, _: *anyopaque) !linux.fd_t {
        return (@as(*Fixture, @ptrCast(@alignCast(context)))).session_fd;
    }
    fn dispatchSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        var value: u64 = 0;
        const result = linux.read(self.session_fd, @ptrCast(&value), @sizeOf(u64));
        if (linux.errno(result) == .AGAIN) return;
        if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64))
            return error.EventFdReadFailed;
        const callback = self.callback.?;
        switch (self.command) {
            .enable => callback.listener.enable(callback.userdata),
            .disable => callback.listener.disable(callback.userdata),
        }
    }
    fn disableSeat(_: *anyopaque, _: *anyopaque) !void {}
    fn openDevice(context: *anyopaque, _: *anyopaque, _: [:0]const u8) !ouro.backend_platform.OpenedDevice {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.drm_fd < 0) self.drm_fd = try eventFd();
        return .{ .id = 1, .fd = self.drm_fd };
    }
    fn closeDevice(context: *anyopaque, _: *anyopaque, _: i32) !void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).device_closes += 1;
    }
    fn closeFd(context: *anyopaque, fd: linux.fd_t) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        _ = linux.close(fd);
        if (fd == self.drm_fd) self.drm_fd = -1;
    }

    fn discover(context: *anyopaque, cards: []ouro.drm_platform.Card, _: []const u8) !usize {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (!self.discover_cards) return 0;
        var card: ouro.drm_platform.Card = .{};
        const path = "/dev/dri/card-test";
        const stable = "/devices/test";
        @memcpy(card.path[0..path.len], path);
        card.path_len = path.len;
        @memcpy(card.syspath[0..stable.len], stable);
        card.syspath_len = stable.len;
        card.boot_vga = true;
        cards[0] = card;
        return 1;
    }
    fn enableCaps(_: *anyopaque, _: linux.fd_t) !void {}
    fn topology(context: *anyopaque, _: linux.fd_t, out: *ouro.drm_platform.TopologyBuffer) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        out.reset();
        out.connectors[0] = .{ .id = 10, .connector_type = 1, .connector_type_id = 1, .connected = true, .desktop = true, .width_mm = 1, .height_mm = 1, .encoder_id = 20, .mode_start = 0, .mode_count = 1, .encoder_start = 0, .encoder_count = 1, .properties = .{ .crtc_id = 1 } };
        out.modes[0] = .{ .clock = 1, .hdisplay = 3, .hsync_start = 3, .hsync_end = 3, .htotal = 3, .hskew = 0, .vdisplay = 2, .vsync_start = 2, .vsync_end = 2, .vtotal = 2, .vscan = 0, .vrefresh = 60, .flags = 0, .mode_type = 0 };
        out.connector_encoders[0] = 20;
        out.encoders[0] = .{ .id = 20, .crtc_id = 30, .possible_crtcs = 1 };
        out.crtcs[0] = .{ .id = 30, .index = 0, .properties = .{ .active = 2, .mode_id = 3 } };
        out.planes[0] = .{ .id = 40, .possible_crtcs = 1, .plane_type_value = 1, .format_start = 0, .format_count = 1, .properties = .{ .plane_type = 4, .fb_id = 5, .crtc_id = 6, .src_x = 7, .src_y = 8, .src_w = 9, .src_h = 10, .crtc_x = 11, .crtc_y = 12, .crtc_w = 13, .crtc_h = 14 } };
        out.formats[0] = .{ .fourcc = ouro.gbm.format_xrgb8888, .modifier = ouro.gbm.modifier_linear };
        out.connector_count = 1;
        out.mode_count = 1;
        out.connector_encoder_count = 1;
        out.encoder_count = 1;
        out.crtc_count = 1;
        out.plane_count = 1;
        out.format_count = 1;
        _ = self;
    }

    fn createGbm(context: *anyopaque, _: linux.fd_t) !ouro.gbm.Device {
        return context;
    }
    fn destroyGbm(context: *anyopaque, _: ouro.gbm.Device) void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).gbm_destroyed += 1;
    }
    fn createBo(context: *anyopaque, _: ouro.gbm.Device, _: ouro.gbm.Allocation) !ouro.gbm.Bo {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const bo = &self.bo_bytes[self.bo_count];
        self.bo_count += 1;
        return @ptrCast(bo);
    }
    fn destroyBo(context: *anyopaque, _: ouro.gbm.Bo) void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).bo_destroyed += 1;
    }
    fn metadata(_: *anyopaque, bo: ouro.gbm.Bo) !ouro.gbm.Metadata {
        return .{ .width = 3, .height = 2, .format = ouro.gbm.format_xrgb8888, .modifier = ouro.gbm.modifier_linear, .plane_count = 1, .handles = .{ @truncate(@intFromPtr(bo)), 0, 0, 0 }, .strides = .{ 16, 0, 0, 0 } };
    }
    fn exportPlane(_: *anyopaque, _: ouro.gbm.Bo, _: u8) !linux.fd_t {
        return error.UnexpectedExport;
    }
    fn mapBo(_: *anyopaque, bo: ouro.gbm.Bo) !ouro.gbm.Mapping {
        return .{ .data = @ptrCast(bo), .stride = 16, .token = bo };
    }
    fn unmapBo(_: *anyopaque, _: ouro.gbm.Bo, _: ouro.gbm.MapToken) void {}
    fn addFb(_: *anyopaque, _: linux.fd_t, meta: ouro.gbm.Metadata) !u32 {
        return meta.handles[0];
    }
    fn removeFb(context: *anyopaque, _: linux.fd_t, _: u32) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.framebuffer_removed == 0) self.framebuffer_removal_before_bo = self.bo_destroyed == 0;
        self.framebuffer_removed += 1;
    }
    fn createBlob(_: *anyopaque, _: linux.fd_t, _: ouro.drm.Mode) !u32 {
        return 1;
    }
    fn destroyBlob(_: *anyopaque, _: linux.fd_t, _: u32) !void {}
    fn createRequest(context: *anyopaque) !ouro.drm_atomic.Request {
        const self: *Fixture = @ptrCast(@alignCast(context));
        const request = &self.requests[self.request_count];
        self.request_count += 1;
        return @ptrCast(request);
    }
    fn destroyRequest(context: *anyopaque, _: ouro.drm_atomic.Request) void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).request_destroyed += 1;
    }
    fn resetRequest(_: *anyopaque, _: ouro.drm_atomic.Request) void {}
    fn addProperty(_: *anyopaque, _: ouro.drm_atomic.Request, _: u32, _: u32, _: u64) !void {}
    fn atomicCommit(context: *anyopaque, _: linux.fd_t, _: ouro.drm_atomic.Request, flags: ouro.drm_atomic.CommitFlags, userdata: ?*anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (flags.page_flip_event) {
            self.flip_userdata = userdata;
            try signalFd(self.drm_fd);
        }
    }
    fn handleEvents(context: *anyopaque, _: linux.fd_t, callback: ouro.drm_atomic.FlipCallback) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try consumeFd(self.drm_fd);
        const userdata = self.flip_userdata orelse return error.MissingFlip;
        self.flip_userdata = null;
        self.page_flips += 1;
        callback(userdata, 1, 2, 3000, 30);
    }
};

pub fn coordinatorConfig() Coordinator.Config {
    return .{ .router_capacity = 12, .timer_capacity = 2, .device_capacity = 1, .shm = .{ .limits = .{ .max_pool_bytes = 4096 }, .pool_capacity = 1, .buffer_capacity = 1, .formats = &shm_formats }, .surface = .{ .surface_capacity = 1, .region_capacity = 1, .region_operation_capacity = 1, .frame_callback_capacity = 1, .release_callback_capacity = 1, .content_update_capacity = 1, .dependency_capacity = 1, .attachment_capacity = 1, .copy_capacity = 1, .max_copy_bytes = pixels.len }, .drm = .{ .card_capacity = 1, .connector_capacity = 1, .mode_capacity = 1, .connector_encoder_capacity = 1, .encoder_capacity = 1, .crtc_capacity = 1, .plane_capacity = 1, .format_capacity = 1, .event_capacity = 4 }, .output = .{ .output_id = .{ .index = 0, .generation = 1 }, .scheduler = .{ .refresh_ns = 4 * std.time.ns_per_ms, .render_budget_ns = std.time.ns_per_ms }, .renderer = .pixman, .image_count = 2, .max_samples = 2, .max_source_bytes = pixels.len, .max_source_width = 3, .max_source_height = 2, .kms = .{ .event_capacity = 2 } } };
}
pub fn compositorConfig() Compositor.Config {
    return .{ .ring = .{ .entries = 32, .flags = 0 }, .reactor = clientReactorConfig(), .runtime = .{ .actor = .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 }, .object_capacity = 16, .object_quota = 16, .buckets_per_client = 16, .max_globals = 4, .registry_capacity = 1 } };
}
pub fn clientReactorConfig() wayring.io_uring.Config {
    return .{ .max_connections = 1, .receive_buffer_size = 4096, .receive_buffer_count = 4, .receive_control_capacity = 256, .fragment_block_size = 256, .fragment_block_count = 4, .transmit_block_size = 512, .transmit_block_count = 8, .descriptor_count = 4, .send_descriptor_capacity = 2 };
}
fn drainClient(reactor: *wayring.io_uring.Reactor, driver: *ClientDriver, handler: *ClientHandler) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0) 0 else try reactor.ring.copy_cqes(&completions, 0);
    const progress = try driver.dispatch(completions[0..count], handler);
    if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    return progress;
}
fn submitClient(reactor: *wayring.io_uring.Reactor, driver: *ClientDriver, handler: *ClientHandler) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}
fn drainServer(root: *Compositor, coordinator: *Coordinator, loop: *Loop) !void {
    var wayring_drained = false;
    for (0..128) |_| {
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and coordinator.backendDrainComplete()) return;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    return error.DrainTimeout;
}
fn waitForEither(server: *linux.IoUring, client: *linux.IoUring) !void {
    for (0..1_000_000) |_| {
        if (server.cq_ready() != 0 or client.cq_ready() != 0) return;
        _ = linux.sched_yield();
    }
    return error.CompletionTimeout;
}
fn waitReady(ring: *linux.IoUring) !void {
    for (0..1_000_000) |_| {
        if (ring.cq_ready() != 0) return;
        _ = linux.sched_yield();
    }
    return error.CompletionTimeout;
}
fn eventFd() !linux.fd_t {
    const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
    if (linux.errno(result) != .SUCCESS) return error.EventFdFailed;
    return @intCast(result);
}
fn signalFd(fd: linux.fd_t) !void {
    const value: u64 = 1;
    const result = linux.write(fd, @ptrCast(&value), @sizeOf(u64));
    if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64)) return error.EventFdWriteFailed;
}
fn consumeFd(fd: linux.fd_t) !void {
    var value: u64 = 0;
    const result = linux.read(fd, @ptrCast(&value), @sizeOf(u64));
    if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64)) return error.EventFdReadFailed;
}
fn ordinaryMemfd(size: usize, offset: usize, bytes: []const u8) !linux.fd_t {
    const result = linux.memfd_create("ouro-r15", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS) return error.SystemCallFailed;
    const written = linux.pwrite(fd, bytes.ptr, bytes.len, @intCast(offset));
    if (linux.errno(written) != .SUCCESS or written != bytes.len) return error.SystemCallFailed;
    return fd;
}
