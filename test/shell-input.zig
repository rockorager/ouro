//! Generated-client M3 shell/input vertical over the deterministic DRM fixture.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("xdg_protocol");
const physical_fixture = @import("drm-presentation.zig");

const linux = std.os.linux;
const ClientConnection = wayring.client.Connection(protocol);
const ClientDriver = wayring.client.Driver(protocol);
const ClientCore = wayring.client.Core(protocol);
const Compositor = ouro.compositor.Compositor(protocol);
const Coordinator = ouro.physical.Coordinator(protocol);
const Loop = ouro.loop.Loop(protocol);

const pixels = [_]u8{
    0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff, 0x70, 0x80, 0x90, 0xff, 0, 0, 0, 0,
    0xa0, 0xb0, 0xc0, 0xff, 0xd0, 0xe0, 0xf0, 0xff, 0x11, 0x22, 0x33, 0xff, 0, 0, 0, 0,
};

test "shell-input: pollable backend retains a backpressured suffix without replay" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-shell-input-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var input = try FakeInput.init();
    defer input.deinit();
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        physical_fixture.compositorConfig(),
    );
    var platforms = fixture.platforms();
    platforms.input = input.platform();
    var config = physical_fixture.coordinatorConfig();
    // Two events force Backend.advance to own the suffix of this four-event
    // platform batch after the accepted prefix has been cleared.
    config.input.device_capacity = 1;
    config.input.event_capacity = 2;
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
    config.surface.content_update_capacity = 2;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_source_bytes = pixels.len + 4;
    const coordinator = try Coordinator.create(
        allocator,
        root,
        platforms,
        config,
    );
    var loop = try Loop.init(
        allocator,
        root,
        &coordinator.router,
        &coordinator.timers,
        coordinator,
        .{ .completion_batch = 16 },
    );
    try coordinator.start(&loop);

    var client_reactor: wayring.io_uring.Reactor = undefined;
    try client_reactor.initOwned(
        allocator,
        .{ .entries = 16, .flags = 0 },
        physical_fixture.clientReactorConfig(),
    );
    var client = try ClientConnection.attach(
        allocator,
        &client_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 2, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: Handler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var input_sent = false;
    var key_sent = false;
    var motion_redraw_sent = false;
    var two_layers_observed = false;
    var first_cursor_destination: ?ouro.render.Rect = null;
    var client_progress: ClientDriver.Progress = .{};
    for (0..512) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!input_sent and coordinator.stats.applied == 1 and coordinator.input != null) {
            try input.publish(&.{
                .{ .device_added = .{
                    .device = 42,
                    .capabilities = .{ .pointer = true, .keyboard = true },
                } },
            });
            input_sent = true;
        }
        if (input_sent and !key_sent and handler.input_ready and input.cursor == input.event_count) {
            try input.publish(&.{
                .{ .pointer_motion = .{
                    .device = 42,
                    .time_usec = 1_000,
                    .dx = 1,
                    .dy = 1,
                } },
                .{ .pointer_button = .{
                    .device = 42,
                    .time_usec = 2_000,
                    .button = 0x110,
                    .pressed = true,
                } },
                .{ .keyboard_key = .{
                    .device = 42,
                    .time_usec = 3_000,
                    .key = 30,
                    .pressed = true,
                } },
            });
            key_sent = true;
        }
        if (coordinator.stats.submitted == 2 and !two_layers_observed) {
            const app = coordinator.app_layer.sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expectEqual(coordinator.app_layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.sample, coordinator.app_layer.binding.?.sample);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(cursor.sample, coordinator.cursor_layer.binding.?.sample);
            try std.testing.expectEqual(cursor.presentation, submitted[1].presentation);
            try std.testing.expectEqual(@as(i32, 0), app.destination.x);
            try std.testing.expectEqual(@as(i32, 0), app.destination.y);
            try std.testing.expectEqual(@as(u32, 3), app.destination.width);
            try std.testing.expectEqual(@as(u32, 2), app.destination.height);
            try std.testing.expect(cursor.destination.x >= 0 and cursor.destination.y >= 0);
            first_cursor_destination = cursor.destination;
            two_layers_observed = true;
        }
        if (coordinator.stats.presented == 2 and !motion_redraw_sent) {
            try input.publish(&.{.{ .pointer_motion = .{
                .device = 42,
                .time_usec = 4_000,
                .dx = -1,
                .dy = 0,
            } }});
            motion_redraw_sent = true;
        }
        if (coordinator.stats.submitted == 3) {
            const app = coordinator.app_layer.sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expectEqual(coordinator.app_layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(cursor.presentation, submitted[1].presentation);
            try std.testing.expect(!std.meta.eql(first_cursor_destination.?, cursor.destination));
        }
        if (coordinator.stats.presented == 3 and handler.pointer_motion == 2 and
            handler.pointer_button != 0 and handler.keyboard_key != 0) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0) {
            try waitForEither(&root.ring, client_reactor.ring);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), handler.configure_count);
    try std.testing.expect(handler.configure_serial != 0);
    try std.testing.expectEqual(handler.configure_serial, handler.acked_serial);
    try std.testing.expect(two_layers_observed);
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, 3), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 3), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, 5), coordinator.stats.input_events);
    try std.testing.expectEqual(@as(usize, 4), input.dispatch_count);
    try std.testing.expectEqual(@as(usize, 9), input.next_count);
    try std.testing.expect(handler.pointer_enter != 0);
    try std.testing.expect(handler.keyboard_enter != 0);
    try std.testing.expect(handler.pointer_motion != 0);
    try std.testing.expect(handler.pointer_button != 0);
    try std.testing.expect(handler.keyboard_key != 0);
    try std.testing.expectEqual(@as(usize, 2), handler.pointer_motion);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_button);
    try std.testing.expectEqual(@as(usize, 1), handler.keyboard_key);
    try std.testing.expectEqual(@as(usize, 1), handler.buffer_release);
    try std.testing.expect(handler.buffer_release_order != 0);
    try std.testing.expect(handler.buffer_release_order < handler.frame_done_order);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    const retained_app = coordinator.app_layer.sample.?;
    const retained_cursor = coordinator.cursor_layer.sample.?;
    const first_output_generation = coordinator.output.?.outputId().generation;
    try fixture.signalSession(.disable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.output == null and coordinator.session.state == .disabled) break;
        if (root.ring.cq_ready() == 0) try waitServer(&root.ring);
    }
    try std.testing.expect(coordinator.output == null);
    try std.testing.expect(coordinator.app_layer.active);
    try std.testing.expect(coordinator.cursor_layer.active);
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layer.sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.stats.presented == 4) break;
        if (root.ring.cq_ready() == 0) try waitServer(&root.ring);
    }
    try std.testing.expectEqual(@as(usize, 4), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 4), coordinator.stats.presented);
    try std.testing.expect(coordinator.output.?.outputId().generation != first_output_generation);
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layer.sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);

    try handler.destroyCursor();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..64) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!coordinator.cursor_layer.active) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(!coordinator.cursor_layer.active);
    try std.testing.expect(coordinator.app_layer.active);

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitClient(&client_reactor, &driver, &handler);
    var wayring_drained = false;
    for (0..256) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and client_progress.quiescent and coordinator.backendDrainComplete()) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(wayring_drained);
    try std.testing.expect(client_progress.quiescent);
    try std.testing.expect(coordinator.backendDrainComplete());
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.output_drains);

    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const FakeInput = struct {
    fd: linux.fd_t,
    events: [8]ouro.input_platform.RawEvent = undefined,
    event_count: usize = 0,
    cursor: usize = 0,
    ready: bool = false,
    dispatch_count: usize = 0,
    next_count: usize = 0,

    fn init() !FakeInput {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.EventFdFailed;
        return .{ .fd = @intCast(result) };
    }

    fn deinit(self: *FakeInput) void {
        _ = linux.close(self.fd);
        self.fd = -1;
    }

    fn platform(self: *FakeInput) ouro.input_platform.Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    fn publish(self: *FakeInput, events: []const ouro.input_platform.RawEvent) !void {
        if (self.ready or self.cursor != self.event_count or events.len > self.events.len)
            return error.InvalidFakeInputState;
        @memcpy(self.events[0..events.len], events);
        self.event_count = events.len;
        self.cursor = 0;
        self.ready = true;
        const value: u64 = 1;
        const result = linux.write(self.fd, @ptrCast(&value), @sizeOf(u64));
        if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64))
            return error.EventFdWriteFailed;
    }

    const vtable: ouro.input_platform.Platform.VTable = .{
        .create = create,
        .destroy = destroy,
        .get_fd = getFd,
        .dispatch = dispatch,
        .next_event = nextEvent,
        .suspend_context = suspendContext,
        .resume_context = resumeContext,
    };

    fn create(context: *anyopaque, _: *ouro.input_platform.Restricted, _: [:0]const u8) !*anyopaque {
        return context;
    }
    fn destroy(_: *anyopaque, _: *anyopaque) void {}
    fn getFd(context: *anyopaque, _: *anyopaque) !linux.fd_t {
        return (@as(*FakeInput, @ptrCast(@alignCast(context)))).fd;
    }
    fn dispatch(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        self.dispatch_count += 1;
        if (!self.ready) return;
        var value: u64 = 0;
        const result = linux.read(self.fd, @ptrCast(&value), @sizeOf(u64));
        if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64))
            return error.EventFdReadFailed;
        self.ready = false;
    }
    fn nextEvent(context: *anyopaque, _: *anyopaque) !?ouro.input_platform.RawEvent {
        const self: *FakeInput = @ptrCast(@alignCast(context));
        self.next_count += 1;
        if (self.cursor == self.event_count) return null;
        defer self.cursor += 1;
        return self.events[self.cursor];
    }
    fn suspendContext(_: *anyopaque, _: *anyopaque) !void {}
    fn resumeContext(_: *anyopaque, _: *anyopaque) !void {}
};

