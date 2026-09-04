//! Replaceable Vulkan ABI boundary. Borrowed source rows are synchronously
//! packed into target-owned mapped storage; renderer policy never sees a Vulkan
//! object. DMA-BUF and sync_file FD ownership remains explicit.

const std = @import("std");
const linux = std.os.linux;
const gbm = @import("../backend/gbm.zig");
const render = @import("types.zig");
const render_content = @import("content.zig");
const icc = @import("icc.zig");

const c = @cImport({
    @cInclude("drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("linux/sync_file.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/sysmacros.h");
    @cInclude("sys/stat.h");
    @cInclude("vulkan/vulkan.h");
});

pub const Renderer = *anyopaque;
pub const Target = *anyopaque;
pub const CaptureTarget = *anyopaque;

pub const Config = struct {
    max_samples: usize,
    max_color_luts: usize,
    max_source_bytes: usize,
    max_targets: usize,
    content_bytes: usize = 1,
    content_allocations: usize = 1,
    require_color_management: bool = false,
};

/// Exact std430 ABI consumed by `vulkan_composite.comp`.
pub const Sample = extern struct {
    source: [4]u32,
    crop: [4]i32,
    destination: [4]i32,
    clip: [4]i32,
    attributes: [4]u32,
    affine: [4]i32,
    affine_tail: [4]i32,
    color_matrix_0: [4]f32,
    color_matrix_1: [4]f32,
    color_matrix_2: [4]f32,
};

pub const CapturePhase = enum { before_cursor, after_cursor };

pub const Captures = packed struct(u2) {
    before_cursor: bool = false,
    after_cursor: bool = false,
};

pub const Readback = struct {
    bytes: []const u8,
    stride: u32,
};

pub const CaptureDestination = struct {
    target: CaptureTarget,
    source: render.Rect,
};

pub const Frame = struct {
    output: render.Size,
    output_transform: render.Transform = .normal,
    output_format: render.PixelFormat,
    output_color_description: render.color.Description = .srgb,
    output_lut_slot: ?u32 = null,
    clear: render.Color,
    samples: []const Sample,
    sources: []const render.SurfaceSample,
    source_byte_count: usize,
    render_damage: []const render.Rect,
    cursor_start: usize = 0,
    captures: Captures = .{},
    capture_destination: ?CaptureDestination = null,
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, std.posix.fd_t, Config) anyerror!Renderer,
        destroy: *const fn (*anyopaque, Renderer) void,
        import_target: *const fn (*anyopaque, Renderer, gbm.Metadata, std.posix.fd_t) anyerror!Target,
        destroy_target: *const fn (*anyopaque, Renderer, Target) void,
        supports_capture_target: *const fn (*anyopaque, Renderer, gbm.Metadata) bool,
        import_capture_target: *const fn (*anyopaque, Renderer, gbm.Metadata, std.posix.fd_t) anyerror!CaptureTarget,
        prepare_capture_target: *const fn (*anyopaque, Renderer, CaptureTarget, std.posix.fd_t) anyerror!void,
        destroy_capture_target: *const fn (*anyopaque, Renderer, CaptureTarget) void,
        draw: *const fn (*anyopaque, Renderer, Target, Frame) anyerror!std.posix.fd_t,
        readback: *const fn (*anyopaque, Renderer, Target, CapturePhase) anyerror!Readback,
        content_provider: *const fn (*anyopaque, Renderer) ?render_content.Provider,
        validate_external: *const fn (*anyopaque, Renderer, render.ExternalSource, render.Size, render.PixelFormat) anyerror!void,
        sampled_dmabuf_formats: *const fn (*anyopaque, Renderer, []gbm.FormatModifier) anyerror!usize,
        packs_sources: *const fn (*anyopaque, Renderer) bool,
        cache_lut: *const fn (*anyopaque, Renderer, *const icc.Lut) anyerror!u32,
    };

    pub fn create(self: Platform, fd: std.posix.fd_t, config: Config) !Renderer {
        return self.vtable.create(self.context, fd, config);
    }
    pub fn destroy(self: Platform, renderer: Renderer) void {
        self.vtable.destroy(self.context, renderer);
    }
    pub fn importTarget(self: Platform, renderer: Renderer, metadata: gbm.Metadata, fd: std.posix.fd_t) !Target {
        // The implementation takes FD ownership on every outcome.
        return self.vtable.import_target(self.context, renderer, metadata, fd);
    }
    pub fn destroyTarget(self: Platform, renderer: Renderer, target: Target) void {
        self.vtable.destroy_target(self.context, renderer, target);
    }
    pub fn importCaptureTarget(self: Platform, renderer: Renderer, metadata: gbm.Metadata, fd: std.posix.fd_t) !CaptureTarget {
        // The implementation takes FD ownership on every outcome.
        return self.vtable.import_capture_target(self.context, renderer, metadata, fd);
    }
    pub fn supportsCaptureTarget(self: Platform, renderer: Renderer, metadata: gbm.Metadata) bool {
        return self.vtable.supports_capture_target(self.context, renderer, metadata);
    }
    pub fn prepareCaptureTarget(self: Platform, renderer: Renderer, target: CaptureTarget, fd: std.posix.fd_t) !void {
        return self.vtable.prepare_capture_target(self.context, renderer, target, fd);
    }
    pub fn destroyCaptureTarget(self: Platform, renderer: Renderer, target: CaptureTarget) void {
        self.vtable.destroy_capture_target(self.context, renderer, target);
    }
    pub fn draw(self: Platform, renderer: Renderer, target: Target, frame: Frame) !std.posix.fd_t {
        return self.vtable.draw(self.context, renderer, target, frame);
    }
    pub fn readback(self: Platform, renderer: Renderer, target: Target, phase: CapturePhase) !Readback {
        return self.vtable.readback(self.context, renderer, target, phase);
    }
    pub fn contentProvider(self: Platform, renderer: Renderer) ?render_content.Provider {
        return self.vtable.content_provider(self.context, renderer);
    }
    pub fn validateExternal(
        self: Platform,
        renderer: Renderer,
        source: render.ExternalSource,
        size: render.Size,
        format: render.PixelFormat,
    ) !void {
        try self.vtable.validate_external(self.context, renderer, source, size, format);
    }
    pub fn sampledDmabufFormats(
        self: Platform,
        renderer: Renderer,
        output: []gbm.FormatModifier,
    ) ![]const gbm.FormatModifier {
        const count = try self.vtable.sampled_dmabuf_formats(
            self.context,
            renderer,
            output,
        );
        if (count > output.len) return error.InvalidPlatformResult;
        return output[0..count];
    }
    pub fn packsSources(self: Platform, renderer: Renderer) bool {
        return self.vtable.packs_sources(self.context, renderer);
    }
    pub fn cacheLut(self: Platform, renderer: Renderer, lut: *const icc.Lut) !u32 {
        return self.vtable.cache_lut(self.context, renderer, lut);
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create = realCreate,
    .destroy = realDestroy,
    .import_target = realImportTarget,
    .destroy_target = realDestroyTarget,
    .supports_capture_target = realSupportsCaptureTarget,
    .import_capture_target = realImportCaptureTarget,
    .prepare_capture_target = realPrepareCaptureTarget,
    .destroy_capture_target = realDestroyCaptureTarget,
    .draw = realDraw,
    .readback = realReadback,
    .content_provider = realContentProvider,
    .validate_external = realValidateExternal,
    .sampled_dmabuf_formats = realSampledDmabufFormats,
    .packs_sources = realPacksSources,
    .cache_lut = realCacheLut,
};

const device_extensions = [_][*:0]const u8{
    c.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    c.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    c.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    c.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME,
    c.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    c.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
};

const sampled_image_capacity = 32;
pub const direct_color_bit: u32 = 1 << 31;
pub const direct_content_bit: u32 = 1 << 30;

const Texture = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    size: render.Size,
    initialized: bool = false,
};

const CacheEntry = struct {
    occupied: bool = false,
    surface: u64 = 0,
    commit_sequence: u64 = 0,
    format: render.PixelFormat = .xrgb8888,
    texture: Texture = undefined,
};

const UploadAllocation = struct {
    active: bool = false,
    generation: u32 = 0,
    offset: usize = 0,
    size: usize = 0,
    references: usize = 0,
};

const NativeAllocation = struct {
    active: bool = false,
    generation: u32 = 0,
    references: usize = 0,
    texture: Texture = undefined,
    ready: ?render.SampleIdentity = null,
};

const ImportedImage = struct {
    occupied: bool = false,
    generation: u32 = 0,
    references: usize = 0,
    source: render.ExternalSource = undefined,
    image: c.VkImage = undefined,
    memory: c.VkDeviceMemory = undefined,
    view: c.VkImageView = undefined,
};

const PendingAcquire = struct {
    occupied: bool = false,
    native_token: u64 = 0,
    identity: render.SampleIdentity = undefined,
    imported_token: u64 = 0,
    fd: std.posix.fd_t = -1,
};

fn growRecords(comptime T: type, records: *[]T) !usize {
    if (records.len >= std.math.maxInt(u32)) return error.CapacityExceeded;
    const old_len = records.len;
    const doubled = std.math.mul(usize, old_len, 2) catch std.math.maxInt(u32);
    const new_len = @min(@max(old_len + 1, doubled), std.math.maxInt(u32));
    records.* = try std.heap.c_allocator.realloc(records.*, new_len);
    @memset(records.*[old_len..], .{});
    return old_len;
}

const Upload = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    staging_offset: usize,
    row_length: u32,
    direct: bool,
};

const PreparedTexture = struct {
    cache_index: usize,
    source_index: usize,
    texture: Texture,
    created: bool,
    retire_previous: bool,
    uploads: [render.upload_damage_rect_capacity]Upload = undefined,
    upload_count: u8 = 0,
    surface: u64,
    commit_sequence: u64,
    format: render.PixelFormat,
    content_token: ?u64 = null,
    native_token: ?u64 = null,
    imported_token: ?u64 = null,
    direct_external: bool = false,
};

const RealRenderer = struct {
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    queue: c.VkQueue,
    queue_family: u32,
    memory: c.VkPhysicalDeviceMemoryProperties,
    descriptor_layout: c.VkDescriptorSetLayout,
    pipeline_layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    descriptor_pool: c.VkDescriptorPool,
    sampled_pipeline: ?c.VkPipeline,
    sampler: ?c.VkSampler,
    blur_pipeline: ?c.VkPipeline,
    blur_sampler: ?c.VkSampler,
    cache: []CacheEntry,
    prepared: []PreparedTexture,
    sampled_enabled: bool,
    get_memory_fd_properties: c.PFN_vkGetMemoryFdPropertiesKHR,
    get_semaphore_fd: c.PFN_vkGetSemaphoreFdKHR,
    import_semaphore_fd: c.PFN_vkImportSemaphoreFdKHR,
    max_samples: usize,
    sample_buffer_size: usize,
    sample_region_alignment: usize,
    max_source_bytes: usize,
    copy_offset_alignment: usize,
    staging_buffer_size: usize,
    content_buffer: c.VkBuffer,
    content_memory: c.VkDeviceMemory,
    content_map: *anyopaque,
    content_buffer_size: usize,
    content_allocations: []UploadAllocation,
    native_allocations: []NativeAllocation,
    imported_images: []ImportedImage,
    imported_cursor: usize,
    pending_acquires: []PendingAcquire,
    lut_buffer: c.VkBuffer,
    lut_memory: c.VkDeviceMemory,
    lut_map: *anyopaque,
    lut_hashes: [][32]u8,
    lut_count: usize,
    resource_epoch: u64,
};

const TargetState = enum { ready, in_flight, queue_failed, export_failed };

const RealTarget = struct {
    image: c.VkImage,
    image_memory: c.VkDeviceMemory,
    view: c.VkImageView,
    linear_image: c.VkImage,
    linear_memory: c.VkDeviceMemory,
    linear_view: c.VkImageView,
    blur_image: c.VkImage,
    blur_memory: c.VkDeviceMemory,
    blur_view: c.VkImageView,
    blur_initialized_layout: bool = false,
    sample_buffer: c.VkBuffer,
    sample_memory: c.VkDeviceMemory,
    sample_map: *anyopaque,
    source_buffer: c.VkBuffer,
    source_memory: c.VkDeviceMemory,
    source_map: *anyopaque,
    source_buffer_size: usize,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_sets: []c.VkDescriptorSet,
    batch_capacity: usize,
    sample_buffer_size: usize,
    command_pool: c.VkCommandPool,
    command_buffer: c.VkCommandBuffer,
    fence: c.VkFence,
    semaphore: c.VkSemaphore,
    source_semaphore: c.VkSemaphore,
    acquire_semaphores: []c.VkSemaphore,
    retired_textures: []Texture,
    retired_texture_count: usize = 0,
    width: u32,
    height: u32,
    state: TargetState = .ready,
    fence_needs_reset: bool = false,
    initialized_layout: bool = false,
    content_leases: []u64,
    content_lease_count: usize = 0,
    native_leases: []u64,
    native_lease_count: usize = 0,
    imported_leases: []u64,
    imported_lease_count: usize = 0,
    readback_buffers: [2]c.VkBuffer,
    readback_memories: [2]c.VkDeviceMemory,
    readback_maps: [2]*anyopaque,
    readback_size: usize,
    captured: Captures = .{},
    recorded_sampled_frame: RecordedSampledFrame = .{},
};

const RealCaptureTarget = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    acquire_semaphore: c.VkSemaphore,
    completion_fence: ?c.VkFence,
    width: u32,
    height: u32,
};

const RecordedPreparedTexture = struct {
    image: c.VkImage,
    view: c.VkImageView,
    initialized: bool,
    first_upload: usize,
    upload_count: usize,
};

/// Exact command-buffer inputs for ordinary sampled SHM composition. Pixel
/// bytes live in coherent mapped buffers and may change between submissions.
/// Packed samples are conservatively compared in full because their geometry
/// determines the recorded dispatch topology.
const RecordedSampledFrame = struct {
    valid: bool = false,
    resource_epoch: u64 = 0,
    target_initialized: bool = false,
    output: render.Size = .{ .width = 0, .height = 0 },
    output_format: render.PixelFormat = .xrgb8888,
    output_transfer: render.color.TransferFunction = .srgb,
    output_reference_luminance: u32 = 0,
    output_lut_slot: ?u32 = null,
    clear: render.Color = .{ .r = 0, .g = 0, .b = 0 },
    samples: std.ArrayList(Sample) = .empty,
    damage: std.ArrayList(render.Rect) = .empty,
    prepared: std.ArrayList(RecordedPreparedTexture) = .empty,
    uploads: std.ArrayList(Upload) = .empty,
    descriptor_views: std.ArrayList(c.VkImageView) = .empty,

    fn deinit(self: *RecordedSampledFrame, allocator: std.mem.Allocator) void {
        self.samples.deinit(allocator);
        self.damage.deinit(allocator);
        self.prepared.deinit(allocator);
        self.uploads.deinit(allocator);
        self.descriptor_views.deinit(allocator);
        self.* = undefined;
    }

    fn matches(
        self: *const RecordedSampledFrame,
        renderer: *const RealRenderer,
        target: *const RealTarget,
        frame: Frame,
        prepared_batch: []const PreparedTexture,
    ) bool {
        if (!self.valid or
            self.resource_epoch != renderer.resource_epoch or
            self.target_initialized != target.initialized_layout or
            !std.meta.eql(self.output, frame.output) or
            self.output_format != frame.output_format or
            self.output_transfer != frame.output_color_description.transfer or
            self.output_reference_luminance != @as(u32, @bitCast(frame.output_color_description.reference_luminance)) or
            self.output_lut_slot != frame.output_lut_slot or
            !std.meta.eql(self.clear, frame.clear) or
            self.samples.items.len != frame.samples.len or
            self.damage.items.len != frame.render_damage.len or
            self.prepared.items.len != prepared_batch.len or
            self.descriptor_views.items.len != frame.sources.len)
            return false;
        if (!std.mem.eql(
            u8,
            std.mem.sliceAsBytes(self.samples.items),
            std.mem.sliceAsBytes(frame.samples),
        )) return false;
        for (self.damage.items, frame.render_damage) |recorded, current|
            if (!std.meta.eql(recorded, current)) return false;

        var upload_index: usize = 0;
        for (self.prepared.items, prepared_batch) |recorded, current| {
            if (recorded.image != current.texture.image or
                recorded.view != current.texture.view or
                recorded.initialized != current.texture.initialized or
                recorded.first_upload != upload_index or
                recorded.upload_count != current.upload_count)
                return false;
            for (current.uploads[0..current.upload_count]) |upload| {
                if (upload_index >= self.uploads.items.len or
                    !std.meta.eql(self.uploads.items[upload_index], upload))
                    return false;
                upload_index += 1;
            }
        }
        if (upload_index != self.uploads.items.len) return false;
        for (frame.sources, self.descriptor_views.items) |surface, recorded_view| {
            const index = preparedIndex(prepared_batch, surface.sample.surface) orelse
                return false;
            if (recorded_view != prepared_batch[index].texture.view) return false;
        }
        return true;
    }

    fn replace(
        self: *RecordedSampledFrame,
        allocator: std.mem.Allocator,
        renderer: *const RealRenderer,
        target: *const RealTarget,
        frame: Frame,
        prepared_batch: []const PreparedTexture,
    ) !void {
        self.valid = false;
        self.samples.clearRetainingCapacity();
        self.damage.clearRetainingCapacity();
        self.prepared.clearRetainingCapacity();
        self.uploads.clearRetainingCapacity();
        self.descriptor_views.clearRetainingCapacity();
        try self.samples.appendSlice(allocator, frame.samples);
        try self.damage.appendSlice(allocator, frame.render_damage);
        for (prepared_batch) |current| {
            try self.prepared.append(allocator, .{
                .image = current.texture.image,
                .view = current.texture.view,
                .initialized = current.texture.initialized,
                .first_upload = self.uploads.items.len,
                .upload_count = current.upload_count,
            });
            try self.uploads.appendSlice(allocator, current.uploads[0..current.upload_count]);
        }
        for (frame.sources) |surface| {
            const index = preparedIndex(prepared_batch, surface.sample.surface) orelse
                return error.InvalidSampleSource;
            try self.descriptor_views.append(allocator, prepared_batch[index].texture.view);
        }
        self.resource_epoch = renderer.resource_epoch;
        self.target_initialized = target.initialized_layout;
        self.output = frame.output;
        self.output_format = frame.output_format;
        self.output_transfer = frame.output_color_description.transfer;
        self.output_reference_luminance = @bitCast(frame.output_color_description.reference_luminance);
        self.output_lut_slot = frame.output_lut_slot;
        self.clear = frame.clear;
        self.valid = true;
    }
};

const Push = extern struct {
    clear_color: [4]u32,
    output: [4]u32,
    damage: [4]u32,
    output_color: [4]u32,
};

const continuation_bit: u32 = 0x80000000;
const intermediate_bit: u32 = 0x40000000;
const sample_count_mask: u32 = ~(continuation_bit | intermediate_bit);

const Batch = struct { first: usize, count: usize, initialize: bool };

fn batchAt(total: usize, capacity: usize, index: usize) Batch {
    const first = index * capacity;
    return .{ .first = first, .count = @min(capacity, total - first), .initialize = index == 0 };
}

