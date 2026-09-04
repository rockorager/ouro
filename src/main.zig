//! Ouro's single-output physical-display executable.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("xdg_protocol");

const linux = std.os.linux;
const Compositor = ouro.compositor.Compositor(protocol);
const Runtime = ouro.physical.Coordinator(protocol);
const Runner = ouro.physical.Runner(protocol);
const SystemdSession = @import("systemd_session.zig");

const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

const Options = struct {
    socket: ?[]const u8 = null,
    renderer: ouro.real_output.RendererPreference = .vulkan_then_pixman,
    drm_device: ?[]const u8 = null,
    config: ?[]const u8 = null,
    managed_session: bool = false,
    headless: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const options = parseOptions(init.minimal.args) catch |err| {
        usage();
        return err;
    };
    if (options.headless and (options.drm_device == null or options.managed_session)) {
        usage();
        return error.InvalidHeadlessOptions;
    }
    const managed_socket = if (options.socket == null and options.managed_session)
        try std.fmt.allocPrint(
            allocator,
            "{s}/ouro.sock",
            .{init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory},
        )
    else
        null;
    defer if (managed_socket) |value| allocator.free(value);
    const socket = options.socket orelse managed_socket orelse "/tmp/ouro.sock";
    const wayland_display = if (managed_socket != null) "ouro.sock" else socket;
    var systemd_session = SystemdSession.init(
        init.io,
        init.environ_map,
        options.managed_session,
    );
    if (options.managed_session) {
        _ = init.environ_map.swapRemove("DISPLAY");
        _ = init.environ_map.swapRemove("WAYLAND_DISPLAY");
        try init.environ_map.put("WAYLAND_DISPLAY", wayland_display);
        try init.environ_map.put("XDG_CURRENT_DESKTOP", "ouro");
        try init.environ_map.put("XDG_SESSION_DESKTOP", "ouro");
        try init.environ_map.put("XDG_SESSION_TYPE", "wayland");
    }
    // Install before any subsystem can create a worker. All threads must
    // inherit the blocked mask so TERM/INT/HUP are delivered through signalfd.
    var shutdown_signals = try ouro.shutdown_signal.Watcher.install();
    defer shutdown_signals.deinit();
    try systemd_session.prepare();
    defer systemd_session.shutdown() catch |err| {
        std.log.warn("could not shut down the managed graphical session: {t}", .{err});
    };
    const config_store: ouro.config.Store = .{
        .allocator = allocator,
        .io = init.io,
        .environ_map = init.environ_map,
        .explicit_path = options.config,
    };
    var initial_config = try config_store.load();
    defer initial_config.deinit();
    var initial_engine_settings = try Runtime.EngineSettings.init(
        allocator,
        initial_config.input_rules,
        initial_config.output_rules,
    );
    var initial_engine_settings_owned = true;
    defer if (initial_engine_settings_owned) initial_engine_settings.deinit();
    var initial_key_consumer = try Runtime.Bindings.snapshotFromReferenceConfig(
        allocator,
        &initial_config,
    );
    var initial_key_consumer_owned = true;
    defer if (initial_key_consumer_owned) initial_key_consumer.deinit();
    var initial_policy: Runtime.PolicySnapshot = .{
        .focus_follows_mouse = initial_config.general.focus_follows_mouse,
        .inner_gap = initial_config.general.inner_gap,
        .outer_gap = initial_config.general.outer_gap,
    };
    var initial_policy_owned = true;
    defer if (initial_policy_owned) initial_policy.deinit();
    const launcher: ouro.launcher.Systemd = .{
        .allocator = allocator,
        .io = init.io,
        .environ_map = init.environ_map,
    };
    const dri_result = linux.open("/dev/dri", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dri_result) != .SUCCESS) {
        std.log.err("DRM smoke unavailable: /dev/dri is absent or inaccessible", .{});
        return error.DrmHardwareUnavailable;
    }
    _ = linux.close(@intCast(dri_result));

    wayring.unix_socket.unlink(socket) catch {};
    defer wayring.unix_socket.unlink(socket) catch {};
    const session_state_path = try std.fmt.allocPrint(allocator, "{s}.sessions-v1", .{socket});
    defer allocator.free(session_state_path);
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(socket, 128),
        compositorConfig(),
    );
    const coordinator = Runtime.create(allocator, root, .{
        .session = if (options.headless) ouro.backend_platform.headless else ouro.backend_platform.real,
        .input = if (options.headless) null else ouro.input_platform.real,
        .hotplug = if (options.headless) null else ouro.drm_hotplug.real,
    }, .{
        .router_capacity = 17,
        .timer_capacity = 6,
        .device_capacity = 36,
        .input = .{
            .device_capacity = 16,
            .event_capacity = 64,
            .restricted_capacity = 32,
        },
        .shm = .{
            // Clients commonly reserve large sparse pools (foot uses 512 MiB)
            // while committing only output-sized buffers from them.
            .limits = .{ .max_pool_bytes = 1024 * 1024 * 1024 },
            .pool_capacity = 64,
            .buffer_capacity = 64,
            .formats = &shm_formats,
        },
        .surface = .{
            .surface_capacity = 16,
            .region_capacity = 8,
            .viewport_capacity = 8,
            .presentation_resource_capacity = 16,
            .presentation_feedback_capacity = 64,
            .region_operation_capacity = 64,
            .frame_callback_capacity = 64,
            .release_callback_capacity = 64,
            .content_update_capacity = 32,
            .dependency_capacity = 32,
            .attachment_capacity = 64,
            .copy_capacity = 4,
            .max_copy_bytes = 16 * 1024 * 1024,
        },
        .shell = .{
            .manager_capacity = 16,
            .positioner_capacity = 8,
            .surface_capacity = 16,
            .toplevel_capacity = 16,
            .popup_capacity = 8,
            .event_capacity = 64,
            .outbound_capacity = 64,
            .outstanding_configure_capacity = 32,
            .metadata_bytes = 256,
        },
        .xdg_session_store_path = session_state_path,
        .desktop = .{
            .toplevel_capacity = 16,
            .popup_capacity = 8,
            .command_capacity = 64,
            .metadata_bytes = 256,
        },
        .interaction = .{
            .window_capacity = 24,
            .device_capacity = 16,
            .command_capacity = 64,
            .bounds = .{ .x = 0, .y = 0, .width = 8192, .height = 8192 },
        },
        .linux_dmabuf = .{},
        .virtual_keyboard_reconciles_focus = options.headless,
        .enable_color_protocols = options.renderer == .vulkan,
        .color_management = .{
            // Compilation remains single-worker and byte-bounded. Up to 32
            // client and 32 output transforms fit the 64-slot renderer cache.
            .async_jobs = 16,
            .queued_profile_bytes = 32 * 1024 * 1024,
            .retained_luts = 32,
        },
        .protocol_output = .{ .association_capacity = 17 },
        .output_management = .{
            // One connector may consume the complete DRM mode inventory. A
            // bound manager snapshots every head and mode, and all eight
            // manager slots may have snapshots queued concurrently.
            .mode_capacity = 128,
            .outbound_capacity = 8192,
        },
        .drm = .{
            .card_capacity = 8,
            .connector_capacity = 32,
            .mode_capacity = 128,
            .connector_encoder_capacity = 64,
            .encoder_capacity = 32,
            .crtc_capacity = 16,
            .plane_capacity = 64,
            .format_capacity = 8192,
            .event_capacity = 16,
            .device_path = options.drm_device,
        },
        .output = .{
            .output_id = .{ .index = 0, .generation = 1 },
            .scheduler = .{
                .refresh_ns = 16_666_667,
                .render_budget_ns = 7_000_000,
                .adaptive_render_samples = 256,
                .adaptive_render_margin_ns = 2 * std.time.ns_per_ms,
            },
            .renderer = options.renderer,
            .image_count = 3,
            .max_samples = 17,
            .max_source_bytes = 32 * 1024 * 1024,
            .max_surface_bytes = 128 * 1024 * 1024,
            .max_content_bytes = 512 * 1024 * 1024,
            .max_source_width = 8192,
            .max_source_height = 8192,
            // Client descriptions and profile changes share a bounded cache.
            .max_color_luts = 64,
            .enable_color_management = options.renderer == .vulkan,
        },
    }) catch |err| {
        root.deinit() catch {};
        return err;
    };
    coordinator.installConfig(
        &initial_engine_settings,
        &initial_key_consumer,
        &initial_policy,
    ) catch |err| {
        coordinator.requestStop() catch unreachable;
        std.debug.assert(coordinator.backendDrainComplete());
        coordinator.destroy() catch {};
        root.deinit() catch {};
        return err;
    };
    initial_engine_settings_owned = false;
    initial_key_consumer_owned = false;
    initial_policy_owned = false;
    var runner = Runner.init(
        allocator,
        coordinator,
        .{ .completion_batch = 32 },
    ) catch |err| {
        coordinator.requestStop() catch unreachable;
        std.debug.assert(coordinator.backendDrainComplete());
        coordinator.destroy() catch {};
        root.deinit() catch {};
        return err;
    };
    var run_error: ?anyerror = null;
    runner.start() catch |err| {
        if (run_error == null) run_error = err;
    };
    if (run_error == null) systemd_session.ready(wayland_display) catch |err| {
        run_error = err;
    };
    if (run_error == null) runner.installShutdown(&shutdown_signals) catch |err| {
        run_error = err;
    };

    if (run_error == null)
        std.log.info("Ouro listening on {s}; renderer policy={s}", .{
            socket,
            @tagName(options.renderer),
        });
    var wayring_drained = false;
    var signal_stop_started = false;
    while (!wayring_drained or !coordinator.backendDrainComplete()) {
        if (run_error != null and !signal_stop_started) {
            beginShutdown(&systemd_session, coordinator) catch |stop_err| {
                std.log.err("compositor shutdown failed: {t}", .{stop_err});
                continue;
            };
            signal_stop_started = true;
        }
        const progress = runner.turnAndWait() catch |err| {
            if (run_error == null) {
                run_error = err;
                std.log.err("compositor event loop failed: {t}", .{err});
            }
            continue;
        };
        const key_consumer = coordinator.bindingState();
        while (key_consumer.peekAction()) |binding| {
            const binding_stopped = applyBinding(
                coordinator,
                &systemd_session,
                &launcher,
                binding,
            ) catch |err| failed: {
                std.log.err("binding action failed: {t}", .{err});
                break :failed false;
            };
            key_consumer.dropAction();
            if (binding_stopped) {
                signal_stop_started = true;
                break;
            }
        }
        wayring_drained = progress.wayring.shutdown_complete;
        if (!signal_stop_started and progress.shutdown_requested) {
            // Stop managed clients before draining their Wayland connections.
            // Waiting until the compositor defer runs creates a cycle: Ouro
            // waits for clients which systemd keeps alive until Ouro exits.
            beginShutdown(&systemd_session, coordinator) catch |err| {
                if (run_error == null) run_error = err;
                continue;
            };
            signal_stop_started = true;
        }
        if (!signal_stop_started and progress.reload_requested) {
            var candidate = config_store.load() catch |err| {
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                continue;
            };
            defer candidate.deinit();
            var engine_settings_candidate = Runtime.EngineSettings.init(
                allocator,
                candidate.input_rules,
                candidate.output_rules,
            ) catch |err| {
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                continue;
            };
            var policy_candidate: Runtime.PolicySnapshot = .{
                .focus_follows_mouse = candidate.general.focus_follows_mouse,
                .inner_gap = candidate.general.inner_gap,
                .outer_gap = candidate.general.outer_gap,
            };
            var key_consumer_candidate = Runtime.Bindings.snapshotFromReferenceConfig(
                allocator,
                &candidate,
            ) catch |err| {
                engine_settings_candidate.deinit();
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                continue;
            };
            coordinator.installConfig(
                &engine_settings_candidate,
                &key_consumer_candidate,
                &policy_candidate,
            ) catch |err| {
                engine_settings_candidate.deinit();
                key_consumer_candidate.deinit();
                policy_candidate.deinit();
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                continue;
            };
            std.log.info("configuration reloaded", .{});
        }
    }
    runner.deinit();
    const destroy_result = coordinator.destroy();
    const root_result = root.deinit();
    if (run_error) |err| return err;
    try destroy_result;
    try root_result;
}

