//! Fixed-capacity GBM scanout pool and DRM framebuffer lifetime owner.
//! The pool must be fully drained and destroyed before its borrowed R9
//! snapshot/FD may be invalidated by rescan, removal, or session disable.

const std = @import("std");
const gbm = @import("../gbm.zig");
const drm = @import("manager.zig");
const drm_api = @import("platform.zig");

const c = @cImport({
    @cInclude("xf86drmMode.h");
});

pub const default_capacity = 3;

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        add: *const fn (*anyopaque, std.posix.fd_t, gbm.Metadata) anyerror!u32,
        remove: *const fn (*anyopaque, std.posix.fd_t, u32) anyerror!void,
    };

    pub fn add(self: Platform, fd: std.posix.fd_t, metadata: gbm.Metadata) !u32 {
        return self.vtable.add(self.context, fd, metadata);
    }

    pub fn remove(self: Platform, fd: std.posix.fd_t, id: u32) !void {
        return self.vtable.remove(self.context, fd, id);
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{ .add = realAdd, .remove = realRemove };

fn realAdd(_: *anyopaque, fd: std.posix.fd_t, metadata: gbm.Metadata) !u32 {
    var framebuffer_id: u32 = 0;
    const result = if (requiresModifierRegistration(metadata)) blk: {
        const modifiers = [_]u64{metadata.modifier} ** gbm.max_planes;
        break :blk c.drmModeAddFB2WithModifiers(
            fd,
            metadata.width,
            metadata.height,
            metadata.format,
            &metadata.handles,
            &metadata.strides,
            &metadata.offsets,
            &modifiers,
            &framebuffer_id,
            c.DRM_MODE_FB_MODIFIERS,
        );
    } else c.drmModeAddFB2(
        fd,
        metadata.width,
        metadata.height,
        metadata.format,
        &metadata.handles,
        &metadata.strides,
        &metadata.offsets,
        &framebuffer_id,
        0,
    );
    if (result != 0 or framebuffer_id == 0) return error.AddFramebufferFailed;
    return framebuffer_id;
}

fn requiresModifierRegistration(metadata: gbm.Metadata) bool {
    return metadata.modifier != gbm.modifier_invalid and
        metadata.modifier != gbm.modifier_linear;
}

fn realRemove(_: *anyopaque, fd: std.posix.fd_t, id: u32) !void {
    if (c.drmModeRmFB(fd, id) != 0) return error.RemoveFramebufferFailed;
}

pub const Config = struct {
    capacity: usize = default_capacity,
    /// CPU startup uses only GBM targets requested and reported as linear.
    /// GPU startup may fall back to another explicit scanout modifier.
    linear_only: bool = false,
};

pub const Handle = struct {
    slot: u32,
    generation: u32,
};

pub const State = enum { free, acquired, submitted, retired };

pub const Image = struct {
    metadata: gbm.Metadata,
    framebuffer_id: u32,
    state: State,
};

pub const Mapping = struct {
    data: []u8,
    stride: u32,
};

const Slot = struct {
    bo: gbm.Bo,
    metadata: gbm.Metadata,
    framebuffer_id: u32,
    generation: u32 = 1,
    state: State = .free,
    mapping: ?gbm.Mapping = null,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    gbm_platform: gbm.Platform,
    drm_platform: Platform,
    fd: std.posix.fd_t,
    device: gbm.Device,
    slots: []Slot,
    allocation: gbm.Allocation,

    pub fn init(
        allocator: std.mem.Allocator,
        gbm_platform: gbm.Platform,
        drm_platform: Platform,
        fd: std.posix.fd_t,
        snapshot: drm.Snapshot,
        config: Config,
    ) !Pool {
        if (config.capacity == 0 or config.capacity > std.math.maxInt(u32))
            return error.InvalidConfig;
        const mode = snapshot.selectedMode();
        if (mode.hdisplay == 0 or mode.vdisplay == 0) return error.InvalidMode;
        const allocation = try negotiate(snapshot, mode.hdisplay, mode.vdisplay, config.linear_only);
        const slots = try allocator.alloc(Slot, config.capacity);
        errdefer allocator.free(slots);
        const device = try gbm_platform.createDevice(fd);
        errdefer gbm_platform.destroyDevice(device);

        var created: usize = 0;
        errdefer cleanupCreated(gbm_platform, drm_platform, fd, slots[0..created]);
        while (created < slots.len) : (created += 1) {
            const bo = try gbm_platform.createBo(device, allocation);
            errdefer gbm_platform.destroyBo(bo);
            var metadata = try gbm_platform.getMetadata(bo);
            // The ordinary GBM allocation API does not retain an explicit
            // modifier and Mesa may report INVALID even when LINEAR usage was
            // required. This path is linear by construction; explicit tiled
            // allocations remain subject to exact modifier validation.
            if (allocation.modifier == gbm.modifier_linear and
                metadata.modifier == gbm.modifier_invalid)
                metadata.modifier = gbm.modifier_linear;
            try validateMetadata(allocation, metadata);
            const framebuffer_id = try drm_platform.add(fd, metadata);
            if (framebuffer_id == 0) return error.InvalidFramebufferId;
            slots[created] = .{
                .bo = bo,
                .metadata = metadata,
                .framebuffer_id = framebuffer_id,
            };
        }
        return .{
            .allocator = allocator,
            .gbm_platform = gbm_platform,
            .drm_platform = drm_platform,
            .fd = fd,
            .device = device,
            .slots = slots,
            .allocation = allocation,
        };
    }

    /// Terminal teardown. In-flight images reject without mutation because KMS
    /// still owns them. Once drain is proven, every FB/BO is retired in reverse
    /// creation order; removal errors are reported after cleanup completes.
    pub fn deinit(self: *Pool) !void {
        for (self.slots) |slot| if (slot.state == .submitted)
            return error.ImagesInFlight;
        var first_error: ?anyerror = null;
        var index = self.slots.len;
        while (index != 0) {
            index -= 1;
            const slot = &self.slots[index];
            if (slot.mapping) |mapping| {
                self.gbm_platform.unmap(slot.bo, mapping.token);
                slot.mapping = null;
            }
            self.drm_platform.remove(self.fd, slot.framebuffer_id) catch |err| {
                if (first_error == null) first_error = err;
            };
            self.gbm_platform.destroyBo(slot.bo);
        }
        self.gbm_platform.destroyDevice(self.device);
        const allocator = self.allocator;
        allocator.free(self.slots);
        self.* = undefined;
        if (first_error) |err| return err;
    }

    pub fn acquire(self: *Pool) !Handle {
        for (self.slots, 0..) |*slot, index| if (slot.state == .free) {
            slot.state = .acquired;
            return .{ .slot = @intCast(index), .generation = slot.generation };
        };
        return error.PoolExhausted;
    }

    pub fn image(self: *Pool, handle: Handle) !Image {
        const slot = try self.get(handle);
        return .{
            .metadata = slot.metadata,
            .framebuffer_id = slot.framebuffer_id,
            .state = slot.state,
        };
    }

    /// Exports a caller-owned DMA-BUF FD for a plane of this acquired image.
    /// The slot's BO and every framebuffer registration remain Pool-owned.
    pub fn exportPlaneFd(self: *Pool, handle: Handle, plane: u8) !std.posix.fd_t {
        const slot = try self.get(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        if (plane >= slot.metadata.plane_count) return error.InvalidPlane;
        return self.gbm_platform.exportPlaneFd(slot.bo, plane);
    }

    pub fn map(self: *Pool, handle: Handle) !Mapping {
        const slot = try self.get(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        if (slot.mapping != null) return error.AlreadyMapped;
        if (slot.metadata.modifier != gbm.modifier_linear)
            return error.NotLinear;
        const mapping = try self.gbm_platform.map(slot.bo, .write);
        const length = std.math.mul(usize, mapping.stride, slot.metadata.height) catch {
            self.gbm_platform.unmap(slot.bo, mapping.token);
            return error.MappingTooLarge;
        };
        slot.mapping = mapping;
        return .{ .data = mapping.data[0..length], .stride = mapping.stride };
    }

    pub fn unmap(self: *Pool, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        const mapping = slot.mapping orelse return error.NotMapped;
        self.gbm_platform.unmap(slot.bo, mapping.token);
        slot.mapping = null;
    }

    /// Preflight used immediately before an external KMS commit. A successful
    /// check guarantees `submit` cannot fail unless the coordinator mutates
    /// this single-thread-owned pool between the two calls.
    pub fn validateSubmit(self: *Pool, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        if (slot.mapping != null) return error.StillMapped;
    }

    pub fn submit(self: *Pool, handle: Handle) !void {
        try self.validateSubmit(handle);
        const slot = try self.get(handle);
        slot.state = .submitted;
    }

    /// Returns an acquired image that never reached KMS. Mapped images must be
    /// explicitly unmapped first so renderer failure paths remain deliberate.
    pub fn discard(self: *Pool, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        if (slot.mapping != null) return error.StillMapped;
        try recycle(slot);
    }

    pub fn release(self: *Pool, handle: Handle) !void {
        const slot = try self.get(handle);
        if (slot.state != .submitted) return error.InvalidTransition;
        try recycle(slot);
    }

    fn get(self: *Pool, handle: Handle) !*Slot {
        if (handle.slot >= self.slots.len) return error.StaleImage;
        const slot = &self.slots[handle.slot];
        if (slot.generation != handle.generation or
            slot.state == .free or slot.state == .retired)
            return error.StaleImage;
        return slot;
    }
};

fn recycle(slot: *Slot) !void {
    if (slot.generation == std.math.maxInt(u32)) {
        // The image is no longer externally owned, but this slot can never
        // safely issue another handle.
        slot.state = .retired;
        return error.GenerationExhausted;
    }
    slot.generation += 1;
    slot.state = .free;
}

fn negotiate(snapshot: drm.Snapshot, width: u32, height: u32, linear_only: bool) !gbm.Allocation {
    const plane = snapshot.selectedPlane();
    const start: usize = plane.format_start;
    const end = start + plane.format_count;
    if (end > snapshot.formats.len) return error.MalformedTopology;
    const formats = snapshot.formats[start..end];
    const preferred = [_]u32{ gbm.format_xrgb8888, gbm.format_argb8888 };

    // Prefer a CPU-capable target across all supported compositor formats
    // before considering a tiled modifier for GPU startup.
    for (preferred) |fourcc| {
        var implicit = false;
        for (formats) |format| if (format.fourcc == fourcc) {
            if (format.modifier == gbm.modifier_linear) return .{
                .width = width,
                .height = height,
                .format = fourcc,
                .modifier = gbm.modifier_linear,
                .explicit_modifier = true,
            };
            if (format.modifier == drm_api.modifier_invalid) implicit = true;
        };
        if (implicit) return .{
            .width = width,
            .height = height,
            .format = fourcc,
            .modifier = gbm.modifier_linear,
            .explicit_modifier = false,
        };
    }
    if (linear_only) return error.NoLinearRenderFormat;

    for (preferred) |fourcc| {
        var modifier: ?u64 = null;
        for (formats) |format| {
            if (format.fourcc == fourcc and
                format.modifier != drm_api.modifier_invalid and
                format.modifier != gbm.modifier_linear and
                (modifier == null or format.modifier < modifier.?))
                modifier = format.modifier;
        }
        if (modifier) |selected| return .{
            .width = width,
            .height = height,
            .format = fourcc,
            .modifier = selected,
            .explicit_modifier = true,
        };
    }
    return error.NoRenderFormat;
}

fn validateMetadata(allocation: gbm.Allocation, metadata: gbm.Metadata) !void {
    if (metadata.width != allocation.width or metadata.height != allocation.height or
        metadata.format != allocation.format or metadata.modifier != allocation.modifier)
        return error.AllocationMismatch;
    if (metadata.plane_count == 0 or metadata.plane_count > gbm.max_planes)
        return error.UnsupportedPlaneCount;
    for (0..@as(usize, metadata.plane_count)) |plane| {
        if (metadata.handles[plane] == 0 or metadata.strides[plane] == 0)
            return error.InvalidPlaneMetadata;
    }
}

fn cleanupCreated(
    gbm_platform: gbm.Platform,
    drm_platform: Platform,
    fd: std.posix.fd_t,
    slots: []Slot,
) void {
    var index = slots.len;
    while (index != 0) {
        index -= 1;
        drm_platform.remove(fd, slots[index].framebuffer_id) catch {};
        gbm_platform.destroyBo(slots[index].bo);
    }
}

test "scanout: negotiation prefers explicit linear then implicit fallback" {
    var fixture = TestSnapshot.init(&.{
        .{ .fourcc = gbm.format_xrgb8888, .modifier = 9 },
        .{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear },
    });
    var allocation = try negotiate(fixture.snapshot(), 100, 50, false);
    try std.testing.expect(allocation.explicit_modifier);
    try std.testing.expectEqual(gbm.modifier_linear, allocation.modifier);
    fixture = TestSnapshot.init(&.{.{
        .fourcc = gbm.format_xrgb8888,
        .modifier = drm_api.modifier_invalid,
    }});
    allocation = try negotiate(fixture.snapshot(), 100, 50, false);
    try std.testing.expect(!allocation.explicit_modifier);
    try std.testing.expectEqual(gbm.modifier_linear, allocation.modifier);
    fixture = TestSnapshot.init(&.{
        .{ .fourcc = gbm.format_xrgb8888, .modifier = 9 },
        .{ .fourcc = gbm.format_argb8888, .modifier = gbm.modifier_linear },
    });
    allocation = try negotiate(fixture.snapshot(), 100, 50, false);
    try std.testing.expectEqual(gbm.format_argb8888, allocation.format);
    try std.testing.expectEqual(gbm.modifier_linear, allocation.modifier);
    fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = 9 }});
    try std.testing.expectError(
        error.NoLinearRenderFormat,
        negotiate(fixture.snapshot(), 100, 50, true),
    );
    allocation = try negotiate(fixture.snapshot(), 100, 50, false);
    try std.testing.expectEqual(@as(u64, 9), allocation.modifier);
    var metadata: gbm.Metadata = .{ .width = 1, .height = 1, .format = gbm.format_xrgb8888, .modifier = gbm.modifier_linear, .plane_count = 1 };
    try std.testing.expect(!requiresModifierRegistration(metadata));
    metadata.modifier = 9;
    try std.testing.expect(requiresModifierRegistration(metadata));
}

