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
const protocol_input_method = ouro.input_method;

const pixels = [_]u8{
    0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff, 0x70, 0x80, 0x90, 0xff, 0, 0, 0, 0,
    0xa0, 0xb0, 0xc0, 0xff, 0xd0, 0xe0, 0xf0, 0xff, 0x11, 0x22, 0x33, 0xff, 0, 0, 0, 0,
};

test "shell-input: core compatibility extensions cross generated runtime" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-wayland-fixes-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 24;
    root_config.runtime.registry_capacity = 2;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const first_registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: WaylandFixesHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = first_registry,
    };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.fixes != null and handler.system_bell != null and
            handler.toplevel_drag_manager != null and
            handler.toplevel_icon_manager != null and handler.toplevel_icon_done == 1 and
            handler.gtk_surface != null and handler.gtk_capabilities == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.fixes != null);
    try std.testing.expectEqual(@as(u32, 1), handler.fixes_version);
    try std.testing.expect(handler.system_bell != null);
    try std.testing.expectEqual(@as(u32, 1), handler.system_bell_version);
    try std.testing.expect(handler.toplevel_drag_manager != null);
    try std.testing.expect(handler.toplevel_icon_manager != null);
    try std.testing.expectEqual(@as(usize, 1), handler.toplevel_icon_done);
    try std.testing.expectEqual(@as(u32, 5), handler.gtk_shell_version);
    try std.testing.expectEqual(@as(usize, 1), handler.gtk_capabilities);

    try protocol.gtk_surface1.encodeRequest(
        &actor.transmit,
        handler.gtk_surface.?.id,
        .{ .set_dbus_properties = .{
            .application_id = "org.ouro.Test",
            .app_menu_path = null,
            .menubar_path = null,
            .window_object_path = "/org/ouro/Test",
            .application_object_path = null,
            .unique_bus_name = null,
        } },
    );
    try protocol.gtk_surface1.encodeRequest(&actor.transmit, handler.gtk_surface.?.id, .{ .set_modal = .{} });
    try wayring.client.sendRequest(
        protocol.gtk_surface1,
        &client.objects,
        &actor.transmit,
        handler.gtk_surface.?,
        .{ .release = .{} },
    );

    try protocol.xdg_system_bell_v1.encodeRequest(
        &actor.transmit,
        handler.system_bell.?.id,
        .{ .ring = .{ .surface = 0 } },
    );
    try wayring.client.sendRequest(
        protocol.xdg_system_bell_v1,
        &client.objects,
        &actor.transmit,
        handler.system_bell.?,
        .{ .destroy = .{} },
    );

    const second_registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    try wayring.client.sendRequest(
        protocol.wl_fixes,
        &client.objects,
        &actor.transmit,
        handler.fixes.?,
        .{ .destroy_registry = .{ .registry = second_registry.id } },
    );
    _ = try client.objects.retireLocal(second_registry);
    try submitClient(&reactor, &driver, &handler);
    for (0..64) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        _ = linux.sched_yield();
    }
    try std.testing.expect(client.objects.namespace.resolve(second_registry) == null);
    const replacement_registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    try std.testing.expectEqual(second_registry.id, replacement_registry.id);
    try std.testing.expect(client.objects.namespace.resolve(first_registry) != null);
    try std.testing.expect(client.objects.namespace.resolve(handler.fixes.?) != null);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    try wayring.client.sendRequest(
        protocol.wl_fixes,
        &client.objects,
        &actor.transmit,
        handler.fixes.?,
        .{ .destroy = .{} },
    );
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (client.objects.namespace.resolve(handler.fixes.?) == null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(client.objects.namespace.resolve(handler.fixes.?) == null);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const cp = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and cp.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const WaylandFixesHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    fixes: ?wayring.objects.Handle = null,
    fixes_version: u32 = 0,
    system_bell: ?wayring.objects.Handle = null,
    system_bell_version: u32 = 0,
    toplevel_drag_manager: ?wayring.objects.Handle = null,
    toplevel_icon_manager: ?wayring.objects.Handle = null,
    toplevel_icon_done: usize = 0,
    compositor: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    gtk_shell: ?wayring.objects.Handle = null,
    gtk_shell_version: u32 = 0,
    gtk_surface: ?wayring.objects.Handle = null,
    gtk_capabilities: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(self: *WaylandFixesHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *WaylandFixesHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Display.info) {
            _ = try ClientCore.decodeDisplayEvent(self.objects, message, fds);
            return .continue_dispatch;
        }
        if (target.object.interface == &protocol.xdg_toplevel_icon_manager_v1.info) {
            switch (try protocol.xdg_toplevel_icon_manager_v1.decodeEvent(message, fds)) {
                .icon_size => return error.UnexpectedPreferredIconSize,
                .done => self.toplevel_icon_done += 1,
            }
            return .continue_dispatch;
        }
        if (target.object.interface == &protocol.gtk_shell1.info) {
            switch (try protocol.gtk_shell1.decodeEvent(message, fds)) {
                .capabilities => |value| {
                    try std.testing.expectEqual(@as(u32, 0), value.capabilities);
                    self.gtk_capabilities += 1;
                },
            }
            return .continue_dispatch;
        }
        if (target.object.interface != &ClientCore.Registry.info) return .continue_dispatch;
        switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
            .global => |value| if (std.mem.eql(u8, value.interface, protocol.wl_fixes.info.name)) {
                self.fixes_version = value.version;
                self.fixes = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.wl_fixes.info,
                    @min(value.version, 1),
                    null,
                );
            } else if (std.mem.eql(u8, value.interface, protocol.xdg_system_bell_v1.info.name)) {
                self.system_bell_version = value.version;
                self.system_bell = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.xdg_system_bell_v1.info,
                    @min(value.version, 1),
                    null,
                );
            } else if (std.mem.eql(u8, value.interface, protocol.xdg_toplevel_icon_manager_v1.info.name)) {
                self.toplevel_icon_manager = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.xdg_toplevel_icon_manager_v1.info,
                    @min(value.version, 1),
                    null,
                );
            } else if (std.mem.eql(u8, value.interface, protocol.xdg_toplevel_drag_manager_v1.info.name)) {
                self.toplevel_drag_manager = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.xdg_toplevel_drag_manager_v1.info,
                    @min(value.version, 1),
                    null,
                );
            } else if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name)) {
                self.compositor = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.wl_compositor.info,
                    @min(value.version, 6),
                    null,
                );
                try self.maybeCreateGtkSurface();
            } else if (std.mem.eql(u8, value.interface, protocol.gtk_shell1.info.name)) {
                self.gtk_shell_version = value.version;
                self.gtk_shell = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.gtk_shell1.info,
                    @min(value.version, 5),
                    null,
                );
                try self.maybeCreateGtkSurface();
            },
            .global_remove => {},
        }
        return .continue_dispatch;
    }

    fn maybeCreateGtkSurface(self: *WaylandFixesHandler) !void {
        if (self.gtk_surface != null or self.compositor == null or self.gtk_shell == null) return;
        self.surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        self.gtk_surface = (try protocol.gtk_shell1.construct_get_gtk_surface(
            self.objects,
            self.queue,
            self.gtk_shell.?,
            .{ .surface = self.surface.?.id },
        )).gtk_surface;
    }
};

test "shell-input: generated transient seat publishes before ready and retires independently" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-transient-seat-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 24;
    root_config.runtime.registry_capacity = 1;
    root_config.runtime.max_globals = 68;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 24, .max_client_ids = 23 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: TransientSeatHandler = .{ .objects = &client.objects, .queue = &actor.transmit, .registry = registry };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.manager != null and handler.virtual_pointer_manager != null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.manager != null);
    try std.testing.expect(handler.virtual_pointer_manager != null);

    handler.creating = true;
    handler.transient = (try protocol.ext_transient_seat_manager_v1.construct_create(
        &client.objects,
        &actor.transmit,
        handler.manager.?,
        .{},
    )).seat;
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.ready == 1 and handler.seat_events >= 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.dynamic_global);
    try std.testing.expectEqual(@as(usize, 1), handler.ready);
    try std.testing.expectEqual(@as(usize, 0), handler.denied);
    try std.testing.expect(handler.seat != null);
    try std.testing.expect(handler.seat_events >= 2);

    const transient = handler.transient.?;
    const seat = handler.seat.?;
    const virtual_pointer = (try protocol.zwlr_virtual_pointer_manager_v1.construct_create_virtual_pointer(
        &client.objects,
        &actor.transmit,
        handler.virtual_pointer_manager.?,
        .{ .seat = seat.id },
    )).id;
    try submitClient(&reactor, &driver, &handler);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.pointer_capability) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.pointer_capability);

    try wayring.client.sendRequest(
        protocol.zwlr_virtual_pointer_v1,
        &client.objects,
        &actor.transmit,
        virtual_pointer,
        .{ .destroy = .{} },
    );
    try submitClient(&reactor, &driver, &handler);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!handler.pointer_capability and handler.capability_events >= 3) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(!handler.pointer_capability);
    try std.testing.expect(handler.capability_events >= 3);

    try wayring.client.sendRequest(
        protocol.ext_transient_seat_v1,
        &client.objects,
        &actor.transmit,
        transient,
        .{ .destroy = .{} },
    );
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.global_remove == 1 and client.objects.namespace.resolve(transient) == null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.global_remove);
    try std.testing.expect(client.objects.namespace.resolve(transient) == null);
    try std.testing.expect(client.objects.namespace.resolve(seat) != null);

    try wayring.client.sendRequest(protocol.wl_seat, &client.objects, &actor.transmit, seat, .{ .release = .{} });
    try wayring.client.sendRequest(
        protocol.ext_transient_seat_manager_v1,
        &client.objects,
        &actor.transmit,
        handler.manager.?,
        .{ .destroy = .{} },
    );
    try submitClient(&reactor, &driver, &handler);
    for (0..64) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
    }
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const cp = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and cp.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const TransientSeatHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    manager: ?wayring.objects.Handle = null,
    virtual_pointer_manager: ?wayring.objects.Handle = null,
    transient: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    creating: bool = false,
    seat_names: [4]u32 = undefined,
    seat_versions: [4]u32 = undefined,
    seat_name_count: usize = 0,
    dynamic_name: ?u32 = null,
    dynamic_global: usize = 0,
    global_remove: usize = 0,
    ready: usize = 0,
    denied: usize = 0,
    seat_events: usize = 0,
    capability_events: usize = 0,
    pointer_capability: bool = false,
    event_failures: usize = 0,

    pub fn eventError(self: *TransientSeatHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *TransientSeatHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| if (std.mem.eql(u8, value.interface, protocol.ext_transient_seat_manager_v1.info.name)) {
                    self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_transient_seat_manager_v1.info, 1, null);
                } else if (std.mem.eql(u8, value.interface, protocol.zwlr_virtual_pointer_manager_v1.info.name)) {
                    self.virtual_pointer_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwlr_virtual_pointer_manager_v1.info, @min(value.version, 2), null);
                } else if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name)) {
                    if (self.seat_name_count == self.seat_names.len) return error.TooManySeatGlobals;
                    self.seat_names[self.seat_name_count] = value.name;
                    self.seat_versions[self.seat_name_count] = value.version;
                    self.seat_name_count += 1;
                },
                .global_remove => |value| {
                    if (self.dynamic_name == value.name) self.global_remove += 1;
                },
            }
        } else if (target.object.interface == &protocol.ext_transient_seat_v1.info) {
            switch (try protocol.ext_transient_seat_v1.decodeEvent(message, fds)) {
                .ready => |value| {
                    try std.testing.expect(self.creating);
                    var version: ?u32 = null;
                    for (self.seat_names[0..self.seat_name_count], self.seat_versions[0..self.seat_name_count]) |name, candidate_version| {
                        if (name == value.global_name) version = candidate_version;
                    }
                    try std.testing.expect(version != null);
                    self.dynamic_name = value.global_name;
                    self.dynamic_global += 1;
                    self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.global_name, &protocol.wl_seat.info, @min(version.?, 9), null);
                    self.ready += 1;
                },
                .denied => self.denied += 1,
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            switch (try protocol.wl_seat.decodeEvent(message, fds)) {
                .capabilities => |value| {
                    self.pointer_capability = value.capabilities.contains(protocol.wl_seat.capability.pointer);
                    self.capability_events += 1;
                },
                .name => {},
            }
            self.seat_events += 1;
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

test "shell-input: generated workspace client observes and activates the fixed workspace" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-workspace-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 24;
    root_config.runtime.object_quota = 24;
    root_config.runtime.registry_capacity = 1;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: WorkspaceHandler = .{ .objects = &client.objects, .queue = &actor.transmit, .registry = registry };
    try submitClient(&reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var turns_after_activation: usize = 0;
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.activation_sent) turns_after_activation += 1;
        if (handler.output_enter == 2 and turns_after_activation >= 4 and
            coordinator.workspace_adapter.pendingCommands() == 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.manager != null);
    try std.testing.expect(handler.group != null);
    try std.testing.expect(handler.workspace != null);
    try std.testing.expectEqual(@as(usize, 8), handler.initial_order);
    try std.testing.expectEqual(@as(usize, 1), handler.initial_done);
    try std.testing.expectEqual(@as(usize, 2), handler.output_enter);
    try std.testing.expect(handler.activation_sent);
    try std.testing.expectEqual(@as(usize, 0), coordinator.workspace_adapter.pendingCommands());
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    // Depending on registry publication order, output_enter may be part of
    // the initial done batch or a separate association update.
    try std.testing.expect(handler.output_done <= 2);
    const output_done_before_disable = handler.output_done;
    try fixture.signalSession(.disable);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.primaryKmsOutput() == null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(coordinator.primaryKmsOutput() == null);
    // Session suspension removes scanout ownership, not the physical output.
    // Workspace membership therefore remains associated with the connector.
    try std.testing.expectEqual(@as(usize, 0), handler.output_leave);
    try std.testing.expectEqual(output_done_before_disable, handler.output_done);

    try protocol.ext_workspace_manager_v1.encodeRequest(&actor.transmit, handler.manager.?.id, .{ .stop = .{} });
    try submitClient(&reactor, &driver, &handler);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.finished == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.finished);

    try wayring.client.sendRequest(protocol.ext_workspace_group_handle_v1, &client.objects, &actor.transmit, handler.group.?, .{ .destroy = .{} });
    try wayring.client.sendRequest(protocol.ext_workspace_handle_v1, &client.objects, &actor.transmit, handler.workspace.?, .{ .destroy = .{} });
    try submitClient(&reactor, &driver, &handler);
    for (0..32) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
    }

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..256) |_| {
        const cp = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and cp.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const WorkspaceHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    outputs: [2]wayring.objects.Handle = undefined,
    output_count: usize = 0,
    manager: ?wayring.objects.Handle = null,
    group: ?wayring.objects.Handle = null,
    workspace: ?wayring.objects.Handle = null,
    initial_order: usize = 0,
    initial_done: usize = 0,
    output_enter: usize = 0,
    output_leave: usize = 0,
    output_done: usize = 0,
    finished: usize = 0,
    activation_sent: bool = false,
    event_failures: usize = 0,

    pub fn eventError(self: *WorkspaceHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *WorkspaceHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name)) {
                    self.outputs[self.output_count] = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
                    self.output_count += 1;
                } else if (std.mem.eql(u8, value.interface, protocol.ext_workspace_manager_v1.info.name)) {
                    self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_workspace_manager_v1.info, 1, null);
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_output.info) {
            _ = try protocol.wl_output.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.ext_workspace_manager_v1.info) {
            switch (try protocol.ext_workspace_manager_v1.decodeEvent(message, fds)) {
                .workspace_group => |value| {
                    try std.testing.expectEqual(@as(usize, 0), self.initial_order);
                    self.group = (try protocol.ext_workspace_manager_v1.admit_event_workspace_group(self.objects, self.manager.?, value, .{})).workspace_group;
                    self.initial_order = 1;
                },
                .workspace => |value| {
                    try std.testing.expectEqual(@as(usize, 2), self.initial_order);
                    self.workspace = (try protocol.ext_workspace_manager_v1.admit_event_workspace(self.objects, self.manager.?, value, .{})).workspace;
                    self.initial_order = 3;
                },
                .done => {
                    if (self.initial_done == 0) {
                        try std.testing.expectEqual(@as(usize, 8), self.initial_order);
                        try protocol.ext_workspace_handle_v1.encodeRequest(self.queue, self.workspace.?.id, .{ .activate = .{} });
                        try protocol.ext_workspace_manager_v1.encodeRequest(self.queue, self.manager.?.id, .{ .commit = .{} });
                        self.activation_sent = true;
                        self.initial_done = 1;
                    } else {
                        self.output_done += 1;
                    }
                },
                .finished => self.finished += 1,
            }
        } else if (target.object.interface == &protocol.ext_workspace_group_handle_v1.info) {
            switch (try protocol.ext_workspace_group_handle_v1.decodeEvent(message, fds)) {
                .capabilities => |value| {
                    try std.testing.expectEqual(@as(usize, 1), self.initial_order);
                    try std.testing.expectEqual(@as(u32, 0), value.capabilities.value);
                    self.initial_order = 2;
                },
                .workspace_enter => |value| {
                    try std.testing.expectEqual(@as(usize, 7), self.initial_order);
                    try std.testing.expectEqual(self.workspace.?.id, value.workspace);
                    self.initial_order = 8;
                },
                .output_enter => |value| {
                    try std.testing.expect(self.hasOutput(value.output));
                    self.output_enter += 1;
                },
                .output_leave => |value| {
                    try std.testing.expect(self.hasOutput(value.output));
                    self.output_leave += 1;
                },
                .workspace_leave, .removed => return error.UnexpectedWorkspaceGroupEvent,
            }
        } else if (target.object.interface == &protocol.ext_workspace_handle_v1.info) {
            switch (try protocol.ext_workspace_handle_v1.decodeEvent(message, fds)) {
                .id => |value| {
                    try std.testing.expectEqual(@as(usize, 3), self.initial_order);
                    try std.testing.expectEqualStrings("ouro-0", value.id);
                    self.initial_order = 4;
                },
                .name => |value| {
                    try std.testing.expectEqual(@as(usize, 4), self.initial_order);
                    try std.testing.expectEqualStrings("Ouro", value.name);
                    self.initial_order = 5;
                },
                .state => |value| {
                    try std.testing.expectEqual(@as(usize, 5), self.initial_order);
                    try std.testing.expect(value.state.contains(protocol.ext_workspace_handle_v1.state.active));
                    self.initial_order = 6;
                },
                .capabilities => |value| {
                    try std.testing.expectEqual(@as(usize, 6), self.initial_order);
                    try std.testing.expectEqual(protocol.ext_workspace_handle_v1.workspace_capabilities.activate, value.capabilities);
                    self.initial_order = 7;
                },
                .coordinates => return error.UnexpectedWorkspaceCoordinates,
                .removed => return error.UnexpectedWorkspaceRemoved,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn hasOutput(self: *const WorkspaceHandler, id: u32) bool {
        for (self.outputs[0..self.output_count]) |output|
            if (output.id == id) return true;
        return false;
    }
};

test "shell-input: XDG session restore precedes the first toplevel configure" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-xdg-session-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 24;
    root_config.runtime.object_quota = 24;
    root_config.runtime.registry_capacity = 1;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    const stored = try coordinator.xdg_session_adapter.importSession("saved");
    try coordinator.xdg_session_adapter.importToplevel(stored, "main", .{
        .maximized = false,
        .fullscreen = false,
        .mode = .floating,
        .floating_geometry = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
    });
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: XdgSessionHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitClient(&reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.configure_order == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.session_restored);
    try std.testing.expectEqual(@as(usize, 1), handler.restore_order);
    try std.testing.expectEqual(@as(usize, 2), handler.configure_order);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

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
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

const XdgSessionHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    xdg_surface: ?wayring.objects.Handle = null,
    toplevel: ?wayring.objects.Handle = null,
    session: ?wayring.objects.Handle = null,
    toplevel_session: ?wayring.objects.Handle = null,
    created: bool = false,
    session_restored: bool = false,
    restore_order: usize = 0,
    configure_order: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *XdgSessionHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *XdgSessionHandler,
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
        } else if (target.object.interface == &protocol.xdg_session_v1.info) {
            switch (try protocol.xdg_session_v1.decodeEvent(message, fds)) {
                .restored => self.session_restored = true,
                .created, .replaced => return error.UnexpectedSessionEvent,
            }
        } else if (target.object.interface == &protocol.xdg_toplevel_session_v1.info) {
            switch (try protocol.xdg_toplevel_session_v1.decodeEvent(message, fds)) {
                .restored => {
                    try std.testing.expectEqual(@as(usize, 0), self.restore_order);
                    try std.testing.expectEqual(@as(usize, 0), self.configure_order);
                    self.restore_order = 1;
                },
            }
        } else if (target.object.interface == &protocol.xdg_toplevel.info) {
            switch (try protocol.xdg_toplevel.decodeEvent(message, fds)) {
                .configure => |value| {
                    try std.testing.expectEqual(@as(usize, 1), self.restore_order);
                    try std.testing.expectEqual(@as(i32, 2), value.width);
                    try std.testing.expectEqual(@as(i32, 1), value.height);
                    self.configure_order = 2;
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.xdg_surface.info) {
            switch (try protocol.xdg_surface.decodeEvent(message, fds)) {
                .configure => |value| try protocol.xdg_surface.encodeRequest(
                    self.queue,
                    self.xdg_surface.?.id,
                    .{ .ack_configure = .{ .serial = value.serial } },
                ),
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn bindGlobal(self: *XdgSessionHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_session_manager_v1.info.name))
            self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_session_manager_v1.info, 1, null);
    }

    fn maybeCreate(self: *XdgSessionHandler) !void {
        if (self.created or self.compositor == null or self.wm_base == null or self.manager == null)
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
        self.session = (try protocol.xdg_session_manager_v1.construct_get_session(
            self.objects,
            self.queue,
            self.manager.?,
            .{
                .reason = .recover,
                .session_id = "saved",
            },
        )).id;
        self.toplevel_session = (try protocol.xdg_session_v1.construct_restore_toplevel(
            self.objects,
            self.queue,
            self.session.?,
            .{ .toplevel = self.toplevel.?.id, .name = "main" },
        )).id;
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{ .commit = .{} });
        self.created = true;
    }
};