const Handler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    xdg_surface: ?wayring.objects.Handle = null,
    toplevel: ?wayring.objects.Handle = null,
    pointer: ?wayring.objects.Handle = null,
    keyboard: ?wayring.objects.Handle = null,
    cursor_surface: ?wayring.objects.Handle = null,
    mapped_buffer: ?wayring.objects.Handle = null,
    frame_callback: ?wayring.objects.Handle = null,
    shell_created: bool = false,
    mapped: bool = false,
    input_requested: bool = false,
    input_ready: bool = false,
    configure_count: usize = 0,
    configure_serial: u32 = 0,
    acked_serial: u32 = 0,
    pointer_enter: usize = 0,
    pointer_motion: usize = 0,
    pointer_button: usize = 0,
    keyboard_enter: usize = 0,
    keyboard_key: usize = 0,
    buffer_release: usize = 0,
    completion_order: usize = 0,
    buffer_release_order: usize = 0,
    frame_done_order: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *Handler,
        _: wayring.io_uring.Peer,
        failure: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
        _ = failure;
    }

    pub fn event(
        self: *Handler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| try self.bindGlobal(value),
                .global_remove => {},
            }
            try self.maybeCreateShell();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_toplevel.info) {
            switch (try protocol.xdg_toplevel.decodeEvent(message, fds)) {
                .configure => {},
                .close => {},
                else => {},
            }
        } else if (target.object.interface == &protocol.xdg_surface.info) {
            switch (try protocol.xdg_surface.decodeEvent(message, fds)) {
                .configure => |value| {
                    self.configure_count += 1;
                    self.configure_serial = value.serial;
                    try protocol.xdg_surface.encodeRequest(self.queue, self.xdg_surface.?.id, .{
                        .ack_configure = .{ .serial = value.serial },
                    });
                    self.acked_serial = value.serial;
                    if (!self.mapped) try self.mapSurface();
                },
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            switch (try protocol.wl_seat.decodeEvent(message, fds)) {
                .capabilities => |value| if (!self.input_requested and
                    value.capabilities.contains(protocol.wl_seat.capability.pointer) and
                    value.capabilities.contains(protocol.wl_seat.capability.keyboard))
                {
                    self.pointer = (try protocol.wl_seat.construct_get_pointer(
                        self.objects,
                        self.queue,
                        self.seat.?,
                        .{},
                    )).id;
                    self.keyboard = (try protocol.wl_seat.construct_get_keyboard(
                        self.objects,
                        self.queue,
                        self.seat.?,
                        .{},
                    )).id;
                    self.input_requested = true;
                },
                .name => {},
            }
        } else if (target.object.interface == &protocol.wl_pointer.info) {
            switch (try protocol.wl_pointer.decodeEvent(message, fds)) {
                .enter => |value| {
                    self.pointer_enter += 1;
                    _ = value;
                },
                .motion => self.pointer_motion += 1,
                .button => |value| {
                    self.pointer_button += 1;
                    if (self.cursor_surface == null) try self.queueCursor(value.serial);
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.wl_keyboard.info) {
            switch (try protocol.wl_keyboard.decodeEvent(message, fds)) {
                .keymap => |value| {
                    _ = linux.close(value.fd);
                    self.input_ready = true;
                },
                .enter => self.keyboard_enter += 1,
                .key => self.keyboard_key += 1,
                else => {},
            }
        } else if (target.object.interface == &protocol.wl_buffer.info) {
            switch (try protocol.wl_buffer.decodeEvent(message, fds)) {
                .release => {
                    self.buffer_release += 1;
                    self.completion_order += 1;
                    self.buffer_release_order = self.completion_order;
                    try wayring.client.sendRequest(
                        protocol.wl_buffer,
                        self.objects,
                        self.queue,
                        self.mapped_buffer.?,
                        .{ .destroy = .{} },
                    );
                    self.mapped_buffer = null;
                },
            }
        } else if (target.object.interface == &ClientCore.Callback.info) {
            switch (try ClientCore.decodeCallbackEvent(
                self.objects,
                self.frame_callback.?,
                message,
                fds,
            )) {
                .done => {
                    self.completion_order += 1;
                    self.frame_done_order = self.completion_order;
                    self.frame_callback = null;
                },
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn bindGlobal(self: *Handler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
            self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_seat.info, @min(value.version, 9), null);
    }

    fn maybeCreateShell(self: *Handler) !void {
        if (self.shell_created or self.compositor == null or self.shm == null or self.wm_base == null)
            return;
        self.surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
            self.objects,
            self.queue,
            self.wm_base.?,
            .{ .surface = self.surface.?.id },
        )).id;
        self.toplevel = (try protocol.xdg_surface.construct_get_toplevel(
            self.objects,
            self.queue,
            self.xdg_surface.?,
            .{},
        )).id;
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{ .commit = .{} });
        self.shell_created = true;
    }

    fn mapSurface(self: *Handler) !void {
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 16,
                .width = 3,
                .height = 2,
                .stride = 16,
                .format = .argb8888,
            },
        )).id;
        self.mapped_buffer = buffer;
        self.frame_callback = (try protocol.wl_surface.construct_frame(
            self.objects,
            self.queue,
            self.surface.?,
            .{},
        )).callback;
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{
            .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{
            .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{ .commit = .{} });
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        self.mapped = true;
    }

    fn queueCursor(self: *Handler, serial: u32) !void {
        const descriptor = try ordinaryMemfd(4096, 0, &.{ 0xff, 0xff, 0xff, 0xff });
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{ .offset = 0, .width = 1, .height = 1, .stride = 4, .format = .argb8888 },
        )).id;
        const surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.cursor_surface = surface;
        try protocol.wl_pointer.encodeRequest(self.queue, self.pointer.?.id, .{ .set_cursor = .{
            .serial = serial,
            .surface = surface.id,
            .hotspot_x = 0,
            .hotspot_y = 0,
        } });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .damage_buffer = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{ .commit = .{} });
        try wayring.client.sendRequest(protocol.wl_buffer, self.objects, self.queue, buffer, .{ .destroy = .{} });
        try wayring.client.sendRequest(protocol.wl_shm_pool, self.objects, self.queue, pool.id, .{ .destroy = .{} });
    }

    fn destroyCursor(self: *Handler) !void {
        try wayring.client.sendRequest(
            protocol.wl_surface,
            self.objects,
            self.queue,
            self.cursor_surface.?,
            .{ .destroy = .{} },
        );
        self.cursor_surface = null;
    }
};