fn beginShutdown(systemd_session: *SystemdSession, coordinator: *Runtime) !void {
    // Managed clients must stop before their Wayland connections and physical
    // outputs drain. Both operations remain retryable until each succeeds.
    try systemd_session.shutdown();
    try coordinator.requestStop();
}

fn applyBinding(
    coordinator: *Runtime,
    systemd_session: *SystemdSession,
    launcher: *const ouro.launcher.Systemd,
    binding: ouro.config.Binding,
) !bool {
    switch (binding.action) {
        .focus_next => try coordinator.focusNext(),
        .focus_previous => try coordinator.focusPrevious(),
        .move_next => try coordinator.moveFocusedTile(.next),
        .move_previous => try coordinator.moveFocusedTile(.previous),
        .focus_left => try coordinator.focusDirection(.left),
        .focus_right => try coordinator.focusDirection(.right),
        .focus_up => try coordinator.focusDirection(.up),
        .focus_down => try coordinator.focusDirection(.down),
        .move_left => try coordinator.moveFocusedDirection(.left),
        .move_right => try coordinator.moveFocusedDirection(.right),
        .move_up => try coordinator.moveFocusedDirection(.up),
        .move_down => try coordinator.moveFocusedDirection(.down),
        .move_output_next => try coordinator.moveFocusedToOutput(false),
        .move_output_previous => try coordinator.moveFocusedToOutput(true),
        .switch_workspace => |number| try coordinator.switchWorkspace(number),
        .move_to_workspace => |number| try coordinator.moveFocusedToWorkspace(number),
        .close => if (coordinator.focusedToplevel()) |id| try coordinator.requestClose(id),
        .toggle_fullscreen => try coordinator.toggleFocusedFullscreen(),
        .toggle_maximized => try coordinator.toggleFocusedMaximized(),
        .toggle_floating => try coordinator.toggleFocusedFloating(),
        .exit => {
            try beginShutdown(systemd_session, coordinator);
            return true;
        },
        .run => |argv| {
            launcher.launch(argv) catch |err| {
                std.log.err("could not launch {s}: {t}", .{ argv[0], err });
            };
        },
    }
    return false;
}

