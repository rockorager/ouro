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
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 32;
    root_config.runtime.buckets_per_client = 32;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
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
    config.surface.guarded_shm_access = false;
    config.output.max_samples = 3;
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
    var drag_release_sent = false;
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
                    .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
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
                .{ .pointer_axis = .{
                    .device = 42,
                    .time_usec = 3_000,
                    .source = .wheel,
                    .vertical = .{ .value = 15, .value120 = 120 },
                    .horizontal = null,
                } },
                .{ .keyboard_key = .{
                    .device = 42,
                    .time_usec = 4_000,
                    .key = 30,
                    .pressed = true,
                } },
            });
            key_sent = true;
        }
        if (key_sent and !drag_release_sent and coordinator.data_device_adapter.dragActive() and
            input.cursor == input.event_count)
        {
            try input.publish(&.{.{ .pointer_button = .{
                .device = 42,
                .time_usec = 4_500,
                .button = 0x110,
                .pressed = false,
            } }});
            drag_release_sent = true;
        }
        if (coordinator.stats.submitted == 2 and !two_layers_observed) {
            const app = coordinator.app_layers[0].sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expectEqual(coordinator.app_layers[0].binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.sample, coordinator.app_layers[0].binding.?.sample);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(cursor.sample, coordinator.cursor_layer.binding.?.sample);
            try std.testing.expectEqual(cursor.presentation, submitted[1].presentation);
            try std.testing.expectEqual(@as(i32, -1), app.destination.x);
            try std.testing.expectEqual(@as(i32, 0), app.destination.y);
            try std.testing.expectEqual(@as(u32, 3), app.destination.width);
            try std.testing.expectEqual(@as(u32, 2), app.destination.height);
            try std.testing.expect(cursor.destination.x >= 0 and cursor.destination.y >= 0);
            first_cursor_destination = cursor.destination;
            two_layers_observed = true;
        }
        if (coordinator.stats.presented == 2 and !motion_redraw_sent and
            handler.drag_cancelled == 1 and input.cursor == input.event_count)
        {
            try input.publish(&.{.{ .pointer_motion = .{
                .device = 42,
                .time_usec = 5_000,
                .dx = -1,
                .dy = 0,
            } }});
            motion_redraw_sent = true;
        }
        if (coordinator.stats.submitted == 3) {
            const app = coordinator.app_layers[0].sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expectEqual(coordinator.app_layers[0].binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(cursor.presentation, submitted[1].presentation);
            try std.testing.expect(!std.meta.eql(first_cursor_destination.?, cursor.destination));
        }
        if (coordinator.stats.presented == 3 and handler.pointer_motion == 2 and
            handler.pointer_button != 0 and handler.pointer_axis != 0 and
            handler.pointer_axis_value120 != 0 and handler.keyboard_key != 0 and
            handler.drag_cancelled == 1 and handler.drag_enter == 1 and
            handler.drag_leave == 1) break;
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
    try std.testing.expectEqual(@as(usize, 7), coordinator.stats.input_events);
    try std.testing.expectEqual(@as(usize, 5), input.dispatch_count);
    try std.testing.expectEqual(@as(usize, 12), input.next_count);
    try std.testing.expect(handler.pointer_enter != 0);
    try std.testing.expect(handler.keyboard_enter != 0);
    try std.testing.expect(handler.pointer_motion != 0);
    try std.testing.expect(handler.pointer_button != 0);
    try std.testing.expect(handler.keyboard_key != 0);
    try std.testing.expectEqual(@as(usize, 2), handler.pointer_motion);
    try std.testing.expectEqual(@as(usize, 2), handler.pointer_button);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_cancelled);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_data_offer);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_mime_offer);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_source_actions);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_enter);
    try std.testing.expectEqual(@as(usize, 1), handler.drag_leave);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis_source);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis_value120);
    try std.testing.expectEqual(@as(usize, 5), handler.pointer_frame);
    try std.testing.expectEqual(@as(i32, 15 * 256), handler.pointer_axis_fixed);
    try std.testing.expectEqual(@as(i32, 120), handler.pointer_axis_value120_value);
    try std.testing.expectEqual(@as(usize, 1), handler.keyboard_key);
    try std.testing.expectEqual(@as(usize, 1), handler.buffer_release);
    try std.testing.expect(handler.buffer_release_order != 0);
    try std.testing.expect(handler.buffer_release_order < handler.frame_done_order);
    try std.testing.expect(handler.output_geometry);
    try std.testing.expectEqual(@as(i32, 1), handler.output_physical_width);
    try std.testing.expectEqual(@as(i32, 1), handler.output_physical_height);
    try std.testing.expect(handler.output_mode);
    try std.testing.expect(handler.output_scale);
    try std.testing.expect(handler.output_name);
    try std.testing.expect(handler.output_description);
    try std.testing.expect(handler.output_done != 0);
    try std.testing.expectEqual(@as(usize, 2), handler.output_enter);
    try std.testing.expectEqual(@as(usize, 0), handler.output_leave);
    try std.testing.expect(!handler.output_released);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    const retained_app = coordinator.app_layers[0].sample.?;
    const retained_cursor = coordinator.cursor_layer.sample.?;
    const first_output_generation = coordinator.output.?.outputId().generation;
    try fixture.signalSession(.disable);
    for (0..128) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.output == null and coordinator.session.state == .disabled and
            handler.output_leave == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(coordinator.output == null);
    try std.testing.expectEqual(@as(usize, 2), handler.output_leave);
    try std.testing.expect(coordinator.app_layers[0].active);
    try std.testing.expect(coordinator.cursor_layer.active);
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layers[0].sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.stats.presented == 4 and handler.output_enter == 4 and
            handler.output_deleted) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 4), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 4), coordinator.stats.presented);
    try std.testing.expect(coordinator.output.?.outputId().generation != first_output_generation);
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layers[0].sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);
    try std.testing.expectEqual(@as(usize, 4), handler.output_enter);
    try std.testing.expect(handler.output_released);
    try std.testing.expect(handler.output_deleted);

    try handler.destroyCursor();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..64) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!coordinator.cursor_layer.active and handler.output_deleted) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(!coordinator.cursor_layer.active);
    try std.testing.expect(coordinator.app_layers[0].active);
    try std.testing.expect(handler.output_deleted);

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

