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

test "configuration installs before physical startup claims an output" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/ouro-config-before-start-{d}.sock",
        .{linux.getpid()},
    );
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        compositorConfig(),
    );
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
        coordinatorConfig(),
    );
    try std.testing.expect(!coordinator.processing_virtual_pointer);
    try std.testing.expect(!coordinator.shell_maintenance_pending);
    try std.testing.expect(!coordinator.pointer_reconcile_pending);
    var reference = try ouro.config.defaultSnapshot(allocator);
    defer reference.deinit();
    var engine = try Coordinator.EngineSettings.init(
        allocator,
        reference.input_rules,
        reference.output_rules,
    );
    var bindings = try Coordinator.Bindings.snapshotFromReferenceConfig(
        allocator,
        &reference,
    );
    var policy: Coordinator.PolicySnapshot = .{};

    try coordinator.installConfig(&engine, &bindings, &policy);
    try coordinator.requestStop();
    try std.testing.expect(coordinator.backendDrainComplete());
    try coordinator.destroy();
    try root.deinit();
}

test "generated ordinary SHM traverses the physical coordinator exactly once and drains" {
    try runVertical(.session_disable, .shm);
}

test "client disconnect before render deadline abandons pending presentation" {
    try runVertical(.client_disconnect, .shm);
}

test "generated DMA-BUF traverses GBM import and the physical coordinator" {
    try runVertical(.client_disconnect, .dmabuf);
}

test "generated single pixel buffer scales through the physical coordinator" {
    try runVertical(.client_disconnect, .single_pixel);
}

test "generated alpha modifier reaches the physical render sample" {
    try runVertical(.client_disconnect, .alpha_shm);
}

