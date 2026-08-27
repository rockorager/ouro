//! Ouro's single-output physical-display executable.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("xdg_protocol");

const linux = std.os.linux;
const c = @cImport({
    @cInclude("sys/stat.h");
});
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
    output_icc: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    const options = parseOptions(init.minimal.args) catch |err| {
        usage();
        return err;
    };
    if (options.output_icc != null and options.renderer != .vulkan)
        return error.OutputIccRequiresVulkan;
    var output_profile_fd: linux.fd_t = -1;
    defer if (output_profile_fd >= 0) {
        _ = linux.close(output_profile_fd);
    };
    var output_lut: ouro.icc.Lut = undefined;
    var output_lut_valid = false;
    defer if (output_lut_valid) {
        output_lut.deinit(allocator);
    };
    var output_description = ouro.render.color.Description.srgb;
    var output_profile_size: u32 = 0;
    if (options.output_icc) |path| {
        const loaded = try loadOutputProfile(allocator, path);
        output_profile_fd = loaded.fd;
        output_profile_size = @intCast(loaded.bytes.len);
        defer allocator.free(loaded.bytes);
        output_lut = try ouro.icc.compileOutput(allocator, loaded.bytes);
        output_lut_valid = true;
        output_description.lut = &output_lut;
    }
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
        .timer_capacity = 5,
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
        .enable_color_protocols = options.renderer == .vulkan,
        .color_management = .{
            // Compilation remains single-worker and byte-bounded, while the
            // queue can admit every retained client ICC description.
            .async_jobs = 16,
            .queued_profile_bytes = 32 * 1024 * 1024,
            .retained_luts = 16,
            .output_description = output_description,
            .output_icc_fd = output_profile_fd,
            .output_icc_size = output_profile_size,
        },
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
            // Sixteen client ICC descriptions plus a distinct output profile.
            .max_color_luts = 17,
            .enable_color_management = options.renderer == .vulkan,
            .output_color_description = output_description,
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
        } else if (std.mem.startsWith(u8, argument, "--output-icc=")) {
            options.output_icc = argument["--output-icc=".len..];
            if (options.output_icc.?.len == 0) return error.InvalidOutputIcc;
        } else return error.UnknownArgument;
    }
    return options;
}

fn usage() void {
    std.debug.print(
        \\usage: ouro [--socket=PATH] [--renderer=auto|pixman|vulkan] [--output-icc=PATH]
        \\
        \\  auto    try Vulkan, then fall back to Pixman at startup
        \\  pixman  require the CPU Pixman renderer
        \\  vulkan  require Vulkan and KMS IN_FENCE_FD (no host wait)
        \\  --output-icc  apply an ICC v2/v4 output profile and VCGT (Vulkan only)
        \\
    , .{});
}

fn loadOutputProfile(allocator: std.mem.Allocator, path: []const u8) !struct { fd: linux.fd_t, bytes: []u8 } {
    const terminated = try allocator.dupeZ(u8, path);
    defer allocator.free(terminated);
    const raw = linux.open(terminated, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(raw) != .SUCCESS) return error.OpenOutputIccFailed;
    const fd: linux.fd_t = @intCast(raw);
    errdefer _ = linux.close(fd);
    var stat: c.struct_stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_size > ouro.icc.max_profile_bytes)
        return error.InvalidOutputIcc;
    const bytes = try allocator.alloc(u8, @intCast(stat.st_size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const read = linux.pread(fd, bytes[offset..].ptr, bytes.len - offset, @intCast(offset));
        if (linux.errno(read) != .SUCCESS or read == 0) return error.ReadOutputIccFailed;
        offset += read;
    }
    return .{ .fd = fd, .bytes = bytes };
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
            .object_quota = std.math.maxInt(u32),
            .buckets_per_client = 128,
            .max_globals = 48,
            .registry_capacity = 4,
        },
    };
}
