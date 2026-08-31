//! R14 single-output orchestration owner. This is the only boundary which composes
//! the reviewed CU/render identities, R13 planner, R10 pool, renderer, and R11
//! KMS owner. It queues no io_uring submission; the runtime remains the sole
//! submitter and routes timer/DRM completions back into this owner.

const std = @import("std");
const linux = std.os.linux;
const completion = @import("../runtime/completion.zig");
const timer = @import("../runtime/timer.zig");
const gbm = @import("../backend/gbm.zig");
const drm = @import("../backend/drm/manager.zig");
const framebuffer = @import("../backend/drm/framebuffer.zig");
const atomic = @import("../backend/drm/atomic.zig");
const kms = @import("../backend/drm/output.zig");
const render = @import("../render/types.zig");
const render_content = @import("../render/content.zig");
const cpu = @import("../render/cpu.zig");
const vulkan = @import("../render/vulkan.zig");
const vulkan_platform = @import("../render/vulkan_platform.zig");
const render_list = @import("../scene/render_list.zig");
const damage = @import("../scene/damage.zig");
const scheduler_api = @import("headless.zig");
const c = @cImport({
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/sync_file.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
});

pub const RendererPreference = enum { pixman, vulkan, vulkan_then_pixman };
pub const RendererKind = enum { pixman, vulkan };

pub const Config = struct {
    output_id: scheduler_api.OutputId,
    scheduler: scheduler_api.Config,
    renderer: RendererPreference = .vulkan_then_pixman,
    image_count: usize = framebuffer.default_capacity,
    /// Total imported output images across every output sharing one renderer.
    max_render_targets: usize = framebuffer.default_capacity * 4,
    max_samples: usize,
    max_color_luts: usize = 16,
    enable_color_management: bool = false,
    output_color_description: render.color.Description = .srgb,
    /// Aggregate packed source bytes available to one fallback render frame.
    max_source_bytes: usize,
    /// Maximum bytes retained for one surface version. Defaults to the frame
    /// capacity for compatibility with single-surface configurations.
    max_surface_bytes: ?usize = null,
    max_source_width: u32,
    max_source_height: u32,
    max_client_damage: usize = 32,
    max_scene_damage: usize = 32,
    max_repair_damage: usize = 32,
    max_render_damage: usize = 32,
    clear: render.Color = .{ .r = 0, .g = 0, .b = 0 },
    output_transform: render.Transform = .normal,
    kms: kms.Config = .{},
};

pub const Platforms = struct {
    gbm: gbm.Platform = gbm.real,
    framebuffer: framebuffer.Platform = framebuffer.real,
    atomic: atomic.Platform = atomic.real,
    vulkan: vulkan_platform.Platform = vulkan_platform.real,
};

pub const SampleBinding = struct {
    surface: scheduler_api.SurfaceId,
    sample: render.SampleIdentity,
    presentation: render.PresentationIdentity,
};

/// Copies the exact generational identity from `presentation.Queue.Token`;
/// the queue pointer remains owned by the protocol/presentation boundary.
pub fn presentationIdentity(token: anytype) render.PresentationIdentity {
    return .{ .slot = token.index, .generation = token.generation };
}

/// Converts an applied CU's generational surface key and committed sequence to
/// the exact renderer identity. Callers retain no protocol-resource pointer.
pub fn appliedSampleBinding(
    surface: scheduler_api.SurfaceId,
    commit_sequence: u64,
    presentation: render.PresentationIdentity,
) !SampleBinding {
    if (surface.generation == 0 or commit_sequence == 0 or presentation.generation == 0)
        return error.InvalidIdentity;
    return .{
        .surface = surface,
        .sample = .{
            .surface = (@as(u64, surface.generation) << 32) | surface.index,
            .commit_sequence = commit_sequence,
        },
        .presentation = presentation,
    };
}

const Scheduler = scheduler_api.Scheduler(render.PresentationIdentity);
pub const FrameOutcome = scheduler_api.FrameOutcome(render.PresentationIdentity);

/// Renderer-owned capture bytes borrowed only for the synchronous
/// `WaylandCallbacks.captured` call. The protocol/runtime owner must copy them
/// into client storage before returning.
pub const CaptureReadback = struct {
    bytes: []const u8,
    stride: u32,
};

/// The protocol/runtime implementation must transactionally activate and queue
/// frame callbacks, then queue each sampled presentation's release callbacks
/// and finish its lease. Returning an error retains the completed outcome for
/// retry and blocks another render from overwriting scheduler sample storage.
pub const WaylandCallbacks = struct {
    context: *anyopaque,
    presented_fn: *const fn (*anyopaque, FrameOutcome, u32) anyerror!void,
    retired_fn: *const fn (*anyopaque, FrameOutcome) anyerror!void,
    captured_fn: ?*const fn (*anyopaque, u64, bool, u64, ?CaptureReadback) anyerror!void = null,

    pub fn presented(self: WaylandCallbacks, outcome: FrameOutcome, callback_data: u32) !void {
        return self.presented_fn(self.context, outcome, callback_data);
    }

    pub fn retired(self: WaylandCallbacks, outcome: FrameOutcome) !void {
        return self.retired_fn(self.context, outcome);
    }

    pub fn captured(
        self: WaylandCallbacks,
        token: u64,
        success: bool,
        timestamp_ns: u64,
        readback: ?CaptureReadback,
    ) !void {
        if (self.captured_fn) |function|
            try function(self.context, token, success, timestamp_ns, readback);
    }
};

const Renderer = union(RendererKind) {
    pixman: cpu.Renderer,
    vulkan: vulkan.Renderer,

    fn deinit(self: *Renderer) void {
        switch (self.*) {
            .pixman => |*value| value.deinit(),
            .vulkan => |*value| value.deinit(),
        }
    }
};

fn surfaceByteCapacity(config: Config) usize {
    return config.max_surface_bytes orelse config.max_source_bytes;
}

fn validateConfig(config: Config) !void {
    const surface_bytes = surfaceByteCapacity(config);
    if (config.image_count == 0 or config.max_render_targets < config.image_count or
        config.max_samples == 0 or config.max_source_bytes == 0 or surface_bytes == 0 or
        surface_bytes > config.max_source_bytes)
        return error.InvalidConfig;
}

test "drm-output: retained surface capacity fits aggregate frame capacity" {
    const base: Config = .{
        .output_id = .{ .index = 0, .generation = 1 },
        .scheduler = .{ .refresh_ns = 10, .render_budget_ns = 3 },
        .renderer = .pixman,
        .image_count = 2,
        .max_samples = 2,
        .max_source_bytes = 8,
        .max_source_width = 1,
        .max_source_height = 1,
    };
    try validateConfig(base);
    var invalid = base;
    invalid.max_surface_bytes = 9;
    try std.testing.expectError(error.InvalidConfig, validateConfig(invalid));
}

