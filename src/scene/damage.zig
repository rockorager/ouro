//! Allocation-free R13 scene-damage transformation and scanout-image repair.
//!
//! `prepare` only writes preallocated scratch storage. `publish` is called
//! after rendering is accepted and is the sole operation that advances image
//! validity: the rendered image becomes current, while every other image
//! accumulates only this frame's client/scene damage (never repair damage).

const std = @import("std");
const framebuffer = @import("../backend/drm/framebuffer.zig");
const render = @import("../render/types.zig");
const surface_state = @import("../surface.zig");

pub const Damage = struct {
    min_x: i64,
    min_y: i64,
    max_x: i64,
    max_y: i64,
    empty: bool = false,

    pub fn rect(x: i64, y: i64, width: i64, height: i64) Damage {
        return .{ .min_x = x, .min_y = y, .max_x = x +| width, .max_y = y +| height };
    }

    pub fn fromSurface(value: surface_state.Damage) Damage {
        return .{
            .min_x = value.min_x,
            .min_y = value.min_y,
            .max_x = value.max_x,
            .max_y = value.max_y,
            .empty = value.empty,
        };
    }
};

/// Geometry associated with an exact applied R12 sample. `surface_size` is the
/// logical post-buffer-transform/post-viewport extent in surface coordinates.
pub const SurfaceState = struct {
    sample: render.SampleIdentity,
    presentation: render.PresentationIdentity,
    crop: render.SourceRect,
    destination: render.Rect,
    clip: render.Rect,
    transform: render.Transform,
    surface_size: render.Size,

    pub fn fromSample(value: render.SurfaceSample, surface_size: render.Size) SurfaceState {
        return .{
            .sample = value.sample,
            .presentation = value.presentation,
            .crop = value.crop,
            .destination = value.destination,
            .clip = value.clip,
            .transform = value.transform,
            .surface_size = surface_size,
        };
    }
};

pub const Change = struct {
    previous: ?SurfaceState = null,
    current: ?SurfaceState = null,
    surface_damage: ?Damage = null,
    buffer_damage: ?Damage = null,
    /// Stacking, opacity, or occlusion changes can invalidate unchanged bounds.
    invalidate_bounds: bool = false,
};

pub const Config = struct {
    image_count: usize,
    max_samples: usize,
    max_client_rects: usize,
    max_scene_rects: usize,
    max_repair_rects: usize,
    max_render_rects: usize,
};

pub const Error = std.mem.Allocator.Error || render.ValidationError || error{
    InvalidConfig,
    StaleImage,
    PlanPending,
    NoPlanPending,
    SampleCapacityExceeded,
    MissingCurrentSample,
    CurrentSampleMismatch,
    DuplicateCurrentChange,
};

const Region = struct {
    rects: []render.Rect,
    count: usize = 0,
    full: bool = false,

    fn clear(self: *Region) void {
        self.count = 0;
        self.full = false;
    }

    fn setFull(self: *Region, output: render.Size) void {
        self.count = 1;
        self.full = true;
        self.rects[0] = outputRect(output);
    }

    fn add(self: *Region, output: render.Size, value: render.Rect) void {
        if (self.full) return;
        var combined = value;
        var index: usize = 0;
        while (index < self.count) {
            if (touches(self.rects[index], combined)) {
                combined = bounds(self.rects[index], combined);
                self.count -= 1;
                self.rects[index] = self.rects[self.count];
                index = 0;
            } else index += 1;
        }
        if (self.count == self.rects.len) {
            self.setFull(output);
            return;
        }
        self.rects[self.count] = combined;
        self.count += 1;
    }

    fn addRegion(self: *Region, output: render.Size, other: Region) void {
        if (other.full) {
            self.setFull(output);
            return;
        }
        for (other.rects[0..other.count]) |value| self.add(output, value);
    }

    fn slice(self: Region) []const render.Rect {
        return self.rects[0..self.count];
    }
};

const Image = struct {
    last_generation: u32 = 0,
    stale: Region,
};