fn realCreate(_: *anyopaque, drm_fd: std.posix.fd_t, config: Config) !Renderer {
    const allocator = std.heap.c_allocator;
    const self = try allocator.create(RealRenderer);
    errdefer allocator.destroy(self);

    var app: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "ouro",
        .applicationVersion = 1,
        .pEngineName = "ouro",
        .engineVersion = 1,
        .apiVersion = c.VK_API_VERSION_1_2,
    };
    const instance_extensions = [_][*:0]const u8{c.VK_KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME};
    var instance_info: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = instance_extensions.len,
        .ppEnabledExtensionNames = &instance_extensions,
    };
    try vk(c.vkCreateInstance(&instance_info, null, &self.instance), error.CreateInstanceFailed);
    errdefer c.vkDestroyInstance(self.instance, null);

    self.physical_device = try choosePhysicalDevice(self.instance, drm_fd);
    try requireDeviceExtensions(self.physical_device);
    self.queue_family = try chooseQueueFamily(self.physical_device);
    c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &self.memory);
    var physical_properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(self.physical_device, &physical_properties);
    var physical_features: c.VkPhysicalDeviceFeatures = undefined;
    c.vkGetPhysicalDeviceFeatures(self.physical_device, &physical_features);
    var source_format: c.VkFormatProperties = undefined;
    c.vkGetPhysicalDeviceFormatProperties(
        self.physical_device,
        c.VK_FORMAT_B8G8R8A8_UNORM,
        &source_format,
    );
    const sample_size = std.math.mul(usize, config.max_samples, @sizeOf(Sample)) catch
        return error.InvalidConfig;
    const descriptor_count = std.math.mul(usize, config.max_targets, 3) catch
        return error.InvalidConfig;
    const storage_image_count = std.math.mul(usize, config.max_targets, 3) catch
        return error.InvalidConfig;
    const lut_texels = std.math.mul(usize, config.max_color_luts, icc.texel_count) catch
        return error.InvalidConfig;
    const lut_buffer_size = std.math.mul(usize, lut_texels, @sizeOf([4]f32)) catch
        return error.InvalidConfig;
    const sampled_descriptor_count = std.math.mul(
        usize,
        config.max_targets,
        sampled_image_capacity + 2,
    ) catch return error.InvalidConfig;
    if (physical_properties.apiVersion < c.VK_API_VERSION_1_2 or
        sample_size == 0 or sample_size > physical_properties.limits.maxStorageBufferRange or
        config.max_source_bytes == 0 or config.max_color_luts == 0 or
        config.max_color_luts > std.math.maxInt(i32) or
        lut_buffer_size == 0 or lut_buffer_size > physical_properties.limits.maxStorageBufferRange or
        config.max_source_bytes > physical_properties.limits.maxStorageBufferRange or
        config.content_bytes == 0 or config.content_allocations == 0 or
        config.content_allocations > std.math.maxInt(u32) or
        config.max_targets == 0 or config.max_targets > std.math.maxInt(u32) or
        descriptor_count > std.math.maxInt(u32) or
        storage_image_count > std.math.maxInt(u32) or
        physical_properties.limits.maxPerStageDescriptorStorageBuffers < 4 or
        physical_properties.limits.maxDescriptorSetStorageBuffers < 4 or
        physical_properties.limits.maxPerStageDescriptorStorageImages < 3 or
        physical_properties.limits.maxDescriptorSetStorageImages < 3)
        return error.InvalidConfig;
    self.sampled_enabled = config.max_samples <= sampled_image_capacity and
        sampled_descriptor_count <= std.math.maxInt(u32) and
        physical_features.shaderSampledImageArrayDynamicIndexing == c.VK_TRUE and
        physical_properties.limits.maxPerStageDescriptorSampledImages >= sampled_image_capacity + 2 and
        physical_properties.limits.maxDescriptorSetSampledImages >= sampled_image_capacity + 2 and
        physical_properties.limits.maxPerStageDescriptorSamplers >= sampled_image_capacity + 2 and
        physical_properties.limits.maxDescriptorSetSamplers >= sampled_image_capacity + 2 and
        source_format.optimalTilingFeatures &
            (c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT) ==
            (c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT);
    if (config.require_color_management and !self.sampled_enabled)
        return error.ColorManagementUnavailable;
    try requireSyncFdSemaphore(self.physical_device);
    const priority: f32 = 1;
    var queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = self.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var enabled_features: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);
    enabled_features.shaderSampledImageArrayDynamicIndexing = if (self.sampled_enabled)
        c.VK_TRUE
    else
        c.VK_FALSE;
    var device_info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = device_extensions.len,
        .ppEnabledExtensionNames = &device_extensions,
        .pEnabledFeatures = &enabled_features,
    };
    try vk(c.vkCreateDevice(self.physical_device, &device_info, null, &self.device), error.CreateDeviceFailed);
    errdefer c.vkDestroyDevice(self.device, null);
    c.vkGetDeviceQueue(self.device, self.queue_family, 0, &self.queue);
    self.get_memory_fd_properties = @ptrCast(c.vkGetDeviceProcAddr(self.device, "vkGetMemoryFdPropertiesKHR") orelse return error.MissingMemoryFdPropertiesFunction);
    self.get_semaphore_fd = @ptrCast(c.vkGetDeviceProcAddr(self.device, "vkGetSemaphoreFdKHR") orelse return error.MissingSemaphoreFdFunction);
    self.import_semaphore_fd = @ptrCast(c.vkGetDeviceProcAddr(self.device, "vkImportSemaphoreFdKHR") orelse return error.MissingSemaphoreFdFunction);

    const bindings = [_]c.VkDescriptorSetLayoutBinding{
        descriptorBinding(0, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
        descriptorBinding(1, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        descriptorBinding(2, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        descriptorBinding(4, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        descriptorBinding(5, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
        descriptorBinding(6, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER),
        .{
            .binding = 3,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = sampled_image_capacity,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
        descriptorBinding(7, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE),
        descriptorBinding(8, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
        descriptorBinding(9, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER),
    };
    var descriptor_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = if (self.sampled_enabled) bindings.len else 6,
        .pBindings = &bindings,
    };
    try vk(c.vkCreateDescriptorSetLayout(self.device, &descriptor_info, null, &self.descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
    var push_range: c.VkPushConstantRange = .{ .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = @sizeOf(Push) };
    var layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &self.descriptor_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    try vk(c.vkCreatePipelineLayout(self.device, &layout_info, null, &self.pipeline_layout), error.CreatePipelineLayoutFailed);
    errdefer c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    const shader_bytes align(@alignOf(u32)) = @embedFile("vulkan_composite.spv").*;
    var shader_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = shader_bytes.len,
        .pCode = @ptrCast(&shader_bytes),
    };
    var shader: c.VkShaderModule = undefined;
    try vk(c.vkCreateShaderModule(self.device, &shader_info, null, &shader), error.CreateShaderFailed);
    defer c.vkDestroyShaderModule(self.device, shader, null);
    var pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = .{ .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = c.VK_SHADER_STAGE_COMPUTE_BIT, .module = shader, .pName = "main", .pSpecializationInfo = null },
        .layout = self.pipeline_layout,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    try vk(c.vkCreateComputePipelines(self.device, null, 1, &pipeline_info, null, &self.pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(self.device, self.pipeline, null);
    self.sampled_pipeline = null;
    self.blur_pipeline = null;
    if (self.sampled_enabled) {
        const sampled_shader_bytes align(@alignOf(u32)) = @embedFile("vulkan_texture_composite.spv").*;
        var sampled_shader_info = shader_info;
        sampled_shader_info.codeSize = sampled_shader_bytes.len;
        sampled_shader_info.pCode = @ptrCast(&sampled_shader_bytes);
        var sampled_shader: c.VkShaderModule = undefined;
        try vk(
            c.vkCreateShaderModule(self.device, &sampled_shader_info, null, &sampled_shader),
            error.CreateShaderFailed,
        );
        defer c.vkDestroyShaderModule(self.device, sampled_shader, null);
        var sampled_pipeline_info = pipeline_info;
        sampled_pipeline_info.stage.module = sampled_shader;
        var sampled_pipeline: c.VkPipeline = undefined;
        try vk(
            c.vkCreateComputePipelines(
                self.device,
                null,
                1,
                &sampled_pipeline_info,
                null,
                &sampled_pipeline,
            ),
            error.CreatePipelineFailed,
        );
        self.sampled_pipeline = sampled_pipeline;

        const blur_shader_bytes align(@alignOf(u32)) = @embedFile("vulkan_backdrop_blur.spv").*;
        var blur_shader_info = shader_info;
        blur_shader_info.codeSize = blur_shader_bytes.len;
        blur_shader_info.pCode = @ptrCast(&blur_shader_bytes);
        var blur_shader: c.VkShaderModule = undefined;
        try vk(c.vkCreateShaderModule(self.device, &blur_shader_info, null, &blur_shader), error.CreateShaderFailed);
        defer c.vkDestroyShaderModule(self.device, blur_shader, null);
        var blur_pipeline_info = pipeline_info;
        blur_pipeline_info.stage.module = blur_shader;
        var blur_pipeline: c.VkPipeline = undefined;
        try vk(c.vkCreateComputePipelines(self.device, null, 1, &blur_pipeline_info, null, &blur_pipeline), error.CreatePipelineFailed);
        self.blur_pipeline = blur_pipeline;
    }
    errdefer if (self.sampled_pipeline) |pipeline|
        c.vkDestroyPipeline(self.device, pipeline, null);
    errdefer if (self.blur_pipeline) |pipeline|
        c.vkDestroyPipeline(self.device, pipeline, null);
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = @intCast(storage_image_count) },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = @intCast(descriptor_count) },
        .{
            .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = if (self.sampled_enabled)
                @intCast(sampled_descriptor_count)
            else
                0,
        },
    };
    var pool_info: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = @intCast(config.max_targets),
        .poolSizeCount = if (self.sampled_enabled) pool_sizes.len else pool_sizes.len - 1,
        .pPoolSizes = &pool_sizes,
    };
    try vk(c.vkCreateDescriptorPool(self.device, &pool_info, null, &self.descriptor_pool), error.CreateDescriptorPoolFailed);
    errdefer c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    self.sampler = null;
    self.blur_sampler = null;
    self.cache = &.{};
    self.prepared = &.{};
    if (self.sampled_enabled) {
        var sampler_info: c.VkSamplerCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = c.VK_FILTER_NEAREST,
            .minFilter = c.VK_FILTER_NEAREST,
            .mipmapMode = c.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0,
            .anisotropyEnable = c.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = c.VK_FALSE,
            .compareOp = c.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = c.VK_BORDER_COLOR_INT_OPAQUE_BLACK,
            .unnormalizedCoordinates = c.VK_FALSE,
        };
        var sampler: c.VkSampler = undefined;
        try vk(c.vkCreateSampler(self.device, &sampler_info, null, &sampler), error.CreateSamplerFailed);
        self.sampler = sampler;
        errdefer c.vkDestroySampler(self.device, sampler, null);
        sampler_info.magFilter = c.VK_FILTER_LINEAR;
        sampler_info.minFilter = c.VK_FILTER_LINEAR;
        var blur_sampler: c.VkSampler = undefined;
        try vk(c.vkCreateSampler(self.device, &sampler_info, null, &blur_sampler), error.CreateSamplerFailed);
        self.blur_sampler = blur_sampler;
        errdefer c.vkDestroySampler(self.device, blur_sampler, null);
        self.cache = try allocator.alloc(CacheEntry, config.max_samples);
        @memset(self.cache, .{});
        errdefer allocator.free(self.cache);
        self.prepared = try allocator.alloc(PreparedTexture, config.max_samples);
        errdefer allocator.free(self.prepared);
    }
    self.max_samples = config.max_samples;
    self.sample_buffer_size = sample_size;
    self.sample_region_alignment = @max(
        @as(usize, @intCast(physical_properties.limits.minStorageBufferOffsetAlignment)),
        @alignOf(Sample),
    );
    self.max_source_bytes = config.max_source_bytes;
    self.copy_offset_alignment = @max(
        @as(usize, @intCast(physical_properties.limits.optimalBufferCopyOffsetAlignment)),
        @alignOf(u32),
    );
    self.staging_buffer_size = std.math.add(
        usize,
        config.max_source_bytes,
        std.math.mul(
            usize,
            std.math.mul(
                usize,
                config.max_samples,
                render.upload_damage_rect_capacity,
            ) catch return error.InvalidConfig,
            self.copy_offset_alignment - 1,
        ) catch return error.InvalidConfig,
    ) catch return error.InvalidConfig;
    self.content_buffer_size = std.math.add(
        usize,
        config.content_bytes,
        std.math.mul(
            usize,
            config.content_allocations,
            self.copy_offset_alignment - 1,
        ) catch return error.InvalidConfig,
    ) catch return error.InvalidConfig;
    self.content_allocations = try allocator.alloc(UploadAllocation, config.content_allocations);
    @memset(self.content_allocations, .{});
    errdefer allocator.free(self.content_allocations);
    self.native_allocations = try allocator.alloc(NativeAllocation, config.content_allocations);
    @memset(self.native_allocations, .{});
    errdefer allocator.free(self.native_allocations);
    const imported_capacity = std.math.mul(usize, config.content_allocations, 2) catch
        return error.InvalidConfig;
    self.imported_images = try allocator.alloc(ImportedImage, imported_capacity);
    @memset(self.imported_images, .{});
    self.imported_cursor = 0;
    errdefer allocator.free(self.imported_images);
    self.pending_acquires = try allocator.alloc(PendingAcquire, config.content_allocations);
    @memset(self.pending_acquires, .{});
    errdefer allocator.free(self.pending_acquires);
    self.lut_hashes = try allocator.alloc([32]u8, config.max_color_luts);
    errdefer allocator.free(self.lut_hashes);
    self.lut_count = 0;
    self.resource_epoch = 1;
    try createHostBuffer(self, lut_buffer_size, &self.lut_buffer, &self.lut_memory, &self.lut_map);
    errdefer destroyBuffer(self, self.lut_buffer, self.lut_memory);
    try createHostBuffer(
        self,
        self.content_buffer_size,
        &self.content_buffer,
        &self.content_memory,
        &self.content_map,
    );
    return @ptrCast(self);
}

fn realDestroy(_: *anyopaque, renderer: Renderer) void {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    _ = c.vkDeviceWaitIdle(self.device);
    for (self.content_allocations) |allocation|
        std.debug.assert(!allocation.active);
    for (self.native_allocations) |allocation| {
        std.debug.assert(!allocation.active);
        if (allocation.generation != 0) destroyTexture(self, allocation.texture);
    }
    std.heap.c_allocator.free(self.native_allocations);
    for (self.imported_images) |*image| {
        std.debug.assert(!image.occupied or image.references == 1);
        destroyImportedImage(self, image);
    }
    std.heap.c_allocator.free(self.imported_images);
    for (self.pending_acquires) |pending| std.debug.assert(!pending.occupied);
    std.heap.c_allocator.free(self.pending_acquires);
    destroyBuffer(self, self.lut_buffer, self.lut_memory);
    std.heap.c_allocator.free(self.lut_hashes);
    destroyBuffer(self, self.content_buffer, self.content_memory);
    std.heap.c_allocator.free(self.content_allocations);
    for (self.cache) |entry| if (entry.occupied) destroyTexture(self, entry.texture);
    std.heap.c_allocator.free(self.prepared);
    std.heap.c_allocator.free(self.cache);
    if (self.sampler) |sampler| c.vkDestroySampler(self.device, sampler, null);
    if (self.blur_sampler) |sampler| c.vkDestroySampler(self.device, sampler, null);
    c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    if (self.sampled_pipeline) |pipeline| c.vkDestroyPipeline(self.device, pipeline, null);
    if (self.blur_pipeline) |pipeline| c.vkDestroyPipeline(self.device, pipeline, null);
    c.vkDestroyPipeline(self.device, self.pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroyInstance(self.instance, null);
    std.heap.c_allocator.destroy(self);
}

fn realContentProvider(_: *anyopaque, renderer: Renderer) ?render_content.Provider {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    if (!self.sampled_enabled) return null;
    return .{
        .context = self,
        .allocate_fn = allocateContent,
        .release_fn = releaseContentOwner,
        .pinned_fn = contentPinned,
        .allocate_native_fn = allocateNative,
        .prepare_native_fn = prepareNative,
        .cancel_native_fn = cancelNative,
        .release_native_fn = releaseNativeOwner,
        .pinned_native_fn = nativePinned,
        .ready_native_fn = nativeReady,
        .validate_retained_external_fn = validateRetainedExternal,
    };
}

fn realCacheLut(_: *anyopaque, renderer: Renderer, lut: *const icc.Lut) !u32 {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    if (lut.rgba.len != icc.texel_count) return error.InvalidColorLut;
    for (self.lut_hashes[0..self.lut_count], 0..) |hash, slot|
        if (std.mem.eql(u8, &hash, &lut.lut_hash)) return @intCast(slot);
    if (self.lut_count == self.lut_hashes.len) return error.ColorLutCapacityExceeded;
    const slot = self.lut_count;
    const output = @as([*][4]f32, @ptrCast(@alignCast(self.lut_map)))[slot * icc.texel_count .. (slot + 1) * icc.texel_count];
    for (lut.rgba, output) |source, *destination|
        destination.* = .{ source[0], source[1], source[2], source[3] };
    self.lut_hashes[slot] = lut.lut_hash;
    self.lut_count += 1;
    return @intCast(slot);
}

fn realPacksSources(_: *anyopaque, renderer: Renderer) bool {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    return !self.sampled_enabled;
}

fn prepareNative(
    context: *anyopaque,
    native: render.NativeBacking,
    identity: render.SampleIdentity,
    source: render.ExternalSource,
) !void {
    const self: *RealRenderer = @ptrCast(@alignCast(context));
    const allocation = nativeAllocation(self, native.token) orelse
        return error.StaleNativeBacking;
    if (native.owner != context) return error.ForeignNativeBacking;
    const imported_token = try importedImage(
        self,
        source,
        allocation.texture.size,
        inferExternalFormat(source.drm_format) orelse return error.UnsupportedExternalFormat,
    );
    const acquire_fd = try exportDmaBufFence(source.fds[0]);
    errdefer _ = linux.close(acquire_fd);
    const pending_index = for (self.pending_acquires, 0..) |candidate, index| {
        if (!candidate.occupied) break index;
    } else try growRecords(PendingAcquire, &self.pending_acquires);
    const pending = &self.pending_acquires[pending_index];
    pending.* = .{
        .occupied = true,
        .native_token = native.token,
        .identity = identity,
        .imported_token = imported_token,
        .fd = acquire_fd,
    };
}

fn cancelNative(context: *anyopaque, native: render.NativeBacking, identity: render.SampleIdentity) void {
    const self: *RealRenderer = @ptrCast(@alignCast(context));
    cancelPendingAcquire(self, native.token, identity);
}

fn allocateContent(context: *anyopaque, size: usize) !render_content.Allocation {
    const self: *RealRenderer = @ptrCast(@alignCast(context));
    const index = for (self.content_allocations, 0..) |allocation, candidate| {
        if (!allocation.active) break candidate;
    } else try growRecords(UploadAllocation, &self.content_allocations);
    var offset: usize = 0;
    while (true) {
        offset = std.mem.alignForward(usize, offset, self.copy_offset_alignment);
        const end = std.math.add(usize, offset, size) catch
            return error.ContentByteCapacityExceeded;
        if (end > self.content_buffer_size) return error.ContentByteCapacityExceeded;
        var conflict_end: ?usize = null;
        for (self.content_allocations) |allocation| {
            if (!allocation.active) continue;
            const allocation_end = allocation.offset + allocation.size;
            if (offset < allocation_end and end > allocation.offset)
                conflict_end = @max(conflict_end orelse 0, allocation_end);
        }
        if (conflict_end) |next| {
            offset = next;
            continue;
        }
        break;
    }
    const allocation = &self.content_allocations[index];
    allocation.generation +%= 1;
    if (allocation.generation == 0) allocation.generation = 1;
    allocation.active = true;
    allocation.offset = offset;
    allocation.size = size;
    allocation.references = 1;
    const token = (@as(u64, allocation.generation) << 32) | @as(u32, @intCast(index));
    return .{
        .bytes = @as([*]u8, @ptrCast(self.content_map))[offset..][0..size],
        .upload = .{ .owner = self, .token = token, .offset = offset },
    };
}

fn contentAllocation(self: *RealRenderer, token: u64) ?*UploadAllocation {
    const index: u32 = @truncate(token);
    const generation: u32 = @truncate(token >> 32);
    if (index >= self.content_allocations.len) return null;
    const allocation = &self.content_allocations[index];
    if (!allocation.active or allocation.generation != generation) return null;
    return allocation;
}

fn retainContent(self: *RealRenderer, token: u64) !void {
    const allocation = contentAllocation(self, token) orelse return error.StaleContentBacking;
    allocation.references = std.math.add(usize, allocation.references, 1) catch
        return error.ContentReferenceOverflow;
}

fn releaseContent(self: *RealRenderer, token: u64) void {
    const allocation = contentAllocation(self, token) orelse unreachable;
    std.debug.assert(allocation.references != 0);
    allocation.references -= 1;
    if (allocation.references == 0) allocation.active = false;
}

fn releaseContentOwner(context: *anyopaque, token: u64) void {
    releaseContent(@ptrCast(@alignCast(context)), token);
}

fn contentPinned(context: *anyopaque, token: u64) bool {
    const self: *RealRenderer = @ptrCast(@alignCast(context));
    const allocation = contentAllocation(self, token) orelse return false;
    return allocation.references > 1;
}

fn nativeAllocation(self: *RealRenderer, token: u64) ?*NativeAllocation {
    const index: u32 = @truncate(token);
    const generation: u32 = @truncate(token >> 32);
    if (index >= self.native_allocations.len) return null;
    const allocation = &self.native_allocations[index];
    if (!allocation.active or allocation.generation != generation) return null;
    return allocation;
}

fn allocateNative(context: *anyopaque, size: render.Size, _: render.PixelFormat) !render.NativeBacking {
    const self: *RealRenderer = @ptrCast(@alignCast(context));
    const index = for (self.native_allocations, 0..) |allocation, candidate| {
        if (!allocation.active) break candidate;
    } else try growRecords(NativeAllocation, &self.native_allocations);
    const allocation = &self.native_allocations[index];
    if (allocation.generation != 0) destroyTexture(self, allocation.texture);
    allocation.texture = try createTexture(self, size);
    allocation.generation +%= 1;
    if (allocation.generation == 0) allocation.generation = 1;
    allocation.active = true;
    allocation.references = 1;
    allocation.ready = null;
    return .{ .owner = self, .token = (@as(u64, allocation.generation) << 32) | @as(u32, @intCast(index)) };
}

fn retainNative(self: *RealRenderer, token: u64) !void {
    const allocation = nativeAllocation(self, token) orelse return error.StaleNativeBacking;
    allocation.references = std.math.add(usize, allocation.references, 1) catch return error.ContentReferenceOverflow;
}

fn releaseNative(self: *RealRenderer, token: u64) void {
    const allocation = nativeAllocation(self, token) orelse return;
    std.debug.assert(allocation.references != 0);
    allocation.references -= 1;
    if (allocation.references == 0) {
        cancelPendingAcquires(self, token);
        allocation.active = false;
    }
}

fn releaseNativeOwner(context: *anyopaque, token: u64) void {
    releaseNative(@ptrCast(@alignCast(context)), token);
}

fn nativePinned(_: *anyopaque, _: u64) bool {
    // Extra native references are lifetime leases held by work already
    // submitted to this renderer's single queue. They prevent destruction,
    // but the next submission may replace the same mutable snapshot: its
    // transfer-write barrier is ordered after every prior compute read. Frame
    // capture and queue submission are synchronous and non-reentrant, so no
    // unsubmitted reader can exist at this boundary.
    return false;
}

fn nativeReady(context: *anyopaque, token: u64, identity: render.SampleIdentity) bool {
    const allocation = nativeAllocation(@ptrCast(@alignCast(context)), token) orelse return false;
    return if (allocation.ready) |ready| std.meta.eql(ready, identity) else false;
}

fn validateRetainedExternal(
    context: *anyopaque,
    source: render.ExternalSource,
    size: render.Size,
    format: render.PixelFormat,
) !void {
    try requireExternalSampling(@ptrCast(@alignCast(context)), source, size, format);
}

fn realValidateExternal(
    _: *anyopaque,
    renderer: Renderer,
    source: render.ExternalSource,
    size: render.Size,
    format: render.PixelFormat,
) !void {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    var candidate = source;
    candidate.context = self;
    candidate.token = std.math.maxInt(u64);
    candidate.alive_fn = validationSourceAlive;
    const token = try importedImage(self, candidate, size, format);
    const entry = importedFromToken(self, token) orelse unreachable;
    destroyImportedImage(self, entry);
}

fn realSampledDmabufFormats(
    _: *anyopaque,
    renderer: Renderer,
    output: []gbm.FormatModifier,
) !usize {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const candidates = [_]struct {
        fourcc: u32,
        format: render.PixelFormat,
        vk_format: c.VkFormat,
    }{
        .{ .fourcc = c.DRM_FORMAT_ARGB8888, .format = .argb8888_premultiplied, .vk_format = c.VK_FORMAT_B8G8R8A8_UNORM },
        .{ .fourcc = c.DRM_FORMAT_XRGB8888, .format = .xrgb8888, .vk_format = c.VK_FORMAT_B8G8R8A8_UNORM },
        .{ .fourcc = c.DRM_FORMAT_ABGR8888, .format = .argb8888_premultiplied, .vk_format = c.VK_FORMAT_R8G8B8A8_UNORM },
        .{ .fourcc = c.DRM_FORMAT_XBGR8888, .format = .xrgb8888, .vk_format = c.VK_FORMAT_R8G8B8A8_UNORM },
    };
    var count: usize = 0;
    for (candidates) |candidate| {
        var modifier_list: c.VkDrmFormatModifierPropertiesListEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
            .pNext = null,
            .drmFormatModifierCount = 0,
            .pDrmFormatModifierProperties = null,
        };
        var properties: c.VkFormatProperties2 = .{
            .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
            .pNext = &modifier_list,
            .formatProperties = undefined,
        };
        c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, candidate.vk_format, &properties);
        if (modifier_list.drmFormatModifierCount == 0 or
            modifier_list.drmFormatModifierCount > 64) continue;
        var modifiers: [64]c.VkDrmFormatModifierPropertiesEXT = undefined;
        modifier_list.pDrmFormatModifierProperties = &modifiers;
        c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, candidate.vk_format, &properties);
        for (modifiers[0..modifier_list.drmFormatModifierCount]) |modifier| {
            if (modifier.drmFormatModifierPlaneCount != 1 or
                modifier.drmFormatModifierTilingFeatures & c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT == 0)
                continue;
            const source: render.ExternalSource = .{
                .context = self,
                .token = 0,
                .alive_fn = validationSourceAlive,
                .drm_format = candidate.fourcc,
                .modifier = modifier.drmFormatModifier,
                .plane_count = 1,
                .fds = .{ 0, -1, -1, -1 },
                .strides = .{ 4, 0, 0, 0 },
                .offsets = .{ 0, 0, 0, 0 },
            };
            requireExternalSampling(self, source, .{ .width = 1, .height = 1 }, candidate.format) catch
                continue;
            if (count == output.len) return error.OutputTooSmall;
            output[count] = .{ .fourcc = candidate.fourcc, .modifier = modifier.drmFormatModifier };
            count += 1;
        }
    }
    return count;
}

fn validationSourceAlive(_: *anyopaque, _: u64) bool {
    return false;
}

fn requireExternalSampling(
    self: *RealRenderer,
    source: render.ExternalSource,
    size: render.Size,
    format: render.PixelFormat,
) !void {
    if (source.plane_count != 1 or source.fds[0] < 0 or source.strides[0] == 0)
        return error.UnsupportedExternalSource;
    const vk_format = externalVkFormat(source.drm_format, format) orelse
        return error.UnsupportedExternalFormat;
    var modifier_query: c.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = source.modifier,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var external_query: c.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier_query,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var format_query: c.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external_query,
        .format = vk_format,
        .type = c.VK_IMAGE_TYPE_2D,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        .flags = 0,
    };
    var external_properties: c.VkExternalImageFormatProperties = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        .pNext = null,
        .externalMemoryProperties = undefined,
    };
    var format_properties: c.VkImageFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
        .imageFormatProperties = undefined,
    };
    try vk(c.vkGetPhysicalDeviceImageFormatProperties2(
        self.physical_device,
        &format_query,
        &format_properties,
    ), error.ExternalSamplingUnsupported);
    if (size.width > format_properties.imageFormatProperties.maxExtent.width or
        size.height > format_properties.imageFormatProperties.maxExtent.height)
        return error.ExternalSamplingUnsupported;
    const external_memory = external_properties.externalMemoryProperties;
    if (external_memory.externalMemoryFeatures & c.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT == 0 or
        external_memory.compatibleHandleTypes & c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT == 0)
        return error.ExternalSamplingUnsupported;
}