pub const RenderDevice = struct {
    allocator: std.mem.Allocator,
    card: drm.Card,
    content: render_content.Store,
    renderer: ?Renderer,

    pub fn rendererKind(self: *const RenderDevice) ?RendererKind {
        return if (self.renderer) |value| std.meta.activeTag(value) else null;
    }

    pub fn captureDmabufDevice(self: *RenderDevice, size: render.Size) ?u64 {
        const renderer = &(self.renderer orelse return null);
        switch (renderer.*) {
            .vulkan => |*value| if (!value.supportsCaptureTarget(size)) return null,
            .pixman => return null,
        }
        var status: c.struct_stat = undefined;
        if (c.stat(self.card.devicePath().ptr, &status) != 0) return null;
        return @intCast(status.st_rdev);
    }

    pub fn matches(self: *const RenderDevice, card: *const drm.Card) bool {
        return std.mem.eql(u8, self.card.stablePath(), card.stablePath());
    }

    /// Requires every output target set to have been destroyed first.
    pub fn destroy(self: *RenderDevice) void {
        self.content.deinit();
        if (self.renderer) |*renderer| renderer.deinit();
        self.renderer = null;
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};

pub const ImportedSource = struct {
    access: union(enum) {
        direct: std.posix.fd_t,
        gbm: struct {
            platform: gbm.Platform,
            bo: gbm.Bo,
            mapping: gbm.Mapping,
            destroy_bo: bool,
        },
    },
    bytes: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    format: render.PixelFormat,

    pub fn deinit(source: *ImportedSource) void {
        switch (source.access) {
            .direct => |fd| endDirectRead(fd) catch unreachable,
            .gbm => |access| {
                access.platform.unmap(access.bo, access.mapping.token);
                if (access.destroy_bo) access.platform.destroyBo(access.bo);
            },
        }
        source.* = undefined;
    }
};

const ImportIdentity = struct {
    context: *anyopaque,
    token: u64,
};

const DirectIdentity = struct {
    context: *anyopaque,
    token: u64,
    alive_fn: *const fn (*anyopaque, u64) bool,

    fn alive(identity: DirectIdentity) bool {
        return identity.alive_fn(identity.context, identity.token);
    }
};

const CachedImport = struct {
    occupied: bool = false,
    identity: ImportIdentity = undefined,
    descriptor: gbm.Import = undefined,
    backing: union(enum) {
        direct: []align(std.heap.page_size_min) u8,
        gbm: gbm.Bo,
    } = undefined,
};

// The high slot bit is outside every valid compositor-pool index. KMS can
// therefore keep its existing allocation-free framebuffer handle while this
// adapter routes pool images and cached client images through distinct owners.
// The cache has one entry per live client buffer rather than an arbitrary
// global limit; KMS itself still owns at most current plus next.
const direct_slot_bit: u32 = 1 << 31;

const DirectImage = struct {
    occupied: bool = false,
    state: framebuffer.State = .free,
    generation: u32 = 1,
    identity: DirectIdentity = undefined,
    tested: bool = false,
    bo: gbm.Bo = undefined,
    metadata: gbm.Metadata = undefined,
    framebuffer_id: u32 = 0,
};

const ScanoutImages = struct {
    allocator: std.mem.Allocator,
    pool: *framebuffer.Pool,
    gbm_platform: gbm.Platform,
    framebuffer_platform: framebuffer.Platform,
    direct: std.ArrayListUnmanaged(DirectImage) = .empty,

    fn adapter(images: *ScanoutImages) kms.Images {
        return .{
            .context = images,
            .get_image = getImage,
            .validate_submit = validateSubmit,
            .submit_image = submit,
            .discard_image = discard,
            .release_image = release,
        };
    }

    fn acquireDirect(images: *ScanoutImages, source: render.Source) !framebuffer.Handle {
        const external = source.external orelse return error.InvalidDirectScanoutSource;
        const identity: DirectIdentity = .{
            .context = external.context,
            .token = external.token,
            .alive_fn = external.alive_fn,
        };
        for (images.direct.items) |*slot|
            if (slot.occupied and slot.state == .free and !slot.identity.alive())
                try images.destroyDirect(slot);
        for (images.direct.items, 0..) |*slot, index| {
            if (!slot.occupied or slot.state != .free or
                !std.meta.eql(slot.identity, identity)) continue;
            try validateDirectMetadata(externalImport(source.size, external), slot.metadata);
            slot.state = .acquired;
            return directHandle(index, slot.generation);
        }
        const index: usize = for (images.direct.items, 0..) |slot, candidate| {
            if (!slot.occupied and slot.state == .free) break candidate;
        } else append: {
            if (images.direct.items.len >= direct_slot_bit) return error.DirectScanoutImagesExhausted;
            try images.direct.append(images.allocator, .{});
            break :append images.direct.items.len - 1;
        };
        const import = externalImport(source.size, external);
        const bo = try images.gbm_platform.importBo(images.pool.device, import, .scanout);
        errdefer images.gbm_platform.destroyBo(bo);
        var metadata = try images.gbm_platform.getMetadata(bo);
        if (import.modifier == gbm.modifier_linear and metadata.modifier == gbm.modifier_invalid)
            metadata.modifier = gbm.modifier_linear;
        try validateDirectMetadata(import, metadata);
        const framebuffer_id = try images.framebuffer_platform.add(images.pool.fd, metadata);
        errdefer images.framebuffer_platform.remove(images.pool.fd, framebuffer_id) catch {};
        const slot = &images.direct.items[index];
        slot.occupied = true;
        slot.state = .acquired;
        slot.identity = identity;
        slot.tested = false;
        slot.bo = bo;
        slot.metadata = metadata;
        slot.framebuffer_id = framebuffer_id;
        return directHandle(index, slot.generation);
    }

    fn discardAcquired(images: *ScanoutImages, handle: framebuffer.Handle) void {
        discard(images, handle) catch {};
    }

    fn deinit(images: *ScanoutImages) !void {
        for (images.direct.items) |*slot| {
            if (slot.state == .submitted) return error.ImagesInFlight;
            if (slot.occupied) try images.destroyDirect(slot);
        }
        images.direct.deinit(images.allocator);
        images.direct = .empty;
    }

    fn needsTest(images: *ScanoutImages, handle: framebuffer.Handle) !bool {
        return !(try images.directSlot(handle)).tested;
    }

    fn markTested(images: *ScanoutImages, handle: framebuffer.Handle) void {
        (images.directSlot(handle) catch unreachable).tested = true;
    }

    fn directSlot(images: *ScanoutImages, handle: framebuffer.Handle) !*DirectImage {
        if (handle.slot & direct_slot_bit == 0) return error.NotDirectImage;
        const index = handle.slot & ~direct_slot_bit;
        if (index >= images.direct.items.len) return error.StaleImage;
        const slot = &images.direct.items[index];
        if (!slot.occupied or slot.state == .free or slot.state == .retired or
            slot.generation != handle.generation) return error.StaleImage;
        return slot;
    }

    fn getImage(context: *anyopaque, handle: framebuffer.Handle) !framebuffer.Image {
        const images: *ScanoutImages = @ptrCast(@alignCast(context));
        if (handle.slot & direct_slot_bit == 0) return images.pool.image(handle);
        const slot = try images.directSlot(handle);
        return .{
            .metadata = slot.metadata,
            .framebuffer_id = slot.framebuffer_id,
            .state = slot.state,
        };
    }

    fn validateSubmit(context: *anyopaque, handle: framebuffer.Handle) !void {
        const images: *ScanoutImages = @ptrCast(@alignCast(context));
        if (handle.slot & direct_slot_bit == 0) return images.pool.validateSubmit(handle);
        const slot = try images.directSlot(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
    }

    fn submit(context: *anyopaque, handle: framebuffer.Handle) !void {
        const images: *ScanoutImages = @ptrCast(@alignCast(context));
        if (handle.slot & direct_slot_bit == 0) return images.pool.submit(handle);
        const slot = try images.directSlot(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        slot.state = .submitted;
    }

    fn discard(context: *anyopaque, handle: framebuffer.Handle) !void {
        const images: *ScanoutImages = @ptrCast(@alignCast(context));
        if (handle.slot & direct_slot_bit == 0) return images.pool.discard(handle);
        const slot = try images.directSlot(handle);
        if (slot.state != .acquired) return error.InvalidTransition;
        try images.destroyDirect(slot);
    }

    fn release(context: *anyopaque, handle: framebuffer.Handle) !void {
        const images: *ScanoutImages = @ptrCast(@alignCast(context));
        if (handle.slot & direct_slot_bit == 0) return images.pool.release(handle);
        const slot = try images.directSlot(handle);
        if (slot.state != .submitted) return error.InvalidTransition;
        if (slot.generation == std.math.maxInt(u32)) {
            try images.destroyDirect(slot);
        } else {
            slot.state = .free;
            slot.generation += 1;
        }
    }

    fn destroyDirect(images: *ScanoutImages, slot: *DirectImage) !void {
        std.debug.assert(slot.occupied and slot.state != .submitted);
        var first_error: ?anyerror = null;
        images.framebuffer_platform.remove(images.pool.fd, slot.framebuffer_id) catch |err| {
            first_error = err;
        };
        images.gbm_platform.destroyBo(slot.bo);
        const generation = slot.generation;
        if (generation == std.math.maxInt(u32)) {
            slot.* = .{ .state = .retired, .generation = generation };
        } else {
            slot.* = .{ .generation = generation + 1 };
        }
        if (first_error) |err| return err;
    }
};

fn directHandle(index: usize, generation: u32) framebuffer.Handle {
    return .{
        .slot = direct_slot_bit | @as(u32, @intCast(index)),
        .generation = generation,
    };
}

fn externalImport(size: render.Size, external: render.ExternalSource) gbm.Import {
    return .{
        .width = size.width,
        .height = size.height,
        .format = external.drm_format,
        .modifier = external.modifier,
        .plane_count = external.plane_count,
        .fds = external.fds,
        .strides = external.strides,
        .offsets = external.offsets,
    };
}

fn validateDirectMetadata(import: gbm.Import, metadata: gbm.Metadata) !void {
    if (metadata.width != import.width or metadata.height != import.height or
        metadata.format != import.format or metadata.modifier != import.modifier or
        metadata.plane_count != import.plane_count)
        return error.ImportMetadataMismatch;
    for (0..import.plane_count) |plane| if (metadata.handles[plane] == 0 or
        metadata.strides[plane] != import.strides[plane] or
        metadata.offsets[plane] != import.offsets[plane])
        return error.ImportMetadataMismatch;
}

fn validationSourceAlive(_: *anyopaque, _: u64) bool {
    return false;
}

/// Imports and read-maps one client DMA-BUF long enough for the renderer
/// content store to take its immutable bounded copy. GBM owns any required
/// driver staging and implicit synchronization for the mapping lifetime.
pub fn mapImportedSource(
    platform: gbm.Platform,
    device: gbm.Device,
    import: gbm.Import,
) !ImportedSource {
    const bo = try importClientBo(platform, device, import);
    errdefer platform.destroyBo(bo);
    return mapImportedBo(platform, bo, import, true);
}

fn importClientBo(platform: gbm.Platform, device: gbm.Device, import: gbm.Import) !gbm.Bo {
    if (import.plane_count != 1) return error.UnsupportedPlaneCount;
    _ = formatFromDrm(import.format) orelse return error.UnsupportedFormat;
    const bo = try platform.importBo(device, import, .rendering);
    errdefer platform.destroyBo(bo);
    const metadata = try platform.getMetadata(bo);
    if (metadata.width != import.width or metadata.height != import.height or
        metadata.format != import.format or metadata.plane_count != import.plane_count)
        return error.ImportMetadataMismatch;
    if (import.modifier != gbm.modifier_invalid and
        metadata.modifier != import.modifier and
        !(import.modifier == gbm.modifier_linear and metadata.modifier == gbm.modifier_invalid))
        return error.ImportMetadataMismatch;
    return bo;
}

fn mapImportedBo(
    platform: gbm.Platform,
    bo: gbm.Bo,
    import: gbm.Import,
    destroy_bo: bool,
) !ImportedSource {
    const format = formatFromDrm(import.format) orelse return error.UnsupportedFormat;
    const mapping = try platform.map(bo, .read);
    errdefer platform.unmap(bo, mapping.token);
    const row_bytes = std.math.mul(u32, import.width, 4) catch return error.InvalidSource;
    if (mapping.stride < row_bytes) return error.InvalidSource;
    const length = std.math.mul(usize, mapping.stride, import.height) catch
        return error.InvalidSource;
    return .{
        .access = .{ .gbm = .{
            .platform = platform,
            .bo = bo,
            .mapping = mapping,
            .destroy_bo = destroy_bo,
        } },
        .bytes = mapping.data[0..length],
        .width = import.width,
        .height = import.height,
        .stride = mapping.stride,
        .format = format,
    };
}

fn directMap(import: gbm.Import) ![]align(std.heap.page_size_min) u8 {
    if (import.plane_count != 1 or import.modifier != gbm.modifier_linear)
        return error.UnsupportedDirectMap;
    _ = formatFromDrm(import.format) orelse return error.UnsupportedFormat;
    const row_bytes = std.math.mul(u32, import.width, 4) catch return error.InvalidSource;
    if (import.width == 0 or import.height == 0 or import.strides[0] < row_bytes)
        return error.InvalidSource;
    const length = std.math.mul(usize, import.strides[0], import.height) catch
        return error.InvalidSource;
    const end = std.math.add(
        usize,
        import.offsets[0],
        length,
    ) catch return error.InvalidSource;
    var stat: c.struct_stat = undefined;
    if (c.fstat(import.fds[0], &stat) != 0 or stat.st_size < 0 or
        end > @as(usize, @intCast(stat.st_size)))
        return error.InvalidSource;
    return std.posix.mmap(
        null,
        end,
        .{ .READ = true },
        .{ .TYPE = .SHARED },
        import.fds[0],
        0,
    );
}

fn mapDirect(mapping: []align(std.heap.page_size_min) u8, import: gbm.Import) !ImportedSource {
    const length = std.math.mul(usize, import.strides[0], import.height) catch
        return error.InvalidSource;
    const end = std.math.add(usize, import.offsets[0], length) catch
        return error.InvalidSource;
    if (end > mapping.len) return error.InvalidSource;
    const format = formatFromDrm(import.format) orelse return error.UnsupportedFormat;
    try beginDirectRead(import.fds[0]);
    return .{
        .access = .{ .direct = import.fds[0] },
        .bytes = mapping[import.offsets[0]..end],
        .width = import.width,
        .height = import.height,
        .stride = import.strides[0],
        .format = format,
    };
}

fn beginDirectRead(fd: std.posix.fd_t) !void {
    var descriptors = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = linux.POLL.IN,
        .revents = 0,
    }};
    if (try std.posix.poll(&descriptors, -1) != 1 or
        descriptors[0].revents & (linux.POLL.ERR | linux.POLL.NVAL) != 0)
        return error.DmaBufWaitFailed;
    var sync: c.struct_dma_buf_sync = .{ .flags = c.DMA_BUF_SYNC_START | c.DMA_BUF_SYNC_READ };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_SYNC, &sync) != 0) return error.DmaBufSyncFailed;
}

fn endDirectRead(fd: std.posix.fd_t) !void {
    var sync: c.struct_dma_buf_sync = .{ .flags = c.DMA_BUF_SYNC_END | c.DMA_BUF_SYNC_READ };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_SYNC, &sync) != 0) return error.DmaBufSyncFailed;
}

const OutputPath = struct {
    pool: framebuffer.Pool,
    vulkan_targets: ?vulkan.Targets = null,
};

const InitialRenderPath = struct {
    output: OutputPath,
    renderer: Renderer,
};

pub const RenderFailure = struct {
    cause: anyerror,
    frame: FrameOutcome,
};

pub const RenderResult = union(enum) {
    submitted,
    retired: RenderFailure,
};

pub const CaptureDmabuf = struct {
    import: gbm.Import,
    source: render.Rect,
    lease: CaptureLease,
};

pub const CaptureRequest = struct {
    token: u64,
    cursor_start: usize,
    overlay_cursor: bool,
    destination: union(enum) {
        shm: struct { bytes: []u8, stride: u32 },
        dmabuf: CaptureDmabuf,
    },
};

pub const CaptureLease = struct {
    context: *anyopaque,
    token: u64,
    alive_fn: *const fn (*anyopaque, u64) bool,
    duplicate_fn: *const fn (*anyopaque, u64) anyerror!void,
    release_fn: *const fn (*anyopaque, u64) void,

    fn alive(self: CaptureLease) bool {
        return self.alive_fn(self.context, self.token);
    }

    fn duplicate(self: CaptureLease) !void {
        return self.duplicate_fn(self.context, self.token);
    }

    fn release(self: CaptureLease) void {
        self.release_fn(self.context, self.token);
    }
};