test "shell-input: idle notifications track activity and visible inhibitors" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-idle-notify-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var input = try FakeInput.init();
    defer input.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 64;
    root_config.runtime.object_quota = 64;
    root_config.runtime.buckets_per_client = 64;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var platforms = fixture.platforms();
    platforms.input = input.platform();
    var config = physical_fixture.coordinatorConfig();
    config.input.device_capacity = 1;
    config.input.event_capacity = 1;
    config.timer_capacity = 6;
    config.surface.guarded_shm_access = false;
    const coordinator = try Coordinator.create(allocator, root, platforms, config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{
        .completion_batch = 16,
    });
    try coordinator.start(&loop);

    var client_reactor: wayring.io_uring.Reactor = undefined;
    try client_reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &client_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 2, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 64, .max_client_ids = 63 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: Handler = .{ .objects = &client.objects, .queue = &actor.transmit, .registry = registry };
    try submitClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var device_added = false;
    for (0..256) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!device_added and coordinator.input != null) {
            try input.publish(&.{.{ .device_added = .{
                .device = 42,
                .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } },
            } }});
            device_added = true;
        }
        if (handler.mapped and handler.input_ready and coordinator.stats.presented >= 1 and
            handler.idle_notifier != null and handler.idle_inhibit_manager != null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.mapped and handler.input_ready);

    try handler.createIdleNotifications();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..10_000) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.standard_idled == 1 and handler.input_idled == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.standard_idled);
    try std.testing.expectEqual(@as(usize, 1), handler.input_idled);

    try handler.createIdleInhibitor();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..10_000) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.standard_resumed == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.standard_resumed);
    try std.testing.expectEqual(@as(usize, 0), handler.input_resumed);

    try input.publish(&.{.{ .pointer_motion = .{
        .device = 42,
        .time_usec = 10_000,
        .dx = 0,
        .dy = 0,
    } }});
    for (0..10_000) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.input_resumed == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.standard_resumed);
    try std.testing.expectEqual(@as(usize, 1), handler.input_resumed);

    for (0..10_000) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.input_idled == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.input_idled);
    try std.testing.expectEqual(@as(usize, 1), handler.standard_idled);

    try handler.destroyIdleInhibitor();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..10_000) |_| {
        _ = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.standard_idled == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.standard_idled);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitClient(&client_reactor, &driver, &handler);
    var drained = false;
    for (0..256) |_| {
        const client_progress = try drainClient(&client_reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and
            coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const two_toplevel_cycle_count = 42;

test "shell-input: two mapped toplevels sustain independent commit cycles" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-two-toplevels-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.reactor.receive_buffer_size = 8192;
    root_config.reactor.receive_buffer_count = 8;
    root_config.reactor.receive_control_capacity = 512;
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 32;
    root_config.runtime.actor.received_fd_budget = 2;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
    config.surface.frame_callback_capacity = 2;
    config.surface.content_update_capacity = 3;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_samples = 3;
    config.output.max_source_bytes = pixels.len * 2;
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
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
    var handler: MultiHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitMultiClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var observed = false;
    for (0..512) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!observed and coordinator.stats.submitted == 1) {
            var active: usize = 0;
            for (coordinator.app_layers) |layer| if (layer.active) {
                active += 1;
            };
            try std.testing.expectEqual(@as(usize, 2), active);
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expect(!std.meta.eql(submitted[0].surface, submitted[1].surface));
            const windows = try coordinator.desktop.sceneSnapshot(coordinator.scene_windows);
            const first = findLayer(coordinator.app_layers, windows[0].surface) orelse
                return error.MissingFirstLayer;
            const second = findLayer(coordinator.app_layers, windows[1].surface) orelse
                return error.MissingSecondLayer;
            try std.testing.expectEqual(first.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(second.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(@as(i32, 0), first.sample.?.destination.x);
            try std.testing.expectEqual(@as(u32, 2), first.sample.?.destination.width);
            try std.testing.expectEqual(@as(i32, 2), second.sample.?.destination.x);
            try std.testing.expectEqual(@as(u32, 1), second.sample.?.destination.width);
            observed = true;
        }
        if (observed and coordinator.stats.presented == two_toplevel_cycle_count and
            handler.buffer_releases == two_toplevel_cycle_count * 2 and
            handler.frame_done == two_toplevel_cycle_count * 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0) {
            try waitForEither(&root.ring, client_reactor.ring);
        }
    }
    try std.testing.expect(observed);
    try std.testing.expectEqual(@as(usize, two_toplevel_cycle_count * 2), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, two_toplevel_cycle_count), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, two_toplevel_cycle_count), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, two_toplevel_cycle_count * 2), handler.buffer_releases);
    try std.testing.expectEqual(@as(usize, two_toplevel_cycle_count * 2), handler.frame_done);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    const windows = try coordinator.desktop.sceneSnapshot(coordinator.scene_windows);
    try std.testing.expectEqual(windows[1].id, coordinator.desktop.focused().?);
    const pointer_device: ouro.input_backend.DeviceId = .{
        .slot = 0,
        .generation = 1,
        .seat_generation = 1,
    };
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .device_added = .{
        .device = pointer_device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } }));
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .pointer_motion = .{
        .device = pointer_device,
        .time_usec = 1,
        .dx = 0.25,
        .dy = 0,
    } }));
    try std.testing.expectEqual(@as(i32, 64), coordinator.seat_adapter.pointerState().point.x);
    const pointer_focus = coordinator.seat_adapter.pointerState().focus.?;
    const lock = try coordinator.pointer_constraints_adapter.state.create(
        .locked,
        .persistent,
        pointer_focus.surface,
        0,
        null,
    );
    try coordinator.pointer_constraints_adapter.updateFocus(
        pointer_focus.surface,
        .{
            .x = coordinator.seat_adapter.pointerState().point.x,
            .y = coordinator.seat_adapter.pointerState().point.y,
        },
    );
    const locked_point = coordinator.seat_adapter.pointerState().point;
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .pointer_motion = .{
        .device = pointer_device,
        .time_usec = 2,
        .dx = 1.5,
        .dy = 0.5,
    } }));
    try std.testing.expectEqual(locked_point, coordinator.seat_adapter.pointerState().point);
    try coordinator.pointer_constraints_adapter.state.destroy(lock);

    const constraint_region = [_]ouro.region.Operation{
        .{ .add = .{ .x = 0, .y = 0, .width = 1, .height = 2 } },
    };
    const confined = try coordinator.pointer_constraints_adapter.state.create(
        .confined,
        .persistent,
        pointer_focus.surface,
        0,
        &constraint_region,
    );
    try coordinator.pointer_constraints_adapter.updateFocus(
        pointer_focus.surface,
        .{
            .x = coordinator.seat_adapter.pointerState().point.x,
            .y = coordinator.seat_adapter.pointerState().point.y,
        },
    );
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .pointer_motion = .{
        .device = pointer_device,
        .time_usec = 3,
        .dx = 4,
        .dy = 0,
    } }));
    try std.testing.expectEqual(@as(i32, 255), coordinator.seat_adapter.pointerState().point.x);
    try coordinator.pointer_constraints_adapter.state.destroy(confined);
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .pointer_button = .{
        .device = pointer_device,
        .time_usec = 4,
        .button = 0x110,
        .pressed = true,
    } }));
    try std.testing.expectEqual(windows[0].id, coordinator.desktop.focused().?);

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitMultiClient(&client_reactor, &driver, &handler);
    var wayring_drained = false;
    for (0..256) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and client_progress.quiescent and coordinator.backendDrainComplete()) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(wayring_drained);
    try std.testing.expect(client_progress.quiescent);
    try std.testing.expect(coordinator.backendDrainComplete());

    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: layer surface adopts and presents an xdg popup" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-layer-popup-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 48;
    root_config.runtime.object_quota = 48;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
    config.surface.frame_callback_capacity = 2;
    config.surface.release_callback_capacity = 2;
    config.surface.content_update_capacity = 2;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_samples = 3;
    config.output.max_source_bytes = pixels.len * 2;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
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
        .{ .max_objects = 48, .max_client_ids = 47 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: LayerPopupHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitLayerPopupClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var observed = false;
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!observed and handler.layer_mapped and handler.popup_mapped and
            coordinator.stats.presented >= 1)
        {
            const layer_ids = try coordinator.layer_shell_adapter.ids(coordinator.layer_surface_ids);
            try std.testing.expectEqual(@as(usize, 1), layer_ids.len);
            const layer_state = try coordinator.layer_shell_adapter.state(layer_ids[0]);
            var popup_storage: [2]@TypeOf(coordinator.scene_windows[0]) = undefined;
            const popups = try coordinator.desktop.externalPopupSnapshot(
                layer_state.surface,
                &popup_storage,
            );
            try std.testing.expectEqual(@as(usize, 1), popups.len);
            try std.testing.expect(popups[0].visible and popups[0].content_ready);
            try std.testing.expectEqual(
                handler.popup_surface.?.id,
                (try coordinator.adapter.surfaceHandle(popups[0].surface)).id,
            );
            const submitted = coordinator.output.?.sample_storage[0..2];
            const layer = findLayer(coordinator.app_layers, layer_state.surface) orelse
                return error.MissingLayerSurface;
            const popup = findLayer(coordinator.app_layers, popups[0].surface) orelse
                return error.MissingPopupSurface;
            try std.testing.expectEqual(layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(popup.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(@as(usize, 0), (try coordinator.desktop.sceneSnapshot(coordinator.scene_windows)).len);
            observed = true;
        }
        if (observed and handler.releases == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(observed);
    try std.testing.expectEqual(@as(usize, 2), handler.releases);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitLayerPopupClient(&client_reactor, &driver, &handler);
    var drained = false;
    for (0..256) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and
            coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: synchronized subsurface publishes with parent and receives pointer focus" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-subsurface-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 32;
    root_config.runtime.actor.received_fd_budget = 2;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
    config.surface.frame_callback_capacity = 2;
    config.surface.release_callback_capacity = 2;
    config.surface.content_update_capacity = 2;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_samples = 3;
    config.output.max_source_bytes = pixels.len * 2;
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
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
    var handler: MultiHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .cycle_count = 1,
        .subsurface_mode = true,
    };
    try submitMultiClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var observed = false;
    for (0..512) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!observed and coordinator.stats.submitted == 1) {
            const root_id = try coordinator.adapter.surfaceId(handler.surfaces[0].?);
            const child_id = try coordinator.adapter.surfaceId(handler.surfaces[1].?);
            const root_layer = findLayer(coordinator.app_layers, root_id) orelse
                return error.MissingRootLayer;
            const child_layer = findLayer(coordinator.app_layers, child_id) orelse
                return error.MissingChildLayer;
            const submitted = coordinator.output.?.sample_storage[0..2];
            try std.testing.expectEqual(root_layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(child_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(@as(i32, 1), child_layer.sample.?.destination.x);
            try std.testing.expectEqual(@as(i32, 0), child_layer.sample.?.destination.y);
            observed = true;
        }
        if (observed and coordinator.stats.presented == 1 and
            handler.buffer_releases == 2 and handler.frame_done == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(observed);
    try std.testing.expect(handler.subcompositor != null);
    try std.testing.expect(handler.subsurfaces[1] != null);
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, 2), handler.buffer_releases);
    try std.testing.expectEqual(@as(usize, 2), handler.frame_done);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    const pointer_device: ouro.input_backend.DeviceId = .{
        .slot = 0,
        .generation = 1,
        .seat_generation = 1,
    };
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .device_added = .{
        .device = pointer_device,
        .info = .{ .capabilities = .{ .pointer = true } },
    } }));
    try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .pointer_motion = .{
        .device = pointer_device,
        .time_usec = 1,
        .dx = 1.25,
        .dy = 0.25,
    } }));
    const pointer = coordinator.seat_adapter.pointerState();
    try std.testing.expectEqual(
        try coordinator.adapter.surfaceId(handler.surfaces[1].?),
        pointer.focus.?.surface,
    );
    try std.testing.expectEqual(@as(i32, 64), pointer.point.x);
    try std.testing.expectEqual(@as(i32, 64), pointer.point.y);

    try wayring.client.sendRequest(
        protocol.wl_subsurface,
        &client.objects,
        &actor.transmit,
        handler.subsurfaces[1].?,
        .{ .destroy = .{} },
    );
    handler.subsurfaces[1] = null;
    try submitMultiClient(&client_reactor, &driver, &handler);
    for (0..256) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.stats.presented == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, 0), coordinator.removed_layer_len);
    try std.testing.expect(coordinator.seat_adapter.pointerState().focus == null);
    const root_id = try coordinator.adapter.surfaceId(handler.surfaces[0].?);
    const child_id = try coordinator.adapter.surfaceId(handler.surfaces[1].?);
    var scene_order: [2]ouro.core_surface.Adapter(protocol).SurfaceId = undefined;
    try std.testing.expectError(
        error.NotSubsurface,
        coordinator.subcompositor_adapter.sceneOrder(root_id, &scene_order),
    );
    try std.testing.expectError(
        error.NotSubsurface,
        coordinator.subcompositor_adapter.placement(child_id),
    );

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitMultiClient(&client_reactor, &driver, &handler);
    var wayring_drained = false;
    for (0..256) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and client_progress.quiescent and coordinator.backendDrainComplete()) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(wayring_drained);
    try std.testing.expect(client_progress.quiescent);
    try std.testing.expect(coordinator.backendDrainComplete());

    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: one client disconnect does not interrupt another client" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-two-clients-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.reactor.receive_buffer_size = 8192;
    root_config.reactor.receive_buffer_count = 8;
    root_config.reactor.receive_control_capacity = 512;
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 32;
    root_config.runtime.registry_capacity = 2;
    root_config.runtime.actor.received_fd_budget = 2;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 2),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
    config.surface.frame_callback_capacity = 2;
    config.surface.content_update_capacity = 3;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_samples = 3;
    config.output.max_source_bytes = pixels.len * 2;
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
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

    var first_reactor: wayring.io_uring.Reactor = undefined;
    try first_reactor.initOwned(
        allocator,
        .{ .entries = 16, .flags = 0 },
        physical_fixture.clientReactorConfig(),
    );
    var first = try ClientConnection.attach(
        allocator,
        &first_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 2, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    const first_actor = try first.actor();
    var first_driver = ClientDriver.init(&first);
    const first_registry = try ClientCore.getRegistry(
        &first.objects,
        &first_actor.transmit,
        null,
    );
    var first_handler: MultiHandler = .{
        .objects = &first.objects,
        .queue = &first_actor.transmit,
        .registry = first_registry,
        .surface_count = 1,
        .cycle_count = 2,
    };
    try submitMultiClient(&first_reactor, &first_driver, &first_handler);

    var second_reactor: wayring.io_uring.Reactor = undefined;
    try second_reactor.initOwned(
        allocator,
        .{ .entries = 16, .flags = 0 },
        physical_fixture.clientReactorConfig(),
    );
    var second = try ClientConnection.attach(
        allocator,
        &second_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 2, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    const second_actor = try second.actor();
    var second_driver = ClientDriver.init(&second);
    const second_registry = try ClientCore.getRegistry(
        &second.objects,
        &second_actor.transmit,
        null,
    );
    var second_handler: MultiHandler = .{
        .objects = &second.objects,
        .queue = &second_actor.transmit,
        .registry = second_registry,
        .surface_count = 1,
        .cycle_count = 6,
    };
    try submitMultiClient(&second_reactor, &second_driver, &second_handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var first_progress: ClientDriver.Progress = .{};
    var second_progress: ClientDriver.Progress = .{};
    for (0..256) |_| {
        first_progress = try drainMultiClient(&first_reactor, &first_driver, &first_handler);
        second_progress = try drainMultiClient(&second_reactor, &second_driver, &second_handler);
        _ = try loop.turn(coordinator);
        if (first_handler.frame_done == 2 and first_handler.buffer_releases == 2 and
            second_handler.frame_done >= 2 and second_handler.buffer_releases >= 2) break;
        if (root.ring.cq_ready() == 0 and first_reactor.ring.cq_ready() == 0 and
            second_reactor.ring.cq_ready() == 0)
            try waitForAny(&root.ring, first_reactor.ring, second_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.client_count);
    try std.testing.expectEqual(@as(usize, 2), first_handler.frame_done);
    try std.testing.expectEqual(@as(usize, 2), first_handler.buffer_releases);

    _ = try first.prepareClose();
    try submitMultiClient(&first_reactor, &first_driver, &first_handler);
    for (0..32) |_| {
        first_progress = try drainMultiClient(&first_reactor, &first_driver, &first_handler);
        if (first_progress.quiescent) break;
        if (first_reactor.ring.cq_ready() == 0) try waitServer(first_reactor.ring);
    }
    try std.testing.expect(first_progress.quiescent);
    try first.deinit(allocator);
    first_reactor.deinit(allocator);

    for (0..256) |_| {
        second_progress = try drainMultiClient(&second_reactor, &second_driver, &second_handler);
        _ = try loop.turn(coordinator);
        if (coordinator.client_count == 1 and second_handler.frame_done == 6 and
            second_handler.buffer_releases == 6) break;
        if (root.ring.cq_ready() == 0 and second_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, second_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), coordinator.client_count);
    try std.testing.expect(!coordinator.stopping);
    try std.testing.expectEqual(@as(usize, 6), second_handler.frame_done);
    try std.testing.expectEqual(@as(usize, 6), second_handler.buffer_releases);
    try std.testing.expectEqual(@as(usize, 0), first_handler.event_failures);
    try std.testing.expectEqual(@as(usize, 0), second_handler.event_failures);

    _ = try second.prepareClose();
    try submitMultiClient(&second_reactor, &second_driver, &second_handler);
    for (0..32) |_| {
        second_progress = try drainMultiClient(&second_reactor, &second_driver, &second_handler);
        if (second_progress.quiescent) break;
        if (second_reactor.ring.cq_ready() == 0) try waitServer(second_reactor.ring);
    }
    try std.testing.expect(second_progress.quiescent);
    try second.deinit(allocator);
    second_reactor.deinit(allocator);
    try physical_fixture.drainServer(root, coordinator, &loop);

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

const MultiHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    subcompositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    surfaces: [2]?wayring.objects.Handle = .{ null, null },
    subsurfaces: [2]?wayring.objects.Handle = .{ null, null },
    xdg_surfaces: [2]?wayring.objects.Handle = .{ null, null },
    toplevels: [2]?wayring.objects.Handle = .{ null, null },
    buffers: [2]?wayring.objects.Handle = .{ null, null },
    callbacks: [2]?wayring.objects.Handle = .{ null, null },
    mapped: [2]bool = .{ false, false },
    shell_created: bool = false,
    buffer_releases: usize = 0,
    frame_done: usize = 0,
    cycles_started: [2]usize = .{ 0, 0 },
    event_failures: usize = 0,
    surface_count: usize = 2,
    cycle_count: usize = two_toplevel_cycle_count,
    subsurface_mode: bool = false,

    pub fn eventError(
        self: *MultiHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *MultiHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| try self.bindGlobal(value),
                .global_remove => {},
            }
            try self.maybeCreateShells();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_toplevel.info) {
            _ = try protocol.xdg_toplevel.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_surface.info) {
            const index = self.indexFor(self.xdg_surfaces, message.header.object_id) orelse
                return error.UnknownXdgSurface;
            switch (try protocol.xdg_surface.decodeEvent(message, fds)) {
                .configure => |value| {
                    try protocol.xdg_surface.encodeRequest(self.queue, self.xdg_surfaces[index].?.id, .{
                        .ack_configure = .{ .serial = value.serial },
                    });
                    if (!self.mapped[index]) {
                        if (self.subsurface_mode) try self.mapSurface(1);
                        try self.mapSurface(index);
                    } else {
                        try protocol.wl_surface.encodeRequest(
                            self.queue,
                            self.surfaces[index].?.id,
                            .{ .commit = .{} },
                        );
                    }
                },
            }
        } else if (target.object.interface == &protocol.wl_buffer.info) {
            const index = self.indexFor(self.buffers, message.header.object_id) orelse
                return error.UnknownBuffer;
            switch (try protocol.wl_buffer.decodeEvent(message, fds)) {
                .release => {
                    self.buffer_releases += 1;
                    try wayring.client.sendRequest(
                        protocol.wl_buffer,
                        self.objects,
                        self.queue,
                        self.buffers[index].?,
                        .{ .destroy = .{} },
                    );
                    self.buffers[index] = null;
                    try self.maybeStartCycle(index);
                },
            }
        } else if (target.object.interface == &ClientCore.Callback.info) {
            const index = self.indexFor(self.callbacks, message.header.object_id) orelse
                return error.UnknownCallback;
            switch (try ClientCore.decodeCallbackEvent(
                self.objects,
                self.callbacks[index].?,
                message,
                fds,
            )) {
                .done => {
                    self.frame_done += 1;
                    self.callbacks[index] = null;
                    try self.maybeStartCycle(index);
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

    fn bindGlobal(self: *MultiHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_subcompositor.info.name))
            self.subcompositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_subcompositor.info, @min(value.version, 1), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
    }

    fn maybeCreateShells(self: *MultiHandler) !void {
        if (self.shell_created or self.compositor == null or self.shm == null or self.wm_base == null)
            return;
        if (self.subsurface_mode and self.subcompositor == null) return;
        for (0..self.surface_count) |index| {
            self.surfaces[index] = (try protocol.wl_compositor.construct_create_surface(
                self.objects,
                self.queue,
                self.compositor.?,
                .{},
            )).id;
            if (self.subsurface_mode and index != 0) continue;
            self.xdg_surfaces[index] = (try protocol.xdg_wm_base.construct_get_xdg_surface(
                self.objects,
                self.queue,
                self.wm_base.?,
                .{ .surface = self.surfaces[index].?.id },
            )).id;
            self.toplevels[index] = (try protocol.xdg_surface.construct_get_toplevel(
                self.objects,
                self.queue,
                self.xdg_surfaces[index].?,
                .{},
            )).id;
            try protocol.wl_surface.encodeRequest(
                self.queue,
                self.surfaces[index].?.id,
                .{ .commit = .{} },
            );
        }
        if (self.subsurface_mode) {
            self.subsurfaces[1] = (try protocol.wl_subcompositor.construct_get_subsurface(
                self.objects,
                self.queue,
                self.subcompositor.?,
                .{
                    .surface = self.surfaces[1].?.id,
                    .parent = self.surfaces[0].?.id,
                },
            )).id;
            try protocol.wl_subsurface.encodeRequest(
                self.queue,
                self.subsurfaces[1].?.id,
                .{ .set_position = .{ .x = 1, .y = 0 } },
            );
            try protocol.wl_subsurface.encodeRequest(
                self.queue,
                self.subsurfaces[1].?.id,
                .{ .place_above = .{ .sibling = self.surfaces[0].?.id } },
            );
        }
        self.shell_created = true;
    }

    fn mapSurface(self: *MultiHandler, index: usize) !void {
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        self.buffers[index] = (try protocol.wl_shm_pool.construct_create_buffer(
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
        self.callbacks[index] = (try protocol.wl_surface.construct_frame(
            self.objects,
            self.queue,
            self.surfaces[index].?,
            .{},
        )).callback;
        try protocol.wl_surface.encodeRequest(self.queue, self.surfaces[index].?.id, .{
            .attach = .{ .buffer = self.buffers[index].?.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.surfaces[index].?.id, .{
            .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        });
        try protocol.wl_surface.encodeRequest(
            self.queue,
            self.surfaces[index].?.id,
            .{ .commit = .{} },
        );
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        self.mapped[index] = true;
        self.cycles_started[index] += 1;
    }

    fn maybeStartCycle(self: *MultiHandler, index: usize) !void {
        if (self.cycles_started[index] >= self.cycle_count or
            self.buffers[index] != null or self.callbacks[index] != null) return;
        try self.mapSurface(index);
    }

    fn indexFor(
        _: *const MultiHandler,
        handles: [2]?wayring.objects.Handle,
        object_id: u32,
    ) ?usize {
        for (handles, 0..) |handle, index|
            if (handle != null and handle.?.id == object_id) return index;
        return null;
    }
};

const LayerPopupHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    layer_shell: ?wayring.objects.Handle = null,
    layer_surface: ?wayring.objects.Handle = null,
    layer_wl_surface: ?wayring.objects.Handle = null,
    popup_surface: ?wayring.objects.Handle = null,
    popup_xdg_surface: ?wayring.objects.Handle = null,
    popup: ?wayring.objects.Handle = null,
    buffers: [2]?wayring.objects.Handle = .{ null, null },
    created: bool = false,
    layer_mapped: bool = false,
    popup_mapped: bool = false,
    releases: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *LayerPopupHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *LayerPopupHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| try self.bindGlobal(value),
                .global_remove => {},
            }
            try self.maybeCreate();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.zwlr_layer_surface_v1.info) {
            switch (try protocol.zwlr_layer_surface_v1.decodeEvent(message, fds)) {
                .configure => |value| {
                    try protocol.zwlr_layer_surface_v1.encodeRequest(
                        self.queue,
                        self.layer_surface.?.id,
                        .{ .ack_configure = .{ .serial = value.serial } },
                    );
                    if (!self.layer_mapped) {
                        try self.mapSurface(0, self.layer_wl_surface.?);
                        try self.createPopup();
                        self.layer_mapped = true;
                    }
                },
                .closed => return error.LayerClosed,
            }
        } else if (target.object.interface == &protocol.xdg_popup.info) {
            _ = try protocol.xdg_popup.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_surface.info) {
            switch (try protocol.xdg_surface.decodeEvent(message, fds)) {
                .configure => |value| {
                    try protocol.xdg_surface.encodeRequest(
                        self.queue,
                        self.popup_xdg_surface.?.id,
                        .{ .ack_configure = .{ .serial = value.serial } },
                    );
                    if (!self.popup_mapped) {
                        try self.mapSurface(1, self.popup_surface.?);
                        self.popup_mapped = true;
                    }
                },
            }
        } else if (target.object.interface == &protocol.wl_buffer.info) {
            const index: usize = if (self.buffers[0] != null and
                self.buffers[0].?.id == message.header.object_id) 0 else 1;
            switch (try protocol.wl_buffer.decodeEvent(message, fds)) {
                .release => {
                    self.releases += 1;
                    try wayring.client.sendRequest(
                        protocol.wl_buffer,
                        self.objects,
                        self.queue,
                        self.buffers[index].?,
                        .{ .destroy = .{} },
                    );
                    self.buffers[index] = null;
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

    fn bindGlobal(self: *LayerPopupHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.zwlr_layer_shell_v1.info.name))
            self.layer_shell = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwlr_layer_shell_v1.info, @min(value.version, 5), null);
    }

    fn maybeCreate(self: *LayerPopupHandler) !void {
        if (self.created or self.compositor == null or self.shm == null or
            self.wm_base == null or self.layer_shell == null) return;
        self.layer_wl_surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.layer_surface = (try protocol.zwlr_layer_shell_v1.construct_get_layer_surface(
            self.objects,
            self.queue,
            self.layer_shell.?,
            .{
                .surface = self.layer_wl_surface.?.id,
                .output = null,
                .layer = .top,
                .namespace = "ouro-test",
            },
        )).id;
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .set_size = .{ .width = 3, .height = 2 },
        });
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .set_anchor = .{ .anchor = .{ .value = 5 } },
        });

        try protocol.wl_surface.encodeRequest(self.queue, self.layer_wl_surface.?.id, .{ .commit = .{} });
        self.created = true;
    }

    fn createPopup(self: *LayerPopupHandler) !void {
        self.popup_surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.popup_xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
            self.objects,
            self.queue,
            self.wm_base.?,
            .{ .surface = self.popup_surface.?.id },
        )).id;
        const positioner = try protocol.xdg_wm_base.construct_create_positioner(
            self.objects,
            self.queue,
            self.wm_base.?,
            .{},
        );
        try protocol.xdg_positioner.encodeRequest(self.queue, positioner.id.id, .{
            .set_size = .{ .width = 1, .height = 1 },
        });
        try protocol.xdg_positioner.encodeRequest(self.queue, positioner.id.id, .{
            .set_anchor_rect = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        });
        self.popup = (try protocol.xdg_surface.construct_get_popup(
            self.objects,
            self.queue,
            self.popup_xdg_surface.?,
            .{ .parent = null, .positioner = positioner.id.id },
        )).id;
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .get_popup = .{ .popup = self.popup.?.id },
        });
    }

    fn mapSurface(
        self: *LayerPopupHandler,
        index: usize,
        surface: wayring.objects.Handle,
    ) !void {
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        self.buffers[index] = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 16,
                .width = if (index == 0) 3 else 1,
                .height = if (index == 0) 2 else 1,
                .stride = 16,
                .format = .argb8888,
            },
        )).id;
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .attach = .{ .buffer = self.buffers[index].?.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{ .commit = .{} });
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
    }
};