test "scanout: multiplane metadata is copied and mismatches roll back" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{ .plane_count = 2 };
    var pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    const handle = try pool.acquire();
    const image = try pool.image(handle);
    try std.testing.expectEqual(@as(u8, 2), image.metadata.plane_count);
    try std.testing.expectEqual(@as(u32, 102), image.metadata.handles[1]);
    try std.testing.expectEqual(@as(usize, 1), fake.device_create_count);
    try pool.submit(handle);
    try pool.release(handle);
    try pool.deinit();

    fake = .{ .metadata_mismatch = true };
    try std.testing.expectError(error.AllocationMismatch, Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 }));
    try std.testing.expectEqual(@as(usize, 1), fake.bo_destroy_count);
    try std.testing.expectEqual(@as(usize, 1), fake.device_destroy_count);
}

test "scanout: ordinary linear allocation normalizes invalid GBM modifier" {
    var fixture = TestSnapshot.init(&.{.{
        .fourcc = gbm.format_xrgb8888,
        .modifier = gbm.modifier_linear,
    }});
    var fake = FakePlatform{ .modifier = gbm.modifier_invalid };
    var pool = try Pool.init(
        std.testing.allocator,
        fake.gbmPlatform(),
        fake.drmPlatform(),
        17,
        fixture.snapshot(),
        .{ .capacity = 1 },
    );
    const handle = try pool.acquire();
    const image = try pool.image(handle);
    try std.testing.expectEqual(gbm.modifier_linear, image.metadata.modifier);
    try std.testing.expect(!requiresModifierRegistration(image.metadata));
    _ = try pool.map(handle);
    try pool.unmap(handle);
    try pool.discard(handle);
    try pool.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.add_count);

    fixture = TestSnapshot.init(&.{.{
        .fourcc = gbm.format_xrgb8888,
        .modifier = 9,
    }});
    fake = .{ .modifier = gbm.modifier_invalid };
    try std.testing.expectError(error.AllocationMismatch, Pool.init(
        std.testing.allocator,
        fake.gbmPlatform(),
        fake.drmPlatform(),
        17,
        fixture.snapshot(),
        .{ .capacity = 1 },
    ));
    try std.testing.expectEqual(@as(usize, 0), fake.add_count);
}