const CachedCaptureTarget = struct {
    lease: CaptureLease,
    descriptor: gbm.Import,
    target: vulkan_platform.CaptureTarget,
};

fn validateCapture(request: CaptureRequest, output: render.Size, sample_count: usize) !void {
    if (request.cursor_start > sample_count) return error.InvalidCursorPartition;
    switch (request.destination) {
        .shm => |destination| {
            const row_bytes = std.math.mul(u32, output.width, 4) catch
                return error.CaptureCapacityExceeded;
            const byte_count = std.math.mul(usize, destination.stride, output.height) catch
                return error.CaptureCapacityExceeded;
            if (destination.stride < row_bytes or destination.bytes.len < byte_count)
                return error.CaptureCapacityExceeded;
        },
        .dmabuf => |destination| if (destination.import.width != destination.source.width or
            destination.import.height != destination.source.height or
            destination.import.plane_count != 1)
            return error.CaptureCapacityExceeded,
    }
}

pub const RetireAction = union(enum) { cancel: timer.Handle, retired: FrameOutcome };

pub const SessionAction = enum { none, create_output, quiesce_output };

/// Converts Session events into composition-root actions. A disabling event
/// starts output quiescence; the root acknowledges Session disable only after
/// `drainComplete`, `destroy`, and DRM-manager device release. A later enabled
/// generation creates a fresh output and scheduler generation.
pub fn sessionAction(event: @import("../backend/session.zig").Event) SessionAction {
    return switch (event) {
        .enabled => .create_output,
        .disabling => .quiesce_output,
        else => .none,
    };
}