fn importedImage(self: *RealRenderer, source: render.ExternalSource, size: render.Size, format: render.PixelFormat) !u64 {
    try requireExternalSampling(self, source, size, format);
    const vk_format = externalVkFormat(source.drm_format, format) orelse unreachable;
    for (self.imported_images, 0..) |*entry, index| if (entry.occupied and
        entry.source.context == source.context and entry.source.token == source.token)
    {
        if (!std.meta.eql(entry.source, source)) return error.ExternalIdentityMismatch;
        return importedToken(entry, index);
    };

    // Reclaim cache-only imports whose protocol source has gone away before
    // consuming another slot. Persistent buffers remain cached, while buffer
    // churn does not retain dead GEM objects up to the cache capacity.
    const index = for (self.imported_images, 0..) |entry, candidate| {
        if (entry.occupied and entry.references == 1 and
            !entry.source.alive_fn(entry.source.context, entry.source.token))
            break candidate;
    } else for (self.imported_images, 0..) |entry, candidate| {
        if (!entry.occupied) break candidate;
    } else evict: {
        for (0..self.imported_images.len) |_| {
            const candidate = self.imported_cursor;
            self.imported_cursor = (self.imported_cursor + 1) % self.imported_images.len;
            if (self.imported_images[candidate].references == 1) break :evict candidate;
        }
        break :evict try growRecords(ImportedImage, &self.imported_images);
    };
    const entry = &self.imported_images[index];
    destroyImportedImage(self, entry);

    var layout: c.VkSubresourceLayout = .{
        .offset = source.offsets[0],
        .size = 0,
        .rowPitch = source.strides[0],
        .arrayPitch = 0,
        .depthPitch = 0,
    };
    var modifier: c.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = source.modifier,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &layout,
    };
    var external: c.VkExternalMemoryImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier,
        .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external,
        .flags = 0,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = vk_format,
        .extent = .{ .width = size.width, .height = size.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: c.VkImage = undefined;
    try vk(c.vkCreateImage(self.device, &info, null, &image), error.CreateExternalImageFailed);
    errdefer c.vkDestroyImage(self.device, image, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.device, image, &requirements);
    const duplicate = try duplicateFd(source.fds[0]);
    var duplicate_owned = true;
    defer if (duplicate_owned) {
        _ = linux.close(duplicate);
    };
    var properties: c.VkMemoryFdPropertiesKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
        .pNext = null,
        .memoryTypeBits = 0,
    };
    try vk(self.get_memory_fd_properties.?(
        self.device,
        c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        duplicate,
        &properties,
    ), error.GetMemoryFdPropertiesFailed);
    const bits = intersectMemoryTypeBits(requirements.memoryTypeBits, properties.memoryTypeBits);
    if (bits == 0) return error.NoCompatibleMemoryType;
    var dedicated: c.VkMemoryDedicatedAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .pNext = null,
        .image = image,
        .buffer = null,
    };
    var import: c.VkImportMemoryFdInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .pNext = &dedicated,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = duplicate,
    };
    var allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try memoryType(self, bits, 0),
    };
    var memory: c.VkDeviceMemory = undefined;
    try vk(c.vkAllocateMemory(self.device, &allocation, null, &memory), error.ImportExternalMemoryFailed);
    duplicate_owned = false;
    errdefer c.vkFreeMemory(self.device, memory, null);
    try vk(c.vkBindImageMemory(self.device, image, memory, 0), error.BindExternalMemoryFailed);
    var view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = vk_format,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = colorRange(),
    };
    var view: c.VkImageView = undefined;
    try vk(c.vkCreateImageView(self.device, &view_info, null, &view), error.CreateExternalImageViewFailed);
    errdefer c.vkDestroyImageView(self.device, view, null);
    entry.generation +%= 1;
    if (entry.generation == 0) entry.generation = 1;
    entry.* = .{
        .occupied = true,
        .generation = entry.generation,
        .references = 1,
        .source = source,
        .image = image,
        .memory = memory,
        .view = view,
    };
    return importedToken(entry, index);
}

fn importedToken(entry: *const ImportedImage, index: usize) u64 {
    return (@as(u64, entry.generation) << 32) | @as(u32, @intCast(index));
}

fn importedFromToken(self: *RealRenderer, token: u64) ?*ImportedImage {
    const index: u32 = @truncate(token);
    const generation: u32 = @truncate(token >> 32);
    if (index >= self.imported_images.len) return null;
    const entry = &self.imported_images[index];
    if (!entry.occupied or entry.generation != generation) return null;
    return entry;
}

fn inferExternalFormat(drm_format: u32) ?render.PixelFormat {
    if (drm_format == c.DRM_FORMAT_XRGB8888 or drm_format == c.DRM_FORMAT_XBGR8888)
        return .xrgb8888;
    if (drm_format == c.DRM_FORMAT_ARGB8888 or drm_format == c.DRM_FORMAT_ABGR8888)
        return .argb8888_premultiplied;
    return null;
}

fn externalVkFormat(drm_format: u32, format: render.PixelFormat) ?c.VkFormat {
    return switch (format) {
        .xrgb8888 => if (drm_format == c.DRM_FORMAT_XRGB8888)
            c.VK_FORMAT_B8G8R8A8_UNORM
        else if (drm_format == c.DRM_FORMAT_XBGR8888)
            c.VK_FORMAT_R8G8B8A8_UNORM
        else
            null,
        .argb8888_premultiplied => if (drm_format == c.DRM_FORMAT_ARGB8888)
            c.VK_FORMAT_B8G8R8A8_UNORM
        else if (drm_format == c.DRM_FORMAT_ABGR8888)
            c.VK_FORMAT_R8G8B8A8_UNORM
        else
            null,
    };
}

test "external DMA-BUF channel order selects the matching Vulkan format" {
    try std.testing.expect(externalVkFormat(
        c.DRM_FORMAT_ARGB8888,
        .argb8888_premultiplied,
    ) == c.VK_FORMAT_B8G8R8A8_UNORM);
    try std.testing.expect(externalVkFormat(
        c.DRM_FORMAT_ABGR8888,
        .argb8888_premultiplied,
    ) == c.VK_FORMAT_R8G8B8A8_UNORM);
    try std.testing.expect(externalVkFormat(
        c.DRM_FORMAT_XBGR8888,
        .xrgb8888,
    ) == c.VK_FORMAT_R8G8B8A8_UNORM);
    try std.testing.expect(externalVkFormat(
        c.DRM_FORMAT_ABGR8888,
        .xrgb8888,
    ) == null);
}

fn pendingAcquire(
    self: *RealRenderer,
    native_token: u64,
    identity: render.SampleIdentity,
) ?*PendingAcquire {
    for (self.pending_acquires) |*pending| if (pending.occupied and
        pending.native_token == native_token and std.meta.eql(pending.identity, identity))
        return pending;
    return null;
}

fn takePendingAcquire(
    self: *RealRenderer,
    native_token: u64,
    identity: render.SampleIdentity,
) ?PendingAcquire {
    const pending = pendingAcquire(self, native_token, identity) orelse return null;
    const result = pending.*;
    pending.* = .{};
    return result;
}

fn cancelPendingAcquire(self: *RealRenderer, native_token: u64, identity: render.SampleIdentity) void {
    const pending = pendingAcquire(self, native_token, identity) orelse return;
    _ = linux.close(pending.fd);
    pending.* = .{};
}

fn cancelPendingAcquires(self: *RealRenderer, native_token: u64) void {
    for (self.pending_acquires) |*pending| if (pending.occupied and
        pending.native_token == native_token)
    {
        _ = linux.close(pending.fd);
        pending.* = .{};
    };
}

fn retainImported(self: *RealRenderer, token: u64) !void {
    const entry = importedFromToken(self, token) orelse return error.StaleExternalImage;
    entry.references = std.math.add(usize, entry.references, 1) catch
        return error.ContentReferenceOverflow;
}

fn releaseImported(self: *RealRenderer, token: u64) void {
    const entry = importedFromToken(self, token) orelse unreachable;
    std.debug.assert(entry.references > 1);
    entry.references -= 1;
}

fn destroyImportedImage(self: *RealRenderer, entry: *ImportedImage) void {
    if (!entry.occupied) return;
    std.debug.assert(entry.references == 1);
    c.vkDestroyImageView(self.device, entry.view, null);
    c.vkDestroyImage(self.device, entry.image, null);
    c.vkFreeMemory(self.device, entry.memory, null);
    const generation = entry.generation;
    entry.* = .{ .generation = generation };
    bumpResourceEpoch(self);
}

fn duplicateFd(fd: std.posix.fd_t) !std.posix.fd_t {
    const result = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .BADF => error.InvalidExternalFd,
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn exportDmaBufFence(fd: std.posix.fd_t) !std.posix.fd_t {
    return exportDmaBufFenceFor(fd, c.DMA_BUF_SYNC_READ);
}

fn exportDmaBufWriteFence(fd: std.posix.fd_t) !std.posix.fd_t {
    return exportDmaBufFenceFor(fd, c.DMA_BUF_SYNC_RW);
}

fn exportDmaBufFenceFor(fd: std.posix.fd_t, flags: u32) !std.posix.fd_t {
    var export_file: c.struct_dma_buf_export_sync_file = .{
        .flags = flags,
        .fd = -1,
    };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_file) != 0 or
        export_file.fd < 0) return error.ExportAcquireFenceFailed;
    return export_file.fd;
}

fn mergeSyncFiles(first: std.posix.fd_t, second: std.posix.fd_t) !std.posix.fd_t {
    var merge = std.mem.zeroes(c.struct_sync_merge_data);
    merge.fd2 = second;
    merge.fence = -1;
    if (c.ioctl(first, c.SYNC_IOC_MERGE, &merge) != 0 or merge.fence < 0)
        return error.MergeAcquireFencesFailed;
    return merge.fence;
}

/// Returns a new sync_file that signals after every input, while retaining
/// caller ownership of all inputs. A merge failure closes only intermediates
/// and lets the caller fall back to importing each original fence.
fn mergeAcquireFences(fds: []const std.posix.fd_t) ?std.posix.fd_t {
    std.debug.assert(fds.len > 1);
    var merged: ?std.posix.fd_t = null;
    for (fds[1..]) |fd| {
        const next = mergeSyncFiles(merged orelse fds[0], fd) catch {
            if (merged) |owned| _ = linux.close(owned);
            return null;
        };
        if (merged) |owned| _ = linux.close(owned);
        merged = next;
    }
    return merged.?;
}

fn importDmaBufFence(fd: std.posix.fd_t, sync_fd: std.posix.fd_t) !void {
    var import_file: c.struct_dma_buf_import_sync_file = .{
        .flags = c.DMA_BUF_SYNC_READ,
        .fd = sync_fd,
    };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import_file) != 0)
        return error.ImportCompletionFenceFailed;
}

fn importAcquireFence(
    self: *RealRenderer,
    semaphore: c.VkSemaphore,
    fd: std.posix.fd_t,
) !void {
    var import_info: c.VkImportSemaphoreFdInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
        .pNext = null,
        .semaphore = semaphore,
        .flags = c.VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
        .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        .fd = fd,
    };
    try vk(self.import_semaphore_fd.?(self.device, &import_info), error.ImportAcquireFenceFailed);
}

fn createExportSemaphore(self: *RealRenderer) !c.VkSemaphore {
    var export_info: c.VkExportSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .handleTypes = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    var info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = &export_info,
        .flags = 0,
    };
    var semaphore: c.VkSemaphore = undefined;
    try vk(c.vkCreateSemaphore(self.device, &info, null, &semaphore), error.CreateSemaphoreFailed);
    return semaphore;
}

fn realImportTarget(_: *anyopaque, renderer: Renderer, metadata: gbm.Metadata, dma_buf_fd: std.posix.fd_t) !Target {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const allocator = std.heap.c_allocator;
    var owns_dma_buf_fd = true;
    defer if (owns_dma_buf_fd) {
        _ = std.os.linux.close(dma_buf_fd);
    };
    const target = try allocator.create(RealTarget);
    errdefer allocator.destroy(target);
    target.recorded_sampled_frame = .{};
    errdefer target.recorded_sampled_frame.deinit(allocator);
    target.retired_textures = try allocator.alloc(Texture, self.max_samples);
    target.retired_texture_count = 0;
    errdefer allocator.free(target.retired_textures);
    target.content_leases = try allocator.alloc(u64, self.max_samples);
    target.content_lease_count = 0;
    errdefer allocator.free(target.content_leases);
    target.native_leases = try allocator.alloc(u64, self.max_samples);
    target.native_lease_count = 0;
    errdefer allocator.free(target.native_leases);
    target.imported_leases = try allocator.alloc(u64, self.max_samples);
    target.imported_lease_count = 0;
    errdefer allocator.free(target.imported_leases);
    target.acquire_semaphores = try allocator.alloc(c.VkSemaphore, self.max_samples);
    var acquire_semaphore_count: usize = 0;
    errdefer {
        for (target.acquire_semaphores[0..acquire_semaphore_count]) |semaphore|
            c.vkDestroySemaphore(self.device, semaphore, null);
        allocator.free(target.acquire_semaphores);
    }
    if (metadata.plane_count != 1) return error.UnsupportedPlaneCount;
    try requireTargetFormat(self.physical_device, metadata);

    var plane_layout: c.VkSubresourceLayout = .{ .offset = metadata.offsets[0], .size = 0, .rowPitch = metadata.strides[0], .arrayPitch = 0, .depthPitch = 0 };
    const view_formats = [_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM };
    var format_list: c.VkImageFormatListCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .pNext = null,
        .viewFormatCount = view_formats.len,
        .pViewFormats = &view_formats,
    };
    var modifier_info: c.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .pNext = &format_list,
        .drmFormatModifier = metadata.modifier,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &plane_layout,
    };
    var external_info: c.VkExternalMemoryImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier_info,
        .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_info,
        .flags = c.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .extent = .{ .width = metadata.width, .height = metadata.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    try vk(c.vkCreateImage(self.device, &image_info, null, &target.image), error.CreateTargetImageFailed);
    var image_only_cleanup = true;
    errdefer if (image_only_cleanup) c.vkDestroyImage(self.device, target.image, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.device, target.image, &requirements);
    var fd_properties: c.VkMemoryFdPropertiesKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
        .pNext = null,
        .memoryTypeBits = 0,
    };
    try vk(
        self.get_memory_fd_properties.?(self.device, c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, dma_buf_fd, &fd_properties),
        error.GetMemoryFdPropertiesFailed,
    );
    const compatible_memory_bits = intersectMemoryTypeBits(requirements.memoryTypeBits, fd_properties.memoryTypeBits);
    if (compatible_memory_bits == 0) return error.NoCompatibleMemoryType;
    var dedicated: c.VkMemoryDedicatedAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO, .pNext = null, .image = target.image, .buffer = null };
    var import: c.VkImportMemoryFdInfoKHR = .{ .sType = c.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR, .pNext = &dedicated, .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, .fd = dma_buf_fd };
    var allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try memoryType(self, compatible_memory_bits, 0),
    };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, &target.image_memory), error.ImportTargetMemoryFailed);
    // Successful Vulkan FD import consumes the caller-owned descriptor.
    owns_dma_buf_fd = false;
    image_only_cleanup = false;
    errdefer {
        c.vkDestroyImage(self.device, target.image, null);
        c.vkFreeMemory(self.device, target.image_memory, null);
    }
    try vk(c.vkBindImageMemory(self.device, target.image, target.image_memory, 0), error.BindTargetMemoryFailed);
    var view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = target.image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = c.VK_FORMAT_R8G8B8A8_UNORM,
        .components = .{ .r = c.VK_COMPONENT_SWIZZLE_IDENTITY, .g = c.VK_COMPONENT_SWIZZLE_IDENTITY, .b = c.VK_COMPONENT_SWIZZLE_IDENTITY, .a = c.VK_COMPONENT_SWIZZLE_IDENTITY },
        .subresourceRange = colorRange(),
    };
    try vk(c.vkCreateImageView(self.device, &view_info, null, &target.view), error.CreateTargetViewFailed);
    errdefer c.vkDestroyImageView(self.device, target.view, null);
    try createLinearImage(
        self,
        metadata.width,
        metadata.height,
        &target.linear_image,
        &target.linear_memory,
        &target.linear_view,
    );
    errdefer destroyLinearImage(self, target);
    target.blur_image = null;
    target.blur_memory = null;
    target.blur_view = null;
    target.blur_initialized_layout = false;

    target.sample_buffer = null;
    target.sample_memory = null;
    target.sample_map = undefined;
    target.descriptor_pool = null;
    target.readback_buffers = .{ null, null };
    target.readback_memories = .{ null, null };
    target.readback_maps = undefined;
    target.readback_size = try captureByteCount(metadata.width, metadata.height);
    target.captured = .{};
    target.descriptor_sets = &.{};
    target.batch_capacity = 0;
    target.sample_buffer_size = 0;
    target.state = .ready;
    try createHostBuffer(self, self.staging_buffer_size, &target.source_buffer, &target.source_memory, &target.source_map);
    target.source_buffer_size = self.staging_buffer_size;
    errdefer destroyBuffer(self, target.source_buffer, target.source_memory);

    try growTargetBatches(self, target, 1);
    errdefer destroyTargetBatchResources(self, target);

    var command_info: c.VkCommandPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .pNext = null, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = self.queue_family };
    try vk(c.vkCreateCommandPool(self.device, &command_info, null, &target.command_pool), error.CreateCommandPoolFailed);
    errdefer c.vkDestroyCommandPool(self.device, target.command_pool, null);
    var command_allocate: c.VkCommandBufferAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .pNext = null, .commandPool = target.command_pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    try vk(c.vkAllocateCommandBuffers(self.device, &command_allocate, &target.command_buffer), error.AllocateCommandBufferFailed);
    var fence_info: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO, .pNext = null, .flags = 0 };
    try vk(c.vkCreateFence(self.device, &fence_info, null, &target.fence), error.CreateFenceFailed);
    errdefer c.vkDestroyFence(self.device, target.fence, null);
    var export_info: c.VkExportSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO, .pNext = null, .handleTypes = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT };
    var semaphore_info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = &export_info, .flags = 0 };
    try vk(c.vkCreateSemaphore(self.device, &semaphore_info, null, &target.semaphore), error.CreateSemaphoreFailed);
    errdefer c.vkDestroySemaphore(self.device, target.semaphore, null);
    try vk(c.vkCreateSemaphore(self.device, &semaphore_info, null, &target.source_semaphore), error.CreateSemaphoreFailed);
    errdefer c.vkDestroySemaphore(self.device, target.source_semaphore, null);
    semaphore_info.pNext = null;
    for (target.acquire_semaphores) |*semaphore| {
        try vk(c.vkCreateSemaphore(self.device, &semaphore_info, null, semaphore), error.CreateSemaphoreFailed);
        acquire_semaphore_count += 1;
    }
    target.width = metadata.width;
    target.height = metadata.height;
    target.fence_needs_reset = false;
    target.initialized_layout = false;
    return @ptrCast(target);
}

