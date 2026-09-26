//! Real registry traffic against the physical coordinator, with deterministic
//! DRM/Vulkan boundaries. No GPU or display server is required.
const std = @import("std");
const wayring = @import("wayring");
const ouro = @import("ouro");
const protocol = @import("core_protocol");
const physical = @import("drm-presentation.zig");
const linux = std.os.linux;
const Coordinator = ouro.physical.Coordinator(protocol);
const Compositor = ouro.compositor.Compositor(protocol);
const Loop = ouro.loop.Loop(protocol);
const vk = ouro.vulkan_platform;

test "color startup: registry follows the selected color pipeline and survives recreation" {
    const Case = struct {
        preference: ouro.real_output.RendererPreference,
        failure: Probe.Failure = .none,
        protocols: bool = true,
        pipeline: bool = false,
        block_representation: bool = false,
        expected: ouro.real_output.RendererKind,
    };
    for ([_]Case{
        .{ .preference = .vulkan_then_pixman, .expected = .vulkan },
        .{ .preference = .vulkan_then_pixman, .block_representation = true, .expected = .vulkan },
        .{ .preference = .vulkan_then_pixman, .failure = .color, .expected = .pixman },
        .{ .preference = .vulkan_then_pixman, .failure = .target, .expected = .pixman },
        .{ .preference = .vulkan, .expected = .vulkan },
        .{ .preference = .pixman, .expected = .pixman },
        .{ .preference = .vulkan, .protocols = false, .expected = .vulkan },
        .{ .preference = .vulkan, .protocols = false, .pipeline = true, .expected = .vulkan },
    }) |case| {
        var fixture = try physical.Fixture.init();
        defer fixture.deinit();
        var probe: Probe = .{ .failure = case.failure };
        var drm_vtable = fixture.platforms().drm.vtable.*;
        drm_vtable.read_topology = Probe.topology;
        var platforms = fixture.platforms();
        platforms.drm.vtable = &drm_vtable;
        platforms.output.vulkan = probe.platform();
        var path_storage: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-color-startup-{d}.sock", .{linux.getpid()});
        wayring.unix_socket.unlink(path) catch {};
        defer wayring.unix_socket.unlink(path) catch {};
        var root_config = physical.compositorConfig();
        root_config.runtime.registry_capacity = 2;
        const root = try Compositor.create(std.testing.allocator, try wayring.unix_socket.listen(path, 1), root_config);
        var config = physical.coordinatorConfig();
        config.output.renderer = case.preference;
        config.enable_color_protocols = case.protocols;
        // Protocol enablement must require the pipeline on its own. Enabling
        // the pipeline independently must also preserve protocol opt-out.
        config.output.enable_color_management = case.pipeline;
        const coordinator = try Coordinator.create(std.testing.allocator, root, platforms, config);
        // Negotiate the pipeline normally, but delay its globals until the
        // output registry update has drained so only color publication blocks.
        if (case.block_representation) coordinator.color_protocols_enabled = false;
        var loop = try Loop.init(std.testing.allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
        try coordinator.start(&loop);
        var registry: Registry = undefined;
        if (case.expected == .vulkan) {
            registry = try Registry.connect(path);
            try registry.roundtrip(&loop, coordinator);
            try registry.expectColors(false);
            try std.testing.expect(registry.globals > 0);
        }
        try std.testing.expect(coordinator.render_device == null);
        try std.testing.expect(coordinator.color_management_adapter.global == null);
        try std.testing.expect(coordinator.color_representation_adapter.global == null);

        try fixture.signalSession(.enable);
        try waitOutput(&loop, coordinator, true);
        if (case.expected == .pixman) registry = try Registry.connect(path);
        const device = coordinator.render_device.?;
        const output_id = coordinator.physical_outputs[0].kms_output.?.outputId();
        const colors = case.protocols and case.expected == .vulkan;
        const require_color = case.protocols or case.pipeline;
        try std.testing.expectEqual(case.expected, device.rendererKind().?);
        try std.testing.expectEqual(require_color and case.expected == .vulkan, device.color_management_enabled);
        try std.testing.expectEqual(case.preference != .pixman, probe.creates != 0);
        if (probe.creates != 0) try std.testing.expectEqual(require_color, probe.required_color);
        if (case.block_representation) {
            try registry.roundtrip(&loop, coordinator);
            try registry.expectColors(false);
            try std.testing.expectEqual(coordinator.physical_output_count, coordinator.output_global_index);
            const peer = coordinator.clients.items[0].peer;
            const actor = try root.reactor.getActor(peer);
            for (0..256) |_| {
                _ = try loop.turn(coordinator);
                if (actor.transmit.queuedBytes() == 0 and !actor.transmit.sendActive()) break;
                pause();
            }
            try std.testing.expectEqual(@as(usize, 0), actor.transmit.queuedBytes());
            try std.testing.expect(!actor.transmit.sendActive());
            const budget = actor.transmit.byte_budget;
            // Each color global fits alone, but both cannot be queued at once.
            actor.transmit.byte_budget = 64;
            coordinator.color_protocols_enabled = true;
            try coordinator.prepare();
            try std.testing.expect(coordinator.color_management_adapter.global != null);
            const representation = coordinator.color_representation_adapter.global.?;
            try std.testing.expectEqual(representation, root.runtime.global_update.?.handle);
            try std.testing.expectEqual(peer, (try root.runtime.publishNext()).blocked);
            // No output update is pending, and both color handles now exist.
            // Coordinator preparation alone returns early; the driver must
            // send the first event and retry the second on normal loop turns.
            try coordinator.prepare();
            try std.testing.expectEqual(peer, (try root.runtime.publishNext()).blocked);
            try registry.roundtrip(&loop, coordinator);
            try registry.expectColors(true);
            try std.testing.expect(root.runtime.global_update == null);
            actor.transmit.byte_budget = budget;
        }
        try registry.roundtrip(&loop, coordinator);
        try registry.expectColors(colors);
        var late_registry = try Registry.connect(path);
        try late_registry.roundtrip(&loop, coordinator);
        try late_registry.expectColors(colors);
        _ = linux.close(late_registry.fd);
        const management = coordinator.color_management_adapter.global;
        const representation = coordinator.color_representation_adapter.global;
        const creates = probe.creates;

        try fixture.signalSession(.disable);
        try waitOutput(&loop, coordinator, false);
        try registry.roundtrip(&loop, coordinator);
        try registry.expectColors(colors);
        // Recreation must reuse the proven renderer. A prior Pixman fallback
        // must not grow globals when Vulkan later becomes available; Vulkan
        // must not silently downgrade after clients have bound its globals.
        probe.failure = if (case.expected == .vulkan) .color else .none;
        try fixture.signalSession(.enable);
        try waitOutput(&loop, coordinator, true);
        try std.testing.expectEqual(device, coordinator.render_device.?);
        try std.testing.expectEqual(creates, probe.creates);
        try std.testing.expect(!std.meta.eql(output_id, coordinator.physical_outputs[0].kms_output.?.outputId()));
        try std.testing.expectEqual(management, coordinator.color_management_adapter.global);
        try std.testing.expectEqual(representation, coordinator.color_representation_adapter.global);
        try registry.roundtrip(&loop, coordinator);
        try registry.expectColors(colors);

        _ = linux.close(registry.fd);
        try coordinator.requestStop();
        try physical.drainServer(root, coordinator, &loop);
        loop.deinit();
        try coordinator.destroy();
        try root.deinit();
        try std.testing.expectEqual(probe.successful_creates, probe.destroys);
    }
}

test "color startup: explicit Vulkan rejects a missing color pipeline without advertising" {
    var fixture = try physical.Fixture.init();
    defer fixture.deinit();
    var probe: Probe = .{ .failure = .color };
    var drm_vtable = fixture.platforms().drm.vtable.*;
    drm_vtable.read_topology = Probe.topology;
    var platforms = fixture.platforms();
    platforms.drm.vtable = &drm_vtable;
    platforms.output.vulkan = probe.platform();
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_storage, "/tmp/ouro-color-failure-{d}.sock", .{linux.getpid()});
    wayring.unix_socket.unlink(path) catch {};
    defer wayring.unix_socket.unlink(path) catch {};
    const root = try Compositor.create(std.testing.allocator, try wayring.unix_socket.listen(path, 1), physical.compositorConfig());
    var config = physical.coordinatorConfig();
    config.output.renderer = .vulkan;
    config.enable_color_protocols = true;
    const coordinator = try Coordinator.create(std.testing.allocator, root, platforms, config);
    var loop = try Loop.init(std.testing.allocator, root, &coordinator.router, &coordinator.timers, coordinator, .{ .completion_batch = 16 });
    try coordinator.start(&loop);
    var registry = try Registry.connect(path);
    try registry.roundtrip(&loop, coordinator);
    // Deliver the seat callback directly so the expected startup failure is
    // tested at its owner, rather than Loop's fatal-error logging boundary.
    const callback = fixture.callback.?;
    callback.listener.enable(callback.userdata);
    try std.testing.expectError(error.ColorManagementUnavailable, coordinator.completions(&.{}, &.{}));
    try std.testing.expect(probe.required_color);
    try std.testing.expect(coordinator.render_device == null);
    try registry.roundtrip(&loop, coordinator);
    try registry.expectColors(false);
    _ = linux.close(registry.fd);
    try coordinator.requestStop();
    try physical.drainServer(root, coordinator, &loop);
    loop.deinit();
    try coordinator.destroy();
    try root.deinit();
}

