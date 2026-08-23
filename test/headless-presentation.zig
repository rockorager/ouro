const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");

const linux = std.os.linux;
const ClientConnection = wayring.client.Connection(protocol);
const ClientDriver = wayring.client.Driver(protocol);
const ClientCore = wayring.client.Core(protocol);
const ServerCore = wayring.server.Core(protocol);
const Compositor = ouro.compositor.Compositor(protocol);
const Loop = ouro.loop.Loop(protocol);
const Shm = wayring.server.Shm(protocol);
const Adapter = ouro.core_surface.Adapter(protocol);
const PresentationQueue = ouro.presentation.Queue(Imported);
const Headless = ouro.headless_output.Scheduler(PresentationQueue.Token);

const pixel_bytes = [_]u8{
    0x04, 0x03, 0x02, 0x01, 0x14, 0x13, 0x12, 0x11,
    0x24, 0x23, 0x22, 0x21, 0xaa, 0xbb, 0xcc, 0xdd,
    0x34, 0x33, 0x32, 0x31, 0x44, 0x43, 0x42, 0x41,
    0x54, 0x53, 0x52, 0x51, 0xee, 0xff, 0x00, 0x99,
};

const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

const Imported = struct {
    byte_len: usize,
    first_pixel: u32,
};

test "generated client presents ordinary SHM through the integrated headless runtime" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_storage,
        "/tmp/ouro-r7-{d}.sock",
        .{linux.getpid()},
    );
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    const listener = try wayring.unix_socket.listen(path, 1);
    const root = try Compositor.create(allocator, listener, .{
        .ring = .{ .entries = 32, .flags = 0 },
        .reactor = .{
            .max_connections = 1,
            .receive_buffer_size = 4096,
            .receive_buffer_count = 4,
            .receive_control_capacity = 256,
            .fragment_block_size = 256,
            .fragment_block_count = 4,
            .transmit_block_size = 512,
            .transmit_block_count = 8,
            .descriptor_count = 4,
            .send_descriptor_capacity = 2,
        },
        .runtime = .{
            .actor = .{
                .received_fd_budget = 1,
                .transmit_byte_budget = 4096,
                .transmit_fd_budget = 1,
            },
            .object_capacity = 16,
            .object_quota = 16,
            .buckets_per_client = 16,
            .max_globals = 2,
            .registry_capacity = 1,
        },
    });
    errdefer root.deinit() catch {};

    const harness = try allocator.create(Harness);
    defer allocator.destroy(harness);
    harness.root = root;
    harness.imported_disposals = 0;
    harness.copy_completions = 0;
    harness.applied_count = 0;
    harness.render_count = 0;
    harness.presented_count = 0;
    harness.frame_queued_count = 0;
    harness.release_queued_count = 0;
    harness.copy_was_bounded_and_blocking = false;
    harness.early_resources_destroyed_while_copy_pending = false;
    harness.lease_held_until_presented = false;
    harness.duplicate_was_inert = false;
    harness.duplicate_timer_was_inert = false;
    harness.pending_content = null;
    harness.presentation = null;
    harness.copy_outcome = null;
    harness.router = try ouro.completion.Router.init(allocator, 4);
    errdefer harness.router.deinit(allocator);
    harness.timers = try ouro.timer.Timers.init(allocator, 2);
    errdefer harness.timers.deinit(allocator);
    harness.shm = try Shm.init(allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &shm_formats,
    });
    errdefer harness.shm.deinit(allocator);
    harness.adapter = try Adapter.init(
        allocator,
        &harness.shm,
        &root.ring,
        &harness.router,
        .{
            .surface_capacity = 1,
            .region_capacity = 1,
            .region_operation_capacity = 1,
            .frame_callback_capacity = 1,
            .release_callback_capacity = 1,
            .content_update_capacity = 1,
            .dependency_capacity = 1,
            .attachment_capacity = 1,
            .copy_capacity = 1,
            .max_copy_bytes = pixel_bytes.len,
        },
    );
    errdefer harness.adapter.deinit();
    harness.presentations = try PresentationQueue.init(
        allocator,
        1,
        &harness.imported_disposals,
        disposeImported,
    );
    errdefer harness.presentations.deinit(allocator);
    harness.headless = try Headless.init(
        allocator,
        .{ .index = 0, .generation = 1 },
        .{
            .phase_ns = 0,
            .refresh_ns = 4 * std.time.ns_per_ms,
            .render_budget_ns = std.time.ns_per_ms,
        },
        1,
    );
    errdefer harness.headless.deinit(allocator);
    harness.handler = .{ .harness = harness };

    _ = try harness.shm.install(&root.runtime);
    try std.testing.expectEqual(
        wayring.server.Runtime(protocol).PublishResult.complete,
        try root.runtime.publishNext(),
    );
    _ = try harness.adapter.install(&root.runtime);
    harness.loop = try Loop.init(
        allocator,
        root,
        &harness.router,
        &harness.timers,
        &harness.handler,
        .{ .completion_batch = 16 },
    );
    harness.handler.loop = &harness.loop;
    errdefer harness.loop.deinit();

    var client_reactor: wayring.io_uring.Reactor = undefined;
    try client_reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, .{
        .max_connections = 1,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 256,
        .fragment_block_size = 256,
        .fragment_block_count = 2,
        .transmit_block_size = 512,
        .transmit_block_count = 6,
        .descriptor_count = 3,
        .send_descriptor_capacity = 1,
    });
    defer client_reactor.deinit(allocator);
    var client = try ClientConnection.attach(
        allocator,
        &client_reactor,
        try wayring.unix_socket.connect(path),
        .{
            .received_fd_budget = 1,
            .transmit_byte_budget = 4096,
            .transmit_fd_budget = 1,
        },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    var client_driver = ClientDriver.init(&client);
    const client_actor = try client.actor();
    const registry = try ClientCore.getRegistry(
        &client.objects,
        &client_actor.transmit,
        null,
    );
    var client_handler: ClientHandler = .{
        .harness = harness,
        .objects = &client.objects,
        .queue = &client_actor.transmit,
        .registry = registry,
    };
    _ = try client_driver.schedule();
    _ = try client_driver.prepare(&client_handler);
    _ = try client_reactor.ring.submit();

    // The first turn performs the Loop's sole submission and publishes the
    // initial accept SQE. Every subsequent wait occurs outside dispatch.
    _ = try harness.loop.turn(&harness.handler);
    var client_progress: ClientDriver.Progress = .{};
    var callbacks_complete = false;
    for (0..128) |_| {
        client_progress = try drainClient(
            &client_reactor,
            &client_driver,
            &client_handler,
        );
        callbacks_complete = client_handler.frame_done_count == 1 and
            client_handler.release_done_count == 1 and
            client_handler.frame_delete_count == 1 and
            client_handler.release_delete_count == 1;
        if (callbacks_complete) break;

        if (root.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
        _ = try harness.loop.turn(&harness.handler);
    }
    try std.testing.expect(callbacks_complete);

    try std.testing.expectEqual(@as(usize, 1), harness.copy_completions);
    try std.testing.expectEqual(@as(usize, 1), harness.applied_count);
    try std.testing.expectEqual(@as(usize, 1), harness.render_count);
    try std.testing.expectEqual(@as(usize, 1), harness.presented_count);
    try std.testing.expectEqual(@as(usize, 1), harness.frame_queued_count);
    try std.testing.expectEqual(@as(usize, 1), harness.release_queued_count);
    try std.testing.expectEqual(@as(usize, 1), harness.imported_disposals);
    try std.testing.expect(harness.copy_was_bounded_and_blocking);
    try std.testing.expect(harness.early_resources_destroyed_while_copy_pending);
    try std.testing.expect(harness.lease_held_until_presented);
    try std.testing.expect(harness.duplicate_was_inert);
    try std.testing.expect(harness.duplicate_timer_was_inert);
    try std.testing.expectEqual(@as(usize, 2), client_handler.format_count);
    try std.testing.expectEqualSlices(u8, &pixel_bytes, &harness.copied_bytes);
    try std.testing.expectEqual(@as(usize, 0), harness.shm.store.active_buffers);
    try std.testing.expectEqual(@as(usize, 0), harness.shm.store.active_pins);
    try std.testing.expectEqual(@as(usize, 0), harness.shm.store.active_pools);
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.imports.available());
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.frame_pool.available());
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.release_pool.available());
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.region_pool.available());
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.scheduler.availableNodes());
    try std.testing.expectEqual(@as(usize, 1), harness.adapter.scheduler.availableEdges());
    try std.testing.expectEqual(@as(usize, 1), harness.presentations.available());
    try std.testing.expectEqual(@as(usize, 2), harness.timers.available());
    try std.testing.expectEqual(@as(usize, 4), harness.router.available());
    try std.testing.expect(client.objects.namespace.resolve(client_handler.frame.?) == null);
    try std.testing.expect(client.objects.namespace.resolve(client_handler.release.?) == null);
    try std.testing.expect(!client.objects.ids.isActive(client_handler.frame.?.id));
    try std.testing.expect(!client.objects.ids.isActive(client_handler.release.?.id));

    try harness.loop.requestShutdown();
    _ = try client.prepareClose();
    _ = try client_driver.schedule();
    client_progress = try client_driver.prepare(&client_handler);
    _ = try client_reactor.ring.submit();

    var shutdown_complete = false;
    for (0..128) |_| {
        client_progress = try drainClient(
            &client_reactor,
            &client_driver,
            &client_handler,
        );
        const progress = try harness.loop.turn(&harness.handler);
        shutdown_complete = progress.wayring.shutdown_complete;
        if (shutdown_complete and client_progress.quiescent) break;
        if ((!shutdown_complete or !client_progress.quiescent) and
            root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(shutdown_complete);
    try std.testing.expect(client_progress.quiescent);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.connected_count);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.disconnected_count);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.buffer_removals);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.pool_removals);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.surface_removals);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.frame_removals);
    try std.testing.expectEqual(@as(usize, 1), harness.handler.release_removals);

    try client.deinit(allocator);
    harness.loop.deinit();
    harness.headless.deinit(allocator);
    harness.presentations.deinit(allocator);
    harness.adapter.deinit();
    harness.shm.deinit(allocator);
    harness.timers.deinit(allocator);
    harness.router.deinit(allocator);
    try root.deinit();
}