test "shell-input: generated data-control client crosses ext and wlr runtime paths" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-data-control-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 64;
    root_config.runtime.object_quota = 48;
    root_config.runtime.registry_capacity = 1;
    root_config.runtime.actor.received_fd_budget = 4;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 32 });
    try coordinator.start(&loop);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 4, .transmit_byte_budget = 8192, .transmit_fd_budget = 2 },
        .{ .max_objects = 24, .max_client_ids = 23 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: DataControlHandler = .{ .objects = &client.objects, .queue = &actor.transmit, .registry = registry };
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.initial_ext_regular == 1 and handler.initial_ext_primary == 1 and handler.initial_wlr_regular == 1 and handler.initial_wlr_primary == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.seat != null);
    try std.testing.expect(handler.ext_manager != null);
    try std.testing.expect(handler.wlr_manager != null);
    try std.testing.expectEqual(@as(usize, 1), handler.initial_ext_regular);
    try std.testing.expectEqual(@as(usize, 1), handler.initial_ext_primary);
    try std.testing.expectEqual(@as(usize, 1), handler.initial_wlr_regular);
    try std.testing.expectEqual(@as(usize, 1), handler.initial_wlr_primary);

    handler.source1 = (try protocol.ext_data_control_manager_v1.construct_create_data_source(&client.objects, &actor.transmit, handler.ext_manager.?, .{})).id;
    try protocol.ext_data_control_source_v1.encodeRequest(&actor.transmit, handler.source1.?.id, .{ .offer = .{ .mime_type = "text/plain;charset=utf-8" } });
    try protocol.ext_data_control_device_v1.encodeRequest(&actor.transmit, handler.ext_device.?.id, .{ .set_selection = .{ .source = handler.source1.?.id } });
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.ext_selection != null and handler.wlr_selection != null and handler.ext_mimes != 0 and handler.wlr_mimes != 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.ext_selection != null);
    try std.testing.expect(handler.wlr_selection != null);
    try std.testing.expectEqual(@as(usize, 1), handler.ext_mimes);
    try std.testing.expectEqual(@as(usize, 1), handler.wlr_mimes);

    var pipe: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    const read_fd = pipe[0];
    defer _ = linux.close(read_fd);
    var write_fd = pipe[1];
    defer if (write_fd >= 0) {
        _ = linux.close(write_fd);
    };
    try protocol.ext_data_control_offer_v1.encodeRequest(&actor.transmit, handler.ext_selection.?.id, .{ .receive = .{ .mime_type = "text/plain;charset=utf-8", .fd = write_fd } });
    write_fd = -1; // The generated transmit queue owns it after encoding.
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.send_fd >= 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.send_mime_valid);
    try std.testing.expect(handler.send_fd >= 0);
    try std.testing.expectEqual(@as(usize, 1), linux.write(handler.send_fd, "x", 1));
    _ = linux.close(handler.send_fd);
    handler.send_fd = -1;
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), linux.read(read_fd, &byte, 1));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);

    handler.source2 = (try protocol.ext_data_control_manager_v1.construct_create_data_source(&client.objects, &actor.transmit, handler.ext_manager.?, .{})).id;
    try protocol.ext_data_control_source_v1.encodeRequest(&actor.transmit, handler.source2.?.id, .{ .offer = .{ .mime_type = "text/plain" } });
    try protocol.ext_data_control_device_v1.encodeRequest(&actor.transmit, handler.ext_device.?.id, .{ .set_selection = .{ .source = handler.source2.?.id } });
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.cancelled != 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.cancelled);

    const ext_mimes_before_wlr = handler.ext_mimes;
    handler.wlr_source = (try protocol.zwlr_data_control_manager_v1.construct_create_data_source(&client.objects, &actor.transmit, handler.wlr_manager.?, .{})).id;
    try protocol.zwlr_data_control_source_v1.encodeRequest(&actor.transmit, handler.wlr_source.?.id, .{ .offer = .{ .mime_type = "text/html" } });
    try protocol.zwlr_data_control_device_v1.encodeRequest(&actor.transmit, handler.wlr_device.?.id, .{ .set_selection = .{ .source = handler.wlr_source.?.id } });
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.cancelled == 2 and handler.ext_mimes > ext_mimes_before_wlr) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.cancelled);
    try std.testing.expect(handler.ext_mimes > ext_mimes_before_wlr);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const cp = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and cp.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: generated primary selection validates focus serial and transfers data" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-primary-selection-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var input = try FakeInput.init();
    defer input.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 32;
    root_config.runtime.object_quota = 24;
    root_config.runtime.actor.received_fd_budget = 2;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 1), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    var platforms = fixture.platforms();
    platforms.input = input.platform();
    const coordinator = try Coordinator.create(allocator, root, platforms, config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);

    var reactor: wayring.io_uring.Reactor = undefined;
    try reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var client = try ClientConnection.attach(
        allocator,
        &reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 2, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 24, .max_client_ids = 23 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: PrimarySelectionHandler = .{ .objects = &client.objects, .queue = &actor.transmit, .registry = registry };
    defer {
        if (handler.read_fd >= 0) _ = linux.close(handler.read_fd);
    }
    try submitClient(&reactor, &driver, &handler);
    for (0..256) |_| {
        _ = try drainClient(&reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.surface != null and handler.device != null and handler.source != null and coordinator.peer != null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.surface != null and handler.device != null and handler.source != null);
    const peer = coordinator.peer.?;
    try coordinator.primary_selection_adapter.setFocus(peer);
    try input.publish(&.{.{ .device_added = .{
        .device = 71,
        .info = .{ .capabilities = .{ .keyboard = true } },
    } }});
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.keyboard != null) break;
        _ = linux.sched_yield();
    }
    const surface_id = try coordinator.adapter.surfaceId(handler.surface.?);
    try coordinator.seat_adapter.setKeyboardFocus(try coordinator.seat_adapter.makeTarget(peer, surface_id));
    try input.publish(&.{.{ .keyboard_key = .{
        .device = 71,
        .time_usec = 1_000,
        .key = 30,
        .pressed = true,
    } }});
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.send_count == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.send_count);
    try handler.expectTransfer("first");

    try handler.replaceSelection();
    try submitClient(&reactor, &driver, &handler);
    for (0..512) |_| {
        _ = try loop.turn(coordinator);
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.send_count == 2 and handler.cancelled == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.cancelled);
    try std.testing.expectEqual(@as(usize, 2), handler.send_count);
    try handler.expectTransfer("second");

    try coordinator.primary_selection_adapter.setFocus(null);
    for (0..128) |_| {
        _ = try loop.turn(coordinator);
        _ = try drainClient(&reactor, &driver, &handler);
        if (handler.null_selections >= 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.null_selections);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    _ = try client.prepareClose();
    try submitClient(&reactor, &driver, &handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const cp = try drainClient(&reactor, &driver, &handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and cp.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try client.deinit(allocator);
    reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: security context filters nested manager before registry discovery" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    var child_path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-security-parent-{d}.sock", .{linux.getpid()});
    const child_path = try std.fmt.bufPrint(&child_path_storage, "/tmp/ouro-security-child-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    wayring.unix_socket.unlink(child_path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(child_path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 64;
    root_config.runtime.object_quota = 32;
    root_config.runtime.registry_capacity = 2;
    root_config.runtime.actor.received_fd_budget = 2;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 2),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
    config.security_context = .{
        .resource_capacity = 2,
        .listener_capacity = 1,
        .client_capacity = 1,
        .metadata_bytes = 64,
    };
    const coordinator = try Coordinator.create(allocator, root, fixture.platforms(), config);
    var loop = try Loop.init(
        allocator,
        root,
        &coordinator.router,
        &coordinator.timers,
        coordinator,
        .{ .completion_batch = 32 },
    );
    try coordinator.start(&loop);

    var parent_reactor: wayring.io_uring.Reactor = undefined;
    try parent_reactor.initOwned(
        allocator,
        .{ .entries = 16, .flags = 0 },
        physical_fixture.clientReactorConfig(),
    );
    var parent = try ClientConnection.attach(
        allocator,
        &parent_reactor,
        try wayring.unix_socket.connect(path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 2 },
        .{ .max_objects = 8, .max_client_ids = 7 },
    );
    const parent_actor = try parent.actor();
    var parent_driver = ClientDriver.init(&parent);
    const parent_registry = try ClientCore.getRegistry(&parent.objects, &parent_actor.transmit, null);
    var parent_handler: Handler = .{
        .objects = &parent.objects,
        .queue = &parent_actor.transmit,
        .registry = parent_registry,
        .registry_only = true,
        .test_security_context = true,
    };
    try submitClient(&parent_reactor, &parent_driver, &parent_handler);
    for (0..256) |_| {
        _ = try drainClient(&parent_reactor, &parent_driver, &parent_handler);
        _ = try loop.turn(coordinator);
        if (parent_handler.security_manager != null and
            parent_handler.ext_data_control_global_seen and
            parent_handler.wlr_data_control_global_seen and
            parent_handler.input_method_global_seen and
            parent_handler.virtual_keyboard_global_seen and
            parent_handler.virtual_pointer_global_seen and
            parent_handler.foreign_toplevel_global_seen and
            parent_handler.workspace_global_seen and
            parent_handler.image_output_global_seen and
            parent_handler.image_toplevel_global_seen and
            parent_handler.image_copy_global_seen) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(parent_handler.security_manager != null);
    try std.testing.expect(parent_handler.ext_data_control_global_seen);
    try std.testing.expect(parent_handler.wlr_data_control_global_seen);
    try std.testing.expect(parent_handler.input_method_global_seen);
    try std.testing.expect(parent_handler.virtual_keyboard_global_seen);
    try std.testing.expect(parent_handler.virtual_pointer_global_seen);
    try std.testing.expect(parent_handler.foreign_toplevel_global_seen);
    try std.testing.expect(parent_handler.workspace_global_seen);
    try std.testing.expect(parent_handler.image_output_global_seen);
    try std.testing.expect(parent_handler.image_toplevel_global_seen);
    try std.testing.expect(parent_handler.image_copy_global_seen);

    var close_pair: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(
        linux.AF.UNIX,
        linux.SOCK.STREAM | linux.SOCK.CLOEXEC,
        0,
        &close_pair,
    )));
    var close_signal = close_pair[0];
    defer if (close_signal >= 0) {
        _ = linux.close(close_signal);
    };
    var sent_close = close_pair[1];
    defer if (sent_close >= 0) {
        _ = linux.close(sent_close);
    };
    var child_listener = try wayring.unix_socket.listen(child_path, 1);
    defer if (child_listener >= 0) {
        _ = linux.close(child_listener);
    };
    const context = (try protocol.wp_security_context_manager_v1.construct_create_listener(
        &parent.objects,
        &parent_actor.transmit,
        parent_handler.security_manager.?,
        .{ .listen_fd = child_listener, .close_fd = sent_close },
    )).id;
    // Wayring's transmit queue takes descriptor ownership at enqueue time.
    child_listener = -1;
    sent_close = -1;
    try protocol.wp_security_context_v1.encodeRequest(
        &parent_actor.transmit,
        context.id,
        .{ .set_sandbox_engine = .{ .name = "org.example.Sandbox" } },
    );
    try protocol.wp_security_context_v1.encodeRequest(
        &parent_actor.transmit,
        context.id,
        .{ .set_app_id = .{ .app_id = "org.example.Client" } },
    );
    try protocol.wp_security_context_v1.encodeRequest(
        &parent_actor.transmit,
        context.id,
        .{ .commit = .{} },
    );
    try submitClient(&parent_reactor, &parent_driver, &parent_handler);
    for (0..256) |_| {
        _ = try drainClient(&parent_reactor, &parent_driver, &parent_handler);
        _ = try loop.turn(coordinator);
        const listeners = coordinator.security_context_adapter.committedListeners();
        if (listeners.len != 0 and listeners[0].accept_token != null) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), coordinator.security_context_adapter.committedListeners().len);
    const listener = coordinator.security_context_adapter.committedListeners()[0];
    try std.testing.expect(listener.accept_token != null);

    var child_reactor: wayring.io_uring.Reactor = undefined;
    try child_reactor.initOwned(
        allocator,
        .{ .entries = 16, .flags = 0 },
        physical_fixture.clientReactorConfig(),
    );
    var child = try ClientConnection.attach(
        allocator,
        &child_reactor,
        try wayring.unix_socket.connect(child_path),
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 8, .max_client_ids = 7 },
    );
    const child_actor = try child.actor();
    var child_driver = ClientDriver.init(&child);
    const child_registry = try ClientCore.getRegistry(&child.objects, &child_actor.transmit, null);
    var child_handler: Handler = .{
        .objects = &child.objects,
        .queue = &child_actor.transmit,
        .registry = child_registry,
        .registry_only = true,
        .test_security_context = true,
    };
    try submitClient(&child_reactor, &child_driver, &child_handler);
    for (0..512) |_| {
        _ = try drainClient(&parent_reactor, &parent_driver, &parent_handler);
        _ = try drainClient(&child_reactor, &child_driver, &child_handler);
        _ = try loop.turn(coordinator);
        if (child_handler.compositor != null and root.runtime.registries.initial_count == 0)
            break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(child_handler.compositor != null);
    try std.testing.expect(!child_handler.security_global_seen);
    try std.testing.expect(!child_handler.ext_data_control_global_seen);
    try std.testing.expect(!child_handler.wlr_data_control_global_seen);
    try std.testing.expect(!child_handler.input_method_global_seen);
    try std.testing.expect(!child_handler.virtual_keyboard_global_seen);
    try std.testing.expect(!child_handler.virtual_pointer_global_seen);
    try std.testing.expect(!child_handler.foreign_toplevel_global_seen);
    try std.testing.expect(!child_handler.workspace_global_seen);
    try std.testing.expect(!child_handler.image_output_global_seen);
    try std.testing.expect(!child_handler.image_toplevel_global_seen);
    try std.testing.expect(!child_handler.image_copy_global_seen);
    try std.testing.expect(child_handler.security_manager == null);
    var sandbox_peer: ?wayring.io_uring.Peer = null;
    for (coordinator.clients.items) |client_state| if (client_state.active and
        coordinator.security_context_adapter.sandboxed(client_state.peer))
    {
        sandbox_peer = client_state.peer;
        break;
    };
    try std.testing.expect(sandbox_peer != null);
    const metadata = coordinator.security_context_adapter.metadata(sandbox_peer.?).?;
    try std.testing.expectEqualStrings("org.example.Sandbox", metadata.sandbox_engine.?);
    try std.testing.expectEqualStrings("org.example.Client", metadata.app_id.?);

    _ = linux.close(close_signal);
    close_signal = -1;
    for (0..256) |_| {
        _ = try drainClient(&parent_reactor, &parent_driver, &parent_handler);
        _ = try drainClient(&child_reactor, &child_driver, &child_handler);
        _ = try loop.turn(coordinator);
        if (listener.listen_fd < 0 and listener.close_fd < 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(linux.fd_t, -1), listener.listen_fd);
    try std.testing.expectEqual(@as(linux.fd_t, -1), listener.close_fd);

    _ = try parent.prepareClose();
    _ = try child.prepareClose();
    try submitClient(&parent_reactor, &parent_driver, &parent_handler);
    try submitClient(&child_reactor, &child_driver, &child_handler);
    try coordinator.requestStop();
    var drained = false;
    for (0..512) |_| {
        const parent_progress = try drainClient(&parent_reactor, &parent_driver, &parent_handler);
        const child_progress = try drainClient(&child_reactor, &child_driver, &child_handler);
        const progress = try loop.turn(coordinator);
        drained = progress.wayring.shutdown_complete and parent_progress.quiescent and
            child_progress.quiescent and coordinator.backendDrainComplete();
        if (drained) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try child.deinit(allocator);
    child_reactor.deinit(allocator);
    try parent.deinit(allocator);
    parent_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

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
    root_config.runtime.object_capacity = 128;
    root_config.runtime.object_quota = 128;
    root_config.runtime.buckets_per_client = 128;
    root_config.runtime.actor.received_fd_budget = 3;
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
    config.shm.pool_capacity = 3;
    config.shm.buffer_capacity = 3;
    config.surface.surface_capacity = 3;
    config.surface.content_update_capacity = 3;
    config.surface.dependency_capacity = 3;
    config.surface.attachment_capacity = 3;
    config.surface.copy_capacity = 3;
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
        .{ .max_objects = 128, .max_client_ids = 127 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: Handler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .test_pointer_warp = true,
        .test_foreign_toplevel = true,
        .test_wlr_foreign_toplevel = true,
        .test_toplevel_tag = true,
        .test_image_capture_sources = true,
        .test_toplevel_drag = true,
        .frame_before_map = true,
    };
    defer {
        if (handler.image_capture_read_fd >= 0)
            _ = linux.close(handler.image_capture_read_fd);
    }
    try submitClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var input_sent = false;
    var key_sent = false;
    var drag_release_sent = false;
    var toplevel_drag_active = false;
    var motion_redraw_sent = false;
    var motion_submission_start: ?usize = null;
    var motion_frame_observed = false;
    var two_layers_observed = false;
    var drag_icon_observed = false;
    var drag_icon_motion_observed = false;
    var first_drag_icon_destination: ?ouro.render.Rect = null;
    var first_cursor_destination: ?ouro.render.Rect = null;
    var client_progress: ClientDriver.Progress = .{};
    for (0..512) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        const submitted_before_turn = coordinator.stats.submitted;
        _ = try loop.turn(coordinator);
        if (motion_redraw_sent and motion_submission_start == null and
            input.cursor == input.event_count)
        {
            motion_submission_start = submitted_before_turn;
        }
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
        if (!toplevel_drag_active and handler.toplevel_drag_attached and
            coordinator.toplevel_drag_adapter.activeAttachment() != null)
        {
            toplevel_drag_active = true;
        }
        if (key_sent and !drag_release_sent and drag_icon_motion_observed and toplevel_drag_active and
            coordinator.data_device_adapter.dragActive() and
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
        if (coordinator.stats.submitted >= 2 and !two_layers_observed and
            coordinator.app_layers[0].sample != null and coordinator.cursor_layer.sample != null)
        {
            const app = coordinator.app_layers[0].sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const cursor_index: usize = if (coordinator.physical_outputs[0].drag_icon_previous != null) 2 else 1;
            const submitted = coordinator.primaryKmsOutput().?.sample_storage[0 .. cursor_index + 1];
            try std.testing.expectEqual(coordinator.app_layers[0].binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.sample, coordinator.app_layers[0].binding.?.sample);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[cursor_index].surface);
            try std.testing.expectEqual(cursor.sample, coordinator.cursor_layer.binding.?.sample);
            try std.testing.expectEqual(cursor.presentation, submitted[cursor_index].presentation);
            try std.testing.expectEqual(@as(i32, -1), app.destination.x);
            try std.testing.expectEqual(@as(i32, 0), app.destination.y);
            try std.testing.expectEqual(@as(u32, 3), app.destination.width);
            try std.testing.expectEqual(@as(u32, 2), app.destination.height);
            try std.testing.expect(cursor.destination.x >= 0 and cursor.destination.y >= 0);
            two_layers_observed = true;
        }
        if (!drag_icon_observed and coordinator.drag_icon_root != null and
            coordinator.physical_outputs[0].drag_icon_previous != null)
        {
            for (coordinator.app_layers[0..coordinator.app_layer_count]) |layer| {
                if (layer.id == null or !std.meta.eql(layer.id.?, coordinator.drag_icon_root.?)) continue;
                const icon = layer.sample orelse continue;
                try std.testing.expect(layer.floating);
                try std.testing.expectEqual(coordinator.interaction.cursor.position.x + 1, icon.destination.x);
                try std.testing.expectEqual(coordinator.interaction.cursor.position.y, icon.destination.y);
                try std.testing.expectEqual(@as(u32, 1), icon.destination.width);
                try std.testing.expectEqual(@as(u32, 1), icon.destination.height);
                first_drag_icon_destination = icon.destination;
                drag_icon_observed = true;
                break;
            }
        }
        if (coordinator.stats.presented >= 2 and drag_icon_observed and !motion_redraw_sent and
            coordinator.data_device_adapter.dragActive() and input.cursor == input.event_count and
            coordinator.cursor_layer.sample != null)
        {
            first_cursor_destination = coordinator.cursor_layer.sample.?.destination;
            try input.publish(&.{.{ .pointer_motion = .{
                .device = 42,
                .time_usec = 5_000,
                .dx = -1,
                .dy = 0,
            } }});
            motion_redraw_sent = true;
        }
        if (!motion_frame_observed and motion_submission_start != null and
            coordinator.stats.submitted > motion_submission_start.? and
            coordinator.app_layers[0].sample != null and coordinator.cursor_layer.sample != null)
        {
            const app = coordinator.app_layers[0].sample.?;
            const cursor = coordinator.cursor_layer.sample.?;
            const submitted = coordinator.primaryKmsOutput().?.sample_storage[0..3];
            try std.testing.expectEqual(coordinator.app_layers[0].binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(app.presentation, submitted[0].presentation);
            for (coordinator.app_layers[0..coordinator.app_layer_count]) |layer| {
                if (layer.id == null or coordinator.drag_icon_root == null or
                    !std.meta.eql(layer.id.?, coordinator.drag_icon_root.?)) continue;
                const icon = layer.sample orelse continue;
                try std.testing.expectEqual(layer.binding.?.surface, submitted[1].surface);
                try std.testing.expectEqual(icon.presentation, submitted[1].presentation);
                try std.testing.expectEqual(coordinator.interaction.cursor.position.x + 1, icon.destination.x);
                try std.testing.expectEqual(coordinator.interaction.cursor.position.y, icon.destination.y);
                if (!std.meta.eql(first_drag_icon_destination.?, icon.destination))
                    drag_icon_motion_observed = true;
                break;
            }
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[2].surface);
            try std.testing.expectEqual(cursor.presentation, submitted[2].presentation);
            if (!std.meta.eql(first_cursor_destination.?, cursor.destination))
                motion_frame_observed = true;
        }
        if (motion_frame_observed and
            coordinator.stats.presented >= motion_submission_start.? + 1 and
            coordinator.stats.submitted == coordinator.stats.presented and
            handler.pointer_motion == 2 and
            handler.pointer_button != 0 and handler.pointer_axis != 0 and
            handler.pointer_axis_value120 != 0 and handler.keyboard_key != 0 and
            handler.drag_cancelled == 1 and handler.drag_enter == 1 and
            handler.drag_leave == 1) break;
        if (handler.event_failures != 0) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0) {
            try waitForEither(&root.ring, client_reactor.ring);
        }
    }

    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try std.testing.expect(handler.configure_count >= 2);
    try std.testing.expect(handler.configure_serial != 0);
    try std.testing.expectEqual(handler.configure_serial, handler.acked_serial);
    try std.testing.expect(two_layers_observed);
    try std.testing.expect(drag_icon_observed);
    try std.testing.expect(drag_icon_motion_observed);
    try std.testing.expect(motion_frame_observed);
    try std.testing.expect(coordinator.stats.submitted >= motion_submission_start.? + 1);
    try std.testing.expectEqual(coordinator.stats.submitted, coordinator.stats.presented);
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
    try std.testing.expect(handler.toplevel_drag_attached);
    try std.testing.expect(toplevel_drag_active);
    try std.testing.expect(handler.toplevel_drag_destroyed);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis_source);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis);
    try std.testing.expectEqual(@as(usize, 1), handler.pointer_axis_value120);
    try std.testing.expectEqual(@as(usize, 5), handler.pointer_frame);
    try std.testing.expectEqual(@as(i32, 15 * 256), handler.pointer_axis_fixed);
    try std.testing.expectEqual(@as(i32, 120), handler.pointer_axis_value120_value);
    try std.testing.expectEqual(@as(usize, 1), handler.keyboard_key);
    try std.testing.expect(handler.buffer_release <= 1);
    try std.testing.expect(handler.output_geometry);
    try std.testing.expectEqual(@as(i32, 1), handler.output_physical_width);
    try std.testing.expectEqual(@as(i32, 1), handler.output_physical_height);
    try std.testing.expect(handler.output_mode);
    try std.testing.expect(handler.output_scale);
    try std.testing.expect(handler.output_name);
    try std.testing.expect(handler.output_description);
    try std.testing.expect(handler.output_done != 0);
    try std.testing.expect(coordinator.drag_icon_root == null);
    try std.testing.expectEqual(@as(usize, 3), handler.output_enter);
    try std.testing.expect(handler.output_leave <= 1);
    try std.testing.expect(!handler.output_released);
    try std.testing.expect(handler.foreign_toplevel_list != null);
    try std.testing.expect(handler.foreign_toplevel_handle != null);
    try std.testing.expect(handler.foreign_toplevel_title);
    try std.testing.expect(handler.foreign_toplevel_app_id);
    try std.testing.expect(handler.foreign_toplevel_identifier);
    try std.testing.expect(handler.foreign_toplevel_done >= 1);
    try std.testing.expectEqual(@as(usize, 1), handler.foreign_toplevel_finished);
    try std.testing.expectEqual(@as(u32, 3), handler.wlr_foreign_toplevel_version);
    try std.testing.expect(handler.wlr_foreign_toplevel_manager != null);
    try std.testing.expect(handler.wlr_foreign_toplevel_handle != null);
    try std.testing.expectEqual(@as(usize, 1), handler.wlr_foreign_toplevel_announcements);
    try std.testing.expectEqual(@as(usize, 7), handler.wlr_foreign_toplevel_initial_order);
    try std.testing.expect(handler.wlr_foreign_toplevel_done >= 1);
    try std.testing.expectEqual(@as(usize, 1), handler.wlr_foreign_toplevel_output_enter);
    try std.testing.expectEqual(@as(usize, 0), handler.wlr_foreign_toplevel_output_leave);
    try std.testing.expectEqual(@as(usize, 0), coordinator.foreign_toplevel_list_adapter.pendingCommands());
    try std.testing.expect(handler.toplevel_tag_set);
    const tagged_peer = coordinator.peer.?;
    const tagged_objects = try root.runtime.clients.get(tagged_peer);
    const tagged_id = try coordinator.shell_adapter.toplevelIdOn(tagged_objects, handler.toplevel.?.id);
    const tagged_metadata = try coordinator.shell_adapter.metadata(tagged_id);
    try std.testing.expectEqualStrings("main", tagged_metadata.tag);
    try std.testing.expectEqualStrings("Main window", tagged_metadata.description);
    try std.testing.expect(handler.image_output_source != null);
    try std.testing.expect(handler.image_toplevel_source != null);
    try std.testing.expect(handler.image_cursor_session != null);
    try std.testing.expect(handler.image_cursor_enter >= 1);
    try std.testing.expect(handler.image_cursor_position >= 1);
    try std.testing.expect(handler.image_cursor_hotspot >= 1);
    try std.testing.expectEqual(@as(i32, 0), handler.image_cursor_hotspot_x);
    try std.testing.expectEqual(@as(i32, 0), handler.image_cursor_hotspot_y);
    const capture_peer = coordinator.peer.?;
    const capture_objects = try root.runtime.clients.get(capture_peer);
    try std.testing.expect(coordinator.image_capture_source_adapter.snapshotForResource(
        capture_peer,
        capture_objects,
        handler.image_output_source.?.id,
    ).?.target != null);
    try std.testing.expect(coordinator.image_capture_source_adapter.snapshotForResource(
        capture_peer,
        capture_objects,
        handler.image_toplevel_source.?.id,
    ).?.target != null);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    try handler.queueToplevelCapture();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..128) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.image_capture_ready) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(handler.image_capture_ready);
    try std.testing.expectEqual(@as(u32, 3), handler.image_capture_width);
    try std.testing.expectEqual(@as(u32, 2), handler.image_capture_height);
    var toplevel_pixels: [24]u8 = undefined;
    const capture_read = linux.pread(
        handler.image_capture_read_fd,
        &toplevel_pixels,
        toplevel_pixels.len,
        0,
    );
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(capture_read));
    try std.testing.expectEqual(@as(usize, toplevel_pixels.len), capture_read);
    try std.testing.expectEqualSlices(u8, pixels[0..12], toplevel_pixels[0..12]);
    try std.testing.expectEqualSlices(u8, pixels[16..28], toplevel_pixels[12..24]);

    const motion_before_warp = handler.pointer_motion;
    try handler.queuePointerWarp();
    try submitClient(&client_reactor, &driver, &handler);
    for (0..64) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        const point = coordinator.seat_adapter.pointerState().point;
        if (point.x == 256 and point.y == 256) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(
        ouro.seat.Adapter(protocol, ouro.core_surface.Adapter(protocol)).Point{ .x = 256, .y = 256 },
        coordinator.seat_adapter.pointerState().point,
    );
    try std.testing.expectEqual(motion_before_warp, handler.pointer_motion);
    for (0..64) |_| {
        if (coordinator.stats.presented >= 4) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
    }
    const presented_before_disable = coordinator.stats.presented;
    const submitted_before_disable = coordinator.stats.submitted;

    const retained_app = coordinator.app_layers[0].sample.?;
    const retained_cursor = coordinator.cursor_layer.sample.?;
    const first_output_generation = coordinator.primaryKmsOutput().?.outputId().generation;
    try fixture.signalSession(.disable);
    for (0..128) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.primaryKmsOutput() == null and coordinator.session.state == .disabled and
            handler.output_leave == 3 and handler.wlr_foreign_toplevel_output_leave == 1) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(coordinator.primaryKmsOutput() == null);
    try std.testing.expectEqual(@as(usize, 3), handler.output_leave);
    try std.testing.expectEqual(@as(usize, 1), handler.wlr_foreign_toplevel_output_leave);
    try std.testing.expect(coordinator.app_layers[0].active);
    try std.testing.expect(coordinator.cursor_layer.active);
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layers[0].sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);
    try fixture.signalSession(.enable);
    for (0..128) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.stats.presented == presented_before_disable + 1 and handler.output_enter == 5 and
            handler.wlr_foreign_toplevel_output_enter == 2 and handler.output_deleted) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(coordinator.stats.submitted >= submitted_before_disable);
    try std.testing.expect(coordinator.stats.submitted <= submitted_before_disable + 1);
    try std.testing.expectEqual(presented_before_disable + 1, coordinator.stats.presented);
    try std.testing.expect(
        coordinator.primaryKmsOutput().?.outputId().generation != first_output_generation,
    );
    try std.testing.expectEqual(retained_app.sample, coordinator.app_layers[0].sample.?.sample);
    try std.testing.expectEqual(retained_cursor.sample, coordinator.cursor_layer.sample.?.sample);
    try std.testing.expectEqual(@as(usize, 5), handler.output_enter);
    try std.testing.expectEqual(@as(usize, 2), handler.wlr_foreign_toplevel_output_enter);
    try std.testing.expect(handler.output_released);
    try std.testing.expect(handler.output_deleted);
    try std.testing.expect(coordinator.image_capture_source_adapter.snapshotForResource(
        capture_peer,
        capture_objects,
        handler.image_output_source.?.id,
    ).?.target == null);

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

    try protocol.wl_surface.encodeRequest(handler.queue, handler.surface.?.id, .{
        .attach = .{ .buffer = null, .x = 0, .y = 0 },
    });
    try protocol.wl_surface.encodeRequest(handler.queue, handler.surface.?.id, .{ .commit = .{} });
    try submitClient(&client_reactor, &driver, &handler);
    for (0..64) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.buffer_release >= 1 and !coordinator.app_layers[0].active) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.buffer_release);
    try std.testing.expect(handler.buffer_release_order > handler.frame_done_order);
    try std.testing.expect(!coordinator.app_layers[0].active);

    try wayring.client.sendRequest(
        protocol.xdg_toplevel,
        handler.objects,
        handler.queue,
        handler.toplevel.?,
        .{ .destroy = .{} },
    );
    handler.toplevel = null;
    try wayring.client.sendRequest(
        protocol.xdg_surface,
        handler.objects,
        handler.queue,
        handler.xdg_surface.?,
        .{ .destroy = .{} },
    );
    handler.xdg_surface = null;
    try wayring.client.sendRequest(
        protocol.wl_surface,
        handler.objects,
        handler.queue,
        handler.surface.?,
        .{ .destroy = .{} },
    );
    handler.surface = null;
    try submitClient(&client_reactor, &driver, &handler);
    for (0..64) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.foreign_toplevel_closed == 1) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.foreign_toplevel_closed);
    try std.testing.expectEqual(@as(usize, 1), handler.wlr_foreign_toplevel_closed);
    try wayring.client.sendRequest(
        protocol.zwlr_foreign_toplevel_handle_v1,
        handler.objects,
        handler.queue,
        handler.wlr_foreign_toplevel_handle.?,
        .{ .destroy = .{} },
    );
    handler.wlr_foreign_toplevel_handle = null;
    try submitClient(&client_reactor, &driver, &handler);
    try std.testing.expect(coordinator.image_capture_source_adapter.snapshotForResource(
        capture_peer,
        capture_objects,
        handler.image_toplevel_source.?.id,
    ).?.target == null);

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

