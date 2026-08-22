const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");

const linux = std.os.linux;
const ClientCore = wayring.client.Core(protocol);
const ClientConnection = wayring.client.Connection(protocol);
const ServerCore = wayring.server.Core(protocol);
const ServerConnections = wayring.server.SharedClients(protocol);
const Shm = wayring.server.Shm(protocol);
const CommitState = ouro.surface.CommitState(u32);

const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

test "SHM-backed wl_surface attachment commits before release completes" {
    var sockets: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &sockets,
    )));
    var ring = try linux.IoUring.init(
        16,
        linux.IORING_SETUP_SINGLE_ISSUER | linux.IORING_SETUP_DEFER_TASKRUN,
    );
    defer ring.deinit();
    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initBorrowed(std.testing.allocator, &ring, .{
        .max_connections = 2,
        .receive_buffer_size = 4096,
        .receive_buffer_count = 4,
        .receive_control_capacity = 256,
        .fragment_block_size = 256,
        .fragment_block_count = 2,
        .transmit_block_size = 512,
        .transmit_block_count = 4,
        .descriptor_count = 4,
        .send_descriptor_capacity = 2,
    });
    const actor_config: wayring.io_uring.ActorConfig = .{
        .received_fd_budget = 1,
        .transmit_byte_budget = 2048,
        .transmit_fd_budget = 1,
    };
    var server_connections = try ServerConnections.init(
        std.testing.allocator,
        &reactor,
        8,
        8,
        16,
    );
    const server_peer = try server_connections.admit(
        .{ .fd = sockets[0], .more = false },
        actor_config,
        null,
    );
    var client_connection = try ClientConnection.attach(
        std.testing.allocator,
        &reactor,
        sockets[1],
        actor_config,
        .{ .max_objects = 8, .max_client_ids = 7 },
    );
    const client_peer = client_connection.peer;
    const server_objects = try server_connections.get(server_peer);
    const client_objects = &client_connection.objects;
    var shm = try Shm.init(std.testing.allocator, .{
        .limits = .{ .max_pool_bytes = 4096 },
        .pool_capacity = 1,
        .buffer_capacity = 1,
        .formats = &shm_formats,
    });
    defer shm.deinit(std.testing.allocator);
    server_objects.setRemovalHook(.{
        .context = &shm,
        .notify = removeShmResource,
    });
    const shm_resource = try client_objects.createLocal(&protocol.wl_shm.info, 1, null);
    errdefer _ = client_objects.cancelLocal(shm_resource) catch {};
    const surface = try client_objects.createLocal(&protocol.wl_surface.info, 7, null);
    errdefer _ = client_objects.cancelLocal(surface) catch {};
    _ = try server_objects.insertClient(shm_resource.id, &protocol.wl_shm.info, 1, &shm);
    _ = try server_objects.insertClient(surface.id, &protocol.wl_surface.info, 7, null);

    var region_pool = try ouro.surface.RegionPool.init(std.testing.allocator, 1);
    defer region_pool.deinit(std.testing.allocator);
    var regions = ouro.surface.SurfaceRegions.init(&region_pool);
    defer regions.deinit();
    var frame_pool = try ouro.surface.FramePool.init(std.testing.allocator, 1);
    defer frame_pool.deinit(std.testing.allocator);
    var frames = ouro.surface.FrameQueue.init(&frame_pool);
    defer frames.deinit();
    var release_pool = try ouro.surface.ReleasePool.init(std.testing.allocator, 1);
    defer release_pool.deinit(std.testing.allocator);
    var releases = ouro.surface.ReleaseQueue.init(&release_pool);
    defer releases.deinit();
    var scheduler = try CommitState.Scheduler.init(std.testing.allocator, 1, 1);
    defer scheduler.deinit(std.testing.allocator);
    var commit_queue = CommitState.Scheduler.Queue.init(&scheduler, surface.id);
    defer CommitState.deinitQueue(&commit_queue);
    var server_handler: ReleaseServerHandler = .{
        .objects = server_objects,
        .actor = try reactor.getActor(server_peer),
        .shm = &shm,
        .regions = &regions,
        .frames = &frames,
        .releases = &releases,
        .scheduler = &scheduler,
        .commit_queue = &commit_queue,
    };

    const client_actor = try client_connection.actor();
    const descriptor = try memfd(4096);
    const pool = try protocol.wl_shm.construct_create_pool(
        client_objects,
        &client_actor.transmit,
        shm_resource,
        .{ .fd = descriptor, .size = 4096 },
    );
    const buffer = (try protocol.wl_shm_pool.construct_create_buffer(
        client_objects,
        &client_actor.transmit,
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
        client_objects,
        &client_actor.transmit,
        surface,
        .{ .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 } },
    );
    const release_callback = (try protocol.wl_surface.construct_get_release(
        client_objects,
        &client_actor.transmit,
        surface,
        .{},
    )).callback;
    try wayring.client.sendRequest(
        protocol.wl_surface,
        client_objects,
        &client_actor.transmit,
        surface,
        .{ .commit = .{} },
    );
    var client_handler: ReleaseClientHandler = .{
        .objects = client_objects,
        .callback = release_callback,
    };
    try reactor.prepareSend(client_peer);
    _ = try reactor.ring.submit();

    while (!client_handler.done or !client_handler.deleted) {
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        var prepared = false;
        switch (event) {
            .received => {
                if (peer.slot == server_peer.slot) {
                    const result = try ServerCore.receivedRequests(
                        actor,
                        &server_objects.namespace,
                        try reactor.getReceiver(peer),
                        completion,
                        &server_handler,
                    );
                    if (result == .terminal) return result.terminal.cause;
                } else {
                    const result = try ClientCore.receivedEvents(
                        actor,
                        &client_objects.namespace,
                        try reactor.getReceiver(peer),
                        completion,
                        &client_handler,
                    );
                    if (result == .terminal) return result.terminal.cause;
                }
                if (!actor.receive_active) {
                    try reactor.prepareReceive(peer);
                    prepared = true;
                }
            },
            .sent => |sent| if (sent.more_queued) {
                try reactor.prepareSend(peer);
                prepared = true;
            },
            .buffers_exhausted => {
                try reactor.prepareReceive(peer);
                prepared = true;
            },
            else => return error.InvalidCompletion,
        }
        if (actor.transmit.queuedBytes() > 0 and !actor.transmit.sendActive()) {
            try reactor.prepareSend(peer);
            prepared = true;
        }
        if (prepared) _ = try reactor.ring.submit();
    }
    try std.testing.expect(server_handler.committed);
    try std.testing.expect(server_handler.released);
    try std.testing.expectEqual(@as(u32, 0), client_handler.callback_data);
    try std.testing.expect(client_objects.namespace.resolve(release_callback) == null);
    try std.testing.expect(!client_objects.ids.isActive(release_callback.id));

    _ = try server_connections.prepareClose(server_peer);
    _ = try client_connection.prepareClose();
    _ = try reactor.ring.submit();
    while (!(try reactor.getActor(server_peer)).canDeinit() or
        !(try reactor.getActor(client_peer)).canDeinit())
    {
        const completion = try reactor.ring.copy_cqe();
        const routed = (reactor.route(null, completion) orelse
            return error.InvalidCompletion).connection;
        const peer = reactor.routedPeer(routed);
        const actor = try reactor.getActor(peer);
        const event = try actor.completeRouted(routed.operation, completion);
        switch (event) {
            .received => try (try reactor.getReceiver(peer)).buffers.put(completion),
            .receive_stopped, .buffers_exhausted, .cancel_complete, .disconnected => {},
            else => return error.InvalidCompletion,
        }
    }
    try server_connections.destroy(server_peer);
    try client_connection.deinit(std.testing.allocator);
    server_connections.deinit(std.testing.allocator);
    reactor.deinit(std.testing.allocator);
}