fn parseOptions(args: std.process.Args) !Options {
    var options: Options = .{};
    var iterator = args.iterate();
    _ = iterator.next();
    while (iterator.next()) |argument| {
        if (std.mem.eql(u8, argument, "--help")) {
            usage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, argument, "--renderer=pixman")) {
            options.renderer = .pixman;
        } else if (std.mem.eql(u8, argument, "--renderer=vulkan")) {
            options.renderer = .vulkan;
        } else if (std.mem.eql(u8, argument, "--renderer=auto")) {
            options.renderer = .vulkan_then_pixman;
        } else if (std.mem.startsWith(u8, argument, "--socket=")) {
            options.socket = argument["--socket=".len..];
            if (options.socket.?.len == 0) return error.InvalidSocket;
        } else if (std.mem.startsWith(u8, argument, "--drm-device=")) {
            options.drm_device = argument["--drm-device=".len..];
            if (options.drm_device.?.len == 0) return error.InvalidDrmDevice;
        } else if (std.mem.startsWith(u8, argument, "--config=")) {
            options.config = argument["--config=".len..];
            if (options.config.?.len == 0) return error.InvalidConfigPath;
        } else if (std.mem.eql(u8, argument, "--managed-session")) {
            options.managed_session = true;
        } else if (std.mem.eql(u8, argument, "--headless")) {
            options.headless = true;
        } else return error.UnknownArgument;
    }
    return options;
}