fn realDestroyTarget(_: *anyopaque, renderer: Renderer, target_value: Target) void {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealTarget = @ptrCast(@alignCast(target_value));
    if (target.state == .in_flight or target.state == .export_failed)
        _ = c.vkWaitForFences(self.device, 1, &target.fence, c.VK_TRUE, std.math.maxInt(u64));
    drainContentLeases(self, target);
    drainNativeLeases(self, target);
    drainImportedLeases(self, target);
    drainRetiredTextures(self, target);
    for (target.acquire_semaphores) |semaphore|
        c.vkDestroySemaphore(self.device, semaphore, null);
    c.vkDestroySemaphore(self.device, target.source_semaphore, null);
    c.vkDestroySemaphore(self.device, target.semaphore, null);
    c.vkDestroyFence(self.device, target.fence, null);
    c.vkDestroyCommandPool(self.device, target.command_pool, null);
    for (target.readback_buffers, target.readback_memories) |buffer, memory|
        if (buffer != null) destroyBuffer(self, buffer, memory);
    destroyTargetBatchResources(self, target);
    target.recorded_sampled_frame.deinit(std.heap.c_allocator);
    destroyBuffer(self, target.source_buffer, target.source_memory);
    c.vkDestroyImageView(self.device, target.view, null);
    c.vkDestroyImage(self.device, target.image, null);
    c.vkFreeMemory(self.device, target.image_memory, null);
    if (target.blur_image != null) destroyBlurImage(self, target);
    destroyLinearImage(self, target);
    std.heap.c_allocator.free(target.retired_textures);
    std.heap.c_allocator.free(target.content_leases);
    std.heap.c_allocator.free(target.native_leases);
    std.heap.c_allocator.free(target.imported_leases);
    std.heap.c_allocator.free(target.acquire_semaphores);
    std.heap.c_allocator.destroy(target);
}

fn realImportCaptureTarget(
    _: *anyopaque,
    renderer: Renderer,
    metadata: gbm.Metadata,
    dma_buf_fd: std.posix.fd_t,
) !CaptureTarget {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    var owns_fd = true;
    defer if (owns_fd) {
        _ = linux.close(dma_buf_fd);
    };
    if (metadata.plane_count != 1 or
        (metadata.format != gbm.format_argb8888 and metadata.format != gbm.format_xrgb8888))
        return error.UnsupportedCaptureTarget;
    try requireCaptureTargetFormat(self.physical_device, metadata);
    const acquire_fd = try exportDmaBufWriteFence(dma_buf_fd);
    var owns_acquire_fd = true;
    defer if (owns_acquire_fd) {
        _ = linux.close(acquire_fd);
    };

    const target = try std.heap.c_allocator.create(RealCaptureTarget);
    errdefer std.heap.c_allocator.destroy(target);
    var plane_layout: c.VkSubresourceLayout = .{
        .offset = metadata.offsets[0],
        .size = 0,
        .rowPitch = metadata.strides[0],
        .arrayPitch = 0,
        .depthPitch = 0,
    };
    var modifier_info: c.VkImageDrmFormatModifierExplicitCreateInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_EXPLICIT_CREATE_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = metadata.modifier,
        .drmFormatModifierPlaneCount = 1,
        .pPlaneLayouts = &plane_layout,
    };
    var external_info: c.VkExternalMemoryImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
        .pNext = &modifier_info,
        .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = &external_info,
        .flags = 0,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .extent = .{ .width = metadata.width, .height = metadata.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    try vk(c.vkCreateImage(self.device, &image_info, null, &target.image), error.CreateCaptureTargetFailed);
    errdefer c.vkDestroyImage(self.device, target.image, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.device, target.image, &requirements);
    var fd_properties: c.VkMemoryFdPropertiesKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_FD_PROPERTIES_KHR,
        .pNext = null,
        .memoryTypeBits = 0,
    };
    try vk(
        self.get_memory_fd_properties.?(self.device, c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT, dma_buf_fd, &fd_properties),
        error.GetMemoryFdPropertiesFailed,
    );
    const memory_bits = intersectMemoryTypeBits(requirements.memoryTypeBits, fd_properties.memoryTypeBits);
    if (memory_bits == 0) return error.NoCompatibleMemoryType;
    var dedicated: c.VkMemoryDedicatedAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
        .pNext = null,
        .image = target.image,
        .buffer = null,
    };
    var import: c.VkImportMemoryFdInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_IMPORT_MEMORY_FD_INFO_KHR,
        .pNext = &dedicated,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        .fd = dma_buf_fd,
    };
    const allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = &import,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try memoryType(self, memory_bits, 0),
    };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, &target.memory), error.ImportCaptureTargetMemoryFailed);
    owns_fd = false;
    errdefer c.vkFreeMemory(self.device, target.memory, null);
    try vk(c.vkBindImageMemory(self.device, target.image, target.memory, 0), error.BindCaptureTargetMemoryFailed);
    var semaphore_info: c.VkSemaphoreCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    try vk(c.vkCreateSemaphore(self.device, &semaphore_info, null, &target.acquire_semaphore), error.CreateSemaphoreFailed);
    errdefer c.vkDestroySemaphore(self.device, target.acquire_semaphore, null);
    try importAcquireFence(self, target.acquire_semaphore, acquire_fd);
    owns_acquire_fd = false;
    target.completion_fence = null;
    target.width = metadata.width;
    target.height = metadata.height;
    return @ptrCast(target);
}

fn realSupportsCaptureTarget(_: *anyopaque, renderer: Renderer, metadata: gbm.Metadata) bool {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    if (metadata.plane_count != 1 or
        (metadata.format != gbm.format_argb8888 and metadata.format != gbm.format_xrgb8888))
        return false;
    requireCaptureTargetFormat(self.physical_device, metadata) catch return false;
    return true;
}

fn realPrepareCaptureTarget(
    _: *anyopaque,
    renderer: Renderer,
    target_value: CaptureTarget,
    dma_buf_fd: std.posix.fd_t,
) !void {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealCaptureTarget = @ptrCast(@alignCast(target_value));
    if (target.completion_fence) |fence| {
        if (c.vkGetFenceStatus(self.device, fence) != c.VK_SUCCESS)
            return error.CaptureTargetBusy;
        target.completion_fence = null;
    }
    const acquire_fd = try exportDmaBufWriteFence(dma_buf_fd);
    var owns_fd = true;
    defer if (owns_fd) {
        _ = linux.close(acquire_fd);
    };
    try importAcquireFence(self, target.acquire_semaphore, acquire_fd);
    owns_fd = false;
}

fn realDestroyCaptureTarget(_: *anyopaque, renderer: Renderer, target_value: CaptureTarget) void {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealCaptureTarget = @ptrCast(@alignCast(target_value));
    if (target.completion_fence) |fence|
        _ = c.vkWaitForFences(self.device, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));
    c.vkDestroySemaphore(self.device, target.acquire_semaphore, null);
    c.vkDestroyImage(self.device, target.image, null);
    c.vkFreeMemory(self.device, target.memory, null);
    bumpResourceEpoch(self);
    std.heap.c_allocator.destroy(target);
}

fn realReadback(_: *anyopaque, renderer: Renderer, target_value: Target, phase: CapturePhase) !Readback {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealTarget = @ptrCast(@alignCast(target_value));
    if (target.state != .in_flight or c.vkGetFenceStatus(self.device, target.fence) != c.VK_SUCCESS)
        return error.TargetBusy;
    const captured = switch (phase) {
        .before_cursor => target.captured.before_cursor,
        .after_cursor => target.captured.after_cursor,
    };
    if (!captured) return error.CaptureUnavailable;
    const index = @intFromEnum(phase);
    return .{
        .bytes = @as([*]const u8, @ptrCast(target.readback_maps[index]))[0..target.readback_size],
        .stride = try captureStride(target.width),
    };
}

fn destroyTargetBatchResources(self: *RealRenderer, target: *RealTarget) void {
    target.recorded_sampled_frame.valid = false;
    if (target.descriptor_pool != null)
        c.vkDestroyDescriptorPool(self.device, target.descriptor_pool, null);
    if (target.sample_buffer != null)
        destroyBuffer(self, target.sample_buffer, target.sample_memory);
    std.heap.c_allocator.free(target.descriptor_sets);
    target.descriptor_pool = null;
    target.sample_buffer = null;
    target.descriptor_sets = &.{};
    target.batch_capacity = 0;
}

/// Recreates target-local descriptors only while the target is ready. Every
/// recorded batch gets an immutable set and an aligned sample-buffer region.
fn growTargetBatches(self: *RealRenderer, target: *RealTarget, count: usize) !void {
    if (count <= target.batch_capacity) return;
    std.debug.assert(target.state == .ready);
    const allocator = std.heap.c_allocator;
    const stride = std.mem.alignForward(usize, self.sample_buffer_size, self.sample_region_alignment);
    const buffer_size = std.math.mul(usize, stride, count) catch return error.CapacityExceeded;
    var buffer: c.VkBuffer = undefined;
    var memory: c.VkDeviceMemory = undefined;
    var map: *anyopaque = undefined;
    try createHostBuffer(self, buffer_size, &buffer, &memory, &map);
    errdefer destroyBuffer(self, buffer, memory);
    const sets = try allocator.alloc(c.VkDescriptorSet, count);
    errdefer allocator.free(sets);
    const layouts = try allocator.alloc(c.VkDescriptorSetLayout, count);
    defer allocator.free(layouts);
    @memset(layouts, self.descriptor_layout);
    const combined_count = std.math.mul(usize, count, sampled_image_capacity + 2) catch return error.CapacityExceeded;
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = @intCast(count * 3) },
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = @intCast(count * 4) },
        .{ .type = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = if (self.sampled_enabled) @intCast(combined_count) else 0 },
    };
    var pool_info: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = @intCast(count),
        .poolSizeCount = if (self.sampled_enabled) pool_sizes.len else pool_sizes.len - 1,
        .pPoolSizes = &pool_sizes,
    };
    var pool: c.VkDescriptorPool = undefined;
    try vk(c.vkCreateDescriptorPool(self.device, &pool_info, null, &pool), error.CreateDescriptorPoolFailed);
    errdefer c.vkDestroyDescriptorPool(self.device, pool, null);
    var set_info: c.VkDescriptorSetAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = null, .descriptorPool = pool, .descriptorSetCount = @intCast(count), .pSetLayouts = layouts.ptr };
    try vk(c.vkAllocateDescriptorSets(self.device, &set_info, sets.ptr), error.AllocateDescriptorSetFailed);
    var image_descriptor: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = target.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
    var linear_descriptor: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = target.linear_view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
    var source_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = target.source_buffer, .offset = 0, .range = self.max_source_bytes };
    var lut_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = self.lut_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
    var content_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = self.content_buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
    for (sets, 0..) |set, index| {
        var sample_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = buffer, .offset = stride * index, .range = self.sample_buffer_size };
        const writes = [_]c.VkWriteDescriptorSet{
            descriptorWrite(set, 0, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &image_descriptor, null),
            descriptorWrite(set, 1, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &sample_descriptor),
            descriptorWrite(set, 2, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &source_descriptor),
            descriptorWrite(set, 4, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &lut_descriptor),
            descriptorWrite(set, 5, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &linear_descriptor, null),
            descriptorWrite(set, 6, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &content_descriptor),
        };
        c.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }
    destroyTargetBatchResources(self, target);
    target.sample_buffer = buffer;
    target.sample_memory = memory;
    target.sample_map = map;
    target.sample_buffer_size = buffer_size;
    target.descriptor_pool = pool;
    target.descriptor_sets = sets;
    target.batch_capacity = count;
    if (target.blur_image != null) updateBlurDescriptors(self, target);
}

fn growTargetSource(self: *RealRenderer, target: *RealTarget, size: usize) !void {
    if (size <= target.source_buffer_size) return;
    std.debug.assert(target.state == .ready);
    var buffer: c.VkBuffer = undefined;
    var memory: c.VkDeviceMemory = undefined;
    var map: *anyopaque = undefined;
    try createHostBuffer(self, size, &buffer, &memory, &map);
    const old_batches = target.batch_capacity;
    destroyTargetBatchResources(self, target);
    destroyBuffer(self, target.source_buffer, target.source_memory);
    target.source_buffer = buffer;
    target.source_memory = memory;
    target.source_map = map;
    target.source_buffer_size = size;
    growTargetBatches(self, target, old_batches) catch |err| {
        // The old descriptors referenced the destroyed source buffer and cannot
        // be restored. Keep all Vulkan ownership valid and make the target
        // explicitly terminal rather than exposing a half-ready target.
        target.state = .queue_failed;
        return err;
    };
}

const PreparedBatch = struct {
    count: usize,
    staging_bytes: usize,
};

fn prepareTextures(self: *RealRenderer, frame: Frame, staging_capacity: usize) !PreparedBatch {
    if (frame.sources.len > self.cache.len) {
        const old_len = self.cache.len;
        self.cache = try std.heap.c_allocator.realloc(self.cache, frame.sources.len);
        @memset(self.cache[old_len..], .{});
    }
    if (frame.sources.len > self.prepared.len)
        self.prepared = try std.heap.c_allocator.realloc(self.prepared, frame.sources.len);
    var count: usize = 0;
    var staging_bytes: usize = 0;
    errdefer cleanupPreparedTextures(self, count);
    for (frame.sources, 0..) |surface, source_index| {
        if (preparedIndex(self.prepared[0..count], surface.sample.surface)) |index| {
            const prior = self.prepared[index];
            if (prior.commit_sequence != surface.sample.commit_sequence or
                !std.meta.eql(prior.texture.size, surface.source.size) or
                prior.format != surface.source.format)
                return error.ConflictingSurfaceVersion;
            continue;
        }

        const native = if (surface.source.native) |backing| nativeAllocation(self, backing.token) orelse
            return error.StaleNativeBacking else null;
        if (surface.source.native) |backing| if (backing.owner != @as(*anyopaque, @ptrCast(self)))
            return error.ForeignNativeBacking;
        const direct_external = native == null and surface.source.external != null;
        const direct_imported_token = if (direct_external) try importedImage(
            self,
            surface.source.external.?,
            surface.source.size,
            surface.source.format,
        ) else null;
        const direct_imported = if (direct_imported_token) |token|
            importedFromToken(self, token) orelse return error.StaleExternalImage
        else
            null;
        const existing_index = if (native == null and !direct_external)
            cacheIndex(self.cache, surface.sample.surface)
        else
            null;
        const cache_index = existing_index orelse
            (if (native != null or direct_external) std.math.maxInt(usize) else freeCacheIndex(self.cache, self.prepared[0..count]) orelse
                evictableCacheIndex(self.cache, frame, self.prepared[0..count]) orelse
                return error.TextureCapacityExceeded);
        const existing = if (existing_index) |index| self.cache[index] else null;
        const compatible = if (existing) |entry|
            std.meta.eql(entry.texture.size, surface.source.size) and
                entry.format == surface.source.format
        else
            false;
        const created = native == null and !direct_external and
            (existing == null or !compatible or cache_index != existing_index.?);
        const texture = if (native) |allocation|
            allocation.texture
        else if (direct_imported) |imported|
            Texture{
                .image = imported.image,
                .memory = imported.memory,
                .view = imported.view,
                .size = surface.source.size,
                .initialized = true,
            }
        else if (created)
            try createTexture(self, surface.source.size)
        else
            existing.?.texture;
        const prepared_index = count;
        const direct_upload = if (surface.source.upload) |upload|
            if (upload.owner == @as(*anyopaque, @ptrCast(self))) upload else null
        else
            null;
        const upload_damage = if (direct_external or
            (direct_upload != null and existing != null and compatible and existing.?.texture.initialized))
            render.UploadDamage{}
        else if (native) |allocation|
            nativeTextureUpload(allocation, surface)
        else
            textureUpload(created, existing, surface);
        const imported_token = direct_imported_token orelse if (native != null and upload_damage.count != 0)
            (pendingAcquire(self, surface.source.native.?.token, surface.sample) orelse
                return error.MissingAcquireFence).imported_token
        else
            null;
        self.prepared[prepared_index] = .{
            .cache_index = cache_index,
            .source_index = source_index,
            .texture = texture,
            .created = created,
            .retire_previous = native == null and !direct_external and created and
                self.cache[cache_index].occupied,
            .surface = surface.sample.surface,
            .commit_sequence = surface.sample.commit_sequence,
            .format = surface.source.format,
            .content_token = if (direct_upload) |upload| upload.token else null,
            .native_token = if (surface.source.native) |backing| backing.token else null,
            .imported_token = imported_token,
            .direct_external = direct_external,
        };
        count += 1;

        for (upload_damage.items()) |rect| {
            const width: usize = @intCast(rect.max_x - rect.min_x);
            const height: usize = @intCast(rect.max_y - rect.min_y);
            const row_bytes = std.math.mul(usize, width, 4) catch
                return error.CapacityExceeded;
            const byte_count = std.math.mul(usize, row_bytes, height) catch
                return error.CapacityExceeded;
            const upload_offset, const row_length, const direct = if (native != null)
                .{ @as(usize, 0), @as(u32, 0), false }
            else if (direct_upload) |backing| direct: {
                const row_offset = std.math.mul(
                    usize,
                    surface.source.stride,
                    @intCast(rect.min_y),
                ) catch return error.CapacityExceeded;
                const column_offset = std.math.mul(
                    usize,
                    @intCast(rect.min_x),
                    4,
                ) catch return error.CapacityExceeded;
                const offset = std.math.add(
                    usize,
                    backing.offset,
                    std.math.add(usize, row_offset, column_offset) catch
                        return error.CapacityExceeded,
                ) catch return error.CapacityExceeded;
                break :direct .{ offset, surface.source.stride / 4, true };
            } else fallback: {
                staging_bytes = std.mem.alignForward(
                    usize,
                    staging_bytes,
                    self.copy_offset_alignment,
                );
                const end = std.math.add(usize, staging_bytes, byte_count) catch
                    return error.CapacityExceeded;
                if (end > staging_capacity) return error.CapacityExceeded;
                const offset = staging_bytes;
                staging_bytes = end;
                break :fallback .{ offset, @as(u32, @intCast(width)), false };
            };
            self.prepared[prepared_index].uploads[
                self.prepared[prepared_index].upload_count
            ] = .{
                .x = @intCast(rect.min_x),
                .y = @intCast(rect.min_y),
                .width = @intCast(rect.max_x - rect.min_x),
                .height = @intCast(rect.max_y - rect.min_y),
                .staging_offset = upload_offset,
                .row_length = row_length,
                .direct = direct,
            };
            self.prepared[prepared_index].upload_count += 1;
        }
    }
    return .{ .count = count, .staging_bytes = staging_bytes };
}

fn ensureSampledFrameCapacity(self: *RealRenderer, target: *RealTarget, sample_count: usize) !usize {
    if (sample_count > sample_count_mask) return error.CapacityExceeded;
    const allocator = std.heap.c_allocator;
    if (self.prepared.len < sample_count)
        self.prepared = try allocator.realloc(self.prepared, sample_count);
    if (self.cache.len < sample_count) {
        const old_len = self.cache.len;
        self.cache = try allocator.realloc(self.cache, sample_count);
        @memset(self.cache[old_len..], .{});
    }
    const alignment_slack = std.math.mul(
        usize,
        std.math.mul(usize, sample_count, render.upload_damage_rect_capacity) catch return error.CapacityExceeded,
        self.copy_offset_alignment - 1,
    ) catch return error.CapacityExceeded;
    const staging_size = std.math.add(usize, self.max_source_bytes, alignment_slack) catch return error.CapacityExceeded;
    try growTargetSource(self, target, staging_size);
    const batch_count = std.math.divCeil(usize, sample_count, self.max_samples) catch 0;
    try growTargetBatches(self, target, @max(batch_count, 1));
    if (target.retired_textures.len < sample_count)
        target.retired_textures = try allocator.realloc(target.retired_textures, sample_count);
    if (target.content_leases.len < sample_count)
        target.content_leases = try allocator.realloc(target.content_leases, sample_count);
    if (target.native_leases.len < sample_count)
        target.native_leases = try allocator.realloc(target.native_leases, sample_count);
    if (target.imported_leases.len < sample_count)
        target.imported_leases = try allocator.realloc(target.imported_leases, sample_count);
    if (target.acquire_semaphores.len < sample_count) {
        const semaphores = try allocator.alloc(c.VkSemaphore, sample_count);
        errdefer allocator.free(semaphores);
        @memcpy(semaphores[0..target.acquire_semaphores.len], target.acquire_semaphores);
        var created = target.acquire_semaphores.len;
        errdefer for (semaphores[target.acquire_semaphores.len..created]) |semaphore|
            c.vkDestroySemaphore(self.device, semaphore, null);
        var info: c.VkSemaphoreCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = null, .flags = 0 };
        while (created < semaphores.len) : (created += 1)
            try vk(c.vkCreateSemaphore(self.device, &info, null, &semaphores[created]), error.CreateSemaphoreFailed);
        allocator.free(target.acquire_semaphores);
        target.acquire_semaphores = semaphores;
    }
    return batch_count;
}

fn cleanupPreparedTextures(self: *RealRenderer, count: usize) void {
    for (self.prepared[0..count]) |prepared| if (prepared.created)
        destroyTexture(self, prepared.texture);
}

fn preparedIndex(prepared: []const PreparedTexture, surface: u64) ?usize {
    for (prepared, 0..) |entry, index| if (entry.surface == surface) return index;
    return null;
}

fn cacheIndex(cache: []const CacheEntry, surface: u64) ?usize {
    for (cache, 0..) |entry, index| if (entry.occupied and entry.surface == surface)
        return index;
    return null;
}

fn freeCacheIndex(cache: []const CacheEntry, prepared: []const PreparedTexture) ?usize {
    outer: for (cache, 0..) |entry, index| if (!entry.occupied) {
        for (prepared) |value| if (value.cache_index == index) continue :outer;
        return index;
    };
    return null;
}

fn evictableCacheIndex(
    cache: []const CacheEntry,
    frame: Frame,
    prepared: []const PreparedTexture,
) ?usize {
    outer: for (cache, 0..) |entry, index| {
        for (frame.sources) |surface| if (entry.surface == surface.sample.surface)
            continue :outer;
        for (prepared) |value| if (value.cache_index == index) continue :outer;
        return index;
    }
    return null;
}

fn fullUpload(size: render.Size) render.UploadDamage {
    var damage: render.UploadDamage = .{};
    damage.rects[0] = .{ .min_x = 0, .min_y = 0, .max_x = size.width, .max_y = size.height };
    damage.count = 1;
    return damage;
}

fn textureUpload(
    created: bool,
    existing: ?CacheEntry,
    surface: render.SurfaceSample,
) render.UploadDamage {
    if (created or !existing.?.texture.initialized) return fullUpload(surface.source.size);
    if (existing.?.commit_sequence == surface.sample.commit_sequence) return .{};
    if (existing.?.commit_sequence +% 1 == surface.sample.commit_sequence)
        return clippedUpload(surface.upload_damage, surface.source.size);
    return fullUpload(surface.source.size);
}

