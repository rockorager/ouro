//! Ouro's single-output physical-display executable.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("xdg_protocol");

const linux = std.os.linux;
const Compositor = ouro.compositor.Compositor(protocol);
const Loop = ouro.loop.Loop(protocol);
const Coordinator = ouro.physical.Coordinator(protocol);

const shm_formats = [_]wayring.shm.Format{
    .{ .value = protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

const Options = struct {
    socket: []const u8 = "/tmp/ouro.sock",
    renderer: ouro.real_output.RendererPreference = .vulkan_then_pixman,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const options = parseOptions(init.minimal.args) catch |err| {
        usage();
        return err;
    };
    const dri_result = linux.open("/dev/dri", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (linux.errno(dri_result) != .SUCCESS) {
        std.log.err("DRM smoke unavailable: /dev/dri is absent or inaccessible", .{});
        return error.DrmHardwareUnavailable;
    }
    _ = linux.close(@intCast(dri_result));
    var shutdown_signals = try ouro.shutdown_signal.Watcher.install();
    defer shutdown_signals.deinit();

    wayring.unix_socket.unlink(options.socket) catch {};
    defer wayring.unix_socket.unlink(options.socket) catch {};
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(options.socket, 128),
        compositorConfig(),
    );
    const coordinator = Coordinator.create(allocator, root, .{
        .input = ouro.input_platform.real,
    }, .{
        .router_capacity = 16,
        .timer_capacity = 4,
        .device_capacity = 36,
        .input = .{
            .device_capacity = 16,
            .event_capacity = 64,
            .restricted_capacity = 32,
        },
        .shm = .{
            .limits = .{ .max_pool_bytes = 16 * 1024 * 1024 },
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
        .protocol_output = .{ .association_capacity = 17 },
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
        },
        .output = .{
            .output_id = .{ .index = 0, .generation = 1 },
            .scheduler = .{
                .refresh_ns = 16_666_667,
                .render_budget_ns = 7_000_000,
            },
            .renderer = options.renderer,
            .image_count = 3,
            .max_samples = 17,
            .max_source_bytes = 32 * 1024 * 1024,
            .max_surface_bytes = 16 * 1024 * 1024,
            .max_source_width = 8192,
            .max_source_height = 8192,
        },
    }) catch |err| {
        root.deinit() catch {};
        return err;
    };
    var loop = Loop.init(
        allocator,
        root,
        &coordinator.router,
        &coordinator.timers,
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
    loop.installShutdown(&shutdown_signals) catch |err| {
        run_error = err;
    };
    coordinator.start(&loop) catch |err| {
        if (run_error == null) run_error = err;
    };
    if (run_error != null) coordinator.requestStop() catch {};

    if (run_error == null)
        std.log.info("Ouro listening on {s}; renderer policy={s}", .{
            options.socket,
            @tagName(options.renderer),
        });
    var wayring_drained = false;
    var signal_stop_started = false;
    var wait_for_completion = false;
    while (!wayring_drained or !coordinator.backendDrainComplete()) {
        if (wait_for_completion) loop.waitForCompletion() catch |err| {
            if (run_error == null) run_error = err;
            coordinator.requestStop() catch |stop_err| {
                if (run_error == null) run_error = stop_err;
            };
            wait_for_completion = false;
            continue;
        };
        const progress = loop.turn(coordinator) catch |err| {
            if (run_error == null) run_error = err;
            coordinator.requestStop() catch |stop_err| {
                if (run_error == null) run_error = stop_err;
            };
            wait_for_completion = false;
            continue;
        };
        wayring_drained = progress.wayring.shutdown_complete;
        wait_for_completion = !progress.needs_more_work;
        if (!signal_stop_started and progress.shutdown_requested) {
            signal_stop_started = true;
            coordinator.requestStop() catch |err| {
                if (run_error == null) run_error = err;
            };
            wait_for_completion = false;
        }
    }
    loop.deinit();
    const destroy_result = coordinator.destroy();
    const root_result = root.deinit();
    if (run_error) |err| return err;
    try destroy_result;
    try root_result;
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
            if (options.socket.len == 0) return error.InvalidSocket;
        } else return error.UnknownArgument;
    }
    return options;
}

fn usage() void {
    std.debug.print(
        \\usage: ouro [--socket=PATH] [--renderer=auto|pixman|vulkan]
        \\
        \\  auto    try Vulkan, then fall back to Pixman at startup
        \\  pixman  require the CPU Pixman renderer
        \\  vulkan  require Vulkan and KMS IN_FENCE_FD (no host wait)
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
                .received_fd_budget = 2,
                .transmit_byte_budget = 8192,
                .transmit_fd_budget = 2,
            },
            .object_capacity = 128,
            .object_quota = 128,
            .buckets_per_client = 128,
            .max_globals = 15,
            .registry_capacity = 4,
        },
    };
}