pub const Planner = struct {
    allocator: std.mem.Allocator,
    output: render.Size,
    output_transform: render.Transform,
    physical_output: render.Size,
    images: []Image,
    stale_storage: []render.Rect,
    planned_samples: []render.PlannedSample,
    client: Region,
    scene: Region,
    repair: Region,
    combined: Region,
    pending: bool = false,
    pending_handle: framebuffer.Handle = undefined,

    pub fn init(
        allocator: std.mem.Allocator,
        output: render.Size,
        output_transform: render.Transform,
        config: Config,
    ) Error!Planner {
        try render.validateOutput(output);
        if (config.image_count == 0 or config.max_samples == 0 or
            config.max_client_rects == 0 or config.max_scene_rects == 0 or
            config.max_repair_rects == 0 or config.max_render_rects == 0 or
            config.image_count > std.math.maxInt(u32) or
            config.max_samples > std.math.maxInt(u32))
            return error.InvalidConfig;
        const stale_count = std.math.mul(
            usize,
            config.image_count,
            config.max_repair_rects,
        ) catch return error.InvalidConfig;
        const images = try allocator.alloc(Image, config.image_count);
        errdefer allocator.free(images);
        const stale = try allocator.alloc(render.Rect, stale_count);
        errdefer allocator.free(stale);
        const samples = try allocator.alloc(render.PlannedSample, config.max_samples);
        errdefer allocator.free(samples);
        const client = try allocator.alloc(render.Rect, config.max_client_rects);
        errdefer allocator.free(client);
        const scene = try allocator.alloc(render.Rect, config.max_scene_rects);
        errdefer allocator.free(scene);
        const repair = try allocator.alloc(render.Rect, config.max_repair_rects);
        errdefer allocator.free(repair);
        const combined = try allocator.alloc(render.Rect, config.max_render_rects);
        errdefer allocator.free(combined);

        const physical = transformedSize(output, output_transform);
        for (images, 0..) |*image, index| {
            image.* = .{ .stale = .{
                .rects = stale[index * config.max_repair_rects ..][0..config.max_repair_rects],
            } };
            image.stale.setFull(physical);
        }
        return .{
            .allocator = allocator,
            .output = output,
            .output_transform = output_transform,
            .physical_output = physical,
            .images = images,
            .stale_storage = stale,
            .planned_samples = samples,
            .client = .{ .rects = client },
            .scene = .{ .rects = scene },
            .repair = .{ .rects = repair },
            .combined = .{ .rects = combined },
        };
    }

    pub fn deinit(self: *Planner) void {
        self.allocator.free(self.combined.rects);
        self.allocator.free(self.repair.rects);
        self.allocator.free(self.scene.rects);
        self.allocator.free(self.client.rects);
        self.allocator.free(self.planned_samples);
        self.allocator.free(self.stale_storage);
        self.allocator.free(self.images);
        self.* = undefined;
    }

    pub fn allocatedBytes(self: Planner) usize {
        return self.images.len * @sizeOf(Image) +
            self.stale_storage.len * @sizeOf(render.Rect) +
            self.planned_samples.len * @sizeOf(render.PlannedSample) +
            (self.client.rects.len + self.scene.rects.len + self.repair.rects.len +
                self.combined.rects.len) * @sizeOf(render.Rect);
    }

    /// Validates all fallible identities and geometry before touching scratch
    /// state. Unsupported/overflowing damage geometry degrades to full output.
    pub fn prepare(
        self: *Planner,
        handle: framebuffer.Handle,
        list: render.List,
        changes: []const Change,
    ) Error!render.DamagePlan {
        if (self.pending) return error.PlanPending;
        try self.validateHandle(handle);
        try render.validateList(list);
        if (!std.meta.eql(list.output, self.output)) return error.InvalidOutput;
        if (list.samples.len > self.planned_samples.len)
            return error.SampleCapacityExceeded;
        try validateChanges(list, changes);

        self.client.clear();
        self.scene.clear();
        self.repair.clear();
        self.combined.clear();
        const image = self.images[handle.slot];
        self.repair.addRegion(self.physical_output, image.stale);

        for (list.samples, 0..) |sample, index| {
            self.planned_samples[index] = .{
                .source_index = @intCast(index),
                .sample = sample.sample,
                .presentation = sample.presentation,
                .crop = sample.crop,
                .destination = transformGeometryRect(sample.destination, self.output, self.output_transform),
                .clip = transformGeometryRect(sample.clip, self.output, self.output_transform),
                .transform = compose(self.output_transform, sample.transform),
                .global_alpha = sample.global_alpha,
            };
        }

        for (changes) |change| self.addChange(change);
        self.combined.addRegion(self.physical_output, self.client);
        self.combined.addRegion(self.physical_output, self.scene);
        self.combined.addRegion(self.physical_output, self.repair);
        self.pending = true;
        self.pending_handle = handle;
        return .{
            .output = self.physical_output,
            .samples = self.planned_samples[0..list.samples.len],
            .client_damage = self.client.slice(),
            .scene_damage = self.scene.slice(),
            .repair_damage = self.repair.slice(),
            .render_damage = self.combined.slice(),
            .client_full = self.client.full,
            .scene_full = self.scene.full,
            .repair_full = self.repair.full,
            .render_full = self.combined.full,
        };
    }

    /// Commits a successfully rendered plan. Repair is deliberately omitted
    /// from the damage propagated to images that missed this frame.
    pub fn publish(self: *Planner) Error!void {
        if (!self.pending) return error.NoPlanPending;
        const target: usize = self.pending_handle.slot;
        for (self.images, 0..) |*image, index| {
            if (index == target) {
                image.stale.clear();
                image.last_generation = self.pending_handle.generation;
            } else {
                image.stale.addRegion(self.physical_output, self.client);
                image.stale.addRegion(self.physical_output, self.scene);
            }
        }
        self.pending = false;
    }

    /// Cancels a failed render. No image validity or generation changes.
    pub fn cancel(self: *Planner) Error!void {
        if (!self.pending) return error.NoPlanPending;
        self.pending = false;
    }

    fn validateHandle(self: Planner, handle: framebuffer.Handle) Error!void {
        if (handle.slot >= self.images.len or handle.generation == 0 or
            handle.generation <= self.images[handle.slot].last_generation)
            return error.StaleImage;
    }

    fn addChange(self: *Planner, change: Change) void {
        const bounds_changed = change.invalidate_bounds or change.previous == null or
            change.current == null or !sameVisual(change.previous.?, change.current.?);
        if (bounds_changed) {
            if (change.previous) |previous| self.addBounds(&self.scene, previous);
            if (change.current) |current| self.addBounds(&self.scene, current);
        }
        const current = change.current orelse return;
        if (change.surface_damage) |damage| {
            if (!validDamage(damage)) {
                self.client.setFull(self.physical_output);
                return;
            }
            self.addMapped(&self.client, mapSurfaceDamage(current, damage));
        }
        if (change.buffer_damage) |damage| {
            if (!validDamage(damage)) {
                self.client.setFull(self.physical_output);
                return;
            }
            self.addMapped(&self.client, mapBufferDamage(current, damage));
        }
    }

    fn addBounds(self: *Planner, region: *Region, state: SurfaceState) void {
        if (!validStateGeometry(state)) {
            region.setFull(self.physical_output);
            return;
        }
        const logical = clippedBounds(state) orelse return;
        const physical = transformRect(logical, self.output, self.output_transform) orelse return;
        region.add(self.physical_output, physical);
    }

    fn addMapped(self: *Planner, region: *Region, logical: ?render.Rect) void {
        const value = logical orelse return;
        const physical = transformRect(value, self.output, self.output_transform) orelse return;
        region.add(self.physical_output, physical);
    }
};