fn nativeTextureUpload(allocation: *const NativeAllocation, surface: render.SurfaceSample) render.UploadDamage {
    if (!allocation.texture.initialized or allocation.ready == null) return fullUpload(surface.source.size);
    const ready = allocation.ready.?;
    if (std.meta.eql(ready, surface.sample)) return .{};
    if (ready.surface == surface.sample.surface and ready.commit_sequence +% 1 == surface.sample.commit_sequence)
        return clippedUpload(surface.upload_damage, surface.source.size);
    return fullUpload(surface.source.size);
}

fn clippedUpload(damage: render.UploadDamage, size: render.Size) render.UploadDamage {
    var clipped: render.UploadDamage = .{};
    for (damage.items()) |rect| {
        const min_x = std.math.clamp(rect.min_x, 0, @as(i64, size.width));
        const min_y = std.math.clamp(rect.min_y, 0, @as(i64, size.height));
        const max_x = std.math.clamp(rect.max_x, 0, @as(i64, size.width));
        const max_y = std.math.clamp(rect.max_y, 0, @as(i64, size.height));
        if (min_x >= max_x or min_y >= max_y) continue;
        clipped.rects[clipped.count] = .{
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
        };
        clipped.count += 1;
    }
    return clipped;
}

fn recordPackedPass(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    sample_count: usize,
) !void {
    if (sample_count > sample_count_mask) return error.CapacityExceeded;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[0], 0, null);
    for (frame.render_damage) |damage| {
        const push: Push = .{
            .clear_color = .{ frame.clear.a, frame.clear.r, frame.clear.g, frame.clear.b },
            .output = .{ frame.output.width, frame.output.height, @intFromEnum(frame.output_format), @intCast(sample_count) },
            .damage = .{ @intCast(damage.x), @intCast(damage.y), damage.width, damage.height },
            .output_color = .{
                @intFromEnum(frame.output_color_description.transfer),
                @bitCast(frame.output_color_description.reference_luminance),
                if (frame.output_lut_slot) |slot| slot + 1 else 0,
                0,
            },
        };
        c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
        c.vkCmdDispatch(target.command_buffer, (damage.width + 7) / 8, (damage.height + 7) / 8, 1);
    }
}

fn recordCapture(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    phase: CapturePhase,
    source_stage: c.VkPipelineStageFlags,
    source_access: c.VkAccessFlags,
) void {
    var image_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = source_access,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = target.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        source_stage,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &image_barrier,
    );
    recordCaptureCopy(self, target, frame, phase);
}

fn recordCaptureCopy(self: *RealRenderer, target: *RealTarget, frame: Frame, phase: CapturePhase) void {
    if (frame.capture_destination) |destination| {
        recordCaptureTargetCopy(self, target, destination);
        return;
    }
    const index = @intFromEnum(phase);
    var copy: c.VkBufferImageCopy = .{
        .bufferOffset = 0,
        .bufferRowLength = target.width,
        .bufferImageHeight = target.height,
        .imageSubresource = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
        .imageOffset = .{ .x = 0, .y = 0, .z = 0 },
        .imageExtent = .{ .width = target.width, .height = target.height, .depth = 1 },
    };
    c.vkCmdCopyImageToBuffer(
        target.command_buffer,
        target.image,
        c.VK_IMAGE_LAYOUT_GENERAL,
        target.readback_buffers[index],
        1,
        &copy,
    );
    var host_barrier: c.VkBufferMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_HOST_READ_BIT,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .buffer = target.readback_buffers[index],
        .offset = 0,
        .size = target.readback_size,
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0,
        null,
        1,
        &host_barrier,
        0,
        null,
    );
}

fn recordCaptureTargetCopy(self: *RealRenderer, target: *RealTarget, destination: CaptureDestination) void {
    const capture: *RealCaptureTarget = @ptrCast(@alignCast(destination.target));
    var acquire: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .dstQueueFamilyIndex = self.queue_family,
        .image = capture.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &acquire,
    );
    const clear = c.VkClearColorValue{ .uint32 = .{ 0, 0, 0, 0 } };
    const range = colorRange();
    c.vkCmdClearColorImage(
        target.command_buffer,
        capture.image,
        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        &clear,
        1,
        &range,
    );

    const source_left = @max(destination.source.x, 0);
    const source_top = @max(destination.source.y, 0);
    const source_right = @min(
        @as(i64, destination.source.x) + destination.source.width,
        target.width,
    );
    const source_bottom = @min(
        @as(i64, destination.source.y) + destination.source.height,
        target.height,
    );
    if (source_left < source_right and source_top < source_bottom) {
        const copy: c.VkImageCopy = .{
            .srcSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcOffset = .{ .x = @intCast(source_left), .y = @intCast(source_top), .z = 0 },
            .dstSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .dstOffset = .{
                .x = @intCast(source_left - destination.source.x),
                .y = @intCast(source_top - destination.source.y),
                .z = 0,
            },
            .extent = .{
                .width = @intCast(source_right - source_left),
                .height = @intCast(source_bottom - source_top),
                .depth = 1,
            },
        };
        c.vkCmdCopyImage(
            target.command_buffer,
            target.image,
            c.VK_IMAGE_LAYOUT_GENERAL,
            capture.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &copy,
        );
    }
    var release = acquire;
    release.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
    release.dstAccessMask = 0;
    release.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    release.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    release.srcQueueFamilyIndex = self.queue_family;
    release.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT;
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &release,
    );
}

fn recordResumeAfterCapture(target: *RealTarget) void {
    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = target.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );
}

fn realDraw(_: *anyopaque, renderer: Renderer, target_value: Target, frame: Frame) !std.posix.fd_t {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealTarget = @ptrCast(@alignCast(target_value));
    if (frame.sources.len != frame.samples.len or
        frame.source_byte_count > self.max_source_bytes)
        return error.CapacityExceeded;
    if (frame.cursor_start > frame.samples.len) return error.InvalidCursorPartition;
    if (frame.output.width != target.width or frame.output.height != target.height)
        return error.TargetMismatch;
    if (frame.capture_destination) |destination| {
        const capture: *RealCaptureTarget = @ptrCast(@alignCast(destination.target));
        if (destination.source.width != capture.width or
            destination.source.height != capture.height or
            @as(u8, @intFromBool(frame.captures.before_cursor)) +
                @as(u8, @intFromBool(frame.captures.after_cursor)) != 1)
            return error.InvalidCaptureDestination;
    }
    var validated_bytes: usize = 0;
    for (frame.sources, frame.samples) |surface, sample| {
        const source = surface.source;
        const packed_stride = std.math.mul(u32, source.size.width, 4) catch
            return error.CapacityExceeded;
        const length = if (self.sampled_enabled or source.native != null or source.upload != null)
            0
        else
            std.math.mul(usize, packed_stride, source.size.height) catch
                return error.CapacityExceeded;
        const source_length = std.math.mul(usize, source.stride, source.size.height) catch
            return error.CapacityExceeded;
        const end = std.math.add(usize, validated_bytes, length) catch
            return error.CapacityExceeded;
        const source_offset = std.math.cast(u32, if (source.upload) |upload|
            if (upload.owner == @as(*anyopaque, @ptrCast(self))) upload.offset else validated_bytes
        else
            validated_bytes) orelse
            return error.CapacityExceeded;
        if (source.stride < packed_stride or
            (source.native == null and source.external == null and source_length > source.bytes.len) or
            end > frame.source_byte_count or
            !std.meta.eql(sample.source, [4]u32{
                source_offset,
                source.size.width,
                source.size.height,
                packed_stride,
            }))
            return error.CapacityExceeded;
        validated_bytes = end;
    }
    if (validated_bytes != frame.source_byte_count) return error.CapacityExceeded;
    switch (target.state) {
        .ready => {},
        .in_flight => {
            if (c.vkGetFenceStatus(self.device, target.fence) != c.VK_SUCCESS) return error.TargetBusy;
            target.state = .ready;
            target.fence_needs_reset = true;
            drainContentLeases(self, target);
            drainNativeLeases(self, target);
            drainImportedLeases(self, target);
        },
        .queue_failed, .export_failed => return error.TargetTerminal,
    }
    if (frame.capture_destination == null)
        try ensureReadbacks(self, target, frame.captures);
    target.captured = .{};
    drainRetiredTextures(self, target);
    if (self.sampled_enabled and frame.sources.len != 0)
        return realDrawSampled(self, target, frame);
    if (frame.samples.len > self.max_samples) return error.CapacityExceeded;
    for (frame.sources) |surface| if (surface.source.native != null)
        return error.NativeSampledPathUnavailable;
    @memcpy(@as([*]u8, @ptrCast(target.sample_map))[0 .. frame.samples.len * @sizeOf(Sample)], std.mem.sliceAsBytes(frame.samples));
    const source_map = @as([*]u8, @ptrCast(target.source_map))[0..frame.source_byte_count];
    var offset: usize = 0;
    for (frame.sources) |surface| {
        const source = surface.source;
        const packed_stride = source.size.width * 4;
        for (0..source.size.height) |row| {
            const source_start = @as(usize, source.stride) * row;
            const packed_start = offset + @as(usize, packed_stride) * row;
            @memcpy(
                source_map[packed_start..][0..packed_stride],
                source.bytes[source_start..][0..packed_stride],
            );
        }
        offset += @as(usize, packed_stride) * source.size.height;
    }
    std.debug.assert(offset == source_map.len);
    try vk(c.vkResetCommandBuffer(target.command_buffer, 0), error.ResetCommandBufferFailed);
    var begin: c.VkCommandBufferBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .pNext = null, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT, .pInheritanceInfo = null };
    try vk(c.vkBeginCommandBuffer(target.command_buffer, &begin), error.BeginCommandBufferFailed);
    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = if (target.initialized_layout) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .dstQueueFamilyIndex = self.queue_family,
        .image = target.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    var transfer_final = false;
    if (frame.captures.before_cursor) {
        try recordPackedPass(self, target, frame, frame.cursor_start);
        recordCapture(
            self,
            target,
            frame,
            .before_cursor,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_ACCESS_SHADER_WRITE_BIT,
        );
        transfer_final = true;
        if (frame.cursor_start != frame.samples.len) {
            recordResumeAfterCapture(target);
            try recordPackedPass(self, target, frame, frame.samples.len);
            transfer_final = false;
        }
    } else {
        try recordPackedPass(self, target, frame, frame.samples.len);
    }
    if (frame.captures.after_cursor) {
        if (transfer_final)
            recordCaptureCopy(self, target, frame, .after_cursor)
        else
            recordCapture(
                self,
                target,
                frame,
                .after_cursor,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_ACCESS_SHADER_WRITE_BIT,
            );
        transfer_final = true;
    }
    var release_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = if (transfer_final) c.VK_ACCESS_TRANSFER_READ_BIT else c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = 0,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = self.queue_family,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .image = target.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        if (transfer_final) c.VK_PIPELINE_STAGE_TRANSFER_BIT else c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &release_barrier,
    );
    try vk(c.vkEndCommandBuffer(target.command_buffer), error.EndCommandBufferFailed);
    const capture_wait: ?c.VkSemaphore = if (frame.capture_destination) |destination|
        (@as(*RealCaptureTarget, @ptrCast(@alignCast(destination.target)))).acquire_semaphore
    else
        null;
    const capture_wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
    var submit: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = @intFromBool(capture_wait != null),
        .pWaitSemaphores = if (capture_wait) |*semaphore| semaphore else null,
        .pWaitDstStageMask = if (capture_wait != null) &capture_wait_stage else null,
        .commandBufferCount = 1,
        .pCommandBuffers = &target.command_buffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &target.semaphore,
    };
    if (target.fence_needs_reset) {
        try vk(c.vkResetFences(self.device, 1, &target.fence), error.ResetFenceFailed);
        target.fence_needs_reset = false;
    }
    if (c.vkQueueSubmit(self.queue, 1, &submit, target.fence) != c.VK_SUCCESS) {
        target.state = .queue_failed;
        return error.QueueSubmitFailed;
    }
    if (frame.capture_destination) |destination|
        (@as(*RealCaptureTarget, @ptrCast(@alignCast(destination.target)))).completion_fence = target.fence;
    target.state = .in_flight;
    target.initialized_layout = true;
    target.captured = frame.captures;
    var fd_info: c.VkSemaphoreGetFdInfoKHR = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR, .pNext = null, .semaphore = target.semaphore, .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT };
    var completion_fd: c_int = -1;
    if (self.get_semaphore_fd.?(self.device, &fd_info, &completion_fd) != c.VK_SUCCESS or completion_fd < 0) {
        target.state = .export_failed;
        return error.CompletionExportFailedAfterSubmit;
    }
    return completion_fd;
}

fn recordSampledPass(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    sample_count: usize,
) !void {
    const pass_batch_count = if (sample_count == 0)
        1
    else
        try std.math.divCeil(usize, sample_count, self.max_samples);
    c.vkCmdBindPipeline(
        target.command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        self.sampled_pipeline.?,
    );
    if (pass_batch_count > 1) {
        // Initialize linear light once, render each ordered descriptor batch
        // only where it has visible samples, then encode the complete damage.
        // This preserves blending across batches without making every damaged
        // pixel test every sample in the scene.
        c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[0], 0, null);
        for (frame.render_damage) |damage|
            recordSampledDispatch(self, target, frame, damage, intermediate_bit, 0);
        recordSampledBarrier(target);

        for (0..pass_batch_count) |batch_index| {
            const partition = batchAt(sample_count, self.max_samples, batch_index);
            c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[batch_index], 0, null);
            recordSampledPartition(self, target, frame, partition);
            recordSampledBarrier(target);
        }

        c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[0], 0, null);
        for (frame.render_damage) |damage|
            recordSampledDispatch(self, target, frame, damage, continuation_bit, 0);
        return;
    }
    for (0..pass_batch_count) |batch_index| {
        const partition = if (sample_count == 0)
            Batch{ .first = 0, .count = 0, .initialize = true }
        else
            batchAt(sample_count, self.max_samples, batch_index);
        c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[batch_index], 0, null);
        for (frame.render_damage) |damage| {
            const encoded_count: u32 = @intCast(partition.count);
            const flags: u32 = (if (!partition.initialize) continuation_bit else 0) |
                (if (batch_index + 1 < pass_batch_count) intermediate_bit else 0);
            const push: Push = .{
                .clear_color = .{ frame.clear.a, frame.clear.r, frame.clear.g, frame.clear.b },
                .output = .{ frame.output.width, frame.output.height, @intFromEnum(frame.output_format), encoded_count | flags },
                .damage = .{ @intCast(damage.x), @intCast(damage.y), damage.width, damage.height },
                .output_color = .{
                    @intFromEnum(frame.output_color_description.transfer),
                    @bitCast(frame.output_color_description.reference_luminance),
                    if (frame.output_lut_slot) |slot| slot + 1 else 0,
                    0,
                },
            };
            c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
            c.vkCmdDispatch(target.command_buffer, (damage.width + 7) / 8, (damage.height + 7) / 8, 1);
        }
        if (batch_index + 1 < pass_batch_count) {
            recordSampledBarrier(target);
        }
    }
}

fn recordBackdropEffectPass(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    sample_count: usize,
) !void {
    const allocator = std.heap.c_allocator;
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_sets[0], 0, null);
    var segment_start: usize = 0;
    for (frame.sources[0..sample_count], 0..) |_, index| {
        var regions = try mappedBlurRects(allocator, frame, index);
        defer regions.deinit(allocator);
        if (regions.items.len == 0) continue;

        recordSampledRange(self, target, frame, segment_start, index, true);
        recordSampledBarrier(target);
        recordBlurRegions(self, target, frame, index, regions.items);
        segment_start = index;
    }
    recordSampledRange(self, target, frame, segment_start, sample_count, false);
}

fn recordSampledRange(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    first: usize,
    end: usize,
    intermediate: bool,
) void {
    std.debug.assert(first <= end and end <= self.max_samples);
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.sampled_pipeline.?);
    const flags: u32 = (if (first != 0) continuation_bit else 0) |
        (if (intermediate) intermediate_bit else 0);
    for (frame.render_damage) |damage|
        recordSampledDispatch(
            self,
            target,
            frame,
            damage,
            @as(u32, @intCast(end - first)) | flags,
            @intCast(first),
        );
}

fn recordBlurRegions(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    sample_index: usize,
    regions: []const render.Rect,
) void {
    const source = frame.sources[sample_index];
    const planned = frame.samples[sample_index];
    const scale_x = @as(f32, @floatFromInt(planned.destination[2])) /
        @as(f32, @floatFromInt(source.effect_size.width));
    const scale_y = @as(f32, @floatFromInt(planned.destination[3])) /
        @as(f32, @floatFromInt(source.effect_size.height));
    const scale = @max(scale_x, scale_y);
    const support: u32 = @intFromFloat(@ceil(24.0 * scale));

    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.blur_pipeline.?);
    for (regions) |region| for (frame.render_damage) |damage| {
        const exact = intersectRect(region, damage) orelse continue;
        recordBlurDispatch(self, target, frame, expandVertical(exact, support, frame.output), false, scale);
    };
    recordBlurBarrier(target);
    for (regions) |region| for (frame.render_damage) |damage| {
        const exact = intersectRect(region, damage) orelse continue;
        recordBlurDispatch(self, target, frame, exact, true, scale);
    };
    recordSampledBarrier(target);
}

fn recordBlurDispatch(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    rect: render.Rect,
    vertical: bool,
    scale: f32,
) void {
    const push: Push = .{
        .clear_color = @splat(0),
        .output = .{ frame.output.width, frame.output.height, 0, 0 },
        .damage = .{ @intCast(rect.x), @intCast(rect.y), rect.width, rect.height },
        .output_color = .{ @intFromBool(vertical), @bitCast(scale), 0, 0 },
    };
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    c.vkCmdDispatch(target.command_buffer, (rect.width + 7) / 8, (rect.height + 7) / 8, 1);
}

fn recordBlurBarrier(target: *RealTarget) void {
    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = target.blur_image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
}

fn recordSampledDispatch(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    damage: render.Rect,
    encoded_count: u32,
    sample_start: u32,
) void {
    const push: Push = .{
        .clear_color = .{ frame.clear.a, frame.clear.r, frame.clear.g, frame.clear.b },
        .output = .{ frame.output.width, frame.output.height, @intFromEnum(frame.output_format), encoded_count },
        .damage = .{ @intCast(damage.x), @intCast(damage.y), damage.width, damage.height },
        .output_color = .{
            @intFromEnum(frame.output_color_description.transfer),
            @bitCast(frame.output_color_description.reference_luminance),
            if (frame.output_lut_slot) |slot| slot + 1 else 0,
            sample_start,
        },
    };
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    c.vkCmdDispatch(target.command_buffer, (damage.width + 7) / 8, (damage.height + 7) / 8, 1);
}

fn recordSampledPartition(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    partition: Batch,
) void {
    for (frame.render_damage) |damage| {
        const samples = frame.samples[partition.first..][0..partition.count];
        var intersections: [sampled_image_capacity]?SampleIntersection = @splat(null);
        var remaining: u32 = 0;
        for (samples, 0..) |sample, index| {
            intersections[index] = sampleIntersection(sample, damage);
            if (intersections[index] != null)
                remaining |= @as(u32, 1) << @intCast(index);
        }
        while (remaining != 0) {
            var component = @as(u32, 1) << @intCast(@ctz(remaining));
            remaining &= ~component;
            var changed = true;
            while (changed) {
                changed = false;
                var candidates = remaining;
                while (candidates != 0) {
                    const candidate_index: u5 = @intCast(@ctz(candidates));
                    const candidate_bit = @as(u32, 1) << candidate_index;
                    candidates &= ~candidate_bit;
                    var members = component;
                    while (members != 0) {
                        const member_index: u5 = @intCast(@ctz(members));
                        members &= ~(@as(u32, 1) << member_index);
                        if (intersectionsOverlap(
                            intersections[member_index].?,
                            intersections[candidate_index].?,
                        )) {
                            component |= candidate_bit;
                            remaining &= ~candidate_bit;
                            changed = true;
                            break;
                        }
                    }
                }
            }
            if (@popCount(component) == 1) {
                const index: u5 = @intCast(@ctz(component));
                const visible = intersections[index].?;
                recordSampledDispatch(self, target, frame, .{
                    .x = @intCast(visible.min_x),
                    .y = @intCast(visible.min_y),
                    .width = @intCast(visible.max_x - visible.min_x),
                    .height = @intCast(visible.max_y - visible.min_y),
                }, 1 | continuation_bit | intermediate_bit, index);
            } else {
                recordSampledComponent(
                    self,
                    target,
                    frame,
                    component,
                    intersections[0..partition.count],
                );
            }
        }
    }
}

fn recordSampledComponent(
    self: *RealRenderer,
    target: *RealTarget,
    frame: Frame,
    component: u32,
    intersections: []const ?SampleIntersection,
) void {
    const first: u5 = @intCast(@ctz(component));
    const last: u5 = @intCast(31 - @clz(component));
    const encoded_count = @as(u32, last) - first + 1 |
        continuation_bit | intermediate_bit;
    var damage_min_x: i64 = std.math.maxInt(i64);
    var damage_min_y: i64 = std.math.maxInt(i64);
    var damage_max_x: i64 = std.math.minInt(i64);
    var damage_max_y: i64 = std.math.minInt(i64);
    for (intersections, 0..) |intersection, index| {
        if (component & (@as(u32, 1) << @intCast(index)) == 0) continue;
        const visible = intersection.?;
        damage_min_x = @min(damage_min_x, visible.min_x);
        damage_min_y = @min(damage_min_y, visible.min_y);
        damage_max_x = @max(damage_max_x, visible.max_x);
        damage_max_y = @max(damage_max_y, visible.max_y);
    }
    var y = damage_min_y;
    while (y < damage_max_y) {
        var next_y = damage_max_y;
        var active = false;
        for (intersections, 0..) |intersection, index| {
            if (component & (@as(u32, 1) << @intCast(index)) == 0) continue;
            const visible = intersection.?;
            if (visible.min_y > y) {
                next_y = @min(next_y, visible.min_y);
            } else if (visible.max_y > y) {
                active = true;
                next_y = @min(next_y, visible.max_y);
            }
        }
        if (active) {
            var x = damage_min_x;
            while (x < damage_max_x) {
                var run_start = damage_max_x;
                for (intersections, 0..) |intersection, index| {
                    if (component & (@as(u32, 1) << @intCast(index)) == 0) continue;
                    const visible = intersection.?;
                    if (visible.min_y <= y and visible.max_y > y and visible.max_x > x)
                        run_start = @min(run_start, @max(x, visible.min_x));
                }
                if (run_start == damage_max_x) break;
                var run_end = run_start;
                var extended = true;
                while (extended) {
                    extended = false;
                    for (intersections, 0..) |intersection, index| {
                        if (component & (@as(u32, 1) << @intCast(index)) == 0) continue;
                        const visible = intersection.?;
                        if (visible.min_y <= y and visible.max_y > y and
                            visible.min_x <= run_end and visible.max_x > run_end)
                        {
                            run_end = visible.max_x;
                            extended = true;
                        }
                    }
                }
                recordSampledDispatch(self, target, frame, .{
                    .x = @intCast(run_start),
                    .y = @intCast(y),
                    .width = @intCast(run_end - run_start),
                    .height = @intCast(next_y - y),
                }, encoded_count, first);
                x = run_end;
            }
        }
        y = next_y;
    }
}