/// Heap-stable because R11 retains pointers into `kms_output` commit records
/// and its image adapter points at the embedded pool.
pub const Output = struct {
    allocator: std.mem.Allocator,
    pool: framebuffer.Pool,
    scanout_images: ScanoutImages,
    render_device: *RenderDevice,
    owns_render_device: bool,
    vulkan_targets: ?vulkan.Targets,
    builder: render_list.Builder,
    planner: damage.Planner,
    scheduler: Scheduler,
    sample_storage: []scheduler_api.Sample(render.PresentationIdentity),
    import_cache: []CachedImport,
    import_cache_cursor: usize,
    kms_output: *kms.Output,
    output_format: render.PixelFormat,
    output_color_description: render.color.Description,
    clear: render.Color,
    accepting_frames: bool = true,
    in_flight_frame: ?scheduler_api.FrameId = null,
    in_flight_handle: ?framebuffer.Handle = null,
    in_flight_render_fence: ?std.posix.fd_t = null,
    in_flight_ready_ns: ?u64 = null,
    pending_callback: ?FrameOutcome = null,
    pending_capture: ?CaptureRequest = null,
    pending_capture_target: ?vulkan_platform.CaptureTarget = null,
    capture_targets: std.ArrayListUnmanaged(CachedCaptureTarget) = .empty,
    event_cursor: usize = 0,
    paused: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        platforms: Platforms,
        device: kms.Device,
        snapshot: drm.Snapshot,
        config: Config,
    ) !*Output {
        try validateConfig(config);
        const fd = try device.fd(snapshot.handle);
        var path = try initRenderPath(allocator, platforms, fd, snapshot, config);
        var path_owned = true;
        errdefer if (path_owned) {
            if (path.output.vulkan_targets) |*targets| switch (path.renderer) {
                .vulkan => |*renderer| renderer.destroyTargets(targets),
                .pixman => unreachable,
            };
            path.renderer.deinit();
            path.output.pool.deinit() catch {};
        };
        const render_device = try allocator.create(RenderDevice);
        var render_device_owned = true;
        errdefer if (render_device_owned) allocator.destroy(render_device);
        const content_version_capacity = std.math.add(
            usize,
            config.max_samples,
            1,
        ) catch return error.InvalidConfig;
        const content_provider = switch (path.renderer) {
            .pixman => null,
            .vulkan => |*renderer| renderer.contentProvider(),
        };
        var content = try render_content.Store.initWithProvider(allocator, .{
            .version_capacity = content_version_capacity,
            .byte_capacity = std.math.mul(
                usize,
                surfaceByteCapacity(config),
                content_version_capacity,
            ) catch return error.InvalidConfig,
        }, content_provider);
        var content_owned = true;
        errdefer if (content_owned) content.deinit();
        render_device.* = .{
            .allocator = allocator,
            .card = snapshot.card,
            .content = content,
            .renderer = path.renderer,
        };
        render_device_owned = false;
        content_owned = false;
        path_owned = false;
        return createWithPath(
            allocator,
            platforms,
            device,
            snapshot,
            config,
            render_device,
            true,
            path.output,
        ) catch |err| {
            render_device.destroy();
            return err;
        };
    }

    pub fn createWithRenderDevice(
        allocator: std.mem.Allocator,
        platforms: Platforms,
        device: kms.Device,
        snapshot: drm.Snapshot,
        config: Config,
        render_device: *RenderDevice,
    ) !*Output {
        try validateConfig(config);
        if (!render_device.matches(&snapshot.card)) return error.RenderDeviceMismatch;
        const fd = try device.fd(snapshot.handle);
        const path = try initOutputPath(allocator, platforms, fd, snapshot, config, render_device);
        return createWithPath(
            allocator,
            platforms,
            device,
            snapshot,
            config,
            render_device,
            false,
            path,
        );
    }

    fn createWithPath(
        allocator: std.mem.Allocator,
        platforms: Platforms,
        device: kms.Device,
        snapshot: drm.Snapshot,
        config: Config,
        render_device: *RenderDevice,
        owns_render_device: bool,
        path_value: OutputPath,
    ) !*Output {
        var path = path_value;
        errdefer {
            if (path.vulkan_targets) |*targets| switch (render_device.renderer orelse
                unreachable) {
                .vulkan => |*renderer| renderer.destroyTargets(targets),
                .pixman => unreachable,
            };
            path.pool.deinit() catch {};
        }
        const self = try allocator.create(Output);
        errdefer allocator.destroy(self);
        self.pool = path.pool;
        self.scanout_images = .{
            .allocator = allocator,
            .pool = &self.pool,
            .gbm_platform = platforms.gbm,
            .framebuffer_platform = platforms.framebuffer,
        };
        self.render_device = render_device;
        self.owns_render_device = owns_render_device;
        self.vulkan_targets = path.vulkan_targets;
        const mode = snapshot.selectedMode();
        const logical_output: render.Size = switch (config.output_transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => .{
                .width = mode.vdisplay,
                .height = mode.hdisplay,
            },
            else => .{ .width = mode.hdisplay, .height = mode.vdisplay },
        };
        self.output_format = formatFromDrm(self.pool.allocation.format) orelse
            return error.UnsupportedOutputFormat;
        try config.output_color_description.validate();
        self.output_color_description = config.output_color_description;
        self.builder = try render_list.Builder.initBorrowed(allocator, config.max_samples);
        errdefer self.builder.deinit();
        self.planner = try damage.Planner.init(allocator, logical_output, config.output_transform, .{
            .image_count = config.image_count,
            .max_samples = config.max_samples,
            .max_client_rects = config.max_client_damage,
            .max_scene_rects = config.max_scene_damage,
            .max_repair_rects = config.max_repair_damage,
            .max_render_rects = config.max_render_damage,
        });
        errdefer self.planner.deinit();
        self.scheduler = try Scheduler.init(allocator, config.output_id, config.scheduler, config.max_samples);
        errdefer self.scheduler.deinit(allocator);
        self.sample_storage = try allocator.alloc(
            scheduler_api.Sample(render.PresentationIdentity),
            config.max_samples,
        );
        errdefer allocator.free(self.sample_storage);
        const import_cache_capacity = std.math.mul(usize, config.max_samples, 2) catch
            return error.InvalidConfig;
        self.import_cache = try allocator.alloc(CachedImport, import_cache_capacity);
        @memset(self.import_cache, .{});
        errdefer allocator.free(self.import_cache);
        self.kms_output = try kms.Output.create(
            allocator,
            platforms.atomic,
            device,
            self.scanout_images.adapter(),
            snapshot,
            config.kms,
        );
        self.allocator = allocator;
        self.clear = config.clear;
        self.accepting_frames = true;
        self.in_flight_frame = null;
        self.in_flight_handle = null;
        self.in_flight_render_fence = null;
        self.in_flight_ready_ns = null;
        self.pending_callback = null;
        self.pending_capture = null;
        self.pending_capture_target = null;
        self.capture_targets = .empty;
        self.event_cursor = 0;
        self.import_cache_cursor = 0;
        self.paused = false;
        return self;
    }

    /// Strict teardown order: R11 has already drained R10, then renderer waits
    /// and releases imported targets while the pool/BOs remain alive, then R10
    /// removes framebuffers and BOs.
    pub fn destroy(self: *Output) !void {
        if (!self.drainComplete() or self.pending_callback != null or
            self.pending_capture != null or self.pending_capture_target != null or
            self.in_flight_render_fence != null or self.in_flight_ready_ns != null)
            return error.DrainIncomplete;
        try self.kms_output.destroy();
        try self.scanout_images.deinit();
        if (self.render_device.renderer) |*value| {
            switch (value.*) {
                .vulkan => |*renderer| for (self.capture_targets.items) |entry| {
                    renderer.destroyCaptureTarget(entry.target);
                    entry.lease.release();
                },
                .pixman => std.debug.assert(self.capture_targets.items.len == 0),
            }
            self.capture_targets.deinit(self.allocator);
            if (self.vulkan_targets) |*targets| switch (value.*) {
                .vulkan => |*renderer| renderer.destroyTargets(targets),
                .pixman => unreachable,
            };
            self.vulkan_targets = null;
        }
        for (self.import_cache) |*entry| self.destroyCachedImport(entry);
        self.allocator.free(self.import_cache);
        try self.pool.deinit();
        self.allocator.free(self.sample_storage);
        self.scheduler.deinit(self.allocator);
        self.planner.deinit();
        self.builder.deinit();
        const allocator = self.allocator;
        const render_device = self.render_device;
        const owns_render_device = self.owns_render_device;
        allocator.destroy(self);
        if (owns_render_device) render_device.destroy();
    }

    fn captureTarget(
        self: *Output,
        renderer: *vulkan.Renderer,
        destination: CaptureDmabuf,
    ) !vulkan_platform.CaptureTarget {
        var index: usize = 0;
        while (index < self.capture_targets.items.len) {
            const entry = &self.capture_targets.items[index];
            if (!entry.lease.alive()) {
                renderer.destroyCaptureTarget(entry.target);
                entry.lease.release();
                _ = self.capture_targets.swapRemove(index);
                continue;
            }
            if (entry.lease.context == destination.lease.context and
                entry.lease.token == destination.lease.token and
                std.meta.eql(entry.descriptor, destination.import))
            {
                try renderer.prepareCaptureTarget(entry.target, destination.import);
                return entry.target;
            }
            index += 1;
        }

        try destination.lease.duplicate();
        errdefer destination.lease.release();
        const target = try renderer.importCaptureTarget(destination.import);
        errdefer renderer.destroyCaptureTarget(target);
        try self.capture_targets.append(self.allocator, .{
            .lease = destination.lease,
            .descriptor = destination.import,
            .target = target,
        });
        return target;
    }

    pub fn rendererKind(self: *const Output) ?RendererKind {
        return self.render_device.rendererKind();
    }

    pub fn validateClientBuffer(self: *Output, import: gbm.Import) !void {
        const format = formatFromDrm(import.format) orelse return error.UnsupportedFormat;
        const renderer = &(self.render_device.renderer orelse return error.RendererUnavailable);
        switch (renderer.*) {
            .pixman => {
                var source = try mapImportedSource(self.pool.gbm_platform, self.pool.device, import);
                source.deinit();
            },
            .vulkan => |*value| try value.validateExternal(.{
                .context = self,
                .token = 0,
                .alive_fn = validationSourceAlive,
                .drm_format = import.format,
                .modifier = import.modifier,
                .plane_count = import.plane_count,
                .fds = import.fds,
                .strides = import.strides,
                .offsets = import.offsets,
            }, .{ .width = import.width, .height = import.height }, format),
        }
    }

    pub fn mapClientBuffer(
        self: *Output,
        identity: ImportIdentity,
        import: gbm.Import,
    ) !ImportedSource {
        for (self.import_cache) |*entry| if (entry.occupied and
            entry.identity.context == identity.context and entry.identity.token == identity.token)
        {
            if (!std.meta.eql(entry.descriptor, import)) return error.ImportIdentityMismatch;
            return switch (entry.backing) {
                .direct => |mapping| mapDirect(mapping, import),
                .gbm => |bo| promoted: {
                    if (directMap(import)) |mapping| {
                        if (mapDirect(mapping, import)) |mapped| {
                            self.pool.gbm_platform.destroyBo(bo);
                            entry.backing = .{ .direct = mapping };
                            break :promoted mapped;
                        } else |_| std.posix.munmap(mapping);
                    } else |_| {}
                    break :promoted mapImportedBo(self.pool.gbm_platform, bo, import, false);
                },
            };
        };

        const bo = try importClientBo(self.pool.gbm_platform, self.pool.device, import);
        errdefer self.pool.gbm_platform.destroyBo(bo);
        var mapped = try mapImportedBo(self.pool.gbm_platform, bo, import, false);
        errdefer mapped.deinit();
        const destination = self.importCacheDestination();
        self.destroyCachedImport(destination);
        destination.* = .{
            .occupied = true,
            .identity = identity,
            .descriptor = import,
            .backing = .{ .gbm = bo },
        };
        return mapped;
    }

    fn importCacheDestination(self: *Output) *CachedImport {
        const destination: *CachedImport = for (self.import_cache) |*entry| {
            if (!entry.occupied) break entry;
        } else &self.import_cache[self.import_cache_cursor];
        self.import_cache_cursor = (self.import_cache_cursor + 1) % self.import_cache.len;
        return destination;
    }

    fn destroyCachedImport(self: *Output, entry: *CachedImport) void {
        if (!entry.occupied) return;
        switch (entry.backing) {
            .direct => |mapping| std.posix.munmap(mapping),
            .gbm => |bo| self.pool.gbm_platform.destroyBo(bo),
        }
        entry.* = .{};
    }

    /// Transfers the initial output's renderer ownership to the composition
    /// root so it can outlive this and subsequent output instances.
    pub fn takeRenderDevice(self: *Output) *RenderDevice {
        std.debug.assert(self.owns_render_device);
        self.owns_render_device = false;
        return self.render_device;
    }

    pub fn outputId(self: *const Output) scheduler_api.OutputId {
        return self.scheduler.output;
    }

    pub fn captureDmabufDevice(self: *Output, size: render.Size) ?u64 {
        return self.render_device.captureDmabufDevice(size);
    }

    pub fn currentFrameId(self: *const Output) ?scheduler_api.FrameId {
        return self.scheduler.currentFrameId();
    }

    pub fn request(self: *Output, reason: scheduler_api.Reason, now_ns: u64) !void {
        if (!self.accepting_frames) return error.OutputPaused;
        try self.scheduler.request(reason, now_ns);
    }

    pub fn timerRequest(self: *const Output, now_ns: u64) !?scheduler_api.TimerRequest {
        if (!self.accepting_frames) return null;
        return self.scheduler.timerRequest(now_ns);
    }

    pub fn beginImmediatePhysical(self: *Output, now_ns: u64) !?scheduler_api.FrameId {
        if (!self.accepting_frames) return null;
        const request_value = try self.scheduler.beginImmediatePhysical(now_ns) orelse return null;
        return request_value.frame;
    }

    pub fn timerArmed(self: *Output, request_value: scheduler_api.TimerRequest, handle: timer.Handle, now_ns: u64) !void {
        try self.scheduler.timerArmed(request_value, handle, now_ns);
    }

    pub fn timerEvent(self: *Output, handle: timer.Handle, event: timer.Event, now_ns: u64) !?scheduler_api.RenderRequest {
        const result = try self.scheduler.timerEvent(handle, event, now_ns) orelse return null;
        return switch (result) {
            .render => |value| value,
            .frame => error.UnexpectedHeadlessPresentation,
        };
    }

    /// Performs the complete synchronous event-turn render/commit transition.
    /// `applied` must already come from the CU scheduler and retain stable source
    /// bytes through this call. Every binding must exactly match one sampled
    /// presentation.
    pub fn renderFrame(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        applied: []const render_list.AppliedSurface,
        changes: []const damage.Change,
        bindings: []const SampleBinding,
        now_ns: u64,
    ) !RenderResult {
        return self.renderFrameInternal(frame_id, applied, changes, bindings, now_ns, null, null);
    }

    pub fn renderFrameOn(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        applied: []const render_list.AppliedSurface,
        changes: []const damage.Change,
        bindings: []const SampleBinding,
        now_ns: u64,
        ring: *linux.IoUring,
    ) !RenderResult {
        return self.renderFrameInternal(frame_id, applied, changes, bindings, now_ns, null, ring);
    }

    pub fn renderFrameCapture(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        applied: []const render_list.AppliedSurface,
        changes: []const damage.Change,
        bindings: []const SampleBinding,
        now_ns: u64,
        capture: CaptureRequest,
    ) !RenderResult {
        return self.renderFrameInternal(frame_id, applied, changes, bindings, now_ns, capture, null);
    }

    pub fn renderFrameCaptureOn(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        applied: []const render_list.AppliedSurface,
        changes: []const damage.Change,
        bindings: []const SampleBinding,
        now_ns: u64,
        capture: CaptureRequest,
        ring: *linux.IoUring,
    ) !RenderResult {
        return self.renderFrameInternal(frame_id, applied, changes, bindings, now_ns, capture, ring);
    }

    fn renderFrameInternal(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        applied: []const render_list.AppliedSurface,
        changes: []const damage.Change,
        bindings: []const SampleBinding,
        now_ns: u64,
        capture: ?CaptureRequest,
        ring: ?*linux.IoUring,
    ) !RenderResult {
        if (!self.accepting_frames or self.in_flight_frame != null or
            self.pending_callback != null or self.pending_capture != null)
            return error.InvalidState;
        const list = self.builder.buildBorrowed(
            self.planner.output,
            self.output_format,
            self.clear,
            applied,
        ) catch |cause| return self.retireUnstartedRender(frame_id, cause);
        var color_list = list;
        color_list.output_color_description = self.output_color_description;
        if (bindings.len > self.sample_storage.len)
            self.sample_storage = self.allocator.realloc(self.sample_storage, bindings.len) catch |cause|
                return self.retireUnstartedRender(frame_id, cause);
        bindSamples(color_list, bindings, self.sample_storage) catch |cause|
            return self.retireUnstartedRender(frame_id, cause);
        try self.scheduler.captureSamples(frame_id, self.sample_storage[0..bindings.len]);
        if (capture == null and try self.submitDirectScanout(frame_id, color_list, now_ns, ring))
            return .submitted;
        const handle = self.pool.acquire() catch |cause|
            return self.retireRender(frame_id, cause);
        if (capture) |capture_request| validateCapture(
            capture_request,
            self.planner.physical_output,
            list.samples.len,
        ) catch |cause| {
            self.pool.discard(handle) catch {};
            return self.retireRender(frame_id, cause);
        };
        // Capture reads the complete acquired output image after ordinary
        // per-image repair. Forcing full damage here would redraw unchanged
        // output even though the planner already restores every stale region.
        const plan = self.planner.prepare(handle, color_list, changes) catch |cause| {
            self.pool.discard(handle) catch {};
            return self.retireRender(frame_id, cause);
        };

        var in_fence: ?std.posix.fd_t = null;
        var retained_render_fence: ?std.posix.fd_t = null;
        defer if (retained_render_fence) |fd| {
            _ = linux.close(fd);
        };
        var capture_target: ?vulkan_platform.CaptureTarget = null;
        const renderer = &(self.render_device.renderer orelse {
            return self.retireAndDiscard(frame_id, error.RendererUnavailable, handle);
        });
        switch (renderer.*) {
            .pixman => |*value| if (capture) |capture_request| switch (capture_request.destination) {
                .dmabuf => return self.retireAndDiscard(frame_id, error.RendererMismatch, handle),
                .shm => |destination| value.renderPhased(
                    &self.pool,
                    handle,
                    list,
                    plan,
                    capture_request.cursor_start,
                    if (capture_request.overlay_cursor) null else .{ .bytes = destination.bytes, .stride = destination.stride },
                    if (capture_request.overlay_cursor) .{ .bytes = destination.bytes, .stride = destination.stride } else null,
                ) catch |cause| {
                    return self.retireAndDiscard(frame_id, cause, handle);
                },
            } else value.renderPool(&self.pool, handle, list, plan) catch |cause| {
                return self.retireAndDiscard(frame_id, cause, handle);
            },
            .vulkan => |*value| {
                if (self.vulkan_targets == null)
                    return self.retireAndDiscard(frame_id, error.RendererUnavailable, handle);
                const render_result = if (capture) |capture_request| capture_result: {
                    const captures: vulkan_platform.Captures = if (capture_request.overlay_cursor)
                        .{ .after_cursor = true }
                    else
                        .{ .before_cursor = true };
                    break :capture_result switch (capture_request.destination) {
                        .shm => value.renderCapture(
                            &self.vulkan_targets.?,
                            vulkan.Target.fromPool(&self.pool),
                            handle,
                            color_list,
                            plan,
                            capture_request.cursor_start,
                            captures,
                        ),
                        .dmabuf => |destination| dmabuf: {
                            capture_target = self.captureTarget(value, destination) catch |cause|
                                return self.retireAndDiscard(frame_id, cause, handle);
                            break :dmabuf value.renderCaptureTo(
                                &self.vulkan_targets.?,
                                vulkan.Target.fromPool(&self.pool),
                                handle,
                                color_list,
                                plan,
                                capture_request.cursor_start,
                                captures,
                                .{ .target = capture_target.?, .source = destination.source },
                            );
                        },
                    };
                } else value.renderPool(
                    &self.vulkan_targets.?,
                    &self.pool,
                    handle,
                    list,
                    plan,
                );
                in_fence = render_result catch |cause| {
                    if (cause == error.CompletionExportFailedAfterSubmit) {
                        // The GPU has accepted work without exporting the only
                        // synchronization primitive. Target teardown is the
                        // terminal wait and releases every submitted content
                        // lease while Pool/BO still lives. The device-owned
                        // content arena remains alive with RenderDevice.
                        value.destroyTargets(&self.vulkan_targets.?);
                        self.vulkan_targets = null;
                    }
                    return self.retireAndDiscard(frame_id, cause, handle);
                };
                if (in_fence) |fd| retained_render_fence = duplicateFence(fd);
            },
        }
        // Capture and renderer success prove this transition under the
        // single-thread event-turn contract. Record it before KMS acceptance
        // so no fallible scheduler bookkeeping remains beyond that boundary.
        _ = self.scheduler.renderComplete(frame_id, now_ns) catch unreachable;
        self.kms_output.queue(handle, in_fence) catch |cause| {
            if (in_fence) |fd| _ = linux.close(fd); // R11 rejected ownership.
            return self.retireAndDiscard(frame_id, cause, handle);
        };
        const commit_result = if (ring) |value|
            self.kms_output.commitQueuedOn(value)
        else
            self.kms_output.commitQueued();
        commit_result catch |cause| {
            // R11 now owns and closes the fence and terminally disposes the
            // acquired image on every commit rollback.
            self.planner.cancel() catch unreachable;
            return self.retireRender(frame_id, cause);
        };
        // KMS now irreversibly owns the submitted R10 image. Establish R14's
        // tracking first; the remaining transitions are prevalidated and
        // cannot fail without violating single-thread ownership.
        self.in_flight_frame = frame_id;
        self.in_flight_handle = handle;
        std.debug.assert(self.in_flight_render_fence == null);
        std.debug.assert(self.in_flight_ready_ns == null);
        self.in_flight_render_fence = retained_render_fence;
        retained_render_fence = null;
        self.pending_capture = capture;
        self.pending_capture_target = capture_target;
        self.planner.publish() catch unreachable;
        self.scheduler.submitPhysical(frame_id, now_ns) catch unreachable;
        return .submitted;
    }

    /// Records synchronous Pixman completion after the caller captures a
    /// post-render CLOCK_MONOTONIC timestamp. Vulkan completion is measured
    /// from its retained sync_file at page flip instead.
    pub fn renderReady(self: *Output, frame_id: scheduler_api.FrameId, now_ns: u64) !void {
        if (self.in_flight_frame == null or
            !std.meta.eql(self.in_flight_frame.?, frame_id) or
            self.rendererKind() != .pixman or self.in_flight_ready_ns != null)
            return error.InvalidState;
        self.in_flight_ready_ns = now_ns;
    }

    /// Attempts the strict one-sample bypass while the scheduler still owns a
    /// reversible rendering-stage frame. Candidate import, FB registration,
    /// and TEST_ONLY failure all leave the current KMS image untouched and
    /// return to ordinary composition. After the real commit succeeds, the
    /// remaining scheduler transitions are prevalidated and infallible.
    fn submitDirectScanout(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        list: render.List,
        now_ns: u64,
        ring: ?*linux.IoUring,
    ) !bool {
        if (self.planner.output_transform != .normal) return false;
        const source = directScanoutSource(list, self.output_color_description) orelse
            return false;
        const handle = self.scanout_images.acquireDirect(source) catch return false;
        var acquired = true;
        defer if (acquired) self.scanout_images.discardAcquired(handle);
        const needs_test = self.scanout_images.needsTest(handle) catch unreachable;
        if (needs_test)
            self.kms_output.queueTested(handle, null) catch return false
        else
            self.kms_output.queue(handle, null) catch return false;
        acquired = false;
        const commit_result = if (ring) |value|
            self.kms_output.commitQueuedOn(value)
        else
            self.kms_output.commitQueued();
        commit_result catch return false;
        if (needs_test) self.scanout_images.markTested(handle);
        _ = self.scheduler.renderComplete(frame_id, now_ns) catch unreachable;
        self.in_flight_frame = frame_id;
        // Pool targets did not receive this scene. A later composed frame must
        // repair its complete destination before any pool image is displayed.
        self.planner.invalidateAll();
        self.scheduler.submitPhysical(frame_id, now_ns) catch unreachable;
        return true;
    }

    /// Dispatches callbacks already recorded by R11. Callback backpressure is
    /// retryable: the exact scheduler outcome remains pinned until success.
    pub fn processKmsEvents(self: *Output, callbacks: WaylandCallbacks) !void {
        return self.processKmsEventsInternal(callbacks, null);
    }

    pub fn processKmsEventsOn(
        self: *Output,
        callbacks: WaylandCallbacks,
        ring: *linux.IoUring,
    ) !void {
        return self.processKmsEventsInternal(callbacks, ring);
    }

    fn processKmsEventsInternal(
        self: *Output,
        callbacks: WaylandCallbacks,
        ring: ?*linux.IoUring,
    ) !void {
        // Never ask R11 to publish deferred policy into an already-full queue.
        // This matters when callback delivery previously hit TX backpressure.
        if (self.kms_output.events().len == 0)
            try self.kms_output.processCallbacks();
        try self.consumeKmsEvents(callbacks, ring);

        // One page flip can defer exactly one disabling commit because its
        // `.presented` event occupied the final event slot. After consuming the
        // batch, give R11 one non-spinning policy pass and consume that result.
        try self.kms_output.processCallbacks();
        try self.consumeKmsEvents(callbacks, ring);
    }

    fn consumeKmsEvents(
        self: *Output,
        callbacks: WaylandCallbacks,
        ring: ?*linux.IoUring,
    ) !void {
        const events = self.kms_output.events();
        while (self.event_cursor < events.len) {
            switch (events[self.event_cursor]) {
                .presented => |event| {
                    const timestamp_ns = flipTimestampNs(event.seconds, event.microseconds);
                    try self.finishCapture(callbacks, true, timestamp_ns);
                    if (self.pending_callback == null) {
                        const frame_id = self.in_flight_frame orelse return error.UnexpectedPageFlip;
                        // R11 validates the callback against the exact commit
                        // record before publishing this event. Its current
                        // scanout can already be null when a queued pause is
                        // committed in the same event batch, so it is not a
                        // stable identity source at this handoff boundary.
                        self.pending_callback = try self.scheduler.presentPhysical(
                            frame_id,
                            timestamp_ns,
                            self.takeRenderReadyTimestamp(ring),
                        );
                    }
                    const outcome = self.pending_callback.?;
                    try callbacks.presented(outcome, callbackData(outcome.actual_ns.?));
                    self.pending_callback = null;
                    self.in_flight_frame = null;
                    self.in_flight_handle = null;
                },
                .paused => self.paused = true,
                .removed => {
                    if (self.in_flight_frame) |frame_id| {
                        try self.finishCapture(callbacks, false, 0);
                        if (self.pending_callback == null)
                            self.pending_callback = try self.scheduler.retirePhysical(frame_id);
                        try callbacks.retired(self.pending_callback.?);
                        self.pending_callback = null;
                        self.discardRenderTiming(ring);
                        self.in_flight_frame = null;
                        self.in_flight_handle = null;
                    }
                    self.paused = true;
                },
                .failed => {
                    try self.finishCapture(callbacks, false, 0);
                    self.discardRenderTiming(ring);
                    return error.KmsFailed;
                },
                .drained => {},
            }
            self.event_cursor += 1;
        }
        self.kms_output.clearEvents();
        self.event_cursor = 0;
    }

    fn takeRenderReadyTimestamp(self: *Output, ring: ?*linux.IoUring) ?u64 {
        const ready_ns = if (self.in_flight_render_fence) |fd|
            syncFileSignalNanoseconds(fd)
        else
            self.in_flight_ready_ns;
        self.discardRenderTiming(ring);
        return ready_ns;
    }

    fn discardRenderTiming(self: *Output, ring: ?*linux.IoUring) void {
        if (self.in_flight_render_fence) |fd| close: {
            if (ring) |shared_ring| {
                const sqe = shared_ring.close(completion.skipped_success_user_data, fd) catch
                    break :close;
                sqe.flags |= linux.IOSQE_CQE_SKIP_SUCCESS;
                self.in_flight_render_fence = null;
            }
        }
        if (self.in_flight_render_fence) |fd| _ = linux.close(fd);
        self.in_flight_render_fence = null;
        self.in_flight_ready_ns = null;
    }

    fn finishCapture(
        self: *Output,
        callbacks: WaylandCallbacks,
        presented: bool,
        timestamp_ns: u64,
    ) !void {
        const capture_request = self.pending_capture orelse return;
        var success = presented;
        var readback: ?CaptureReadback = null;
        if (success) switch (capture_request.destination) {
            .shm => |destination| {
                const renderer = &(self.render_device.renderer orelse
                    return error.RendererUnavailable);
                switch (renderer.*) {
                    .pixman => readback = .{
                        .bytes = destination.bytes,
                        .stride = destination.stride,
                    },
                    .vulkan => |*value| vulkan_readback: {
                        const targets = &(self.vulkan_targets orelse return error.RendererUnavailable);
                        const source = value.readback(
                            targets,
                            self.in_flight_handle orelse return error.MissingCaptureTarget,
                            if (capture_request.overlay_cursor) .after_cursor else .before_cursor,
                        ) catch {
                            success = false;
                            break :vulkan_readback;
                        };
                        readback = .{ .bytes = source.bytes, .stride = source.stride };
                    },
                }
            },
            .dmabuf => {},
        };
        if (self.pending_capture_target) |target| {
            _ = target;
            self.pending_capture_target = null;
        }
        try callbacks.captured(capture_request.token, success, timestamp_ns, readback);
        self.pending_capture = null;
    }

    /// Starts the Session-disable path. A submitted frame is allowed to flip
    /// and produce its real callback before R11 disables scanout.
    pub fn requestPause(self: *Output) !?RetireAction {
        self.accepting_frames = false;
        const removal = try self.scheduler.remove();
        try self.kms_output.requestPause();
        if (retireAction(removal)) |action| return action;
        if (self.scheduler.currentStage() == .rendering) return .{
            .retired = try self.scheduler.cancelUnstartedRender(self.scheduler.currentFrameId().?),
        };
        return null;
    }

    pub fn terminalDeviceTeardown(self: *Output) !?RetireAction {
        self.accepting_frames = false;
        const removal = try self.scheduler.remove();
        try self.kms_output.terminalDeviceTeardown();
        if (retireAction(removal)) |action| return action;
        if (self.scheduler.currentStage() == .rendering) return .{
            .retired = try self.scheduler.cancelUnstartedRender(self.scheduler.currentFrameId().?),
        };
        return null;
    }

    pub fn prepareReadiness(self: *Output, router: *completion.Router, ring: *linux.IoUring) !void {
        try self.kms_output.prepareReadiness(router, ring);
    }

    pub fn completeReadiness(self: *Output, router: *completion.Router, ring: *linux.IoUring, token: completion.Token, result: i32) !void {
        try self.kms_output.completeReadiness(router, ring, token, result);
    }

    pub fn ownsReadinessToken(self: *const Output, token: completion.Token) bool {
        return self.kms_output.ownsReadinessToken(token);
    }

    pub fn beginDrain(self: *Output, router: *completion.Router, ring: *linux.IoUring) !void {
        if (!self.paused) return error.ScanoutNotQuiescent;
        try self.kms_output.beginDrain(router, ring);
    }

    pub fn drainComplete(self: *const Output) bool {
        return self.kms_output.drainComplete() and
            self.scheduler.currentStage() == .removed and self.in_flight_frame == null;
    }

    fn retireRender(self: *Output, frame_id: scheduler_api.FrameId, cause: anyerror) !RenderResult {
        return .{ .retired = .{ .cause = cause, .frame = try self.scheduler.failRender(frame_id) } };
    }

    fn retireUnstartedRender(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        cause: anyerror,
    ) !RenderResult {
        return .{ .retired = .{
            .cause = cause,
            .frame = try self.scheduler.cancelUnstartedRender(frame_id),
        } };
    }

    /// Retire Scheduler first so cleanup can never strand the frame. R10's
    /// `GenerationExhausted` means the slot was successfully retired and does
    /// not replace the initiating cause; other cleanup failures are reported
    /// with the already-retired outcome.
    fn retireAndDiscard(
        self: *Output,
        frame_id: scheduler_api.FrameId,
        cause: anyerror,
        handle: framebuffer.Handle,
    ) !RenderResult {
        const frame = try self.scheduler.failRender(frame_id);
        self.planner.cancel() catch unreachable;
        var reported = cause;
        self.pool.discard(handle) catch |cleanup| switch (cleanup) {
            error.GenerationExhausted => {},
            else => reported = cleanup,
        };
        return .{ .retired = .{ .cause = reported, .frame = frame } };
    }
};

