//! Renderer-neutral R12/R13 contract implemented through a narrow Vulkan boundary.
//!
//! The renderer borrows R10 images and imports only caller-owned DMA-BUF FDs;
//! GBM BO and DRM framebuffer ownership never moves. `render` submits without
//! waiting and returns a caller-owned sync_file FD suitable for R11's
//! `IN_FENCE_FD`. R14 chooses this renderer and owns output orchestration.

const std = @import("std");
const linux = std.os.linux;
const gbm = @import("../backend/gbm.zig");
const framebuffer = @import("../backend/drm/framebuffer.zig");
const render_types = @import("types.zig");
const vk = @import("vulkan_platform.zig");

pub const Config = struct {
    max_samples: usize,
    max_color_luts: usize = 1,
    require_color_management: bool = false,
    max_source_bytes: usize,
    max_targets: usize = framebuffer.default_capacity,
    max_damage_rects: usize = 32,
    content_bytes: usize = 1,
    content_allocations: usize = 1,
};

pub const Target = struct {
    context: *anyopaque,
    image_fn: *const fn (*anyopaque, framebuffer.Handle) anyerror!framebuffer.Image,
    export_fd_fn: *const fn (*anyopaque, framebuffer.Handle, u8) anyerror!std.posix.fd_t,

    pub fn fromPool(pool: *framebuffer.Pool) Target {
        return .{ .context = pool, .image_fn = poolImage, .export_fd_fn = poolExportFd };
    }

    fn poolImage(context: *anyopaque, handle: framebuffer.Handle) !framebuffer.Image {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).image(handle);
    }

    fn poolExportFd(context: *anyopaque, handle: framebuffer.Handle, plane: u8) !std.posix.fd_t {
        return (@as(*framebuffer.Pool, @ptrCast(@alignCast(context)))).exportPlaneFd(handle, plane);
    }
};

const TargetRecord = struct {
    imported: ?vk.Target = null,
    generation: u32 = 0,
    terminal: bool = false,
    metadata: gbm.Metadata = undefined,
};

const TransformEntry = struct {
    source: render_types.color.Description,
    output: render_types.color.Description,
    compiled: render_types.color.Transform,
};