const ReleaseServerHandler = struct {
    objects: *wayring.objects.SharedServerObjects,
    actor: *wayring.connection.Actor,
    shm: *Shm,
    surface: ouro.surface.Surface = .{},
    regions: *ouro.surface.SurfaceRegions,
    frames: *ouro.surface.FrameQueue,
    releases: *ouro.surface.ReleaseQueue,
    scheduler: *CommitState.Scheduler,
    commit_queue: *CommitState.Scheduler.Queue,
    committed: bool = false,
    released: bool = false,
    attached_buffer: ?wayring.objects.Handle = null,

    pub fn request(
        handler: *ReleaseServerHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (try handler.shm.request(
            handler.actor,
            handler.objects,
            target,
            message,
            fds,
        )) |control| return control;
        if (target.object.interface != &protocol.wl_surface.info) return error.UnexpectedRequest;
        const decoded = try wayring.server.decodeRequest(
            protocol.wl_surface,
            handler.objects,
            message,
            fds,
        );
        switch (decoded.value) {
            .attach => |value| {
                const buffer_id = value.buffer orelse return error.InvalidBuffer;
                const buffer_handle = handler.objects.namespace.lookupHandle(buffer_id) orelse
                    return error.InvalidBuffer;
                const buffer_object = handler.objects.namespace.resolve(buffer_handle) orelse
                    return error.InvalidBuffer;
                const token = handler.shm.bufferToken(buffer_object) orelse
                    return error.InvalidBuffer;
                const metadata = try handler.shm.store.bufferInfo(token);
                if (metadata.offset != 16 or metadata.width != 3 or metadata.height != 2 or
                    metadata.stride != 16)
                    return error.InvalidBufferMetadata;
                handler.attached_buffer = buffer_handle;
                try handler.surface.attach(7, .{
                    .handle = buffer_handle,
                    .width = metadata.width,
                    .height = metadata.height,
                }, value.x, value.y);
            },
            .get_release => |value| {
                const admitted = try protocol.wl_surface.admit_get_release(
                    handler.objects,
                    decoded.handle,
                    value,
                    .{},
                );
                try handler.releases.request(admitted.callback);
            },
            .commit => {
                _ = try CommitState.commit(
                    handler.scheduler,
                    handler.commit_queue,
                    &handler.surface,
                    handler.regions,
                    handler.frames,
                    handler.releases,
                    .desync,
                    &.{},
                    0,
                );
                var applied: [1]CommitState.Scheduler.Applied = undefined;
                const result = try handler.scheduler.tryApply(handler.commit_queue, &applied);
                if (result.len != 1) return error.MissingContentUpdate;
                var content = result[0].payload;
                defer content.deinit();
                const attachment = content.surface.attachment orelse
                    return error.MissingAttachment;
                const committed_buffer = attachment.buffer orelse
                    return error.MissingBuffer;
                const attached_buffer = handler.attached_buffer orelse
                    return error.MissingAttachment;
                if (!std.meta.eql(committed_buffer.handle, attached_buffer) or
                    committed_buffer.width != 3 or committed_buffer.height != 2)
                    return error.InvalidCommittedAttachment;
                const callback = content.release_callbacks.?.peek() orelse
                    return error.MissingRelease;
                try ServerCore.completeSync(
                    handler.objects,
                    &handler.actor.transmit,
                    callback,
                    0,
                );
                try content.release_callbacks.?.consume(callback);
                handler.committed = true;
                handler.released = true;
            },
            else => return error.UnexpectedRequest,
        }
        try decoded.finish(protocol, handler.objects, &handler.actor.transmit);
        return .continue_dispatch;
    }
};

fn removeShmResource(
    context: ?*anyopaque,
    handle: wayring.objects.Handle,
    object: wayring.objects.Object,
) void {
    const shm: *Shm = @ptrCast(@alignCast(context.?));
    _ = shm.resourceRemoved(handle, object);
}

fn memfd(size: usize) !linux.fd_t {
    const result = linux.memfd_create("ouro-release-e2e", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    return fd;
}

const ReleaseClientHandler = struct {
    objects: *wayring.objects.ClientObjects,
    callback: wayring.objects.Handle,
    done: bool = false,
    deleted: bool = false,
    callback_data: u32 = 1,

    pub fn event(
        handler: *ReleaseClientHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &protocol.wl_callback.info) {
            const decoded = try ClientCore.decodeCallbackEvent(
                handler.objects,
                handler.callback,
                message,
                fds,
            );
            handler.callback_data = switch (decoded) {
                .done => |value| value.callback_data,
            };
            handler.done = true;
        } else if (target.object.interface == &protocol.wl_display.info) {
            const decoded = try ClientCore.decodeDisplayEvent(handler.objects, message, fds);
            switch (decoded) {
                .delete_id => |value| {
                    if (value.id == handler.callback.id) handler.deleted = true;
                },
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};