fn intersectionsOverlap(a: SampleIntersection, b: SampleIntersection) bool {
    return @max(a.min_x, b.min_x) < @min(a.max_x, b.max_x) and
        @max(a.min_y, b.min_y) < @min(a.max_y, b.max_y);
}

const SampleIntersection = struct {
    min_x: i64,
    min_y: i64,
    max_x: i64,
    max_y: i64,
};

fn sampleIntersection(sample: Sample, rect: render.Rect) ?SampleIntersection {
    const rect_min_x: i64 = rect.x;
    const rect_min_y: i64 = rect.y;
    const rect_max_x = rect_min_x + rect.width;
    const rect_max_y = rect_min_y + rect.height;
    const destination_min_x: i64 = sample.destination[0];
    const destination_min_y: i64 = sample.destination[1];
    const destination_max_x = destination_min_x + sample.destination[2];
    const destination_max_y = destination_min_y + sample.destination[3];
    const clip_min_x: i64 = sample.clip[0];
    const clip_min_y: i64 = sample.clip[1];
    const clip_max_x = clip_min_x + sample.clip[2];
    const clip_max_y = clip_min_y + sample.clip[3];
    const visible: SampleIntersection = .{
        .min_x = @max(rect_min_x, destination_min_x, clip_min_x),
        .min_y = @max(rect_min_y, destination_min_y, clip_min_y),
        .max_x = @min(rect_max_x, destination_max_x, clip_max_x),
        .max_y = @min(rect_max_y, destination_max_y, clip_max_y),
    };
    return if (visible.min_x < visible.max_x and visible.min_y < visible.max_y)
        visible
    else
        null;
}

fn frameMayHaveBlur(frame: Frame) bool {
    for (frame.sources) |source| if (render.hasVisibleBlur(source)) return true;
    return false;
}

fn frameHasVisibleBlur(frame: Frame) !bool {
    const allocator = std.heap.c_allocator;
    for (frame.sources, 0..) |_, index| {
        var rectangles = try mappedBlurRects(allocator, frame, index);
        defer rectangles.deinit(allocator);
        if (rectangles.items.len != 0) return true;
    }
    return false;
}

fn mappedBlurRects(
    allocator: std.mem.Allocator,
    frame: Frame,
    sample_index: usize,
) !std.ArrayListUnmanaged(render.Rect) {
    const source = frame.sources[sample_index];
    var mapped: std.ArrayListUnmanaged(render.Rect) = .empty;
    errdefer mapped.deinit(allocator);
    if (!render.hasVisibleBlur(source)) return mapped;

    var blur: std.ArrayListUnmanaged(render.Rect) = .empty;
    defer blur.deinit(allocator);
    var opaque_rects: std.ArrayListUnmanaged(render.Rect) = .empty;
    defer opaque_rects.deinit(allocator);
    try canonicalRegion(allocator, source.effect_size, source.blur_region, &blur);
    if (source.global_alpha == 255 and source.opaque_region.len != 0) {
        try canonicalRegion(allocator, source.effect_size, source.opaque_region, &opaque_rects);
        var remainder: std.ArrayListUnmanaged(render.Rect) = .empty;
        defer remainder.deinit(allocator);
        for (opaque_rects.items) |cover| {
            remainder.clearRetainingCapacity();
            for (blur.items) |value| try subtractRect(allocator, &remainder, value, cover);
            std.mem.swap(std.ArrayListUnmanaged(render.Rect), &blur, &remainder);
        }
    }

    for (blur.items) |local| if (mapEffectRect(frame, sample_index, local)) |physical|
        try mapped.append(allocator, physical);
    return mapped;
}

fn canonicalRegion(
    allocator: std.mem.Allocator,
    size: render.Size,
    operations: []const render.RegionOperation,
    rectangles: *std.ArrayListUnmanaged(render.Rect),
) !void {
    rectangles.clearRetainingCapacity();
    const bounds: render.Rect = .{ .x = 0, .y = 0, .width = size.width, .height = size.height };
    var fragments: std.ArrayListUnmanaged(render.Rect) = .empty;
    defer fragments.deinit(allocator);
    var scratch: std.ArrayListUnmanaged(render.Rect) = .empty;
    defer scratch.deinit(allocator);

    for (operations) |operation| {
        const value = switch (operation) {
            .add => |rectangle| rectangle,
            .subtract => |rectangle| rectangle,
        };
        const candidate = intersectRect(bounds, rectangleFromRegion(value) orelse continue) orelse continue;
        switch (operation) {
            .add => {
                fragments.clearRetainingCapacity();
                try fragments.append(allocator, candidate);
                for (rectangles.items) |cover| {
                    scratch.clearRetainingCapacity();
                    for (fragments.items) |fragment|
                        try subtractRect(allocator, &scratch, fragment, cover);
                    std.mem.swap(std.ArrayListUnmanaged(render.Rect), &fragments, &scratch);
                }
                try rectangles.appendSlice(allocator, fragments.items);
            },
            .subtract => {
                scratch.clearRetainingCapacity();
                for (rectangles.items) |rectangle|
                    try subtractRect(allocator, &scratch, rectangle, candidate);
                std.mem.swap(std.ArrayListUnmanaged(render.Rect), rectangles, &scratch);
            },
        }
    }
}

fn rectangleFromRegion(value: @import("../region.zig").Rectangle) ?render.Rect {
    if (value.width <= 0 or value.height <= 0) return null;
    return .{
        .x = value.x,
        .y = value.y,
        .width = @intCast(value.width),
        .height = @intCast(value.height),
    };
}

fn mapEffectRect(frame: Frame, sample_index: usize, local: render.Rect) ?render.Rect {
    const source = frame.sources[sample_index];
    const destination = source.destination;
    const left = @as(i64, destination.x) + @divFloor(
        @as(i64, local.x) * destination.width,
        source.effect_size.width,
    );
    const top = @as(i64, destination.y) + @divFloor(
        @as(i64, local.y) * destination.height,
        source.effect_size.height,
    );
    const right = @as(i64, destination.x) + (std.math.divCeil(
        i64,
        (@as(i64, local.x) + local.width) * destination.width,
        source.effect_size.width,
    ) catch return null);
    const bottom = @as(i64, destination.y) + (std.math.divCeil(
        i64,
        (@as(i64, local.y) + local.height) * destination.height,
        source.effect_size.height,
    ) catch return null);
    const logical_output = switch (frame.output_transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => render.Size{ .width = frame.output.height, .height = frame.output.width },
        else => frame.output,
    };
    const transformed = transformEffectRect(left, top, right, bottom, logical_output, frame.output_transform);
    const clipped = rectFromEdges(
        @max(transformed.x, 0),
        @max(transformed.y, 0),
        @min(transformed.x + transformed.width, frame.output.width),
        @min(transformed.y + transformed.height, frame.output.height),
    ) orelse return null;
    const visible = sampleIntersection(frame.samples[sample_index], clipped) orelse return null;
    return rectFromEdges(visible.min_x, visible.min_y, visible.max_x, visible.max_y);
}

fn transformEffectRect(
    left: i64,
    top: i64,
    right: i64,
    bottom: i64,
    output: render.Size,
    transform: render.Transform,
) render.PlanRect {
    const width: i64 = output.width;
    const height: i64 = output.height;
    const edges: [4]i64 = switch (transform) {
        .normal => .{ left, top, right, bottom },
        .@"90" => .{ top, width - right, bottom, width - left },
        .@"180" => .{ width - right, height - bottom, width - left, height - top },
        .@"270" => .{ height - bottom, left, height - top, right },
        .flipped => .{ width - right, top, width - left, bottom },
        .flipped_90 => .{ top, left, bottom, right },
        .flipped_180 => .{ left, height - bottom, right, height - top },
        .flipped_270 => .{ height - bottom, width - right, height - top, width - left },
    };
    return .{
        .x = edges[0],
        .y = edges[1],
        .width = @intCast(edges[2] - edges[0]),
        .height = @intCast(edges[3] - edges[1]),
    };
}

fn subtractRect(
    allocator: std.mem.Allocator,
    output: *std.ArrayListUnmanaged(render.Rect),
    value: render.Rect,
    cover: render.Rect,
) !void {
    const overlap = intersectRect(value, cover) orelse {
        try output.append(allocator, value);
        return;
    };
    const left: i64 = value.x;
    const top: i64 = value.y;
    const right = left + value.width;
    const bottom = top + value.height;
    const overlap_right = @as(i64, overlap.x) + overlap.width;
    const overlap_bottom = @as(i64, overlap.y) + overlap.height;
    if (rectFromEdges(left, top, right, overlap.y)) |remaining| try output.append(allocator, remaining);
    if (rectFromEdges(left, overlap_bottom, right, bottom)) |remaining| try output.append(allocator, remaining);
    if (rectFromEdges(left, overlap.y, overlap.x, overlap_bottom)) |remaining| try output.append(allocator, remaining);
    if (rectFromEdges(overlap_right, overlap.y, right, overlap_bottom)) |remaining| try output.append(allocator, remaining);
}

fn intersectRect(a: render.Rect, b: render.Rect) ?render.Rect {
    return rectFromEdges(
        @max(a.x, b.x),
        @max(a.y, b.y),
        @min(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width),
        @min(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height),
    );
}

fn rectFromEdges(left: i64, top: i64, right: i64, bottom: i64) ?render.Rect {
    if (left < std.math.minInt(i32) or left > std.math.maxInt(i32) or
        top < std.math.minInt(i32) or top > std.math.maxInt(i32) or
        right <= left or bottom <= top or right - left > std.math.maxInt(u32) or
        bottom - top > std.math.maxInt(u32)) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn expandVertical(value: render.Rect, radius: u32, output: render.Size) render.Rect {
    const top = @max(@as(i64, 0), @as(i64, value.y) - radius);
    const bottom = @min(@as(i64, output.height), @as(i64, value.y) + value.height + radius);
    return .{ .x = value.x, .y = @intCast(top), .width = value.width, .height = @intCast(bottom - top) };
}

fn recordSampledBarrier(target: *RealTarget) void {
    var between: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = target.linear_image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &between);
}

fn recordRestartSampledPass(target: *RealTarget, uses_linear_image: bool) void {
    recordResumeAfterCapture(target);
    if (!uses_linear_image) return;
    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = target.linear_image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
}

fn sampledFrameReplayable(frame: Frame, prepared_batch: []const PreparedTexture) bool {
    if (frame.captures.before_cursor or frame.captures.after_cursor or
        frame.capture_destination != null or frameMayHaveBlur(frame))
        return false;
    for (prepared_batch) |prepared| if (prepared.native_token != null or
        prepared.imported_token != null or prepared.direct_external)
        return false;
    return true;
}

