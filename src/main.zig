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
const PreparedConfig = ouro.configuration.Prepared(Runtime);
const fatal_shutdown_grace_ns = 5 * std.time.ns_per_s;

const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

const Options = struct {
    socket: ?[]const u8 = null,
    renderer: ouro.real_output.RendererPreference = .vulkan_then_pixman,
    scanout_modifier: ?u64 = null,
    drm_device: ?[]const u8 = null,
    config: ?[]const u8 = null,
    export_config: bool = false,
    export_mcp_descriptor: bool = false,
    mcp_socket: ?[]const u8 = null,
    managed_session: bool = false,
    headless: bool = false,
    disable_hdr: bool = false,
    trace_pacing: bool = false,
    hardware_cursor: bool = true,
};

pub fn main(init: std.process.Init) !void {
    // Reuse small allocations instead of mapping a page for every commit.
    const allocator = std.heap.smp_allocator;
    const options = parseOptions(init.minimal.args) catch |err| {
        usage();
        return err;
    };
    if (options.export_mcp_descriptor) {
        var output: std.Io.Writer.Allocating = .init(allocator);
        defer output.deinit();
        try ouro.control.writeDescriptor(&output.writer);
        try output.writer.writeByte('\n');
        try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
        return;
    }
    if (options.export_config) {
        const store: ouro.config.Store = .{
            .allocator = allocator,
            .io = init.io,
            .environ_map = init.environ_map,
            .explicit_path = options.config,
        };
        const source = try store.exportSource();
        defer allocator.free(source);
        try std.Io.File.stdout().writeStreamingAll(init.io, source);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
        return;
    }
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
    var performance: ouro.diagnostics.Recorder = .{};
    // Diagnostics must not prevent a graphical session from starting.
    performance.start() catch |err| std.log.warn("performance recorder unavailable: {t}", .{err});
    defer performance.stop();
    const config_store: ouro.config.Store = .{
        .allocator = allocator,
        .io = init.io,
        .environ_map = init.environ_map,
        .explicit_path = options.config,
    };
    var settings: ?ouro.settings_client.Client = null;
    defer if (settings) |*client| client.deinit();
    var initial_config = if (options.config != null) try config_store.load() else from_settings: {
        try systemd_session.startSettingsSocket();
        const runtime_dir = init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory;
        const path = try std.fmt.allocPrint(allocator, "{s}/ouro/settings.mcp.sock", .{runtime_dir});
        defer allocator.free(path);
        settings = try ouro.settings_client.Client.init(allocator, path);
        var update = settings.?.waitInitial(shutdown_signals.descriptor(), 10_000) catch |err| {
            std.log.err("cannot load ourosettings at {s}: {t}; start ourosettings.socket or use --config=PATH", .{ path, err });
            return err;
        };
        defer update.deinit(allocator);
        break :from_settings ouro.configuration.parseSettings(allocator, update) catch |err| {
            std.log.err("invalid ourosettings /compositor at startup: {t}", .{err});
            return err;
        };
    };
    defer initial_config.deinit();
    var initial = try PreparedConfig.init(allocator, &initial_config);
    var initial_owned = true;
    defer if (initial_owned) initial.deinit();
    // Do not tear down a managed graphical session before startup settings
    // have been received and validated.
    try systemd_session.prepare();
    defer systemd_session.shutdown() catch |err| {
        std.log.warn("could not shut down the managed graphical session: {t}", .{err});
    };
    const launcher: ouro.launcher.Systemd = .{
        .allocator = allocator,
        .io = init.io,
        .environ_map = init.environ_map,
    };
    var mcp = try ouro.mcp_client.Client.init(allocator);
    defer mcp.deinit();
    const control_path = if (options.mcp_socket) |path| try allocator.dupe(u8, path) else try std.fmt.allocPrint(allocator, "{s}/ouro.mcp.sock", .{init.environ_map.get("XDG_RUNTIME_DIR") orelse return error.MissingRuntimeDirectory});
    defer allocator.free(control_path);
    var catalog: std.Io.Writer.Allocating = .init(allocator);
    defer catalog.deinit();
    try ouro.control.writeCatalog(&catalog.writer);
    var control = try ouro.mcp_server.Server.init(allocator, control_path, catalog.written());
    defer control.deinit();
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
    var exit_deadline: ouro.shutdown_signal.ExitDeadline = .{};
    // Keep the deadline armed through all deferred cleanup, including stopping
    // the managed session and joining the diagnostics thread.
    errdefer exit_deadline.arm(fatal_shutdown_grace_ns);
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
        .router_capacity = 20,
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
                .adaptive_render_safety_ns = 200 * std.time.ns_per_us,
            },
            .renderer = options.renderer,
            .scanout_modifier = options.scanout_modifier,
            .enable_hdr = !options.disable_hdr,
            .trace_pacing = options.trace_pacing,
            .hardware_cursor = options.hardware_cursor,
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
        exit_deadline.arm(fatal_shutdown_grace_ns);
        root.deinit() catch {};
        return err;
    };
    if (performance.thread != null) coordinator.performance = &performance;
    coordinator.installConfig(
        &initial.engine,
        &initial.bindings,
        &initial.policy,
    ) catch |err| {
        exit_deadline.arm(fatal_shutdown_grace_ns);
        coordinator.requestStop() catch unreachable;
        std.debug.assert(coordinator.backendDrainComplete());
        coordinator.destroy() catch {};
        root.deinit() catch {};
        return err;
    };
    initial_owned = false;
    var runner = Runner.init(
        allocator,
        coordinator,
        .{ .completion_batch = 32 },
    ) catch |err| {
        exit_deadline.arm(fatal_shutdown_grace_ns);
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
    if (run_error == null) if (settings) |*client| runner.loop.installSettings(client) catch |err| {
        run_error = err;
    };
    if (run_error == null) runner.loop.installMcp(&mcp) catch |err| {
        run_error = err;
    };
    if (run_error == null) runner.loop.installControl(&control) catch |err| {
        run_error = err;
    };
    if (run_error != null) exit_deadline.arm(fatal_shutdown_grace_ns);

    if (run_error == null)
        std.log.info("Ouro listening on {s}; MCP at {s}; renderer policy={s}", .{
            socket,
            control_path,
            @tagName(options.renderer),
        });
    var wayring_drained = false;
    var signal_stop_started = false;
    var pending_config: ?PreparedConfig = null;
    defer if (pending_config) |*candidate| candidate.deinit();
    while (!wayring_drained or !coordinator.backendDrainComplete() or !runner.loop.settingsDrained() or !runner.loop.mcpDrained() or !runner.loop.controlDrained()) {
        if (coordinator.terminalFailure()) |terminal_error| {
            exit_deadline.arm(fatal_shutdown_grace_ns);
            std.log.err("backend cannot safely drain: {t}; exiting with scanout pinned for kernel teardown", .{terminal_error});
            // Do not run the normal destructors or publish buffer releases:
            // neither a failed disable nor loss of the seat connection proves
            // scanout idle. Process exit closes all process-owned FD/ring
            // references, unlike closing the manager's borrowed DRM FD alone.
            return run_error orelse terminal_error;
        }
        if (run_error != null and !signal_stop_started) {
            beginShutdown(&systemd_session, coordinator) catch |stop_err| {
                std.log.err("compositor shutdown failed: {t}; exiting with scanout pinned for kernel teardown", .{stop_err});
                return run_error.?;
            };
            signal_stop_started = true;
        }
        const progress = runner.turnAndWait() catch |err| {
            exit_deadline.arm(fatal_shutdown_grace_ns);
            if (run_error) |original_error| {
                // A fatal turn gets one attempt to start a normal drain. If
                // draining also fails, retrying retained work can spin forever
                // before submission. Keep GPU/buffer owners pinned on exit.
                std.log.err("compositor drain failed: {t}; exiting with scanout pinned for kernel teardown", .{err});
                return original_error;
            }
            run_error = err;
            std.log.err("compositor event loop failed: {t}", .{err});
            if (@errorReturnTrace()) |trace|
                std.debug.dumpErrorReturnTrace(trace)
            else
                std.log.err("error-return trace unavailable in this build", .{});
            continue;
        };
        const key_consumer = coordinator.bindingState();
        while (key_consumer.peekAction()) |binding| {
            const binding_stopped = applyAction(
                coordinator,
                &systemd_session,
                &launcher,
                &mcp,
                binding.action,
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
        var control_reload = false;
        if (!signal_stop_started and !progress.shutdown_requested) {
            while (control.peekCall()) |call| {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const command = ouro.control.decode(arena.allocator(), call.name, call.arguments) catch |err| {
                    try control.failCall(-32602, @errorName(err));
                    continue;
                };
                // Large snapshot buffers are transient heap allocations, not
                // part of the compositor stack or every action acknowledgment.
                var small_response: [4096]u8 = undefined;
                const response_storage = if (command == .get_state)
                    try arena.allocator().alloc(u8, ouro.mcp_server.maximum_frame_size - 2048)
                else
                    &small_response;
                var response = std.Io.Writer.fixed(response_storage);
                const stopped = executeControl(arena.allocator(), command, coordinator, &systemd_session, &launcher, &mcp, settings == null, &control_reload, &response) catch |err| failed: {
                    response = std.Io.Writer.fixed(response_storage);
                    try response.print("{{\"resultType\":\"complete\",\"content\":[{{\"type\":\"text\",\"text\":{f}}}],\"isError\":true}}", .{std.json.fmt(@errorName(err), .{})});
                    break :failed false;
                };
                try control.completeCall(response.buffered());
                if (stopped) {
                    signal_stop_started = true;
                    break;
                }
            }
        }
        wayring_drained = progress.wayring.shutdown_complete;
        if (!signal_stop_started and progress.shutdown_requested) {
            // Stop managed clients before draining their Wayland connections.
            // Waiting until the compositor defer runs creates a cycle: Ouro
            // waits for clients which systemd keeps alive until Ouro exits.
            beginShutdown(&systemd_session, coordinator) catch |err| {
                exit_deadline.arm(fatal_shutdown_grace_ns);
                if (run_error == null) run_error = err;
                continue;
            };
            signal_stop_started = true;
        }
        if (!signal_stop_started and (progress.settings_changed or ((progress.reload_requested or control_reload) and settings == null))) update_config: {
            var candidate = if (settings) |*client| from_settings: {
                var update = client.take() orelse break :update_config;
                defer update.deinit(allocator);
                break :from_settings ouro.configuration.parseSettings(allocator, update) catch |err| {
                    std.log.err("invalid ourosettings /compositor; keeping active configuration: {t}", .{err});
                    break :update_config;
                };
            } else config_store.load() catch |err| {
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                break :update_config;
            };
            defer candidate.deinit();
            const prepared = PreparedConfig.init(allocator, &candidate) catch |err| {
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                break :update_config;
            };
            if (pending_config) |*old| old.deinit();
            pending_config = prepared;
            runner.loop.configuration_pending = true;
        }
        if (!signal_stop_started and pending_config != null and coordinator.configInstallReady()) {
            const candidate = &pending_config.?;
            coordinator.installConfig(
                &candidate.engine,
                &candidate.bindings,
                &candidate.policy,
            ) catch |err| {
                candidate.deinit();
                pending_config = null;
                runner.loop.configuration_pending = false;
                std.log.err("configuration reload failed; keeping active configuration: {t}", .{err});
                continue;
            };
            pending_config = null;
            runner.loop.configuration_pending = false;
            std.log.info("configuration accepted; output changes complete asynchronously", .{});
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

fn applyAction(
    coordinator: *Runtime,
    systemd_session: *SystemdSession,
    launcher: *const ouro.launcher.Systemd,
    mcp: *ouro.mcp_client.Client,
    action: ouro.config.Action,
) !bool {
    switch (action) {
        .exit => {
            try beginShutdown(systemd_session, coordinator);
            return true;
        },
        .run => |argv| try launcher.launch(argv),
        .call => |call| try mcp.enqueue(call),
        else => try ouro.control.apply(coordinator, action),
    }
    return false;
}

fn executeControl(
    allocator: std.mem.Allocator,
    command: ouro.control.Command,
    coordinator: *Runtime,
    systemd_session: *SystemdSession,
    launcher: *const ouro.launcher.Systemd,
    mcp: *ouro.mcp_client.Client,
    file_config: bool,
    reload: *bool,
    writer: *std.Io.Writer,
) !bool {
    if (coordinator.session_lock_adapter.pendingLock() != null or
        coordinator.session_lock_adapter.activeLock() != null or coordinator.session_lock_adapter.isFailClosed())
        return error.SessionLocked;
    switch (command) {
        .get_state => {
            const state_storage = try allocator.alloc(u8, ouro.mcp_server.maximum_frame_size);
            defer allocator.free(state_storage);
            var state = std.Io.Writer.fixed(state_storage);
            try coordinator.desktop.writeControlState(&state);
            try ouro.control.writeStateResult(writer, state.buffered());
            return false;
        },
        .reload_config => {
            if (!file_config) return error.SettingsUpdateAutomatically;
            try writer.writeAll(ouro.control.accepted);
            reload.* = true;
            return false;
        },
        .action => |action| {
            // Construct the acknowledgment before any mutation.
            try writer.writeAll(ouro.control.accepted);
            return applyAction(coordinator, systemd_session, launcher, mcp, action);
        },
    }
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
        } else if (std.mem.startsWith(u8, argument, "--scanout-modifier=")) {
            options.scanout_modifier = std.fmt.parseInt(u64, argument["--scanout-modifier=".len..], 0) catch
                return error.InvalidScanoutModifier;
            if (options.scanout_modifier.? == ouro.gbm.modifier_invalid)
                return error.InvalidScanoutModifier;
        } else if (std.mem.startsWith(u8, argument, "--socket=")) {
            options.socket = argument["--socket=".len..];
            if (options.socket.?.len == 0) return error.InvalidSocket;
        } else if (std.mem.startsWith(u8, argument, "--drm-device=")) {
            options.drm_device = argument["--drm-device=".len..];
            if (options.drm_device.?.len == 0) return error.InvalidDrmDevice;
        } else if (std.mem.startsWith(u8, argument, "--config=")) {
            options.config = argument["--config=".len..];
            if (options.config.?.len == 0) return error.InvalidConfigPath;
        } else if (std.mem.eql(u8, argument, "--export-config")) {
            options.export_config = true;
        } else if (std.mem.eql(u8, argument, "--export-mcp-descriptor")) {
            options.export_mcp_descriptor = true;
        } else if (std.mem.startsWith(u8, argument, "--mcp-socket=")) {
            options.mcp_socket = argument["--mcp-socket=".len..];
            if (options.mcp_socket.?.len == 0) return error.InvalidSocket;
        } else if (std.mem.eql(u8, argument, "--managed-session")) {
            options.managed_session = true;
        } else if (std.mem.eql(u8, argument, "--headless")) {
            options.headless = true;
        } else if (std.mem.eql(u8, argument, "--disable-hdr")) {
            options.disable_hdr = true;
        } else if (std.mem.eql(u8, argument, "--trace-pacing")) {
            options.trace_pacing = true;
        } else if (std.mem.eql(u8, argument, "--software-cursor")) {
            options.hardware_cursor = false;
        } else return error.UnknownArgument;
    }
    if (options.scanout_modifier != null and options.renderer != .vulkan)
        return error.ModifierRequiresVulkan;
    return options;
}

fn usage() void {
    std.debug.print(
        \\usage: ouro [--socket=PATH] [--renderer=auto|pixman|vulkan] [--drm-device=PATH] [--config=PATH] [--managed-session] [--headless]
        \\
        \\  auto    try Vulkan, then fall back to Pixman at startup
        \\  pixman  require the CPU Pixman renderer
        \\  vulkan  require Vulkan and KMS IN_FENCE_FD (no host wait)
        \\  --scanout-modifier=0xHEX  diagnostic: require exact Vulkan output layout; no fallback
        \\  --disable-hdr  disable automatic HDR output selection (use SDR)
        \\  --trace-pacing  diagnostic: log per-frame monotonic timing; adds measurement overhead
        \\  --software-cursor  disable hardware cursor updates for comparison/troubleshooting
        \\  --drm-device  require this DRM card instead of automatic selection
        \\  --config      file-only override (base JSON and adjacent config.d); no ourosettings
        \\                otherwise subscribe to ourosettings /compositor (10s startup deadline)
        \\  --export-config  print merged legacy file configuration and exit (no settings writes)
        \\  --export-mcp-descriptor  print installed discovery JSON and exit (no display/settings needed)
        \\  --mcp-socket   override $XDG_RUNTIME_DIR/ouro.mcp.sock; parent must be private
        \\  --managed-session  publish and bind the systemd graphical session lifecycle
        \\  --headless     bypass libseat and input for an explicitly selected virtual DRM device
        \\  SIGHUP        reload --config sources; ourosettings updates arrive automatically
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