fn retireAction(removal: anytype) ?RetireAction {
    const value = removal orelse return null;
    return switch (value) {
        .cancel => |handle| .{ .cancel = handle },
        .frame => |frame| .{ .retired = frame },
    };
}

fn initRenderPath(allocator: std.mem.Allocator, platforms: Platforms, fd: std.posix.fd_t, snapshot: drm.Snapshot, config: Config) !InitialRenderPath {
    return switch (config.renderer) {
        .pixman => initPixman(allocator, platforms, fd, snapshot, config),
        .vulkan => initVulkan(allocator, platforms, fd, snapshot, config),
        .vulkan_then_pixman => initVulkan(allocator, platforms, fd, snapshot, config) catch
            initPixman(allocator, platforms, fd, snapshot, config),
    };
}

fn initOutputPath(
    allocator: std.mem.Allocator,
    platforms: Platforms,
    fd: std.posix.fd_t,
    snapshot: drm.Snapshot,
    config: Config,
    render_device: *RenderDevice,
) !OutputPath {
    const renderer = &(render_device.renderer orelse return error.RendererUnavailable);
    return switch (renderer.*) {
        .pixman => initPixmanOutput(allocator, platforms, fd, snapshot, config),
        .vulkan => |*value| initVulkanOutput(
            allocator,
            platforms,
            fd,
            snapshot,
            config,
            value,
        ),
    };
}