test "shell-input: tablet global delivers normalized device and tool metadata" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-tablet-{d}.sock", .{linux.getpid()});
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
    config.input.device_capacity = 1;
    config.input.event_capacity = 2;
    config.tablet_input.device_capacity = 1;
    config.tablet_input.tool_capacity = 1;
    config.tablet_input.event_capacity = 8;
    config.tablet_v2.manager_capacity = 1;
    config.tablet_v2.tablet_seat_capacity = 1;
    config.tablet_v2.tablet_capacity = 1;
    config.tablet_v2.tool_capacity = 1;
    config.tablet_v2.outbound_capacity = 8;
    const coordinator = try Coordinator.create(allocator, root, platforms, config);
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
    var handler: TabletHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    try submitTabletClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var published = false;
    var client_progress: ClientDriver.Progress = .{};
    for (0..512) |_| {
        client_progress = try drainTabletClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!published and handler.tablet_seat != null and coordinator.input != null) {
            try input.publish(&.{
                .{ .device_added = .{
                    .device = 42,
                    .info = .{
                        .capabilities = .{ .tablet_tool = true },
                        .vendor = 0x1234,
                        .product = 0x5678,
                    },
                } },
                .{ .tablet_tool_proximity = .{
                    .device = 42,
                    .tool = .{
                        .reference = 99,
                        .kind = .pen,
                        .serial = 7,
                        .hardware_id = 8,
                        .capabilities = .{ .pressure = true },
                    },
                    .time_usec = 1_000,
                    .entered = true,
                    .axes = .{ .x = 0.5, .y = 0.5, .pressure = 0.25 },
                } },
            });
            published = true;
        }
        if (handler.tablet_done == 1 and handler.tool_done == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(published);
    try std.testing.expectEqual(@as(usize, 1), handler.tablet_added);
    try std.testing.expectEqual(@as(usize, 1), handler.tool_added);
    try std.testing.expectEqual(@as(usize, 1), handler.tablet_done);
    try std.testing.expectEqual(@as(usize, 1), handler.tool_done);
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.input_events);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitTabletClient(&client_reactor, &driver, &handler);
    var drained = false;
    for (0..256) |_| {
        client_progress = try drainTabletClient(&client_reactor, &driver, &handler);
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
    coordinator.scene_windows = try allocator.realloc(coordinator.scene_windows, 1);
    coordinator.foreign_toplevels = try allocator.realloc(coordinator.foreign_toplevels, 1);
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
        .activation_mode = true,
        .metadata_commit_after_attach = true,
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
            const submitted = coordinator.primaryKmsOutput().?.sample_storage[0..2];
            try std.testing.expect(!std.meta.eql(submitted[0].surface, submitted[1].surface));
            const windows = try coordinator.desktop.sceneSnapshot(coordinator.scene_windows);
            const first = findLayer(coordinator.app_layers, windows[0].surface) orelse
                return error.MissingFirstLayer;
            const second = findLayer(coordinator.app_layers, windows[1].surface) orelse
                return error.MissingSecondLayer;
            try std.testing.expectEqual(first.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(second.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(first.change.?.current, first.change.?.previous);
            try std.testing.expectEqual(second.change.?.current, second.change.?.previous);
            try std.testing.expect(first.change.?.surface_damage == null);
            try std.testing.expect(second.change.?.surface_damage == null);
            try std.testing.expectEqual(@as(i32, 0), first.sample.?.destination.x);
            try std.testing.expectEqual(@as(u32, 3), first.sample.?.destination.width);
            try std.testing.expectEqual(@as(i32, 2), second.sample.?.destination.x);
            try std.testing.expectEqual(@as(u32, 3), second.sample.?.destination.width);
            observed = true;
        }
        if (observed and coordinator.stats.presented >= two_toplevel_cycle_count and
            handler.buffer_releases == two_toplevel_cycle_count * 2 and
            handler.frame_done == two_toplevel_cycle_count * 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(observed);
    try std.testing.expect(coordinator.stats.applied >= two_toplevel_cycle_count * 2);
    try std.testing.expect(coordinator.stats.submitted >= two_toplevel_cycle_count);
    try std.testing.expect(coordinator.stats.presented >= two_toplevel_cycle_count);
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
    for (0..128) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.pointer != null) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(handler.pointer != null);
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
    for (0..256) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.activation_done == 1 and
            std.meta.eql(coordinator.desktop.focused().?, windows[1].id)) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.activation_done);
    try std.testing.expectEqual(windows[1].id, coordinator.desktop.focused().?);

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

test "shell-input: secondary output removal closes its reactive layer popup root" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-layer-popup-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 52;
    root_config.runtime.object_quota = 52;
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
    const coordinator = try Coordinator.create(allocator, root, fixture.platformsWithHotplug(), config);
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
        .{ .max_objects = 52, .max_client_ids = 51 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: LayerPopupHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .minimum_outputs = 2,
        .reactive = true,
        // Model Vulkan clients which cannot allocate their first buffer until
        // the compositor publishes the selected output.
        .require_layer_enter_before_map = true,
    };
    try submitLayerPopupClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var observed = false;
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!observed and handler.layer_mapped and handler.popup_mapped and handler.releases == 2 and
            coordinator.stats.presented >= 1)
        {
            const layer_ids = try coordinator.layer_shell_adapter.ids(coordinator.layer_surface_ids);
            try std.testing.expectEqual(@as(usize, 1), layer_ids.len);
            const layer_state = try coordinator.layer_shell_adapter.state(layer_ids[0]);
            const work_area: @TypeOf(coordinator.desktop.workArea()) =
                .{ .x = 0, .y = 1, .width = 6, .height = 1 };
            try std.testing.expectEqual(work_area, coordinator.desktop.workArea());
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
            const submitted = coordinator.physical_outputs[1].kms_output.?.sample_storage[0..2];
            const layer = findLayer(coordinator.app_layers, layer_state.surface) orelse
                return error.MissingLayerSurface;
            const popup = findLayer(coordinator.app_layers, popups[0].surface) orelse
                return error.MissingPopupSurface;
            if (!std.meta.eql(popup.binding.?.surface, submitted[1].surface)) {
                const delay: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
                _ = linux.nanosleep(&delay, null);
                continue;
            }
            try std.testing.expectEqual(layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(popup.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(@as(i32, 3), layer.sample.?.destination.x);
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
    try std.testing.expectEqual(@as(usize, 1), handler.layer_enters);
    try std.testing.expectEqual(@as(usize, 0), handler.layer_leaves);

    const layer_ids = try coordinator.layer_shell_adapter.ids(coordinator.layer_surface_ids);
    const layer_state = try coordinator.layer_shell_adapter.state(layer_ids[0]);
    var popup_storage: [2]@TypeOf(coordinator.scene_windows[0]) = undefined;
    var popups = try coordinator.desktop.externalPopupSnapshot(
        layer_state.surface,
        &popup_storage,
    );
    try std.testing.expectEqual(@as(usize, 1), popups.len);

    try fixture.signalSession(.disable);
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output == null and
            coordinator.physical_outputs[1].kms_output == null and
            coordinator.session.state == .disabled and handler.layer_leaves == 1) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(@as(usize, 1), handler.layer_leaves);
    try fixture.signalSession(.enable);
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (coordinator.physical_outputs[0].kms_output != null and
            coordinator.physical_outputs[1].kms_output != null and
            handler.layer_enters == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), handler.layer_enters);
    try std.testing.expectEqual(@as(usize, 0), handler.layer_closed);
    popups = try coordinator.desktop.externalPopupSnapshot(layer_state.surface, &popup_storage);
    try std.testing.expectEqual(@as(usize, 1), popups.len);
    try std.testing.expect(popups[0].visible);

    const popup_configures_before_reposition = handler.popup_configure_count;
    handler.hold_popup_configures = true;
    try handler.repositionPopup();
    for (0..256) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.popup_configure_count > popup_configures_before_reposition) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(
        popup_configures_before_reposition + 1,
        handler.popup_configure_count,
    );
    try std.testing.expect(handler.popup_configures[handler.popup_configure_count - 1] !=
        handler.popup_configures[handler.popup_configure_count - 2]);

    fixture.second_desktop = false;
    try fixture.signalHotplug();
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.layer_closed == 1 and
            !coordinator.physical_outputs[1].connected and
            !coordinator.physical_outputs[1].removing) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), handler.layer_closed);
    try std.testing.expect(!coordinator.physical_outputs[1].connected);
    try std.testing.expectEqual(
        popup_configures_before_reposition + 1,
        handler.popup_configure_count,
    );
    try std.testing.expectEqual(@as(usize, 2), handler.layer_leaves);
    popups = try coordinator.desktop.externalPopupSnapshot(layer_state.surface, &popup_storage);
    try std.testing.expectEqual(@as(usize, 1), popups.len);
    try std.testing.expect(!popups[0].visible);
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