fn drainClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *Handler,
) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0)
        0
    else
        try reactor.ring.copy_cqes(&completions, 0);
    var progress = try driver.dispatch(completions[0..count], handler);
    // Event callbacks can enqueue generated-client requests after dispatch's
    // preparation phase. Explicitly schedule that new output in this harness.
    if (handler.queue.queuedBytes() != 0) {
        _ = try driver.schedule();
        const prepared = try driver.prepare(handler);
        progress.prepared += prepared.prepared;
        progress.pending = prepared.pending;
        progress.quiescent = prepared.quiescent;
    }
    if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    return progress;
}

fn submitClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *Handler,
) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}

fn waitForEither(server: *linux.IoUring, client: *linux.IoUring) !void {
    for (0..10_000_000) |_| {
        if (server.cq_ready() != 0 or client.cq_ready() != 0) return;
        _ = linux.sched_yield();
    }
    return error.CompletionTimeout;
}

fn waitServer(server: *linux.IoUring) !void {
    for (0..1_000_000) |_| {
        if (server.cq_ready() != 0) return;
        _ = linux.sched_yield();
    }
    return error.CompletionTimeout;
}

fn ordinaryMemfd(size: usize, offset: usize, bytes: []const u8) !linux.fd_t {
    const result = linux.memfd_create("ouro-shell-input", 0);
    if (linux.errno(result) != .SUCCESS) return error.MemfdCreateFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    const truncate_result = linux.ftruncate(fd, @intCast(size));
    if (linux.errno(truncate_result) != .SUCCESS) return error.TruncateFailed;
    const written = linux.pwrite(fd, bytes.ptr, bytes.len, @intCast(offset));
    if (linux.errno(written) != .SUCCESS or written != bytes.len) return error.WriteFailed;
    return fd;
}

test "shell-input: cursor composition retains source identities" {
    const Id = packed struct { index: u32, generation: u32 };
    const Cursor = ouro.scene_cursor.Cursor(Id);
    const id: Id = .{ .index = 4, .generation = 9 };
    const source = ouro.render.SurfaceSample{
        .sample = .{ .surface = 0x0000_0009_0000_0004, .commit_sequence = 17 },
        .presentation = .{ .slot = 3, .generation = 12 },
        .source = .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .argb8888_premultiplied,
            .bytes = &.{ 0xff, 0xff, 0xff, 0xff },
        },
        .crop = ouro.render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    var cursor: Cursor = .{ .pointer_available = true };
    cursor.request(id, .{ .x = 0, .y = 0 });
    cursor.move(.{ .x = 2, .y = 1 });
    const placed = (try cursor.composite(.{ .surface = id, .sample = source }, .{
        .width = 3,
        .height = 2,
    })).?;
    try std.testing.expectEqual(source.sample, placed.sample);
    try std.testing.expectEqual(source.presentation, placed.presentation);
}