test "scanout: AddFB and partial creation failures clean up in reverse" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{ .fail_add_at = 2 };
    try std.testing.expectError(error.FakeAdd, Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{}));
    try std.testing.expectEqualSlices(u32, &.{1}, fake.removedIds());
    try std.testing.expectEqual(@as(usize, 2), fake.bo_destroy_count);
    try std.testing.expectEqual(@as(usize, 1), fake.device_destroy_count);

    fake = .{ .fail_bo_at = 3 };
    try std.testing.expectError(error.FakeBo, Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{}));
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, fake.removedIds());
}

test "scanout: map lifetime is explicit and only linear acquired images map" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{};
    var pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    const handle = try pool.acquire();
    const mapping = try pool.map(handle);
    try std.testing.expectEqual(@as(usize, 64 * 48), mapping.data.len);
    try std.testing.expectError(error.AlreadyMapped, pool.map(handle));
    try std.testing.expectError(error.StillMapped, pool.submit(handle));
    try std.testing.expectError(error.StillMapped, pool.discard(handle));
    try pool.unmap(handle);
    try std.testing.expectError(error.NotMapped, pool.unmap(handle));
    try pool.submit(handle);
    try pool.release(handle);
    try pool.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.map_count);
    try std.testing.expectEqual(@as(usize, 1), fake.unmap_count);

    fake = .{};
    pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    _ = try pool.map(try pool.acquire());
    try pool.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.unmap_count);

    fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = 9 }});
    fake = .{ .modifier = 9 };
    pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    const nonlinear = try pool.acquire();
    try std.testing.expectError(error.NotLinear, pool.map(nonlinear));
    try pool.deinit();
}