fn waitOutput(loop: *Loop, coordinator: *Coordinator, present: bool) !void {
    for (0..256) |_| {
        _ = try loop.turn(coordinator);
        if ((coordinator.physical_outputs[0].kms_output != null) == present and
            (present or coordinator.session.state == .disabled)) return;
        pause();
    }
    return error.OutputTimeout;
}

fn pause() void {
    const delay: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
    _ = linux.nanosleep(&delay, null);
}

// A small wire client observes both the initial registry and later dynamic
// advertisements. Sync replies bound every negative assertion.
const Registry = struct {
    fd: linux.fd_t,
    callback: u32 = 2,
    bytes: [8192]u8 = undefined,
    used: usize = 0,
    globals: usize = 0,
    management: usize = 0,
    representation: usize = 0,
    color_names: [2]u32 = .{ 0, 0 },
    color_removes: usize = 0,

    fn connect(path: []const u8) !Registry {
        const fd = try wayring.unix_socket.connect(path);
        errdefer _ = linux.close(fd);
        const request = [_]u32{ 1, (12 << 16) | 1, 2 }; // get_registry(2)
        try std.testing.expectEqual(@sizeOf(@TypeOf(request)), linux.write(fd, std.mem.asBytes(&request), @sizeOf(@TypeOf(request))));
        return .{ .fd = fd };
    }

    fn roundtrip(self: *Registry, loop: *Loop, coordinator: *Coordinator) !void {
        self.callback += 1;
        const request = [_]u32{ 1, 12 << 16, self.callback };
        try std.testing.expectEqual(@sizeOf(@TypeOf(request)), linux.write(self.fd, std.mem.asBytes(&request), @sizeOf(@TypeOf(request))));
        for (0..256) |_| {
            _ = try loop.turn(coordinator);
            const count = linux.recvfrom(self.fd, self.bytes[self.used..].ptr, self.bytes.len - self.used, linux.MSG.DONTWAIT, null, null);
            switch (linux.errno(count)) {
                .AGAIN => {},
                .SUCCESS => {
                    if (count == 0) return error.RegistryDisconnected;
                    self.used += count;
                },
                else => return error.RegistryReadFailed,
            }
            var consumed: usize = 0;
            var done = false;
            while (self.used - consumed >= 8) {
                const message = self.bytes[consumed..self.used];
                const object = word(message[0..4]);
                const header = word(message[4..8]);
                const size = header >> 16;
                if (message.len < size) break;
                if (object == 2 and header & 0xffff == 0) {
                    self.globals += 1;
                    const name = word(message[8..12]);
                    const length = word(message[12..16]);
                    const interface = message[16 .. 16 + length - 1];
                    if (std.mem.eql(u8, interface, "wp_color_manager_v1")) {
                        self.management += 1;
                        self.color_names[0] = name;
                    } else if (std.mem.eql(u8, interface, "wp_color_representation_manager_v1")) {
                        self.representation += 1;
                        self.color_names[1] = name;
                    }
                } else if (object == 2 and header & 0xffff == 1) {
                    const name = word(message[8..12]);
                    for (self.color_names) |color_name| if (name == color_name) {
                        self.color_removes += 1;
                    };
                } else if (object == self.callback) {
                    done = true;
                } else if (object == 1 and header & 0xffff == 0) return error.ServerProtocolError;
                consumed += size;
            }
            std.mem.copyForwards(u8, &self.bytes, self.bytes[consumed..self.used]);
            self.used -= consumed;
            if (done) return;
            pause();
        }
        return error.RegistryTimeout;
    }

    fn expectColors(self: Registry, enabled: bool) !void {
        try std.testing.expectEqual(@as(usize, @intFromBool(enabled)), self.management);
        try std.testing.expectEqual(@as(usize, @intFromBool(enabled)), self.representation);
        try std.testing.expectEqual(@as(usize, 0), self.color_removes);
    }

    fn word(bytes: *const [4]u8) u32 {
        return std.mem.readInt(u32, bytes, .little);
    }
};