fn realDrawSampled(self: *RealRenderer, target: *RealTarget, frame: Frame) !std.posix.fd_t {
    const allocator = std.heap.c_allocator;
    const has_blur = try frameHasVisibleBlur(frame);
    if (has_blur and frame.samples.len > self.max_samples) return error.CapacityExceeded;
    const batch_count = try ensureSampledFrameCapacity(self, target, frame.samples.len);
    if (has_blur) try ensureBlurImage(self, target);
    const batch = try prepareTextures(self, frame, target.source_buffer_size);
    var prepared_owned = true;
    defer if (prepared_owned) cleanupPreparedTextures(self, batch.count);
    const content_tokens = try allocator.alloc(u64, frame.samples.len);
    defer allocator.free(content_tokens);
    var content_token_count: usize = 0;
    var content_tokens_owned = true;
    defer if (content_tokens_owned) for (content_tokens[0..content_token_count]) |token|
        releaseContent(self, token);
    const native_tokens = try allocator.alloc(u64, frame.samples.len);
    defer allocator.free(native_tokens);
    var native_token_count: usize = 0;
    var native_tokens_owned = true;
    defer if (native_tokens_owned) for (native_tokens[0..native_token_count]) |token|
        releaseNative(self, token);
    const imported_tokens = try allocator.alloc(u64, frame.samples.len);
    defer allocator.free(imported_tokens);
    var imported_token_count: usize = 0;
    var source_bridge_count: usize = 0;
    var imported_tokens_owned = true;
    defer if (imported_tokens_owned) for (imported_tokens[0..imported_token_count]) |token|
        releaseImported(self, token);
    const wait_capacity = std.math.add(
        usize,
        frame.samples.len,
        @intFromBool(frame.capture_destination != null),
    ) catch return error.CapacityExceeded;
    const wait_semaphores = try allocator.alloc(c.VkSemaphore, wait_capacity);
    defer allocator.free(wait_semaphores);
    const wait_stages = try allocator.alloc(c.VkPipelineStageFlags, wait_capacity);
    defer allocator.free(wait_stages);
    var wait_count: usize = 0;
    const acquire_fds = try allocator.alloc(std.posix.fd_t, frame.samples.len);
    defer allocator.free(acquire_fds);
    var acquire_fd_count: usize = 0;
    defer for (acquire_fds[0..acquire_fd_count]) |fd| if (fd >= 0) {
        _ = linux.close(fd);
    };

    for (self.prepared[0..batch.count]) |prepared| {
        if (prepared.upload_count == 0) continue;
        const token = prepared.content_token orelse continue;
        var present = false;
        for (content_tokens[0..content_token_count]) |existing|
            present = present or existing == token;
        if (present) continue;
        try retainContent(self, token);
        content_tokens[content_token_count] = token;
        content_token_count += 1;
    }
    for (self.prepared[0..batch.count]) |prepared| {
        if (prepared.native_token) |native_token| {
            var native_present = false;
            for (native_tokens[0..native_token_count]) |existing|
                native_present = native_present or existing == native_token;
            if (!native_present) {
                try retainNative(self, native_token);
                native_tokens[native_token_count] = native_token;
                native_token_count += 1;
            }
        }
        const imported_token = prepared.imported_token orelse continue;
        var imported_present = false;
        for (imported_tokens[0..imported_token_count]) |existing|
            imported_present = imported_present or existing == imported_token;
        if (!imported_present) {
            try retainImported(self, imported_token);
            imported_tokens[imported_token_count] = imported_token;
            imported_token_count += 1;
        }
        if (prepared.native_token != null) source_bridge_count += 1;
        const acquire_fd = if (prepared.native_token) |native_token| pending: {
            const pending = takePendingAcquire(self, native_token, .{
                .surface = prepared.surface,
                .commit_sequence = prepared.commit_sequence,
            }) orelse return error.MissingAcquireFence;
            if (pending.imported_token != imported_token) return error.ExternalIdentityMismatch;
            break :pending pending.fd;
        } else external: {
            const source = frame.sources[prepared.source_index].source.external orelse
                return error.MissingExternalSource;
            break :external try exportDmaBufFence(source.fds[0]);
        };
        acquire_fds[acquire_fd_count] = acquire_fd;
        acquire_fd_count += 1;
    }

    // A signaled sync_file remains signaled permanently, so importing it into
    // Vulkan cannot add an ordering dependency. Poll the batch once and keep
    // only genuinely pending acquire fences for the explicit wait bridge.
    if (acquire_fd_count != 0) {
        const descriptors = try allocator.alloc(std.posix.pollfd, acquire_fd_count);
        defer allocator.free(descriptors);
        for (acquire_fds[0..acquire_fd_count], descriptors) |fd, *descriptor| {
            descriptor.* = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        }
        if (std.posix.poll(descriptors, 0)) |_| {
            var pending_count: usize = 0;
            for (acquire_fds[0..acquire_fd_count], descriptors) |fd, descriptor| {
                if (descriptor.revents & linux.POLL.IN != 0) {
                    _ = linux.close(fd);
                } else {
                    acquire_fds[pending_count] = fd;
                    pending_count += 1;
                }
            }
            acquire_fd_count = pending_count;
        } else |_| {}
    }

    if (acquire_fd_count != 0) {
        const merged = if (acquire_fd_count > 1)
            mergeAcquireFences(acquire_fds[0..acquire_fd_count])
        else
            null;
        if (merged) |fd| {
            var owned = true;
            defer if (owned) {
                _ = linux.close(fd);
            };
            try importAcquireFence(self, target.acquire_semaphores[0], fd);
            owned = false;
            for (acquire_fds[0..acquire_fd_count]) |*original| {
                _ = linux.close(original.*);
                original.* = -1;
            }
            wait_semaphores[0] = target.acquire_semaphores[0];
            wait_stages[0] = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
            wait_count = 1;
        } else {
            for (acquire_fds[0..acquire_fd_count], 0..) |fd, index| {
                try importAcquireFence(self, target.acquire_semaphores[index], fd);
                acquire_fds[index] = -1;
                wait_semaphores[index] = target.acquire_semaphores[index];
                wait_stages[index] = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
                wait_count += 1;
            }
        }
    }

    const sample_stride = std.mem.alignForward(usize, self.sample_buffer_size, self.sample_region_alignment);
    const sample_map = @as([*]u8, @ptrCast(target.sample_map))[0..target.sample_buffer_size];
    for (0..batch_count) |batch_index| {
        const partition = batchAt(frame.samples.len, self.max_samples, batch_index);
        const bytes = std.mem.sliceAsBytes(frame.samples[partition.first..][0..partition.count]);
        @memcpy(sample_map[sample_stride * batch_index ..][0..bytes.len], bytes);
    }
    const staging = @as([*]u8, @ptrCast(target.source_map))[0..batch.staging_bytes];
    for (self.prepared[0..batch.count]) |prepared| {
        const source = frame.sources[prepared.source_index].source;
        if (prepared.native_token != null) continue;
        for (prepared.uploads[0..prepared.upload_count]) |upload| {
            if (upload.direct) continue;
            const row_bytes = @as(usize, upload.width) * 4;
            for (0..upload.height) |row| {
                const source_start = @as(usize, source.stride) * (upload.y + row) +
                    @as(usize, upload.x) * 4;
                const destination_start = upload.staging_offset + row_bytes * row;
                @memcpy(
                    staging[destination_start..][0..row_bytes],
                    source.bytes[source_start..][0..row_bytes],
                );
            }
        }
    }

    const prepared_batch = self.prepared[0..batch.count];
    const replayable = sampledFrameReplayable(frame, prepared_batch);
    const replay = replayable and target.recorded_sampled_frame.matches(
        self,
        target,
        frame,
        prepared_batch,
    );
    if (!replayable) target.recorded_sampled_frame.valid = false;
    if (!replay) {
        for (0..batch_count) |batch_index| {
            const partition = batchAt(frame.samples.len, self.max_samples, batch_index);
            var image_descriptors: [sampled_image_capacity]c.VkDescriptorImageInfo = undefined;
            for (frame.sources[partition.first..][0..partition.count], 0..) |surface, source_index| {
                const prepared = self.prepared[preparedIndex(prepared_batch, surface.sample.surface) orelse unreachable];
                image_descriptors[source_index] = .{ .sampler = self.sampler.?, .imageView = prepared.texture.view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
            }
            for (partition.count..sampled_image_capacity) |index| image_descriptors[index] = image_descriptors[0];
            var descriptor_write: c.VkWriteDescriptorSet = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .pNext = null,
                .dstSet = target.descriptor_sets[batch_index],
                .dstBinding = 3,
                .dstArrayElement = 0,
                .descriptorCount = sampled_image_capacity,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
                .pImageInfo = &image_descriptors,
                .pBufferInfo = null,
                .pTexelBufferView = null,
            };
            c.vkUpdateDescriptorSets(self.device, 1, &descriptor_write, 0, null);
        }

        try vk(c.vkResetCommandBuffer(target.command_buffer, 0), error.ResetCommandBufferFailed);
        var begin: c.VkCommandBufferBeginInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        try vk(c.vkBeginCommandBuffer(target.command_buffer, &begin), error.BeginCommandBufferFailed);
        var acquire_start: usize = 0;
        while (acquire_start < batch.count) : (acquire_start += sampled_image_capacity) {
            const acquire_end = @min(acquire_start + sampled_image_capacity, batch.count);
            var barriers: [sampled_image_capacity]c.VkImageMemoryBarrier = undefined;
            var barrier_count: usize = 0;
            for (self.prepared[acquire_start..acquire_end], acquire_start..) |prepared, index| {
                const token = prepared.imported_token orelse continue;
                if (prepared.native_token != null) continue;
                var duplicate = false;
                for (self.prepared[0..index]) |earlier|
                    duplicate = duplicate or (earlier.native_token == null and earlier.imported_token == token);
                if (duplicate) continue;
                barriers[barrier_count] = .{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = 0,
                    .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                    .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                    .newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
                    .dstQueueFamilyIndex = self.queue_family,
                    .image = prepared.texture.image,
                    .subresourceRange = colorRange(),
                };
                barrier_count += 1;
            }
            if (barrier_count == 0) continue;
            c.vkCmdPipelineBarrier(
                target.command_buffer,
                c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                @intCast(barrier_count),
                &barriers,
            );
        }
        for (self.prepared[0..batch.count]) |prepared| {
            if (prepared.upload_count == 0) continue;
            if (prepared.imported_token) |token| {
                const imported = importedFromToken(self, token) orelse
                    return error.StaleExternalImage;
                recordNativeCopies(self, target.command_buffer, prepared, imported);
            }
        }
        var upload_start: usize = 0;
        while (upload_start < batch.count) : (upload_start += sampled_image_capacity) {
            const upload_batch = self.prepared[upload_start..@min(
                upload_start + sampled_image_capacity,
                batch.count,
            )];
            var barriers: [sampled_image_capacity]c.VkImageMemoryBarrier = undefined;
            var barrier_count: usize = 0;
            for (upload_batch) |prepared| {
                if (prepared.upload_count == 0 or prepared.imported_token != null) continue;
                barriers[barrier_count] = .{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = if (prepared.texture.initialized) c.VK_ACCESS_SHADER_READ_BIT else 0,
                    .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
                    .oldLayout = if (prepared.texture.initialized)
                        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
                    else
                        c.VK_IMAGE_LAYOUT_UNDEFINED,
                    .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                    .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                    .image = prepared.texture.image,
                    .subresourceRange = colorRange(),
                };
                barrier_count += 1;
            }
            if (barrier_count == 0) continue;
            c.vkCmdPipelineBarrier(
                target.command_buffer,
                c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                0,
                0,
                null,
                0,
                null,
                @intCast(barrier_count),
                &barriers,
            );
            for (upload_batch) |prepared| {
                if (prepared.upload_count == 0 or prepared.imported_token != null) continue;
                for (prepared.uploads[0..prepared.upload_count]) |upload| {
                    var copy: c.VkBufferImageCopy = .{
                        .bufferOffset = upload.staging_offset,
                        .bufferRowLength = upload.row_length,
                        .bufferImageHeight = 0,
                        .imageSubresource = .{
                            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                            .mipLevel = 0,
                            .baseArrayLayer = 0,
                            .layerCount = 1,
                        },
                        .imageOffset = .{ .x = @intCast(upload.x), .y = @intCast(upload.y), .z = 0 },
                        .imageExtent = .{ .width = upload.width, .height = upload.height, .depth = 1 },
                    };
                    c.vkCmdCopyBufferToImage(
                        target.command_buffer,
                        if (upload.direct) self.content_buffer else target.source_buffer,
                        prepared.texture.image,
                        c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                        1,
                        &copy,
                    );
                }
            }
            for (barriers[0..barrier_count]) |*barrier| {
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            }
            c.vkCmdPipelineBarrier(
                target.command_buffer,
                c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                0,
                0,
                null,
                0,
                null,
                @intCast(barrier_count),
                &barriers,
            );
        }
        var target_barrier: c.VkImageMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
            .oldLayout = if (target.initialized_layout) c.VK_IMAGE_LAYOUT_GENERAL else c.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
            .dstQueueFamilyIndex = self.queue_family,
            .image = target.image,
            .subresourceRange = colorRange(),
        };
        c.vkCmdPipelineBarrier(
            target.command_buffer,
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &target_barrier,
        );
        const uses_linear_image = frame.samples.len > self.max_samples or has_blur;
        if (uses_linear_image) {
            var linear_barrier: c.VkImageMemoryBarrier = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext = null,
                .srcAccessMask = 0,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
                .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .image = target.linear_image,
                .subresourceRange = colorRange(),
            };
            c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &linear_barrier);
        }
        if (has_blur) {
            var blur_barrier: c.VkImageMemoryBarrier = .{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext = null,
                .srcAccessMask = 0,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
                .oldLayout = if (target.blur_initialized_layout)
                    c.VK_IMAGE_LAYOUT_GENERAL
                else
                    c.VK_IMAGE_LAYOUT_UNDEFINED,
                .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
                .image = target.blur_image,
                .subresourceRange = colorRange(),
            };
            c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 0, null, 0, null, 1, &blur_barrier);
        }
        var transfer_final = false;
        if (frame.captures.before_cursor) {
            if (has_blur)
                try recordBackdropEffectPass(self, target, frame, frame.cursor_start)
            else
                try recordSampledPass(self, target, frame, frame.cursor_start);
            recordCapture(
                self,
                target,
                frame,
                .before_cursor,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_ACCESS_SHADER_WRITE_BIT,
            );
            transfer_final = true;
            if (frame.cursor_start != frame.samples.len) {
                recordRestartSampledPass(target, uses_linear_image);
                if (has_blur)
                    try recordBackdropEffectPass(self, target, frame, frame.samples.len)
                else
                    try recordSampledPass(self, target, frame, frame.samples.len);
                transfer_final = false;
            }
        } else {
            if (has_blur)
                try recordBackdropEffectPass(self, target, frame, frame.samples.len)
            else
                try recordSampledPass(self, target, frame, frame.samples.len);
        }
        if (frame.captures.after_cursor) {
            if (transfer_final)
                recordCaptureCopy(self, target, frame, .after_cursor)
            else
                recordCapture(
                    self,
                    target,
                    frame,
                    .after_cursor,
                    c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                    c.VK_ACCESS_SHADER_WRITE_BIT,
                );
            transfer_final = true;
        }
        if (frame.capture_destination) |destination| {
            const capture: *RealCaptureTarget = @ptrCast(@alignCast(destination.target));
            wait_semaphores[wait_count] = capture.acquire_semaphore;
            wait_stages[wait_count] = c.VK_PIPELINE_STAGE_TRANSFER_BIT;
            wait_count += 1;
        }
        var release_start: usize = 0;
        while (release_start < batch.count) : (release_start += sampled_image_capacity) {
            const release_end = @min(release_start + sampled_image_capacity, batch.count);
            var barriers: [sampled_image_capacity]c.VkImageMemoryBarrier = undefined;
            var barrier_count: usize = 0;
            for (self.prepared[release_start..release_end], release_start..) |prepared, index| {
                const token = prepared.imported_token orelse continue;
                if (prepared.native_token != null) continue;
                var duplicate = false;
                for (self.prepared[0..index]) |earlier|
                    duplicate = duplicate or (earlier.native_token == null and earlier.imported_token == token);
                if (duplicate) continue;
                barriers[barrier_count] = .{
                    .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
                    .dstAccessMask = 0,
                    .oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                    .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
                    .srcQueueFamilyIndex = self.queue_family,
                    .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
                    .image = prepared.texture.image,
                    .subresourceRange = colorRange(),
                };
                barrier_count += 1;
            }
            if (barrier_count == 0) continue;
            c.vkCmdPipelineBarrier(
                target.command_buffer,
                c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
                0,
                0,
                null,
                0,
                null,
                @intCast(barrier_count),
                &barriers,
            );
        }
        var release_barrier: c.VkImageMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = if (transfer_final) c.VK_ACCESS_TRANSFER_READ_BIT else c.VK_ACCESS_SHADER_WRITE_BIT,
            .dstAccessMask = 0,
            .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
            .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
            .srcQueueFamilyIndex = self.queue_family,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
            .image = target.image,
            .subresourceRange = colorRange(),
        };
        c.vkCmdPipelineBarrier(
            target.command_buffer,
            if (transfer_final) c.VK_PIPELINE_STAGE_TRANSFER_BIT else c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
            0,
            0,
            null,
            0,
            null,
            1,
            &release_barrier,
        );
        try vk(c.vkEndCommandBuffer(target.command_buffer), error.EndCommandBufferFailed);
        if (replayable) try target.recorded_sampled_frame.replace(
            allocator,
            self,
            target,
            frame,
            prepared_batch,
        );
    }
    if (target.fence_needs_reset) {
        try vk(c.vkResetFences(self.device, 1, &target.fence), error.ResetFenceFailed);
        target.fence_needs_reset = false;
    }
    var submit: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = @intCast(wait_count),
        .pWaitSemaphores = if (wait_count == 0) null else wait_semaphores.ptr,
        .pWaitDstStageMask = if (wait_count == 0) null else wait_stages.ptr,
        .commandBufferCount = 1,
        .pCommandBuffers = &target.command_buffer,
        .signalSemaphoreCount = if (source_bridge_count == 0) 1 else 2,
        .pSignalSemaphores = &[_]c.VkSemaphore{ target.semaphore, target.source_semaphore },
    };
    if (c.vkQueueSubmit(self.queue, 1, &submit, target.fence) != c.VK_SUCCESS) {
        target.state = .queue_failed;
        return error.QueueSubmitFailed;
    }
    if (frame.capture_destination) |destination|
        (@as(*RealCaptureTarget, @ptrCast(@alignCast(destination.target)))).completion_fence = target.fence;
    target.state = .in_flight;
    target.initialized_layout = true;
    if (has_blur) target.blur_initialized_layout = true;
    target.captured = frame.captures;
    std.debug.assert(target.content_lease_count == 0);
    @memcpy(target.content_leases[0..content_token_count], content_tokens[0..content_token_count]);
    target.content_lease_count = content_token_count;
    content_tokens_owned = false;
    std.debug.assert(target.native_lease_count == 0);
    @memcpy(target.native_leases[0..native_token_count], native_tokens[0..native_token_count]);
    target.native_lease_count = native_token_count;
    native_tokens_owned = false;
    std.debug.assert(target.imported_lease_count == 0);
    @memcpy(target.imported_leases[0..imported_token_count], imported_tokens[0..imported_token_count]);
    target.imported_lease_count = imported_token_count;
    imported_tokens_owned = false;

    // Queue submission transfers ownership of every prepared object. Publish
    // those leases before any post-submit synchronization operation can fail.
    for (self.prepared[0..batch.count]) |prepared| {
        if (prepared.native_token != null or prepared.direct_external) continue;
        const cache = &self.cache[prepared.cache_index];
        if (prepared.retire_previous) {
            std.debug.assert(target.retired_texture_count < target.retired_textures.len);
            target.retired_textures[target.retired_texture_count] = cache.texture;
            target.retired_texture_count += 1;
        }
        var texture = prepared.texture;
        texture.initialized = true;
        cache.* = .{
            .occupied = true,
            .surface = prepared.surface,
            .commit_sequence = prepared.commit_sequence,
            .format = prepared.format,
            .texture = texture,
        };
    }
    prepared_owned = false;

    // Snapshot imports release their protocol source before presentation, so
    // bridge GPU completion back into each DMA-BUF reservation. Direct sampled
    // sources remain leased until replacement or detach with no frame in
    // flight; their protocol lifetime already proves GPU completion.
    var source_safe = source_bridge_count == 0;
    var source_exported = source_bridge_count == 0;
    if (source_bridge_count != 0) source_sync: {
        var source_fd_info: c.VkSemaphoreGetFdInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .pNext = null,
            .semaphore = target.source_semaphore,
            .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
        };
        var source_completion_fd: c_int = -1;
        if (self.get_semaphore_fd.?(self.device, &source_fd_info, &source_completion_fd) != c.VK_SUCCESS or
            source_completion_fd < 0) break :source_sync;
        source_exported = true;
        defer _ = linux.close(source_completion_fd);
        for (self.prepared[0..batch.count]) |prepared| {
            if (prepared.imported_token == null or prepared.native_token == null) continue;
            const source = frame.sources[prepared.source_index].source.external orelse
                break :source_sync;
            importDmaBufFence(source.fds[0], source_completion_fd) catch break :source_sync;
        }
        source_safe = true;
    }
    if (!source_safe) {
        try vk(
            c.vkWaitForFences(self.device, 1, &target.fence, c.VK_TRUE, std.math.maxInt(u64)),
            error.SourceCompletionWaitFailed,
        );
        source_safe = true;
    }
    std.debug.assert(source_safe);
    if (!source_exported) {
        const replacement = createExportSemaphore(self) catch {
            markNativeReady(self, self.prepared[0..batch.count]);
            target.state = .export_failed;
            return error.CompletionExportFailedAfterSubmit;
        };
        c.vkDestroySemaphore(self.device, target.source_semaphore, null);
        target.source_semaphore = replacement;
    }
    markNativeReady(self, self.prepared[0..batch.count]);
    var fd_info: c.VkSemaphoreGetFdInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
        .pNext = null,
        .semaphore = target.semaphore,
        .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    var completion_fd: c_int = -1;
    if (self.get_semaphore_fd.?(self.device, &fd_info, &completion_fd) != c.VK_SUCCESS or
        completion_fd < 0)
    {
        target.state = .export_failed;
        return error.CompletionExportFailedAfterSubmit;
    }
    return completion_fd;
}

fn markNativeReady(self: *RealRenderer, prepared_batch: []const PreparedTexture) void {
    for (prepared_batch) |prepared| if (prepared.native_token) |token| {
        const allocation = nativeAllocation(self, token) orelse unreachable;
        if (prepared.upload_count != 0) {
            allocation.texture.initialized = true;
            allocation.ready = .{
                .surface = prepared.surface,
                .commit_sequence = prepared.commit_sequence,
            };
        }
    };
}

fn recordNativeCopies(
    self: *RealRenderer,
    command_buffer: c.VkCommandBuffer,
    prepared: PreparedTexture,
    imported: *ImportedImage,
) void {
    const source_before: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .dstQueueFamilyIndex = self.queue_family,
        .image = imported.image,
        .subresourceRange = colorRange(),
    };
    const destination_before: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = if (prepared.texture.initialized) c.VK_ACCESS_SHADER_READ_BIT else 0,
        .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = if (prepared.texture.initialized)
            c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        else
            c.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = prepared.texture.image,
        .subresourceRange = colorRange(),
    };
    const before = [_]c.VkImageMemoryBarrier{ source_before, destination_before };
    c.vkCmdPipelineBarrier(
        command_buffer,
        if (prepared.texture.initialized)
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT
        else
            c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        before.len,
        &before,
    );
    for (prepared.uploads[0..prepared.upload_count]) |upload| {
        var copy: c.VkImageCopy = .{
            .srcSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .srcOffset = .{ .x = @intCast(upload.x), .y = @intCast(upload.y), .z = 0 },
            .dstSubresource = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .mipLevel = 0,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
            .dstOffset = .{ .x = @intCast(upload.x), .y = @intCast(upload.y), .z = 0 },
            .extent = .{ .width = upload.width, .height = upload.height, .depth = 1 },
        };
        c.vkCmdCopyImage(
            command_buffer,
            imported.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            prepared.texture.image,
            c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            1,
            &copy,
        );
    }
    const source_after: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT,
        .dstAccessMask = 0,
        .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = self.queue_family,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .image = imported.image,
        .subresourceRange = colorRange(),
    };
    const destination_after: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        .newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = prepared.texture.image,
        .subresourceRange = colorRange(),
    };
    const after = [_]c.VkImageMemoryBarrier{ source_after, destination_after };
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        0,
        null,
        0,
        null,
        after.len,
        &after,
    );
}

fn drainRetiredTextures(self: *RealRenderer, target: *RealTarget) void {
    for (target.retired_textures[0..target.retired_texture_count]) |texture|
        destroyTexture(self, texture);
    target.retired_texture_count = 0;
}

fn drainContentLeases(self: *RealRenderer, target: *RealTarget) void {
    for (target.content_leases[0..target.content_lease_count]) |token|
        releaseContent(self, token);
    target.content_lease_count = 0;
}

fn drainNativeLeases(self: *RealRenderer, target: *RealTarget) void {
    for (target.native_leases[0..target.native_lease_count]) |token|
        releaseNative(self, token);
    target.native_lease_count = 0;
}

fn drainImportedLeases(self: *RealRenderer, target: *RealTarget) void {
    for (target.imported_leases[0..target.imported_lease_count]) |token|
        releaseImported(self, token);
    target.imported_lease_count = 0;
}

fn choosePhysicalDevice(instance: c.VkInstance, drm_fd: std.posix.fd_t) !c.VkPhysicalDevice {
    var stat: c.struct_stat = undefined;
    if (c.fstat(drm_fd, &stat) != 0) return error.StatDrmDeviceFailed;
    const expected_major: i64 = @intCast(c.major(stat.st_rdev));
    const expected_minor: i64 = @intCast(c.minor(stat.st_rdev));
    var count: u32 = 0;
    try vk(c.vkEnumeratePhysicalDevices(instance, &count, null), error.EnumeratePhysicalDevicesFailed);
    if (count == 0 or count > 32) return error.NoMatchingDrmDevice;
    var devices: [32]c.VkPhysicalDevice = undefined;
    try vk(c.vkEnumeratePhysicalDevices(instance, &count, &devices), error.EnumeratePhysicalDevicesFailed);
    for (devices[0..count]) |device| {
        var drm_properties: c.VkPhysicalDeviceDrmPropertiesEXT = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT, .pNext = null, .hasPrimary = c.VK_FALSE, .hasRender = c.VK_FALSE, .primaryMajor = 0, .primaryMinor = 0, .renderMajor = 0, .renderMinor = 0 };
        var properties: c.VkPhysicalDeviceProperties2 = .{ .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, .pNext = &drm_properties, .properties = undefined };
        c.vkGetPhysicalDeviceProperties2(device, &properties);
        if (drm_properties.hasPrimary == c.VK_TRUE and drm_properties.hasRender == c.VK_TRUE and
            drm_properties.primaryMajor == expected_major and drm_properties.primaryMinor == expected_minor)
            return device;
    }
    return error.NoMatchingDrmDevice;
}

fn requireSyncFdSemaphore(device: c.VkPhysicalDevice) !void {
    var info: c.VkPhysicalDeviceExternalSemaphoreInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO,
        .pNext = null,
        .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
    };
    var properties: c.VkExternalSemaphoreProperties = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES,
        .pNext = null,
        .exportFromImportedHandleTypes = 0,
        .compatibleHandleTypes = 0,
        .externalSemaphoreFeatures = 0,
    };
    c.vkGetPhysicalDeviceExternalSemaphoreProperties(device, &info, &properties);
    if (properties.externalSemaphoreFeatures &
        (c.VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT |
            c.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT) !=
        (c.VK_EXTERNAL_SEMAPHORE_FEATURE_EXPORTABLE_BIT |
            c.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT) or
        properties.compatibleHandleTypes & c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT == 0)
        return error.SyncFdSemaphoreUnsupported;
}

fn requireDeviceExtensions(device: c.VkPhysicalDevice) !void {
    var count: u32 = 0;
    try vk(
        c.vkEnumerateDeviceExtensionProperties(device, null, &count, null),
        error.EnumerateDeviceExtensionsFailed,
    );
    if (count == 0 or count > 256) return error.RequiredDeviceExtensionMissing;
    var properties: [256]c.VkExtensionProperties = undefined;
    try vk(
        c.vkEnumerateDeviceExtensionProperties(device, null, &count, &properties),
        error.EnumerateDeviceExtensionsFailed,
    );
    for (device_extensions) |required| {
        var found = false;
        for (properties[0..count]) |property| {
            if (std.mem.eql(u8, std.mem.span(required), std.mem.sliceTo(&property.extensionName, 0))) {
                found = true;
                break;
            }
        }
        if (!found) return error.RequiredDeviceExtensionMissing;
    }
}

fn requireTargetFormat(device: c.VkPhysicalDevice, metadata: gbm.Metadata) !void {
    try requireModifierStorage(device, c.VK_FORMAT_B8G8R8A8_UNORM, metadata);
    try requireModifierStorage(device, c.VK_FORMAT_R8G8B8A8_UNORM, metadata);

    const view_formats = [_]c.VkFormat{ c.VK_FORMAT_B8G8R8A8_UNORM, c.VK_FORMAT_R8G8B8A8_UNORM };
    var format_list: c.VkImageFormatListCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_LIST_CREATE_INFO,
        .pNext = null,
        .viewFormatCount = view_formats.len,
        .pViewFormats = &view_formats,
    };
    var modifier_info: c.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .pNext = &format_list,
        .drmFormatModifier = metadata.modifier,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var external_info: c.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier_info,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var image_info: c.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external_info,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .type = c.VK_IMAGE_TYPE_2D,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        .flags = c.VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT,
    };
    var external_properties: c.VkExternalImageFormatProperties = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        .pNext = null,
        .externalMemoryProperties = undefined,
    };
    var image_properties: c.VkImageFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
        .imageFormatProperties = undefined,
    };
    try vk(
        c.vkGetPhysicalDeviceImageFormatProperties2(device, &image_info, &image_properties),
        error.ModifierStorageUnsupported,
    );
    if (metadata.width > image_properties.imageFormatProperties.maxExtent.width or
        metadata.height > image_properties.imageFormatProperties.maxExtent.height)
        return error.TargetExtentUnsupported;
    const external = external_properties.externalMemoryProperties;
    if (external.externalMemoryFeatures & c.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT == 0 or
        external.compatibleHandleTypes & c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT == 0)
        return error.DmaBufImportUnsupported;
}

fn requireCaptureTargetFormat(device: c.VkPhysicalDevice, metadata: gbm.Metadata) !void {
    var modifier_info: c.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = metadata.modifier,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var external_info: c.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier_info,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var image_info: c.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external_info,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .type = c.VK_IMAGE_TYPE_2D,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .flags = 0,
    };
    var external_properties: c.VkExternalImageFormatProperties = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        .pNext = null,
        .externalMemoryProperties = undefined,
    };
    var image_properties: c.VkImageFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
        .imageFormatProperties = undefined,
    };
    try vk(
        c.vkGetPhysicalDeviceImageFormatProperties2(device, &image_info, &image_properties),
        error.CaptureTargetUnsupported,
    );
    if (metadata.width > image_properties.imageFormatProperties.maxExtent.width or
        metadata.height > image_properties.imageFormatProperties.maxExtent.height)
        return error.TargetExtentUnsupported;
    const external = external_properties.externalMemoryProperties;
    if (external.externalMemoryFeatures & c.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT == 0 or
        external.compatibleHandleTypes & c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT == 0)
        return error.DmaBufImportUnsupported;
}

fn requireModifierStorage(device: c.VkPhysicalDevice, format: c.VkFormat, metadata: gbm.Metadata) !void {
    var modifier_list: c.VkDrmFormatModifierPropertiesListEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        .pNext = null,
        .drmFormatModifierCount = 0,
        .pDrmFormatModifierProperties = null,
    };
    var format_properties: c.VkFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = &modifier_list,
        .formatProperties = undefined,
    };
    c.vkGetPhysicalDeviceFormatProperties2(device, format, &format_properties);
    if (modifier_list.drmFormatModifierCount == 0 or modifier_list.drmFormatModifierCount > 64)
        return error.ModifierUnsupported;
    var modifiers: [64]c.VkDrmFormatModifierPropertiesEXT = undefined;
    modifier_list.pDrmFormatModifierProperties = &modifiers;
    c.vkGetPhysicalDeviceFormatProperties2(device, format, &format_properties);
    var found = false;
    for (modifiers[0..modifier_list.drmFormatModifierCount]) |modifier| {
        if (modifier.drmFormatModifier != metadata.modifier) continue;
        if (modifier.drmFormatModifierPlaneCount != metadata.plane_count)
            return error.ModifierPlaneCountMismatch;
        if (modifier.drmFormatModifierTilingFeatures & c.VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT == 0)
            return error.ModifierStorageUnsupported;
        found = true;
        break;
    }
    if (!found) return error.ModifierUnsupported;
}

fn chooseQueueFamily(device: c.VkPhysicalDevice) !u32 {
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, null);
    if (count == 0 or count > 64) return error.NoComputeQueue;
    var properties: [64]c.VkQueueFamilyProperties = undefined;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &count, &properties);
    for (properties[0..count], 0..) |property, index|
        if (property.queueCount != 0 and property.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) return @intCast(index);
    return error.NoComputeQueue;
}