test "shell-input: popup applies each acknowledged configure after output removal" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-toplevel-popup-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    fixture.second_desktop = true;
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 52;
    root_config.runtime.object_quota = 52;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.shm.pool_capacity = 2;
    config.shm.buffer_capacity = 2;
    config.surface.surface_capacity = 2;
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
        fixture.platformsWithHotplug(),
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
        .{ .max_objects = 52, .max_client_ids = 51 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: LayerPopupHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .minimum_outputs = 2,
        .toplevel_root = true,
        .reactive = true,
    };
    try submitLayerPopupClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var scene_storage: [4]@TypeOf(coordinator.scene_windows[0]) = undefined;
    var root_id: ?@TypeOf(coordinator.scene_windows[0].id) = null;
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.layer_mapped and handler.popup_mapped and handler.releases == 2) {
            const scene = try coordinator.desktop.sceneSnapshot(&scene_storage);
            if (scene.len == 2) {
                for (scene) |window| {
                    const surface = try coordinator.adapter.surfaceHandle(window.surface);
                    if (surface.id == handler.layer_wl_surface.?.id) root_id = window.id;
                }
                if (root_id != null) break;
            }
        }
        _ = linux.sched_yield();
    }
    try std.testing.expect(root_id != null);
    try std.testing.expectEqual(@as(usize, 1), handler.popup_configure_count);

    try coordinator.desktop.setFloating(root_id.?, true);
    try coordinator.desktop.setFloatingGeometry(
        root_id.?,
        .{ .x = 3, .y = 0, .width = 2, .height = 2 },
    );
    for (0..256) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        const root_scene = try coordinator.desktop.scene(root_id.?);
        if (root_scene.geometry.x == 3) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(i32, 3), (try coordinator.desktop.scene(root_id.?)).geometry.x);

    handler.hold_popup_configures = true;
    const before_move = handler.popup_configure_count;
    try handler.repositionPopup();
    for (0..256) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.popup_configure_count > before_move) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.popup_configure_count > before_move);
    const stale_serial = handler.popup_configures[handler.popup_configure_count - 1];

    fixture.second_desktop = false;
    try fixture.signalHotplug();
    const before_removal = handler.popup_configure_count;
    for (0..512) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (handler.popup_configure_count > before_removal and
            !coordinator.physical_outputs[1].connected and
            !coordinator.physical_outputs[1].removing) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(handler.popup_configure_count > before_removal);
    try std.testing.expect(!coordinator.physical_outputs[1].connected);
    const current_serial = handler.popup_configures[handler.popup_configure_count - 1];
    try std.testing.expect(stale_serial != current_serial);

    var scene = try coordinator.desktop.sceneSnapshot(&scene_storage);
    var popup_before_stale: ?@TypeOf(scene[0].geometry) = null;
    for (scene) |window| {
        const surface = try coordinator.adapter.surfaceHandle(window.surface);
        if (surface.id == handler.popup_surface.?.id) popup_before_stale = window.geometry;
    }
    try std.testing.expect(popup_before_stale != null);
    try std.testing.expect(popup_before_stale.?.x >= 3);

    try handler.ackPopupConfigure(stale_serial);
    try handler.commitPopup();
    for (0..32) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (client_progress.quiescent and handler.queue.queuedBytes() == 0) break;
    }
    scene = try coordinator.desktop.sceneSnapshot(&scene_storage);
    var stale_applied = false;
    for (scene) |window| {
        const surface = try coordinator.adapter.surfaceHandle(window.surface);
        if (surface.id == handler.popup_surface.?.id) {
            try std.testing.expectEqual(@as(i32, 3), window.geometry.x);
            try std.testing.expect(!std.meta.eql(popup_before_stale.?, window.geometry));
            stale_applied = true;
        }
    }
    try std.testing.expect(stale_applied);

    try handler.ackPopupConfigure(current_serial);
    try handler.commitPopup();
    var routed_to_primary = false;
    for (0..256) |_| {
        client_progress = try drainLayerPopupClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        scene = try coordinator.desktop.sceneSnapshot(&scene_storage);
        for (scene) |window| {
            const surface = try coordinator.adapter.surfaceHandle(window.surface);
            if (surface.id == handler.popup_surface.?.id and window.geometry.x >= 0 and
                window.geometry.x + window.geometry.width <= 3)
                routed_to_primary = true;
        }
        if (routed_to_primary) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(routed_to_primary);

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
        _ = linux.sched_yield();
    }
    try std.testing.expect(drained);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    try client.deinit(allocator);
    client_reactor.deinit(allocator);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

test "shell-input: screencopy captures clipped output into writable SHM" {
    try runScreencopyCapture(false, false);
}

test "shell-input: copy with damage waits for a newer output frame" {
    try runScreencopyCapture(false, true);
}

test "shell-input: session disable fails pending screencopy" {
    try runScreencopyCapture(true, false);
}

fn runScreencopyCapture(interrupt: bool, repeat_with_damage: bool) !void {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-screencopy-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 24;
    root_config.runtime.object_quota = 24;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
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
    var rotated = coordinator.output_management_adapter.lifecycle.current;
    rotated.transform = 1;
    _ = try coordinator.output_management_adapter.publishHead(
        coordinator.output_management_adapter.lifecycle.primary,
        rotated,
    );

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
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: ScreencopyHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .capture_goal = if (repeat_with_damage) 2 else 1,
    };
    defer {
        if (handler.read_fd >= 0) _ = linux.close(handler.read_fd);
    }
    try submitClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var disable_sent = false;
    var damage_sent = false;
    for (0..512) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        if (repeat_with_damage and handler.ready_events == 1 and !handler.capture_requested) {
            try handler.maybeCapture();
            try submitClient(&client_reactor, &driver, &handler);
        }
        _ = try loop.turn(coordinator);
        if (interrupt and !disable_sent and coordinator.pending_screencopy != null) {
            try fixture.signalSession(.disable);
            disable_sent = true;
        }
        if (repeat_with_damage and !damage_sent and handler.ready_events == 1 and
            coordinator.screencopy_adapter.capture_count == 1 and
            coordinator.pending_screencopy == null)
        {
            try coordinator.primaryKmsOutput().?.request(.damage, 1);
            damage_sent = true;
            _ = try loop.turn(coordinator);
        }
        if ((!interrupt and handler.ready) or
            (interrupt and handler.failed and coordinator.pending_screencopy == null and
                coordinator.session.state == .disabled)) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(interrupt, disable_sent);
    try std.testing.expectEqual(!interrupt, handler.ready);
    try std.testing.expectEqual(interrupt, handler.failed);
    try std.testing.expectEqual(repeat_with_damage, damage_sent);
    const completed: usize = if (repeat_with_damage) 2 else 1;
    try std.testing.expectEqual(completed, handler.buffer_events);
    try std.testing.expectEqual(completed, handler.buffer_done_events);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    if (interrupt) {
        try std.testing.expect(coordinator.pending_screencopy == null);
        try std.testing.expectEqual(.disabled, coordinator.session.state);
    } else {
        try std.testing.expectEqual(
            .@"90",
            coordinator.primaryKmsOutput().?.planner.output_transform,
        );
        try std.testing.expectEqual(completed, handler.flags_events);
        try std.testing.expectEqual(completed, handler.damage_events);
        var captured: [4]u8 = undefined;
        const read = linux.pread(handler.read_fd, &captured, captured.len, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read));
        try std.testing.expectEqual(@as(usize, captured.len), read);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xff }, &captured);
    }

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitClient(&client_reactor, &driver, &handler);
    var drained = false;
    for (0..256) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
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

test "shell-input: image copy capture publishes constraints and writes output SHM" {
    try runImageCopyCapture(false);
}

test "shell-input: session disable fails image copy frame and stops session" {
    try runImageCopyCapture(true);
}

fn runImageCopyCapture(interrupt: bool) !void {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-image-copy-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 24;
    root_config.runtime.object_quota = 24;
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(path, 1),
        root_config,
    );
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 24;
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
    var rotated = coordinator.output_management_adapter.lifecycle.current;
    rotated.transform = 1;
    _ = try coordinator.output_management_adapter.publishHead(
        coordinator.output_management_adapter.lifecycle.primary,
        rotated,
    );

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
        .{ .received_fd_budget = 1, .transmit_byte_budget = 4096, .transmit_fd_budget = 1 },
        .{ .max_objects = 16, .max_client_ids = 15 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: ImageCopyHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
    };
    defer {
        if (handler.read_fd >= 0) _ = linux.close(handler.read_fd);
    }
    try submitClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var disable_sent = false;
    for (0..512) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (interrupt and !disable_sent and coordinator.pending_image_copy != null) {
            try fixture.signalSession(.disable);
            disable_sent = true;
        }
        if ((!interrupt and handler.ready) or
            (interrupt and handler.failed and handler.stopped and
                coordinator.pending_image_copy == null and
                coordinator.session.state == .disabled)) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expectEqual(interrupt, disable_sent);
    try std.testing.expectEqual(!interrupt, handler.ready);
    try std.testing.expectEqual(interrupt, handler.failed);
    try std.testing.expectEqual(interrupt, handler.stopped);
    try std.testing.expectEqual(@as(usize, 1), handler.buffer_size_events);
    try std.testing.expectEqual(@as(usize, 2), handler.shm_format_events);
    try std.testing.expectEqual(@as(usize, 1), handler.constraints_done_events);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);
    if (interrupt) {
        try std.testing.expect(coordinator.pending_image_copy == null);
        try std.testing.expectEqual(.disabled, coordinator.session.state);
    } else {
        try std.testing.expectEqual(@as(usize, 1), handler.transform_events);
        try std.testing.expectEqual(@as(usize, 1), handler.damage_events);
        try std.testing.expectEqual(@as(usize, 1), handler.presentation_events);
        var captured: [24]u8 = undefined;
        const read = linux.pread(handler.read_fd, &captured, captured.len, 0);
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(read));
        try std.testing.expectEqual(@as(usize, captured.len), read);
        const black_pixel = [_]u8{ 0, 0, 0, 0xff };
        for (0..6) |pixel|
            try std.testing.expectEqualSlices(u8, &black_pixel, captured[pixel * 4 ..][0..4]);
    }

    coordinator.disconnected(coordinator.peer.?);
    _ = try client.prepareClose();
    try submitClient(&client_reactor, &driver, &handler);
    var drained = false;
    for (0..256) |_| {
        client_progress = try drainClient(&client_reactor, &driver, &handler);
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

test "shell-input: synchronized cursor subsurface batch renders root and child" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-cursor-subsurface-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 24;
    root_config.runtime.object_quota = 24;
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
    config.surface.content_update_capacity = 2;
    config.surface.dependency_capacity = 2;
    config.surface.attachment_capacity = 2;
    config.surface.copy_capacity = 2;
    config.output.max_samples = 2;
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
        .{ .max_objects = 24, .max_client_ids = 23 },
    );
    const actor = try client.actor();
    var driver = ClientDriver.init(&client);
    const registry = try ClientCore.getRegistry(&client.objects, &actor.transmit, null);
    var handler: MultiHandler = .{
        .objects = &client.objects,
        .queue = &actor.transmit,
        .registry = registry,
        .cycle_count = 1,
        .cursor_mode = true,
    };
    try submitMultiClient(&client_reactor, &driver, &handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var client_progress: ClientDriver.Progress = .{};
    var committed = false;
    var observed = false;
    for (0..512) |_| {
        client_progress = try drainMultiClient(&client_reactor, &driver, &handler);
        _ = try loop.turn(coordinator);
        if (!committed and handler.shell_created) {
            const root_id = coordinator.adapter.surfaceId(handler.surfaces[0].?) catch null;
            if (root_id) |cursor_root| {
                _ = try coordinator.adapter.surfaceId(handler.surfaces[1].?);
                const pointer_device: ouro.input_backend.DeviceId = .{
                    .slot = 0,
                    .generation = 1,
                    .seat_generation = 1,
                };
                try std.testing.expect(try coordinator.acceptNormalizedInput(.{ .device_added = .{
                    .device = pointer_device,
                    .info = .{ .capabilities = .{ .pointer = true } },
                } }));
                coordinator.interaction.cursorRequest(cursor_root, .{ .x = 0, .y = 0 });
                try handler.mapSurface(1);
                try handler.mapSurface(0);
                try submitMultiClient(&client_reactor, &driver, &handler);
                committed = true;
            }
        }
        if (!observed and coordinator.stats.submitted == 1) {
            const root_id = try coordinator.adapter.surfaceId(handler.surfaces[0].?);
            const child_id = try coordinator.adapter.surfaceId(handler.surfaces[1].?);
            const child_layer = findLayer(coordinator.app_layers, child_id) orelse
                return error.MissingChildLayer;
            const submitted = coordinator.primaryKmsOutput().?.sample_storage[0..2];
            try std.testing.expectEqual(coordinator.cursor_layer.binding.?.surface, submitted[0].surface);
            try std.testing.expectEqual(child_layer.binding.?.surface, submitted[1].surface);
            try std.testing.expectEqual(root_id, coordinator.cursor_layer.id.?);
            try std.testing.expectEqual(
                coordinator.cursor_layer.sample.?.destination.x + 1,
                child_layer.sample.?.destination.x,
            );
            try std.testing.expectEqual(
                coordinator.cursor_layer.sample.?.destination.y,
                child_layer.sample.?.destination.y,
            );
            observed = true;
        }
        if (observed and coordinator.stats.presented == 1 and
            handler.buffer_releases == 2 and handler.frame_done == 2) break;
        if (root.ring.cq_ready() == 0 and client_reactor.ring.cq_ready() == 0)
            try waitForEither(&root.ring, client_reactor.ring);
    }
    try std.testing.expect(committed);
    try std.testing.expect(observed);
    try std.testing.expectEqual(@as(usize, 2), coordinator.stats.applied);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.submitted);
    try std.testing.expectEqual(@as(usize, 1), coordinator.stats.presented);
    try std.testing.expectEqual(@as(usize, 2), handler.buffer_releases);
    try std.testing.expectEqual(@as(usize, 2), handler.frame_done);
    try std.testing.expectEqual(@as(usize, 0), handler.event_failures);

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
            const submitted = coordinator.primaryKmsOutput().?.sample_storage[0..2];
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