fn validateChanges(list: render.List, changes: []const Change) Error!void {
    for (changes, 0..) |change, index| {
        const current = change.current orelse continue;
        const sample_index = findSample(list, current) orelse return error.MissingCurrentSample;
        if (!matchesSample(current, list.samples[sample_index]))
            return error.CurrentSampleMismatch;
        for (changes[0..index]) |earlier| if (earlier.current) |value| {
            if (std.meta.eql(value.sample, current.sample))
                return error.DuplicateCurrentChange;
        };
    }
}

fn findSample(list: render.List, state: SurfaceState) ?usize {
    for (list.samples, 0..) |sample, index| {
        if (std.meta.eql(sample.sample, state.sample) and
            std.meta.eql(sample.presentation, state.presentation)) return index;
    }
    return null;
}

fn matchesSample(state: SurfaceState, sample: render.SurfaceSample) bool {
    return std.meta.eql(state.crop, sample.crop) and
        std.meta.eql(state.destination, sample.destination) and
        std.meta.eql(state.clip, sample.clip) and state.transform == sample.transform and
        state.surface_size.width != 0 and state.surface_size.height != 0;
}

fn sameVisual(a: SurfaceState, b: SurfaceState) bool {
    return std.meta.eql(a.crop, b.crop) and
        std.meta.eql(a.destination, b.destination) and
        std.meta.eql(a.clip, b.clip) and a.transform == b.transform and
        std.meta.eql(a.surface_size, b.surface_size);
}

fn validDamage(damage: Damage) bool {
    return damage.empty or (damage.max_x > damage.min_x and damage.max_y > damage.min_y);
}

fn validStateGeometry(state: SurfaceState) bool {
    return state.destination.width != 0 and state.destination.height != 0 and
        state.clip.width != 0 and state.clip.height != 0 and
        state.surface_size.width != 0 and state.surface_size.height != 0;
}

fn clippedBounds(state: SurfaceState) ?render.Rect {
    return intersect(intersect(state.destination, state.clip) orelse return null, outputRect(.{ .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) }));
}

