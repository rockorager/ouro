//! Replaceable Vulkan ABI boundary. Borrowed source rows are synchronously
//! packed into target-owned mapped storage; renderer policy never sees a Vulkan
//! object. DMA-BUF and sync_file FD ownership remains explicit.

const std = @import("std");
const linux = std.os.linux;
const gbm = @import("../backend/gbm.zig");
const render = @import("types.zig");
const render_content = @import("content.zig");

const c = @cImport({
    @cInclude("drm_fourcc.h");
    @cInclude("linux/dma-buf.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/sysmacros.h");
    @cInclude("sys/stat.h");
    @cInclude("vulkan/vulkan.h");
});

pub const Renderer = *anyopaque;
pub const Target = *anyopaque;

pub const Config = struct {
    max_samples: usize,
    max_source_bytes: usize,
    max_targets: usize,
    content_bytes: usize = 1,
    content_allocations: usize = 1,
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
};

pub const Frame = struct {
    output: render.Size,
    output_format: render.PixelFormat,
    clear: render.Color,
    samples: []const Sample,
    sources: []const render.SurfaceSample,
    source_byte_count: usize,
    render_damage: []const render.Rect,
};

pub const Platform = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, std.posix.fd_t, Config) anyerror!Renderer,
        destroy: *const fn (*anyopaque, Renderer) void,
        import_target: *const fn (*anyopaque, Renderer, gbm.Metadata, std.posix.fd_t) anyerror!Target,
        destroy_target: *const fn (*anyopaque, Renderer, Target) void,
        draw: *const fn (*anyopaque, Renderer, Target, Frame) anyerror!std.posix.fd_t,
        content_provider: *const fn (*anyopaque, Renderer) ?render_content.Provider,
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
    pub fn draw(self: Platform, renderer: Renderer, target: Target, frame: Frame) !std.posix.fd_t {
        return self.vtable.draw(self.context, renderer, target, frame);
    }
    pub fn contentProvider(self: Platform, renderer: Renderer) ?render_content.Provider {
        return self.vtable.content_provider(self.context, renderer);
    }
};

var real_context: u8 = 0;
pub const real: Platform = .{ .context = &real_context, .vtable = &real_vtable };

const real_vtable: Platform.VTable = .{
    .create = realCreate,
    .destroy = realDestroy,
    .import_target = realImportTarget,
    .destroy_target = realDestroyTarget,
    .draw = realDraw,
    .content_provider = realContentProvider,
};

const device_extensions = [_][*:0]const u8{
    c.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    c.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    c.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    c.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME,
    c.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
    c.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
};

const sampled_image_capacity = 8;

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
};

const PendingAcquire = struct {
    occupied: bool = false,
    native_token: u64 = 0,
    identity: render.SampleIdentity = undefined,
    imported_token: u64 = 0,
    fd: std.posix.fd_t = -1,
};

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
    cache: []CacheEntry,
    prepared: []PreparedTexture,
    sampled_enabled: bool,
    get_memory_fd_properties: c.PFN_vkGetMemoryFdPropertiesKHR,
    get_semaphore_fd: c.PFN_vkGetSemaphoreFdKHR,
    import_semaphore_fd: c.PFN_vkImportSemaphoreFdKHR,
    max_samples: usize,
    sample_buffer_size: usize,
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
};

const TargetState = enum { ready, in_flight, queue_failed, export_failed };

const RealTarget = struct {
    image: c.VkImage,
    image_memory: c.VkDeviceMemory,
    view: c.VkImageView,
    sample_buffer: c.VkBuffer,
    sample_memory: c.VkDeviceMemory,
    sample_map: *anyopaque,
    source_buffer: c.VkBuffer,
    source_memory: c.VkDeviceMemory,
    source_map: *anyopaque,
    descriptor_set: c.VkDescriptorSet,
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
};