fn initPixmanOutput(allocator: std.mem.Allocator, platforms: Platforms, fd: std.posix.fd_t, snapshot: drm.Snapshot, config: Config) !OutputPath {
    return .{
        .pool = try cpu.initTargetPool(
            allocator,
            platforms.gbm,
            platforms.framebuffer,
            fd,
            snapshot,
            config.image_count,
        ),
    };
}

fn initVulkanOutput(
    allocator: std.mem.Allocator,
    platforms: Platforms,
    fd: std.posix.fd_t,
    snapshot: drm.Snapshot,
    config: Config,
    renderer: *vulkan.Renderer,
) !OutputPath {
    if (snapshot.selectedPlane().properties.in_fence_fd == 0)
        return error.InFenceUnsupported;
    var pool = try vulkan.initTargetPool(
        allocator,
        platforms.gbm,
        platforms.framebuffer,
        fd,
        snapshot,
        config.image_count,
    );
    errdefer pool.deinit() catch {};
    return .{
        .pool = pool,
        .vulkan_targets = try renderer.createTargets(config.image_count),
    };
}

fn initPixman(allocator: std.mem.Allocator, platforms: Platforms, fd: std.posix.fd_t, snapshot: drm.Snapshot, config: Config) !InitialRenderPath {
    var pool = try cpu.initTargetPool(allocator, platforms.gbm, platforms.framebuffer, fd, snapshot, config.image_count);
    errdefer pool.deinit() catch {};
    const renderer = try cpu.Renderer.init(allocator, .{
        .max_samples = config.max_samples,
        .max_source_width = config.max_source_width,
        .max_source_height = config.max_source_height,
    });
    return .{
        .output = .{ .pool = pool },
        .renderer = .{ .pixman = renderer },
    };
}

fn initVulkan(allocator: std.mem.Allocator, platforms: Platforms, fd: std.posix.fd_t, snapshot: drm.Snapshot, config: Config) !InitialRenderPath {
    if (snapshot.selectedPlane().properties.in_fence_fd == 0)
        return error.InFenceUnsupported;
    var pool = try vulkan.initTargetPool(allocator, platforms.gbm, platforms.framebuffer, fd, snapshot, config.image_count);
    errdefer pool.deinit() catch {};
    const content_version_capacity = std.math.add(usize, config.max_samples, 1) catch
        return error.InvalidConfig;
    const content_store_bytes = std.math.mul(
        usize,
        surfaceByteCapacity(config),
        content_version_capacity,
    ) catch return error.InvalidConfig;
    const retained_upload_bytes = std.math.mul(
        usize,
        config.max_source_bytes,
        config.max_render_targets,
    ) catch return error.InvalidConfig;
    const renderer = try vulkan.Renderer.init(allocator, platforms.vulkan, fd, .{
        .max_samples = config.max_samples,
        .max_source_bytes = config.max_source_bytes,
        .max_targets = config.max_render_targets,
        .max_color_luts = config.max_color_luts,
        .require_color_management = config.enable_color_management,
        .max_damage_rects = config.max_render_damage,
        .content_bytes = std.math.add(
            usize,
            content_store_bytes,
            retained_upload_bytes,
        ) catch return error.InvalidConfig,
        .content_allocations = std.math.add(
            usize,
            content_version_capacity,
            std.math.mul(
                usize,
                config.max_render_targets,
                config.max_samples,
            ) catch return error.InvalidConfig,
        ) catch return error.InvalidConfig,
    });
    var owned_renderer = renderer;
    errdefer owned_renderer.deinit();
    const targets = try owned_renderer.createTargets(config.image_count);
    return .{
        .output = .{
            .pool = pool,
            .vulkan_targets = targets,
        },
        .renderer = .{ .vulkan = owned_renderer },
    };
}

fn bindSamples(list: render.List, bindings: []const SampleBinding, output: []scheduler_api.Sample(render.PresentationIdentity)) !void {
    if (bindings.len != list.samples.len or bindings.len > output.len)
        return error.SampleBindingMismatch;
    for (bindings, 0..) |binding, index| {
        const sample = list.samples[index];
        if (!std.meta.eql(binding.sample, sample.sample) or
            !std.meta.eql(binding.presentation, sample.presentation) or
            binding.sample.surface !=
                ((@as(u64, binding.surface.generation) << 32) | binding.surface.index))
            return error.SampleBindingMismatch;
        output[index] = .{ .surface = binding.surface, .presentation = binding.presentation };
    }
}

pub fn formatFromDrm(value: u32) ?render.PixelFormat {
    if (value == gbm.format_xrgb8888) return .xrgb8888;
    if (value == gbm.format_argb8888) return .argb8888_premultiplied;
    return null;
}

fn directScanoutSource(
    list: render.List,
    output_color: render.color.Description,
) ?render.Source {
    if (list.samples.len != 1) return null;
    const sample = list.samples[0];
    const external = sample.source.external orelse return null;
    if (sample.source.native != null or sample.source.upload != null or
        sample.source.format != .xrgb8888 or list.output_format != .xrgb8888 or
        formatFromDrm(external.drm_format) != .xrgb8888 or
        !std.meta.eql(sample.source.size, list.output) or sample.transform != .normal or
        sample.global_alpha != 255 or
        !std.meta.eql(sample.color_description, output_color) or
        !std.meta.eql(sample.color_representation, render.color.Representation{}))
        return null;
    const fixed_width = @as(i64, sample.source.size.width) * render.fixed_one;
    const fixed_height = @as(i64, sample.source.size.height) * render.fixed_one;
    if (sample.crop.x != 0 or sample.crop.y != 0 or
        sample.crop.width != fixed_width or sample.crop.height != fixed_height)
        return null;
    const full = render.Rect{
        .x = 0,
        .y = 0,
        .width = list.output.width,
        .height = list.output.height,
    };
    if (!std.meta.eql(sample.destination, full) or !std.meta.eql(sample.clip, full))
        return null;
    return sample.source;
}

fn flipTimestampNs(seconds: u32, microseconds: u32) u64 {
    return @as(u64, seconds) * std.time.ns_per_s + @as(u64, microseconds) * std.time.ns_per_us;
}

fn callbackData(timestamp_ns: u64) u32 {
    return @truncate(timestamp_ns / std.time.ns_per_ms);
}

fn duplicateFence(fd: std.posix.fd_t) ?std.posix.fd_t {
    const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    if (linux.errno(result) != .SUCCESS) return null;
    return @intCast(result);
}

fn syncFileSignalNanoseconds(fd: std.posix.fd_t) ?u64 {
    var fences: [16]c.sync_fence_info = undefined;
    var info: c.sync_file_info = std.mem.zeroes(c.sync_file_info);
    info.num_fences = fences.len;
    info.sync_fence_info = @intFromPtr(&fences);
    if (!readSyncFileInfo(fd, &info) or info.status != 1 or
        info.num_fences == 0 or info.num_fences > fences.len)
        return null;

    var signal_ns: u64 = 0;
    for (fences[0..info.num_fences]) |fence| {
        if (fence.status != 1 or fence.timestamp_ns == 0) return null;
        signal_ns = @max(signal_ns, fence.timestamp_ns);
    }
    return signal_ns;
}

fn readSyncFileInfo(fd: std.posix.fd_t, info: *c.sync_file_info) bool {
    while (true) {
        const result = c.ioctl(fd, c.SYNC_IOC_FILE_INFO, info);
        if (result == 0) return true;
        if (std.posix.errno(result) != .INTR) return false;
    }
}

test "drm-sim: exact sampled identities bind in presentation order" {
    const bytes = [_]u8{ 0, 0, 0, 255 };
    const binding = try appliedSampleBinding(
        .{ .index = 11, .generation = 3 },
        9,
        .{ .slot = 2, .generation = 4 },
    );
    const sample: render.SurfaceSample = .{
        .sample = binding.sample,
        .presentation = binding.presentation,
        .source = .{ .size = .{ .width = 1, .height = 1 }, .stride = 4, .format = .xrgb8888, .bytes = &bytes },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    const list: render.List = .{ .output = .{ .width = 1, .height = 1 }, .output_format = .xrgb8888, .clear = .{ .r = 0, .g = 0, .b = 0 }, .samples = &.{sample} };
    var output: [1]scheduler_api.Sample(render.PresentationIdentity) = undefined;
    try bindSamples(list, &.{binding}, &output);
    try std.testing.expectEqual(sample.presentation, output[0].presentation);
    var stale = sample;
    stale.presentation.generation += 1;
    try std.testing.expectError(error.SampleBindingMismatch, bindSamples(list, &.{.{
        .surface = binding.surface,
        .sample = stale.sample,
        .presentation = stale.presentation,
    }}, &output));
}

test "drm-output: direct scanout eligibility is exact and conservative" {
    const external: render.ExternalSource = .{
        .context = @ptrFromInt(1),
        .token = 1,
        .alive_fn = testExternalAlive,
        .drm_format = gbm.format_xrgb8888,
        .modifier = gbm.modifier_linear,
        .plane_count = 1,
        .fds = .{ 3, -1, -1, -1 },
        .strides = .{ 8, 0, 0, 0 },
        .offsets = .{ 0, 0, 0, 0 },
    };
    var sample: render.SurfaceSample = .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 2, .height = 1 },
            .stride = 8,
            .format = .xrgb8888,
            .bytes = &.{},
            .external = external,
        },
        .crop = render.SourceRect.pixels(0, 0, 2, 1),
        .destination = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 2, .height = 1 },
    };
    var list: render.List = .{
        .output = .{ .width = 2, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{sample},
    };
    try std.testing.expect(directScanoutSource(list, .srgb) != null);
    sample.destination.width = 1;
    list.samples = &.{sample};
    try std.testing.expect(directScanoutSource(list, .srgb) == null);
    sample.destination.width = 2;
    sample.global_alpha = 254;
    list.samples = &.{sample};
    try std.testing.expect(directScanoutSource(list, .srgb) == null);
    sample.global_alpha = 255;
    sample.source.native = .{ .owner = @ptrFromInt(1), .token = 1 };
    list.samples = &.{sample};
    try std.testing.expect(directScanoutSource(list, .srgb) == null);
}

fn testExternalAlive(_: *anyopaque, _: u64) bool {
    return true;
}

