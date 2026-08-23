//! Ouro's single-output physical-display executable.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");

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

    wayring.unix_socket.unlink(options.socket) catch {};
    defer wayring.unix_socket.unlink(options.socket) catch {};
    const root = try Compositor.create(
        allocator,
        try wayring.unix_socket.listen(options.socket, 1),
        compositorConfig(),
    );
    const coordinator = Coordinator.create(allocator, root, .{}, .{
        .router_capacity = 16,
        .timer_capacity = 4,
        .device_capacity = 4,
        .shm = .{
            .limits = .{ .max_pool_bytes = 16 * 1024 * 1024 },
            .pool_capacity = 8,
            .buffer_capacity = 16,
            .formats = &shm_formats,
        },
        .surface = .{
            .surface_capacity = 8,
            .region_capacity = 8,
            .region_operation_capacity = 64,
            .frame_callback_capacity = 64,
            .release_callback_capacity = 64,
            .content_update_capacity = 16,
            .dependency_capacity = 16,
            .attachment_capacity = 16,
            .copy_capacity = 4,
            .max_copy_bytes = 16 * 1024 * 1024,
        },
        .drm = .{
            .card_capacity = 8,
            .connector_capacity = 32,
            .mode_capacity = 128,
            .connector_encoder_capacity = 64,
            .encoder_capacity = 32,
            .crtc_capacity = 16,
            .plane_capacity = 64,
            .format_capacity = 256,
            .event_capacity = 16,
        },
        .output = .{
            .output_id = .{ .index = 0, .generation = 1 },
            .scheduler = .{
                .refresh_ns = 16_666_667,
                .render_budget_ns = 2_000_000,
            },
            .renderer = options.renderer,
            .image_count = 3,
            .max_samples = 8,
            .max_source_bytes = 16 * 1024 * 1024,
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
    coordinator.start(&loop) catch |err| {
        run_error = err;
        coordinator.requestStop() catch |stop_err| {
            run_error = stop_err;
        };
    };

    if (run_error == null)
        std.log.info("Ouro listening on {s}; renderer policy={s}", .{
            options.socket,
            @tagName(options.renderer),
        });
    var wayring_drained = false;
    while (!wayring_drained or !coordinator.backendDrainComplete()) {
        const progress = loop.turn(coordinator) catch |err| {
            if (run_error == null) run_error = err;
            coordinator.requestStop() catch |stop_err| {
                if (run_error == null) run_error = stop_err;
            };
            continue;
        };
        wayring_drained = progress.wayring.shutdown_complete;
        if (!progress.needs_more_work and progress.reaped == 0) {
            std.Io.sleep(init.io, .fromMilliseconds(1), .awake) catch |err| {
                if (run_error == null) run_error = err;
                coordinator.requestStop() catch |stop_err| {
                    if (run_error == null) run_error = stop_err;
                };
            };
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
            .max_connections = 1,
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
            .max_globals = 2,
            .registry_capacity = 1,
        },
    };
}