const Push = extern struct {
    clear_color: [4]u32,
    output: [4]u32,
    damage: [4]u32,
};

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
    const descriptor_count = std.math.mul(usize, config.max_targets, 2) catch
        return error.InvalidConfig;
    const sampled_descriptor_count = std.math.mul(
        usize,
        config.max_targets,
        sampled_image_capacity,
    ) catch return error.InvalidConfig;
    if (physical_properties.apiVersion < c.VK_API_VERSION_1_2 or
        sample_size == 0 or sample_size > physical_properties.limits.maxStorageBufferRange or
        config.max_source_bytes == 0 or
        config.max_source_bytes > physical_properties.limits.maxStorageBufferRange or
        config.content_bytes == 0 or config.content_allocations == 0 or
        config.content_allocations > std.math.maxInt(u32) or
        config.max_targets == 0 or config.max_targets > std.math.maxInt(u32) or
        descriptor_count > std.math.maxInt(u32) or
        physical_properties.limits.maxPerStageDescriptorStorageBuffers < 2 or
        physical_properties.limits.maxDescriptorSetStorageBuffers < 2 or
        physical_properties.limits.maxPerStageDescriptorStorageImages < 1 or
        physical_properties.limits.maxDescriptorSetStorageImages < 1)
        return error.InvalidConfig;
    self.sampled_enabled = config.max_samples <= sampled_image_capacity and
        sampled_descriptor_count <= std.math.maxInt(u32) and
        physical_features.shaderSampledImageArrayDynamicIndexing == c.VK_TRUE and
        physical_properties.limits.maxPerStageDescriptorSampledImages >= sampled_image_capacity and
        physical_properties.limits.maxDescriptorSetSampledImages >= sampled_image_capacity and
        physical_properties.limits.maxPerStageDescriptorSamplers >= sampled_image_capacity and
        physical_properties.limits.maxDescriptorSetSamplers >= sampled_image_capacity and
        source_format.optimalTilingFeatures &
            (c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT) ==
            (c.VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT);
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
        .{
            .binding = 3,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = sampled_image_capacity,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };
    var descriptor_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = if (self.sampled_enabled) bindings.len else bindings.len - 1,
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
    }
    errdefer if (self.sampled_pipeline) |pipeline|
        c.vkDestroyPipeline(self.device, pipeline, null);
    const pool_sizes = [_]c.VkDescriptorPoolSize{
        .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = @intCast(config.max_targets) },
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
        self.cache = try allocator.alloc(CacheEntry, config.max_samples);
        @memset(self.cache, .{});
        errdefer allocator.free(self.cache);
        self.prepared = try allocator.alloc(PreparedTexture, config.max_samples);
        errdefer allocator.free(self.prepared);
    }
    self.max_samples = config.max_samples;
    self.sample_buffer_size = sample_size;
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
    destroyBuffer(self, self.content_buffer, self.content_memory);
    std.heap.c_allocator.free(self.content_allocations);
    for (self.cache) |entry| if (entry.occupied) destroyTexture(self, entry.texture);
    std.heap.c_allocator.free(self.prepared);
    std.heap.c_allocator.free(self.cache);
    if (self.sampler) |sampler| c.vkDestroySampler(self.device, sampler, null);
    c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    if (self.sampled_pipeline) |pipeline| c.vkDestroyPipeline(self.device, pipeline, null);
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
    };
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
    const pending = for (self.pending_acquires) |*candidate| {
        if (!candidate.occupied) break candidate;
    } else return error.AcquireCapacityExceeded;
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
    } else return error.ContentAllocationCapacityExceeded;
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
    } else return error.ContentAllocationCapacityExceeded;
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

fn nativePinned(context: *anyopaque, token: u64) bool {
    const allocation = nativeAllocation(@ptrCast(@alignCast(context)), token) orelse return false;
    return allocation.references > 1;
}

fn nativeReady(context: *anyopaque, token: u64, identity: render.SampleIdentity) bool {
    const allocation = nativeAllocation(@ptrCast(@alignCast(context)), token) orelse return false;
    return if (allocation.ready) |ready| std.meta.eql(ready, identity) else false;
}