fn mapSurfaceDamage(state: SurfaceState, damage: Damage) ?render.Rect {
    const source = clipDamage(damage, state.surface_size) orelse return null;
    const x = scaleInterval(source[0], source[2], state.surface_size.width, state.destination.width) orelse
        return null;
    const y = scaleInterval(source[1], source[3], state.surface_size.height, state.destination.height) orelse
        return null;
    return clipMapped(state, x, y);
}

fn mapBufferDamage(state: SurfaceState, damage: Damage) ?render.Rect {
    if (damage.empty) return null;
    const one: i128 = render.fixed_one;
    const left = @max(@as(i128, state.crop.x), @as(i128, damage.min_x) * one);
    const top = @max(@as(i128, state.crop.y), @as(i128, damage.min_y) * one);
    const right = @min(@as(i128, state.crop.x) + state.crop.width, @as(i128, damage.max_x) * one);
    const bottom = @min(@as(i128, state.crop.y) + state.crop.height, @as(i128, damage.max_y) * one);
    if (right <= left or bottom <= top) return null;
    const swaps_axes = switch (state.transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => true,
        else => false,
    };
    const u_destination = if (swaps_axes) state.destination.height else state.destination.width;
    const v_destination = if (swaps_axes) state.destination.width else state.destination.height;
    const u = scaleInterval(left - state.crop.x, right - state.crop.x, @intCast(state.crop.width), u_destination) orelse return null;
    const v = scaleInterval(top - state.crop.y, bottom - state.crop.y, @intCast(state.crop.height), v_destination) orelse return null;
    const dw: i64 = state.destination.width;
    const dh: i64 = state.destination.height;
    const xy: [4]i64 = switch (state.transform) {
        .normal => .{ u[0], v[0], u[1], v[1] },
        .@"90" => .{ v[0], dh - u[1], v[1], dh - u[0] },
        .@"180" => .{ dw - u[1], dh - v[1], dw - u[0], dh - v[0] },
        .@"270" => .{ dw - v[1], u[0], dw - v[0], u[1] },
        .flipped => .{ dw - u[1], v[0], dw - u[0], v[1] },
        .flipped_90 => .{ v[0], u[0], v[1], u[1] },
        .flipped_180 => .{ u[0], dh - v[1], u[1], dh - v[0] },
        .flipped_270 => .{ dw - v[1], dh - u[1], dw - v[0], dh - u[0] },
    };
    return clipMapped(state, .{ xy[0], xy[2] }, .{ xy[1], xy[3] });
}

fn clipDamage(damage: Damage, size: render.Size) ?[4]i128 {
    if (damage.empty) return null;
    const left = @max(@as(i128, 0), damage.min_x);
    const top = @max(@as(i128, 0), damage.min_y);
    const right = @min(@as(i128, size.width), damage.max_x);
    const bottom = @min(@as(i128, size.height), damage.max_y);
    if (right <= left or bottom <= top) return null;
    return .{ left, top, right, bottom };
}

fn scaleInterval(start: i128, end: i128, source: u32, destination: u32) ?[2]i64 {
    if (source == 0 or start < 0 or end < start) return null;
    const first = @divFloor(start * destination, source);
    const last = @divFloor(end * destination + source - 1, source);
    if (first > std.math.maxInt(i64) or last > std.math.maxInt(i64)) return null;
    return .{ @intCast(first), @intCast(last) };
}

fn clipMapped(state: SurfaceState, x: [2]i64, y: [2]i64) ?render.Rect {
    const mapped = rectFromEdges(
        @as(i64, state.destination.x) + x[0],
        @as(i64, state.destination.y) + y[0],
        @as(i64, state.destination.x) + x[1],
        @as(i64, state.destination.y) + y[1],
    ) orelse return null;
    return intersect(intersect(mapped, state.destination) orelse return null, state.clip);
}

fn transformedSize(size: render.Size, transform: render.Transform) render.Size {
    return switch (transform) {
        .@"90", .@"270", .flipped_90, .flipped_270 => .{ .width = size.height, .height = size.width },
        else => size,
    };
}

fn transformRect(value: render.Rect, output: render.Size, transform: render.Transform) ?render.Rect {
    const clipped = intersect(value, outputRect(output)) orelse return null;
    const result = transformGeometryRect(clipped, output, transform);
    return .{
        .x = @intCast(result.x),
        .y = @intCast(result.y),
        .width = result.width,
        .height = result.height,
    };
}