const Harness = struct {
    root: *Compositor,
    router: ouro.completion.Router,
    timers: ouro.timer.Timers,
    shm: Shm,
    adapter: Adapter,
    presentations: PresentationQueue,
    headless: Headless,
    loop: Loop,
    handler: ServerHandler,
    imported_disposals: usize = 0,
    copy_completions: usize = 0,
    applied_count: usize = 0,
    render_count: usize = 0,
    presented_count: usize = 0,
    frame_queued_count: usize = 0,
    release_queued_count: usize = 0,
    copy_was_bounded_and_blocking: bool = false,
    early_resources_destroyed_while_copy_pending: bool = false,
    lease_held_until_presented: bool = false,
    duplicate_was_inert: bool = false,
    duplicate_timer_was_inert: bool = false,
    copied_bytes: [pixel_bytes.len]u8 = undefined,
    pending_content: ?Adapter.Content = null,
    presentation: ?PresentationQueue.Token = null,
    copy_outcome: ?ouro.loop.OuroCompletion = null,
};

const ServerHandler = struct {
    harness: *Harness,
    loop: ?*Loop = null,
    peer: ?wayring.io_uring.Peer = null,
    surface_id: u32 = 0,
    surface: ?wayring.objects.Handle = null,
    frame_id: u32 = 0,
    release_id: u32 = 0,
    connected_count: usize = 0,
    disconnected_count: usize = 0,
    buffer_removals: usize = 0,
    pool_removals: usize = 0,
    surface_removals: usize = 0,
    frame_removals: usize = 0,
    release_removals: usize = 0,

    pub fn connected(handler: *ServerHandler, peer: wayring.io_uring.Peer) void {
        handler.peer = peer;
        handler.connected_count += 1;
        const objects = handler.harness.root.runtime.clients.get(peer) catch unreachable;
        objects.setRemovalHook(.{
            .context = handler,
            .notify = resourceRemoved,
        });
    }

    pub fn disconnected(handler: *ServerHandler, _: wayring.io_uring.Peer) void {
        handler.disconnected_count += 1;
    }

    pub fn protocolError(
        _: *ServerHandler,
        _: wayring.io_uring.Peer,
        failure: ServerCore.RequestFailure,
    ) void {
        std.debug.panic("unexpected protocol error: {s}", .{@errorName(failure.cause)});
    }

    pub fn request(
        handler: *ServerHandler,
        peer: wayring.io_uring.Peer,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const harness = handler.harness;
        const actor = try harness.root.runtime.clients.reactor.getActor(peer);
        const objects = try harness.root.runtime.clients.get(peer);
        const interface = target.object.interface;
        if (interface == &ServerCore.Display.info) {
            switch (try harness.root.runtime.decodeDisplayRequest(peer, message, fds, null)) {
                .get_registry => {},
                .sync => |callback| try ServerCore.completeSync(
                    objects,
                    &actor.transmit,
                    callback,
                    0,
                ),
            }
            return .continue_dispatch;
        }
        if (interface == &ServerCore.Registry.info) {
            const registry = objects.namespace.lookupHandle(message.header.object_id) orelse
                return error.UnknownRegistry;
            const request_value = try ServerCore.decodeRegistryRequest(
                objects,
                registry,
                message,
                fds,
            );
            _ = try harness.root.runtime.bindGlobal(peer, request_value);
            return .continue_dispatch;
        }
        if (try harness.shm.request(actor, objects, target, message, fds)) |control| {
            if (harness.adapter.pendingShmCopies() == 1 and
                harness.shm.store.active_buffers == 0)
            {
                var applied: [1]Adapter.Applied = undefined;
                harness.early_resources_destroyed_while_copy_pending =
                    harness.shm.store.active_pins == 1 and
                    harness.shm.store.active_pools == 1 and
                    (try harness.adapter.tryApply(handler.surface.?, &applied)).len == 0;
            }
            return control;
        }
        if (try harness.adapter.request(peer, target, message, fds)) |control| {
            if (handler.surface == null and handler.surface_id != 0)
                handler.surface = objects.namespace.lookupHandle(handler.surface_id);
            if (harness.adapter.pendingShmCopies() == 1 and handler.surface != null) {
                var applied: [1]Adapter.Applied = undefined;
                const blocked = try harness.adapter.tryApply(handler.surface.?, &applied);
                handler.harness.copy_was_bounded_and_blocking = blocked.len == 0 and
                    harness.router.available() == 3 and
                    harness.adapter.imports.available() == 0 and
                    harness.shm.store.active_buffers == 1 and
                    harness.shm.store.active_pins == 1;
            }
            return control;
        }
        return error.UnexpectedRequest;
    }

    pub fn completions(
        handler: *ServerHandler,
        timer_outcomes: []const ouro.loop.TimerOutcome,
        ouro_outcomes: []const ouro.loop.OuroCompletion,
    ) !void {
        const harness = handler.harness;
        for (ouro_outcomes) |outcome| {
            try std.testing.expectEqual(ouro.completion.Kind.copy, outcome.token.kind);
            try std.testing.expectEqual(@as(usize, 1), harness.adapter.pendingShmCopies());
            harness.copy_outcome = outcome;
            try harness.adapter.completeShmCopy(outcome);
            harness.copy_completions += 1;
            try handler.applyCopiedCommit();
        }
        for (timer_outcomes) |outcome| {
            const event = try harness.headless.timerEvent(
                outcome.handle,
                outcome.event,
                try monotonicNs(),
            ) orelse continue;
            switch (event) {
                .render => |render| try handler.renderImmediately(render.frame),
                .frame => |frame| {
                    try handler.present(frame);
                    harness.duplicate_timer_was_inert = (try harness.headless.timerEvent(
                        outcome.handle,
                        outcome.event,
                        try monotonicNs(),
                    )) == null and harness.presented_count == 1;
                },
            }
        }
        try handler.armRequestedTimer();
    }

    fn applyCopiedCommit(handler: *ServerHandler) !void {
        const harness = handler.harness;
        var applied_storage: [1]Adapter.Applied = undefined;
        const applied = try harness.adapter.tryApply(handler.surface.?, &applied_storage);
        try std.testing.expectEqual(@as(usize, 1), applied.len);
        harness.applied_count += 1;
        var content = applied[0].payload;
        errdefer content.deinit();
        const lease = content.attachment_lease orelse return error.MissingLease;
        const bytes = try harness.adapter.shmBytes(lease);
        try std.testing.expectEqualSlices(u8, &pixel_bytes, bytes);
        @memcpy(&harness.copied_bytes, bytes);
        const imported: Imported = .{
            .byte_len = bytes.len,
            .first_pixel = std.mem.readInt(u32, bytes[0..4], .little),
        };
        harness.presentation = try harness.presentations.admit(
            imported,
            &content.attachment_lease,
            &content.release_callbacks,
        );
        harness.pending_content = content;
        harness.lease_held_until_presented = harness.presentations.available() == 0 and
            harness.adapter.imports.available() == 0 and
            harness.imported_disposals == 0;
        var no_more: [1]Adapter.Applied = undefined;
        try std.testing.expectEqual(
            @as(usize, 0),
            (try harness.adapter.tryApply(handler.surface.?, &no_more)).len,
        );
        try harness.headless.request(.damage, try monotonicNs());
    }

    fn renderImmediately(
        handler: *ServerHandler,
        frame: ouro.headless_output.FrameId,
    ) !void {
        const harness = handler.harness;
        harness.render_count += 1;
        const sample = [_]ouro.headless_output.Sample(PresentationQueue.Token){.{
            .surface = .{
                .index = handler.surface.?.id,
                .generation = handler.surface.?.generation,
            },
            .presentation = harness.presentation.?,
        }};
        try harness.headless.captureSamples(frame, &sample);
        try std.testing.expect((try harness.headless.renderComplete(
            frame,
            try monotonicNs(),
        )) == null);
    }

    fn present(
        handler: *ServerHandler,
        frame: ouro.headless_output.FrameOutcome(PresentationQueue.Token),
    ) !void {
        const harness = handler.harness;
        try std.testing.expectEqual(ouro.headless_output.Disposition.presented, frame.disposition);
        try std.testing.expect(frame.frame_callbacks_due);
        try std.testing.expectEqual(@as(usize, 1), frame.sampled.len);
        try std.testing.expectEqual(harness.presentation.?, frame.sampled[0].presentation);
        try std.testing.expectEqual(handler.surface.?.id, frame.sampled[0].surface.index);
        try std.testing.expectEqual(@as(usize, 0), harness.adapter.imports.available());
        try std.testing.expectEqual(@as(usize, 0), harness.presentations.available());
        try std.testing.expectEqual(@as(usize, 0), harness.imported_disposals);
        harness.presented_count += 1;

        var content = &(harness.pending_content orelse return error.MissingContent);
        try std.testing.expectEqual(
            @as(usize, 1),
            try harness.adapter.activateFrames(handler.surface.?, content),
        );
        const peer = handler.peer.?;
        const objects = try harness.root.runtime.clients.get(peer);
        const actor = try harness.root.runtime.clients.reactor.getActor(peer);
        try std.testing.expect(try harness.adapter.completeFrameOn(
            objects,
            &actor.transmit,
            handler.surface.?,
            77,
        ));
        try std.testing.expect(!try harness.adapter.completeFrameOn(
            objects,
            &actor.transmit,
            handler.surface.?,
            77,
        ));
        harness.frame_queued_count += 1;
        harness.release_queued_count += try harness.presentations.queueReleases(
            harness.presentation.?,
            handler,
            queueRelease,
        );
        try harness.presentations.finish(harness.presentation.?);
        content.deinit();
        harness.pending_content = null;
        harness.presentation = null;
        _ = try handler.loop.?.driver.schedule(peer);

        try std.testing.expectEqual(@as(usize, 1), harness.imported_disposals);
        try std.testing.expectEqual(@as(usize, 1), harness.adapter.imports.available());
        try std.testing.expectEqual(@as(usize, 1), harness.presentations.available());
        const duplicate = harness.copy_outcome.?;
        try std.testing.expectError(
            error.StaleCopyCompletion,
            harness.adapter.completeShmCopy(duplicate),
        );
        harness.duplicate_was_inert = harness.adapter.pendingShmCopies() == 0 and
            harness.adapter.imports.available() == 1 and
            harness.imported_disposals == 1;
    }

    fn armRequestedTimer(handler: *ServerHandler) !void {
        const harness = handler.harness;
        const now = try monotonicNs();
        const request_value = (try harness.headless.timerRequest(now)) orelse return;
        const handle = try harness.timers.arm(
            &harness.router,
            &harness.root.ring,
            request_value.deadline,
        );
        try harness.headless.timerArmed(request_value, handle, now);
    }

    fn queueRelease(context: ?*anyopaque, callback: wayring.objects.Handle) !void {
        const handler: *ServerHandler = @ptrCast(@alignCast(context.?));
        const peer = handler.peer.?;
        const objects = try handler.harness.root.runtime.clients.get(peer);
        const actor = try handler.harness.root.runtime.clients.reactor.getActor(peer);
        try Adapter.completeReleaseOn(objects, &actor.transmit, callback);
    }

    fn resourceRemoved(
        context: ?*anyopaque,
        handle: wayring.objects.Handle,
        object: wayring.objects.Object,
    ) void {
        const handler: *ServerHandler = @ptrCast(@alignCast(context.?));
        _ = handler.harness.adapter.resourceRemoved(handle, object);
        if (object.interface == &protocol.wl_buffer.info) handler.buffer_removals += 1;
        if (object.interface == &protocol.wl_shm_pool.info) handler.pool_removals += 1;
        if (object.interface == &protocol.wl_surface.info) handler.surface_removals += 1;
        if (object.interface == &protocol.wl_callback.info and handle.id == handler.frame_id)
            handler.frame_removals += 1;
        if (object.interface == &protocol.wl_callback.info and handle.id == handler.release_id)
            handler.release_removals += 1;
    }
};