fn usage() void {
    std.debug.print(
        \\usage: ouro [--socket=PATH] [--renderer=auto|pixman|vulkan] [--drm-device=PATH] [--config=PATH] [--managed-session] [--headless]
        \\
        \\  auto    try Vulkan, then fall back to Pixman at startup
        \\  pixman  require the CPU Pixman renderer
        \\  vulkan  require Vulkan and KMS IN_FENCE_FD (no host wait)
        \\  --drm-device  require this DRM card instead of automatic selection
        \\  --config      load JSON output rules, including per-output ICC profiles
        \\  --managed-session  publish and bind the systemd graphical session lifecycle
        \\  --headless     bypass libseat and input for an explicitly selected virtual DRM device
        \\  SIGHUP        reload configuration; invalid replacements are rejected
        \\
    , .{});
}

fn compositorConfig() Compositor.Config {
    return .{
        .ring = .{ .entries = 64, .flags = 0 },
        .reactor = .{
            .receive_buffer_size = 8192,
            .receive_buffer_count = 8,
            .receive_control_capacity = 512,
            .fragment_block_size = 512,
            .fragment_block_count = 8,
            .transmit_block_size = 1024,
            .transmit_block_count = 16,
            .descriptor_count = 16,
            .send_descriptor_capacity = 4,
        },
        .runtime = .{
            .actor = .{
                .received_fd_budget = 16,
                .transmit_byte_budget = 8192,
                .transmit_fd_budget = 2,
            },
            .object_capacity = 128,
            .object_quota = 1024,
            .buckets_per_client = 128,
            // Leave room for all 32 wl_output globals plus the optional
            // wp_linux_drm_syncobj_manager_v1 discovered after startup.
            .max_globals = 128,
            .registry_capacity = 4,
        },
    };
}