fn transformGeometryRect(value: render.Rect, output: render.Size, transform: render.Transform) render.PlanRect {
    const x: i64 = value.x;
    const y: i64 = value.y;
    const right = x + value.width;
    const bottom = y + value.height;
    const width: i64 = output.width;
    const height: i64 = output.height;
    const edges: [4]i64 = switch (transform) {
        .normal => .{ x, y, right, bottom },
        .@"90" => .{ y, width - right, bottom, width - x },
        .@"180" => .{ width - right, height - bottom, width - x, height - y },
        .@"270" => .{ height - bottom, x, height - y, right },
        .flipped => .{ width - right, y, width - x, bottom },
        .flipped_90 => .{ y, x, bottom, right },
        .flipped_180 => .{ x, height - bottom, right, height - y },
        .flipped_270 => .{ height - bottom, width - right, height - y, width - x },
    };
    return .{
        .x = edges[0],
        .y = edges[1],
        .width = @intCast(edges[2] - edges[0]),
        .height = @intCast(edges[3] - edges[1]),
    };
}

fn compose(outer: render.Transform, inner: render.Transform) render.Transform {
    const points = [_][2]i8{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 } };
    inline for (std.meta.tags(render.Transform)) |candidate| {
        var equal = true;
        inline for (points) |point| {
            const actual = unitPoint(outer, unitPoint(inner, point));
            if (!std.meta.eql(actual, unitPoint(candidate, point))) equal = false;
        }
        if (equal) return candidate;
    }
    unreachable;
}

fn unitPoint(transform: render.Transform, point: [2]i8) [2]i8 {
    const x = point[0];
    const y = point[1];
    return switch (transform) {
        .normal => .{ x, y },
        .@"90" => .{ y, 1 - x },
        .@"180" => .{ 1 - x, 1 - y },
        .@"270" => .{ 1 - y, x },
        .flipped => .{ 1 - x, y },
        .flipped_90 => .{ y, x },
        .flipped_180 => .{ x, 1 - y },
        .flipped_270 => .{ 1 - y, 1 - x },
    };
}

fn outputRect(size: render.Size) render.Rect {
    return .{ .x = 0, .y = 0, .width = size.width, .height = size.height };
}

fn rectFromEdges(left: i64, top: i64, right: i64, bottom: i64) ?render.Rect {
    if (right <= left or bottom <= top or left < std.math.minInt(i32) or
        top < std.math.minInt(i32) or left > std.math.maxInt(i32) or
        top > std.math.maxInt(i32) or right - left > std.math.maxInt(u32) or
        bottom - top > std.math.maxInt(u32)) return null;
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(right - left), .height = @intCast(bottom - top) };
}

fn intersect(a: render.Rect, b: render.Rect) ?render.Rect {
    return rectFromEdges(
        @max(a.x, b.x),
        @max(a.y, b.y),
        @min(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width),
        @min(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height),
    );
}

fn touches(a: render.Rect, b: render.Rect) bool {
    return @as(i64, a.x) <= @as(i64, b.x) + b.width and
        @as(i64, b.x) <= @as(i64, a.x) + a.width and
        @as(i64, a.y) <= @as(i64, b.y) + b.height and
        @as(i64, b.y) <= @as(i64, a.y) + a.height;
}

fn bounds(a: render.Rect, b: render.Rect) render.Rect {
    const left = @min(a.x, b.x);
    const top = @min(a.y, b.y);
    const right = @max(@as(i64, a.x) + a.width, @as(i64, b.x) + b.width);
    const bottom = @max(@as(i64, a.y) + a.height, @as(i64, b.y) + b.height);
    return rectFromEdges(left, top, right, bottom).?;
}

fn testConfig(images: usize) Config {
    return .{
        .image_count = images,
        .max_samples = 4,
        .max_client_rects = 4,
        .max_scene_rects = 4,
        .max_repair_rects = 4,
        .max_render_rects = 8,
    };
}

fn testSample(
    surface: u64,
    sequence: u64,
    bytes: []const u8,
    destination: render.Rect,
) render.SurfaceSample {
    return .{
        .sample = .{ .surface = surface, .commit_sequence = sequence },
        .presentation = .{ .slot = @intCast(surface - 1), .generation = @intCast(sequence) },
        .source = .{
            .size = .{ .width = 1, .height = 1 },
            .stride = 4,
            .format = .xrgb8888,
            .bytes = bytes,
        },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = destination,
        .clip = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
    };
}