test "physical coordinator keeps serving until its final client disconnects" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-clients-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root_config = compositorConfig();
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 2),
        root_config,
    );
    const coordinator_config = coordinatorConfig();
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platforms(),
        coordinator_config,
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
    _ = try loop.turn(coordinator);

    const first = try wayring.unix_socket.connect(path);
    var first_open = true;
    defer if (first_open) {
        _ = linux.close(first);
    };
    const second = try wayring.unix_socket.connect(path);
    var second_open = true;
    defer if (second_open) {
        _ = linux.close(second);
    };
    for (0..32) |_| {
        if (coordinator.client_count == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.client_count);
    const first_peer = coordinator.peer.?;

    _ = linux.close(first);
    first_open = false;
    for (0..32) |_| {
        if (coordinator.client_count == 1) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expectEqual(@as(usize, 1), coordinator.client_count);
    try std.testing.expect(!coordinator.stopping);
    try std.testing.expect(!std.meta.eql(first_peer, coordinator.peer.?));

    _ = linux.close(second);
    second_open = false;
    for (0..32) |_| {
        if (coordinator.client_count == 0) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expectEqual(@as(usize, 0), coordinator.client_count);
    try std.testing.expect(coordinator.stopping);
    try drainServer(root, coordinator, &loop);

    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical DRM lease resolver grants the independent secondary tuple" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-lease-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..32) |_| {
        if (coordinator.primaryKmsOutput() != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
        _ = try loop.turn(coordinator);
    }
    const handle = coordinator.manager.currentHandle().?;
    const candidates = try coordinator.manager.scanoutCandidates(handle);
    try std.testing.expectEqual(@as(usize, 1), candidates.len);
    const lease_candidates = try coordinator.manager.leaseCandidates(handle);
    try std.testing.expectEqual(@as(usize, 1), lease_candidates.len);
    const grant = (try coordinator.grantDrmLease(.physical, &.{.{
        .topology_generation = handle.generation,
        .candidate = lease_candidates[0],
    }})).?;
    defer _ = linux.close(grant.fd);
    try std.testing.expectEqualSlices(u32, &.{ 11, 31, 41 }, fixture.lease_objects[0..fixture.lease_object_count]);
    try std.testing.expect(coordinator.revokeDrmLease(grant.token));
    try std.testing.expectEqual(@as(usize, 1), fixture.lease_revoke_count);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator activates and drains every desktop connector" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-plural-output-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.physical_output_count);
    try std.testing.expectEqual(@as(u32, 10), coordinator.physical_outputs[0].connector_id);
    try std.testing.expectEqual(@as(u32, 11), coordinator.physical_outputs[1].connector_id);
    try std.testing.expect(coordinator.physical_outputs[0].kms_output != null);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    try std.testing.expect(!std.meta.eql(
        coordinator.physical_outputs[0].kms_output.?.outputId(),
        coordinator.physical_outputs[1].kms_output.?.outputId(),
    ));
    const secondary = try coordinator.output_adapter.logicalSnapshot(
        coordinator.physical_outputs[1].protocol_output,
    );
    try std.testing.expectEqual(@as(i32, 3), secondary.x);
    try std.testing.expectEqual(@as(?i32, 3), secondary.width);
    const global_bounds: @TypeOf(coordinator.desktop.workArea()) =
        .{ .x = 0, .y = 0, .width = 6, .height = 2 };
    try std.testing.expectEqual(global_bounds, coordinator.desktop.workArea());
    try std.testing.expectEqual(global_bounds, coordinator.interaction.bounds);
    try std.testing.expect((try coordinator.output_management_adapter.lifecycle.currentHead(
        coordinator.physical_outputs[1].management_head,
    )).enabled);
    try coordinator.output_adapter.publishScale(
        coordinator.physical_outputs[1].protocol_output,
        240,
    );
    var secondary_head = try coordinator.output_management_adapter.lifecycle.currentHead(
        coordinator.physical_outputs[1].management_head,
    );
    secondary_head.scale_120 = 240;
    _ = try coordinator.output_management_adapter.publishHead(
        coordinator.physical_outputs[1].management_head,
        secondary_head,
    );
    try std.testing.expectEqual(@as(usize, 0), (try coordinator.manager.leaseCandidates(
        coordinator.manager.currentHandle().?,
    )).len);

    try fixture.signalSession(.disable);
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        var active = false;
        for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
            active = active or physical.kms_output != null;
        if (!active and coordinator.session.state == .disabled) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
        try std.testing.expect(physical.kms_output == null);
    for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical| {
        try std.testing.expect(!(try coordinator.output_management_adapter.lifecycle.currentHead(
            physical.management_head,
        )).enabled);
        try std.testing.expect(!coordinator.output_adapter.outputs[
            physical.protocol_output.index
        ].available);
    }

    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expectEqual(@as(usize, 2), coordinator.physical_output_count);
    try std.testing.expect(coordinator.physical_outputs[0].kms_output != null);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
        try std.testing.expect(coordinator.output_adapter.outputs[
            physical.protocol_output.index
        ].available);
    try std.testing.expectEqual(
        @as(u32, 240),
        (try coordinator.output_management_adapter.lifecycle.currentHead(
            coordinator.physical_outputs[1].management_head,
        )).scale_120,
    );
    try std.testing.expectEqual(
        @as(u32, 240),
        coordinator.output_adapter.outputs[
            coordinator.physical_outputs[1].protocol_output.index
        ].scale_120,
    );

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator waits for peer output after a retired latching attempt" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-fifo-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 1 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const primary = &coordinator.physical_outputs[0];
    const secondary = &coordinator.physical_outputs[1];
    try std.testing.expect(primary.kms_output != null);
    try std.testing.expect(secondary.kms_output != null);

    // Secondary outputs schedule an initial blank scanout so a connector with
    // no mapped clients becomes visibly active. Let that startup transaction
    // settle before testing the independent latching failure below.
    for (0..64) |_| {
        if (physicalOutputsSettled(coordinator)) break;
        _ = try loop.turn(coordinator);
        if (physicalOutputsSettled(coordinator)) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expectEqual(secondary.damage_requested, secondary.damage_applied);

    fixture.fail_page_flip_crtc = 30;
    try primary.kms_output.?.request(.damage, 1);
    primary.damage_requested +%= 1;
    try coordinator.prepare();
    _ = try root.ring.submit();
    try secondary.kms_output.?.request(.damage, 1);
    secondary.damage_requested +%= 1;

    while (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    _ = try loop.turn(coordinator);
    try std.testing.expectEqual(primary.damage_requested, primary.damage_applied);
    try std.testing.expect(secondary.damage_applied != secondary.damage_requested);

    for (0..64) |_| {
        _ = try loop.turn(coordinator);
        if (secondary.damage_applied == secondary.damage_requested) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expectEqual(secondary.damage_requested, secondary.damage_applied);
    for (0..64) |_| {
        var in_flight = false;
        for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
            in_flight = in_flight or (physical.kms_output != null and
                physical.kms_output.?.in_flight_frame != null);
        if (!in_flight) break;
        _ = try loop.turn(coordinator);
        _ = linux.sched_yield();
    }

    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator retires a disconnected secondary output" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-remove-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const protocol_output = coordinator.physical_outputs[1].protocol_output;
    const management_head = coordinator.physical_outputs[1].management_head;
    const physical_id = coordinator.physical_outputs[1].id;
    fixture.second_desktop = false;
    try fixture.signalHotplug();
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.physical_outputs[1].connected and
            !coordinator.physical_outputs[1].removing) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(!coordinator.physical_outputs[1].connected);
    try std.testing.expect(!coordinator.physical_outputs[1].removing);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output == null);
    try std.testing.expect(coordinator.physical_outputs[1].claim == null);
    try std.testing.expect(!(try coordinator.output_adapter.outputPublished(protocol_output)));
    try std.testing.expectError(
        error.InvalidHead,
        coordinator.output_management_adapter.lifecycle.currentHead(management_head),
    );
    const primary = try coordinator.output_adapter.logicalSnapshot(
        coordinator.physical_outputs[0].protocol_output,
    );
    try std.testing.expectEqual(@as(i32, 0), primary.x);
    try std.testing.expectEqual(@as(?i32, 3), primary.width);

    fixture.second_desktop = true;
    const primary_kms = coordinator.physical_outputs[0].kms_output.?;
    const primary_physical_id = coordinator.physical_outputs[0].id;
    const primary_protocol_output = coordinator.physical_outputs[0].protocol_output;
    const primary_management_head = coordinator.physical_outputs[0].management_head;
    const drains_before_reconnect = coordinator.stats.output_drains;
    const serial_before_reconnect = coordinator.output_management_adapter.lifecycle.serial;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.topology_refresh_pending and
            coordinator.physical_outputs[1].connected and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(coordinator.physical_outputs[1].connected);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    try std.testing.expectEqual(physical_id.index, coordinator.physical_outputs[1].id.index);
    try std.testing.expect(physical_id.generation != coordinator.physical_outputs[1].id.generation);
    try std.testing.expect(!std.meta.eql(
        protocol_output,
        coordinator.physical_outputs[1].protocol_output,
    ));
    try std.testing.expect(!std.meta.eql(
        management_head,
        coordinator.physical_outputs[1].management_head,
    ));
    try std.testing.expect(try coordinator.output_adapter.outputPublished(
        coordinator.physical_outputs[1].protocol_output,
    ));
    try std.testing.expect(coordinator.physical_outputs[0].kms_output.? == primary_kms);
    try std.testing.expect(std.meta.eql(primary_physical_id, coordinator.physical_outputs[0].id));
    try std.testing.expect(std.meta.eql(
        primary_protocol_output,
        coordinator.physical_outputs[0].protocol_output,
    ));
    try std.testing.expect(std.meta.eql(
        primary_management_head,
        coordinator.physical_outputs[0].management_head,
    ));
    try std.testing.expectEqual(drains_before_reconnect, coordinator.stats.output_drains);
    try std.testing.expectEqual(
        serial_before_reconnect + 1,
        coordinator.output_management_adapter.lifecycle.serial,
    );

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator rebuilds an output when its modes change" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-mode-hotplug-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }

    const physical_id = coordinator.physical_outputs[0].id;
    const protocol_output = coordinator.physical_outputs[0].protocol_output;
    const management_head = coordinator.physical_outputs[0].management_head;
    const unchanged_kms = coordinator.physical_outputs[1].kms_output.?;
    const unchanged_physical_id = coordinator.physical_outputs[1].id;
    const unchanged_protocol_output = coordinator.physical_outputs[1].protocol_output;
    const unchanged_management_head = coordinator.physical_outputs[1].management_head;
    const drains_before = coordinator.stats.output_drains;
    fixture.first_mode_width = 4;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.topology_refresh_pending and
            coordinator.physical_outputs[0].kms_output != null)
        {
            const snapshot = coordinator.output_adapter.logicalSnapshot(
                coordinator.physical_outputs[0].protocol_output,
            ) catch continue;
            if (snapshot.width == 4) break;
        }
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const snapshot = try coordinator.output_adapter.logicalSnapshot(
        coordinator.physical_outputs[0].protocol_output,
    );
    try std.testing.expectEqual(@as(?i32, 4), snapshot.width);
    try std.testing.expect(std.meta.eql(physical_id, coordinator.physical_outputs[0].id));
    try std.testing.expect(std.meta.eql(
        protocol_output,
        coordinator.physical_outputs[0].protocol_output,
    ));
    try std.testing.expect(!std.meta.eql(
        management_head,
        coordinator.physical_outputs[0].management_head,
    ));
    try std.testing.expect(coordinator.physical_outputs[1].kms_output.? == unchanged_kms);
    try std.testing.expect(std.meta.eql(
        unchanged_physical_id,
        coordinator.physical_outputs[1].id,
    ));
    try std.testing.expect(std.meta.eql(
        unchanged_protocol_output,
        coordinator.physical_outputs[1].protocol_output,
    ));
    try std.testing.expect(std.meta.eql(
        unchanged_management_head,
        coordinator.physical_outputs[1].management_head,
    ));
    try std.testing.expectEqual(drains_before + 1, coordinator.stats.output_drains);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator falls back when topology changes during targeted refresh" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-refresh-race-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }

    const first_id = coordinator.physical_outputs[0].id;
    const first_output = coordinator.physical_outputs[0].protocol_output;
    const first_head = coordinator.physical_outputs[0].management_head;
    const second_id = coordinator.physical_outputs[1].id;
    const second_output = coordinator.physical_outputs[1].protocol_output;
    const second_head = coordinator.physical_outputs[1].management_head;
    const drains_before = coordinator.stats.output_drains;
    fixture.first_mode_width = 4;
    fixture.change_second_mode_after_read = true;
    try fixture.signalHotplug();
    for (0..768) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.topology_refresh_pending and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null)
        {
            const first = coordinator.output_adapter.logicalSnapshot(first_output) catch continue;
            const second = coordinator.output_adapter.logicalSnapshot(second_output) catch continue;
            if (first.width == 4 and second.width == 4) break;
        }
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }

    try std.testing.expectEqual(@as(?i32, 4), (try coordinator.output_adapter.logicalSnapshot(first_output)).width);
    try std.testing.expectEqual(@as(?i32, 4), (try coordinator.output_adapter.logicalSnapshot(second_output)).width);
    try std.testing.expect(std.meta.eql(first_id, coordinator.physical_outputs[0].id));
    try std.testing.expect(std.meta.eql(first_output, coordinator.physical_outputs[0].protocol_output));
    try std.testing.expect(!std.meta.eql(first_head, coordinator.physical_outputs[0].management_head));
    try std.testing.expect(std.meta.eql(second_id, coordinator.physical_outputs[1].id));
    try std.testing.expect(std.meta.eql(second_output, coordinator.physical_outputs[1].protocol_output));
    try std.testing.expect(!std.meta.eql(second_head, coordinator.physical_outputs[1].management_head));
    try std.testing.expectEqual(drains_before + 2, coordinator.stats.output_drains);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator fails over from a disconnected primary output" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-failover-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[1].kms_output != null and
            coordinator.output_global_index == 2) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    for (0..64) |_| {
        if (physicalOutputsSettled(coordinator)) break;
        _ = try loop.turn(coordinator);
        if (physicalOutputsSettled(coordinator)) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const primary_protocol = coordinator.physical_outputs[0].protocol_output;
    const primary_head = coordinator.physical_outputs[0].management_head;
    const secondary_protocol = coordinator.physical_outputs[1].protocol_output;
    const secondary_head = coordinator.physical_outputs[1].management_head;
    try coordinator.output_adapter.publishScale(secondary_protocol, 240);
    var secondary_state = try coordinator.output_management_adapter.lifecycle.currentHead(
        secondary_head,
    );
    secondary_state.scale_120 = 240;
    _ = try coordinator.output_management_adapter.publishHead(
        secondary_head,
        secondary_state,
    );

    fixture.first_desktop = false;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.physical_outputs[0].connected and
            !coordinator.physical_outputs[0].removing and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(!coordinator.physical_outputs[0].connected);
    try std.testing.expect(coordinator.physical_outputs[0].kms_output == null);
    try std.testing.expect(!(try coordinator.output_adapter.outputPublished(primary_protocol)));
    try std.testing.expectError(
        error.InvalidHead,
        coordinator.output_management_adapter.lifecycle.currentHead(primary_head),
    );
    try std.testing.expect(coordinator.physical_outputs[1].connected);
    try std.testing.expectEqual(@as(u32, 11), coordinator.physical_outputs[1].connector_id);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    try std.testing.expect(try coordinator.output_adapter.outputPublished(secondary_protocol));
    try std.testing.expectEqual(secondary_protocol, coordinator.output_adapter.primaryOutput());
    try std.testing.expectEqual(
        secondary_head,
        coordinator.output_management_adapter.lifecycle.primary,
    );
    try std.testing.expectEqual(
        @as(u32, 240),
        coordinator.fractional_scale_adapter.preferred_scale,
    );
    try std.testing.expectEqual(@as(?i32, 1), (try coordinator.output_adapter.logicalSnapshot(
        secondary_protocol,
    )).width);

    fixture.first_desktop = true;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.topology_refresh_pending and
            coordinator.physical_outputs[0].connected and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(coordinator.physical_outputs[0].connected);
    try std.testing.expectEqual(@as(u32, 10), coordinator.physical_outputs[0].connector_id);
    try std.testing.expect(!std.meta.eql(
        primary_protocol,
        coordinator.physical_outputs[0].protocol_output,
    ));
    try std.testing.expectEqual(secondary_protocol, coordinator.physical_outputs[1].protocol_output);
    try std.testing.expectEqual(secondary_protocol, coordinator.output_adapter.primaryOutput());
    try std.testing.expectEqual(
        secondary_head,
        coordinator.output_management_adapter.lifecycle.primary,
    );

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "physical coordinator replaces the last disconnected output exactly" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-reconnect-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const disconnected_protocol = coordinator.physical_outputs[0].protocol_output;
    const disconnected_head = coordinator.physical_outputs[0].management_head;

    fixture.first_desktop = false;
    try fixture.signalHotplug();
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.topology_refresh_pending and
            coordinator.physical_outputs[0].kms_output == null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(coordinator.topology_refresh_pending);
    try std.testing.expect(coordinator.physical_outputs[0].kms_output == null);
    try std.testing.expect(!(try coordinator.output_management_adapter.lifecycle.currentHead(
        coordinator.physical_outputs[0].management_head,
    )).enabled);

    fixture.second_desktop = true;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        if (!coordinator.topology_refresh_pending and
            !coordinator.physical_outputs[0].connected and
            !coordinator.physical_outputs[0].removing and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(!coordinator.topology_refresh_pending);
    try std.testing.expect(!coordinator.physical_outputs[0].connected);
    try std.testing.expect(!(try coordinator.output_adapter.outputPublished(
        disconnected_protocol,
    )));
    try std.testing.expectError(
        error.InvalidHead,
        coordinator.output_management_adapter.lifecycle.currentHead(disconnected_head),
    );
    try std.testing.expectEqual(@as(u32, 11), coordinator.physical_outputs[1].connector_id);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    try std.testing.expect(!std.meta.eql(
        disconnected_protocol,
        coordinator.physical_outputs[1].protocol_output,
    ));
    try std.testing.expectEqual(
        coordinator.physical_outputs[1].protocol_output,
        coordinator.output_adapter.primaryOutput(),
    );
    try std.testing.expect((try coordinator.output_management_adapter.lifecycle.currentHead(
        coordinator.physical_outputs[1].management_head,
    )).enabled);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated output management applies two heads atomically" {
    try generatedMultiHeadApply(false, false, false, false, false, false, false, false);
}

test "generated output management rolls back every head" {
    try generatedMultiHeadApply(true, false, false, false, false, false, false, false);
}

test "generated output management disables a secondary head atomically" {
    try generatedMultiHeadApply(false, true, false, false, false, false, false, false);
}

test "generated output management re-enables a secondary head atomically" {
    try generatedMultiHeadApply(false, true, true, false, false, false, false, false);
}

test "generated output management promotes an enabled head after disabling the primary" {
    try generatedMultiHeadApply(false, false, false, false, false, true, false, false);
}

test "generated output management retries hotplug deferred during reconfiguration" {
    try generatedMultiHeadApply(false, false, false, false, false, false, true, false);
}

test "generated output management resumes session disable deferred during reconfiguration" {
    try generatedMultiHeadApply(false, false, false, false, false, false, false, true);
}

test "generated output management rotates one physical head" {
    try generatedMultiHeadApply(false, false, false, true, false, false, false, false);
}

test "generated output management rolls back a physical transform" {
    try generatedMultiHeadApply(true, false, false, true, false, false, false, false);
}

test "generated output management enables adaptive sync on one head" {
    try generatedMultiHeadApply(false, false, false, false, true, false, false, false);
}

fn generatedMultiHeadApply(
    fail_second_activation: bool,
    disable_second: bool,
    reenable_second: bool,
    rotate_first: bool,
    adaptive_sync: bool,
    disable_first: bool,
    hotplug_during_apply: bool,
    session_disable_during_apply: bool,
) !void {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    fixture.vrr_supported = adaptive_sync;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-multi-head-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const platforms = if (hotplug_during_apply)
        fixture.platformsWithHotplug()
    else
        fixture.platforms();
    const coordinator = try Coordinator.create(allocator, root, platforms, coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    for (0..64) |_| {
        if (physicalOutputsSettled(coordinator)) break;
        _ = try loop.turn(coordinator);
        if (physicalOutputsSettled(coordinator)) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const first_ids = .{
        coordinator.physical_outputs[0].kms_output.?.outputId(),
        coordinator.physical_outputs[1].kms_output.?.outputId(),
    };
    if (fail_second_activation)
        fixture.fail_create_bo_at = fixture.bo_count + coordinatorConfig().output.image_count;

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: MultiOutputManagementClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .disable_second = disable_second,
        .reenable_second = reenable_second,
        .rotate_first = rotate_first,
        .adaptive_sync = adaptive_sync,
        .disable_first = disable_first,
    };
    try submitClient(&reactor, &driver, &handler);
    var hotplug_signaled = false;
    var session_disable_signaled = false;
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.apply_submitted and !handler.apply_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.apply_flushed = true;
        }
        if (handler.reenable_submitted and !handler.reenable_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.reenable_flushed = true;
        }
        _ = try loop.turn(coordinator);
        if (hotplug_during_apply and !hotplug_signaled and
            coordinator.output_reconfigure != null)
        {
            fixture.second_desktop = false;
            try fixture.signalHotplug();
            hotplug_signaled = true;
        }
        if (session_disable_during_apply and !session_disable_signaled and
            coordinator.output_reconfigure != null)
        {
            try fixture.signalSession(.disable);
            session_disable_signaled = true;
        }
        const transaction_complete = handler.succeeded == @as(usize, 1) + @intFromBool(reenable_second) or
            handler.failed == 1;
        const hotplug_complete = !hotplug_during_apply or (hotplug_signaled and
            !coordinator.physical_outputs[1].connected and !coordinator.hotplug_refresh_pending);
        var outputs_inactive = true;
        for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
            outputs_inactive = outputs_inactive and physical.kms_output == null;
        const session_disable_complete = !session_disable_during_apply or
            (session_disable_signaled and outputs_inactive and coordinator.session.state == .disabled);
        if (transaction_complete and hotplug_complete and session_disable_complete) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) {
            try waitForEither(&root.ring, reactor.ring);
        }
    }
    try std.testing.expectEqual(
        if (fail_second_activation) 0 else @as(usize, 1) + @intFromBool(reenable_second),
        handler.succeeded,
    );
    try std.testing.expectEqual(@as(usize, @intFromBool(fail_second_activation)), handler.failed);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expectEqual(hotplug_during_apply, hotplug_signaled);
    try std.testing.expectEqual(session_disable_during_apply, session_disable_signaled);
    if (hotplug_during_apply) {
        try std.testing.expect(coordinator.physical_outputs[0].connected);
        try std.testing.expect(coordinator.physical_outputs[0].kms_output != null);
        try std.testing.expect(!coordinator.physical_outputs[1].connected);
        try std.testing.expect(coordinator.physical_outputs[1].kms_output == null);
        try std.testing.expectEqual(
            coordinator.physical_outputs[0].protocol_output,
            coordinator.output_adapter.primaryOutput(),
        );
    } else if (session_disable_during_apply) {
        try std.testing.expectEqual(.disabled, coordinator.session.state);
        for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
            try std.testing.expect(physical.kms_output == null);
    } else {
        try std.testing.expectEqual(@as(i32, if (fail_second_activation or disable_second or disable_first) 0 else 3), (try coordinator.output_management_adapter.lifecycle.currentHead(
            coordinator.physical_outputs[0].management_head,
        )).x);
        try std.testing.expectEqual(@as(i32, if (fail_second_activation or disable_second) 3 else 0), (try coordinator.output_management_adapter.lifecycle.currentHead(
            coordinator.physical_outputs[1].management_head,
        )).x);
        const first_state = try coordinator.output_management_adapter.lifecycle.currentHead(
            coordinator.physical_outputs[0].management_head,
        );
        try std.testing.expectEqual(
            @as(i32, if (rotate_first and !fail_second_activation) 1 else 0),
            first_state.transform,
        );
        try std.testing.expectEqual(adaptive_sync and !fail_second_activation, first_state.adaptive_sync);
        if (disable_first) {
            try std.testing.expect(!first_state.enabled);
            try std.testing.expect(coordinator.physical_outputs[0].kms_output == null);
            try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
            try std.testing.expectEqual(
                coordinator.physical_outputs[1].protocol_output,
                coordinator.output_adapter.primaryOutput(),
            );
            try std.testing.expectEqual(
                coordinator.physical_outputs[1].management_head,
                coordinator.output_management_adapter.lifecycle.primary,
            );
        }
        if (adaptive_sync and !fail_second_activation) {
            try std.testing.expect(coordinator.physical_outputs[0].kms_output.?.kms_output.adaptive_sync);
        }
        if (rotate_first and !fail_second_activation) {
            const first_output = coordinator.physical_outputs[0].kms_output.?;
            try std.testing.expectEqual(ouro.render.Size{ .width = 2, .height = 3 }, first_output.planner.output);
            try std.testing.expectEqual(ouro.render.Size{ .width = 3, .height = 2 }, first_output.planner.physical_output);
            const logical = try coordinator.output_adapter.logicalSnapshot(
                coordinator.physical_outputs[0].protocol_output,
            );
            try std.testing.expectEqual(@as(?i32, 2), logical.width);
            try std.testing.expectEqual(@as(?i32, 3), logical.height);
            try std.testing.expectEqual(@as(u3, 1), logical.transform);
            const capture = coordinator.captureConstraints(.{ .source = .{
                .output = first_output.outputId(),
            } }).?;
            try std.testing.expectEqual(@as(u32, 3), capture.width);
            try std.testing.expectEqual(@as(u32, 2), capture.height);
            try std.testing.expectEqual(@as(u3, 1), capture.transform);
        } else if (rotate_first) {
            const first_output = coordinator.physical_outputs[0].kms_output.?;
            try std.testing.expectEqual(ouro.render.Size{ .width = 3, .height = 2 }, first_output.planner.output);
            try std.testing.expectEqual(ouro.render.Transform.normal, first_output.planner.output_transform);
            try std.testing.expectEqual(
                @as(u3, 0),
                (try coordinator.output_adapter.logicalSnapshot(
                    coordinator.physical_outputs[0].protocol_output,
                )).transform,
            );
        }
        if (disable_first) {
            try std.testing.expect(!std.meta.eql(
                first_ids[1],
                coordinator.physical_outputs[1].kms_output.?.outputId(),
            ));
            try std.testing.expectEqual(@as(usize, 2), coordinator.stats.output_drains);
        } else if (disable_second and !reenable_second) {
            try std.testing.expectEqual(
                first_ids[0],
                coordinator.physical_outputs[0].kms_output.?.outputId(),
            );
            try std.testing.expect(coordinator.physical_outputs[1].kms_output == null);
            try std.testing.expect(!(try coordinator.output_management_adapter.lifecycle.currentHead(
                coordinator.physical_outputs[1].management_head,
            )).enabled);
            try std.testing.expectEqual(@as(usize, 1), coordinator.stats.output_drains);
        } else if (!reenable_second) {
            try std.testing.expect(!std.meta.eql(
                first_ids[0],
                coordinator.physical_outputs[0].kms_output.?.outputId(),
            ));
            try std.testing.expect(!std.meta.eql(
                first_ids[1],
                coordinator.physical_outputs[1].kms_output.?.outputId(),
            ));
            try std.testing.expectEqual(@as(usize, 2), coordinator.stats.output_drains);
        } else {
            try std.testing.expectEqual(
                first_ids[0],
                coordinator.physical_outputs[0].kms_output.?.outputId(),
            );
            try std.testing.expect(!std.meta.eql(
                first_ids[1],
                coordinator.physical_outputs[1].kms_output.?.outputId(),
            ));
            try std.testing.expect((try coordinator.output_management_adapter.lifecycle.currentHead(
                coordinator.physical_outputs[1].management_head,
            )).enabled);
            try std.testing.expectEqual(@as(usize, 1), coordinator.stats.output_drains);
        }
    }

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        const client_progress = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and
            coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated client leases and hotplugs two non-desktop connectors" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.third_connector = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-lease-client-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platformsWithHotplug(),
        coordinatorConfig(),
    );
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: LeaseClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    _ = try driver.schedule();
    _ = try driver.prepare(&handler);
    _ = try reactor.ring.submit();

    _ = try loop.turn(coordinator);
    for (0..32) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (coordinator.client_count == 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expectEqual(@as(usize, 1), coordinator.client_count);
    try fixture.signalSession(.enable);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.device != null and !handler.bind_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.bind_flushed = true;
        }
        if (handler.submitted and !handler.lease_request_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.lease_request_flushed = true;
        }
        if (handler.lease_fd_received) fixture.lease_active = false;
        _ = try loop.turn(coordinator);
        if (handler.finished == 1 or handler.event_failures != 0) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expect(handler.discovery_fd_received);
    try std.testing.expect(handler.lease_fd_received);
    try std.testing.expectEqual(@as(usize, 1), handler.finished);
    try std.testing.expectEqual(@as(usize, 1), fixture.lease_create_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.lease_revoke_count);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 11, 31, 41, 12, 32, 42 },
        fixture.lease_objects[0..fixture.lease_object_count],
    );

    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.connector_done_count == 4) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 4), handler.connector_done_count);

    fixture.third_connector = false;
    try fixture.signalHotplug();
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.release_requested and !handler.release_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.release_flushed = true;
        } else if (handler.device != null and !handler.bind_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.bind_flushed = true;
        }
        _ = try loop.turn(coordinator);
        if (handler.withdrawn >= 4 and handler.connector_done_count >= 6 and
            handler.globals >= 2 and handler.global_removes >= 1 and handler.released >= 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(handler.withdrawn >= 4);
    try std.testing.expect(handler.connector_done_count >= 6);
    try std.testing.expect(handler.global_removes >= 1);
    try std.testing.expect(coordinator.primaryKmsOutput() != null);

    fixture.third_connector = true;
    try fixture.signalHotplug();
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.release_requested and !handler.release_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.release_flushed = true;
        } else if (handler.device != null and !handler.bind_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.bind_flushed = true;
        }
        _ = try loop.turn(coordinator);
        if (handler.withdrawn >= 5 and handler.connector_done_count >= 7 and
            handler.globals >= 3 and handler.global_removes >= 2 and handler.released >= 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(handler.withdrawn >= 5);
    try std.testing.expect(handler.connector_done_count >= 7);
    try std.testing.expect(handler.global_removes >= 2);

    try fixture.signalSession(.disable);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.release_requested and !handler.release_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.release_flushed = true;
        }
        _ = try loop.turn(coordinator);
        if (coordinator.primaryKmsOutput() == null and coordinator.session.state == .disabled) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(handler.withdrawn >= 5);
    try std.testing.expect(handler.released >= 1);
    try std.testing.expect(handler.global_removes >= 2);
    try std.testing.expectEqual(ouro.session.State.disabled, coordinator.session.state);

    try fixture.signalSession(.enable);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.device != null and !handler.bind_flushed) {
            try submitClient(&reactor, &driver, &handler);
            handler.bind_flushed = true;
        }
        _ = try loop.turn(coordinator);
        if (coordinator.primaryKmsOutput() != null and !coordinator.topology_refresh_pending) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(handler.globals >= 3);
    try std.testing.expect(handler.connector_done_count >= 7);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expect(coordinator.primaryKmsOutput() != null);

    _ = try client.prepareClose();
    _ = try driver.schedule();
    var client_progress = try driver.prepare(&handler);
    _ = try reactor.ring.submit();
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        client_progress = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated session lock publishes only after presentation and client loss stays fail closed" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    fixture.flip_batch_limit = 1;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-session-lock-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(
        allocator,
        root,
        fixture.platformsWithHotplug(),
        coordinatorConfig(),
    );
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    const secondary = &coordinator.physical_outputs[1];
    try coordinator.output_adapter.publishScale(secondary.protocol_output, 240);
    var secondary_head = try coordinator.output_management_adapter.lifecycle.currentHead(
        secondary.management_head,
    );
    secondary_head.scale_120 = 240;
    _ = try coordinator.output_management_adapter.publishHead(
        secondary.management_head,
        secondary_head,
    );

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: SessionLockClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .minimum_outputs = 2,
        .expected_width = 1,
        .expected_height = 1,
    };
    try submitClient(&reactor, &driver, &handler);

    var observed_partial_secure_presentation = false;
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.session_lock_adapter.pendingLock() != null) {
            var presented_outputs: usize = 0;
            for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical| {
                if (physical.kms_output != null and physical.session_lock_presented)
                    presented_outputs += 1;
            }
            if (presented_outputs == 1) {
                try std.testing.expectEqual(@as(usize, 0), handler.locked);
                observed_partial_secure_presentation = true;
            }
        }
        if (handler.locked == 1 and handler.surface_enters == 1 and
            handler.preferred_scale == 240) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.configures);
    try std.testing.expect(observed_partial_secure_presentation);
    try std.testing.expectEqual(@as(usize, 1), handler.locked);
    try std.testing.expectEqual(@as(usize, 0), handler.finished);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expectEqual(@as(usize, 1), handler.surface_enters);
    try std.testing.expectEqual(@as(usize, 0), handler.surface_leaves);
    try std.testing.expectEqual(@as(u32, 240), handler.preferred_scale);
    try std.testing.expect(coordinator.stats.presented >= 1);
    try std.testing.expect(coordinator.session_lock_adapter.isFailClosed());
    const lock_ids = try coordinator.session_lock_adapter.surfaceIds(coordinator.lock_surface_ids);
    try std.testing.expectEqual(@as(usize, 1), lock_ids.len);
    const lock_state = try coordinator.session_lock_adapter.surfaceState(lock_ids[0]);
    try std.testing.expectEqual(
        coordinator.physical_outputs[1].protocol_output,
        lock_state.output_id,
    );
    var lock_destination: ?ouro.render.Rect = null;
    for (coordinator.app_layers) |layer| {
        if (layer.id) |id| if (std.meta.eql(id, lock_state.surface) and layer.sample != null) {
            lock_destination = layer.sample.?.destination;
            break;
        };
    }
    try std.testing.expectEqual(
        ouro.render.Rect{ .x = 3, .y = 0, .width = 1, .height = 1 },
        lock_destination.?,
    );
    const lock_resource = try coordinator.adapter.surfaceResource(lock_state.surface);
    var lock_associations: usize = 0;
    for (coordinator.output_adapter.associations) |association| {
        if (!association.active or !association.desired or
            !std.meta.eql(association.surface, lock_resource)) continue;
        try std.testing.expectEqual(
            coordinator.physical_outputs[1].protocol_output,
            association.output,
        );
        lock_associations += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), lock_associations);

    try fixture.signalSession(.disable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output == null and
            coordinator.physical_outputs[1].kms_output == null and
            coordinator.session.state == .disabled and
            handler.surface_leaves == 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(coordinator.physical_outputs[0].kms_output == null);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output == null);
    try std.testing.expectEqual(@as(usize, 1), handler.surface_leaves);

    try fixture.signalSession(.enable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null and
            handler.surface_enters == 2) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(coordinator.physical_outputs[0].kms_output != null);
    try std.testing.expect(coordinator.physical_outputs[1].kms_output != null);
    try std.testing.expectEqual(@as(usize, 2), handler.surface_enters);
    try std.testing.expectEqual(@as(u32, 240), handler.preferred_scale);

    fixture.second_desktop = false;
    try fixture.signalHotplug();
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!coordinator.physical_outputs[1].connected and
            !coordinator.physical_outputs[1].removing and
            handler.surface_leaves == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(!coordinator.physical_outputs[1].connected);
    const retired_lock = try coordinator.session_lock_adapter.surfaceState(lock_ids[0]);
    try std.testing.expect(retired_lock.retired);
    try std.testing.expect(!retired_lock.mapped);
    try std.testing.expect(coordinator.session_lock_adapter.activeLock() != null);
    try std.testing.expect(coordinator.session_lock_adapter.isFailClosed());
    try std.testing.expect(coordinator.physical_outputs[0].kms_output != null);
    lock_associations = 0;
    for (coordinator.output_adapter.associations) |association| {
        if (association.active and association.desired and
            std.meta.eql(association.surface, lock_resource)) lock_associations += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), lock_associations);
    try std.testing.expectEqual(@as(usize, 2), handler.surface_leaves);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    const client_progress = try drainClient(&reactor, &driver, &handler);
    try std.testing.expect(client_progress.quiescent);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.client_count == 0) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expectEqual(@as(usize, 0), coordinator.client_count);
    try std.testing.expect(coordinator.session_lock_adapter.activeLock() == null);
    try std.testing.expect(coordinator.session_lock_adapter.isFailClosed());
    try std.testing.expect(!coordinator.stopping);

    try coordinator.requestStop();
    try drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated output management test succeeds and unsupported apply is non-mutating" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-management-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.primaryKmsOutput() != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(coordinator.primaryKmsOutput() != null);
    const output_id = coordinator.primaryKmsOutput().?.outputId();

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 24, .max_client_ids = 23 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: OutputManagementClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.failed == 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.succeeded);
    try std.testing.expectEqual(@as(usize, 1), handler.failed);
    try std.testing.expectEqual(@as(usize, 0), handler.cancelled);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expectEqual(output_id, coordinator.primaryKmsOutput().?.outputId());
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.selected_outputs);
    try std.testing.expectEqual(@as(usize, 0), coordinator.stats.output_drains);
    try std.testing.expectEqual(@as(i32, 3), coordinator.output_management_adapter.lifecycle.current.width);
    try std.testing.expectEqual(@as(i32, 2), coordinator.output_management_adapter.lifecycle.current.height);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        const client_progress = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated output power client drains and recreates the physical output" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-output-power-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    try std.testing.expect(coordinator.primaryKmsOutput() != null);
    const initial_primary = coordinator.primaryKmsOutput().?.outputId();
    const initial_secondary = coordinator.physical_outputs[1].kms_output.?.outputId();

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: OutputPowerClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.mode_counts[0] == handler.modes[0].len and
            handler.mode_counts[1] == handler.modes[1].len) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    for (handler.modes) |modes| try std.testing.expectEqualSlices(u32, &.{
        protocol.zwlr_output_power_v1.mode.on.value,
        protocol.zwlr_output_power_v1.mode.off.value,
        protocol.zwlr_output_power_v1.mode.on.value,
    }, &modes);
    try std.testing.expectEqual(@as(usize, 0), handler.failed);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expect(coordinator.primaryKmsOutput() != null);
    try std.testing.expect(!std.meta.eql(
        initial_primary,
        coordinator.physical_outputs[0].kms_output.?.outputId(),
    ));
    try std.testing.expect(!std.meta.eql(
        initial_secondary,
        coordinator.physical_outputs[1].kms_output.?.outputId(),
    ));
    try std.testing.expectEqual(
        coordinator.physical_outputs[0].kms_output.?.outputId(),
        coordinator.primaryKmsOutput().?.outputId(),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        coordinator.stats.selected_outputs,
    );
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.output_drains);
    const powers = handler.powers;

    try fixture.signalSession(.disable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output == null and
            coordinator.physical_outputs[1].kms_output == null and
            coordinator.session.state == .disabled) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try fixture.signalSession(.enable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqual(powers, handler.powers);
    try std.testing.expectEqual(@as(usize, 0), handler.failed);
    try std.testing.expectEqual([2]usize{ 3, 3 }, handler.mode_counts);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        const client_progress = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "generated gamma control applies exact ramps and restores on reuse" {
    try generatedGammaControl(1);
}

test "generated gamma control routes the primary output exactly" {
    try generatedGammaControl(0);
}

fn generatedGammaControl(output_index: usize) !void {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-r15-gamma-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), compositorConfig());
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), coordinatorConfig());
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        if (coordinator.physical_output_count == 2 and
            coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null) break;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    var driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: GammaClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .desired_output_index = output_index,
    };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (fixture.gamma_sets == 1) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &GammaClientHandler.first_ramps, &fixture.gamma_current);
    try std.testing.expectEqual(@as(u32, if (output_index == 0) 30 else 31), fixture.gamma_crtc);
    try std.testing.expectEqual(@as(usize, 1), fixture.gamma_gets);

    try handler.destroyControl();
    try submitClient(&reactor, &driver, &handler);
    for (0..128) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (fixture.gamma_sets == 2) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &fixture.gamma_original, &fixture.gamma_current);
    try handler.createControl();
    try submitClient(&reactor, &driver, &handler);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (fixture.gamma_sets == 3) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &GammaClientHandler.second_ramps, &fixture.gamma_current);
    try std.testing.expectEqual(@as(usize, 1), fixture.gamma_gets);

    try fixture.signalSession(.disable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output == null and
            coordinator.physical_outputs[1].kms_output == null and
            coordinator.session.state == .disabled and fixture.gamma_sets == 4) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &fixture.gamma_original, &fixture.gamma_current);
    try fixture.signalSession(.enable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null and
            fixture.gamma_sets == 5) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &GammaClientHandler.second_ramps, &fixture.gamma_current);
    try std.testing.expectEqual(@as(usize, 0), handler.failed);
    try std.testing.expectEqual(@as(usize, 2), fixture.gamma_gets);

    try handler.destroyControl();
    try submitClient(&reactor, &driver, &handler);
    for (0..128) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (fixture.gamma_sets == 6) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expectEqualSlices(u16, &fixture.gamma_original, &fixture.gamma_current);
    try std.testing.expectEqual(@as(usize, 2), handler.gamma_sizes);
    try std.testing.expectEqual(@as(usize, 0), handler.failed);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        const client_progress = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and client_progress.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        if (root.ring.cq_ready() == 0 and reactor.ring.cq_ready() == 0) try waitForEither(&root.ring, reactor.ring);
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
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
    try std.testing.expect(coordinator.primaryKmsOutput() == null);
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
    try std.testing.expect(coordinator.primaryKmsOutput() == null);
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
const ClientSource = enum { shm, alpha_shm, dmabuf, single_pixel };