const Probe = struct {
    const Failure = enum { none, color, target };
    failure: Failure = .none,
    creates: usize = 0,
    successful_creates: usize = 0,
    destroys: usize = 0,
    required_color: bool = false,

    fn topology(context: *anyopaque, fd: linux.fd_t, out: *ouro.drm_platform.TopologyBuffer) !void {
        const fixture: *physical.Fixture = @ptrCast(@alignCast(context));
        try fixture.platforms().drm.vtable.read_topology(context, fd, out);
        for (out.planes[0..out.plane_count]) |*plane| plane.properties.in_fence_fd = 17;
    }

    fn platform(self: *Probe) vk.Platform {
        return .{ .context = self, .vtable = &vtable };
    }
    const vtable: vk.Platform.VTable = blk: {
        var table = vk.real.vtable.*;
        table.create = create;
        table.destroy = destroy;
        table.packs_sources = packs;
        table.supports_target = supports;
        table.content_provider = content;
        table.sampled_dmabuf_formats = formats;
        break :blk table;
    };
    fn create(context: *anyopaque, _: linux.fd_t, config: vk.Config) !vk.Renderer {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.creates += 1;
        self.required_color = config.require_color_management;
        if (config.require_color_management and self.failure == .color) return error.ColorManagementUnavailable;
        self.successful_creates += 1;
        return context;
    }
    fn destroy(context: *anyopaque, _: vk.Renderer) void {
        const self: *Probe = @ptrCast(@alignCast(context));
        self.destroys += 1;
    }
    fn packs(_: *anyopaque, _: vk.Renderer) bool {
        return false;
    }
    fn supports(context: *anyopaque, _: vk.Renderer, _: ouro.gbm.Allocation) bool {
        const self: *Probe = @ptrCast(@alignCast(context));
        return self.failure != .target;
    }
    fn content(_: *anyopaque, _: vk.Renderer) ?ouro.render_content.Provider {
        return null;
    }
    fn formats(_: *anyopaque, _: vk.Renderer, _: []ouro.gbm.FormatModifier) !usize {
        return 0;
    }
};