test "shell-input: generated input-method client bridges focused text input" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-input-method-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};

    var fixture = try physical_fixture.Fixture.init();
    defer fixture.deinit();
    var input = try FakeInput.init();
    defer input.deinit();
    var root_config = physical_fixture.compositorConfig();
    root_config.runtime.object_capacity = 96;
    root_config.runtime.object_quota = 48;
    root_config.runtime.registry_capacity = 2;
    const root = try Compositor.create(allocator, try wayring.unix_socket.listen(path, 2), root_config);
    var config = physical_fixture.coordinatorConfig();
    config.router_capacity = 32;
    config.virtual_keyboard_reconciles_focus = true;
    var platforms = fixture.platforms();
    platforms.input = input.platform();
    const coordinator = try Coordinator.create(allocator, root, platforms, config);
    var loop = try Loop.init(allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 32 });
    try coordinator.start(&loop);

    var app_reactor: wayring.io_uring.Reactor = undefined;
    try app_reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var app = try ClientConnection.attach(allocator, &app_reactor, try wayring.unix_socket.connect(path), .{ .received_fd_budget = 2, .transmit_byte_budget = 8192, .transmit_fd_budget = 2 }, .{ .max_objects = 48, .max_client_ids = 47 });
    const app_actor = try app.actor();
    var app_driver = ClientDriver.init(&app);
    const app_registry = try ClientCore.getRegistry(&app.objects, &app_actor.transmit, null);
    var app_handler: Handler = .{
        .objects = &app.objects,
        .queue = &app_actor.transmit,
        .registry = app_registry,
        .test_text_input = true,
        .pointer_axis_expected_time = 17,
    };
    try submitClient(&app_reactor, &app_driver, &app_handler);

    var method_reactor: wayring.io_uring.Reactor = undefined;
    try method_reactor.initOwned(allocator, .{ .entries = 16, .flags = 0 }, physical_fixture.clientReactorConfig());
    var method_client = try ClientConnection.attach(allocator, &method_reactor, try wayring.unix_socket.connect(path), .{ .received_fd_budget = 2, .transmit_byte_budget = 8192, .transmit_fd_budget = 2 }, .{ .max_objects = 16, .max_client_ids = 15 });
    const method_actor = try method_client.actor();
    var method_driver = ClientDriver.init(&method_client);
    const method_registry = try ClientCore.getRegistry(&method_client.objects, &method_actor.transmit, null);
    var method_handler: InputMethodHandler = .{ .objects = &method_client.objects, .queue = &method_actor.transmit, .registry = method_registry };
    try submitClient(&method_reactor, &method_driver, &method_handler);

    _ = try loop.turn(coordinator);
    try fixture.signalSession(.enable);
    var device_added = false;
    var focus_clicked = false;
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (!device_added and coordinator.input != null) {
            try input.publish(&.{.{ .device_added = .{ .device = 42, .info = .{ .capabilities = .{ .pointer = true, .keyboard = true } } } }});
            device_added = true;
        }
        if (device_added and !focus_clicked and app_handler.mapped and app_handler.input_ready and input.cursor == input.event_count) {
            try input.publish(&.{
                .{ .pointer_motion = .{ .device = 42, .time_usec = 1_000, .dx = 1, .dy = 1 } },
                .{ .pointer_button = .{ .device = 42, .time_usec = 2_000, .button = 0x110, .pressed = true } },
            });
            focus_clicked = true;
        }
        if (app_handler.text_input_enter == 1 and method_handler.unavailable == 1 and
            method_handler.grab_keymap == 1 and method_handler.grab_repeat == 1 and
            method_handler.grab_modifiers >= 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(app_handler.mapped);
    try std.testing.expectEqual(@as(usize, 1), app_handler.text_input_enter);
    try std.testing.expect(method_handler.method != null);
    try std.testing.expect(method_handler.popup_surface != null);
    try std.testing.expect(method_handler.popup != null);
    const method_server_objects = try root.runtime.clients.get(coordinator.clients.items[1].peer);
    const popup_surface_handle = method_server_objects.namespace.lookupHandle(method_handler.popup_surface.?.id).?;
    const popup_surface_object = method_server_objects.namespace.resolve(popup_surface_handle).?;
    const popup_core_surface = try coordinator.adapter.getSurfaceObject(
        popup_surface_handle,
        popup_surface_object,
    );
    try std.testing.expect(popup_core_surface.role.id != 0);
    const popup_role = popup_core_surface.role.id;
    try std.testing.expect(popup_core_surface.role.object_active);
    try wayring.client.sendRequest(
        protocol.zwp_input_popup_surface_v2,
        &method_client.objects,
        &method_actor.transmit,
        method_handler.popup.?,
        .{ .destroy = .{} },
    );
    method_handler.popup = null;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..64) |_| {
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (!popup_core_surface.role.object_active) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(popup_role, popup_core_surface.role.id);
    try std.testing.expect(!popup_core_surface.role.object_active);
    try std.testing.expectEqual(@as(usize, 1), method_handler.unavailable);
    try std.testing.expectEqual(@as(usize, 1), method_handler.grab_keymap);
    try std.testing.expectEqual(@as(usize, 1), method_handler.grab_repeat);
    try std.testing.expectEqual(@as(usize, 1), method_handler.grab_modifiers);
    try std.testing.expect(method_handler.grab_initial_valid);

    try input.publish(&.{
        .{ .keyboard_key = .{ .device = 42, .time_usec = 3_000, .key = 42, .pressed = true } },
        .{ .keyboard_key = .{ .device = 42, .time_usec = 4_000, .key = 30, .pressed = true } },
        .{ .keyboard_key = .{ .device = 42, .time_usec = 5_000, .key = 30, .pressed = false } },
        .{ .keyboard_key = .{ .device = 42, .time_usec = 6_000, .key = 42, .pressed = false } },
    });
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (method_handler.grab_keys == 4 and method_handler.grab_modifiers == 3) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(input.event_count, input.cursor);
    try std.testing.expect(coordinator.input_method_adapter.activeGrab() != null);
    try std.testing.expectEqual(@as(usize, 4), method_handler.grab_keys);
    try std.testing.expectEqual(@as(usize, 3), method_handler.grab_modifiers);
    try std.testing.expect(method_handler.grab_keys_valid);

    // Model a headless seat which selected its desktop window before any
    // keyboard existed. Installing the virtual keymap must reconcile that
    // selected window before the immediately following key events.
    try coordinator.seat_adapter.setKeyboardFocus(null);
    const virtual_keyboard = method_handler.virtual_keyboard.?;
    const keymap = coordinator.seat_adapter.keyboardSnapshot();
    const keymap_fd = try coordinator.seat_adapter.duplicateKeymap();
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .keymap = .{
        .format = .xkb_v1,
        .fd = keymap_fd,
        .size = keymap.keymap_size,
    } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .key = .{ .time = 7, .key = 30, .state = 1 } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .key = .{ .time = 8, .key = 30, .state = 1 } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .key = .{ .time = 9, .key = 30, .state = 0 } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .key = .{ .time = 10, .key = 30, .state = 0 } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .key = .{ .time = 11, .key = 31, .state = 1 } });
    try protocol.zwp_virtual_keyboard_v1.encodeRequest(&method_actor.transmit, virtual_keyboard.id, .{ .modifiers = .{
        .mods_depressed = 1,
        .mods_latched = 2,
        .mods_locked = 4,
        .group = 1,
    } });
    try wayring.client.sendRequest(
        protocol.zwp_virtual_keyboard_v1,
        &method_client.objects,
        &method_actor.transmit,
        virtual_keyboard,
        .{ .destroy = .{} },
    );
    method_handler.virtual_keyboard = null;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (app_handler.keyboard_key == 4 and method_handler.grab_keymap == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 4), app_handler.keyboard_key);
    try std.testing.expectEqual(@as(usize, 2), method_handler.grab_keymap);
    try std.testing.expectEqual(@as(usize, 4), method_handler.grab_keys);

    const virtual_pointer = method_handler.virtual_pointer.?;
    const pointer_buttons_before = app_handler.pointer_button;
    const pointer_axes_before = app_handler.pointer_axis;
    const pointer_position_before = coordinator.interaction.pointerPosition();
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .motion = .{ .time = 12, .dx = 256, .dy = 0 } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .button = .{ .time = 13, .button = 0x111, .state = .pressed } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .button = .{ .time = 14, .button = 0x111, .state = .pressed } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .button = .{ .time = 15, .button = 0x111, .state = .released } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .button = .{ .time = 16, .button = 0x111, .state = .released } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .axis_source = .{ .axis_source = .wheel } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .axis_discrete = .{ .time = 17, .axis = .vertical_scroll, .value = 256, .discrete = 1 } });
    try protocol.zwlr_virtual_pointer_v1.encodeRequest(&method_actor.transmit, virtual_pointer.id, .{ .frame = .{} });
    try wayring.client.sendRequest(
        protocol.zwlr_virtual_pointer_v1,
        &method_client.objects,
        &method_actor.transmit,
        virtual_pointer,
        .{ .destroy = .{} },
    );
    method_handler.virtual_pointer = null;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (app_handler.pointer_button == pointer_buttons_before + 2 and
            app_handler.pointer_axis == pointer_axes_before + 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(u4, 0b0101), app_handler.virtual_pointer_button_times);
    try std.testing.expectEqual(@as(usize, 0), app_handler.zero_time_pointer_buttons);
    try std.testing.expectEqual(pointer_buttons_before + 2, app_handler.pointer_button);
    try std.testing.expectEqual(pointer_axes_before + 1, app_handler.pointer_axis);
    try std.testing.expectEqual(
        pointer_position_before.x + 1,
        coordinator.interaction.pointerPosition().x,
    );

    const method_done_before_enable = method_handler.done;
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .enable = .{} });
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .set_surrounding_text = .{ .text = "hello world", .cursor = 5, .anchor = 3 } });
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .set_text_change_cause = .{ .cause = .other } });
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .set_content_type = .{ .hint = .completion, .purpose = .email } });
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .set_cursor_rectangle = .{ .x = 7, .y = 11, .width = 13, .height = 17 } });
    try protocol.zwp_text_input_v3.encodeRequest(&app_actor.transmit, app_handler.text_input.?.id, .{ .commit = .{} });
    try submitClient(&app_reactor, &app_driver, &app_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (method_handler.done > method_done_before_enable) break;
        if (root.ring.cq_ready() == 0 and app_reactor.ring.cq_ready() == 0 and method_reactor.ring.cq_ready() == 0)
            try waitForAny(&root.ring, app_reactor.ring, method_reactor.ring);
    }
    try std.testing.expect(method_handler.state_valid);
    try std.testing.expectEqual(@as(usize, 1), method_handler.activate);
    try std.testing.expectEqual(@as(usize, 1), method_handler.surrounding);
    try std.testing.expectEqual(@as(usize, 1), method_handler.cause);
    try std.testing.expectEqual(@as(usize, 1), method_handler.content);
    try std.testing.expectEqual(@as(usize, 1), method_handler.done);

    method_handler.popup_surface = (try protocol.wl_compositor.construct_create_surface(
        &method_client.objects,
        &method_actor.transmit,
        method_handler.compositor.?,
        .{},
    )).id;
    method_handler.popup = (try protocol.zwp_input_method_v2.construct_get_input_popup_surface(
        &method_client.objects,
        &method_actor.transmit,
        method_handler.method.?,
        .{ .surface = method_handler.popup_surface.?.id },
    )).id;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..128) |_| {
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (method_handler.popup_rectangles == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), method_handler.popup_rectangles);
    try std.testing.expectEqual(@as(i32, 13), method_handler.popup_rectangle.width);
    try std.testing.expectEqual(@as(i32, 17), method_handler.popup_rectangle.height);
    const active_popup_handle = method_server_objects.namespace.lookupHandle(method_handler.popup_surface.?.id).?;
    const active_popup_object = method_server_objects.namespace.resolve(active_popup_handle).?;
    const active_popup_surface = try coordinator.adapter.surfaceIdObject(
        active_popup_handle,
        active_popup_object,
    );
    const active_popup_scene = try coordinator.desktop.sceneForSurface(active_popup_surface);
    try std.testing.expect(active_popup_scene.visible);
    try std.testing.expectEqual(@as(usize, 1), coordinator.input_popup_scene_len);
    try std.testing.expectEqual(
        coordinator.physical_outputs[0].id,
        coordinator.input_popup_scenes[0].output,
    );
    try wayring.client.sendRequest(
        protocol.zwp_input_popup_surface_v2,
        &method_client.objects,
        &method_actor.transmit,
        method_handler.popup.?,
        .{ .destroy = .{} },
    );
    method_handler.popup = null;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..64) |_| {
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (coordinator.input_popup_scene_len == 0) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 0), coordinator.input_popup_scene_len);
    try std.testing.expectError(
        error.StaleSurface,
        coordinator.desktop.sceneForSurface(active_popup_surface),
    );

    const im = method_handler.method.?;
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit_string = .{ .text = "stale" } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .set_preedit_string = .{ .text = "bad", .cursor_begin = 0, .cursor_end = 1 } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .delete_surrounding_text = .{ .before_length = 9, .after_length = 9 } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit = .{ .serial = 0 } });
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..64) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 0), app_handler.text_input_done);

    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit_string = .{ .text = "committed" } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .set_preedit_string = .{ .text = "pré", .cursor_begin = 2, .cursor_end = 4 } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .delete_surrounding_text = .{ .before_length = 4, .after_length = 2 } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit = .{ .serial = 1 } });
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (app_handler.text_input_done == 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), app_handler.text_input_preedit);
    try std.testing.expectEqual(@as(usize, 1), app_handler.text_input_commit);
    try std.testing.expectEqual(@as(usize, 1), app_handler.text_input_delete);
    try std.testing.expect(app_handler.text_input_preedit_valid and app_handler.text_input_commit_valid and app_handler.text_input_delete_valid);
    try std.testing.expectEqual(@as(usize, 1), app_handler.text_input_done);

    try wayring.client.sendRequest(protocol.zwp_input_method_manager_v2, &method_client.objects, &method_actor.transmit, method_handler.manager.?, .{ .destroy = .{} });
    method_handler.manager = null;
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit_string = .{ .text = "committed" } });
    try protocol.zwp_input_method_v2.encodeRequest(&method_actor.transmit, im.id, .{ .commit = .{ .serial = 1 } });
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (app_handler.text_input_done == 2) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 2), app_handler.text_input_done);
    try std.testing.expectEqual(@as(usize, 0), app_handler.event_failures);
    try std.testing.expectEqual(@as(usize, 0), method_handler.event_failures);

    const retained_popup_surface = (try protocol.wl_compositor.construct_create_surface(
        &method_client.objects,
        &method_actor.transmit,
        method_handler.compositor.?,
        .{},
    )).id;
    const retained_popup = (try protocol.zwp_input_method_v2.construct_get_input_popup_surface(
        &method_client.objects,
        &method_actor.transmit,
        im,
        .{ .surface = retained_popup_surface.id },
    )).id;
    const retained_grab = method_handler.keyboard_grab.?;
    const done_before_destroy = method_handler.done;
    try wayring.client.sendRequest(
        protocol.zwp_text_input_v3,
        &app.objects,
        &app_actor.transmit,
        app_handler.text_input.?,
        .{ .destroy = .{} },
    );
    app_handler.text_input = null;
    try submitClient(&app_reactor, &app_driver, &app_handler);
    for (0..512) |_| {
        _ = try drainClient(&app_reactor, &app_driver, &app_handler);
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (method_handler.deactivate == 1 and method_handler.done == done_before_destroy + 1) break;
        _ = linux.sched_yield();
    }
    try std.testing.expectEqual(@as(usize, 1), method_handler.deactivate);
    try std.testing.expectEqual(done_before_destroy + 1, method_handler.done);

    // The parent destructor implicitly retires these child proxies. Wayring's
    // generic client does not yet encode that XML relationship, so mirror the
    // generated-client lifecycle before waiting for the server delete_ids.
    _ = try method_client.objects.retireLocal(retained_popup);
    _ = try method_client.objects.retireLocal(retained_grab);
    method_handler.destroyed_popup_id = retained_popup.id;
    method_handler.destroyed_grab_id = retained_grab.id;
    try wayring.client.sendRequest(
        protocol.zwp_input_method_v2,
        &method_client.objects,
        &method_actor.transmit,
        im,
        .{ .destroy = .{} },
    );
    method_handler.method = null;
    try submitClient(&method_reactor, &method_driver, &method_handler);
    for (0..512) |_| {
        _ = try drainClient(&method_reactor, &method_driver, &method_handler);
        _ = try loop.turn(coordinator);
        if (method_client.objects.namespace.lookupHandle(im.id) == null and
            method_handler.destroyed_popup_deleted and
            method_handler.destroyed_grab_deleted) break;
        _ = linux.sched_yield();
    }
    try std.testing.expect(method_client.objects.namespace.lookupHandle(im.id) == null);
    try std.testing.expect(method_handler.destroyed_popup_deleted);
    try std.testing.expect(method_handler.destroyed_grab_deleted);
    _ = try app.prepareClose();
    _ = try method_client.prepareClose();
    try submitClient(&app_reactor, &app_driver, &app_handler);
    try submitClient(&method_reactor, &method_driver, &method_handler);
    try coordinator.requestStop();
    for (0..512) |_| {
        const a = try drainClient(&app_reactor, &app_driver, &app_handler);
        const m = try drainClient(&method_reactor, &method_driver, &method_handler);
        const p = try loop.turn(coordinator);
        if (a.quiescent and m.quiescent and p.wayring.shutdown_complete and coordinator.backendDrainComplete()) break;
        _ = linux.sched_yield();
    }
    try app.deinit(allocator);
    try method_client.deinit(allocator);
    app_reactor.deinit(allocator);
    method_reactor.deinit(allocator);
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
        .device_configuration = deviceConfiguration,
        .apply_configuration = applyConfiguration,
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
    fn deviceConfiguration(_: *anyopaque, _: ouro.input_platform.DeviceRef) !ouro.input_platform.DeviceConfiguration {
        return .{ .send_events = .{ .default = .{}, .current = .{} } };
    }
    fn applyConfiguration(_: *anyopaque, _: ouro.input_platform.DeviceRef, _: ouro.input_platform.Configuration) !ouro.input_platform.ApplyResult {
        return .{};
    }
};

const TabletHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    seat: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    tablet_seat: ?wayring.objects.Handle = null,
    tablet: ?wayring.objects.Handle = null,
    tool: ?wayring.objects.Handle = null,
    tablet_added: usize = 0,
    tool_added: usize = 0,
    tablet_done: usize = 0,
    tool_done: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *TabletHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *TabletHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| {
                    if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
                        self.seat = try ClientCore.bind(
                            self.objects,
                            self.queue,
                            self.registry,
                            value.name,
                            &protocol.wl_seat.info,
                            @min(value.version, 9),
                            null,
                        );
                    if (std.mem.eql(u8, value.interface, protocol.zwp_tablet_manager_v2.info.name))
                        self.manager = try ClientCore.bind(
                            self.objects,
                            self.queue,
                            self.registry,
                            value.name,
                            &protocol.zwp_tablet_manager_v2.info,
                            @min(value.version, 2),
                            null,
                        );
                    try self.maybeCreateSeat();
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            _ = try protocol.wl_seat.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.zwp_tablet_seat_v2.info) {
            switch (try protocol.zwp_tablet_seat_v2.decodeEvent(message, fds)) {
                .tablet_added => |value| {
                    self.tablet = (try protocol.zwp_tablet_seat_v2.admit_event_tablet_added(
                        self.objects,
                        self.tablet_seat.?,
                        value,
                        .{},
                    )).id;
                    self.tablet_added += 1;
                },
                .tool_added => |value| {
                    self.tool = (try protocol.zwp_tablet_seat_v2.admit_event_tool_added(
                        self.objects,
                        self.tablet_seat.?,
                        value,
                        .{},
                    )).id;
                    self.tool_added += 1;
                },
                .pad_added => |value| {
                    _ = try protocol.zwp_tablet_seat_v2.admit_event_pad_added(
                        self.objects,
                        self.tablet_seat.?,
                        value,
                        .{},
                    );
                },
            }
        } else if (target.object.interface == &protocol.zwp_tablet_v2.info) {
            switch (try protocol.zwp_tablet_v2.decodeEvent(message, fds)) {
                .done => self.tablet_done += 1,
                else => {},
            }
        } else if (target.object.interface == &protocol.zwp_tablet_tool_v2.info) {
            switch (try protocol.zwp_tablet_tool_v2.decodeEvent(message, fds)) {
                .done => self.tool_done += 1,
                else => {},
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn maybeCreateSeat(self: *TabletHandler) !void {
        if (self.tablet_seat != null or self.seat == null or self.manager == null) return;
        self.tablet_seat = (try protocol.zwp_tablet_manager_v2.construct_get_tablet_seat(
            self.objects,
            self.queue,
            self.manager.?,
            .{ .seat = self.seat.?.id },
        )).tablet_seat;
    }
};

const InputMethodHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    virtual_manager: ?wayring.objects.Handle = null,
    virtual_keyboard: ?wayring.objects.Handle = null,
    virtual_pointer_manager: ?wayring.objects.Handle = null,
    virtual_pointer: ?wayring.objects.Handle = null,
    method: ?wayring.objects.Handle = null,
    rejected: ?wayring.objects.Handle = null,
    keyboard_grab: ?wayring.objects.Handle = null,
    popup_surface: ?wayring.objects.Handle = null,
    popup: ?wayring.objects.Handle = null,
    popup_rectangles: usize = 0,
    popup_rectangle: protocol_input_method.PopupRectangle = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    unavailable: usize = 0,
    activate: usize = 0,
    deactivate: usize = 0,
    surrounding: usize = 0,
    cause: usize = 0,
    content: usize = 0,
    done: usize = 0,
    order: usize = 0,
    state_valid: bool = true,
    event_failures: usize = 0,
    grab_keymap: usize = 0,
    grab_repeat: usize = 0,
    grab_modifiers: usize = 0,
    grab_keys: usize = 0,
    grab_initial_valid: bool = true,
    grab_keys_valid: bool = true,
    destroyed_popup_id: u32 = 0,
    destroyed_grab_id: u32 = 0,
    destroyed_popup_deleted: bool = false,
    destroyed_grab_deleted: bool = false,

    pub fn eventError(self: *@This(), _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }
    pub fn event(self: *@This(), target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |v| {
                    if (std.mem.eql(u8, v.interface, protocol.wl_compositor.info.name)) self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, v.name, &protocol.wl_compositor.info, @min(v.version, 7), null);
                    if (std.mem.eql(u8, v.interface, protocol.wl_seat.info.name)) self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, v.name, &protocol.wl_seat.info, @min(v.version, 9), null);
                    if (std.mem.eql(u8, v.interface, protocol.zwp_input_method_manager_v2.info.name)) self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, v.name, &protocol.zwp_input_method_manager_v2.info, 1, null);
                    if (std.mem.eql(u8, v.interface, protocol.zwp_virtual_keyboard_manager_v1.info.name)) self.virtual_manager = try ClientCore.bind(self.objects, self.queue, self.registry, v.name, &protocol.zwp_virtual_keyboard_manager_v1.info, 1, null);
                    if (std.mem.eql(u8, v.interface, protocol.zwlr_virtual_pointer_manager_v1.info.name)) self.virtual_pointer_manager = try ClientCore.bind(self.objects, self.queue, self.registry, v.name, &protocol.zwlr_virtual_pointer_manager_v1.info, 2, null);
                    if (self.virtual_keyboard == null and self.seat != null and self.virtual_manager != null)
                        self.virtual_keyboard = (try protocol.zwp_virtual_keyboard_manager_v1.construct_create_virtual_keyboard(
                            self.objects,
                            self.queue,
                            self.virtual_manager.?,
                            .{ .seat = self.seat.?.id },
                        )).id;
                    if (self.virtual_pointer == null and self.virtual_pointer_manager != null)
                        self.virtual_pointer = (try protocol.zwlr_virtual_pointer_manager_v1.construct_create_virtual_pointer(
                            self.objects,
                            self.queue,
                            self.virtual_pointer_manager.?,
                            .{ .seat = null },
                        )).id;
                    if (self.method == null and self.seat != null and self.manager != null) {
                        self.method = (try protocol.zwp_input_method_manager_v2.construct_get_input_method(self.objects, self.queue, self.manager.?, .{ .seat = self.seat.?.id })).input_method;
                        self.rejected = (try protocol.zwp_input_method_manager_v2.construct_get_input_method(self.objects, self.queue, self.manager.?, .{ .seat = self.seat.?.id })).input_method;
                        self.keyboard_grab = (try protocol.zwp_input_method_v2.construct_grab_keyboard(self.objects, self.queue, self.method.?, .{})).keyboard;
                    }
                    if (self.popup == null and self.compositor != null and self.method != null) {
                        self.popup_surface = (try protocol.wl_compositor.construct_create_surface(
                            self.objects,
                            self.queue,
                            self.compositor.?,
                            .{},
                        )).id;
                        self.popup = (try protocol.zwp_input_method_v2.construct_get_input_popup_surface(
                            self.objects,
                            self.queue,
                            self.method.?,
                            .{ .surface = self.popup_surface.?.id },
                        )).id;
                    }
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            _ = try protocol.wl_seat.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.zwp_input_method_v2.info) {
            const rejected = message.header.object_id == self.rejected.?.id;
            switch (try protocol.zwp_input_method_v2.decodeEvent(message, fds)) {
                .unavailable => {
                    try std.testing.expect(rejected);
                    self.unavailable += 1;
                },
                .activate => {
                    try std.testing.expect(!rejected);
                    self.activate += 1;
                    self.order += 1;
                    try std.testing.expectEqual(@as(usize, 1), self.order);
                },
                .deactivate => {
                    try std.testing.expect(!rejected);
                    self.deactivate += 1;
                    self.order += 1;
                    self.state_valid = self.state_valid and self.order == 6;
                },
                .surrounding_text => |v| {
                    self.surrounding += 1;
                    self.order += 1;
                    self.state_valid = self.state_valid and self.order == 2 and std.mem.eql(u8, v.text, "hello world") and v.cursor == 5 and v.anchor == 3;
                },
                .text_change_cause => |v| {
                    self.cause += 1;
                    self.order += 1;
                    self.state_valid = self.state_valid and self.order == 3 and v.cause.value == protocol.zwp_text_input_v3.change_cause.other.value;
                },
                .content_type => |v| {
                    self.content += 1;
                    self.order += 1;
                    self.state_valid = self.state_valid and self.order == 4 and v.hint.value == protocol.zwp_text_input_v3.content_hint.completion.value and v.purpose.value == protocol.zwp_text_input_v3.content_purpose.email.value;
                },
                .done => {
                    self.done += 1;
                    self.order += 1;
                    self.state_valid = self.state_valid and
                        (self.order == 5 or (self.done == 2 and self.order == 7));
                },
            }
        } else if (target.object.interface == &protocol.zwp_input_method_keyboard_grab_v2.info) {
            switch (try protocol.zwp_input_method_keyboard_grab_v2.decodeEvent(message, fds)) {
                .keymap => |v| {
                    defer _ = linux.close(v.fd);
                    self.grab_keymap += 1;
                    self.grab_initial_valid = self.grab_initial_valid and
                        v.format.value == protocol.wl_keyboard.keymap_format.xkb_v1.value and v.size > 0;
                },
                .repeat_info => |v| {
                    self.grab_repeat += 1;
                    self.grab_initial_valid = self.grab_initial_valid and v.rate == 25 and v.delay == 600;
                },
                .modifiers => |v| {
                    self.grab_modifiers += 1;
                    if (self.grab_modifiers == 1)
                        self.grab_initial_valid = self.grab_initial_valid and v.mods_depressed == 0
                    else if (self.grab_modifiers == 2)
                        self.grab_keys_valid = self.grab_keys_valid and v.mods_depressed != 0
                    else if (self.grab_modifiers == 3)
                        self.grab_keys_valid = self.grab_keys_valid and v.mods_depressed == 0;
                },
                .key => |v| {
                    const expected_keys = [_]u32{ 42, 30, 30, 42 };
                    const expected_states = [_]u32{ 1, 1, 0, 0 };
                    if (self.grab_keys >= expected_keys.len or
                        v.key != expected_keys[self.grab_keys] or
                        v.state.value != expected_states[self.grab_keys]) self.grab_keys_valid = false;
                    self.grab_keys += 1;
                },
            }
        } else if (target.object.interface == &protocol.zwp_input_popup_surface_v2.info) {
            switch (try protocol.zwp_input_popup_surface_v2.decodeEvent(message, fds)) {
                .text_input_rectangle => |value| {
                    self.popup_rectangles += 1;
                    self.popup_rectangle = .{
                        .x = value.x,
                        .y = value.y,
                        .width = value.width,
                        .height = value.height,
                    };
                },
            }
        } else if (target.object.interface == &ClientCore.Display.info) switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
            .delete_id => |value| {
                if (value.id == self.destroyed_popup_id) self.destroyed_popup_deleted = true;
                if (value.id == self.destroyed_grab_id) self.destroyed_grab_deleted = true;
            },
            .@"error" => return error.ServerProtocolError,
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
};

const MultiHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    subcompositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    pointer: ?wayring.objects.Handle = null,
    activation: ?wayring.objects.Handle = null,
    activation_token: ?wayring.objects.Handle = null,
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
    cursor_mode: bool = false,
    activation_mode: bool = false,
    metadata_commit_after_attach: bool = false,
    activation_requested: bool = false,
    activation_done: usize = 0,

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
        } else if (target.object.interface == &protocol.wl_seat.info) {
            switch (try protocol.wl_seat.decodeEvent(message, fds)) {
                .capabilities => |value| {
                    if (self.pointer == null and value.capabilities.contains(
                        protocol.wl_seat.capability.pointer,
                    )) {
                        self.pointer = (try protocol.wl_seat.construct_get_pointer(
                            self.objects,
                            self.queue,
                            self.seat.?,
                            .{},
                        )).id;
                    }
                },
                .name => {},
            }
        } else if (target.object.interface == &protocol.wl_pointer.info) {
            switch (try protocol.wl_pointer.decodeEvent(message, fds)) {
                .button => |value| if (!self.activation_requested and
                    value.state.value == protocol.wl_pointer.button_state.pressed.value)
                    try self.requestActivation(value.serial),
                else => {},
            }
        } else if (target.object.interface == &protocol.xdg_activation_token_v1.info) {
            const value = try protocol.xdg_activation_token_v1.decodeEvent(message, fds);
            try protocol.xdg_activation_v1.encodeRequest(self.queue, self.activation.?.id, .{
                .activate = .{ .token = value.done.token, .surface = self.surfaces[1].?.id },
            });
            try wayring.client.sendRequest(
                protocol.xdg_activation_token_v1,
                self.objects,
                self.queue,
                self.activation_token.?,
                .{ .destroy = .{} },
            );
            self.activation_token = null;
            self.activation_done += 1;
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
        if (self.activation_mode and std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
            self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_seat.info, @min(value.version, 9), null);
        if (self.activation_mode and std.mem.eql(u8, value.interface, protocol.xdg_activation_v1.info.name))
            self.activation = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_activation_v1.info, 1, null);
    }

    fn maybeCreateShells(self: *MultiHandler) !void {
        if (self.shell_created or self.compositor == null or self.shm == null)
            return;
        if (!self.cursor_mode and self.wm_base == null) return;
        if ((self.subsurface_mode or self.cursor_mode) and self.subcompositor == null) return;
        for (0..self.surface_count) |index| {
            self.surfaces[index] = (try protocol.wl_compositor.construct_create_surface(
                self.objects,
                self.queue,
                self.compositor.?,
                .{},
            )).id;
            if (self.cursor_mode or (self.subsurface_mode and index != 0)) continue;
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
        if (self.subsurface_mode or self.cursor_mode) {
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
        if (self.metadata_commit_after_attach) try protocol.wl_surface.encodeRequest(
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

    fn requestActivation(self: *MultiHandler, serial: u32) !void {
        if (self.activation == null or self.seat == null or self.surfaces[0] == null or
            self.surfaces[1] == null) return error.ActivationNotReady;
        self.activation_token = (try protocol.xdg_activation_v1.construct_get_activation_token(
            self.objects,
            self.queue,
            self.activation.?,
            .{},
        )).id;
        try protocol.xdg_activation_token_v1.encodeRequest(self.queue, self.activation_token.?.id, .{
            .set_serial = .{ .serial = serial, .seat = self.seat.?.id },
        });
        try protocol.xdg_activation_token_v1.encodeRequest(self.queue, self.activation_token.?.id, .{
            .set_surface = .{ .surface = self.surfaces[0].?.id },
        });
        try protocol.xdg_activation_token_v1.encodeRequest(self.queue, self.activation_token.?.id, .{
            .set_app_id = .{ .app_id = "ouro.activation.test" },
        });
        try protocol.xdg_activation_token_v1.encodeRequest(
            self.queue,
            self.activation_token.?.id,
            .{ .commit = .{} },
        );
        self.activation_requested = true;
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

const ScreencopyHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    shm: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    buffer: ?wayring.objects.Handle = null,
    read_fd: linux.fd_t = -1,
    output_ready: bool = false,
    capture_goal: usize = 1,
    ready_events: usize = 0,
    capture_requested: bool = false,
    copy_requested: bool = false,
    ready: bool = false,
    failed: bool = false,
    buffer_events: usize = 0,
    buffer_done_events: usize = 0,
    flags_events: usize = 0,
    damage_events: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *ScreencopyHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *ScreencopyHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| try self.bindGlobal(value),
                .global_remove => {},
            }
            try self.maybeCapture();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .done => {
                    self.output_ready = true;
                    try self.maybeCapture();
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwlr_screencopy_frame_v1.info) {
            switch (try protocol.zwlr_screencopy_frame_v1.decodeEvent(message, fds)) {
                .buffer => |value| {
                    try std.testing.expectEqual(protocol.wl_shm.format.xrgb8888.value, value.format.value);
                    try std.testing.expectEqual(@as(u32, 1), value.width);
                    try std.testing.expectEqual(@as(u32, 1), value.height);
                    try std.testing.expectEqual(@as(u32, 4), value.stride);
                    self.buffer_events += 1;
                },
                .buffer_done => {
                    self.buffer_done_events += 1;
                    try self.requestCopy();
                },
                .flags => |value| {
                    try std.testing.expectEqual(@as(u32, 0), value.flags.value);
                    self.flags_events += 1;
                },
                .damage => |value| {
                    try std.testing.expectEqual(@as(u32, 0), value.x);
                    try std.testing.expectEqual(@as(u32, 0), value.y);
                    try std.testing.expectEqual(@as(u32, 1), value.width);
                    try std.testing.expectEqual(@as(u32, 1), value.height);
                    self.damage_events += 1;
                },
                .ready => {
                    self.ready_events += 1;
                    if (self.ready_events == self.capture_goal) {
                        self.ready = true;
                    } else {
                        self.frame = null;
                        self.buffer = null;
                        self.capture_requested = false;
                        self.copy_requested = false;
                        if (self.read_fd >= 0) _ = linux.close(self.read_fd);
                        self.read_fd = -1;
                    }
                },
                .failed => self.failed = true,
                .linux_dmabuf => return error.UnexpectedDmabufCapture,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn bindGlobal(self: *ScreencopyHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name))
            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
        if (std.mem.eql(u8, value.interface, protocol.zwlr_screencopy_manager_v1.info.name))
            self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwlr_screencopy_manager_v1.info, @min(value.version, 3), null);
    }

    fn maybeCapture(self: *ScreencopyHandler) !void {
        if (self.capture_requested or !self.output_ready or self.manager == null or
            self.output == null or self.shm == null) return;
        self.frame = (try protocol.zwlr_screencopy_manager_v1.construct_capture_output_region(
            self.objects,
            self.queue,
            self.manager.?,
            .{
                .overlay_cursor = 0,
                .output = self.output.?.id,
                .x = 1,
                .y = 0,
                .width = 1,
                .height = 1,
            },
        )).frame;
        self.capture_requested = true;
    }

    fn requestCopy(self: *ScreencopyHandler) !void {
        if (self.copy_requested) return;
        const descriptor = try ordinaryMemfd(4, 0, &.{ 0x55, 0x55, 0x55, 0x55 });
        const retained = linux.fcntl(descriptor, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(retained) != .SUCCESS) return error.DuplicateFailed;
        self.read_fd = @intCast(retained);
        errdefer {
            _ = linux.close(self.read_fd);
            self.read_fd = -1;
        }
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4 },
        );
        self.buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 0,
                .width = 1,
                .height = 1,
                .stride = 4,
                .format = .xrgb8888,
            },
        )).id;
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        try protocol.zwlr_screencopy_frame_v1.encodeRequest(
            self.queue,
            self.frame.?.id,
            .{ .copy_with_damage = .{ .buffer = self.buffer.?.id } },
        );
        self.copy_requested = true;
    }
};

const ImageCopyHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    shm: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    source_manager: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    source: ?wayring.objects.Handle = null,
    session: ?wayring.objects.Handle = null,
    frame: ?wayring.objects.Handle = null,
    buffer: ?wayring.objects.Handle = null,
    read_fd: linux.fd_t = -1,
    output_ready: bool = false,
    frame_requested: bool = false,
    capture_requested: bool = false,
    ready: bool = false,
    failed: bool = false,
    stopped: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    buffer_size_events: usize = 0,
    shm_format_events: usize = 0,
    constraints_done_events: usize = 0,
    transform_events: usize = 0,
    damage_events: usize = 0,
    presentation_events: usize = 0,
    event_failures: usize = 0,

    pub fn eventError(
        self: *ImageCopyHandler,
        _: wayring.io_uring.Peer,
        _: ClientCore.EventFailure,
    ) void {
        self.event_failures += 1;
    }

    pub fn event(
        self: *ImageCopyHandler,
        target: wayring.objects.Dispatch,
        message: wayring.wire.Message,
        fds: *wayring.ancillary.FdQueue,
    ) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| try self.bindGlobal(value),
                .global_remove => {},
            }
            try self.maybeCreateSession();
        } else if (target.object.interface == &protocol.wl_shm.info) {
            _ = try protocol.wl_shm.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_output.info) {
            switch (try protocol.wl_output.decodeEvent(message, fds)) {
                .done => {
                    self.output_ready = true;
                    try self.maybeCreateSession();
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.ext_image_copy_capture_session_v1.info) {
            switch (try protocol.ext_image_copy_capture_session_v1.decodeEvent(message, fds)) {
                .buffer_size => |value| {
                    try std.testing.expectEqual(@as(u32, 3), value.width);
                    try std.testing.expectEqual(@as(u32, 2), value.height);
                    self.width = value.width;
                    self.height = value.height;
                    self.buffer_size_events += 1;
                },
                .shm_format => |value| {
                    try std.testing.expect(
                        value.format.value == protocol.wl_shm.format.argb8888.value or
                            value.format.value == protocol.wl_shm.format.xrgb8888.value,
                    );
                    self.shm_format_events += 1;
                },
                .done => {
                    self.constraints_done_events += 1;
                    try self.requestFrame();
                },
                .stopped => self.stopped = true,
                .dmabuf_device, .dmabuf_format => return error.UnexpectedDmabufCapture,
            }
        } else if (target.object.interface == &protocol.ext_image_copy_capture_frame_v1.info) {
            switch (try protocol.ext_image_copy_capture_frame_v1.decodeEvent(message, fds)) {
                .transform => |value| {
                    try std.testing.expectEqual(protocol.wl_output.transform.@"90", value.transform);
                    self.transform_events += 1;
                },
                .damage => |value| {
                    try std.testing.expectEqual(@as(i32, 0), value.x);
                    try std.testing.expectEqual(@as(i32, 0), value.y);
                    try std.testing.expectEqual(@as(i32, 3), value.width);
                    try std.testing.expectEqual(@as(i32, 2), value.height);
                    self.damage_events += 1;
                },
                .presentation_time => |value| {
                    try std.testing.expect(value.tv_nsec < std.time.ns_per_s);
                    self.presentation_events += 1;
                },
                .ready => self.ready = true,
                .failed => self.failed = true,
            }
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }

    fn bindGlobal(self: *ImageCopyHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name))
            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
        if (std.mem.eql(u8, value.interface, protocol.ext_output_image_capture_source_manager_v1.info.name))
            self.source_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_output_image_capture_source_manager_v1.info, 1, null);
        if (std.mem.eql(u8, value.interface, protocol.ext_image_copy_capture_manager_v1.info.name))
            self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_image_copy_capture_manager_v1.info, 1, null);
    }

    fn maybeCreateSession(self: *ImageCopyHandler) !void {
        if (!self.output_ready or self.shm == null or self.output == null or
            self.source_manager == null or self.manager == null) return;
        if (self.source == null)
            self.source = (try protocol.ext_output_image_capture_source_manager_v1.construct_create_source(
                self.objects,
                self.queue,
                self.source_manager.?,
                .{ .output = self.output.?.id },
            )).source;
        if (self.session == null)
            self.session = (try protocol.ext_image_copy_capture_manager_v1.construct_create_session(
                self.objects,
                self.queue,
                self.manager.?,
                .{
                    .source = self.source.?.id,
                    .options = protocol.ext_image_copy_capture_manager_v1.options.fromInt(0),
                },
            )).session;
    }

    fn requestFrame(self: *ImageCopyHandler) !void {
        if (self.frame_requested) return;
        try std.testing.expectEqual(@as(u32, 3), self.width);
        try std.testing.expectEqual(@as(u32, 2), self.height);
        const descriptor = try ordinaryMemfd(24, 0, &([_]u8{0x55} ** 24));
        const retained = linux.fcntl(descriptor, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(retained) != .SUCCESS) return error.DuplicateFailed;
        self.read_fd = @intCast(retained);
        errdefer {
            _ = linux.close(self.read_fd);
            self.read_fd = -1;
        }
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 24 },
        );
        self.buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 0,
                .width = 3,
                .height = 2,
                .stride = 12,
                .format = .xrgb8888,
            },
        )).id;
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        self.frame = (try protocol.ext_image_copy_capture_session_v1.construct_create_frame(
            self.objects,
            self.queue,
            self.session.?,
            .{},
        )).frame;
        try protocol.ext_image_copy_capture_frame_v1.encodeRequest(
            self.queue,
            self.frame.?.id,
            .{ .attach_buffer = .{ .buffer = self.buffer.?.id } },
        );
        try protocol.ext_image_copy_capture_frame_v1.encodeRequest(
            self.queue,
            self.frame.?.id,
            .{ .capture = .{} },
        );
        self.frame_requested = true;
        self.capture_requested = true;
    }
};

const LayerPopupHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    shm: ?wayring.objects.Handle = null,
    wm_base: ?wayring.objects.Handle = null,
    output: ?wayring.objects.Handle = null,
    output_count: usize = 0,
    minimum_outputs: usize = 0,
    layer_shell: ?wayring.objects.Handle = null,
    layer_surface: ?wayring.objects.Handle = null,
    layer_wl_surface: ?wayring.objects.Handle = null,
    root_xdg_surface: ?wayring.objects.Handle = null,
    root_toplevel: ?wayring.objects.Handle = null,
    popup_surface: ?wayring.objects.Handle = null,
    popup_xdg_surface: ?wayring.objects.Handle = null,
    popup: ?wayring.objects.Handle = null,
    buffers: [2]?wayring.objects.Handle = .{ null, null },
    created: bool = false,
    toplevel_root: bool = false,
    layer_mapped: bool = false,
    layer_configured: bool = false,
    require_layer_enter_before_map: bool = false,
    popup_mapped: bool = false,
    reactive: bool = false,
    hold_popup_configures: bool = false,
    popup_configures: [8]u32 = undefined,
    popup_configure_count: usize = 0,
    layer_closed: usize = 0,
    layer_enters: usize = 0,
    layer_leaves: usize = 0,
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
        } else if (target.object.interface == &protocol.wl_output.info) {
            _ = try protocol.wl_output.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.wl_surface.info) {
            switch (try protocol.wl_surface.decodeEvent(message, fds)) {
                .enter => |value| if (!self.toplevel_root and self.layer_wl_surface != null and
                    message.header.object_id == self.layer_wl_surface.?.id)
                {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.layer_enters += 1;
                    try self.maybeMapLayer();
                },
                .leave => |value| if (!self.toplevel_root and self.layer_wl_surface != null and
                    message.header.object_id == self.layer_wl_surface.?.id)
                {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.layer_leaves += 1;
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwlr_layer_surface_v1.info) {
            switch (try protocol.zwlr_layer_surface_v1.decodeEvent(message, fds)) {
                .configure => |value| {
                    try protocol.zwlr_layer_surface_v1.encodeRequest(
                        self.queue,
                        self.layer_surface.?.id,
                        .{ .ack_configure = .{ .serial = value.serial } },
                    );
                    self.layer_configured = true;
                    try self.maybeMapLayer();
                },
                .closed => self.layer_closed += 1,
            }
        } else if (target.object.interface == &protocol.xdg_popup.info) {
            _ = try protocol.xdg_popup.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_toplevel.info) {
            _ = try protocol.xdg_toplevel.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.xdg_surface.info) {
            switch (try protocol.xdg_surface.decodeEvent(message, fds)) {
                .configure => |value| {
                    if (self.root_xdg_surface != null and
                        message.header.object_id == self.root_xdg_surface.?.id)
                    {
                        try protocol.xdg_surface.encodeRequest(
                            self.queue,
                            self.root_xdg_surface.?.id,
                            .{ .ack_configure = .{ .serial = value.serial } },
                        );
                        if (!self.layer_mapped) {
                            try self.mapSurface(0, self.layer_wl_surface.?);
                            try self.createPopup();
                            self.layer_mapped = true;
                        } else {
                            try protocol.wl_surface.encodeRequest(
                                self.queue,
                                self.layer_wl_surface.?.id,
                                .{ .commit = .{} },
                            );
                        }
                        return .continue_dispatch;
                    }
                    self.popup_configures[self.popup_configure_count] = value.serial;
                    self.popup_configure_count += 1;
                    if (!self.popup_mapped or !self.hold_popup_configures) {
                        try self.ackPopupConfigure(value.serial);
                    }
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

    fn maybeMapLayer(self: *LayerPopupHandler) !void {
        if (self.layer_mapped or !self.layer_configured or
            (self.require_layer_enter_before_map and self.layer_enters == 0)) return;
        try self.mapSurface(0, self.layer_wl_surface.?);
        try self.createPopup();
        self.layer_mapped = true;
    }

    fn bindGlobal(self: *LayerPopupHandler, value: anytype) !void {
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name)) {
            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
            self.output_count += 1;
        }
        if (std.mem.eql(u8, value.interface, protocol.zwlr_layer_shell_v1.info.name))
            self.layer_shell = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwlr_layer_shell_v1.info, @min(value.version, 5), null);
    }

    fn maybeCreate(self: *LayerPopupHandler) !void {
        if (self.created or self.compositor == null or self.shm == null or
            self.wm_base == null or (!self.toplevel_root and self.layer_shell == null) or
            self.output_count < self.minimum_outputs) return;
        self.layer_wl_surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        if (self.toplevel_root) {
            self.root_xdg_surface = (try protocol.xdg_wm_base.construct_get_xdg_surface(
                self.objects,
                self.queue,
                self.wm_base.?,
                .{ .surface = self.layer_wl_surface.?.id },
            )).id;
            self.root_toplevel = (try protocol.xdg_surface.construct_get_toplevel(
                self.objects,
                self.queue,
                self.root_xdg_surface.?,
                .{},
            )).id;
            try protocol.wl_surface.encodeRequest(
                self.queue,
                self.layer_wl_surface.?.id,
                .{ .commit = .{} },
            );
            self.created = true;
            return;
        }
        self.layer_surface = (try protocol.zwlr_layer_shell_v1.construct_get_layer_surface(
            self.objects,
            self.queue,
            self.layer_shell.?,
            .{
                .surface = self.layer_wl_surface.?.id,
                .output = if (self.output) |output| output.id else null,
                .layer = .top,
                .namespace = "ouro-test",
            },
        )).id;
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .set_size = .{ .width = 3, .height = 2 },
        });
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .set_anchor = .{ .anchor = .{ .value = 13 } },
        });
        try protocol.zwlr_layer_surface_v1.encodeRequest(self.queue, self.layer_surface.?.id, .{
            .set_exclusive_zone = .{ .zone = 1 },
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
        try protocol.xdg_positioner.encodeRequest(self.queue, positioner.id.id, .{
            .set_constraint_adjustment = .{ .constraint_adjustment = .{ .value = 1 } },
        });
        if (self.reactive) try protocol.xdg_positioner.encodeRequest(
            self.queue,
            positioner.id.id,
            .{ .set_reactive = .{} },
        );
        self.popup = (try protocol.xdg_surface.construct_get_popup(
            self.objects,
            self.queue,
            self.popup_xdg_surface.?,
            .{
                .parent = if (self.root_xdg_surface) |root| root.id else null,
                .positioner = positioner.id.id,
            },
        )).id;
        if (!self.toplevel_root) try protocol.zwlr_layer_surface_v1.encodeRequest(
            self.queue,
            self.layer_surface.?.id,
            .{ .get_popup = .{ .popup = self.popup.?.id } },
        );
        try protocol.wl_surface.encodeRequest(
            self.queue,
            self.popup_surface.?.id,
            .{ .commit = .{} },
        );
    }

    fn ackPopupConfigure(self: *LayerPopupHandler, serial: u32) !void {
        try protocol.xdg_surface.encodeRequest(
            self.queue,
            self.popup_xdg_surface.?.id,
            .{ .ack_configure = .{ .serial = serial } },
        );
    }

    fn commitPopup(self: *LayerPopupHandler) !void {
        try protocol.wl_surface.encodeRequest(
            self.queue,
            self.popup_surface.?.id,
            .{ .commit = .{} },
        );
    }

    fn repositionPopup(self: *LayerPopupHandler) !void {
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
            .set_anchor_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        });
        try protocol.xdg_positioner.encodeRequest(self.queue, positioner.id.id, .{
            .set_constraint_adjustment = .{ .constraint_adjustment = .{ .value = 1 } },
        });
        try protocol.xdg_positioner.encodeRequest(self.queue, positioner.id.id, .{
            .set_reactive = .{},
        });
        try protocol.xdg_popup.encodeRequest(self.queue, self.popup.?.id, .{
            .reposition = .{ .positioner = positioner.id.id, .token = 1 },
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
                .width = if (index == 0 and !self.toplevel_root) 3 else if (index == 0) 2 else 1,
                .height = if (index == 0) 2 else 1,
                .stride = 16,
                .format = .argb8888,
            },
        )).id;
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .attach = .{ .buffer = self.buffers[index].?.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, surface.id, .{
            .damage_buffer = .{
                .x = 0,
                .y = 0,
                .width = if (index == 0 and self.toplevel_root) 2 else 3,
                .height = 2,
            },
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

const DataControlHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    seat: ?wayring.objects.Handle = null,
    ext_manager: ?wayring.objects.Handle = null,
    wlr_manager: ?wayring.objects.Handle = null,
    ext_device: ?wayring.objects.Handle = null,
    wlr_device: ?wayring.objects.Handle = null,
    source1: ?wayring.objects.Handle = null,
    source2: ?wayring.objects.Handle = null,
    wlr_source: ?wayring.objects.Handle = null,
    ext_selection: ?wayring.objects.Handle = null,
    wlr_selection: ?wayring.objects.Handle = null,
    initial_ext_regular: usize = 0,
    initial_ext_primary: usize = 0,
    initial_wlr_regular: usize = 0,
    initial_wlr_primary: usize = 0,
    ext_mimes: usize = 0,
    wlr_mimes: usize = 0,
    cancelled: usize = 0,
    send_fd: linux.fd_t = -1,
    send_mime_valid: bool = false,
    event_failures: usize = 0,

    pub fn eventError(self: *DataControlHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }

    pub fn event(self: *DataControlHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| {
                    if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
                        self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_seat.info, @min(value.version, 9), null);
                    if (std.mem.eql(u8, value.interface, protocol.ext_data_control_manager_v1.info.name))
                        self.ext_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_data_control_manager_v1.info, 1, null);
                    if (std.mem.eql(u8, value.interface, protocol.zwlr_data_control_manager_v1.info.name))
                        self.wlr_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwlr_data_control_manager_v1.info, @min(value.version, 2), null);
                    try self.createDevices();
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            _ = try protocol.wl_seat.decodeEvent(message, fds);
        } else if (target.object.interface == &protocol.ext_data_control_device_v1.info) {
            switch (try protocol.ext_data_control_device_v1.decodeEvent(message, fds)) {
                .data_offer => |value| {
                    _ = try protocol.ext_data_control_device_v1.admit_event_data_offer(self.objects, self.ext_device.?, value, .{});
                },
                .selection => |value| {
                    if (value.id) |id| self.ext_selection = self.objects.namespace.lookupHandle(id).? else self.initial_ext_regular += 1;
                },
                .primary_selection => |value| {
                    if (value.id == null) self.initial_ext_primary += 1;
                },
                .finished => {},
            }
        } else if (target.object.interface == &protocol.zwlr_data_control_device_v1.info) {
            switch (try protocol.zwlr_data_control_device_v1.decodeEvent(message, fds)) {
                .data_offer => |value| {
                    _ = try protocol.zwlr_data_control_device_v1.admit_event_data_offer(self.objects, self.wlr_device.?, value, .{});
                },
                .selection => |value| {
                    if (value.id) |id| self.wlr_selection = self.objects.namespace.lookupHandle(id).? else self.initial_wlr_regular += 1;
                },
                .primary_selection => |value| {
                    if (value.id == null) self.initial_wlr_primary += 1;
                },
                .finished => {},
            }
        } else if (target.object.interface == &protocol.ext_data_control_offer_v1.info) {
            const value = try protocol.ext_data_control_offer_v1.decodeEvent(message, fds);
            try std.testing.expect(std.mem.eql(u8, "text/plain;charset=utf-8", value.offer.mime_type) or
                std.mem.eql(u8, "text/plain", value.offer.mime_type) or
                std.mem.eql(u8, "text/html", value.offer.mime_type));
            self.ext_mimes += 1;
        } else if (target.object.interface == &protocol.zwlr_data_control_offer_v1.info) {
            const value = try protocol.zwlr_data_control_offer_v1.decodeEvent(message, fds);
            try std.testing.expect(std.mem.eql(u8, "text/plain;charset=utf-8", value.offer.mime_type) or
                std.mem.eql(u8, "text/plain", value.offer.mime_type) or
                std.mem.eql(u8, "text/html", value.offer.mime_type));
            self.wlr_mimes += 1;
        } else if (target.object.interface == &protocol.ext_data_control_source_v1.info) {
            switch (try protocol.ext_data_control_source_v1.decodeEvent(message, fds)) {
                .send => |value| {
                    self.send_mime_valid = std.mem.eql(u8, "text/plain;charset=utf-8", value.mime_type);
                    self.send_fd = value.fd;
                },
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

    fn createDevices(self: *DataControlHandler) !void {
        if (self.seat == null) return;
        if (self.ext_manager != null and self.ext_device == null)
            self.ext_device = (try protocol.ext_data_control_manager_v1.construct_get_data_device(self.objects, self.queue, self.ext_manager.?, .{ .seat = self.seat.?.id })).id;
        if (self.wlr_manager != null and self.wlr_device == null)
            self.wlr_device = (try protocol.zwlr_data_control_manager_v1.construct_get_data_device(self.objects, self.queue, self.wlr_manager.?, .{ .seat = self.seat.?.id })).id;
    }
};

const PrimarySelectionHandler = struct {
    objects: *wayring.objects.ClientObjects,
    queue: *wayring.tx.Queue,
    registry: wayring.objects.Handle,
    compositor: ?wayring.objects.Handle = null,
    seat: ?wayring.objects.Handle = null,
    manager: ?wayring.objects.Handle = null,
    surface: ?wayring.objects.Handle = null,
    keyboard: ?wayring.objects.Handle = null,
    device: ?wayring.objects.Handle = null,
    source: ?wayring.objects.Handle = null,
    offer: ?wayring.objects.Handle = null,
    serial: u32 = 0,
    offer_mimes: usize = 0,
    selections: usize = 0,
    null_selections: usize = 0,
    cancelled: usize = 0,
    send_count: usize = 0,
    read_fd: linux.fd_t = -1,
    event_failures: usize = 0,

    pub fn eventError(self: *PrimarySelectionHandler, _: wayring.io_uring.Peer, _: ClientCore.EventFailure) void {
        self.event_failures += 1;
    }
    pub fn event(self: *PrimarySelectionHandler, target: wayring.objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
        if (target.object.interface == &ClientCore.Registry.info) {
            switch (try ClientCore.decodeRegistryEvent(self.objects, self.registry, message, fds)) {
                .global => |value| {
                    if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
                        self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 6), null);
                    if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
                        self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_seat.info, @min(value.version, 9), null);
                    if (std.mem.eql(u8, value.interface, protocol.zwp_primary_selection_device_manager_v1.info.name))
                        self.manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwp_primary_selection_device_manager_v1.info, 1, null);
                    try self.createObjects();
                },
                .global_remove => {},
            }
        } else if (target.object.interface == &protocol.wl_seat.info) {
            switch (try protocol.wl_seat.decodeEvent(message, fds)) {
                .capabilities => |value| {
                    if (self.keyboard == null and value.capabilities.contains(protocol.wl_seat.capability.keyboard))
                        self.keyboard = (try protocol.wl_seat.construct_get_keyboard(self.objects, self.queue, self.seat.?, .{})).id;
                },
                .name => {},
            }
        } else if (target.object.interface == &protocol.wl_keyboard.info) {
            switch (try protocol.wl_keyboard.decodeEvent(message, fds)) {
                .keymap => |value| _ = linux.close(value.fd),
                .key => |value| if (value.state.value == protocol.wl_keyboard.key_state.pressed.value) {
                    self.serial = value.serial;
                    try protocol.zwp_primary_selection_device_v1.encodeRequest(self.queue, self.device.?.id, .{ .set_selection = .{ .source = self.source.?.id, .serial = value.serial } });
                },
                else => {},
            }
        } else if (target.object.interface == &protocol.zwp_primary_selection_device_v1.info) {
            switch (try protocol.zwp_primary_selection_device_v1.decodeEvent(message, fds)) {
                .data_offer => |value| self.offer = (try protocol.zwp_primary_selection_device_v1.admit_event_data_offer(self.objects, self.device.?, value, .{})).offer,
                .selection => |value| {
                    if (value.id) |id| {
                        try std.testing.expectEqual(self.offer.?.id, id);
                        self.selections += 1;
                        var pipe: [2]linux.fd_t = undefined;
                        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
                        self.read_fd = pipe[0];
                        try protocol.zwp_primary_selection_offer_v1.encodeRequest(self.queue, self.offer.?.id, .{ .receive = .{ .mime_type = "text/plain", .fd = pipe[1] } });
                    } else self.null_selections += 1;
                },
            }
        } else if (target.object.interface == &protocol.zwp_primary_selection_offer_v1.info) {
            const value = try protocol.zwp_primary_selection_offer_v1.decodeEvent(message, fds);
            try std.testing.expectEqualStrings("text/plain", value.offer.mime_type);
            self.offer_mimes += 1;
        } else if (target.object.interface == &protocol.zwp_primary_selection_source_v1.info) {
            switch (try protocol.zwp_primary_selection_source_v1.decodeEvent(message, fds)) {
                .send => |value| {
                    try std.testing.expectEqualStrings("text/plain", value.mime_type);
                    const bytes = if (self.send_count == 0) "first" else "second";
                    try std.testing.expectEqual(bytes.len, linux.write(value.fd, bytes.ptr, bytes.len));
                    _ = linux.close(value.fd);
                    self.send_count += 1;
                },
                .cancelled => self.cancelled += 1,
            }
        } else if (target.object.interface == &protocol.wl_surface.info) {
            _ = try protocol.wl_surface.decodeEvent(message, fds);
        } else if (target.object.interface == &ClientCore.Display.info) {
            switch (try ClientCore.decodeDisplayEvent(self.objects, message, fds)) {
                .delete_id => {},
                .@"error" => return error.ServerProtocolError,
            }
        } else return error.UnexpectedEvent;
        return .continue_dispatch;
    }
    fn createObjects(self: *PrimarySelectionHandler) !void {
        if (self.compositor != null and self.surface == null)
            self.surface = (try protocol.wl_compositor.construct_create_surface(self.objects, self.queue, self.compositor.?, .{})).id;
        if (self.seat != null and self.manager != null and self.device == null) {
            self.device = (try protocol.zwp_primary_selection_device_manager_v1.construct_get_device(self.objects, self.queue, self.manager.?, .{ .seat = self.seat.?.id })).id;
            try self.createSource();
        }
    }
    fn createSource(self: *PrimarySelectionHandler) !void {
        self.source = (try protocol.zwp_primary_selection_device_manager_v1.construct_create_source(self.objects, self.queue, self.manager.?, .{})).id;
        try protocol.zwp_primary_selection_source_v1.encodeRequest(self.queue, self.source.?.id, .{ .offer = .{ .mime_type = "text/plain" } });
    }
    fn replaceSelection(self: *PrimarySelectionHandler) !void {
        try self.createSource();
        try protocol.zwp_primary_selection_device_v1.encodeRequest(self.queue, self.device.?.id, .{ .set_selection = .{ .source = self.source.?.id, .serial = self.serial } });
    }
    fn expectTransfer(self: *PrimarySelectionHandler, expected: []const u8) !void {
        defer {
            _ = linux.close(self.read_fd);
            self.read_fd = -1;
        }
        var bytes: [16]u8 = undefined;
        const count = linux.read(self.read_fd, &bytes, bytes.len);
        try std.testing.expectEqual(expected.len, count);
        try std.testing.expectEqualStrings(expected, bytes[0..count]);
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
    toplevel_drag_manager: ?wayring.objects.Handle = null,
    toplevel_drag: ?wayring.objects.Handle = null,
    test_toplevel_drag: bool = false,
    toplevel_drag_attached: bool = false,
    toplevel_drag_destroyed: bool = false,
    drag_icon_surface: ?wayring.objects.Handle = null,
    drag_icon_buffer: ?wayring.objects.Handle = null,
    toplevel_tag_manager: ?wayring.objects.Handle = null,
    test_toplevel_tag: bool = false,
    toplevel_tag_set: bool = false,
    output: ?wayring.objects.Handle = null,
    idle_notifier: ?wayring.objects.Handle = null,
    idle_inhibit_manager: ?wayring.objects.Handle = null,
    pointer_warp_manager: ?wayring.objects.Handle = null,
    security_manager: ?wayring.objects.Handle = null,
    foreign_toplevel_list: ?wayring.objects.Handle = null,
    foreign_toplevel_handle: ?wayring.objects.Handle = null,
    test_foreign_toplevel: bool = false,
    foreign_toplevel_title: bool = false,
    foreign_toplevel_app_id: bool = false,
    foreign_toplevel_identifier: bool = false,
    foreign_toplevel_done: usize = 0,
    foreign_toplevel_finished: usize = 0,
    foreign_toplevel_closed: usize = 0,
    foreign_toplevel_global_seen: bool = false,
    workspace_global_seen: bool = false,
    wlr_foreign_toplevel_manager: ?wayring.objects.Handle = null,
    wlr_foreign_toplevel_handle: ?wayring.objects.Handle = null,
    test_wlr_foreign_toplevel: bool = false,
    wlr_foreign_toplevel_version: u32 = 0,
    wlr_foreign_toplevel_announcements: usize = 0,
    wlr_foreign_toplevel_initial_order: usize = 0,
    wlr_foreign_toplevel_done: usize = 0,
    wlr_foreign_toplevel_output_enter: usize = 0,
    wlr_foreign_toplevel_output_leave: usize = 0,
    wlr_foreign_toplevel_finished: usize = 0,
    wlr_foreign_toplevel_closed: usize = 0,
    image_output_manager: ?wayring.objects.Handle = null,
    image_toplevel_manager: ?wayring.objects.Handle = null,
    image_copy_manager: ?wayring.objects.Handle = null,
    image_output_source: ?wayring.objects.Handle = null,
    image_toplevel_source: ?wayring.objects.Handle = null,
    image_cursor_session: ?wayring.objects.Handle = null,
    image_capture_session: ?wayring.objects.Handle = null,
    image_capture_frame: ?wayring.objects.Handle = null,
    image_capture_buffer: ?wayring.objects.Handle = null,
    image_capture_read_fd: linux.fd_t = -1,
    image_capture_width: u32 = 0,
    image_capture_height: u32 = 0,
    image_capture_ready: bool = false,
    test_image_capture_sources: bool = false,
    image_output_global_seen: bool = false,
    image_toplevel_global_seen: bool = false,
    image_copy_global_seen: bool = false,
    image_cursor_enter: usize = 0,
    image_cursor_leave: usize = 0,
    image_cursor_position: usize = 0,
    image_cursor_hotspot: usize = 0,
    image_cursor_hotspot_x: i32 = 0,
    image_cursor_hotspot_y: i32 = 0,
    security_global_seen: bool = false,
    ext_data_control_global_seen: bool = false,
    wlr_data_control_global_seen: bool = false,
    input_method_global_seen: bool = false,
    virtual_keyboard_global_seen: bool = false,
    virtual_pointer_global_seen: bool = false,
    text_input_manager: ?wayring.objects.Handle = null,
    text_input: ?wayring.objects.Handle = null,
    test_text_input: bool = false,
    text_input_enter: usize = 0,
    text_input_done: usize = 0,
    text_input_preedit: usize = 0,
    text_input_commit: usize = 0,
    text_input_delete: usize = 0,
    text_input_commit_valid: bool = false,
    text_input_preedit_valid: bool = false,
    text_input_delete_valid: bool = false,
    test_security_context: bool = false,
    registry_only: bool = false,
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
    frame_before_map: bool = false,
    shell_created: bool = false,
    mapped: bool = false,
    input_requested: bool = false,
    input_ready: bool = false,
    configure_count: usize = 0,
    configure_serial: u32 = 0,
    acked_serial: u32 = 0,
    xdg_toplevel_close: usize = 0,
    pointer_enter: usize = 0,
    pointer_enter_serial: u32 = 0,
    pointer_warp_queued: bool = false,
    test_pointer_warp: bool = false,
    pointer_motion: usize = 0,
    pointer_button: usize = 0,
    virtual_pointer_button_times: u4 = 0,
    zero_time_pointer_buttons: usize = 0,
    pointer_axis_source: usize = 0,
    pointer_axis: usize = 0,
    pointer_axis_value120: usize = 0,
    pointer_frame: usize = 0,
    pointer_axis_fixed: i32 = 0,
    pointer_axis_value120_value: i32 = 0,
    pointer_axis_expected_time: u32 = 3,
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
            if (!self.registry_only) {
                try self.maybeCreateShell();
                try self.maybeCreateDataDevice();
                try self.maybeSetToplevelTag();
            }
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
        } else if (target.object.interface == &protocol.ext_foreign_toplevel_list_v1.info) {
            switch (try protocol.ext_foreign_toplevel_list_v1.decodeEvent(message, fds)) {
                .toplevel => |value| {
                    self.foreign_toplevel_handle = (try protocol.ext_foreign_toplevel_list_v1.admit_event_toplevel(
                        self.objects,
                        self.foreign_toplevel_list.?,
                        value,
                        .{},
                    )).toplevel;
                    try self.maybeCreateImageCaptureSources();
                },
                .finished => self.foreign_toplevel_finished += 1,
            }
        } else if (target.object.interface == &protocol.ext_foreign_toplevel_handle_v1.info) {
            switch (try protocol.ext_foreign_toplevel_handle_v1.decodeEvent(message, fds)) {
                .title => |value| self.foreign_toplevel_title = std.mem.eql(u8, value.title, "Foreign title"),
                .app_id => |value| self.foreign_toplevel_app_id = std.mem.eql(u8, value.app_id, "org.example.Foreign"),
                .identifier => |value| self.foreign_toplevel_identifier = std.mem.startsWith(u8, value.identifier, "ouro-"),
                .done => {
                    self.foreign_toplevel_done += 1;
                    if (self.foreign_toplevel_done == 1)
                        try protocol.ext_foreign_toplevel_list_v1.encodeRequest(
                            self.queue,
                            self.foreign_toplevel_list.?.id,
                            .{ .stop = .{} },
                        );
                },
                .closed => self.foreign_toplevel_closed += 1,
            }
        } else if (target.object.interface == &protocol.zwlr_foreign_toplevel_manager_v1.info) {
            switch (try protocol.zwlr_foreign_toplevel_manager_v1.decodeEvent(message, fds)) {
                .toplevel => |value| {
                    try std.testing.expectEqual(@as(usize, 0), self.wlr_foreign_toplevel_initial_order);
                    self.wlr_foreign_toplevel_initial_order = 1;
                    self.wlr_foreign_toplevel_announcements += 1;
                    self.wlr_foreign_toplevel_handle = (try protocol.zwlr_foreign_toplevel_manager_v1.admit_event_toplevel(
                        self.objects,
                        self.wlr_foreign_toplevel_manager.?,
                        value,
                        .{},
                    )).toplevel;
                },
                .finished => self.wlr_foreign_toplevel_finished += 1,
            }
        } else if (target.object.interface == &protocol.zwlr_foreign_toplevel_handle_v1.info) {
            switch (try protocol.zwlr_foreign_toplevel_handle_v1.decodeEvent(message, fds)) {
                .title => |value| {
                    try std.testing.expectEqual(@as(usize, 1), self.wlr_foreign_toplevel_initial_order);
                    try std.testing.expectEqualStrings("Foreign title", value.title);
                    self.wlr_foreign_toplevel_initial_order = 2;
                },
                .app_id => |value| {
                    try std.testing.expectEqual(@as(usize, 2), self.wlr_foreign_toplevel_initial_order);
                    try std.testing.expectEqualStrings("org.example.Foreign", value.app_id);
                    self.wlr_foreign_toplevel_initial_order = 3;
                },
                .output_enter => |value| {
                    try std.testing.expect(self.wlr_foreign_toplevel_initial_order >= 6);
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.wlr_foreign_toplevel_initial_order = 7;
                    self.wlr_foreign_toplevel_output_enter += 1;
                },
                .state => {
                    if (self.wlr_foreign_toplevel_done == 0) {
                        try std.testing.expectEqual(@as(usize, 3), self.wlr_foreign_toplevel_initial_order);
                        self.wlr_foreign_toplevel_initial_order = 4;
                    }
                },
                .parent => |value| {
                    try std.testing.expectEqual(@as(usize, 4), self.wlr_foreign_toplevel_initial_order);
                    try std.testing.expect(value.parent == null);
                    self.wlr_foreign_toplevel_initial_order = 5;
                },
                .done => {
                    self.wlr_foreign_toplevel_done += 1;
                    if (self.wlr_foreign_toplevel_initial_order == 5) {
                        try std.testing.expectEqual(@as(usize, 5), self.wlr_foreign_toplevel_initial_order);
                        self.wlr_foreign_toplevel_initial_order = 6;
                    }
                },
                .closed => self.wlr_foreign_toplevel_closed += 1,
                .output_leave => |value| {
                    try std.testing.expectEqual(self.output.?.id, value.output);
                    self.wlr_foreign_toplevel_output_leave += 1;
                },
            }
        } else if (target.object.interface == &protocol.ext_image_copy_capture_session_v1.info) {
            switch (try protocol.ext_image_copy_capture_session_v1.decodeEvent(message, fds)) {
                .buffer_size => |value| {
                    self.image_capture_width = value.width;
                    self.image_capture_height = value.height;
                },
                .shm_format => {},
                .done => try self.queueToplevelCaptureFrame(),
                .stopped => return error.UnexpectedCaptureStop,
                .dmabuf_device, .dmabuf_format => return error.UnexpectedDmabufCapture,
            }
        } else if (target.object.interface == &protocol.ext_image_copy_capture_frame_v1.info) {
            switch (try protocol.ext_image_copy_capture_frame_v1.decodeEvent(message, fds)) {
                .transform => |value| try std.testing.expectEqual(
                    protocol.wl_output.transform.normal,
                    value.transform,
                ),
                .damage => |value| {
                    try std.testing.expectEqual(@as(i32, 0), value.x);
                    try std.testing.expectEqual(@as(i32, 0), value.y);
                    try std.testing.expectEqual(@as(i32, 3), value.width);
                    try std.testing.expectEqual(@as(i32, 2), value.height);
                },
                .presentation_time => {},
                .ready => {
                    self.image_capture_ready = true;
                    try self.destroyToplevelCapture();
                },
                .failed => return error.UnexpectedCaptureFailure,
            }
        } else if (target.object.interface == &protocol.ext_image_copy_capture_cursor_session_v1.info) {
            switch (try protocol.ext_image_copy_capture_cursor_session_v1.decodeEvent(message, fds)) {
                .enter => self.image_cursor_enter += 1,
                .leave => self.image_cursor_leave += 1,
                .position => self.image_cursor_position += 1,
                .hotspot => |value| {
                    self.image_cursor_hotspot += 1;
                    self.image_cursor_hotspot_x = value.x;
                    self.image_cursor_hotspot_y = value.y;
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
                .close => self.xdg_toplevel_close += 1,
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
                    try self.maybeCreateImageCaptureSources();
                },
                .name => {},
            }
        } else if (target.object.interface == &protocol.wl_pointer.info) {
            switch (try protocol.wl_pointer.decodeEvent(message, fds)) {
                .enter => |value| {
                    self.pointer_enter += 1;
                    self.pointer_enter_serial = value.serial;
                },
                .motion => self.pointer_motion += 1,
                .button => |value| {
                    self.pointer_button += 1;
                    if (value.time >= 13 and value.time <= 16)
                        self.virtual_pointer_button_times |= @as(u4, 1) << @intCast(value.time - 13);
                    if (value.time == 0) {
                        self.zero_time_pointer_buttons += 1;
                    }
                    if (self.cursor_surface == null and !self.test_text_input)
                        try self.queueCursor(self.pointer_enter_serial);
                    if (value.state.value == protocol.wl_pointer.button_state.pressed.value and
                        self.drag_cancelled == 0 and !self.test_text_input)
                    {
                        if (self.test_toplevel_drag and self.drag_icon_surface == null)
                            try self.queueDragIcon();
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
                                .icon = if (self.test_toplevel_drag) self.drag_icon_surface.?.id else null,
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
                    try std.testing.expectEqual(self.pointer_axis_expected_time, value.time);
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
        } else if (target.object.interface == &protocol.zwp_text_input_v3.info) {
            switch (try protocol.zwp_text_input_v3.decodeEvent(message, fds)) {
                .enter => |value| {
                    try std.testing.expectEqual(self.surface.?.id, value.surface);
                    self.text_input_enter += 1;
                },
                .leave => {},
                .preedit_string => |value| {
                    self.text_input_preedit += 1;
                    self.text_input_preedit_valid = std.mem.eql(u8, value.text orelse "", "pré") and value.cursor_begin == 2 and value.cursor_end == 4;
                },
                .commit_string => |value| {
                    self.text_input_commit += 1;
                    self.text_input_commit_valid = std.mem.eql(u8, value.text orelse "", "committed");
                },
                .delete_surrounding_text => |value| {
                    self.text_input_delete += 1;
                    self.text_input_delete_valid = value.before_length == 4 and value.after_length == 2;
                },
                .done => self.text_input_done += 1,
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
                    if (self.test_toplevel_drag and !self.toplevel_drag_attached) {
                        try protocol.xdg_toplevel_drag_v1.encodeRequest(
                            self.queue,
                            self.toplevel_drag.?.id,
                            .{ .attach = .{
                                .toplevel = self.toplevel.?.id,
                                .x_offset = 1,
                                .y_offset = 1,
                            } },
                        );
                        self.toplevel_drag_attached = true;
                    }
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
                .cancelled => {
                    self.drag_cancelled += 1;
                    if (self.test_toplevel_drag and !self.toplevel_drag_destroyed) {
                        try wayring.client.sendRequest(
                            protocol.xdg_toplevel_drag_v1,
                            self.objects,
                            self.queue,
                            self.toplevel_drag.?,
                            .{ .destroy = .{} },
                        );
                        self.toplevel_drag_destroyed = true;
                    }
                },
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
                    if (!self.test_text_input) {
                        try wayring.client.sendRequest(
                            protocol.wl_buffer,
                            self.objects,
                            self.queue,
                            self.mapped_buffer.?,
                            .{ .destroy = .{} },
                        );
                        self.mapped_buffer = null;
                    }
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
        if (self.registry_only) {
            if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
                self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
            if (std.mem.eql(u8, value.interface, protocol.wp_security_context_manager_v1.info.name)) {
                self.security_global_seen = true;
                if (self.test_security_context)
                    self.security_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wp_security_context_manager_v1.info, @min(value.version, 1), null);
            }
            if (std.mem.eql(u8, value.interface, protocol.ext_data_control_manager_v1.info.name))
                self.ext_data_control_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.zwlr_data_control_manager_v1.info.name))
                self.wlr_data_control_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.zwp_input_method_manager_v2.info.name))
                self.input_method_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.zwp_virtual_keyboard_manager_v1.info.name))
                self.virtual_keyboard_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.zwlr_virtual_pointer_manager_v1.info.name))
                self.virtual_pointer_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.ext_foreign_toplevel_list_v1.info.name))
                self.foreign_toplevel_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.ext_workspace_manager_v1.info.name))
                self.workspace_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.ext_output_image_capture_source_manager_v1.info.name))
                self.image_output_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.ext_foreign_toplevel_image_capture_source_manager_v1.info.name))
                self.image_toplevel_global_seen = true;
            if (std.mem.eql(u8, value.interface, protocol.ext_image_copy_capture_manager_v1.info.name))
                self.image_copy_global_seen = true;
            return;
        }
        if (std.mem.eql(u8, value.interface, protocol.wl_compositor.info.name))
            self.compositor = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_compositor.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_shm.info.name))
            self.shm = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_shm.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.xdg_wm_base.info.name))
            self.wm_base = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_wm_base.info, @min(value.version, 7), null);
        if (std.mem.eql(u8, value.interface, protocol.wl_seat.info.name))
            self.seat = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_seat.info, @min(value.version, 9), null);
        if (self.test_text_input and std.mem.eql(u8, value.interface, protocol.zwp_text_input_manager_v3.info.name))
            self.text_input_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwp_text_input_manager_v3.info, 1, null);
        if (self.test_text_input) {
            if (self.text_input == null and self.text_input_manager != null and self.seat != null)
                self.text_input = (try protocol.zwp_text_input_manager_v3.construct_get_text_input(self.objects, self.queue, self.text_input_manager.?, .{ .seat = self.seat.?.id })).id;
            return;
        }
        if (std.mem.eql(u8, value.interface, protocol.wl_data_device_manager.info.name))
            self.data_device_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_data_device_manager.info, @min(value.version, 3), null);
        if (self.test_toplevel_drag and std.mem.eql(
            u8,
            value.interface,
            protocol.xdg_toplevel_drag_manager_v1.info.name,
        )) self.toplevel_drag_manager = try ClientCore.bind(
            self.objects,
            self.queue,
            self.registry,
            value.name,
            &protocol.xdg_toplevel_drag_manager_v1.info,
            1,
            null,
        );
        if (std.mem.eql(u8, value.interface, protocol.wl_output.info.name))
            self.output = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wl_output.info, @min(value.version, 4), null);
        if (self.test_toplevel_tag and std.mem.eql(u8, value.interface, protocol.xdg_toplevel_tag_manager_v1.info.name))
            self.toplevel_tag_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.xdg_toplevel_tag_manager_v1.info, 1, null);
        if (std.mem.eql(u8, value.interface, protocol.ext_idle_notifier_v1.info.name))
            self.idle_notifier = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.ext_idle_notifier_v1.info, @min(value.version, 2), null);
        if (std.mem.eql(u8, value.interface, protocol.zwp_idle_inhibit_manager_v1.info.name))
            self.idle_inhibit_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.zwp_idle_inhibit_manager_v1.info, @min(value.version, 1), null);
        if (self.test_pointer_warp and std.mem.eql(u8, value.interface, protocol.wp_pointer_warp_v1.info.name))
            self.pointer_warp_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wp_pointer_warp_v1.info, @min(value.version, 1), null);
        if (std.mem.eql(u8, value.interface, protocol.wp_security_context_manager_v1.info.name)) {
            self.security_global_seen = true;
            if (self.test_security_context)
                self.security_manager = try ClientCore.bind(self.objects, self.queue, self.registry, value.name, &protocol.wp_security_context_manager_v1.info, @min(value.version, 1), null);
        }
        if (self.test_foreign_toplevel and std.mem.eql(
            u8,
            value.interface,
            protocol.ext_foreign_toplevel_list_v1.info.name,
        )) self.foreign_toplevel_list = try ClientCore.bind(
            self.objects,
            self.queue,
            self.registry,
            value.name,
            &protocol.ext_foreign_toplevel_list_v1.info,
            1,
            null,
        );
        if (self.test_wlr_foreign_toplevel and std.mem.eql(
            u8,
            value.interface,
            protocol.zwlr_foreign_toplevel_manager_v1.info.name,
        )) {
            self.wlr_foreign_toplevel_version = value.version;
            self.wlr_foreign_toplevel_manager = try ClientCore.bind(
                self.objects,
                self.queue,
                self.registry,
                value.name,
                &protocol.zwlr_foreign_toplevel_manager_v1.info,
                @min(value.version, 3),
                null,
            );
        }
        if (std.mem.eql(u8, value.interface, protocol.ext_foreign_toplevel_list_v1.info.name))
            self.foreign_toplevel_global_seen = true;
        if (std.mem.eql(u8, value.interface, protocol.ext_output_image_capture_source_manager_v1.info.name)) {
            self.image_output_global_seen = true;
            if (self.test_image_capture_sources)
                self.image_output_manager = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.ext_output_image_capture_source_manager_v1.info,
                    1,
                    null,
                );
        }
        if (std.mem.eql(u8, value.interface, protocol.ext_foreign_toplevel_image_capture_source_manager_v1.info.name)) {
            self.image_toplevel_global_seen = true;
            if (self.test_image_capture_sources)
                self.image_toplevel_manager = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.ext_foreign_toplevel_image_capture_source_manager_v1.info,
                    1,
                    null,
                );
        }
        if (std.mem.eql(u8, value.interface, protocol.ext_image_copy_capture_manager_v1.info.name)) {
            self.image_copy_global_seen = true;
            if (self.test_image_capture_sources)
                self.image_copy_manager = try ClientCore.bind(
                    self.objects,
                    self.queue,
                    self.registry,
                    value.name,
                    &protocol.ext_image_copy_capture_manager_v1.info,
                    1,
                    null,
                );
        }
        try self.maybeCreateImageCaptureSources();
        try self.maybeCreateToplevelDrag();
    }

    fn maybeCreateImageCaptureSources(self: *Handler) !void {
        if (!self.test_image_capture_sources) return;
        if (self.image_output_source == null and self.image_output_manager != null and self.output != null)
            self.image_output_source = (try protocol.ext_output_image_capture_source_manager_v1.construct_create_source(
                self.objects,
                self.queue,
                self.image_output_manager.?,
                .{ .output = self.output.?.id },
            )).source;
        if (self.image_toplevel_source == null and self.image_toplevel_manager != null and self.foreign_toplevel_handle != null)
            self.image_toplevel_source = (try protocol.ext_foreign_toplevel_image_capture_source_manager_v1.construct_create_source(
                self.objects,
                self.queue,
                self.image_toplevel_manager.?,
                .{ .toplevel_handle = self.foreign_toplevel_handle.?.id },
            )).source;
        if (self.image_cursor_session == null and self.image_copy_manager != null and
            self.image_output_source != null and self.pointer != null)
            self.image_cursor_session = (try protocol.ext_image_copy_capture_manager_v1.construct_create_pointer_cursor_session(
                self.objects,
                self.queue,
                self.image_copy_manager.?,
                .{
                    .source = self.image_output_source.?.id,
                    .pointer = self.pointer.?.id,
                },
            )).session;
    }

    fn queueToplevelCapture(self: *Handler) !void {
        if (self.image_capture_session != null or self.image_copy_manager == null or
            self.image_toplevel_source == null) return error.CaptureUnavailable;
        self.image_capture_session = (try protocol.ext_image_copy_capture_manager_v1.construct_create_session(
            self.objects,
            self.queue,
            self.image_copy_manager.?,
            .{
                .source = self.image_toplevel_source.?.id,
                .options = protocol.ext_image_copy_capture_manager_v1.options.fromInt(0),
            },
        )).session;
    }

    fn queueToplevelCaptureFrame(self: *Handler) !void {
        if (self.image_capture_frame != null) return;
        try std.testing.expectEqual(@as(u32, 3), self.image_capture_width);
        try std.testing.expectEqual(@as(u32, 2), self.image_capture_height);
        const descriptor = try ordinaryMemfd(24, 0, &([_]u8{0x55} ** 24));
        const retained = linux.fcntl(descriptor, linux.F.DUPFD_CLOEXEC, 0);
        if (linux.errno(retained) != .SUCCESS) return error.DuplicateFailed;
        self.image_capture_read_fd = @intCast(retained);
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 24 },
        );
        self.image_capture_buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{
                .offset = 0,
                .width = 3,
                .height = 2,
                .stride = 12,
                .format = .argb8888,
            },
        )).id;
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
        self.image_capture_frame = (try protocol.ext_image_copy_capture_session_v1.construct_create_frame(
            self.objects,
            self.queue,
            self.image_capture_session.?,
            .{},
        )).frame;
        try protocol.ext_image_copy_capture_frame_v1.encodeRequest(
            self.queue,
            self.image_capture_frame.?.id,
            .{ .attach_buffer = .{ .buffer = self.image_capture_buffer.?.id } },
        );
        try protocol.ext_image_copy_capture_frame_v1.encodeRequest(
            self.queue,
            self.image_capture_frame.?.id,
            .{ .capture = .{} },
        );
    }

    fn destroyToplevelCapture(self: *Handler) !void {
        try wayring.client.sendRequest(
            protocol.ext_image_copy_capture_frame_v1,
            self.objects,
            self.queue,
            self.image_capture_frame.?,
            .{ .destroy = .{} },
        );
        self.image_capture_frame = null;
        try wayring.client.sendRequest(
            protocol.ext_image_copy_capture_session_v1,
            self.objects,
            self.queue,
            self.image_capture_session.?,
            .{ .destroy = .{} },
        );
        self.image_capture_session = null;
        try wayring.client.sendRequest(
            protocol.wl_buffer,
            self.objects,
            self.queue,
            self.image_capture_buffer.?,
            .{ .destroy = .{} },
        );
        self.image_capture_buffer = null;
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
        try self.maybeCreateToplevelDrag();
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
        if (self.test_foreign_toplevel) {
            try protocol.xdg_toplevel.encodeRequest(self.queue, self.toplevel.?.id, .{
                .set_title = .{ .title = "Foreign title" },
            });
            try protocol.xdg_toplevel.encodeRequest(self.queue, self.toplevel.?.id, .{
                .set_app_id = .{ .app_id = "org.example.Foreign" },
            });
        }
        try protocol.xdg_surface.encodeRequest(self.queue, self.xdg_surface.?.id, .{
            .set_window_geometry = .{ .x = 1, .y = 0, .width = 2, .height = 2 },
        });
        if (self.frame_before_map) self.frame_callback = (try protocol.wl_surface.construct_frame(
            self.objects,
            self.queue,
            self.surface.?,
            .{},
        )).callback;
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{ .commit = .{} });
        self.shell_created = true;
        try self.maybeCreateToplevelDrag();
    }

    fn maybeSetToplevelTag(self: *Handler) !void {
        if (!self.test_toplevel_tag or self.toplevel_tag_set or self.toplevel_tag_manager == null or self.toplevel == null) return;
        try protocol.xdg_toplevel_tag_manager_v1.encodeRequest(self.queue, self.toplevel_tag_manager.?.id, .{
            .set_toplevel_tag = .{ .toplevel = self.toplevel.?.id, .tag = "main" },
        });
        try protocol.xdg_toplevel_tag_manager_v1.encodeRequest(self.queue, self.toplevel_tag_manager.?.id, .{
            .set_toplevel_description = .{ .toplevel = self.toplevel.?.id, .description = "Main window" },
        });
        self.toplevel_tag_set = true;
    }

    fn maybeCreateToplevelDrag(self: *Handler) !void {
        if (!self.test_toplevel_drag or self.toplevel_drag != null or
            self.toplevel_drag_manager == null or self.data_source == null) return;
        self.toplevel_drag = (try protocol.xdg_toplevel_drag_manager_v1.construct_get_xdg_toplevel_drag(
            self.objects,
            self.queue,
            self.toplevel_drag_manager.?,
            .{ .data_source = self.data_source.?.id },
        )).id;
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
        if (!self.test_text_input and !self.frame_before_map) {
            self.frame_callback = (try protocol.wl_surface.construct_frame(
                self.objects,
                self.queue,
                self.surface.?,
                .{},
            )).callback;
        }
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{
            .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{
            .damage_buffer = .{ .x = 0, .y = 0, .width = 3, .height = 2 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.surface.?.id, .{ .commit = .{} });
        if (!self.test_text_input) {
            try wayring.client.sendRequest(
                protocol.wl_shm_pool,
                self.objects,
                self.queue,
                pool.id,
                .{ .destroy = .{} },
            );
        }
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

    fn queueDragIcon(self: *Handler) !void {
        const descriptor = try ordinaryMemfd(4, 0, &.{ 0xff, 0xff, 0xff, 0xff });
        const pool = try protocol.wl_shm.construct_create_pool(
            self.objects,
            self.queue,
            self.shm.?,
            .{ .fd = descriptor, .size = 4 },
        );
        self.drag_icon_buffer = (try protocol.wl_shm_pool.construct_create_buffer(
            self.objects,
            self.queue,
            pool.id,
            .{ .offset = 0, .width = 1, .height = 1, .stride = 4, .format = .argb8888 },
        )).id;
        self.drag_icon_surface = (try protocol.wl_compositor.construct_create_surface(
            self.objects,
            self.queue,
            self.compositor.?,
            .{},
        )).id;
        try protocol.wl_surface.encodeRequest(self.queue, self.drag_icon_surface.?.id, .{
            .attach = .{ .buffer = self.drag_icon_buffer.?.id, .x = 0, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(self.queue, self.drag_icon_surface.?.id, .{
            .offset = .{ .x = 1, .y = 0 },
        });
        try protocol.wl_surface.encodeRequest(
            self.queue,
            self.drag_icon_surface.?.id,
            .{ .commit = .{} },
        );
        try wayring.client.sendRequest(
            protocol.wl_shm_pool,
            self.objects,
            self.queue,
            pool.id,
            .{ .destroy = .{} },
        );
    }

    fn queuePointerWarp(self: *Handler) !void {
        try protocol.wp_pointer_warp_v1.encodeRequest(
            self.queue,
            self.pointer_warp_manager.?.id,
            .{ .warp_pointer = .{
                .surface = self.surface.?.id,
                .pointer = self.pointer.?.id,
                .x = 256,
                .y = 256,
                .serial = self.pointer_enter_serial,
            } },
        );
        self.pointer_warp_queued = true;
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

fn drainTabletClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *TabletHandler,
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

fn submitTabletClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: *TabletHandler,
) !void {
    _ = try driver.schedule();
    _ = try driver.prepare(handler);
    _ = try reactor.ring.submit();
}

fn drainClient(
    reactor: *wayring.io_uring.Reactor,
    driver: *ClientDriver,
    handler: anytype,
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
    handler: anytype,
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
        .x = 0,
        .y = 0,
        .width = 3,
        .height = 2,
    })).?;
    try std.testing.expectEqual(source.sample, placed.sample);
    try std.testing.expectEqual(source.presentation, placed.presentation);
}