fn runVertical(trigger: TerminalTrigger, source: ClientSource) !void {
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
        .{ .max_objects = 32, .max_client_ids = 31 },
    );
    var client_driver = ClientDriver.init(&client);
    const actor = try client.actor();
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var client_handler: ClientHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .source = source,
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
                .info = .{ .capabilities = .{ .pointer = true } },
            } }));
            coordinator.interaction.cursorRequest(id, .{ .x = 0, .y = 0 });
            cursor_assigned = true;
        };
        if (coordinator.stats.submitted == 1 and !observed_identity) {
            first_frame = coordinator.primaryKmsOutput().?.currentFrameId().?;
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
            if (source == .single_pixel) {
                const rendered = try coordinator.render_device.?.content.resolve(
                    coordinator.cursor_layer.rendered.?,
                );
                try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 255 }, rendered.bytes);
                try std.testing.expectEqual(@as(u32, 3), sample.destination.width);
                try std.testing.expectEqual(@as(u32, 2), sample.destination.height);
            }
            if (source == .alpha_shm)
                try std.testing.expectEqual(@as(u8, 128), sample.global_alpha);
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
    if (source == .dmabuf) {
        try std.testing.expectEqual(@as(usize, 2), fixture.imported_bos);
        try std.testing.expectEqual(@as(usize, 2), fixture.read_maps);
        // Dumb targets retain their lifetime mapping. The imported validation
        // and retained-source mappings are released by first presentation.
        try std.testing.expectEqual(@as(usize, 2), fixture.unmaps);
    }
    try std.testing.expectEqual(
        @as(u32, 10),
        coordinator.primaryKmsOutput().?.kms_output.connector.id,
    );
    try std.testing.expectEqual(
        @as(u32, 30),
        coordinator.primaryKmsOutput().?.kms_output.crtc.id,
    );
    try std.testing.expectEqual(
        @as(u32, 40),
        coordinator.primaryKmsOutput().?.kms_output.plane.id,
    );
    try std.testing.expectEqual(@as(usize, 1), coordinator.physical_output_count);
    const physical = coordinator.physical_outputs[0];
    try std.testing.expectEqual(coordinator.primaryKmsOutput(), physical.kms_output);
    try std.testing.expectEqual(
        @as(u32, 10),
        (try coordinator.manager.claimSnapshot(physical.claim.?)).selectedConnector().id,
    );
    try std.testing.expectEqual(
        coordinator.output_adapter.primaryOutput(),
        physical.protocol_output,
    );
    try std.testing.expectEqual(
        coordinator.output_management_adapter.lifecycle.primary,
        physical.management_head,
    );

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
        const second_consumed = coordinator.stats.applied == 2 and
            coordinator.cursor_layer.content.owned;
        if (second_consumed and client_handler.surface_enters == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    const abandoned_surface = coordinator.cursor_layer.surface.?;
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.applied);
    try std.testing.expect(!coordinator.cursor_layer.source_release_pending);
    try std.testing.expect(coordinator.cursor_layer.content.owned);
    try std.testing.expect(coordinator.cursor_layer.content.value.attachment_lease == null);
    try std.testing.expect(coordinator.cursor_layer.content.value.release_callbacks == null);
    try std.testing.expect(coordinator.cursor_layer.content.value.surface.attachment.?.buffer == null);
    if (source == .dmabuf) {
        try std.testing.expectEqual(@as(usize, 4), fixture.import_attempts);
        try std.testing.expectEqual(@as(usize, 4), fixture.imported_bos);
    }
    try std.testing.expect(!coordinator.stopping);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.submitted);

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
    for (0..128) |_| {
        _ = try drainClient(&client_reactor, &client_driver, &client_handler);
        _ = try loop.turn(coordinator);
        if (client_handler.presentation_discarded == 1 and
            client_handler.presentation_deleted == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), client_handler.presentation_discarded);
    try std.testing.expectEqual(@as(usize, 2), client_handler.presentation_deleted);
    try std.testing.expectEqual(@as(usize, 1), client_handler.xdg_positions);
    try std.testing.expectEqual(@as(usize, 1), client_handler.xdg_sizes);
    try std.testing.expectEqual(@as(usize, 1), client_handler.xdg_names);
    try std.testing.expectEqual(@as(usize, 1), client_handler.xdg_descriptions);

    if (trigger == .session_disable) {
        // Session disable quiesces R11, renderer, R10, then releases the DRM
        // device before libseat acknowledgement. The client remains connected.
        try fixture.signalSession(.disable);
        for (0..128) |_| {
            if (coordinator.primaryKmsOutput() == null and
                coordinator.session.state == .disabled) break;
            if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
            _ = try loop.turn(coordinator);
        }
        try std.testing.expect(coordinator.primaryKmsOutput() == null);
        try std.testing.expect(coordinator.physical_outputs[0].kms_output == null);
        try std.testing.expect(coordinator.physical_outputs[0].claim == null);
        try std.testing.expectEqual(ouro.session.State.disabled, coordinator.session.state);
        try std.testing.expectEqual(@as(usize, 0), coordinator.session.deviceCount());
        try std.testing.expectEqual(@as(usize, 1), coordinator.stats.output_drains);

        try fixture.signalSession(.enable);
        for (0..128) |_| {
            if (coordinator.primaryKmsOutput() != null) break;
            if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
            _ = try loop.turn(coordinator);
        }
        const replacement = coordinator.primaryKmsOutput() orelse return error.OutputNotRecreated;
        try std.testing.expectEqual(@as(usize, 2), coordinator.stats.selected_outputs);
        try std.testing.expect(replacement.outputId().generation != first_frame.?.output.generation);
        for (0..128) |_| {
            _ = try drainClient(&client_reactor, &client_driver, &client_handler);
            _ = try loop.turn(coordinator);
            if (client_handler.xdg_sizes == 2) break;
            if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
                try waitForEither(&root.ring, client_reactor.ring);
        }
        try std.testing.expectEqual(@as(usize, 2), client_handler.xdg_sizes);
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
    try std.testing.expect(!coordinator.cursor_layer.content.owned);
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.imports.available());
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.frame_pool.available());
    try std.testing.expectEqual(@as(usize, 1), coordinator.adapter.release_pool.available());
    try std.testing.expectEqual(@as(usize, 3), coordinator.presentations.available());
    try std.testing.expectEqual(@as(usize, 1), client_handler.frame_done);
    try std.testing.expect(client_handler.tablet_v2_announced);
    try std.testing.expectEqual(@as(usize, 1), client_handler.presentation_clocks);
    try std.testing.expectEqual(@as(usize, 1), client_handler.presentation_sync_outputs);
    try std.testing.expectEqual(@as(usize, 1), client_handler.presentation_presented);
    try std.testing.expectEqual(@as(usize, 1), client_handler.presentation_discarded);
    try std.testing.expectEqual(@as(usize, 2), client_handler.presentation_deleted);
    try std.testing.expectEqual(
        @as(usize, if (trigger == .session_disable) 2 else 1),
        client_handler.xdg_sizes,
    );
    // The second commit secured renderer-owned content before it was abandoned,
    // so source release is delivered even though no frame callback is due.
    try std.testing.expectEqual(@as(usize, 2), client_handler.release_done);
    try std.testing.expectEqual(@as(usize, 1), client_handler.frame_deleted);
    try std.testing.expectEqual(@as(usize, 2), client_handler.release_deleted);
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
    dmabuf: ?wayring.objects.Handle = null,
    single_pixel_manager: ?wayring.objects.Handle = null,
    viewporter: ?wayring.objects.Handle = null,
    alpha_modifier_manager: ?wayring.objects.Handle = null,
    presentation: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    xdg_output_manager: ?wayring.objects.Handle = null,
    xdg_output: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    release: ?wayring.objects.Handle = null,
    feedback: ?wayring.objects.Handle = null,
    queued: bool = false,
    frame_done: usize = 0,
    release_done: usize = 0,
    frame_deleted: usize = 0,
    release_deleted: usize = 0,
    presentation_clocks: usize = 0,
    presentation_sync_outputs: usize = 0,
    presentation_presented: usize = 0,
    presentation_discarded: usize = 0,
    presentation_deleted: usize = 0,
    surface_enters: usize = 0,
    xdg_positions: usize = 0,
    xdg_sizes: usize = 0,
    xdg_names: usize = 0,
    xdg_descriptions: usize = 0,
    tablet_v2_announced: bool = false,
    source: ClientSource = .shm,

    fn complete(self: ClientHandler) bool {
        return self.frame_done == 1 and self.release_done == 1 and
            self.frame_deleted == 1 and self.release_deleted == 1 and
            self.presentation_clocks == 1 and self.presentation_sync_outputs == 1 and
            self.presentation_presented == 1 and self.presentation_deleted == 1;
    }

    pub fn event(self: *ClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.zwp_tablet_manager_v2.info.name))
                        self.tablet_v2_announced = true;
                    if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name))
                        self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_compositor.info, @min(global.version, 7), null);
                    if ((self.source == .shm or self.source == .alpha_shm) and
                        std.mem.eql(u8, global.interface, protocol.wl_shm.info.name))
                        self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_shm.info, @min(global.version, 2), null);
                    if (self.source == .dmabuf and std.mem.eql(u8, global.interface, protocol.zwp_linux_dmabuf_v1.info.name))
                        self.dmabuf = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.zwp_linux_dmabuf_v1.info, @min(global.version, 3), null);
                    if (self.source == .single_pixel and std.mem.eql(u8, global.interface, protocol.wp_single_pixel_buffer_manager_v1.info.name))
                        self.single_pixel_manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wp_single_pixel_buffer_manager_v1.info, @min(global.version, 1), null);
                    if (self.source == .single_pixel and std.mem.eql(u8, global.interface, protocol.wp_viewporter.info.name))
                        self.viewporter = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wp_viewporter.info, @min(global.version, 1), null);
                    if (self.source == .alpha_shm and std.mem.eql(u8, global.interface, protocol.wp_alpha_modifier_v1.info.name))
                        self.alpha_modifier_manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wp_alpha_modifier_v1.info, @min(global.version, 1), null);
                    if (std.mem.eql(u8, global.interface, protocol.wp_presentation.info.name))
                        self.presentation = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wp_presentation.info, 1, null);
                    if (std.mem.eql(u8, global.interface, protocol.wl_output.info.name))
                        self.output = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_output.info, @min(global.version, 4), null);
                    if (std.mem.eql(u8, global.interface, protocol.zxdg_output_manager_v1.info.name))
                        self.xdg_output_manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.zxdg_output_manager_v1.info, @min(global.version, 3), null);
                    try self.maybeCreateXdgOutput();
                    const source_ready = switch (self.source) {
                        .shm => self.shm != null,
                        .alpha_shm => self.shm != null and self.alpha_modifier_manager != null,
                        .dmabuf => self.dmabuf != null,
                        .single_pixel => self.single_pixel_manager != null and self.viewporter != null,
                    };
                    if (self.compositor != null and self.presentation != null and self.output != null and
                        source_ready and !self.queued) try self.queueWork();
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try wayring.client.decodeEvent(protocol.wl_shm, self.objects, self.shm.?, message, fds);
        } else if (target.object.interface == &protocol.zwp_linux_dmabuf_v1.info) {
            _ = try wayring.client.decodeEvent(protocol.zwp_linux_dmabuf_v1, self.objects, self.dmabuf.?, message, fds);
        } else if (target.object.interface == &protocol.wl_output.info) {
            _ = try protocol.wl_output.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_surface.info) {
            switch (try protocol.wl_surface.decodeEvent(message, fds)) {
                .enter => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.surface_enters += 1;
                },
                .leave => |value| try std.testing.expectEqual(self.output.?.id, value.output),
                else => {},
            }
        } else if (target.object.interface == &protocol.zxdg_output_v1.info) {
            switch (try protocol.zxdg_output_v1.decodeEvent(message, fds)) {
                .logical_position => |value| {
                    try std.testing.expectEqual(@as(i32, 0), value.x);
                    try std.testing.expectEqual(@as(i32, 0), value.y);
                    self.xdg_positions += 1;
                },
                .logical_size => |value| {
                    try std.testing.expectEqual(@as(i32, 3), value.width);
                    try std.testing.expectEqual(@as(i32, 2), value.height);
                    self.xdg_sizes += 1;
                },
                .name => |value| {
                    try std.testing.expectEqualStrings("ouro-0", value.name);
                    self.xdg_names += 1;
                },
                .description => |value| {
                    try std.testing.expectEqualStrings("Ouro output", value.description);
                    self.xdg_descriptions += 1;
                },
                .done => return error.UnexpectedXdgOutputDone,
            }
        } else if (target.object.interface == &protocol.wp_presentation.info) {
            const value = try wayring.client.decodeEvent(protocol.wp_presentation, self.objects, self.presentation.?, message, fds);
            try std.testing.expectEqual(@as(u32, @intFromEnum(linux.CLOCK.MONOTONIC)), value.clock_id.clk_id);
            self.presentation_clocks += 1;
        } else if (target.object.interface == &protocol.wp_presentation_feedback.info) {
            const feedback_event = try wayring.client.decodeEvent(protocol.wp_presentation_feedback, self.objects, self.feedback.?, message, fds);
            switch (feedback_event) {
                .sync_output => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.presentation_sync_outputs += 1;
                },
                .presented => |value| {
                    try std.testing.expectEqual(@as(u32, 0), value.tv_sec_hi);
                    try std.testing.expectEqual(@as(u32, 2), value.tv_sec_lo);
                    try std.testing.expectEqual(@as(u32, 3_000_000), value.tv_nsec);
                    try std.testing.expectEqual(@as(u32, 4_000_000), value.refresh);
                    try std.testing.expectEqual(@as(u32, 0), value.seq_hi);
                    try std.testing.expectEqual(@as(u32, 0), value.seq_lo);
                    try std.testing.expectEqual(@as(u32, 7), value.flags.value);
                    self.presentation_presented += 1;
                },
                .discarded => self.presentation_discarded += 1,
            }
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
                    if (deleted.id == self.feedback.?.id) self.presentation_deleted += 1;
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

    fn maybeCreateXdgOutput(self: *ClientHandler) !void {
        if (self.xdg_output != null or self.xdg_output_manager == null or self.output == null) return;
        self.xdg_output = (try protocol.zxdg_output_manager_v1.construct_get_xdg_output(
            self.objects,
            self.queue,
            self.xdg_output_manager.?,
            .{ .output = self.output.?.id },
        )).id;
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
        const buffer = switch (self.source) {
            .shm, .alpha_shm => try self.createShmBuffer(),
            .dmabuf => try self.createDmabufBuffer(),
            .single_pixel => try self.createSinglePixelBuffer(),
        };
        const alpha_modifier = if (self.source == .alpha_shm)
            (try protocol.wp_alpha_modifier_v1.construct_get_surface(
                self.objects,
                self.queue,
                self.alpha_modifier_manager.?,
                .{ .surface = surface.id },
            )).id
        else
            null;
        if (alpha_modifier) |handle| try wayring.client.sendRequest(
            protocol.wp_alpha_modifier_surface_v1,
            self.objects,
            self.queue,
            handle,
            .{ .set_multiplier = .{ .factor = 0x8080_8080 } },
        );
        const viewport = if (self.source == .single_pixel)
            (try protocol.wp_viewporter.construct_get_viewport(
                self.objects,
                self.queue,
                self.viewporter.?,
                .{ .surface = surface.id },
            )).id
        else
            null;
        if (viewport) |handle| try protocol.wp_viewport.encodeRequest(
            self.queue,
            handle.id,
            .{ .set_destination = .{ .width = 3, .height = 2 } },
        );
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } });
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .damage_buffer = .{
            .x = 0,
            .y = 0,
            .width = if (self.source == .single_pixel) 1 else 3,
            .height = if (self.source == .single_pixel) 1 else 2,
        } });
        self.frame = (try protocol.wl_surface.construct_frame(self.objects, self.queue, surface, .{})).callback;
        self.release = (try protocol.wl_surface.construct_get_release(self.objects, self.queue, surface, .{})).callback;
        self.feedback = (try protocol.wp_presentation.construct_feedback(
            self.objects,
            self.queue,
            self.presentation.?,
            .{ .surface = surface.id },
        )).callback;
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, surface, .{ .commit = .{} });
        if (alpha_modifier) |handle| try wayring.client.sendRequest(
            protocol.wp_alpha_modifier_surface_v1,
            self.objects,
            self.queue,
            handle,
            .{ .destroy = .{} },
        );
        if (viewport) |handle| try wayring.client.sendRequest(
            protocol.wp_viewport,
            self.objects,
            self.queue,
            handle,
            .{ .destroy = .{} },
        );
        try wayring.client.sendRequest(protocol.wl_buffer, self.objects, self.queue, buffer, .{ .destroy = .{} });
    }

    fn createShmBuffer(self: *ClientHandler) !wayring.objects.Handle {
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(self.objects, self.queue, self.shm.?, .{ .fd = descriptor, .size = 4096 });
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(self.objects, self.queue, pool.id, .{
            .offset = 16,
            .width = 3,
            .height = 2,
            .stride = 16,
            .format = .argb8888,
        })).id;
        try wayring.client.sendRequest(protocol.wl_shm_pool, self.objects, self.queue, pool.id, .{ .destroy = .{} });
        return buffer;
    }

    fn createDmabufBuffer(self: *ClientHandler) !wayring.objects.Handle {
        const descriptor = try ordinaryMemfd(4096, 16, &pixels);
        const params = (try protocol.zwp_linux_dmabuf_v1.construct_create_params(
            self.objects,
            self.queue,
            self.dmabuf.?,
            .{},
        )).params_id;
        wayring.client.sendRequest(
            protocol.zwp_linux_buffer_params_v1,
            self.objects,
            self.queue,
            params,
            .{ .add = .{
                .fd = descriptor,
                .plane_idx = 0,
                .offset = 16,
                .stride = 16,
                .modifier_hi = 0,
                .modifier_lo = 0,
            } },
        ) catch |err| {
            _ = linux.close(descriptor);
            return err;
        };
        const buffer = (try protocol.zwp_linux_buffer_params_v1.construct_create_immed(
            self.objects,
            self.queue,
            params,
            .{
                .width = 3,
                .height = 2,
                .format = ouro.gbm.format_xrgb8888,
                .flags = .fromInt(0),
            },
        )).buffer_id;
        try wayring.client.sendRequest(
            protocol.zwp_linux_buffer_params_v1,
            self.objects,
            self.queue,
            params,
            .{ .destroy = .{} },
        );
        return buffer;
    }

    fn createSinglePixelBuffer(self: *ClientHandler) !wayring.objects.Handle {
        return (try protocol.wp_single_pixel_buffer_manager_v1.construct_create_u32_rgba_buffer(
            self.objects,
            self.queue,
            self.single_pixel_manager.?,
            .{
                .r = 0x0202_0202,
                .g = 0x0303_0303,
                .b = 0x0404_0404,
                .a = std.math.maxInt(u32),
            },
        )).id;
    }
};

const SessionLockClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    fractional_scale_manager: ?wayring.objects.Handle = null,
    fractional_scale: ?wayring.objects.Handle = null,
    lock: ?wayring.objects.Handle = null,
    lock_surface: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    buffer: ?wayring.objects.Handle = null,
    output_ready: bool = false,
    output_count: usize = 0,
    minimum_outputs: usize = 1,
    expected_width: u32 = 3,
    expected_height: u32 = 2,
    lock_requested: bool = false,
    configures: usize = 0,
    locked: usize = 0,
    finished: usize = 0,
    event_failures: usize = 0,
    surface_enters: usize = 0,
    surface_leaves: usize = 0,
    preferred_scale: u32 = 0,

    pub fn eventError(self: *SessionLockClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *SessionLockClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name))
                        self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_compositor.info, @min(global.version, 7), null);
                    if (std.mem.eql(u8, global.interface, protocol.wl_shm.info.name))
                        self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_shm.info, @min(global.version, 2), null);
                    if (std.mem.eql(u8, global.interface, protocol.wl_output.info.name)) {
                        self.output = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_output.info, @min(global.version, 4), null);
                        self.output_count += 1;
                    }
                    if (std.mem.eql(u8, global.interface, protocol.ext_session_lock_manager_v1.info.name))
                        self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.ext_session_lock_manager_v1.info, 1, null);
                    if (std.mem.eql(u8, global.interface, protocol.wp_fractional_scale_manager_v1.info.name))
                        self.fractional_scale_manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wp_fractional_scale_manager_v1.info, 1, null);
                },
                .global_remove => {},
            }
            try self.maybeRequestLock();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .done => {
                    if (self.output != null and message.header.object_id == self.output.?.id)
                        self.output_ready = true;
                    try self.maybeRequestLock();
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.ext_session_lock_v1.info) {
            switch (try protocol.ext_session_lock_v1.decodeEvent(message, fds)) {
                .locked => self.locked += 1,
                .finished => self.finished += 1,
            }
        } else if (target.object.interface == &protocol.ext_session_lock_surface_v1.info) {
            switch (try protocol.ext_session_lock_surface_v1.decodeEvent(message, fds)) {
                .configure => |value| try self.commitConfigured(value.serial, value.width, value.height),
            }
        } else if (target.object.interface == &protocol.wl_surface.info) {
            switch (try protocol.wl_surface.decodeEvent(message, fds)) {
                .enter => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.surface_enters += 1;
                },
                .leave => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.surface_leaves += 1;
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.wp_fractional_scale_v1.info) {
            switch (try protocol.wp_fractional_scale_v1.decodeEvent(message, fds)) {
                .preferred_scale => |value| self.preferred_scale = value.scale,
            }
        } else if (target.object.interface == &protocol.wl_buffer.info) {
            _ = try protocol.wl_buffer.decodeEvent(message, fds);
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn maybeRequestLock(self: *SessionLockClientHandler) !void {
        if (self.lock_requested or !self.output_ready or self.compositor == null or
            self.shm == null or self.output == null or self.manager == null or
            self.fractional_scale_manager == null or
            self.output_count < self.minimum_outputs) return;
        self.lock = (try protocol.ext_session_lock_manager_v1.construct_lock(
            self.objects,
            self.queue,
            self.manager.?,
            .{},
        )).id;
        self.surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.fractional_scale = (try protocol.wp_fractional_scale_manager_v1.construct_get_fractional_scale(
            self.objects,
            self.queue,
            self.fractional_scale_manager.?,
            .{ .surface = self.surface.?.id },
        )).id;
        self.lock_surface = (try protocol.ext_session_lock_v1.construct_get_lock_surface(
            self.objects,
            self.queue,
            self.lock.?,
            .{ .surface = self.surface.?.id, .output = self.output.?.id },
        )).id;
        self.lock_requested = true;
    }

    fn commitConfigured(self: *SessionLockClientHandler, serial: u32, width: u32, height: u32) !void {
        try std.testing.expectEqual(self.expected_width, width);
        try std.testing.expectEqual(self.expected_height, height);
        try protocol.ext_session_lock_surface_v1.encodeRequest(
            self.queue,
            self.lock_surface.?.id,
            .{ .ack_configure = .{ .serial = serial } },
        );
        const descriptor = try ordinaryMemfd(4096, 0, &pixels);
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        self.buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 0,
                .width = @intCast(self.expected_width),
                .height = @intCast(self.expected_height),
                .stride = @intCast(self.expected_width * 4),
                .format = .xrgb8888,
            },
        )).id;
        try wayring.client.sendRequest(protocol.wl_shm_pool, self.objects, self.queue, pool.id, .{ .destroy = .{} });
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, self.surface.?, .{ .attach = .{ .buffer = self.buffer.?.id, .x = 0, .y = 0 } });
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, self.surface.?, .{ .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 } });
        try wayring.client.sendRequest(protocol.wl_surface, self.objects, self.queue, self.surface.?, .{ .commit = .{} });
        self.configures += 1;
    }
};

const OutputManagementClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    manager: ?wayring.objects.Handle = null,
    head: ?wayring.objects.Handle = null,
    mode: ?wayring.objects.Handle = null,
    serial: u32 = 0,
    mode_width: i32 = 0,
    mode_height: i32 = 0,
    mode_refresh: i32 = 0,
    mode_preferred: bool = false,
    current_mode: bool = false,
    test_submitted: bool = false,
    apply_submitted: bool = false,
    succeeded: usize = 0,
    failed: usize = 0,
    cancelled: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(self: *OutputManagementClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *OutputManagementClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.zwlr_output_manager_v1.info.name)) self.manager = try ClientCore.bind(
                        self.objects,
                        self.queue,
                        self.registry,
                        global.name,
                        &protocol.zwlr_output_manager_v1.info,
                        @min(global.version, 4),
                        null,
                    );
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_manager_v1.info) {
            switch (try protocol.zwlr_output_manager_v1.decodeEvent(message, fds)) {
                .head => |value| self.head = (try protocol.zwlr_output_manager_v1.admit_event_head(
                    self.objects,
                    self.manager.?,
                    value,
                    .{},
                )).head,
                .done => |value| {
                    self.serial = value.serial;
                    if (!self.test_submitted) try self.submitTest();
                },
                .finished => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_head_v1.info) {
            switch (try protocol.zwlr_output_head_v1.decodeEvent(message, fds)) {
                .mode => |value| self.mode = (try protocol.zwlr_output_head_v1.admit_event_mode(
                    self.objects,
                    self.head.?,
                    value,
                    .{},
                )).mode,
                .current_mode => |value| self.current_mode = self.mode != null and value.mode == self.mode.?.id,
                .name => |value| try std.testing.expectEqualStrings("Ouro-1", value.name),
                .description => |value| try std.testing.expect(value.description.len != 0),
                .enabled => |value| try std.testing.expectEqual(@as(i32, 1), value.enabled),
                .position => |value| try std.testing.expect(value.x == 0 and value.y == 0),
                .transform => |value| try std.testing.expectEqual(@as(i32, 0), value.transform.value),
                .scale => |value| try std.testing.expectEqual(@as(i32, 256), value.scale),
                .adaptive_sync => |value| try std.testing.expectEqual(@as(u32, 0), value.state.value),
                .physical_size, .make, .model, .serial_number, .finished => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_mode_v1.info) {
            switch (try protocol.zwlr_output_mode_v1.decodeEvent(message, fds)) {
                .size => |value| {
                    self.mode_width = value.width;
                    self.mode_height = value.height;
                },
                .refresh => |value| self.mode_refresh = value.refresh,
                .preferred => self.mode_preferred = true,
                .finished => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_configuration_v1.info) {
            switch (try protocol.zwlr_output_configuration_v1.decodeEvent(message, fds)) {
                .succeeded => {
                    self.succeeded += 1;
                    if (!self.apply_submitted) try self.submitUnsupportedApply();
                },
                .failed => self.failed += 1,
                .cancelled => self.cancelled += 1,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn submitTest(self: *OutputManagementClientHandler) !void {
        try std.testing.expect(self.head != null and self.mode != null and self.current_mode and
            !self.mode_preferred and self.mode_width == 3 and self.mode_height == 2 and
            self.mode_refresh == 60_000);
        const configuration = (try protocol.zwlr_output_manager_v1.construct_create_configuration(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .serial = self.serial },
        )).id;
        const configuration_head = (try protocol.zwlr_output_configuration_v1.construct_enable_head(
            self.objects,
            self.queue,
            configuration,
            .{ .head = self.head.?.id },
        )).id;
        try protocol.zwlr_output_configuration_head_v1.encodeRequest(
            self.queue,
            configuration_head.id,
            .{ .set_mode = .{ .mode = self.mode.?.id } },
        );
        try protocol.zwlr_output_configuration_v1.encodeRequest(self.queue, configuration.id, .{ .@"test" = .{} });
        self.test_submitted = true;
    }

    fn submitUnsupportedApply(self: *OutputManagementClientHandler) !void {
        const configuration = (try protocol.zwlr_output_manager_v1.construct_create_configuration(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .serial = self.serial },
        )).id;
        const configuration_head = (try protocol.zwlr_output_configuration_v1.construct_enable_head(
            self.objects,
            self.queue,
            configuration,
            .{ .head = self.head.?.id },
        )).id;
        try protocol.zwlr_output_configuration_head_v1.encodeRequest(
            self.queue,
            configuration_head.id,
            .{ .set_custom_mode = .{ .width = 4, .height = 2, .refresh = 60_000 } },
        );
        try protocol.zwlr_output_configuration_v1.encodeRequest(self.queue, configuration.id, .{ .apply = .{} });
        self.apply_submitted = true;
    }
};

const MultiOutputManagementClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    manager: ?wayring.objects.Handle = null,
    heads: [2]?wayring.objects.Handle = .{ null, null },
    modes: [2]?wayring.objects.Handle = .{ null, null },
    head_count: usize = 0,
    serial: u32 = 0,
    apply_submitted: bool = false,
    apply_flushed: bool = false,
    disable_second: bool = false,
    reenable_second: bool = false,
    reenable_submitted: bool = false,
    reenable_flushed: bool = false,
    rotate_first: bool = false,
    adaptive_sync: bool = false,
    disable_first: bool = false,
    succeeded: usize = 0,
    failed: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(self: *MultiOutputManagementClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *MultiOutputManagementClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.zwlr_output_manager_v1.info.name)) self.manager = try ClientCore.bind(
                        self.objects,
                        self.queue,
                        self.registry,
                        global.name,
                        &protocol.zwlr_output_manager_v1.info,
                        @min(global.version, 4),
                        null,
                    );
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_manager_v1.info) {
            switch (try protocol.zwlr_output_manager_v1.decodeEvent(message, fds)) {
                .head => |value| {
                    if (self.head_count >= self.heads.len) return error.TooManyHeads;
                    self.heads[self.head_count] = (try protocol.zwlr_output_manager_v1.admit_event_head(
                        self.objects,
                        self.manager.?,
                        value,
                        .{},
                    )).head;
                    self.head_count += 1;
                },
                .done => |value| {
                    self.serial = value.serial;
                    if (!self.apply_submitted and self.head_count == self.heads.len and
                        self.modes[0] != null and self.modes[1] != null) try self.submitApply();
                },
                .finished => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_head_v1.info) {
            switch (try protocol.zwlr_output_head_v1.decodeEvent(message, fds)) {
                .mode => |value| {
                    const head = self.objects.namespace.lookupHandle(message.header.object_id) orelse
                        return error.MissingHead;
                    const index = self.headIndex(head) orelse return error.UnknownHead;
                    self.modes[index] = (try protocol.zwlr_output_head_v1.admit_event_mode(
                        self.objects,
                        head,
                        value,
                        .{},
                    )).mode;
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_mode_v1.info) {
            _ = try protocol.zwlr_output_mode_v1.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.zwlr_output_configuration_v1.info) {
            switch (try protocol.zwlr_output_configuration_v1.decodeEvent(message, fds)) {
                .succeeded => {
                    self.succeeded += 1;
                    if (self.reenable_second and self.succeeded == 1)
                        try self.submitReenable();
                },
                .failed => self.failed += 1,
                .cancelled => {},
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn headIndex(self: *const MultiOutputManagementClientHandler, head: wayring.objects.Handle) ?usize {
        for (self.heads, 0..) |candidate, index| {
            if (candidate != null and candidate.?.id == head.id) return index;
        }
        return null;
    }

    fn submitApply(self: *MultiOutputManagementClientHandler) !void {
        const configuration = (try protocol.zwlr_output_manager_v1.construct_create_configuration(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .serial = self.serial },
        )).id;
        for (self.heads, self.modes, 0..) |head, mode, index| {
            if ((self.disable_second and index == 1) or (self.disable_first and index == 0)) {
                try protocol.zwlr_output_configuration_v1.encodeRequest(
                    self.queue,
                    configuration.id,
                    .{ .disable_head = .{ .head = head.?.id } },
                );
                continue;
            }
            const configuration_head = (try protocol.zwlr_output_configuration_v1.construct_enable_head(
                self.objects,
                self.queue,
                configuration,
                .{ .head = head.?.id },
            )).id;
            try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_mode = .{ .mode = mode.?.id } },
            );
            try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_position = .{
                    .x = if (self.disable_second or self.disable_first) 0 else if (index == 0) 3 else 0,
                    .y = 0,
                } },
            );
            if (self.rotate_first and index == 0) try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_transform = .{ .transform = protocol.wl_output.transform.@"90" } },
            );
            if (self.adaptive_sync and index == 0) try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_adaptive_sync = .{ .state = .enabled } },
            );
        }
        try protocol.zwlr_output_configuration_v1.encodeRequest(self.queue, configuration.id, .{ .apply = .{} });
        self.apply_submitted = true;
    }

    fn submitReenable(self: *MultiOutputManagementClientHandler) !void {
        const configuration = (try protocol.zwlr_output_manager_v1.construct_create_configuration(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .serial = self.serial },
        )).id;
        for (self.heads, self.modes, 0..) |head, mode, index| {
            const configuration_head = (try protocol.zwlr_output_configuration_v1.construct_enable_head(
                self.objects,
                self.queue,
                configuration,
                .{ .head = head.?.id },
            )).id;
            try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_mode = .{ .mode = mode.?.id } },
            );
            try protocol.zwlr_output_configuration_head_v1.encodeRequest(
                self.queue,
                configuration_head.id,
                .{ .set_position = .{ .x = if (index == 0) 0 else 3, .y = 0 } },
            );
        }
        try protocol.zwlr_output_configuration_v1.encodeRequest(
            self.queue,
            configuration.id,
            .{ .apply = .{} },
        );
        self.reenable_submitted = true;
    }
};

const OutputPowerClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    manager: ?wayring.objects.Handle = null,
    outputs: [2]?wayring.objects.Handle = .{ null, null },
    output_count: usize = 0,
    powers: [2]?wayring.objects.Handle = .{ null, null },
    output_ready: [2]bool = .{ false, false },
    modes: [2][3]u32 = undefined,
    mode_counts: [2]usize = .{ 0, 0 },
    primary_off_requested: bool = false,
    primary_on_requested: bool = false,
    secondary_off_requested: bool = false,
    secondary_on_requested: bool = false,
    failed: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(self: *OutputPowerClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *OutputPowerClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wl_output.info.name)) {
                        if (self.output_count >= self.outputs.len) return error.UnexpectedOutput;
                        self.outputs[self.output_count] = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_output.info, @min(global.version, 4), null);
                        self.output_count += 1;
                    }
                    if (std.mem.eql(u8, global.interface, protocol.zwlr_output_power_manager_v1.info.name))
                        self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.zwlr_output_power_manager_v1.info, 1, null);
                },
                .global_remove => {},
            }
            try self.maybeCreatePowers();
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .done => {
                    self.output_ready[
                        self.outputIndex(target.object) orelse
                            return error.UnexpectedOutput
                    ] = true;
                    try self.maybeCreatePowers();
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwlr_output_power_v1.info) {
            switch (try protocol.zwlr_output_power_v1.decodeEvent(message, fds)) {
                .mode => |value| {
                    const index = self.powerIndex(target.object) orelse
                        return error.UnexpectedOutputPower;
                    if (self.mode_counts[index] >= self.modes[index].len)
                        return error.UnexpectedPowerMode;
                    self.modes[index][self.mode_counts[index]] = value.mode.value;
                    self.mode_counts[index] += 1;
                    try self.advancePowerCycles();
                },
                .failed => self.failed += 1,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn maybeCreatePowers(self: *OutputPowerClientHandler) !void {
        const manager = self.manager orelse return;
        for (&self.powers, self.outputs, self.output_ready) |*power, output, ready| {
            if (power.* != null or !ready or output == null) continue;
            power.* = (try protocol.zwlr_output_power_manager_v1.construct_get_output_power(
                self.objects,
                self.queue,
                manager,
                .{ .output = output.?.id },
            )).id;
        }
    }

    fn advancePowerCycles(self: *OutputPowerClientHandler) !void {
        if (self.mode_counts[0] == 1 and !self.primary_off_requested) {
            try self.setMode(0, .off);
            self.primary_off_requested = true;
        }
        if (self.mode_counts[0] == 2 and !self.primary_on_requested) {
            try self.setMode(0, .on);
            self.primary_on_requested = true;
        }
        if (self.mode_counts[0] == 3 and self.mode_counts[1] == 1 and
            !self.secondary_off_requested)
        {
            try self.setMode(1, .off);
            self.secondary_off_requested = true;
        }
        if (self.mode_counts[1] == 2 and !self.secondary_on_requested) {
            try self.setMode(1, .on);
            self.secondary_on_requested = true;
        }
    }

    fn setMode(self: *OutputPowerClientHandler, index: usize, mode: protocol.zwlr_output_power_v1.mode) !void {
        try protocol.zwlr_output_power_v1.encodeRequest(
            self.queue,
            self.powers[index].?.id,
            .{ .set_mode = .{ .mode = mode } },
        );
    }

    fn outputIndex(self: *const OutputPowerClientHandler, target: *wayring.objects.Object) ?usize {
        for (self.outputs, 0..) |output, index|
            if (output != null and self.objects.namespace.resolve(output.?) == target) return index;
        return null;
    }

    fn powerIndex(self: *const OutputPowerClientHandler, target: *wayring.objects.Object) ?usize {
        for (self.powers, 0..) |power, index|
            if (power != null and self.objects.namespace.resolve(power.?) == target) return index;
        return null;
    }
};

const GammaClientHandler = struct {
    pub const first_ramps = [_]u16{ 10, 20, 30, 40, 50, 60 };
    pub const second_ramps = [_]u16{ 11, 21, 31, 41, 51, 61 };

    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    manager: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    desired_output_index: usize,
    output_count: usize = 0,
    control: ?wayring.objects.Handle = null,
    output_ready: bool = false,
    gamma_sizes: usize = 0,
    failed: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(self: *GammaClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }
    pub fn event(self: *GammaClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wl_output.info.name)) {
                        if (self.output_count == self.desired_output_index)
                            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.wl_output.info, @min(global.version, 4), null);
                        self.output_count += 1;
                    }
                    if (std.mem.eql(u8, global.interface, protocol.zwlr_gamma_control_manager_v1.info.name))
                        self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, global.name, &protocol.zwlr_gamma_control_manager_v1.info, 1, null);
                },
                .global_remove => {},
            }
            try self.maybeCreateControl();
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .done => {
                    self.output_ready = true;
                    try self.maybeCreateControl();
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwlr_gamma_control_v1.info) {
            switch (try protocol.zwlr_gamma_control_v1.decodeEvent(message, fds)) {
                .gamma_size => |value| {
                    try std.testing.expectEqual(@as(u32, 2), value.size);
                    self.gamma_sizes += 1;
                    const ramps = if (self.gamma_sizes == 1) &first_ramps else &second_ramps;
                    const fd = try ordinaryMemfd(@sizeOf(@TypeOf(first_ramps)), 0, std.mem.sliceAsBytes(ramps));
                    try protocol.zwlr_gamma_control_v1.encodeRequest(self.queue, self.control.?.id, .{ .set_gamma = .{ .fd = fd } });
                },
                .failed => self.failed += 1,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
    fn maybeCreateControl(self: *GammaClientHandler) !void {
        if (self.control != null or !self.output_ready or self.output == null or self.manager == null) return;
        try self.createControl();
    }
    fn createControl(self: *GammaClientHandler) !void {
        self.control = (try protocol.zwlr_gamma_control_manager_v1.construct_get_gamma_control(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .output = self.output.?.id },
        )).id;
    }
    fn destroyControl(self: *GammaClientHandler) !void {
        try wayring.client.sendRequest(protocol.zwlr_gamma_control_v1, self.objects, self.queue, self.control.?, .{ .destroy = .{} });
        self.control = null;
    }
};

const LeaseClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    device: ?wayring.objects.Handle = null,
    connectors: [8]?wayring.objects.Handle = .{null} ** 8,
    lease: ?wayring.objects.Handle = null,
    discovery_fd_received: bool = false,
    connector_names: usize = 0,
    connector_descriptions: usize = 0,
    connector_ids: usize = 0,
    bind_flushed: bool = false,
    submitted: bool = false,
    lease_request_flushed: bool = false,
    lease_fd_received: bool = false,
    finished: usize = 0,
    global_name: ?u32 = null,
    globals: usize = 0,
    global_removes: usize = 0,
    connector_done_count: usize = 0,
    withdrawn: usize = 0,
    released: usize = 0,
    release_requested: bool = false,
    release_flushed: bool = false,
    event_failures: usize = 0,

    pub fn eventError(self: *LeaseClientHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *LeaseClientHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wp_drm_lease_device_v1.info.name)) {
                        self.global_name = global.name;
                        self.globals += 1;
                        self.device = try ClientCore.bind(
                            self.objects,
                            self.queue,
                            self.registry,
                            global.name,
                            &protocol.wp_drm_lease_device_v1.info,
                            1,
                            null,
                        );
                        self.bind_flushed = false;
                    }
                },
                .global_remove => |name| {
                    if (self.global_name == name.name) {
                        self.global_removes += 1;
                        try protocol.wp_drm_lease_device_v1.encodeRequest(
                            self.queue,
                            self.device.?.id,
                            .{ .release = .{} },
                        );
                        self.release_requested = true;
                        self.release_flushed = false;
                    }
                },
            }
        } else if (target.object.interface == &protocol.wp_drm_lease_device_v1.info) {
            switch (try protocol.wp_drm_lease_device_v1.decodeEvent(message, fds)) {
                .drm_fd => |value| {
                    _ = linux.close(value.fd);
                    self.discovery_fd_received = true;
                },
                .connector => |value| {
                    const connector = (try protocol.wp_drm_lease_device_v1.admit_event_connector(
                        self.objects,
                        self.device.?,
                        value,
                        .{},
                    )).id;
                    var stored = false;
                    for (&self.connectors) |*slot| {
                        if (slot.* != null) continue;
                        slot.* = connector;
                        stored = true;
                        break;
                    }
                    if (!stored) return error.UnexpectedConnector;
                },
                .done => if (!self.submitted) {
                    try std.testing.expect(self.discovery_fd_received);
                    try std.testing.expectEqual(@as(usize, 2), self.connector_names);
                    try std.testing.expectEqual(@as(usize, 2), self.connector_descriptions);
                    try std.testing.expectEqual(@as(usize, 2), self.connector_ids);
                    try std.testing.expectEqual(@as(usize, 2), self.connector_done_count);
                    const request = (try protocol.wp_drm_lease_device_v1.construct_create_lease_request(
                        self.objects,
                        self.queue,
                        self.device.?,
                        .{},
                    )).id;
                    for (self.connectors[0..2]) |connector| try wayring.client.sendRequest(
                        protocol.wp_drm_lease_request_v1,
                        self.objects,
                        self.queue,
                        request,
                        .{ .request_connector = .{ .connector = connector.?.id } },
                    );
                    self.lease = (try protocol.wp_drm_lease_request_v1.construct_submit(
                        self.objects,
                        self.queue,
                        request,
                        .{},
                    )).id;
                    self.submitted = true;
                },
                .released => {
                    const released = self.objects.namespace.lookupHandle(message.header.object_id) orelse
                        return error.MissingLeaseDevice;
                    _ = try self.objects.retireLocal(released);
                    if (self.device != null and self.device.?.id == released.id)
                        self.device = null;
                    self.released += 1;
                },
            }
        } else if (target.object.interface == &protocol.wp_drm_lease_connector_v1.info) {
            switch (try protocol.wp_drm_lease_connector_v1.decodeEvent(message, fds)) {
                .name => |value| {
                    try std.testing.expect(std.mem.eql(u8, value.name, "VGA-2") or
                        std.mem.eql(u8, value.name, "VGA-3"));
                    self.connector_names += 1;
                },
                .description => |value| {
                    try std.testing.expect(std.mem.indexOf(u8, value.description, "connector VGA-2") != null or
                        std.mem.indexOf(u8, value.description, "connector VGA-3") != null);
                    self.connector_descriptions += 1;
                },
                .connector_id => |value| {
                    try std.testing.expect(value.connector_id == 11 or value.connector_id == 12);
                    self.connector_ids += 1;
                },
                .done => self.connector_done_count += 1,
                .withdrawn => {
                    self.withdrawn += 1;
                    const connector = self.objects.namespace.lookupHandle(message.header.object_id) orelse
                        return error.MissingConnector;
                    // The device release below retires its server-owned children.
                    _ = try self.objects.removePeer(connector);
                    for (&self.connectors) |*stored| {
                        if (stored.* != null and (stored.*).?.id == connector.id)
                            stored.* = null;
                    }
                },
            }
        } else if (target.object.interface == &protocol.wp_drm_lease_v1.info) {
            switch (try protocol.wp_drm_lease_v1.decodeEvent(message, fds)) {
                .lease_fd => |value| {
                    _ = linux.close(value.leased_fd);
                    self.lease_fd_received = true;
                },
                .finished => self.finished += 1,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

pub const SessionCommand = enum { enable, disable };

pub const Fixture = struct {
    const AtomicRequest = struct { crtc: u32 = 0 };
    const PendingFlip = struct { userdata: ?*anyopaque = null, crtc: u32 = 0 };

    session_fd: linux.fd_t,
    drm_fd: linux.fd_t,
    hotplug_fd: linux.fd_t,
    hotplug_pending: bool = false,
    callback: ?*ouro.backend_platform.CallbackContext = null,
    command: SessionCommand = .enable,
    bo_bytes: [12][32]u8 align(4) = .{[_]u8{0} ** 32} ** 12,
    dumb_bytes: [12][std.heap.page_size_min]u8 align(std.heap.page_size_min) =
        .{[_]u8{0} ** std.heap.page_size_min} ** 12,
    dumb_count: usize = 0,
    bo_count: usize = 0,
    bo_destroyed: usize = 0,
    output_bo_destroyed: usize = 0,
    framebuffer_removed: usize = 0,
    framebuffer_removal_before_bo: bool = false,
    requests: [12]AtomicRequest = .{AtomicRequest{}} ** 12,
    request_count: usize = 0,
    pending_flips: [4]PendingFlip = .{PendingFlip{}} ** 4,
    flip_head: usize = 0,
    flip_len: usize = 0,
    flip_batch_limit: ?usize = null,
    page_flips: usize = 0,
    device_closes: usize = 0,
    seat_closes: usize = 0,
    request_destroyed: usize = 0,
    fail_page_flip_crtc: ?u32 = null,
    gbm_destroyed: usize = 0,
    imported_bos: usize = 0,
    import_attempts: usize = 0,
    fail_imports: bool = false,
    vrr_supported: bool = false,
    read_maps: usize = 0,
    unmaps: usize = 0,
    discover_cards: bool = true,
    first_desktop: bool = true,
    first_mode_width: u16 = 3,
    second_desktop: bool = false,
    second_mode_width: u16 = 3,
    change_second_mode_after_read: bool = false,
    third_connector: bool = false,
    lease_objects: [6]u32 = undefined,
    lease_object_count: usize = 0,
    lease_create_count: usize = 0,
    lease_revoke_count: usize = 0,
    lease_active: bool = false,
    gamma_original: [6]u16 = .{ 1, 2, 3, 4, 5, 6 },
    gamma_current: [6]u16 = .{ 1, 2, 3, 4, 5, 6 },
    gamma_gets: usize = 0,
    gamma_sets: usize = 0,
    gamma_crtc: u32 = 0,
    fail_create_bo_at: ?usize = null,

    pub fn init() !Fixture {
        const session_fd = try eventFd();
        errdefer _ = linux.close(session_fd);
        const drm_fd = try eventFd();
        errdefer _ = linux.close(drm_fd);
        return .{ .session_fd = session_fd, .drm_fd = drm_fd, .hotplug_fd = try eventFd() };
    }

    pub fn deinit(self: *Fixture) void {
        if (self.session_fd >= 0) _ = linux.close(self.session_fd);
        if (self.drm_fd >= 0) _ = linux.close(self.drm_fd);
        if (self.hotplug_fd >= 0) _ = linux.close(self.hotplug_fd);
    }

    pub fn signalSession(self: *Fixture, command: SessionCommand) !void {
        self.command = command;
        try signalFd(self.session_fd);
    }

    pub fn platforms(self: *Fixture) Coordinator.Platforms {
        return .{
            .session = .{ .context = self, .vtable = &session_vtable },
            .drm = .{ .context = self, .vtable = &drm_vtable },
            .gamma = .{ .context = self, .size_fn = gammaSize, .get_fn = gammaGet, .set_fn = gammaSet },
            .output = .{
                .gbm = .{ .context = self, .vtable = &gbm_vtable },
                .framebuffer = .{ .context = self, .vtable = &framebuffer_vtable },
                .atomic = .{ .context = self, .vtable = &atomic_vtable },
            },
        };
    }

    pub fn platformsWithHotplug(self: *Fixture) Coordinator.Platforms {
        var result = self.platforms();
        result.hotplug = .{ .context = self, .vtable = &hotplug_vtable };
        return result;
    }

    pub fn signalHotplug(self: *Fixture) !void {
        self.hotplug_pending = true;
        try signalFd(self.hotplug_fd);
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
        .open_lease_device = openLeaseDevice,
        .create_lease = createLease,
        .revoke_lease = revokeLease,
        .list_lessees = listLessees,
    };
    const hotplug_vtable: ouro.drm_hotplug.Platform.VTable = .{
        .create = hotplugCreate,
        .destroy = hotplugDestroy,
        .get_fd = hotplugGetFd,
        .next_event = hotplugNextEvent,
    };
    const gbm_vtable: ouro.gbm.Platform.VTable = .{
        .create_device = createGbm,
        .destroy_device = destroyGbm,
        .create_bo = createBo,
        .import_bo = importBo,
        .destroy_bo = destroyBo,
        .metadata = metadata,
        .export_plane_fd = exportPlane,
        .map = mapBo,
        .unmap = unmapBo,
    };
    const framebuffer_vtable: ouro.drm_framebuffer.Platform.VTable = .{
        .add = addFb,
        .remove = removeFb,
        .create_dumb = createDumb,
        .destroy_dumb = destroyDumb,
    };
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

    fn openLeaseDevice(_: *anyopaque, _: [:0]const u8) !std.posix.fd_t {
        return eventFd();
    }
    fn createLease(
        context: *anyopaque,
        _: std.posix.fd_t,
        objects: []const u32,
    ) !ouro.drm_platform.LeaseResult {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.lease_create_count += 1;
        self.lease_object_count = objects.len;
        @memcpy(self.lease_objects[0..objects.len], objects);
        self.lease_active = true;
        return .{ .fd = try eventFd(), .lessee_id = @intCast(self.lease_create_count) };
    }
    fn revokeLease(context: *anyopaque, _: std.posix.fd_t, lessee_id: u32) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        try std.testing.expect(lessee_id != 0);
        self.lease_revoke_count += 1;
        self.lease_active = false;
    }
    fn listLessees(context: *anyopaque, _: std.posix.fd_t, storage: []u32) !usize {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (!self.lease_active) return 0;
        storage[0] = @intCast(self.lease_create_count);
        return 1;
    }
    fn gammaSize(context: *anyopaque, _: linux.fd_t, crtc: u32) !u32 {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.gamma_crtc = crtc;
        return 2;
    }
    fn gammaGet(context: *anyopaque, _: linux.fd_t, crtc: u32, r: []u16, g: []u16, b: []u16) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.gamma_crtc = crtc;
        @memcpy(r, self.gamma_original[0..2]);
        @memcpy(g, self.gamma_original[2..4]);
        @memcpy(b, self.gamma_original[4..6]);
        self.gamma_gets += 1;
    }
    fn gammaSet(context: *anyopaque, _: linux.fd_t, crtc: u32, r: []const u16, g: []const u16, b: []const u16) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.gamma_crtc = crtc;
        @memcpy(self.gamma_current[0..2], r);
        @memcpy(self.gamma_current[2..4], g);
        @memcpy(self.gamma_current[4..6], b);
        self.gamma_sets += 1;
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
        out.connectors[0] = .{ .id = 10, .connector_type = 1, .connector_type_id = 1, .connected = true, .desktop = self.first_desktop, .width_mm = 1, .height_mm = 1, .encoder_id = 20, .mode_start = 0, .mode_count = 1, .encoder_start = 0, .encoder_count = 1, .properties = .{ .crtc_id = 1, .vrr_capable = self.vrr_supported } };
        out.modes[0] = .{ .clock = 1, .hdisplay = self.first_mode_width, .hsync_start = self.first_mode_width, .hsync_end = self.first_mode_width, .htotal = self.first_mode_width, .hskew = 0, .vdisplay = 2, .vsync_start = 2, .vsync_end = 2, .vtotal = 2, .vscan = 0, .vrefresh = 60, .flags = 0, .mode_type = 0 };
        out.connector_encoders[0] = 20;
        out.encoders[0] = .{ .id = 20, .crtc_id = 30, .possible_crtcs = 1 };
        out.crtcs[0] = .{ .id = 30, .index = 0, .properties = .{ .active = 2, .mode_id = 3, .vrr_enabled = if (self.vrr_supported) 15 else 0 } };
        out.planes[0] = .{ .id = 40, .possible_crtcs = 1, .plane_type_value = 1, .format_start = 0, .format_count = 1, .properties = .{ .plane_type = 4, .fb_id = 5, .crtc_id = 6, .src_x = 7, .src_y = 8, .src_w = 9, .src_h = 10, .crtc_x = 11, .crtc_y = 12, .crtc_w = 13, .crtc_h = 14 } };
        out.formats[0] = .{ .fourcc = ouro.gbm.format_xrgb8888, .modifier = ouro.gbm.modifier_linear };
        out.connectors[1] = .{ .id = 11, .connector_type = 1, .connector_type_id = 2, .connected = true, .desktop = self.second_desktop, .width_mm = 2, .height_mm = 2, .encoder_id = 21, .mode_start = 1, .mode_count = 1, .encoder_start = 1, .encoder_count = 1, .properties = .{ .crtc_id = 1, .vrr_capable = self.vrr_supported } };
        out.modes[1] = out.modes[0];
        out.modes[1].hdisplay = self.second_mode_width;
        out.modes[1].hsync_start = self.second_mode_width;
        out.modes[1].hsync_end = self.second_mode_width;
        out.modes[1].htotal = self.second_mode_width;
        out.connector_encoders[1] = 21;
        out.encoders[1] = .{ .id = 21, .crtc_id = 31, .possible_crtcs = 2 };
        out.crtcs[1] = .{ .id = 31, .index = 1, .properties = .{ .active = 2, .mode_id = 3, .vrr_enabled = if (self.vrr_supported) 16 else 0 } };
        out.planes[1] = .{ .id = 41, .possible_crtcs = 2, .plane_type_value = 1, .format_start = 1, .format_count = 1, .properties = .{ .plane_type = 4, .fb_id = 5, .crtc_id = 6, .src_x = 7, .src_y = 8, .src_w = 9, .src_h = 10, .crtc_x = 11, .crtc_y = 12, .crtc_w = 13, .crtc_h = 14 } };
        out.formats[1] = out.formats[0];
        if (self.third_connector) {
            out.connectors[2] = .{ .id = 12, .connector_type = 1, .connector_type_id = 3, .connected = true, .desktop = false, .width_mm = 3, .height_mm = 3, .encoder_id = 22, .mode_start = 2, .mode_count = 1, .encoder_start = 2, .encoder_count = 1, .properties = .{ .crtc_id = 1 } };
            out.modes[2] = out.modes[0];
            out.connector_encoders[2] = 22;
            out.encoders[2] = .{ .id = 22, .crtc_id = 32, .possible_crtcs = 4 };
            out.crtcs[2] = .{ .id = 32, .index = 2, .properties = .{ .active = 2, .mode_id = 3 } };
            out.planes[2] = .{ .id = 42, .possible_crtcs = 4, .plane_type_value = 1, .format_start = 2, .format_count = 1, .properties = .{ .plane_type = 4, .fb_id = 5, .crtc_id = 6, .src_x = 7, .src_y = 8, .src_w = 9, .src_h = 10, .crtc_x = 11, .crtc_y = 12, .crtc_w = 13, .crtc_h = 14 } };
            out.formats[2] = out.formats[0];
        }
        const topology_count: usize = if (self.third_connector) 3 else 2;
        out.connector_count = topology_count;
        out.mode_count = topology_count;
        out.connector_encoder_count = topology_count;
        out.encoder_count = topology_count;
        out.crtc_count = topology_count;
        out.plane_count = topology_count;
        out.format_count = topology_count;
        if (self.change_second_mode_after_read) {
            self.second_mode_width = 4;
            self.change_second_mode_after_read = false;
        }
    }

    fn createGbm(context: *anyopaque, _: linux.fd_t) !ouro.gbm.Device {
        return context;
    }

    fn hotplugCreate(context: *anyopaque) !*anyopaque {
        return context;
    }
    fn hotplugDestroy(_: *anyopaque, _: *anyopaque) void {}
    fn hotplugGetFd(_: *anyopaque, context: *anyopaque) !linux.fd_t {
        return (@as(*Fixture, @ptrCast(@alignCast(context)))).hotplug_fd;
    }
    fn hotplugNextEvent(_: *anyopaque, context: *anyopaque) !?ouro.drm_hotplug.Event {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (!self.hotplug_pending) return null;
        self.hotplug_pending = false;
        try consumeFd(self.hotplug_fd);
        return .change;
    }
    fn destroyGbm(context: *anyopaque, _: ouro.gbm.Device) void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).gbm_destroyed += 1;
    }
    fn createBo(context: *anyopaque, _: ouro.gbm.Device, _: ouro.gbm.Allocation) !ouro.gbm.Bo {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.fail_create_bo_at == self.bo_count) {
            self.fail_create_bo_at = null;
            self.bo_count += 1;
            return error.CreateBoFailed;
        }
        const bo = &self.bo_bytes[self.bo_count];
        self.bo_count += 1;
        return @ptrCast(bo);
    }

    fn importBo(context: *anyopaque, device: ouro.gbm.Device, import: ouro.gbm.Import, _: ouro.gbm.ImportUsage) !ouro.gbm.Bo {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.import_attempts += 1;
        if (self.fail_imports) return error.ImportBoFailed;
        const bo = try createBo(context, device, .{
            .width = import.width,
            .height = import.height,
            .format = import.format,
            .modifier = import.modifier,
            .explicit_modifier = true,
        });
        @memcpy(@as(*[32]u8, @ptrCast(@alignCast(bo)))[0..pixels.len], &pixels);
        self.imported_bos += 1;
        return bo;
    }
    fn destroyBo(context: *anyopaque, bo: ouro.gbm.Bo) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.bo_destroyed += 1;
        const address = @intFromPtr(bo);
        const output_start = @intFromPtr(&self.bo_bytes[0]);
        const output_end = @intFromPtr(&self.bo_bytes[2]);
        if (address >= output_start and address < output_end)
            self.output_bo_destroyed += 1;
    }
    fn metadata(_: *anyopaque, bo: ouro.gbm.Bo) !ouro.gbm.Metadata {
        return .{ .width = 3, .height = 2, .format = ouro.gbm.format_xrgb8888, .modifier = ouro.gbm.modifier_linear, .plane_count = 1, .handles = .{ @truncate(@intFromPtr(bo)), 0, 0, 0 }, .strides = .{ 16, 0, 0, 0 } };
    }
    fn exportPlane(_: *anyopaque, _: ouro.gbm.Bo, _: u8) !linux.fd_t {
        return error.UnexpectedExport;
    }
    fn mapBo(context: *anyopaque, bo: ouro.gbm.Bo, access: ouro.gbm.MapAccess) !ouro.gbm.Mapping {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (access == .read) self.read_maps += 1;
        return .{ .data = @ptrCast(bo), .stride = 16, .token = bo };
    }
    fn unmapBo(context: *anyopaque, _: ouro.gbm.Bo, _: ouro.gbm.MapToken) void {
        (@as(*Fixture, @ptrCast(@alignCast(context)))).unmaps += 1;
    }
    fn addFb(_: *anyopaque, _: linux.fd_t, meta: ouro.gbm.Metadata) !u32 {
        return meta.handles[0];
    }
    fn removeFb(context: *anyopaque, _: linux.fd_t, _: u32) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.framebuffer_removed == 0)
            self.framebuffer_removal_before_bo = self.output_bo_destroyed == 0;
        self.framebuffer_removed += 1;
    }
    fn createDumb(
        context: *anyopaque,
        _: linux.fd_t,
        _: u32,
        _: u32,
        _: u32,
    ) !ouro.drm_framebuffer.DumbBuffer {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.fail_create_bo_at == self.bo_count) {
            self.fail_create_bo_at = null;
            self.bo_count += 1;
            return error.CreateDumbBufferFailed;
        }
        const index = self.dumb_count;
        self.dumb_count += 1;
        self.bo_count += 1;
        return .{
            .handle = @intCast(index + 1),
            .stride = 16,
            .bytes = &self.dumb_bytes[index],
        };
    }
    fn destroyDumb(context: *anyopaque, _: linux.fd_t, _: ouro.drm_framebuffer.DumbBuffer) void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        self.bo_destroyed += 1;
        self.output_bo_destroyed += 1;
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
    fn addProperty(_: *anyopaque, request: ouro.drm_atomic.Request, object: u32, _: u32, _: u64) !void {
        if (object == 30 or object == 31)
            (@as(*AtomicRequest, @ptrCast(@alignCast(request)))).crtc = object;
    }
    fn atomicCommit(context: *anyopaque, _: linux.fd_t, request: ouro.drm_atomic.Request, flags: ouro.drm_atomic.CommitFlags, userdata: ?*anyopaque) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (flags.page_flip_event) {
            const atomic_request: *AtomicRequest = @ptrCast(@alignCast(request));
            if (atomic_request.crtc == 0) return error.MissingCrtc;
            if (self.fail_page_flip_crtc == atomic_request.crtc) {
                self.fail_page_flip_crtc = null;
                return error.AtomicCommitFailed;
            }
            if (self.flip_len == self.pending_flips.len) return error.FlipQueueFull;
            const index = (self.flip_head + self.flip_len) % self.pending_flips.len;
            self.pending_flips[index] = .{
                .userdata = userdata,
                .crtc = atomic_request.crtc,
            };
            self.flip_len += 1;
            try signalFd(self.drm_fd);
        }
    }
    fn handleEvents(context: *anyopaque, _: []const u8, callback: ouro.drm_atomic.FlipCallback) !void {
        const self: *Fixture = @ptrCast(@alignCast(context));
        if (self.flip_len == 0) return;
        var handled: usize = 0;
        while (self.flip_len != 0) {
            const flip = self.pending_flips[self.flip_head];
            const userdata = flip.userdata orelse return error.MissingFlip;
            if (flip.crtc == 0) return error.MissingCrtc;
            self.pending_flips[self.flip_head] = .{};
            self.flip_head = (self.flip_head + 1) % self.pending_flips.len;
            self.flip_len -= 1;
            self.page_flips += 1;
            callback(userdata, 1, 2, 3000, flip.crtc);
            handled += 1;
            if (self.flip_batch_limit) |limit| if (handled == limit) break;
        }
        if (self.flip_len != 0) try signalFd(self.drm_fd);
    }
};