/// One output swapchain's imported Vulkan targets. Slot numbers are local to
/// this set, so separate outputs can safely use the same framebuffer slots.
/// The owning renderer must outlive the set and destroy it before its pool.
pub const Targets = struct {
    allocator: std.mem.Allocator,
    owner: vk.Renderer,
    records: []TargetRecord,
};

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    platform: vk.Platform,
    implementation: vk.Renderer,
    target_capacity: usize,
    attached_target_capacity: usize = 0,
    samples: []vk.Sample,
    sources: []render_types.SurfaceSample,
    max_source_bytes: usize,
    packs_sources: bool,
    damage: []render_types.Rect,
    transform_cache: std.ArrayListUnmanaged(TransformEntry) = .empty,

    /// `drm_fd` is borrowed for device identity only. Vulkan selects the
    /// physical device whose primary DRM node has the same major/minor pair.
    pub fn init(
        allocator: std.mem.Allocator,
        platform: vk.Platform,
        drm_fd: std.posix.fd_t,
        config: Config,
    ) !Renderer {
        if (config.max_samples == 0 or config.max_color_luts == 0 or
            config.max_color_luts > std.math.maxInt(i32) or
            config.max_source_bytes == 0 or
            config.max_targets == 0 or config.max_targets > std.math.maxInt(u32) or
            config.max_samples > std.math.maxInt(u32) or
            config.max_source_bytes > std.math.maxInt(u32) or config.max_damage_rects == 0 or
            config.content_bytes == 0 or config.content_allocations == 0)
            return error.InvalidConfig;
        _ = std.math.mul(usize, config.max_samples, @sizeOf(vk.Sample)) catch
            return error.InvalidConfig;
        const descriptor_count = std.math.mul(usize, config.max_targets, 2) catch
            return error.InvalidConfig;
        if (descriptor_count > std.math.maxInt(u32)) return error.InvalidConfig;
        const samples = try allocator.alloc(vk.Sample, config.max_samples);
        errdefer allocator.free(samples);
        const sources = try allocator.alloc(render_types.SurfaceSample, config.max_samples);
        errdefer allocator.free(sources);
        const damage = try allocator.alloc(render_types.Rect, config.max_damage_rects);
        errdefer allocator.free(damage);
        const implementation = try platform.create(drm_fd, .{
            .max_samples = config.max_samples,
            .max_color_luts = config.max_color_luts,
            .require_color_management = config.require_color_management,
            .max_source_bytes = config.max_source_bytes,
            .max_targets = config.max_targets,
            .content_bytes = config.content_bytes,
            .content_allocations = config.content_allocations,
        });
        return .{
            .allocator = allocator,
            .platform = platform,
            .implementation = implementation,
            .target_capacity = config.max_targets,
            .attached_target_capacity = 0,
            .samples = samples,
            .sources = sources,
            .max_source_bytes = config.max_source_bytes,
            .packs_sources = platform.packsSources(implementation),
            .damage = damage,
            .transform_cache = .empty,
        };
    }

    pub fn createTargets(self: *Renderer, capacity: usize) !Targets {
        if (capacity == 0 or capacity > self.target_capacity - self.attached_target_capacity)
            return error.TargetCapacityExceeded;
        const records = try self.allocator.alloc(TargetRecord, capacity);
        @memset(records, .{});
        self.attached_target_capacity += capacity;
        return .{
            .allocator = self.allocator,
            .owner = self.implementation,
            .records = records,
        };
    }

    pub fn contentProvider(self: *Renderer) ?@import("content.zig").Provider {
        return self.platform.contentProvider(self.implementation);
    }

    pub fn validateExternal(
        self: *Renderer,
        source: render_types.ExternalSource,
        size: render_types.Size,
        format: render_types.PixelFormat,
    ) !void {
        try self.platform.validateExternal(self.implementation, source, size, format);
    }

    pub fn sampledDmabufFormats(
        self: *Renderer,
        output: []gbm.FormatModifier,
    ) ![]const gbm.FormatModifier {
        return self.platform.sampledDmabufFormats(self.implementation, output);
    }

    /// Requires every target to be out of KMS ownership. Platform destruction
    /// performs the terminal fence wait before releasing imported BO state.
    pub fn destroyTargets(self: *Renderer, targets: *Targets) void {
        std.debug.assert(targets.owner == self.implementation);
        var index = targets.records.len;
        while (index != 0) {
            index -= 1;
            if (targets.records[index].imported) |target|
                self.platform.destroyTarget(self.implementation, target);
        }
        self.attached_target_capacity -= targets.records.len;
        targets.allocator.free(targets.records);
        targets.* = undefined;
    }

    /// Requires the R11/R10 output path to be drained. The real boundary waits
    /// only during this terminal teardown, never during a render event turn.
    pub fn deinit(self: *Renderer) void {
        std.debug.assert(self.attached_target_capacity == 0);
        self.platform.destroy(self.implementation);
        self.transform_cache.deinit(self.allocator);
        self.allocator.free(self.damage);
        self.allocator.free(self.sources);
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    /// Success returns a new sync_file FD owned by the caller. Ordinary failure
    /// leaves the R10 image discardable. `CompletionExportFailedAfterSubmit`
    /// is different: GPU work owns the image, so R14 must retain it, terminally
    /// drain/deinit this renderer, and only then discard the R10 handle.
    pub fn render(
        self: *Renderer,
        targets: *Targets,
        target: Target,
        handle: framebuffer.Handle,
        list: render_types.List,
        plan: render_types.DamagePlan,
    ) !std.posix.fd_t {
        return self.renderCapture(targets, target, handle, list, plan, list.samples.len, .{});
    }

    pub fn renderCapture(
        self: *Renderer,
        targets: *Targets,
        target: Target,
        handle: framebuffer.Handle,
        list: render_types.List,
        plan: render_types.DamagePlan,
        cursor_start: usize,
        captures: vk.Captures,
    ) !std.posix.fd_t {
        return self.renderCaptureInternal(
            targets,
            target,
            handle,
            list,
            plan,
            cursor_start,
            captures,
            null,
        );
    }

    pub fn renderCaptureTo(
        self: *Renderer,
        targets: *Targets,
        target: Target,
        handle: framebuffer.Handle,
        list: render_types.List,
        plan: render_types.DamagePlan,
        cursor_start: usize,
        captures: vk.Captures,
        destination: vk.CaptureDestination,
    ) !std.posix.fd_t {
        return self.renderCaptureInternal(
            targets,
            target,
            handle,
            list,
            plan,
            cursor_start,
            captures,
            destination,
        );
    }

    fn renderCaptureInternal(
        self: *Renderer,
        targets: *Targets,
        target: Target,
        handle: framebuffer.Handle,
        list: render_types.List,
        plan: render_types.DamagePlan,
        cursor_start: usize,
        captures: vk.Captures,
        capture_destination: ?vk.CaptureDestination,
    ) !std.posix.fd_t {
        try render_types.validateList(list);
        try render_types.validateOutput(plan.output);
        if (cursor_start > list.samples.len) return error.InvalidSourceIndex;
        if (targets.owner != self.implementation) return error.TargetOwnerMismatch;
        if (plan.samples.len > std.math.maxInt(u32)) return error.SampleCapacityExceeded;
        if (plan.samples.len > self.samples.len) {
            const new_samples = try self.allocator.alloc(vk.Sample, plan.samples.len);
            errdefer self.allocator.free(new_samples);
            const new_sources = try self.allocator.alloc(render_types.SurfaceSample, plan.samples.len);
            self.allocator.free(self.samples);
            self.allocator.free(self.sources);
            self.samples = new_samples;
            self.sources = new_sources;
        }
        if (handle.slot >= targets.records.len) return error.TargetCapacityExceeded;
        const image = try target.image_fn(target.context, handle);
        if (image.state != .acquired or image.metadata.width != plan.output.width or
            image.metadata.height != plan.output.height or
            (formatFromDrm(image.metadata.format) orelse return error.TargetMismatch) != list.output_format)
            return error.TargetMismatch;
        if (image.metadata.plane_count != 1) return error.UnsupportedPlaneCount;
        const record = &targets.records[handle.slot];
        if (record.terminal) return error.TargetTerminal;

        var byte_count: usize = 0;
        var sample_count: usize = 0;
        var packed_cursor_start: ?usize = null;
        var cursor_sample_seen = false;
        const output_lut_slot = if (list.output_color_description.lut) |lut|
            try self.platform.cacheLut(self.implementation, lut)
        else
            null;
        for (plan.samples) |planned| {
            if (planned.source_index >= list.samples.len) return error.InvalidSourceIndex;
            if (planned.source_index >= cursor_start) {
                cursor_sample_seen = true;
            } else if (cursor_sample_seen) {
                return error.InvalidCursorPartition;
            }
            if (packed_cursor_start == null and cursor_sample_seen)
                packed_cursor_start = sample_count;
            const source = list.samples[planned.source_index];
            if (!std.meta.eql(planned.sample, source.sample) or
                !std.meta.eql(planned.presentation, source.presentation))
                return error.PlannedIdentityMismatch;
            const destination = clipPlanRect(planned.destination, plan.output) orelse continue;
            const clip = clipPlanRect(planned.clip, plan.output) orelse continue;
            var validated = source;
            validated.crop = planned.crop;
            validated.destination = destination;
            validated.clip = clip;
            validated.transform = planned.transform;
            validated.global_alpha = planned.global_alpha;
            _ = try render_types.validateSample(validated);
            const packed_stride = std.math.mul(u32, source.source.size.width, 4) catch
                return error.SourceCapacityExceeded;
            const length = if (!self.packs_sources or
                source.source.native != null or source.source.upload != null)
                0
            else
                std.math.mul(usize, packed_stride, source.source.size.height) catch
                    return error.SourceCapacityExceeded;
            const start = byte_count;
            byte_count = std.math.add(usize, byte_count, length) catch
                return error.SourceCapacityExceeded;
            if (byte_count > self.max_source_bytes) return error.SourceCapacityExceeded;
            // Native samples retain their dimensions/stride in the packed ABI,
            // but consume no bytes in the CPU source buffer.
            validated.source.stride = packed_stride;
            self.samples[sample_count] = try packSample(
                validated,
                try self.colorTransform(validated.color_description, list.output_color_description),
                if (validated.color_description.lut) |lut|
                    try self.platform.cacheLut(self.implementation, lut)
                else
                    null,
                @intCast(start),
                planned.destination,
            );
            self.sources[sample_count] = source;
            sample_count += 1;
        }
        const capture_cursor_start = packed_cursor_start orelse sample_count;

        var damage_count: usize = 0;
        if (plan.render_full) {
            self.damage[0] = .{ .x = 0, .y = 0, .width = plan.output.width, .height = plan.output.height };
            damage_count = 1;
        } else for (plan.render_damage) |value| {
            const clipped = clipRect(value, plan.output) orelse continue;
            if (damage_count == self.damage.len) return error.DamageCapacityExceeded;
            self.damage[damage_count] = clipped;
            damage_count += 1;
        }

        if (record.imported == null) {
            const fd = try target.export_fd_fn(target.context, handle, 0);
            record.imported = self.platform.importTarget(
                self.implementation,
                image.metadata,
                fd,
            ) catch |err| return err;
            record.metadata = image.metadata;
        } else if (!sameStorage(record.metadata, image.metadata)) {
            return error.TargetStorageChanged;
        }
        record.generation = handle.generation;
        const completion_fd = self.platform.draw(self.implementation, record.imported.?, .{
            .output = plan.output,
            .output_format = list.output_format,
            .output_color_description = list.output_color_description,
            .output_lut_slot = output_lut_slot,
            .clear = list.clear,
            .samples = self.samples[0..sample_count],
            .sources = self.sources[0..sample_count],
            .source_byte_count = byte_count,
            .render_damage = self.damage[0..damage_count],
            .cursor_start = capture_cursor_start,
            .captures = captures,
            .capture_destination = capture_destination,
        }) catch |err| {
            if (err == error.CompletionExportFailedAfterSubmit) record.terminal = true;
            return err;
        };
        if (completion_fd < 0) return error.InvalidCompletionFd;
        return completion_fd;
    }

    pub fn importCaptureTarget(self: *Renderer, import: gbm.Import) !vk.CaptureTarget {
        if (import.plane_count != 1 or import.fds[0] < 0 or
            import.modifier != gbm.modifier_linear or
            (import.format != gbm.format_argb8888 and import.format != gbm.format_xrgb8888))
            return error.UnsupportedCaptureTarget;
        const duplicate = linux.fcntl(import.fds[0], linux.F.DUPFD_CLOEXEC, 0);
        const fd: std.posix.fd_t = switch (linux.errno(duplicate)) {
            .SUCCESS => @intCast(duplicate),
            .MFILE => return error.ProcessFdQuotaExceeded,
            .NFILE => return error.SystemFdQuotaExceeded,
            .BADF => return error.InvalidExternalFd,
            else => |err| return std.posix.unexpectedErrno(err),
        };
        return self.platform.importCaptureTarget(self.implementation, .{
            .width = import.width,
            .height = import.height,
            .format = import.format,
            .modifier = import.modifier,
            .plane_count = import.plane_count,
            .strides = import.strides,
            .offsets = import.offsets,
        }, fd);
    }

    pub fn supportsCaptureTarget(self: *Renderer, size: render_types.Size) bool {
        const stride = std.math.mul(u32, size.width, 4) catch return false;
        return self.platform.supportsCaptureTarget(self.implementation, .{
            .width = size.width,
            .height = size.height,
            .format = gbm.format_xrgb8888,
            .modifier = gbm.modifier_linear,
            .plane_count = 1,
            .strides = .{ stride, 0, 0, 0 },
        });
    }

    pub fn destroyCaptureTarget(self: *Renderer, target: vk.CaptureTarget) void {
        self.platform.destroyCaptureTarget(self.implementation, target);
    }

    pub fn prepareCaptureTarget(self: *Renderer, target: vk.CaptureTarget, import: gbm.Import) !void {
        if (import.plane_count != 1 or import.fds[0] < 0)
            return error.UnsupportedCaptureTarget;
        return self.platform.prepareCaptureTarget(self.implementation, target, import.fds[0]);
    }

    /// Valid only after completion of the exact rendered target generation.
    pub fn readback(
        self: *Renderer,
        targets: *Targets,
        handle: framebuffer.Handle,
        phase: vk.CapturePhase,
    ) !vk.Readback {
        if (targets.owner != self.implementation) return error.TargetOwnerMismatch;
        if (handle.slot >= targets.records.len) return error.TargetCapacityExceeded;
        const record = &targets.records[handle.slot];
        if (record.imported == null or record.generation != handle.generation)
            return error.StaleTarget;
        return self.platform.readback(self.implementation, record.imported.?, phase);
    }

    fn colorTransform(
        self: *Renderer,
        source: render_types.color.Description,
        output: render_types.color.Description,
    ) !render_types.color.Transform {
        for (self.transform_cache.items) |entry| {
            if (std.meta.eql(entry.source, source) and std.meta.eql(entry.output, output))
                return entry.compiled;
        }
        const compiled = render_types.color.compile(source, output) catch
            return error.InvalidColorDescription;
        try self.transform_cache.append(self.allocator, .{
            .source = source,
            .output = output,
            .compiled = compiled,
        });
        return compiled;
    }

    pub fn renderPool(
        self: *Renderer,
        targets: *Targets,
        pool: *framebuffer.Pool,
        handle: framebuffer.Handle,
        list: render_types.List,
        plan: render_types.DamagePlan,
    ) !std.posix.fd_t {
        return self.render(targets, Target.fromPool(pool), handle, list, plan);
    }
};