test "scanout: transitions exhaustion and stale generations are rejected" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{};
    var pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    const first = try pool.acquire();
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    try std.testing.expectError(error.InvalidTransition, pool.release(first));
    try pool.submit(first);
    try std.testing.expectError(error.InvalidTransition, pool.submit(first));
    try pool.release(first);
    try std.testing.expectError(error.StaleImage, pool.image(first));
    const second = try pool.acquire();
    try std.testing.expect(first.generation != second.generation);
    try pool.discard(second);
    try std.testing.expectError(error.StaleImage, pool.image(second));
    const third = try pool.acquire();
    try std.testing.expect(second.generation != third.generation);
    try pool.submit(third);
    try pool.release(third);
    try std.testing.expectError(error.StaleImage, pool.release(third));
    try pool.deinit();
}

test "scanout: generation wrap retires without aliasing or blocking teardown" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{};
    var pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 1 });
    pool.slots[0].generation = std.math.maxInt(u32);
    const handle = try pool.acquire();
    try pool.submit(handle);
    try std.testing.expectError(error.GenerationExhausted, pool.release(handle));
    try std.testing.expectError(error.StaleImage, pool.image(handle));
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    try pool.deinit();
}

test "scanout: teardown rejects in flight and reports removal after full cleanup" {
    var fixture = TestSnapshot.init(&.{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }});
    var fake = FakePlatform{ .fail_remove = true };
    var pool = try Pool.init(std.testing.allocator, fake.gbmPlatform(), fake.drmPlatform(), 17, fixture.snapshot(), .{ .capacity = 2 });
    const handle = try pool.acquire();
    _ = try pool.map(handle);
    try pool.unmap(handle);
    try pool.submit(handle);
    try std.testing.expectError(error.ImagesInFlight, pool.deinit());
    try std.testing.expectEqual(@as(usize, 0), fake.bo_destroy_count);
    try pool.release(handle);
    try std.testing.expectError(error.FakeRemove, pool.deinit());
    try std.testing.expectEqual(@as(usize, 2), fake.bo_destroy_count);
    try std.testing.expectEqual(@as(usize, 1), fake.device_destroy_count);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, fake.removedIds());
}