const ClientHandler = struct {
    harness: *Harness,
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    release: ?wayring.objects.Handle = null,
    work_queued: bool = false,
    frame_done_count: usize = 0,
    release_done_count: usize = 0,
    frame_delete_count: usize = 0,
    release_delete_count: usize = 0,
    format_count: usize = 0,

    pub fn event(
        handler: *ClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        const interface = target.object.interface;
        if (interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(
                handler.objects,
                handler.registry,
                message,
                fds,
            )) {
                .global => |global| {
                    if (std.mem.eql(u8, global.interface, protocol.wl_compositor.info.name))
                        handler.compositor = try ClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &protocol.wl_compositor.info,
                            @min(global.version, 7),
                            null,
                        );
                    if (std.mem.eql(u8, global.interface, protocol.wl_shm.info.name))
                        handler.shm = try ClientCore.bind(
                            handler.objects,
                            handler.queue,
                            handler.registry,
                            global.name,
                            &protocol.wl_shm.info,
                            @min(global.version, 2),
                            null,
                        );
                    if (handler.compositor != null and handler.shm != null and
                        !handler.work_queued)
                        try handler.queueWork();
                },
                .global_remove => {},
            }
        } else if (interface == &protocol.wl_shm.info) {
            switch (try wayring.client.decodeEvent(
                protocol.wl_shm,
                handler.objects,
                handler.shm.?,
                message,
                fds,
            )) {
                .format => handler.format_count += 1,
            }
        } else if (interface == &ClientCore.Callback.info) {
            const callback = handler.objects.namespace.lookupHandle(message.header.object_id) orelse
                return error.MissingCallback;
            const event_value = try ClientCore.decodeCallbackEvent(
                handler.objects,
                callback,
                message,
                fds,
            );
            if (handler.frame != null and message.header.object_id == handler.frame.?.id) {
                try std.testing.expectEqual(@as(u32, 77), event_value.done.callback_data);
                handler.frame_done_count += 1;
            } else if (handler.release != null and
                message.header.object_id == handler.release.?.id)
            {
                try std.testing.expectEqual(@as(u32, 0), event_value.done.callback_data);
                handler.release_done_count += 1;
            } else return error.UnexpectedCallback;
        } else if (interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(handler.objects, message, fds)) {
                .delete_id => |deleted| {
                    if (handler.frame != null and deleted.id == handler.frame.?.id)
                        handler.frame_delete_count += 1;
                    if (handler.release != null and deleted.id == handler.release.?.id)
                        handler.release_delete_count += 1;
                },
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn queueWork(handler: *ClientHandler) !void {
        const surface = (try protocol.wl_compositor.construct_create_surface(
            handler.objects,
            handler.queue,
            handler.compositor.?,
            .{},
        )).id;
        handler.surface = surface;
        handler.harness.handler.surface_id = surface.id;
        const descriptor = try ordinaryMemfd(4096, 16, &pixel_bytes);
        const pool = try protocol.wl_shm.construct_create_pool(
            handler.objects,
            handler.queue,
            handler.shm.?,
            .{ .fd = descriptor, .size = 4096 },
        );
        const buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            handler.objects,
            handler.queue,
            pool.id,
            .{
                .offset = 16,
                .width = 3,
                .height = 2,
                .stride = 16,
                .format = .argb8888,
            },
        )).id;
        try wayring.client.sendRequest(
            protocol.wl_surface,
            handler.objects,
            handler.queue,
            surface,
            .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } },
        );
        handler.frame = (try protocol.wl_surface.construct_frame(
            handler.objects,
            handler.queue,
            surface,
            .{},
        )).callback;
        handler.release = (try protocol.wl_surface.construct_get_release(
            handler.objects,
            handler.queue,
            surface,
            .{},
        )).callback;
        handler.harness.handler.frame_id = handler.frame.?.id;
        handler.harness.handler.release_id = handler.release.?.id;
        try wayring.client.sendRequest(
            protocol.wl_surface,
            handler.objects,
            handler.queue,
            surface,
            .{ .commit = .{} },
        );
        try wayring.client.sendRequest(
            protocol.wl_buffer,
            handler.objects,
            handler.queue,
            buffer,
            .{ .destroy = .{} },
        );
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            handler.objects,
            handler.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        handler.work_queued = true;
    }
};