const Handler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    data_device_manager: ?wayring.objects.Handle = null,
    data_device: ?wayring.objects.Handle = null,
    data_source: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    idle_notifier: ?wayring.objects.Handle = null,
    idle_inhibit_manager: ?wayring.objects.Handle = null,
    idle_standard: ?wayring.objects.Handle = null,
    idle_input: ?wayring.objects.Handle = null,
    idle_inhibitor: ?wayring.objects.Handle = null,
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
    pointer_axis_source: usize = 0,
    pointer_axis: usize = 0,
    pointer_axis_value120: usize = 0,
    pointer_frame: usize = 0,
    pointer_axis_fixed: i32 = 0,
    pointer_axis_value120_value: i32 = 0,
    drag_cancelled: usize = 0,
    drag_data_offer: usize = 0,
    drag_mime_offer: usize = 0,
    drag_source_actions: usize = 0,
    drag_enter: usize = 0,
    drag_leave: usize = 0,
    keyboard_enter: usize = 0,
    keyboard_key: usize = 0,
    buffer_release: usize = 0,
    completion_order: usize = 0,
    buffer_release_order: usize = 0,
    frame_done_order: usize = 0,
    output_geometry: bool = false,
    output_physical_width: i32 = 0,
    output_physical_height: i32 = 0,
    output_mode: bool = false,
    output_scale: bool = false,
    output_name: bool = false,
    output_description: bool = false,
    output_done: usize = 0,
    output_enter: usize = 0,
    output_leave: usize = 0,
    output_released: bool = false,
    output_deleted: bool = false,
    event_failures: usize = 0,
    standard_idled: usize = 0,
    standard_resumed: usize = 0,
    input_idled: usize = 0,
    input_resumed: usize = 0,

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
            try self.maybeCreateDataDevice();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .geometry => |value| {
                    try std.testing.expectEqual(@as(i32, 0), value.x);
                    try std.testing.expectEqual(@as(i32, 0), value.y);
                    try std.testing.expect(value.physical_width == 0 or value.physical_width == 1);
                    try std.testing.expect(value.physical_height == 0 or value.physical_height == 1);
                    try std.testing.expectEqual(protocol.wl_output.subpixel.unknown, value.subpixel);
                    try std.testing.expectEqualStrings("Ouro", value.make);
                    try std.testing.expectEqualStrings("Unknown", value.model);
                    try std.testing.expectEqual(protocol.wl_output.transform.normal, value.transform);
                    self.output_physical_width = value.physical_width;
                    self.output_physical_height = value.physical_height;
                    self.output_geometry = true;
                },
                .mode => |value| {
                    try std.testing.expect(value.flags.contains(protocol.wl_output.mode.current));
                    try std.testing.expect(value.flags.contains(protocol.wl_output.mode.preferred));
                    try std.testing.expectEqual(@as(i32, 3), value.width);
                    try std.testing.expectEqual(@as(i32, 2), value.height);
                    try std.testing.expectEqual(@as(i32, 60_000), value.refresh);
                    self.output_mode = true;
                },
                .scale => |value| {
                    try std.testing.expectEqual(@as(i32, 1), value.factor);
                    self.output_scale = true;
                },
                .name => |value| {
                    try std.testing.expectEqualStrings("ouro-0", value.name);
                    self.output_name = true;
                },
                .description => |value| {
                    try std.testing.expectEqualStrings("Ouro output", value.description);
                    self.output_description = true;
                },
                .done => {
                    self.output_done += 1;
                },
            }
        } else if (target.object.interface == &protocol.wl_surface.info) {
            switch (try protocol.wl_surface.decodeEvent(message, fds)) {
                .enter => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.output_enter += 1;
                    if (self.output_enter == 4 and !self.output_released) {
                        try wayring.client.sendRequest(
                            protocol.wl_output,
                            self.objects,
                            self.queue,
                            self.output.?,
                            .{ .release = .{} },
                        );
                        self.output_released = true;
                    }
                },
                .leave => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.output_leave += 1;
                },
                else => {},
            }
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
                    if (value.state.value == protocol.wl_pointer.button_state.pressed.value and
                        self.drag_cancelled == 0)
                    {
                        try protocol.wl_data_device.encodeRequest(self.queue, self.data_device.?.id, .{
                            .start_drag = .{
                                .source = self.data_source.?.id,
                                .origin = self.surface.?.id,
                                .icon = null,
                                .serial = value.serial +% 1,
                            },
                        });
                        try protocol.wl_data_device.encodeRequest(self.queue, self.data_device.?.id, .{
                            .start_drag = .{
                                .source = self.data_source.?.id,
                                .origin = self.surface.?.id,
                                .icon = null,
                                .serial = value.serial,
                            },
                        });
                    }
                },
                .axis_source => |value| {
                    try std.testing.expectEqual(protocol.wl_pointer.axis_source.wheel.value, value.axis_source.value);
                    self.pointer_axis_source += 1;
                },
                .axis => |value| {
                    try std.testing.expectEqual(protocol.wl_pointer.axis.vertical_scroll.value, value.axis.value);
                    try std.testing.expectEqual(@as(u32, 3), value.time);
                    self.pointer_axis += 1;
                    self.pointer_axis_fixed = value.value;
                },
                .axis_value120 => |value| {
                    try std.testing.expectEqual(protocol.wl_pointer.axis.vertical_scroll.value, value.axis.value);
                    self.pointer_axis_value120 += 1;
                    self.pointer_axis_value120_value = value.value120;
                },
                .frame => self.pointer_frame += 1,
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
        } else if (target.object.interface == &protocol.wl_data_device.info) {
            switch (try protocol.wl_data_device.decodeEvent(message, fds)) {
                .data_offer => |value| {
                    _ = try protocol.wl_data_device.admit_event_data_offer(
                        self.objects,
                        self.data_device.?,
                        value,
                        .{},
                    );
                    self.drag_data_offer += 1;
                },
                .enter => |value| {
                    try std.testing.expectEqual(self.surface.?.id, value.surface);
                    try std.testing.expect(value.id != null);
                    self.drag_enter += 1;
                },
                .leave => self.drag_leave += 1,
                else => {},
            }
        } else if (target.object.interface == &protocol.wl_data_offer.info) {
            switch (try protocol.wl_data_offer.decodeEvent(message, fds)) {
                .offer => |value| {
                    try std.testing.expectEqualStrings("text/plain", value.mime_type);
                    self.drag_mime_offer += 1;
                },
                .source_actions => |value| {
                    const expected = protocol.wl_data_device_manager.dnd_action.copy.value |
                        protocol.wl_data_device_manager.dnd_action.move.value;
                    try std.testing.expectEqual(expected, value.source_actions.value);
                    self.drag_source_actions += 1;
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.wl_data_source.info) {
            switch (try protocol.wl_data_source.decodeEvent(message, fds)) {
                .cancelled => self.drag_cancelled += 1,
                else => {},
            }
        } else if (target.object.interface == &protocol.ext_idle_notification_v1.info) {
            const notification_event = try protocol.ext_idle_notification_v1.decodeEvent(message, fds);
            const standard = self.idle_standard != null and message.header.object_id == self.idle_standard.?.id;
            switch (notification_event) {
                .idled => if (standard) {
                    self.standard_idled += 1;
                } else {
                    self.input_idled += 1;
                },
                .resumed => if (standard) {
                    self.standard_resumed += 1;
                } else {
                    self.input_resumed += 1;
                },
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
                .delete_id => |value| {
                    if (self.output != null and value.id == self.output.?.id)
                        self.output_deleted = true;
                },
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
        if (std.mem.eql(u8, value.interface, protocol.wl_data_device_manager.info.name))
            self.data_device_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_data_device_manager.info, @min(value.version, 3), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name))
            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
        if (std.mem.eql(u8, value.interface, protocol.ext_idle_notifier_v1.info.name))
            self.idle_notifier = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_idle_notifier_v1.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.zwp_idle_inhibit_manager_v1.info.name))
            self.idle_inhibit_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwp_idle_inhibit_manager_v1.info, @min(value.version, 1), null);
    }

    fn maybeCreateDataDevice(self: *Handler) !void {
        if (self.data_device != null or self.data_device_manager == null or self.seat == null) return;
        self.data_source = (try protocol.wl_data_device_manager.construct_create_data_source(
            self.objects,
            self.queue,
            self.data_device_manager.?,
            .{},
        )).id;
        try protocol.wl_data_source.encodeRequest(self.queue, self.data_source.?.id, .{
            .offer = .{ .mime_type = "text/plain" },
        });
        try protocol.wl_data_source.encodeRequest(self.queue, self.data_source.?.id, .{
            .set_actions = .{ .dnd_actions = .fromWire(
                protocol.wl_data_device_manager.dnd_action.copy.value |
                    protocol.wl_data_device_manager.dnd_action.move.value,
            ) },
        });
        self.data_device = (try protocol.wl_data_device_manager.construct_get_data_device(
            self.objects,
            self.queue,
            self.data_device_manager.?,
            .{ .seat = self.seat.?.id },
        )).id;
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
        try protocol.xdg_surface.encodeRequest(self.queue, self.xdg_surface.?.id, .{
            .set_window_geometry = .{ .x = 1, .y = 0, .width = 2, .height = 2 },
        });
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

    fn createIdleNotifications(self: *Handler) !void {
        self.idle_standard = (try protocol.ext_idle_notifier_v1.construct_get_idle_notification(
            self.objects,
            self.queue,
            self.idle_notifier.?,
            .{ .timeout = 1, .seat = self.seat.?.id },
        )).id;
        self.idle_input = (try protocol.ext_idle_notifier_v1.construct_get_input_idle_notification(
            self.objects,
            self.queue,
            self.idle_notifier.?,
            .{ .timeout = 1, .seat = self.seat.?.id },
        )).id;
    }

    fn createIdleInhibitor(self: *Handler) !void {
        self.idle_inhibitor = (try protocol.zwp_idle_inhibit_manager_v1.construct_create_inhibitor(
            self.objects,
            self.queue,
            self.idle_inhibit_manager.?,
            .{ .surface = self.surface.?.id },
        )).id;
    }

    fn destroyIdleInhibitor(self: *Handler) !void {
        try wayring.client.sendRequest(
            protocol.zwp_idle_inhibitor_v1,
            self.objects,
            self.queue,
            self.idle_inhibitor.?,
            .{ .destroy = .{} },
        );
        self.idle_inhibitor = null;
    }
};

fn findLayer(layers: anytype, id: anytype) ?@TypeOf(&layers[0]) {
    for (layers) |*layer|
        if (layer.id != null and std.meta.eql(layer.id.?, id)) return layer;
    return null;
}

fn drainMultiClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *MultiHandler,
) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0)
        0
    else
        try reactor.ring.copy_cqes(&completions, 0);
    var progress = try driver.dispatch(completions[0..count], handler);
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

fn submitMultiClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *MultiHandler,
) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}

fn drainLayerPopupClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *LayerPopupHandler,
) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0)
        0
    else
        try reactor.ring.copy_cqes(&completions, 0);
    var progress = try driver.dispatch(completions[0..count], handler);
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

fn submitLayerPopupClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *LayerPopupHandler,
) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}

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

fn waitForAny(first: *linux.IoUring, second: *linux.IoUring, third: *linux.IoUring) !void {
    for (0..10_000_000) |_| {
        if (first.cq_ready() != 0 or second.cq_ready() != 0 or third.cq_ready() != 0)
            return;
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