fn testList(samples: []const render.SurfaceSample) render.List {
    return .{
        .output = .{ .width = 100, .height = 100 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = samples,
    };
}

fn prime(planner: *Planner, image_count: usize) !void {
    for (0..image_count) |slot| {
        const plan = try planner.prepare(
            .{ .slot = @intCast(slot), .generation = 1 },
            testList(&.{}),
            &.{},
        );
        try std.testing.expect(plan.repair_full);
        try planner.publish();
    }
}

test "damage: movement removal and explicit occlusion invalidate old and new bounds" {
    var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, testConfig(1));
    defer planner.deinit();
    try prime(&planner, 1);
    const pixel = [_]u8{0} ** 4;
    const old_sample = testSample(1, 1, &pixel, .{ .x = 2, .y = 3, .width = 10, .height = 8 });
    const new_sample = testSample(1, 2, &pixel, .{ .x = 30, .y = 20, .width = 10, .height = 8 });
    const old = SurfaceState.fromSample(old_sample, .{ .width = 10, .height = 8 });
    const new = SurfaceState.fromSample(new_sample, .{ .width = 10, .height = 8 });

    var plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{new_sample}), &.{.{ .previous = old, .current = new }});
    try std.testing.expectEqual(@as(usize, 2), plan.scene_damage.len);
    try std.testing.expectEqual(render.Rect{ .x = 2, .y = 3, .width = 10, .height = 8 }, plan.scene_damage[0]);
    try std.testing.expectEqual(render.Rect{ .x = 30, .y = 20, .width = 10, .height = 8 }, plan.scene_damage[1]);
    try planner.publish();

    plan = try planner.prepare(.{ .slot = 0, .generation = 3 }, testList(&.{}), &.{.{ .previous = new }});
    try std.testing.expectEqualSlices(render.Rect, &.{new_sample.destination}, plan.scene_damage);
    try planner.publish();

    const visible = testSample(1, 3, &pixel, new_sample.destination);
    const visible_state = SurfaceState.fromSample(visible, .{ .width = 10, .height = 8 });
    plan = try planner.prepare(.{ .slot = 0, .generation = 4 }, testList(&.{visible}), &.{.{
        .previous = visible_state,
        .current = visible_state,
        .invalidate_bounds = true,
    }});
    try std.testing.expectEqualSlices(render.Rect, &.{visible.destination}, plan.scene_damage);
    try planner.cancel();
}

test "damage: committed surface damage scales through destination and clip" {
    var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, testConfig(1));
    defer planner.deinit();
    try prime(&planner, 1);
    const pixel = [_]u8{0} ** 4;
    var sample = testSample(1, 1, &pixel, .{ .x = 10, .y = 10, .width = 40, .height = 20 });
    sample.clip = .{ .x = 20, .y = 10, .width = 20, .height = 20 };
    const state = SurfaceState.fromSample(sample, .{ .width = 20, .height = 10 });
    const plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{sample}), &.{.{
        .previous = state,
        .current = state,
        .surface_damage = Damage.rect(0, 0, 10, 5),
    }});
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 20, .y = 10, .width = 10, .height = 10 }}, plan.client_damage);
    try planner.cancel();
}

test "damage: buffer crop transform clip and output transform are conservative and exact" {
    var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 50 }, .@"90", testConfig(1));
    defer planner.deinit();
    const bytes = [_]u8{0} ** (40 * 20 * 4);
    var sample = testSample(1, 1, &bytes, .{ .x = 10, .y = 5, .width = 40, .height = 20 });
    sample.source.size = .{ .width = 40, .height = 20 };
    sample.source.stride = 40 * 4;
    sample.crop = render.SourceRect.pixels(10, 0, 20, 20);
    sample.clip = .{ .x = 20, .y = 5, .width = 20, .height = 20 };
    sample.transform = .@"90";
    const state = SurfaceState.fromSample(sample, .{ .width = 40, .height = 20 });
    const plan = try planner.prepare(.{ .slot = 0, .generation = 1 }, .{
        .output = .{ .width = 100, .height = 50 },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = &.{sample},
    }, &.{.{
        .previous = state,
        .current = state,
        .buffer_damage = Damage.rect(10, 0, 10, 10),
        .invalidate_bounds = true,
    }});
    try std.testing.expectEqual(render.Size{ .width = 50, .height = 100 }, plan.output);
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 15, .y = 70, .width = 10, .height = 10 }}, plan.client_damage);
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 5, .y = 60, .width = 20, .height = 20 }}, plan.scene_damage);
    try std.testing.expectEqual(render.PlanRect{ .x = 5, .y = 50, .width = 20, .height = 40 }, plan.samples[0].destination);
    try std.testing.expectEqual(render.PlanRect{ .x = 5, .y = 60, .width = 20, .height = 20 }, plan.samples[0].clip);
    try std.testing.expectEqual(render.Transform.@"180", plan.samples[0].transform);
    try std.testing.expectEqual(sample.sample, plan.samples[0].sample);
    try std.testing.expectEqual(sample.presentation, plan.samples[0].presentation);
    try planner.cancel();
}