/// GPU startup uses R10's normal explicit-modifier negotiation. The Vulkan
/// import remains a startup-time capability check; unlike the CPU renderer it
/// does not force linear storage.
pub fn initTargetPool(
    allocator: std.mem.Allocator,
    gbm_platform: gbm.Platform,
    drm_platform: framebuffer.Platform,
    fd: std.posix.fd_t,
    snapshot: @import("../backend/drm/manager.zig").Snapshot,
    capacity: usize,
) !framebuffer.Pool {
    return framebuffer.Pool.init(
        allocator,
        gbm_platform,
        drm_platform,
        fd,
        snapshot,
        .{ .capacity = capacity },
    );
}

fn packSample(
    sample: render_types.SurfaceSample,
    color_transform: render_types.color.Transform,
    lut_slot: ?u32,
    source_offset: u32,
    original_destination: render_types.PlanRect,
) !vk.Sample {
    const mapping = try affine(sample, original_destination);
    return .{
        .source = .{ source_offset, sample.source.size.width, sample.source.size.height, sample.source.stride },
        .crop = .{ sample.crop.x, sample.crop.y, sample.crop.width, sample.crop.height },
        .destination = .{ sample.destination.x, sample.destination.y, @intCast(sample.destination.width), @intCast(sample.destination.height) },
        .clip = .{ sample.clip.x, sample.clip.y, @intCast(sample.clip.width), @intCast(sample.clip.height) },
        .attributes = .{
            @intFromEnum(sample.source.format),
            @intFromEnum(sample.transform),
            sample.global_alpha,
            @intFromEnum(color_transform.source_transfer),
        },
        .affine = .{ mapping.xx, mapping.xy, mapping.x0, mapping.yx },
        .affine_tail = .{
            mapping.yy,
            mapping.y0,
            @intFromEnum(sample.color_representation.alpha_mode),
            if (lut_slot) |slot| @intCast(slot + 1) else 0,
        },
        .color_matrix_0 = .{
            color_transform.matrix[0][0],
            color_transform.matrix[0][1],
            color_transform.matrix[0][2],
            color_transform.luminance_scale,
        },
        .color_matrix_1 = .{
            color_transform.matrix[1][0],
            color_transform.matrix[1][1],
            color_transform.matrix[1][2],
            0,
        },
        .color_matrix_2 = .{
            color_transform.matrix[2][0],
            color_transform.matrix[2][1],
            color_transform.matrix[2][2],
            0,
        },
    };
}