const TestSnapshot = struct {
    mode: [1]drm.Mode,
    plane: [1]drm.Plane,
    formats: [4]drm.Format = undefined,
    format_count: usize,

    fn init(formats: []const drm.Format) TestSnapshot {
        var self: TestSnapshot = .{
            .mode = .{.{ .clock = 1, .hdisplay = 64, .hsync_start = 64, .hsync_end = 64, .htotal = 64, .hskew = 0, .vdisplay = 48, .vsync_start = 48, .vsync_end = 48, .vtotal = 48, .vscan = 0, .vrefresh = 60, .flags = 0, .mode_type = 0 }},
            .plane = .{.{ .id = 1, .possible_crtcs = 1, .plane_type_value = 1, .format_start = 0, .format_count = @intCast(formats.len), .properties = .{ .plane_type = 1, .fb_id = 2, .crtc_id = 3, .src_x = 4, .src_y = 5, .src_w = 6, .src_h = 7, .crtc_x = 8, .crtc_y = 9, .crtc_w = 10, .crtc_h = 11 } }},
            .format_count = formats.len,
        };
        @memcpy(self.formats[0..formats.len], formats);
        return self;
    }

    fn snapshot(self: *const TestSnapshot) drm.Snapshot {
        return .{
            .handle = .{ .generation = 1 },
            .card = .{},
            .connectors = &.{},
            .modes = &self.mode,
            .connector_encoders = &.{},
            .encoders = &.{},
            .crtcs = &.{},
            .planes = &self.plane,
            .formats = self.formats[0..self.format_count],
            .selection = .{ .connector_index = 0, .mode_index = 0, .crtc_index = 0, .plane_index = 0 },
        };
    }
};