test "drm-sim: physical scheduler is page-flip paced and retires on failure" {
    var scheduler = try Scheduler.init(std.testing.allocator, .{ .index = 1, .generation = 2 }, .{ .refresh_ns = 10, .render_budget_ns = 3 }, 1);
    defer scheduler.deinit(std.testing.allocator);
    try scheduler.request(.damage, 1);
    const arm = (try scheduler.timerRequest(1)).?;
    const timer_handle: timer.Handle = .{ .slot = 1, .generation = 1 };
    try scheduler.timerArmed(arm, timer_handle, 1);
    const render_event = (try scheduler.timerEvent(timer_handle, .fired, 7)).?;
    const samples = [_]scheduler_api.Sample(render.PresentationIdentity){.{
        .surface = .{ .index = 4, .generation = 5 },
        .presentation = .{ .slot = 6, .generation = 7 },
    }};
    try scheduler.captureSamples(render_event.render.frame, &samples);
    _ = try scheduler.renderComplete(render_event.render.frame, 8);
    try scheduler.submitPhysical(render_event.render.frame, 8);
    try std.testing.expect((try scheduler.timerRequest(9)) == null);
    const outcome = try scheduler.presentPhysical(render_event.render.frame, 12, 3);
    try std.testing.expect(outcome.frame_callbacks_due);
    try std.testing.expectEqual(@as(?u64, 12), outcome.actual_ns);
    try std.testing.expectEqualSlices(scheduler_api.Sample(render.PresentationIdentity), &samples, outcome.sampled);

    try scheduler.request(.damage, 13);
    const second = (try scheduler.timerRequest(13)).?;
    const second_timer: timer.Handle = .{ .slot = 1, .generation = 2 };
    try scheduler.timerArmed(second, second_timer, 13);
    const second_event = (try scheduler.timerEvent(second_timer, .fired, 17)).?;
    try scheduler.captureSamples(second_event.render.frame, &samples);
    const retired = try scheduler.failRender(second_event.render.frame);
    try std.testing.expectEqual(scheduler_api.Disposition.retired, retired.disposition);
    try std.testing.expect(!retired.frame_callbacks_due);
}

test "drm-sim: Session generations select create and quiesce actions" {
    try std.testing.expectEqual(SessionAction.create_output, sessionAction(.{ .enabled = 2 }));
    try std.testing.expectEqual(SessionAction.quiesce_output, sessionAction(.{ .disabling = 2 }));
    try std.testing.expectEqual(SessionAction.none, sessionAction(.{ .disabled = 2 }));
}

test "drm-sim: render device survives output target recreation" {
    var fixture = SimFixture{};
    const platforms = fixture.platforms();
    const snapshot = fixture.snapshot();
    var config: Config = .{
        .output_id = .{ .index = 0, .generation = 1 },
        .scheduler = .{ .refresh_ns = 10, .render_budget_ns = 3 },
        .renderer = .pixman,
        .image_count = 2,
        .max_samples = 1,
        .max_source_bytes = 4,
        .max_source_width = 1,
        .max_source_height = 1,
    };
    const first = try Output.create(
        std.testing.allocator,
        platforms,
        fixture.device(),
        snapshot,
        config,
    );
    const render_device = first.takeRenderDevice();
    try std.testing.expectEqual(RendererKind.pixman, render_device.rendererKind().?);
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const content = render_device.content.publish(try render_device.content.prepare(
        .{ .surface = 1, .commit_sequence = 1 },
        .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .xrgb8888,
            .bytes = &pixels,
        },
        .{},
    ));
    try drainIdleSimOutput(first, &fixture);
    try std.testing.expectEqual(RendererKind.pixman, render_device.rendererKind().?);

    config.output_id.generation = 2;
    const second = try Output.createWithRenderDevice(
        std.testing.allocator,
        platforms,
        fixture.device(),
        snapshot,
        config,
        render_device,
    );
    try std.testing.expect(second.render_device == render_device);
    try std.testing.expectEqualSlices(u8, &pixels, (try render_device.content.resolve(content)).bytes);
    try drainIdleSimOutput(second, &fixture);
    render_device.content.release(content);
    render_device.destroy();
    fixture.ring.deinit();
    fixture.router.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), fixture.bos_destroyed);
    try std.testing.expectEqual(@as(usize, 4), fixture.framebuffers_removed);
}

test "drm-sim: pre-capture failures retire scheduler and remain removable" {
    var fixture = SimFixture{};
    const output = try Output.create(
        std.testing.allocator,
        fixture.platforms(),
        fixture.device(),
        fixture.snapshot(),
        .{
            .output_id = .{ .index = 0, .generation = 1 },
            .scheduler = .{ .refresh_ns = 10, .render_budget_ns = 3 },
            .renderer = .pixman,
            .image_count = 2,
            .max_samples = 1,
            .max_source_bytes = 4,
            .max_source_width = 1,
            .max_source_height = 1,
        },
    );
    const bytes = [_]u8{ 0, 0, 0, 255 };
    const malformed: render_list.AppliedSurface = .{
        .sample = .{ .surface = 0, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{ .size = .{ .width = 1, .height = 1 }, .stride = 4, .format = .xrgb8888, .bytes = &bytes },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };

    const first = try startSimFrame(output, 1, .{ .slot = 0, .generation = 1 });
    var stale = first;
    stale.output.generation += 1;
    try std.testing.expectError(
        error.StaleFrame,
        output.renderFrame(stale, &.{malformed}, &.{}, &.{}, 8),
    );
    try std.testing.expectEqual(scheduler_api.Stage.rendering, output.scheduler.currentStage());
    try std.testing.expectEqual(first, output.scheduler.currentFrameId().?);
    const malformed_result = try output.renderFrame(first, &.{malformed}, &.{}, &.{}, 8);
    switch (malformed_result) {
        .retired => |failure| try std.testing.expect(failure.cause == error.InvalidIdentity),
        .submitted => return error.ExpectedRetirement,
    }
    try std.testing.expectEqual(scheduler_api.Stage.idle, output.scheduler.currentStage());

    const second = try startSimFrame(output, 11, .{ .slot = 0, .generation = 2 });
    const binding = try appliedSampleBinding(
        .{ .index = 1, .generation = 1 },
        1,
        .{ .slot = 0, .generation = 1 },
    );
    const binding_result = try output.renderFrame(second, &.{}, &.{}, &.{binding}, 18);
    switch (binding_result) {
        .retired => |failure| try std.testing.expect(failure.cause == error.SampleBindingMismatch),
        .submitted => return error.ExpectedRetirement,
    }
    try std.testing.expectEqual(scheduler_api.Stage.idle, output.scheduler.currentStage());

    try output.request(.damage, 21);
    try std.testing.expect((try output.requestPause()) == null);
    const callbacks: WaylandCallbacks = .{
        .context = &fixture,
        .presented_fn = SimFixture.unexpectedPresented,
        .retired_fn = SimFixture.unexpectedRetired,
    };
    try output.processKmsEvents(callbacks);
    try output.beginDrain(&fixture.router, &fixture.ring);
    try output.processKmsEvents(callbacks);
    try output.destroy();
    fixture.ring.deinit();
    fixture.router.deinit(std.testing.allocator);
}

test "drm-sim: physical Pixman owner starts and drains in strict order" {
    var fixture = SimFixture{};
    const snapshot = fixture.snapshot();
    const output = try Output.create(
        std.testing.allocator,
        fixture.platforms(),
        fixture.device(),
        snapshot,
        .{
            .output_id = .{ .index = 0, .generation = 1 },
            .scheduler = .{ .refresh_ns = 16_666_667, .render_budget_ns = 2_000_000 },
            .renderer = .pixman,
            .image_count = 2,
            .max_samples = 1,
            .max_source_bytes = 4,
            .max_source_width = 1,
            .max_source_height = 1,
            .kms = .{ .event_capacity = 1 },
        },
    );
    try std.testing.expectEqual(RendererKind.pixman, output.rendererKind().?);
    try output.prepareReadiness(&fixture.router, &fixture.ring);
    try output.request(.damage, 1);
    const timer_request = (try output.timerRequest(1)).?;
    const timer_handle: timer.Handle = .{ .slot = 0, .generation = 1 };
    try output.timerArmed(timer_request, timer_handle, 1);
    const frame = (try output.timerEvent(timer_handle, .fired, 14_666_667)).?.frame;
    var captured_bytes = [_]u8{0xaa} ** 4;
    try std.testing.expectEqual(RenderResult.submitted, try output.renderFrameCapture(
        frame,
        &.{},
        &.{},
        &.{},
        15_000_000,
        .{
            .token = 77,
            .cursor_start = 0,
            .overlay_cursor = false,
            .destination = .{ .shm = .{ .bytes = &captured_bytes, .stride = 4 } },
        },
    ));
    try std.testing.expectEqual(frame, output.in_flight_frame.?);
    try std.testing.expect((try output.requestPause()) == null);
    const first_read = output.kms_output.read_token.?;
    try output.completeReadiness(
        &fixture.router,
        &fixture.ring,
        first_read,
        1,
    );
    const callbacks: WaylandCallbacks = .{
        .context = &fixture,
        .presented_fn = SimFixture.presented,
        .retired_fn = SimFixture.unexpectedRetired,
        .captured_fn = SimFixture.captured,
    };
    fixture.capture_backpressure = true;
    try std.testing.expectError(error.Exhausted, output.processKmsEvents(callbacks));
    try std.testing.expect(output.pending_capture != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.presented_count);
    try output.processKmsEvents(callbacks);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &captured_bytes);
    try std.testing.expectEqual(@as(usize, 1), fixture.captured_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.presented_count);
    try std.testing.expect(output.paused);
    try output.beginDrain(&fixture.router, &fixture.ring);
    const drain_read = output.kms_output.read_token.?;
    const drain_cancel = output.kms_output.cancel_token.?;
    try output.completeReadiness(
        &fixture.router,
        &fixture.ring,
        drain_read,
        -@as(i32, @intFromEnum(linux.E.CANCELED)),
    );
    try output.completeReadiness(&fixture.router, &fixture.ring, drain_cancel, 0);
    try output.processKmsEvents(callbacks);
    try std.testing.expect(output.drainComplete());
    try output.destroy();
    fixture.ring.deinit();
    fixture.router.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), fixture.bos_destroyed);
    try std.testing.expectEqual(@as(usize, 2), fixture.framebuffers_removed);
    try std.testing.expect(fixture.pool_removal_started_before_bo);
}