const Affine = struct { xx: i32, xy: i32, x0: i32, yx: i32, yy: i32, y0: i32 };

fn affine(sample: render_types.SurfaceSample, original: render_types.PlanRect) !Affine {
    if (original.width == 0 or original.height == 0) return error.InvalidPlannedGeometry;
    const swap = switch (sample.transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
    const sx = @divTrunc(@as(i64, sample.crop.width), if (swap) original.height else original.width);
    const sy = @divTrunc(@as(i64, sample.crop.height), if (swap) original.width else original.height);
    const dx = @as(i64, sample.destination.x) - original.x;
    const dy = @as(i64, sample.destination.y) - original.y;
    const x = @as(i64, sample.crop.x);
    const y = @as(i64, sample.crop.y);
    const right = x + sample.crop.width;
    const bottom = y + sample.crop.height;
    const half_x = @divTrunc(sx, 2);
    const half_y = @divTrunc(sy, 2);
    const values: [6]i64 = switch (sample.transform) {
        .normal => .{ sx, 0, x + sx * dx + half_x, 0, sy, y + sy * dy + half_y },
        .@"90" => .{ 0, -sx, right - sx * dy - half_x, sy, 0, y + sy * dx + half_y },
        .@"180" => .{ -sx, 0, right - sx * dx - half_x, 0, -sy, bottom - sy * dy - half_y },
        .@"270" => .{ 0, sx, x + sx * dy + half_x, -sy, 0, bottom - sy * dx - half_y },
        .flipped => .{ -sx, 0, right - sx * dx - half_x, 0, sy, y + sy * dy + half_y },
        .flipped_90 => .{ 0, sx, x + sx * dy + half_x, sy, 0, y + sy * dx + half_y },
        .flipped_180 => .{ sx, 0, x + sx * dx + half_x, 0, -sy, bottom - sy * dy - half_y },
        .flipped_270 => .{ 0, -sx, right - sx * dy - half_x, -sy, 0, bottom - sy * dx - half_y },
    };
    return .{
        .xx = std.math.cast(i32, values[0]) orelse return error.InvalidPlannedGeometry,
        .xy = std.math.cast(i32, values[1]) orelse return error.InvalidPlannedGeometry,
        .x0 = std.math.cast(i32, values[2]) orelse return error.InvalidPlannedGeometry,
        .yx = std.math.cast(i32, values[3]) orelse return error.InvalidPlannedGeometry,
        .yy = std.math.cast(i32, values[4]) orelse return error.InvalidPlannedGeometry,
        .y0 = std.math.cast(i32, values[5]) orelse return error.InvalidPlannedGeometry,
    };
}

fn formatFromDrm(format: u32) ?render_types.PixelFormat {
    if (format == gbm.format_argb8888) return .argb8888_premultiplied;
    if (format == gbm.format_xrgb8888) return .xrgb8888;
    return null;
}

fn sameStorage(a: gbm.Metadata, b: gbm.Metadata) bool {
    return a.width == b.width and a.height == b.height and a.format == b.format and
        a.modifier == b.modifier and a.plane_count == b.plane_count and
        std.meta.eql(a.strides, b.strides) and std.meta.eql(a.offsets, b.offsets);
}

fn clipPlanRect(value: render_types.PlanRect, output: render_types.Size) ?render_types.Rect {
    const left = @max(@as(i128, value.x), 0);
    const top = @max(@as(i128, value.y), 0);
    const right = @min(@as(i128, value.x) + value.width, output.width);
    const bottom = @min(@as(i128, value.y) + value.height, output.height);
    if (right <= left or bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(right - left),
        .height = @intCast(bottom - top),
    };
}

fn clipRect(value: render_types.Rect, output: render_types.Size) ?render_types.Rect {
    return clipPlanRect(.{ .x = value.x, .y = value.y, .width = value.width, .height = value.height }, output);
}

test "render-vulkan: packed ABI preserves order geometry transform alpha and retained bytes" {
    const bytes = [_]u8{ 1, 2, 3, 4, 9, 8, 7, 6 };
    const value: render_types.SurfaceSample = .{
        .sample = .{ .surface = 4, .commit_sequence = 8 },
        .presentation = .{ .slot = 2, .generation = 3 },
        .source = .{ .size = .{ .width = 1, .height = 2 }, .stride = 4, .format = .argb8888_premultiplied, .bytes = &bytes },
        .crop = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
        .destination = .{ .x = -5, .y = 6, .width = 7, .height = 8 },
        .clip = .{ .x = 9, .y = -10, .width = 11, .height = 12 },
        .transform = .flipped_270,
        .global_alpha = 13,
    };
    const gpu_sample = try packSample(value, try render_types.color.compile(.srgb, .srgb), null, 16, .{ .x = -5, .y = 6, .width = 7, .height = 8 });
    try std.testing.expectEqual([4]u32{ 16, 1, 2, 4 }, gpu_sample.source);
    try std.testing.expectEqual([4]i32{ 1, 2, 3, 4 }, gpu_sample.crop);
    try std.testing.expectEqual([4]i32{ -5, 6, 7, 8 }, gpu_sample.destination);
    try std.testing.expectEqual([4]u32{ 0, 7, 13, 0 }, gpu_sample.attributes);
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(vk.Sample));
}

test "render-vulkan: sampled DMA-BUF capabilities cross the platform boundary" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 1,
        .max_source_bytes = 4,
        .max_targets = 1,
    });
    defer renderer.deinit();
    var storage: [2]gbm.FormatModifier = undefined;
    try std.testing.expectEqualSlices(gbm.FormatModifier, &.{
        .{ .fourcc = gbm.format_argb8888, .modifier = gbm.modifier_linear },
        .{ .fourcc = gbm.format_xrgb8888, .modifier = 7 },
    }, try renderer.sampledDmabufFormats(&storage));
}

test "render-vulkan: LUT slot is packed without changing Sample ABI" {
    var value: render_types.SurfaceSample = undefined;
    _ = testList(&.{ 0, 0, 0, 255 }, &value);
    const gpu_sample = try packSample(
        value,
        try render_types.color.compile(.srgb, .srgb),
        6,
        0,
        .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    );
    try std.testing.expectEqual(@as(i32, 7), gpu_sample.affine_tail[3]);
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(vk.Sample));
}

test "render-vulkan: LUT hash cache hit does not upload twice" {
    var fake = FakePlatform{};
    const lut: @import("icc.zig").Lut = .{
        .profile_hash = .{7} ** 32,
        .lut_hash = .{8} ** 32,
        .rgba = &.{},
    };
    const platform = fake.platform();
    try std.testing.expectEqual(@as(u32, 0), try platform.cacheLut(@ptrCast(&fake), &lut));
    try std.testing.expectEqual(@as(u32, 0), try platform.cacheLut(@ptrCast(&fake), &lut));
    try std.testing.expectEqual(@as(usize, 1), fake.lut_upload_count);
    var inverse = lut;
    inverse.lut_hash = .{9} ** 32;
    try std.testing.expectEqual(@as(u32, 1), try platform.cacheLut(@ptrCast(&fake), &inverse));
    try std.testing.expectEqual(@as(usize, 2), fake.lut_upload_count);
}