pub fn coordinatorConfig() Coordinator.Config {
    return .{ .router_capacity = 12, .timer_capacity = 6, .device_capacity = 1, .shm = .{ .limits = .{ .max_pool_bytes = 4096 }, .pool_capacity = 1, .buffer_capacity = 1, .formats = &shm_formats }, .surface = .{ .surface_capacity = 1, .region_capacity = 1, .viewport_capacity = 1, .presentation_resource_capacity = 1, .presentation_feedback_capacity = 2, .region_operation_capacity = 1, .frame_callback_capacity = 1, .release_callback_capacity = 1, .content_update_capacity = 1, .dependency_capacity = 1, .attachment_capacity = 1, .copy_capacity = 1, .max_copy_bytes = pixels.len }, .drm = .{ .card_capacity = 1, .connector_capacity = 3, .mode_capacity = 3, .connector_encoder_capacity = 3, .encoder_capacity = 3, .crtc_capacity = 3, .plane_capacity = 3, .format_capacity = 3, .event_capacity = 4 }, .output = .{ .output_id = .{ .index = 0, .generation = 1 }, .scheduler = .{ .refresh_ns = 4 * std.time.ns_per_ms, .render_budget_ns = std.time.ns_per_ms }, .renderer = .pixman, .image_count = 2, .max_samples = 2, .max_source_bytes = pixels.len, .max_source_width = 3, .max_source_height = 2, .kms = .{ .event_capacity = 2 } } };
}
pub fn compositorConfig() Compositor.Config {
    return .{ .ring = .{ .entries = 32, .flags = 0 }, .reactor = clientReactorConfig(), .runtime = .{ .actor = .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 }, .object_capacity = 32, .object_quota = 32, .buckets_per_client = 32, .max_globals = 62, .registry_capacity = 1 } };
}
pub fn clientReactorConfig() wayring.io_uring.Config {
    return .{ .receive_buffer_size = 4096, .receive_buffer_count = 4, .receive_control_capacity = 256, .fragment_block_size = 256, .fragment_block_count = 4, .transmit_block_size = 512, .transmit_block_count = 8, .descriptor_count = 4, .send_descriptor_capacity = 2 };
}
fn drainClient(reactor: *wayring.io_uring.Reactor, driver: *ClientDriver, handler: anytype) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0) 0 else try reactor.ring.copy_cqes(&completions, 0);
    const progress = try driver.dispatch(completions[0..count], handler);
    if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    return progress;
}
fn submitClient(reactor: *wayring.io_uring.Reactor, driver: *ClientDriver, handler: anytype) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}
pub fn drainServer(root: *Compositor, coordinator: *Coordinator, loop: *Loop) !void {
    var wayring_drained = false;
    for (0..128) |_| {
        const progress = try loop.turn(coordinator);
        wayring_drained = progress.wayring.shutdown_complete;
        if (wayring_drained and coordinator.backendDrainComplete()) return;
        if (root.ring.cq_ready() == 0) try waitReady(&root.ring);
    }
    return error.DrainTimeout;
}
fn physicalOutputsSettled(coordinator: *Coordinator) bool {
    for (coordinator.physical_outputs[0..coordinator.physical_output_count]) |physical|
        if (physical.damage_applied != physical.damage_requested or
            (physical.kms_output != null and physical.kms_output.?.in_flight_frame != null))
            return false;
    return true;
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