fn importedImage(self: *RealRenderer, source: render.ExternalSource, size: render.Size, format: render.PixelFormat) !u64 {
    if (source.plane_count != 1 or source.fds[0] < 0 or source.strides[0] == 0)
        return error.UnsupportedExternalSource;
    const vk_format: c.VkFormat = switch (format) {
        .xrgb8888, .argb8888_premultiplied => c.VK_FORMAT_B8G8R8A8_UNORM,
    };
    const expected_drm: u32 = switch (format) {
        .xrgb8888 => c.DRM_FORMAT_XRGB8888,
        .argb8888_premultiplied => c.DRM_FORMAT_ARGB8888,
    };
    if (source.drm_format != expected_drm) return error.UnsupportedExternalFormat;
    for (self.imported_images, 0..) |*entry, index| if (entry.occupied and
        entry.source.context == source.context and entry.source.token == source.token)
    {
        if (!std.meta.eql(entry.source, source)) return error.ExternalIdentityMismatch;
        return importedToken(entry, index);
    };

    const index = for (self.imported_images, 0..) |entry, candidate| {
        if (!entry.occupied) break candidate;
    } else evict: {
        for (0..self.imported_images.len) |_| {
            const candidate = self.imported_cursor;
            self.imported_cursor = (self.imported_cursor + 1) % self.imported_images.len;
            if (self.imported_images[candidate].references == 1) break :evict candidate;
        }
        return error.ExternalImageCapacityExceeded;
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
        .usage = c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
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
    entry.generation +%= 1;
    if (entry.generation == 0) entry.generation = 1;
    entry.* = .{
        .occupied = true,
        .generation = entry.generation,
        .references = 1,
        .source = source,
        .image = image,
        .memory = memory,
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
    if (drm_format == c.DRM_FORMAT_XRGB8888) return .xrgb8888;
    if (drm_format == c.DRM_FORMAT_ARGB8888) return .argb8888_premultiplied;
    return null;
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
    c.vkDestroyImage(self.device, entry.image, null);
    c.vkFreeMemory(self.device, entry.memory, null);
    const generation = entry.generation;
    entry.* = .{ .generation = generation };
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
    var export_file: c.struct_dma_buf_export_sync_file = .{
        .flags = c.DMA_BUF_SYNC_READ,
        .fd = -1,
    };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_EXPORT_SYNC_FILE, &export_file) != 0 or
        export_file.fd < 0) return error.ExportAcquireFenceFailed;
    return export_file.fd;
}

fn importDmaBufFence(fd: std.posix.fd_t, sync_fd: std.posix.fd_t) !void {
    var import_file: c.struct_dma_buf_import_sync_file = .{
        .flags = c.DMA_BUF_SYNC_READ,
        .fd = sync_fd,
    };
    if (c.ioctl(fd, c.DMA_BUF_IOCTL_IMPORT_SYNC_FILE, &import_file) != 0)
        return error.ImportCompletionFenceFailed;
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
        .usage = c.VK_IMAGE_USAGE_STORAGE_BIT,
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

    const sample_size = self.sample_buffer_size;
    try createHostBuffer(self, sample_size, &target.sample_buffer, &target.sample_memory, &target.sample_map);
    errdefer destroyBuffer(self, target.sample_buffer, target.sample_memory);
    try createHostBuffer(self, self.staging_buffer_size, &target.source_buffer, &target.source_memory, &target.source_map);
    errdefer destroyBuffer(self, target.source_buffer, target.source_memory);

    var set_info: c.VkDescriptorSetAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .pNext = null, .descriptorPool = self.descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &self.descriptor_layout };
    try vk(c.vkAllocateDescriptorSets(self.device, &set_info, &target.descriptor_set), error.AllocateDescriptorSetFailed);
    errdefer _ = c.vkFreeDescriptorSets(self.device, self.descriptor_pool, 1, &target.descriptor_set);
    var image_descriptor: c.VkDescriptorImageInfo = .{ .sampler = null, .imageView = target.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
    var sample_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = target.sample_buffer, .offset = 0, .range = sample_size };
    var source_descriptor: c.VkDescriptorBufferInfo = .{ .buffer = target.source_buffer, .offset = 0, .range = self.max_source_bytes };
    const writes = [_]c.VkWriteDescriptorSet{
        descriptorWrite(target.descriptor_set, 0, c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, &image_descriptor, null),
        descriptorWrite(target.descriptor_set, 1, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &sample_descriptor),
        descriptorWrite(target.descriptor_set, 2, c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, null, &source_descriptor),
    };
    c.vkUpdateDescriptorSets(self.device, writes.len, &writes, 0, null);

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
    target.state = .ready;
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
    _ = c.vkFreeDescriptorSets(self.device, self.descriptor_pool, 1, &target.descriptor_set);
    destroyBuffer(self, target.source_buffer, target.source_memory);
    destroyBuffer(self, target.sample_buffer, target.sample_memory);
    c.vkDestroyImageView(self.device, target.view, null);
    c.vkDestroyImage(self.device, target.image, null);
    c.vkFreeMemory(self.device, target.image_memory, null);
    std.heap.c_allocator.free(target.retired_textures);
    std.heap.c_allocator.free(target.content_leases);
    std.heap.c_allocator.free(target.native_leases);
    std.heap.c_allocator.free(target.imported_leases);
    std.heap.c_allocator.free(target.acquire_semaphores);
    std.heap.c_allocator.destroy(target);
}