test "render-vulkan: fixed target cache retains source bytes and cleans up exactly once" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 2,
        .max_source_bytes = 16,
        .max_targets = 1,
    });
    var targets = try renderer.createTargets(1);
    var source = [_]u8{ 1, 2, 3, 4 };
    var target = FakeTarget{};
    const render_target = target.target();
    var first_sample: render_types.SurfaceSample = undefined;
    const first_list = testList(&source, &first_sample);
    var first_planned: render_types.PlannedSample = undefined;
    var first_damage: render_types.Rect = undefined;
    const completion = try renderer.render(&targets, render_target, .{ .slot = 0, .generation = 1 }, first_list, testPlan(first_list, &first_planned, &first_damage, true));
    _ = linux.close(completion);
    source = .{ 9, 9, 9, 9 };
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, fake.last_bytes[0..fake.last_byte_count]);
    target.generation = 2;
    var second_sample: render_types.SurfaceSample = undefined;
    const second_list = testList(&source, &second_sample);
    var second_planned: render_types.PlannedSample = undefined;
    var second_damage: render_types.Rect = undefined;
    const second = try renderer.render(&targets, render_target, .{ .slot = 0, .generation = 2 }, second_list, testPlan(second_list, &second_planned, &second_damage, true));
    _ = linux.close(second);
    try std.testing.expectEqual(@as(usize, 1), target.export_count);
    try std.testing.expectEqual(@as(usize, 1), fake.import_count);
    try std.testing.expectEqual(@as(usize, 2), fake.draw_count);
    renderer.destroyTargets(&targets);
    try std.testing.expectEqual(@as(usize, 1), fake.destroy_target_count);
    renderer.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.destroy_count);
}

test "render-vulkan: output target sets isolate equal framebuffer slots" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 1,
        .max_source_bytes = 4,
        .max_targets = 2,
    });
    var first_targets = try renderer.createTargets(1);
    var second_targets = try renderer.createTargets(1);
    try std.testing.expectError(error.TargetCapacityExceeded, renderer.createTargets(1));

    const bytes = [_]u8{ 1, 2, 3, 4 };
    var sample: render_types.SurfaceSample = undefined;
    const list = testList(&bytes, &sample);
    var planned: render_types.PlannedSample = undefined;
    var damage: render_types.Rect = undefined;
    const plan = testPlan(list, &planned, &damage, true);
    var first_target = FakeTarget{};
    var second_target = FakeTarget{};
    _ = linux.close(try renderer.render(
        &first_targets,
        first_target.target(),
        .{ .slot = 0, .generation = 1 },
        list,
        plan,
    ));
    _ = linux.close(try renderer.render(
        &second_targets,
        second_target.target(),
        .{ .slot = 0, .generation = 1 },
        list,
        plan,
    ));
    try std.testing.expectEqual(@as(usize, 2), fake.import_count);

    renderer.destroyTargets(&first_targets);
    var replacement_targets = try renderer.createTargets(1);
    renderer.destroyTargets(&replacement_targets);
    renderer.destroyTargets(&second_targets);
    try std.testing.expectEqual(@as(usize, 2), fake.destroy_target_count);
    renderer.deinit();
}

test "render-vulkan: failed import closes DMA-BUF and leaves image acquired" {
    var fake = FakePlatform{ .fail_import = true };
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 1,
        .max_source_bytes = 4,
        .max_targets = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    var target = FakeTarget{};
    const bytes = [_]u8{ 0, 0, 0, 255 };
    var value: render_types.SurfaceSample = undefined;
    const list = testList(&bytes, &value);
    var planned: render_types.PlannedSample = undefined;
    var damage: render_types.Rect = undefined;
    try std.testing.expectError(
        error.FakeImport,
        renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, testPlan(list, &planned, &damage, true)),
    );
    try std.testing.expect(target.acquired);
    try std.testing.expect(fake.draw_count == 0);
    try std.testing.expectEqual(.BADF, linux.errno(linux.fcntl(target.last_exported_fd, linux.F.GETFD, 0)));
}

test "render-vulkan: damage plan selects exact source and clips planned i64 geometry" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 2,
        .max_source_bytes = 8,
        .max_targets = 1,
        .max_damage_rects = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    const first_bytes = [_]u8{ 1, 2, 3, 4 };
    const second_bytes = [_]u8{ 5, 6, 7, 8 };
    var samples = [_]render_types.SurfaceSample{ undefined, undefined };
    _ = testList(&first_bytes, &samples[0]);
    _ = testList(&second_bytes, &samples[1]);
    samples[1].sample.surface = 2;
    samples[1].presentation.slot = 1;
    const list: render_types.List = .{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &samples,
    };
    var planned = plannedFromSample(samples[1], 1);
    planned.destination = .{ .x = -10, .y = -20, .width = 11, .height = 21 };
    planned.clip = .{ .x = -1, .y = 0, .width = 2, .height = 1 };
    const damage = [_]render_types.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    const plan = damagePlan(&planned, &damage, false);
    var target = FakeTarget{};
    const completion = try renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, plan);
    _ = linux.close(completion);
    try std.testing.expectEqualSlices(u8, &second_bytes, fake.last_bytes[0..fake.last_byte_count]);
    try std.testing.expectEqual(@as(i32, 0), fake.last_sample.destination[0]);
    try std.testing.expectEqual(@as(i32, 0), fake.last_sample.destination[1]);
    try std.testing.expectEqual(@as(i32, 1), fake.last_sample.destination[2]);
    try std.testing.expectEqual(@as(i32, 62_548), fake.last_sample.affine[2]);
    try std.testing.expectEqual(damage[0], fake.last_damage);

    const duplicate_damage = [_]render_types.Rect{ damage[0], damage[0] };
    try std.testing.expectError(
        error.DamageCapacityExceeded,
        renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, damagePlan(&planned, &duplicate_damage, false)),
    );
    const full_completion = try renderer.render(
        &targets,
        target.target(),
        .{ .slot = 0, .generation = 1 },
        list,
        damagePlan(&planned, &.{}, true),
    );
    _ = linux.close(full_completion);
    try std.testing.expectEqual(render_types.Rect{ .x = 0, .y = 0, .width = 1, .height = 1 }, fake.last_damage);

    planned.sample.surface = 99;
    try std.testing.expectError(
        error.PlannedIdentityMismatch,
        renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, damagePlan(&planned, &damage, false)),
    );
}