fn drainClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *ClientHandler,
) !ClientDriver.Progress {
    var completions: [16]linux.io_uring_cqe = undefined;
    const count = if (reactor.ring.cq_ready() == 0)
        0
    else
        try reactor.ring.copy_cqes(&completions, 0);
    const progress = try driver.dispatch(completions[0..count], handler);
    if (progress.prepared != 0 or progress.pending) _ = try reactor.ring.submit();
    return progress;
}

fn waitForEither(server: *linux.IoUring, client: *linux.IoUring) !void {
    for (0..1_000_000) |_| {
        if (server.cq_ready() != 0 or client.cq_ready() != 0) return;
        _ = linux.sched_yield();
    }
    return error.CompletionTimeout;
}

fn ordinaryMemfd(size: usize, offset: usize, bytes: []const u8) !linux.fd_t {
    const result = linux.memfd_create("ouro-r7", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    const written = linux.pwrite(fd, bytes.ptr, bytes.len, @intCast(offset));
    if (linux.errno(written) != .SUCCESS or written != bytes.len)
        return error.SystemCallFailed;
    return fd;
}

fn monotonicNs() !u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return error.ClockUnavailable;
    return std.math.add(
        u64,
        try std.math.mul(u64, @intCast(now.sec), std.time.ns_per_s),
        @intCast(now.nsec),
    );
}

fn disposeImported(context: ?*anyopaque, imported: Imported) void {
    std.debug.assert(imported.byte_len == pixel_bytes.len);
    std.debug.assert(imported.first_pixel == 0x01020304);
    const count: *usize = @ptrCast(@alignCast(context.?));
    count.* += 1;
}