const FakePlatform = struct {
    device_create_count: usize = 0,
    device_destroy_count: usize = 0,
    bo_create_count: usize = 0,
    bo_destroy_count: usize = 0,
    add_count: usize = 0,
    removed: [8]u32 = undefined,
    remove_count: usize = 0,
    map_count: usize = 0,
    unmap_count: usize = 0,
    fail_bo_at: usize = 0,
    fail_add_at: usize = 0,
    fail_remove: bool = false,
    metadata_mismatch: bool = false,
    plane_count: u8 = 1,
    modifier: u64 = gbm.modifier_linear,
    bytes: [64 * 48]u8 = [_]u8{0} ** (64 * 48),

    const gbm_vtable: gbm.Platform.VTable = .{ .create_device = createDevice, .destroy_device = destroyDevice, .create_bo = createBo, .import_bo = importBo, .destroy_bo = destroyBo, .metadata = metadata, .export_plane_fd = exportPlaneFd, .map = map, .unmap = unmap };
    const drm_vtable: Platform.VTable = .{ .add = add, .remove = remove };

    fn gbmPlatform(self: *FakePlatform) gbm.Platform {
        return .{ .context = self, .vtable = &gbm_vtable };
    }

    fn drmPlatform(self: *FakePlatform) Platform {
        return .{ .context = self, .vtable = &drm_vtable };
    }

    fn removedIds(self: *const FakePlatform) []const u32 {
        return self.removed[0..self.remove_count];
    }

    fn createDevice(context: *anyopaque, fd: std.posix.fd_t) !gbm.Device {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(std.posix.fd_t, 17), fd);
        self.device_create_count += 1;
        return @ptrFromInt(16);
    }

    fn destroyDevice(context: *anyopaque, _: gbm.Device) void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.device_destroy_count += 1;
    }

    fn createBo(context: *anyopaque, _: gbm.Device, _: gbm.Allocation) !gbm.Bo {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.bo_create_count += 1;
        if (self.fail_bo_at == self.bo_create_count) return error.FakeBo;
        return @ptrFromInt(32 + self.bo_create_count * 16);
    }

    fn importBo(context: *anyopaque, device: gbm.Device, import: gbm.Import) !gbm.Bo {
        return createBo(context, device, .{
            .width = import.width,
            .height = import.height,
            .format = import.format,
            .modifier = import.modifier,
            .explicit_modifier = true,
        });
    }

    fn destroyBo(context: *anyopaque, _: gbm.Bo) void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.bo_destroy_count += 1;
    }

    fn metadata(context: *anyopaque, bo: gbm.Bo) !gbm.Metadata {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        const ordinal: u32 = @intCast((@intFromPtr(bo) - 32) / 16);
        var result: gbm.Metadata = .{
            .width = if (self.metadata_mismatch) 63 else 64,
            .height = 48,
            .format = gbm.format_xrgb8888,
            .modifier = self.modifier,
            .plane_count = self.plane_count,
        };
        for (0..self.plane_count) |plane| {
            result.handles[plane] = ordinal * 100 + @as(u32, @intCast(plane)) + 1;
            result.strides[plane] = 64;
            result.offsets[plane] = @intCast(plane * 128);
        }
        return result;
    }

    fn exportPlaneFd(_: *anyopaque, _: gbm.Bo, plane: u8) !std.posix.fd_t {
        if (plane != 0) return error.InvalidPlane;
        return error.NotAvailableInFake;
    }

    fn map(context: *anyopaque, _: gbm.Bo, _: gbm.MapAccess) !gbm.Mapping {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.map_count += 1;
        return .{ .data = &self.bytes, .stride = 64, .token = @ptrFromInt(48) };
    }

    fn unmap(context: *anyopaque, _: gbm.Bo, _: gbm.MapToken) void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.unmap_count += 1;
    }

    fn add(context: *anyopaque, _: std.posix.fd_t, _: gbm.Metadata) !u32 {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.add_count += 1;
        if (self.fail_add_at == self.add_count) return error.FakeAdd;
        return @intCast(self.add_count);
    }

    fn remove(context: *anyopaque, _: std.posix.fd_t, id: u32) !void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.removed[self.remove_count] = id;
        self.remove_count += 1;
        if (self.fail_remove) return error.FakeRemove;
    }
};