test "render-vulkan: capture preserves the packed cursor partition and target generation" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 2,
        .max_source_bytes = 8,
        .max_targets = 1,
        .max_damage_rects = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    const base_bytes = [_]u8{ 1, 2, 3, 4 };
    const cursor_bytes = [_]u8{ 5, 6, 7, 8 };
    var samples = [_]render_types.SurfaceSample{ undefined, undefined };
    _ = testList(&base_bytes, &samples[0]);
    _ = testList(&cursor_bytes, &samples[1]);
    samples[1].sample.surface = 2;
    samples[1].presentation.slot = 1;
    const list: render_types.List = .{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &samples,
    };
    const planned = [_]render_types.PlannedSample{
        plannedFromSample(samples[0], 0),
        plannedFromSample(samples[1], 1),
    };
    const damage = [_]render_types.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    const plan: render_types.DamagePlan = .{
        .output = list.output,
        .samples = &planned,
        .client_damage = &damage,
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = &damage,
        .client_full = true,
        .scene_full = false,
        .repair_full = false,
        // Capture is valid after ordinary target repair; it does not require
        // the current frame's render region to cover the whole output.
        .render_full = false,
    };
    var target = FakeTarget{};
    const handle: framebuffer.Handle = .{ .slot = 0, .generation = 1 };
    _ = linux.close(try renderer.renderCapture(
        &targets,
        target.target(),
        handle,
        list,
        plan,
        1,
        .{ .before_cursor = true, .after_cursor = true },
    ));
    try std.testing.expectEqual(@as(usize, 1), fake.last_cursor_start);
    try std.testing.expect(fake.last_captures.before_cursor);
    try std.testing.expect(fake.last_captures.after_cursor);
    const readback = try renderer.readback(&targets, handle, .before_cursor);
    try std.testing.expectEqual(@as(u32, 4), readback.stride);
    try std.testing.expectEqualSlices(u8, &.{ 9, 10, 11, 12 }, readback.bytes);
    try std.testing.expectError(
        error.StaleTarget,
        renderer.readback(&targets, .{ .slot = 0, .generation = 2 }, .after_cursor),
    );

    const destination: vk.CaptureDestination = .{
        .target = @ptrFromInt(32),
        .source = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    _ = linux.close(try renderer.renderCaptureTo(
        &targets,
        target.target(),
        handle,
        list,
        plan,
        1,
        .{ .after_cursor = true },
        destination,
    ));
    try std.testing.expect(fake.last_capture_destination != null);
    try std.testing.expectEqual(destination.target, fake.last_capture_destination.?.target);
    try std.testing.expectEqual(destination.source, fake.last_capture_destination.?.source);
}

test "render-vulkan: odd source strides repack to aligned contiguous shader words" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 2,
        .max_source_bytes = 8,
        .max_targets = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    const first_bytes = [_]u8{ 1, 2, 3, 4, 0xaa };
    const second_bytes = [_]u8{ 5, 6, 7, 8, 0xbb, 0xcc, 0xdd };
    var samples = [_]render_types.SurfaceSample{ undefined, undefined };
    _ = testList(&first_bytes, &samples[0]);
    samples[0].source.stride = 5;
    _ = testList(&second_bytes, &samples[1]);
    samples[1].source.stride = 7;
    samples[1].sample.surface = 2;
    const list: render_types.List = .{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &samples,
    };
    const planned = [_]render_types.PlannedSample{
        plannedFromSample(samples[0], 0),
        plannedFromSample(samples[1], 1),
    };
    const damage = [_]render_types.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    var plan = damagePlan(&planned[0], &damage, true);
    plan.samples = &planned;
    var target = FakeTarget{};
    const completion = try renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, plan);
    _ = linux.close(completion);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, fake.last_bytes[0..fake.last_byte_count]);
    try std.testing.expectEqual([4]u32{ 0, 1, 1, 4 }, fake.last_samples[0].source);
    try std.testing.expectEqual([4]u32{ 4, 1, 1, 4 }, fake.last_samples[1].source);
}

test "render-vulkan: direct upload sources do not consume fallback frame bytes" {
    var fake = FakePlatform{};
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 2,
        .max_source_bytes = 4,
        .max_targets = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    const bytes = [_]u8{ 1, 2, 3, 4 };
    var samples = [_]render_types.SurfaceSample{ undefined, undefined };
    _ = testList(&bytes, &samples[0]);
    samples[0].source.upload = .{ .owner = &fake, .token = 1, .offset = 0 };
    samples[1] = samples[0];
    samples[1].sample.surface = 2;
    samples[1].source.upload.?.token = 2;
    const list: render_types.List = .{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &samples,
    };
    const planned = [_]render_types.PlannedSample{
        plannedFromSample(samples[0], 0),
        plannedFromSample(samples[1], 1),
    };
    const damage = [_]render_types.Rect{.{ .x = 0, .y = 0, .width = 1, .height = 1 }};
    var plan = damagePlan(&planned[0], &damage, true);
    plan.samples = &planned;
    var target = FakeTarget{};
    const completion = try renderer.render(
        &targets,
        target.target(),
        .{ .slot = 0, .generation = 1 },
        list,
        plan,
    );
    _ = linux.close(completion);
    try std.testing.expectEqual(@as(usize, 0), fake.last_byte_count);
    try std.testing.expectEqual([4]u32{ 0, 1, 1, 4 }, fake.last_samples[0].source);
    try std.testing.expectEqual([4]u32{ 0, 1, 1, 4 }, fake.last_samples[1].source);
}

test "render-vulkan: post-submit completion export failure is terminal and classified" {
    var fake = FakePlatform{ .fail_after_submit = true };
    var renderer = try Renderer.init(std.testing.allocator, fake.platform(), 41, .{
        .max_samples = 1,
        .max_source_bytes = 4,
        .max_targets = 1,
    });
    defer renderer.deinit();
    var targets = try renderer.createTargets(1);
    defer renderer.destroyTargets(&targets);
    const bytes = [_]u8{ 1, 2, 3, 4 };
    var sample: render_types.SurfaceSample = undefined;
    const list = testList(&bytes, &sample);
    var planned: render_types.PlannedSample = undefined;
    var damage: render_types.Rect = undefined;
    const plan = testPlan(list, &planned, &damage, true);
    var target = FakeTarget{};
    try std.testing.expectError(
        error.CompletionExportFailedAfterSubmit,
        renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, plan),
    );
    try std.testing.expectError(
        error.TargetTerminal,
        renderer.render(&targets, target.target(), .{ .slot = 0, .generation = 1 }, list, plan),
    );
    try std.testing.expectEqual(@as(usize, 1), fake.draw_count);
}