const SimFixture = struct {
    bytes: [4][4]u8 align(4) = [_][4]u8{[_]u8{0} ** 4} ** 4,
    dumb_bytes: [4][std.heap.page_size_min]u8 align(std.heap.page_size_min) =
        [_][std.heap.page_size_min]u8{[_]u8{0} ** std.heap.page_size_min} ** 4,
    bo_count: usize = 0,
    bos_destroyed: usize = 0,
    framebuffers_removed: usize = 0,
    pool_removal_started_before_bo: bool = false,
    requests: [4]u8 = .{ 0, 0, 0, 0 },
    request_count: usize = 0,
    flip_userdata: ?*anyopaque = null,
    presented_count: usize = 0,
    captured_count: usize = 0,
    capture_backpressure: bool = false,
    last_map_access: ?gbm.MapAccess = null,
    router: completion.Router = undefined,
    ring: linux.IoUring = undefined,

    const gbm_vtable: gbm.Platform.VTable = .{
        .create_device = createDevice,
        .destroy_device = destroyDevice,
        .create_bo = createBo,
        .import_bo = importBo,
        .destroy_bo = destroyBo,
        .metadata = metadata,
        .export_plane_fd = exportPlaneFd,
        .map = map,
        .unmap = unmap,
    };
    const framebuffer_vtable: framebuffer.Platform.VTable = .{
        .add = addFramebuffer,
        .remove = removeFramebuffer,
        .create_dumb = createDumb,
        .destroy_dumb = destroyDumb,
    };
    const atomic_vtable: atomic.Platform.VTable = .{
        .create_blob = createBlob,
        .destroy_blob = destroyBlob,
        .create_request = createRequest,
        .destroy_request = destroyRequest,
        .reset_request = resetRequest,
        .add_property = addProperty,
        .commit = commit,
        .handle_events = handleEvents,
    };

    fn platforms(self: *SimFixture) Platforms {
        self.router = completion.Router.init(std.testing.allocator, 6) catch unreachable;
        self.ring = linux.IoUring.init(8, 0) catch unreachable;
        return .{
            .gbm = .{ .context = self, .vtable = &gbm_vtable },
            .framebuffer = .{ .context = self, .vtable = &framebuffer_vtable },
            .atomic = .{ .context = self, .vtable = &atomic_vtable },
        };
    }

    fn device(self: *SimFixture) kms.Device {
        return .{ .context = self, .get_fd = getFd };
    }

    fn snapshot(self: *SimFixture) drm.Snapshot {
        _ = self;
        const Data = struct {
            var connectors = [_]drm.Connector{.{ .id = 10, .connector_type = 1, .connector_type_id = 1, .connected = true, .desktop = true, .width_mm = 1, .height_mm = 1, .encoder_id = 20, .mode_start = 0, .mode_count = 1, .encoder_start = 0, .encoder_count = 1, .properties = .{ .crtc_id = 1 } }};
            var modes = [_]drm.Mode{.{ .clock = 1, .hdisplay = 1, .hsync_start = 1, .hsync_end = 1, .htotal = 1, .hskew = 0, .vdisplay = 1, .vsync_start = 1, .vsync_end = 1, .vtotal = 1, .vscan = 0, .vrefresh = 60, .flags = 0, .mode_type = 0 }};
            var connector_encoders = [_]u32{20};
            var encoders = [_]drm.Encoder{.{ .id = 20, .crtc_id = 30, .possible_crtcs = 1 }};
            var crtcs = [_]drm.Crtc{.{ .id = 30, .index = 0, .properties = .{ .active = 2, .mode_id = 3 } }};
            var planes = [_]drm.Plane{.{ .id = 40, .possible_crtcs = 1, .plane_type_value = 1, .format_start = 0, .format_count = 1, .properties = .{ .plane_type = 4, .fb_id = 5, .crtc_id = 6, .src_x = 7, .src_y = 8, .src_w = 9, .src_h = 10, .crtc_x = 11, .crtc_y = 12, .crtc_w = 13, .crtc_h = 14 } }};
            var formats = [_]drm.Format{.{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear }};
        };
        return .{
            .handle = .{ .generation = 1 },
            .card = .{},
            .connectors = &Data.connectors,
            .modes = &Data.modes,
            .connector_encoders = &Data.connector_encoders,
            .encoders = &Data.encoders,
            .crtcs = &Data.crtcs,
            .planes = &Data.planes,
            .formats = &Data.formats,
            .selection = .{ .connector_index = 0, .mode_index = 0, .crtc_index = 0, .plane_index = 0 },
        };
    }

    fn getFd(_: *anyopaque, _: drm.Handle) !std.posix.fd_t {
        return 99;
    }
    fn createDevice(context: *anyopaque, _: std.posix.fd_t) !gbm.Device {
        return context;
    }
    fn destroyDevice(_: *anyopaque, _: gbm.Device) void {}
    fn createBo(context: *anyopaque, _: gbm.Device, _: gbm.Allocation) !gbm.Bo {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        const index = self.bo_count;
        self.bo_count += 1;
        return @ptrCast(&self.bytes[index]);
    }

    fn importBo(context: *anyopaque, gbm_device: gbm.Device, import: gbm.Import, _: gbm.ImportUsage) !gbm.Bo {
        return createBo(context, gbm_device, .{
            .width = import.width,
            .height = import.height,
            .format = import.format,
            .modifier = import.modifier,
            .explicit_modifier = true,
        });
    }
    fn destroyBo(context: *anyopaque, _: gbm.Bo) void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        self.bos_destroyed += 1;
    }
    fn metadata(_: *anyopaque, bo: gbm.Bo) !gbm.Metadata {
        return .{ .width = 1, .height = 1, .format = gbm.format_xrgb8888, .modifier = gbm.modifier_linear, .plane_count = 1, .handles = .{ @intCast(@intFromPtr(bo) & 0xffffffff), 0, 0, 0 }, .strides = .{ 4, 0, 0, 0 } };
    }
    fn exportPlaneFd(_: *anyopaque, _: gbm.Bo, _: u8) !std.posix.fd_t {
        return error.UnexpectedExport;
    }
    fn map(context: *anyopaque, bo: gbm.Bo, access: gbm.MapAccess) !gbm.Mapping {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        self.last_map_access = access;
        return .{ .data = @ptrCast(bo), .stride = 4, .token = bo };
    }
    fn unmap(_: *anyopaque, _: gbm.Bo, _: gbm.MapToken) void {}
    fn addFramebuffer(_: *anyopaque, _: std.posix.fd_t, metadata_value: gbm.Metadata) !u32 {
        return metadata_value.handles[0];
    }
    fn removeFramebuffer(context: *anyopaque, _: std.posix.fd_t, _: u32) !void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        if (self.framebuffers_removed == 0)
            self.pool_removal_started_before_bo = self.bos_destroyed == 0;
        self.framebuffers_removed += 1;
    }
    fn createDumb(
        context: *anyopaque,
        _: std.posix.fd_t,
        _: u32,
        _: u32,
        _: u32,
    ) !framebuffer.DumbBuffer {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        const index = self.bo_count;
        self.bo_count += 1;
        return .{
            .handle = @intCast(index + 1),
            .stride = 4,
            .bytes = &self.dumb_bytes[index],
        };
    }
    fn destroyDumb(context: *anyopaque, _: std.posix.fd_t, _: framebuffer.DumbBuffer) void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        self.bos_destroyed += 1;
    }
    fn createBlob(_: *anyopaque, _: std.posix.fd_t, _: drm.Mode) !u32 {
        return 1;
    }
    fn destroyBlob(_: *anyopaque, _: std.posix.fd_t, _: u32) !void {}
    fn createRequest(context: *anyopaque) !atomic.Request {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        const request = &self.requests[self.request_count];
        self.request_count += 1;
        return @ptrCast(request);
    }
    fn destroyRequest(_: *anyopaque, _: atomic.Request) void {}
    fn resetRequest(_: *anyopaque, _: atomic.Request) void {}
    fn addProperty(_: *anyopaque, _: atomic.Request, _: u32, _: u32, _: u64) !void {}
    fn commit(context: *anyopaque, _: std.posix.fd_t, _: atomic.Request, _: atomic.CommitFlags, userdata: ?*anyopaque) !void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        if (userdata) |value| self.flip_userdata = value;
    }
    fn handleEvents(context: *anyopaque, _: []const u8, callback: atomic.FlipCallback) !void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        const userdata = self.flip_userdata orelse return error.MissingFlip;
        self.flip_userdata = null;
        callback(userdata, 1, 2, 3000, 30);
    }
    fn presented(context: *anyopaque, outcome: FrameOutcome, callback_data: u32) !void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        try std.testing.expect(outcome.frame_callbacks_due);
        try std.testing.expect(outcome.output_removed);
        try std.testing.expectEqual(@as(usize, 0), outcome.sampled.len);
        try std.testing.expectEqual(@as(u32, 2003), callback_data);
        self.presented_count += 1;
    }
    fn unexpectedPresented(_: *anyopaque, _: FrameOutcome, _: u32) !void {
        return error.UnexpectedPresentation;
    }
    fn captured(
        context: *anyopaque,
        token: u64,
        success: bool,
        timestamp_ns: u64,
        readback: ?CaptureReadback,
    ) !void {
        const self: *SimFixture = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(u64, 77), token);
        try std.testing.expect(success);
        try std.testing.expectEqual(@as(u64, 2_003_000_000), timestamp_ns);
        try std.testing.expectEqual(@as(u32, 4), readback.?.stride);
        try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, readback.?.bytes);
        if (self.capture_backpressure) {
            self.capture_backpressure = false;
            return error.Exhausted;
        }
        self.captured_count += 1;
    }
    fn unexpectedRetired(_: *anyopaque, _: FrameOutcome) !void {
        return error.UnexpectedRetirement;
    }
};

test "drm-sim: client DMA-BUF import is read mapped and released" {
    var fixture: SimFixture = .{};
    const platform: gbm.Platform = .{ .context = &fixture, .vtable = &SimFixture.gbm_vtable };
    var source = try mapImportedSource(platform, &fixture, .{
        .width = 1,
        .height = 1,
        .format = gbm.format_xrgb8888,
        .modifier = gbm.modifier_linear,
        .plane_count = 1,
        .fds = .{ 9, -1, -1, -1 },
        .strides = .{ 4, 0, 0, 0 },
    });
    try std.testing.expectEqual(gbm.MapAccess.read, fixture.last_map_access.?);
    try std.testing.expectEqual(@as(usize, 4), source.bytes.len);
    try std.testing.expectEqual(@as(u32, 4), source.stride);
    source.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.bos_destroyed);
}

test "drm-sim: persistent DMA-BUF import cache reuses and boundedly evicts BOs" {
    var fixture: SimFixture = .{};
    const platform: gbm.Platform = .{ .context = &fixture, .vtable = &SimFixture.gbm_vtable };
    var cache: [2]CachedImport = @splat(.{});
    var output: Output = undefined;
    output.pool.gbm_platform = platform;
    output.pool.device = &fixture;
    output.import_cache = &cache;
    output.import_cache_cursor = 0;
    const descriptor: gbm.Import = .{
        .width = 1,
        .height = 1,
        .format = gbm.format_xrgb8888,
        .modifier = gbm.modifier_linear,
        .plane_count = 1,
        .fds = .{ 9, -1, -1, -1 },
        .strides = .{ 4, 0, 0, 0 },
    };
    const owner: *anyopaque = &fixture;

    var first = try output.mapClientBuffer(.{ .context = owner, .token = 1 }, descriptor);
    first.deinit();
    var reused = try output.mapClientBuffer(.{ .context = owner, .token = 1 }, descriptor);
    reused.deinit();
    try std.testing.expectEqual(@as(usize, 1), fixture.bo_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.bos_destroyed);

    var second = try output.mapClientBuffer(.{ .context = owner, .token = 2 }, descriptor);
    second.deinit();
    var third = try output.mapClientBuffer(.{ .context = owner, .token = 3 }, descriptor);
    third.deinit();
    try std.testing.expectEqual(@as(usize, 3), fixture.bo_count);
    try std.testing.expectEqual(@as(usize, 1), fixture.bos_destroyed);

    var changed = descriptor;
    changed.strides[0] = 8;
    try std.testing.expectError(
        error.ImportIdentityMismatch,
        output.mapClientBuffer(.{ .context = owner, .token = 3 }, changed),
    );
    for (&cache) |*entry| output.destroyCachedImport(entry);
    try std.testing.expectEqual(@as(usize, 3), fixture.bos_destroyed);
}

fn startSimFrame(output: *Output, now_ns: u64, handle: timer.Handle) !scheduler_api.FrameId {
    try output.request(.damage, now_ns);
    const request_value = (try output.timerRequest(now_ns)).?;
    try output.timerArmed(request_value, handle, now_ns);
    return (try output.timerEvent(handle, .fired, request_value.frame.sequence + now_ns + 5)).?.frame;
}

fn drainIdleSimOutput(output: *Output, fixture: *SimFixture) !void {
    try std.testing.expect((try output.requestPause()) == null);
    const callbacks: WaylandCallbacks = .{
        .context = fixture,
        .presented_fn = SimFixture.unexpectedPresented,
        .retired_fn = SimFixture.unexpectedRetired,
    };
    try output.processKmsEvents(callbacks);
    try output.beginDrain(&fixture.router, &fixture.ring);
    try output.processKmsEvents(callbacks);
    try output.destroy();
}