fn createHostBuffer(self: *RealRenderer, size: usize, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory, map: **anyopaque) !void {
    var info: c.VkBufferCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .pNext = null, .flags = 0, .size = size, .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE, .queueFamilyIndexCount = 0, .pQueueFamilyIndices = null };
    try vk(c.vkCreateBuffer(self.device, &info, null, buffer), error.CreateBufferFailed);
    var buffer_only_cleanup = true;
    errdefer if (buffer_only_cleanup) c.vkDestroyBuffer(self.device, buffer.*, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(self.device, buffer.*, &requirements);
    var allocation: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .pNext = null, .allocationSize = requirements.size, .memoryTypeIndex = try memoryType(self, requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, memory), error.AllocateBufferMemoryFailed);
    buffer_only_cleanup = false;
    errdefer {
        c.vkDestroyBuffer(self.device, buffer.*, null);
        c.vkFreeMemory(self.device, memory.*, null);
    }
    try vk(c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0), error.BindBufferMemoryFailed);
    var mapped: ?*anyopaque = null;
    try vk(c.vkMapMemory(self.device, memory.*, 0, size, 0, &mapped), error.MapBufferFailed);
    map.* = mapped orelse return error.MapBufferFailed;
}

fn createReadbackBuffer(self: *RealRenderer, size: usize, buffer: *c.VkBuffer, memory: *c.VkDeviceMemory, map: **anyopaque) !void {
    var info: c.VkBufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .size = size,
        .usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    try vk(c.vkCreateBuffer(self.device, &info, null, buffer), error.CreateReadbackBufferFailed);
    var buffer_only_cleanup = true;
    errdefer if (buffer_only_cleanup) c.vkDestroyBuffer(self.device, buffer.*, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(self.device, buffer.*, &requirements);
    var allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        // CPU consumption dominates readback. Prefer cached host memory when
        // the device exposes it, while retaining coherent-only portability.
        .memoryTypeIndex = try preferredMemoryType(
            self,
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT,
        ),
    };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, memory), error.AllocateReadbackMemoryFailed);
    buffer_only_cleanup = false;
    errdefer {
        c.vkDestroyBuffer(self.device, buffer.*, null);
        c.vkFreeMemory(self.device, memory.*, null);
    }
    try vk(c.vkBindBufferMemory(self.device, buffer.*, memory.*, 0), error.BindReadbackMemoryFailed);
    var mapped: ?*anyopaque = null;
    try vk(c.vkMapMemory(self.device, memory.*, 0, size, 0, &mapped), error.MapReadbackFailed);
    map.* = mapped orelse return error.MapReadbackFailed;
}

fn captureStride(width: u32) !u32 {
    return std.math.mul(u32, width, 4) catch error.CaptureCapacityExceeded;
}

fn captureByteCount(width: u32, height: u32) !usize {
    return std.math.mul(usize, try captureStride(width), height) catch
        error.CaptureCapacityExceeded;
}

fn ensureReadbacks(self: *RealRenderer, target: *RealTarget, captures: Captures) !void {
    for ([_]CapturePhase{ .before_cursor, .after_cursor }) |phase| {
        const requested = switch (phase) {
            .before_cursor => captures.before_cursor,
            .after_cursor => captures.after_cursor,
        };
        const index = @intFromEnum(phase);
        if (!requested or target.readback_buffers[index] != null) continue;
        try createReadbackBuffer(
            self,
            target.readback_size,
            &target.readback_buffers[index],
            &target.readback_memories[index],
            &target.readback_maps[index],
        );
    }
}

fn destroyBuffer(self: *RealRenderer, buffer: c.VkBuffer, memory: c.VkDeviceMemory) void {
    c.vkUnmapMemory(self.device, memory);
    c.vkDestroyBuffer(self.device, buffer, null);
    c.vkFreeMemory(self.device, memory, null);
}

fn createLinearImage(
    self: *RealRenderer,
    width: u32,
    height: u32,
    image: *c.VkImage,
    memory: *c.VkDeviceMemory,
    view: *c.VkImageView,
) !void {
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = c.VK_IMAGE_USAGE_STORAGE_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    try vk(c.vkCreateImage(self.device, &image_info, null, image), error.CreateLinearImageFailed);
    errdefer c.vkDestroyImage(self.device, image.*, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.device, image.*, &requirements);
    var allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try memoryType(self, requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
    };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, memory), error.AllocateLinearImageMemoryFailed);
    errdefer c.vkFreeMemory(self.device, memory.*, null);
    try vk(c.vkBindImageMemory(self.device, image.*, memory.*, 0), error.BindLinearImageMemoryFailed);
    var view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image.*,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = colorRange(),
    };
    try vk(c.vkCreateImageView(self.device, &view_info, null, view), error.CreateLinearImageViewFailed);
}

fn destroyLinearImage(self: *RealRenderer, target: *RealTarget) void {
    c.vkDestroyImageView(self.device, target.linear_view, null);
    c.vkDestroyImage(self.device, target.linear_image, null);
    c.vkFreeMemory(self.device, target.linear_memory, null);
}

fn ensureBlurImage(self: *RealRenderer, target: *RealTarget) !void {
    if (target.blur_image != null) return;
    try createLinearImage(
        self,
        target.width,
        target.height,
        &target.blur_image,
        &target.blur_memory,
        &target.blur_view,
    );
    target.blur_initialized_layout = false;
    updateBlurDescriptors(self, target);
}

fn updateBlurDescriptors(self: *RealRenderer, target: *RealTarget) void {
    std.debug.assert(target.blur_image != null);
    var storage = c.VkDescriptorImageInfo{
        .sampler = null,
        .imageView = target.blur_view,
        .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
    };
    var linear_source = c.VkDescriptorImageInfo{
        .sampler = self.blur_sampler.?,
        .imageView = target.linear_view,
        .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
    };
    var blur_source = c.VkDescriptorImageInfo{
        .sampler = self.blur_sampler.?,
        .imageView = target.blur_view,
        .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL,
    };
    for (target.descriptor_sets) |set| {
        const writes = [_]c.VkWriteDescriptorSet{
            descriptorWrite(set, 7, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &storage, null),
            descriptorWrite(set, 8, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &linear_source, null),
            descriptorWrite(set, 9, c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, &blur_source, null),
        };
        c.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);
    }
}

fn destroyBlurImage(self: *RealRenderer, target: *RealTarget) void {
    c.vkDestroyImageView(self.device, target.blur_view, null);
    c.vkDestroyImage(self.device, target.blur_image, null);
    c.vkFreeMemory(self.device, target.blur_memory, null);
    target.blur_view = null;
    target.blur_image = null;
    target.blur_memory = null;
    target.blur_initialized_layout = false;
}

fn createTexture(self: *RealRenderer, size: render.Size) !Texture {
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .extent = .{ .width = size.width, .height = size.height, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_OPTIMAL,
        .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var texture: Texture = .{
        .image = undefined,
        .memory = undefined,
        .view = undefined,
        .size = size,
    };
    try vk(c.vkCreateImage(self.device, &image_info, null, &texture.image), error.CreateTextureFailed);
    errdefer c.vkDestroyImage(self.device, texture.image, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(self.device, texture.image, &requirements);
    var allocation: c.VkMemoryAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .pNext = null,
        .allocationSize = requirements.size,
        .memoryTypeIndex = try memoryType(
            self,
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        ),
    };
    try vk(c.vkAllocateMemory(self.device, &allocation, null, &texture.memory), error.AllocateTextureMemoryFailed);
    errdefer c.vkFreeMemory(self.device, texture.memory, null);
    try vk(c.vkBindImageMemory(self.device, texture.image, texture.memory, 0), error.BindTextureMemoryFailed);
    var view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = texture.image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .components = .{
            .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = colorRange(),
    };
    try vk(c.vkCreateImageView(self.device, &view_info, null, &texture.view), error.CreateTextureViewFailed);
    return texture;
}

fn destroyTexture(self: *RealRenderer, texture: Texture) void {
    c.vkDestroyImageView(self.device, texture.view, null);
    c.vkDestroyImage(self.device, texture.image, null);
    c.vkFreeMemory(self.device, texture.memory, null);
    bumpResourceEpoch(self);
}

fn bumpResourceEpoch(self: *RealRenderer) void {
    self.resource_epoch +%= 1;
    if (self.resource_epoch == 0) self.resource_epoch = 1;
}

fn preferredMemoryType(
    self: *const RealRenderer,
    bits: u32,
    required: c.VkMemoryPropertyFlags,
    preferred: c.VkMemoryPropertyFlags,
) !u32 {
    for (0..self.memory.memoryTypeCount) |index| if (bits & (@as(u32, 1) << @intCast(index)) != 0 and
        self.memory.memoryTypes[index].propertyFlags & (required | preferred) == required | preferred)
        return @intCast(index);
    return memoryType(self, bits, required);
}

fn memoryType(self: *const RealRenderer, bits: u32, required: c.VkMemoryPropertyFlags) !u32 {
    for (0..self.memory.memoryTypeCount) |index| if (bits & (@as(u32, 1) << @intCast(index)) != 0 and
        self.memory.memoryTypes[index].propertyFlags & required == required) return @intCast(index);
    return error.NoCompatibleMemoryType;
}

fn intersectMemoryTypeBits(image_bits: u32, fd_bits: u32) u32 {
    return image_bits & fd_bits;
}

fn descriptorBinding(binding: u32, descriptor_type: c.VkDescriptorType) c.VkDescriptorSetLayoutBinding {
    return .{ .binding = binding, .descriptorType = descriptor_type, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null };
}

fn descriptorWrite(set: c.VkDescriptorSet, binding: u32, descriptor_type: c.VkDescriptorType, image: ?*const c.VkDescriptorImageInfo, buffer: ?*const c.VkDescriptorBufferInfo) c.VkWriteDescriptorSet {
    return .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .pNext = null, .dstSet = set, .dstBinding = binding, .dstArrayElement = 0, .descriptorCount = 1, .descriptorType = descriptor_type, .pImageInfo = image, .pBufferInfo = buffer, .pTexelBufferView = null };
}

fn colorRange() c.VkImageSubresourceRange {
    return .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
}

fn vk(result: c.VkResult, failure: anyerror) !void {
    if (result != c.VK_SUCCESS) return failure;
}

test "render-vulkan: real Vulkan ABI and shader artifact are linked" {
    try std.testing.expect(real.context == @as(*anyopaque, @ptrCast(&real_context)));
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(Sample));
    const shader = @embedFile("vulkan_composite.spv");
    try std.testing.expect(shader.len > 20);
    try std.testing.expectEqual(@as(u32, 0x07230203), std.mem.readInt(u32, shader[0..4], .little));
    const sampled_shader = @embedFile("vulkan_texture_composite.spv");
    try std.testing.expect(sampled_shader.len > 20);
    try std.testing.expectEqual(
        @as(u32, 0x07230203),
        std.mem.readInt(u32, sampled_shader[0..4], .little),
    );
    try std.testing.expect(c.VK_QUEUE_FAMILY_FOREIGN_EXT != c.VK_QUEUE_FAMILY_IGNORED);
    try std.testing.expectEqual(@as(u32, 0b0010), intersectMemoryTypeBits(0b1010, 0b0110));
}

test "render-vulkan: sampled batches preserve order and only first initializes" {
    const expected = [_]Batch{
        .{ .first = 0, .count = 3, .initialize = true },
        .{ .first = 3, .count = 3, .initialize = false },
        .{ .first = 6, .count = 2, .initialize = false },
    };
    for (expected, 0..) |value, index|
        try std.testing.expectEqual(value, batchAt(8, 3, index));
    try std.testing.expectEqual(@as(u32, 3), @as(u32, 3) | 0);
    try std.testing.expectEqual(continuation_bit | 3, @as(u32, 3) | continuation_bit);
}

test "render-vulkan: sampled command replay ignores pixels and rejects recorded changes" {
    var recorded: RecordedSampledFrame = .{};
    defer recorded.deinit(std.testing.allocator);
    var renderer: RealRenderer = undefined;
    renderer.resource_epoch = 7;
    var target: RealTarget = undefined;
    target.initialized_layout = true;

    var pixels = [_]u8{0} ** 64;
    var source = testSurfaceSample(1, &pixels, .{});
    const sample: Sample = std.mem.zeroes(Sample);
    var prepared: PreparedTexture = .{
        .cache_index = 0,
        .source_index = 0,
        .texture = .{
            .image = null,
            .memory = null,
            .view = null,
            .size = source.source.size,
            .initialized = true,
        },
        .created = false,
        .retire_previous = false,
        .surface = source.sample.surface,
        .commit_sequence = source.sample.commit_sequence,
        .format = source.source.format,
    };
    prepared.uploads[0] = .{
        .x = 0,
        .y = 0,
        .width = 4,
        .height = 4,
        .staging_offset = 0,
        .row_length = 4,
        .direct = false,
    };
    prepared.upload_count = 1;
    const damage = [_]render.Rect{.{ .x = 0, .y = 0, .width = 4, .height = 4 }};
    const frame: Frame = .{
        .output = source.source.size,
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = @as([*]const Sample, @ptrCast(&sample))[0..1],
        .sources = @as([*]const render.SurfaceSample, @ptrCast(&source))[0..1],
        .source_byte_count = pixels.len,
        .render_damage = &damage,
    };
    try recorded.replace(
        std.testing.allocator,
        &renderer,
        &target,
        frame,
        @as([*]const PreparedTexture, @ptrCast(&prepared))[0..1],
    );
    pixels[0] = 1;
    source.sample.commit_sequence += 1;
    prepared.commit_sequence += 1;
    try std.testing.expect(recorded.matches(
        &renderer,
        &target,
        frame,
        @as([*]const PreparedTexture, @ptrCast(&prepared))[0..1],
    ));

    prepared.uploads[0].x = 1;
    try std.testing.expect(!recorded.matches(
        &renderer,
        &target,
        frame,
        @as([*]const PreparedTexture, @ptrCast(&prepared))[0..1],
    ));
    prepared.uploads[0].x = 0;
    renderer.resource_epoch += 1;
    try std.testing.expect(!recorded.matches(
        &renderer,
        &target,
        frame,
        @as([*]const PreparedTexture, @ptrCast(&prepared))[0..1],
    ));
}

test "render-vulkan: texture versions select no partial and full upload" {
    const pixels = [_]u8{0} ** 64;
    var sample = testSurfaceSample(2, &pixels, testUploadDamage(&.{.{
        .min_x = 1,
        .min_y = 1,
        .max_x = 3,
        .max_y = 2,
    }}));
    const texture: Texture = .{
        .image = undefined,
        .memory = undefined,
        .view = undefined,
        .size = sample.source.size,
        .initialized = true,
    };
    var existing: CacheEntry = .{
        .occupied = true,
        .surface = sample.sample.surface,
        .commit_sequence = 1,
        .format = sample.source.format,
        .texture = texture,
    };
    const partial = textureUpload(false, existing, sample);
    try std.testing.expectEqual(@as(u8, 1), partial.count);
    try std.testing.expectEqual(
        render.UploadRect{ .min_x = 1, .min_y = 1, .max_x = 3, .max_y = 2 },
        partial.rects[0],
    );
    existing.commit_sequence = 2;
    try std.testing.expectEqual(@as(u8, 0), textureUpload(false, existing, sample).count);
    existing.commit_sequence = 0;
    try std.testing.expectEqual(fullUpload(sample.source.size), textureUpload(false, existing, sample));
    try std.testing.expectEqual(fullUpload(sample.source.size), textureUpload(true, null, sample));
    sample.upload_damage = .{};
    existing.commit_sequence = 1;
    try std.testing.expectEqual(@as(u8, 0), textureUpload(false, existing, sample).count);
}

test "render-vulkan: adjacent sparse damage retains separate texture uploads" {
    const pixels = [_]u8{0} ** 64;
    const sample = testSurfaceSample(2, &pixels, testUploadDamage(&.{
        .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 },
        .{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 },
    }));
    const existing: CacheEntry = .{
        .occupied = true,
        .surface = sample.sample.surface,
        .commit_sequence = 1,
        .format = sample.source.format,
        .texture = .{
            .image = undefined,
            .memory = undefined,
            .view = undefined,
            .size = sample.source.size,
            .initialized = true,
        },
    };
    const uploads = textureUpload(false, existing, sample);
    try std.testing.expectEqual(@as(u8, 2), uploads.count);
    try std.testing.expectEqualSlices(render.UploadRect, sample.upload_damage.items(), uploads.items());
}

test "render-vulkan: native snapshots preserve exact adjacent damage history" {
    const pixels = [_]u8{0} ** 64;
    var sample = testSurfaceSample(2, &pixels, testUploadDamage(&.{
        .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 },
        .{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 },
    }));
    var allocation: NativeAllocation = .{
        .texture = .{
            .image = undefined,
            .memory = undefined,
            .view = undefined,
            .size = sample.source.size,
        },
    };
    try std.testing.expectEqual(fullUpload(sample.source.size), nativeTextureUpload(&allocation, sample));
    allocation.texture.initialized = true;
    allocation.ready = .{ .surface = sample.sample.surface, .commit_sequence = 1 };
    try std.testing.expectEqualSlices(
        render.UploadRect,
        sample.upload_damage.items(),
        nativeTextureUpload(&allocation, sample).items(),
    );
    allocation.ready = sample.sample;
    try std.testing.expectEqual(@as(u8, 0), nativeTextureUpload(&allocation, sample).count);
    sample.sample.commit_sequence = 4;
    try std.testing.expectEqual(fullUpload(sample.source.size), nativeTextureUpload(&allocation, sample));
}

test "render-vulkan: texture cache evicts only a surface absent from the frame" {
    const pixels = [_]u8{0} ** 64;
    var cache = [_]CacheEntry{
        .{ .occupied = true, .surface = 1 },
        .{ .occupied = true, .surface = 2 },
    };
    var visible = testSurfaceSample(1, &pixels, .{});
    const frame: Frame = .{
        .output = .{ .width = 4, .height = 4 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{},
        .sources = @as([*]render.SurfaceSample, @ptrCast(&visible))[0..1],
        .source_byte_count = pixels.len,
        .render_damage = &.{},
    };
    try std.testing.expectEqual(@as(?usize, 1), evictableCacheIndex(&cache, frame, &.{}));
    var reserved: PreparedTexture = .{
        .cache_index = 1,
        .source_index = 0,
        .texture = undefined,
        .created = true,
        .retire_previous = true,
        .surface = 3,
        .commit_sequence = 1,
        .format = .xrgb8888,
    };
    try std.testing.expect(evictableCacheIndex(
        &cache,
        frame,
        @as([*]PreparedTexture, @ptrCast(&reserved))[0..1],
    ) == null);
}

fn testSurfaceSample(
    sequence: u64,
    pixels: []const u8,
    upload_damage: render.UploadDamage,
) render.SurfaceSample {
    return .{
        .sample = .{ .surface = 1, .commit_sequence = sequence },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 4, .height = 4 },
            .stride = 16,
            .format = .xrgb8888,
            .bytes = pixels,
        },
        .upload_damage = upload_damage,
        .crop = render.SourceRect.pixels(0, 0, 4, 4),
        .destination = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .clip = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
    };
}

fn testUploadDamage(rects: []const render.UploadRect) render.UploadDamage {
    var damage: render.UploadDamage = .{};
    std.debug.assert(rects.len <= damage.rects.len);
    @memcpy(damage.rects[0..rects.len], rects);
    damage.count = @intCast(rects.len);
    return damage;
}

test "vulkan backdrop regions preserve ordered union and subtraction" {
    const operations = [_]render.RegionOperation{
        .{ .add = .{ .x = 0, .y = 0, .width = 10, .height = 10 } },
        .{ .subtract = .{ .x = 2, .y = 2, .width = 6, .height = 6 } },
        .{ .add = .{ .x = 4, .y = 4, .width = 2, .height = 2 } },
    };
    var rectangles: std.ArrayListUnmanaged(render.Rect) = .empty;
    defer rectangles.deinit(std.testing.allocator);
    try canonicalRegion(
        std.testing.allocator,
        .{ .width = 10, .height = 10 },
        &operations,
        &rectangles,
    );
    try std.testing.expectEqualSlices(render.Rect, &.{
        .{ .x = 0, .y = 0, .width = 10, .height = 2 },
        .{ .x = 0, .y = 8, .width = 10, .height = 2 },
        .{ .x = 0, .y = 2, .width = 2, .height = 6 },
        .{ .x = 8, .y = 2, .width = 2, .height = 6 },
        .{ .x = 4, .y = 4, .width = 2, .height = 2 },
    }, rectangles.items);
}

test "vulkan backdrop blur is inactive when opaque coverage hides its region" {
    const pixel = [_]u8{0} ** 4;
    const whole = [_]render.RegionOperation{.{
        .add = .{ .x = 0, .y = 0, .width = 20, .height = 10 },
    }};
    var source: render.SurfaceSample = .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .argb8888_premultiplied,
            .bytes = &pixel,
        },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 10, .y = 15, .width = 40, .height = 20 },
        .clip = .{ .x = 0, .y = 0, .width = 100, .height = 80 },
        .effect_size = .{ .width = 20, .height = 10 },
        .opaque_region = &whole,
        .blur_region = &whole,
    };
    const packed_sample: Sample = .{
        .source = .{ 0, 1, 1, 4 },
        .crop = .{ 0, 0, render.fixed_one, render.fixed_one },
        .destination = .{ 10, 15, 40, 20 },
        .clip = .{ 0, 0, 100, 80 },
        .attributes = @splat(0),
        .affine = @splat(0),
        .affine_tail = @splat(0),
        .color_matrix_0 = @splat(0),
        .color_matrix_1 = @splat(0),
        .color_matrix_2 = @splat(0),
    };
    var frame: Frame = .{
        .output = .{ .width = 100, .height = 80 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{packed_sample},
        .sources = &.{source},
        .source_byte_count = 4,
        .render_damage = &.{.{ .x = 0, .y = 0, .width = 100, .height = 80 }},
    };
    try std.testing.expect(!try frameHasVisibleBlur(frame));

    source.opaque_region = &.{.{
        .add = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    }};
    frame.sources = &.{source};
    try std.testing.expect(try frameHasVisibleBlur(frame));
    var mapped = try mappedBlurRects(std.testing.allocator, frame, 0);
    defer mapped.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(render.Rect, &.{.{
        .x = 30,
        .y = 15,
        .width = 20,
        .height = 20,
    }}, mapped.items);
}