test "render-vulkan: overflowing fixed capacities reject before platform startup" {
    var fake = FakePlatform{};
    try std.testing.expectError(
        error.InvalidConfig,
        Renderer.init(std.testing.allocator, fake.platform(), 41, .{
            .max_samples = std.math.maxInt(usize),
            .max_source_bytes = 4,
            .max_targets = 1,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
    try std.testing.expectError(
        error.InvalidConfig,
        Renderer.init(std.testing.allocator, fake.platform(), 41, .{
            .max_samples = 1,
            .max_color_luts = 0,
            .max_source_bytes = 4,
            .max_targets = 1,
        }),
    );
    try std.testing.expectEqual(@as(usize, 0), fake.create_count);
}

test "render-vulkan: shader transform coordinates match Pixman reference cases" {
    const expected = [_][6]u8{
        .{ 0, 1, 2, 3, 4, 5 },
        .{ 1, 3, 5, 0, 2, 4 },
        .{ 5, 4, 3, 2, 1, 0 },
        .{ 4, 2, 0, 5, 3, 1 },
        .{ 1, 0, 3, 2, 5, 4 },
        .{ 0, 2, 4, 1, 3, 5 },
        .{ 4, 5, 2, 3, 0, 1 },
        .{ 5, 3, 1, 4, 2, 0 },
    };
    for (0..8) |transform| {
        const swap = transform == 1 or transform == 3 or transform == 5 or transform == 7;
        const width: u32 = if (swap) 3 else 2;
        const height: u32 = if (swap) 2 else 3;
        for (0..6) |index| {
            const coordinate = shaderCoordinate(@intCast(transform), @intCast(index % width), @intCast(index / width), width, height);
            try std.testing.expectEqual(expected[transform][index], @as(u8, @intCast(coordinate[1] * 2 + coordinate[0])));
        }
    }
    // Pixman's exact global-alpha OVER result for half red over opaque blue.
    try std.testing.expectEqual(@as(u8, 127), multiplyUnorm(255, 127));
    try std.testing.expectEqual(@as(u8, 128), multiplyUnorm(255, 128));
}

fn shaderCoordinate(transform: u3, local_x: i32, local_y: i32, width: u32, height: u32) [2]i32 {
    const swap = transform == 1 or transform == 3 or transform == 5 or transform == 7;
    const crop_width = 2 * render_types.fixed_one;
    const crop_height = 3 * render_types.fixed_one;
    const sx = @divTrunc(crop_width, @as(i32, @intCast(if (swap) height else width)));
    const sy = @divTrunc(crop_height, @as(i32, @intCast(if (swap) width else height)));
    const right = crop_width;
    const bottom = crop_height;
    const fixed: [2]i32 = switch (transform) {
        0 => .{ sx * local_x + @divTrunc(sx, 2), sy * local_y + @divTrunc(sy, 2) },
        1 => .{ right - sx * local_y - @divTrunc(sx, 2), sy * local_x + @divTrunc(sy, 2) },
        2 => .{ right - sx * local_x - @divTrunc(sx, 2), bottom - sy * local_y - @divTrunc(sy, 2) },
        3 => .{ sx * local_y + @divTrunc(sx, 2), bottom - sy * local_x - @divTrunc(sy, 2) },
        4 => .{ right - sx * local_x - @divTrunc(sx, 2), sy * local_y + @divTrunc(sy, 2) },
        5 => .{ sx * local_y + @divTrunc(sx, 2), sy * local_x + @divTrunc(sy, 2) },
        6 => .{ sx * local_x + @divTrunc(sx, 2), bottom - sy * local_y - @divTrunc(sy, 2) },
        7 => .{ right - sx * local_y - @divTrunc(sx, 2), bottom - sy * local_x - @divTrunc(sy, 2) },
    };
    return .{ fixed[0] >> 16, fixed[1] >> 16 };
}

fn multiplyUnorm(value: u8, alpha: u8) u8 {
    return @intCast((@as(u16, value) * alpha + 127) / 255);
}

fn testList(bytes: []const u8, sample: *render_types.SurfaceSample) render_types.List {
    sample.* = .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{ .size = .{ .width = 1, .height = 1 }, .stride = 4, .format = .xrgb8888, .bytes = bytes },
        .crop = render_types.SourceRect.pixels(0, 0, 1, 1),
        .destination = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .clip = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    return .{
        .output = .{ .width = 1, .height = 1 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = @as([*]render_types.SurfaceSample, @ptrCast(sample))[0..1],
    };
}

fn plannedFromSample(sample: render_types.SurfaceSample, source_index: u32) render_types.PlannedSample {
    return .{
        .source_index = source_index,
        .sample = sample.sample,
        .presentation = sample.presentation,
        .crop = sample.crop,
        .destination = .{ .x = sample.destination.x, .y = sample.destination.y, .width = sample.destination.width, .height = sample.destination.height },
        .clip = .{ .x = sample.clip.x, .y = sample.clip.y, .width = sample.clip.width, .height = sample.clip.height },
        .transform = sample.transform,
        .global_alpha = sample.global_alpha,
    };
}

fn damagePlan(planned: *const render_types.PlannedSample, damage: []const render_types.Rect, full: bool) render_types.DamagePlan {
    return .{
        .output = .{ .width = 1, .height = 1 },
        .samples = @as([*]const render_types.PlannedSample, @ptrCast(planned))[0..1],
        .client_damage = &.{},
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = damage,
        .client_full = false,
        .scene_full = false,
        .repair_full = false,
        .render_full = full,
    };
}

fn testPlan(list: render_types.List, planned: *render_types.PlannedSample, damage: *render_types.Rect, full: bool) render_types.DamagePlan {
    planned.* = plannedFromSample(list.samples[0], 0);
    damage.* = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
    return damagePlan(planned, @as([*]render_types.Rect, @ptrCast(damage))[0..1], full);
}

const FakeTarget = struct {
    generation: u32 = 1,
    acquired: bool = true,
    export_count: usize = 0,
    last_exported_fd: std.posix.fd_t = -1,

    fn target(self: *FakeTarget) Target {
        return .{ .context = self, .image_fn = image, .export_fd_fn = exportFd };
    }
    fn image(context: *anyopaque, handle: framebuffer.Handle) !framebuffer.Image {
        const self: *FakeTarget = @ptrCast(@alignCast(context));
        if (!self.acquired or handle.slot != 0 or handle.generation != self.generation) return error.StaleImage;
        return .{ .metadata = fakeMetadata(), .framebuffer_id = 7, .state = .acquired };
    }
    fn exportFd(context: *anyopaque, _: framebuffer.Handle, plane: u8) !std.posix.fd_t {
        const self: *FakeTarget = @ptrCast(@alignCast(context));
        if (plane != 0) return error.InvalidPlane;
        const fd = try eventFd();
        self.export_count += 1;
        self.last_exported_fd = fd;
        return fd;
    }
};

const FakePlatform = struct {
    fail_import: bool = false,
    fail_after_submit: bool = false,
    pack_sources: bool = true,
    create_count: usize = 0,
    import_count: usize = 0,
    draw_count: usize = 0,
    destroy_target_count: usize = 0,
    destroy_count: usize = 0,
    last_bytes: [16]u8 = undefined,
    last_byte_count: usize = 0,
    last_sample: vk.Sample = undefined,
    last_samples: [2]vk.Sample = undefined,
    last_sample_count: usize = 0,
    last_damage: render_types.Rect = undefined,
    lut_hashes: [2][32]u8 = undefined,
    lut_count: usize = 0,
    lut_upload_count: usize = 0,
    last_cursor_start: usize = 0,
    last_captures: vk.Captures = .{},
    last_capture_destination: ?vk.CaptureDestination = null,
    readback_bytes: [4]u8 = .{ 9, 10, 11, 12 },

    const vtable: vk.Platform.VTable = .{
        .create = create,
        .destroy = destroy,
        .import_target = importTarget,
        .destroy_target = destroyTarget,
        .supports_capture_target = supportsCaptureTarget,
        .import_capture_target = importCaptureTarget,
        .prepare_capture_target = prepareCaptureTarget,
        .destroy_capture_target = destroyCaptureTarget,
        .draw = draw,
        .readback = readback,
        .content_provider = contentProvider,
        .validate_external = validateExternal,
        .sampled_dmabuf_formats = sampledDmabufFormats,
        .packs_sources = packsSources,
        .cache_lut = cacheLut,
    };
    fn platform(self: *FakePlatform) vk.Platform {
        return .{ .context = self, .vtable = &vtable };
    }
    fn create(context: *anyopaque, fd: std.posix.fd_t, _: vk.Config) !vk.Renderer {
        if (fd != 41) return error.WrongDevice;
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.create_count += 1;
        return context;
    }
    fn contentProvider(_: *anyopaque, _: vk.Renderer) ?@import("content.zig").Provider {
        return null;
    }
    fn validateExternal(
        _: *anyopaque,
        _: vk.Renderer,
        _: render_types.ExternalSource,
        _: render_types.Size,
        _: render_types.PixelFormat,
    ) !void {}
    fn sampledDmabufFormats(
        _: *anyopaque,
        _: vk.Renderer,
        output: []gbm.FormatModifier,
    ) !usize {
        if (output.len < 2) return error.OutputTooSmall;
        output[0] = .{ .fourcc = gbm.format_argb8888, .modifier = gbm.modifier_linear };
        output[1] = .{ .fourcc = gbm.format_xrgb8888, .modifier = 7 };
        return 2;
    }
    fn packsSources(context: *anyopaque, _: vk.Renderer) bool {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        return self.pack_sources;
    }
    fn cacheLut(context: *anyopaque, _: vk.Renderer, lut: *const @import("icc.zig").Lut) !u32 {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        for (self.lut_hashes[0..self.lut_count], 0..) |hash, slot|
            if (std.mem.eql(u8, &hash, &lut.lut_hash)) return @intCast(slot);
        if (self.lut_count == self.lut_hashes.len) return error.ColorLutCapacityExceeded;
        const slot = self.lut_count;
        self.lut_hashes[slot] = lut.lut_hash;
        self.lut_count += 1;
        self.lut_upload_count += 1;
        return @intCast(slot);
    }
    fn destroy(context: *anyopaque, _: vk.Renderer) void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.destroy_count += 1;
    }
    fn importTarget(context: *anyopaque, _: vk.Renderer, _: gbm.Metadata, fd: std.posix.fd_t) !vk.Target {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.import_count += 1;
        _ = linux.close(fd);
        if (self.fail_import) return error.FakeImport;
        return @ptrFromInt(16);
    }
    fn destroyTarget(context: *anyopaque, _: vk.Renderer, _: vk.Target) void {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.destroy_target_count += 1;
    }
    fn importCaptureTarget(context: *anyopaque, _: vk.Renderer, _: gbm.Metadata, fd: std.posix.fd_t) !vk.CaptureTarget {
        _ = linux.close(fd);
        return context;
    }
    fn supportsCaptureTarget(_: *anyopaque, _: vk.Renderer, _: gbm.Metadata) bool {
        return true;
    }
    fn prepareCaptureTarget(_: *anyopaque, _: vk.Renderer, _: vk.CaptureTarget, _: std.posix.fd_t) !void {}
    fn destroyCaptureTarget(_: *anyopaque, _: vk.Renderer, _: vk.CaptureTarget) void {}
    fn draw(context: *anyopaque, _: vk.Renderer, _: vk.Target, frame: vk.Frame) !std.posix.fd_t {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        self.draw_count += 1;
        self.last_byte_count = frame.source_byte_count;
        var offset: usize = 0;
        for (frame.sources) |sample| {
            const source = sample.source;
            const packed_stride = source.size.width * 4;
            if (source.native != null or source.upload != null) continue;
            for (0..source.size.height) |row| {
                const source_start = @as(usize, source.stride) * row;
                const packed_start = offset + @as(usize, packed_stride) * row;
                @memcpy(
                    self.last_bytes[packed_start..][0..packed_stride],
                    source.bytes[source_start..][0..packed_stride],
                );
            }
            offset += @as(usize, packed_stride) * source.size.height;
        }
        if (offset != frame.source_byte_count) return error.FakeSourceSize;
        self.last_sample_count = frame.samples.len;
        @memcpy(self.last_samples[0..frame.samples.len], frame.samples);
        if (frame.samples.len != 0) self.last_sample = frame.samples[0];
        if (frame.render_damage.len != 0) self.last_damage = frame.render_damage[0];
        self.last_cursor_start = frame.cursor_start;
        self.last_captures = frame.captures;
        self.last_capture_destination = frame.capture_destination;
        if (self.fail_after_submit) return error.CompletionExportFailedAfterSubmit;
        return eventFd();
    }
    fn readback(context: *anyopaque, _: vk.Renderer, _: vk.Target, phase: vk.CapturePhase) !vk.Readback {
        const self: *FakePlatform = @ptrCast(@alignCast(context));
        const captured = switch (phase) {
            .before_cursor => self.last_captures.before_cursor,
            .after_cursor => self.last_captures.after_cursor,
        };
        if (!captured) return error.CaptureUnavailable;
        return .{ .bytes = &self.readback_bytes, .stride = 4 };
    }
};

fn fakeMetadata() gbm.Metadata {
    return .{ .width = 1, .height = 1, .format = gbm.format_xrgb8888, .modifier = gbm.modifier_linear, .plane_count = 1, .strides = .{ 4, 0, 0, 0 } };
}

fn eventFd() !std.posix.fd_t {
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    if (linux.errno(raw) != .SUCCESS) return error.EventFdFailed;
    return @intCast(raw);
}