test "damage: all source and output transforms map exact conservative bounds" {
    const transforms = std.meta.tags(render.Transform);
    const expected = [_]render.Rect{
        .{ .x = 1, .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = 2, .width = 1, .height = 1 },
        .{ .x = 2, .y = 2, .width = 1, .height = 1 },
        .{ .x = 2, .y = 1, .width = 1, .height = 1 },
        .{ .x = 2, .y = 0, .width = 1, .height = 1 },
        .{ .x = 0, .y = 1, .width = 1, .height = 1 },
        .{ .x = 1, .y = 2, .width = 1, .height = 1 },
        .{ .x = 2, .y = 2, .width = 1, .height = 1 },
    };
    for (transforms, expected) |transform, wanted| {
        const swaps_axes = switch (transform) {
            .@"90", .@"270", .flipped_90, .flipped_270 => true,
            else => false,
        };
        const state: SurfaceState = .{
            .sample = .{ .surface = 1, .commit_sequence = 1 },
            .presentation = .{ .slot = 0, .generation = 1 },
            .crop = render.SourceRect.pixels(0, 0, 4, 3),
            .destination = .{
                .x = 10,
                .y = 20,
                .width = if (swaps_axes) 3 else 4,
                .height = if (swaps_axes) 4 else 3,
            },
            .clip = .{ .x = 0, .y = 0, .width = 100, .height = 100 },
            .transform = transform,
            .surface_size = .{ .width = 4, .height = 3 },
        };
        var mapped = mapBufferDamage(state, Damage.rect(1, 0, 1, 1)).?;
        mapped.x -= 10;
        mapped.y -= 20;
        try std.testing.expectEqual(wanted, mapped);
        try std.testing.expectEqual(
            wanted,
            transformRect(.{ .x = 1, .y = 0, .width = 1, .height = 1 }, .{ .width = 4, .height = 3 }, transform).?,
        );
    }
}

test "damage: each scanout image repairs only scene changes it missed" {
    var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, testConfig(3));
    defer planner.deinit();
    try prime(&planner, 3);
    const pixel = [_]u8{0} ** 4;

    const first = testSample(1, 1, &pixel, .{ .x = 0, .y = 0, .width = 100, .height = 100 });
    const first_state = SurfaceState.fromSample(first, .{ .width = 100, .height = 100 });
    var plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{first}), &.{.{
        .previous = first_state,
        .current = first_state,
        .surface_damage = Damage.rect(1, 1, 4, 4),
    }});
    try std.testing.expectEqual(@as(usize, 0), plan.repair_damage.len);
    try planner.publish();

    const second = testSample(1, 2, &pixel, first.destination);
    const second_state = SurfaceState.fromSample(second, first_state.surface_size);
    plan = try planner.prepare(.{ .slot = 1, .generation = 2 }, testList(&.{second}), &.{.{
        .previous = second_state,
        .current = second_state,
        .surface_damage = Damage.rect(20, 20, 4, 4),
    }});
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 1, .y = 1, .width = 4, .height = 4 }}, plan.repair_damage);
    try planner.publish();

    plan = try planner.prepare(.{ .slot = 0, .generation = 3 }, testList(&.{second}), &.{});
    try std.testing.expectEqualSlices(render.Rect, &.{.{ .x = 20, .y = 20, .width = 4, .height = 4 }}, plan.repair_damage);
    try planner.cancel();

    plan = try planner.prepare(.{ .slot = 2, .generation = 2 }, testList(&.{second}), &.{});
    try std.testing.expectEqual(@as(usize, 2), plan.repair_damage.len);
    try std.testing.expectEqual(render.Rect{ .x = 1, .y = 1, .width = 4, .height = 4 }, plan.repair_damage[0]);
    try std.testing.expectEqual(render.Rect{ .x = 20, .y = 20, .width = 4, .height = 4 }, plan.repair_damage[1]);
    try planner.cancel();
}