const PreparedBatch = struct {
    count: usize,
    staging_bytes: usize,
};

fn prepareTextures(self: *RealRenderer, frame: Frame) !PreparedBatch {
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
        const existing_index = if (native == null) cacheIndex(self.cache, surface.sample.surface) else null;
        const cache_index = existing_index orelse
            (if (native != null) std.math.maxInt(usize) else freeCacheIndex(self.cache, self.prepared[0..count]) orelse
                evictableCacheIndex(self.cache, frame, self.prepared[0..count]) orelse
                return error.TextureCapacityExceeded);
        const existing = if (existing_index) |index| self.cache[index] else null;
        const compatible = if (existing) |entry|
            std.meta.eql(entry.texture.size, surface.source.size) and
                entry.format == surface.source.format
        else
            false;
        const created = native == null and (existing == null or !compatible or cache_index != existing_index.?);
        const texture = if (native) |allocation|
            allocation.texture
        else if (created)
            try createTexture(self, surface.source.size)
        else
            existing.?.texture;
        const prepared_index = count;
        const direct_upload = if (surface.source.upload) |upload|
            if (upload.owner == @as(*anyopaque, @ptrCast(self))) upload else null
        else
            null;
        const upload_damage = if (native) |allocation|
            nativeTextureUpload(allocation, surface)
        else
            textureUpload(created, existing, surface);
        const imported_token = if (native != null and upload_damage.count != 0)
            (pendingAcquire(self, surface.source.native.?.token, surface.sample) orelse
                return error.MissingAcquireFence).imported_token
        else
            null;
        self.prepared[prepared_index] = .{
            .cache_index = cache_index,
            .source_index = source_index,
            .texture = texture,
            .created = created,
            .retire_previous = native == null and created and self.cache[cache_index].occupied,
            .surface = surface.sample.surface,
            .commit_sequence = surface.sample.commit_sequence,
            .format = surface.source.format,
            .content_token = if (direct_upload) |upload| upload.token else null,
            .native_token = if (surface.source.native) |backing| backing.token else null,
            .imported_token = imported_token,
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
                if (end > self.staging_buffer_size) return error.CapacityExceeded;
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

fn realDraw(_: *anyopaque, renderer: Renderer, target_value: Target, frame: Frame) !std.posix.fd_t {
    const self: *RealRenderer = @ptrCast(@alignCast(renderer));
    const target: *RealTarget = @ptrCast(@alignCast(target_value));
    if (frame.samples.len > self.max_samples or frame.sources.len != frame.samples.len or
        frame.source_byte_count > self.max_source_bytes)
        return error.CapacityExceeded;
    if (frame.output.width != target.width or frame.output.height != target.height)
        return error.TargetMismatch;
    var validated_bytes: usize = 0;
    for (frame.sources, frame.samples) |surface, sample| {
        const source = surface.source;
        const packed_stride = std.math.mul(u32, source.size.width, 4) catch
            return error.CapacityExceeded;
        const length = if (source.native != null) 0 else std.math.mul(usize, packed_stride, source.size.height) catch
            return error.CapacityExceeded;
        const source_length = std.math.mul(usize, source.stride, source.size.height) catch
            return error.CapacityExceeded;
        const end = std.math.add(usize, validated_bytes, length) catch
            return error.CapacityExceeded;
        const source_offset = std.math.cast(u32, validated_bytes) orelse
            return error.CapacityExceeded;
        if (source.stride < packed_stride or (source.native == null and source_length > source.bytes.len) or
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
    drainRetiredTextures(self, target);
    if (self.sampled_enabled and frame.sources.len != 0) {
        const completion = realDrawSampled(self, target, frame) catch |err| switch (err) {
            error.TextureCapacityExceeded,
            error.CreateTextureFailed,
            error.AllocateTextureMemoryFailed,
            error.BindTextureMemoryFailed,
            error.CreateTextureViewFailed,
            error.NoCompatibleMemoryType,
            error.CapacityExceeded,
            => null,
            else => return err,
        };
        if (completion) |fd| return fd;
    }
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
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &target.descriptor_set, 0, null);
    for (frame.render_damage) |damage| {
        const push: Push = .{
            .clear_color = .{ frame.clear.a, frame.clear.r, frame.clear.g, frame.clear.b },
            .output = .{ frame.output.width, frame.output.height, @intFromEnum(frame.output_format), @intCast(frame.samples.len) },
            .damage = .{ @intCast(damage.x), @intCast(damage.y), damage.width, damage.height },
        };
        c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
        c.vkCmdDispatch(target.command_buffer, (damage.width + 7) / 8, (damage.height + 7) / 8, 1);
    }
    var release_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = 0,
        .oldLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = c.VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = self.queue_family,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .image = target.image,
        .subresourceRange = colorRange(),
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, null, 0, null, 1, &release_barrier);
    try vk(c.vkEndCommandBuffer(target.command_buffer), error.EndCommandBufferFailed);
    var submit: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
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
    target.state = .in_flight;
    target.initialized_layout = true;
    var fd_info: c.VkSemaphoreGetFdInfoKHR = .{ .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR, .pNext = null, .semaphore = target.semaphore, .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT };
    var completion_fd: c_int = -1;
    if (self.get_semaphore_fd.?(self.device, &fd_info, &completion_fd) != c.VK_SUCCESS or completion_fd < 0) {
        target.state = .export_failed;
        return error.CompletionExportFailedAfterSubmit;
    }
    return completion_fd;
}

fn realDrawSampled(self: *RealRenderer, target: *RealTarget, frame: Frame) !std.posix.fd_t {
    const batch = try prepareTextures(self, frame);
    var prepared_owned = true;
    defer if (prepared_owned) cleanupPreparedTextures(self, batch.count);
    var content_tokens: [sampled_image_capacity]u64 = undefined;
    var content_token_count: usize = 0;
    var content_tokens_owned = true;
    defer if (content_tokens_owned) for (content_tokens[0..content_token_count]) |token|
        releaseContent(self, token);
    var native_tokens: [sampled_image_capacity]u64 = undefined;
    var native_token_count: usize = 0;
    var native_tokens_owned = true;
    defer if (native_tokens_owned) for (native_tokens[0..native_token_count]) |token|
        releaseNative(self, token);
    var imported_tokens: [sampled_image_capacity]u64 = undefined;
    var imported_token_count: usize = 0;
    var imported_tokens_owned = true;
    defer if (imported_tokens_owned) for (imported_tokens[0..imported_token_count]) |token|
        releaseImported(self, token);
    var wait_semaphores: [sampled_image_capacity]c.VkSemaphore = undefined;
    var wait_stages: [sampled_image_capacity]c.VkPipelineStageFlags = undefined;
    var wait_count: usize = 0;

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
        const native_token = prepared.native_token orelse continue;
        var native_present = false;
        for (native_tokens[0..native_token_count]) |existing|
            native_present = native_present or existing == native_token;
        if (!native_present) {
            try retainNative(self, native_token);
            native_tokens[native_token_count] = native_token;
            native_token_count += 1;
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
        const pending = takePendingAcquire(self, native_token, .{
            .surface = prepared.surface,
            .commit_sequence = prepared.commit_sequence,
        }) orelse return error.MissingAcquireFence;
        const acquire_fd = pending.fd;
        var acquire_owned = true;
        defer if (acquire_owned) {
            _ = linux.close(acquire_fd);
        };
        if (pending.imported_token != imported_token) return error.ExternalIdentityMismatch;
        var import_info: c.VkImportSemaphoreFdInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_FD_INFO_KHR,
            .pNext = null,
            .semaphore = target.acquire_semaphores[wait_count],
            .flags = c.VK_SEMAPHORE_IMPORT_TEMPORARY_BIT,
            .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT,
            .fd = acquire_fd,
        };
        try vk(self.import_semaphore_fd.?(self.device, &import_info), error.ImportAcquireFenceFailed);
        acquire_owned = false;
        wait_semaphores[wait_count] = target.acquire_semaphores[wait_count];
        wait_stages[wait_count] = c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
        wait_count += 1;
    }

    @memcpy(
        @as([*]u8, @ptrCast(target.sample_map))[0 .. frame.samples.len * @sizeOf(Sample)],
        std.mem.sliceAsBytes(frame.samples),
    );
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

    var image_descriptors: [sampled_image_capacity]c.VkDescriptorImageInfo = undefined;
    for (frame.sources, 0..) |surface, source_index| {
        const prepared = self.prepared[
            preparedIndex(
                self.prepared[0..batch.count],
                surface.sample.surface,
            ) orelse unreachable
        ];
        image_descriptors[source_index] = .{
            .sampler = self.sampler.?,
            .imageView = prepared.texture.view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
    }
    for (frame.sources.len..sampled_image_capacity) |index|
        image_descriptors[index] = image_descriptors[0];
    var descriptor_write: c.VkWriteDescriptorSet = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = target.descriptor_set,
        .dstBinding = 3,
        .dstArrayElement = 0,
        .descriptorCount = sampled_image_capacity,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .pImageInfo = &image_descriptors,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };
    c.vkUpdateDescriptorSets(self.device, 1, &descriptor_write, 0, null);

    try vk(c.vkResetCommandBuffer(target.command_buffer, 0), error.ResetCommandBufferFailed);
    var begin: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try vk(c.vkBeginCommandBuffer(target.command_buffer, &begin), error.BeginCommandBufferFailed);
    for (self.prepared[0..batch.count]) |prepared| {
        if (prepared.upload_count == 0) continue;
        if (prepared.imported_token) |token| {
            const imported = importedFromToken(self, token) orelse
                return error.StaleExternalImage;
            recordNativeCopies(self, target.command_buffer, prepared, imported);
            continue;
        }
        var before: c.VkImageMemoryBarrier = .{
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
        c.vkCmdPipelineBarrier(
            target.command_buffer,
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
            1,
            &before,
        );
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
        var after: c.VkImageMemoryBarrier = .{
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
            &after,
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
    c.vkCmdBindPipeline(
        target.command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        self.sampled_pipeline.?,
    );
    c.vkCmdBindDescriptorSets(
        target.command_buffer,
        c.VK_PIPELINE_BIND_POINT_COMPUTE,
        self.pipeline_layout,
        0,
        1,
        &target.descriptor_set,
        0,
        null,
    );
    for (frame.render_damage) |damage| {
        const push: Push = .{
            .clear_color = .{ frame.clear.a, frame.clear.r, frame.clear.g, frame.clear.b },
            .output = .{
                frame.output.width,
                frame.output.height,
                @intFromEnum(frame.output_format),
                @intCast(frame.samples.len),
            },
            .damage = .{ @intCast(damage.x), @intCast(damage.y), damage.width, damage.height },
        };
        c.vkCmdPushConstants(
            target.command_buffer,
            self.pipeline_layout,
            c.VK_SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(Push),
            &push,
        );
        c.vkCmdDispatch(
            target.command_buffer,
            (damage.width + 7) / 8,
            (damage.height + 7) / 8,
            1,
        );
    }
    var release_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
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
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
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
    if (target.fence_needs_reset) {
        try vk(c.vkResetFences(self.device, 1, &target.fence), error.ResetFenceFailed);
        target.fence_needs_reset = false;
    }
    var submit: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = @intCast(wait_count),
        .pWaitSemaphores = if (wait_count == 0) null else &wait_semaphores,
        .pWaitDstStageMask = if (wait_count == 0) null else &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &target.command_buffer,
        .signalSemaphoreCount = if (imported_token_count == 0) 1 else 2,
        .pSignalSemaphores = &[_]c.VkSemaphore{ target.semaphore, target.source_semaphore },
    };
    if (c.vkQueueSubmit(self.queue, 1, &submit, target.fence) != c.VK_SUCCESS) {
        target.state = .queue_failed;
        return error.QueueSubmitFailed;
    }
    target.state = .in_flight;
    target.initialized_layout = true;
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
        if (prepared.native_token != null) continue;
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

    var source_safe = imported_token_count == 0;
    var source_exported = imported_token_count == 0;
    if (imported_token_count != 0) source_sync: {
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
            if (prepared.imported_token == null) continue;
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
        .usage = c.VK_IMAGE_USAGE_STORAGE_BIT,
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

fn destroyBuffer(self: *RealRenderer, buffer: c.VkBuffer, memory: c.VkDeviceMemory) void {
    c.vkUnmapMemory(self.device, memory);
    c.vkDestroyBuffer(self.device, buffer, null);
    c.vkFreeMemory(self.device, memory, null);
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
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(Sample));
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