test "damage: capacity exhaustion and unsupported damage fall back to full output" {
    const pixel = [_]u8{0} ** 4;
    const a = testSample(1, 1, &pixel, .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    const b = testSample(2, 1, &pixel, .{ .x = 80, .y = 80, .width = 10, .height = 10 });
    const a_state = SurfaceState.fromSample(a, .{ .width = 10, .height = 10 });
    const b_state = SurfaceState.fromSample(b, .{ .width = 10, .height = 10 });
    {
        var config = testConfig(1);
        config.max_client_rects = 1;
        var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, config);
        defer planner.deinit();
        try prime(&planner, 1);
        var plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{ a, b }), &.{
            .{ .previous = a_state, .current = a_state, .surface_damage = Damage.rect(0, 0, 2, 2) },
            .{ .previous = b_state, .current = b_state, .surface_damage = Damage.rect(0, 0, 2, 2) },
        });
        try std.testing.expect(plan.client_full);
        try std.testing.expectEqualSlices(render.Rect, &.{outputRect(planner.physical_output)}, plan.client_damage);
        try planner.cancel();

        plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{a}), &.{.{
            .previous = a_state,
            .current = a_state,
            .surface_damage = .{ .min_x = std.math.minInt(i64), .min_y = 0, .max_x = std.math.minInt(i64), .max_y = 1 },
        }});
        try std.testing.expect(plan.client_full);
        try planner.cancel();
    }

    {
        var config = testConfig(1);
        config.max_render_rects = 1;
        var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, config);
        defer planner.deinit();
        try prime(&planner, 1);
        const plan = try planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{ a, b }), &.{
            .{ .previous = a_state, .current = a_state, .surface_damage = Damage.rect(0, 0, 2, 2) },
            .{ .previous = b_state, .current = b_state, .surface_damage = Damage.rect(0, 0, 2, 2) },
        });
        try std.testing.expect(!plan.client_full);
        try std.testing.expect(plan.render_full);
        try std.testing.expect(plan.fullOutput());
        try std.testing.expectEqualSlices(render.Rect, &.{outputRect(planner.physical_output)}, plan.render_damage);
        try planner.cancel();
    }

    var repair_config = testConfig(2);
    repair_config.max_repair_rects = 1;
    var repair_planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, repair_config);
    defer repair_planner.deinit();
    try prime(&repair_planner, 2);
    var plan = try repair_planner.prepare(.{ .slot = 0, .generation = 2 }, testList(&.{a}), &.{.{
        .previous = a_state,
        .current = a_state,
        .surface_damage = Damage.rect(0, 0, 2, 2),
    }});
    try repair_planner.publish();
    plan = try repair_planner.prepare(.{ .slot = 0, .generation = 3 }, testList(&.{b}), &.{.{
        .previous = b_state,
        .current = b_state,
        .surface_damage = Damage.rect(0, 0, 2, 2),
    }});
    try repair_planner.publish();
    plan = try repair_planner.prepare(.{ .slot = 1, .generation = 2 }, testList(&.{b}), &.{});
    try std.testing.expect(plan.repair_full);
    try std.testing.expectEqualSlices(render.Rect, &.{outputRect(repair_planner.physical_output)}, plan.repair_damage);
    try repair_planner.cancel();
}

test "damage: stale identities handles and cancelled plans are transactional" {
    if (@sizeOf(usize) > @sizeOf(u32)) {
        var invalid = testConfig(1);
        invalid.max_samples = @as(usize, std.math.maxInt(u32)) + 1;
        try std.testing.expectError(
            error.InvalidConfig,
            Planner.init(std.testing.allocator, .{ .width = 1, .height = 1 }, .normal, invalid),
        );
    }
    var planner = try Planner.init(std.testing.allocator, .{ .width = 100, .height = 100 }, .normal, testConfig(1));
    defer planner.deinit();
    const allocated = planner.allocatedBytes();
    const pixel = [_]u8{0} ** 4;
    const sample = testSample(1, 1, &pixel, .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    var stale_state = SurfaceState.fromSample(sample, .{ .width = 10, .height = 10 });
    stale_state.presentation.generation += 1;
    try std.testing.expectError(error.MissingCurrentSample, planner.prepare(
        .{ .slot = 0, .generation = 1 },
        testList(&.{sample}),
        &.{.{ .current = stale_state }},
    ));

    var plan = try planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{sample}), &.{});
    try std.testing.expect(plan.repair_full);
    try std.testing.expectError(error.PlanPending, planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{sample}), &.{}));
    try planner.cancel();
    plan = try planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{sample}), &.{});
    try std.testing.expect(plan.repair_full);
    try planner.publish();
    try std.testing.expectError(error.StaleImage, planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{sample}), &.{}));
    try std.testing.expectError(error.StaleImage, planner.prepare(.{ .slot = 1, .generation = 2 }, testList(&.{sample}), &.{}));
    try std.testing.expectEqual(allocated, planner.allocatedBytes());
}

test "damage: prepare publish and cancel make no allocator calls" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 7 });
    var planner = try Planner.init(failing.allocator(), .{ .width = 100, .height = 100 }, .normal, testConfig(1));
    defer planner.deinit();
    try std.testing.expectEqual(@as(usize, 7), failing.allocations);
    const plan = try planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{}), &.{});
    try std.testing.expect(plan.repair_full);
    try planner.cancel();
    _ = try planner.prepare(.{ .slot = 0, .generation = 1 }, testList(&.{}), &.{});
    try planner.publish();
    try std.testing.expectEqual(@as(usize, 7), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}
