//! Pixman CPU renderer for R10 linear scanout targets.
//!
//! `render` accepts an acquired image, maps it, applies the R13 render-damage
//! plan in protocol z-order, and unmaps it. Success leaves the image acquired
//! for the output path to submit. Failure never submits and makes a best effort
//! to unmap, leaving the handle valid for R10 `discard`.

const std = @import("std");
const gbm = @import("../backend/gbm.zig");
const drm = @import("../backend/drm/manager.zig");
const framebuffer = @import("../backend/drm/framebuffer.zig");
const pixman = @import("pixman.zig");
const render_types = @import("types.zig");

pub const Config = pixman.Config;

pub const Renderer = struct {
    implementation: pixman.Renderer,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Renderer {
        return .{ .implementation = try pixman.Renderer.init(allocator, config) };
    }

    pub fn deinit(self: *Renderer) void {
        self.implementation.deinit();
        self.* = undefined;
    }

    /// The structural target API is R10 Pool's `image`, `map`, and `unmap`.
    /// Keeping this generic also permits deterministic lifecycle tests without
    /// constructing kernel objects; calls with `*framebuffer.Pool` are checked
    /// against that exact API at compile time by `renderPool` below.
    pub fn render(
        self: *Renderer,
        target: anytype,
        handle: anytype,
        render_list: render_types.List,
        damage_plan: render_types.DamagePlan,
    ) !void {
        try render_types.validateList(render_list);
        try render_types.validateOutput(damage_plan.output);
        const image = try target.image(handle);
        if (image.metadata.modifier != gbm.modifier_linear or
            image.metadata.width != damage_plan.output.width or
            image.metadata.height != damage_plan.output.height or
            (formatFromDrm(image.metadata.format) orelse return error.TargetMismatch) !=
                render_list.output_format)
            return error.TargetMismatch;

        const mapping = try target.map(handle);
        var mapped = true;
        errdefer if (mapped) target.unmap(handle) catch {};
        try self.implementation.draw(render_list, damage_plan, mapping.data, mapping.stride);
        try target.unmap(handle);
        mapped = false;
    }

    pub fn renderPool(
        self: *Renderer,
        target: *framebuffer.Pool,
        handle: framebuffer.Handle,
        render_list: render_types.List,
        damage_plan: render_types.DamagePlan,
    ) !void {
        try self.render(target, handle, render_list, damage_plan);
    }
};

/// CPU output startup always opts into R10's strict linear negotiation. A
/// selected primary plane without XRGB/ARGB linear support fails with R10's
/// clear `NoLinearRenderFormat` error rather than creating an unmappable pool.
pub fn initTargetPool(
    allocator: std.mem.Allocator,
    gbm_platform: gbm.Platform,
    drm_platform: framebuffer.Platform,
    fd: std.posix.fd_t,
    snapshot: drm.Snapshot,
    capacity: usize,
) !framebuffer.Pool {
    return framebuffer.Pool.init(
        allocator,
        gbm_platform,
        drm_platform,
        fd,
        snapshot,
        .{ .capacity = capacity, .linear_only = true },
    );
}

fn formatFromDrm(format: u32) ?render_types.PixelFormat {
    if (format == gbm.format_argb8888) return .argb8888_premultiplied;
    if (format == gbm.format_xrgb8888) return .xrgb8888;
    return null;
}

const FakeTarget = struct {
    bytes: [256]u8 = [_]u8{0xcc} ** 256,
    width: u32,
    height: u32,
    stride: u32,
    format: u32 = gbm.format_xrgb8888,
    mapped: bool = false,
    discarded: bool = false,
    map_count: usize = 0,
    unmap_count: usize = 0,
    submit_count: usize = 0,

    const Image = struct { metadata: gbm.Metadata };

    fn image(self: *FakeTarget, _: u8) !Image {
        return .{ .metadata = .{
            .width = self.width,
            .height = self.height,
            .format = self.format,
            .modifier = gbm.modifier_linear,
            .plane_count = 1,
        } };
    }

    fn map(self: *FakeTarget, _: u8) !framebuffer.Mapping {
        self.mapped = true;
        self.map_count += 1;
        return .{
            .data = self.bytes[0 .. @as(usize, self.stride) * self.height],
            .stride = self.stride,
        };
    }

    fn unmap(self: *FakeTarget, _: u8) !void {
        if (!self.mapped) return error.NotMapped;
        self.mapped = false;
        self.unmap_count += 1;
    }

    fn discard(self: *FakeTarget, _: u8) !void {
        if (self.mapped) return error.StillMapped;
        self.discarded = true;
    }

    fn submit(self: *FakeTarget, _: u8) !void {
        self.submit_count += 1;
    }
};

fn list(width: u32, height: u32, samples: []const render_types.SurfaceSample) render_types.List {
    return .{
        .output = .{ .width = width, .height = height },
        .output_format = .xrgb8888,
        .clear = .{ .r = 0, .g = 0, .b = 0 },
        .samples = samples,
    };
}

fn sample(
    bytes: []const u8,
    width: u32,
    height: u32,
    stride: u32,
    destination: render_types.Rect,
) render_types.SurfaceSample {
    return .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{
            .size = .{ .width = width, .height = height },
            .stride = stride,
            .format = .xrgb8888,
            .bytes = bytes,
        },
        .crop = render_types.SourceRect.pixels(0, 0, @intCast(width), @intCast(height)),
        .destination = destination,
        .clip = destination,
    };
}

fn renderWithDamage(
    renderer: *Renderer,
    target: *FakeTarget,
    render_list: render_types.List,
    render_damage: []const render_types.Rect,
    render_full: bool,
) !void {
    var planned: [2]render_types.PlannedSample = undefined;
    if (render_list.samples.len > planned.len) return error.SampleCapacityExceeded;
    for (render_list.samples, 0..) |value, index| planned[index] = .{
        .source_index = @intCast(index),
        .sample = value.sample,
        .presentation = value.presentation,
        .crop = value.crop,
        .destination = .{
            .x = value.destination.x,
            .y = value.destination.y,
            .width = value.destination.width,
            .height = value.destination.height,
        },
        .clip = .{
            .x = value.clip.x,
            .y = value.clip.y,
            .width = value.clip.width,
            .height = value.clip.height,
        },
        .transform = value.transform,
        .global_alpha = value.global_alpha,
    };
    try renderer.render(target, 0, render_list, .{
        .output = render_list.output,
        .samples = planned[0..render_list.samples.len],
        .client_damage = render_damage,
        .scene_damage = &.{},
        .repair_damage = &.{},
        .render_damage = render_damage,
        .client_full = render_full,
        .scene_full = false,
        .repair_full = false,
        .render_full = render_full,
    });
}

fn renderFull(
    renderer: *Renderer,
    target: *FakeTarget,
    render_list: render_types.List,
) !void {
    const damage = [_]render_types.Rect{.{
        .x = 0,
        .y = 0,
        .width = render_list.output.width,
        .height = render_list.output.height,
    }};
    try renderWithDamage(renderer, target, render_list, &damage, true);
}

fn putPixel(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}

fn expectPixels(target: *const FakeTarget, expected: []const u32) !void {
    var offset: usize = 0;
    for (expected) |value| {
        try std.testing.expectEqual(
            value,
            std.mem.readInt(u32, target.bytes[offset..][0..4], .little),
        );
        offset += 4;
    }
}

test "render: clear is exact and target stride padding is untouched" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 1,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    var target = FakeTarget{ .width = 2, .height = 2, .stride = 12 };
    var clear_list = list(2, 2, &.{});
    clear_list.clear = .{ .r = 0x11, .g = 0x22, .b = 0x33 };
    try renderFull(&renderer, &target, clear_list);
    try std.testing.expectEqual(@as(u32, 0xff112233), std.mem.readInt(u32, target.bytes[0..4], .little));
    try std.testing.expectEqual(@as(u32, 0xff112233), std.mem.readInt(u32, target.bytes[4..8], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xcc, 0xcc, 0xcc }, target.bytes[8..12]);
    try std.testing.expectEqual(@as(u32, 0xff112233), std.mem.readInt(u32, target.bytes[12..16], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xcc, 0xcc, 0xcc }, target.bytes[20..24]);

    var alpha_target = FakeTarget{
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = gbm.format_argb8888,
    };
    var alpha_clear = list(1, 1, &.{});
    alpha_clear.output_format = .argb8888_premultiplied;
    alpha_clear.clear = .{ .a = 128, .r = 255, .g = 0, .b = 0 };
    try renderFull(&renderer, &alpha_target, alpha_clear);
    try std.testing.expectEqual(
        @as(u32, 0x80800000),
        std.mem.readInt(u32, alpha_target.bytes[0..4], .little),
    );
}

test "render: allocation is bounded by sample metadata instead of maximum source pixels" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 17,
        .max_source_width = 8192,
        .max_source_height = 8192,
    });
    defer renderer.deinit();
    try std.testing.expect(renderer.implementation.allocatedBytes() < 1024);
}

test "render: damage preserves pixels outside the repaired region" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 3,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    const red = [_]u8{ 0, 0, 255, 255 } ** 3;
    const value = sample(&red, 3, 1, 12, .{ .x = 0, .y = 0, .width = 3, .height = 1 });
    var target = FakeTarget{ .width = 3, .height = 1, .stride = 12 };
    const damage = [_]render_types.Rect{.{ .x = 1, .y = 0, .width = 1, .height = 1 }};
    try renderWithDamage(&renderer, &target, list(3, 1, &.{value}), &damage, false);
    try expectPixels(&target, &.{ 0xcccccccc, 0xffff0000, 0xcccccccc });
}

test "render: protocol z-order and clipping are exact" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 2,
        .max_source_width = 1,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    const red = [_]u8{ 0, 0, 255, 255 };
    const green = [_]u8{ 0, 255, 0, 255 };
    const lower = sample(&red, 1, 1, 4, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    var upper = sample(&green, 1, 1, 4, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    upper.sample.surface = 2;
    upper.clip = .{ .x = 1, .y = 0, .width = 1, .height = 1 };
    var target = FakeTarget{ .width = 2, .height = 1, .stride = 8 };
    try renderFull(&renderer, &target, list(2, 1, &.{ lower, upper }));
    try expectPixels(&target, &.{ 0xffff0000, 0xff00ff00 });
}

test "render: crop nearest scale and source stride padding are exact" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 4,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    var source_bytes = [_]u8{0xaa} ** 20;
    putPixel(&source_bytes, 0, 0xffff0000);
    putPixel(&source_bytes, 4, 0xff00ff00);
    putPixel(&source_bytes, 8, 0xff0000ff);
    putPixel(&source_bytes, 12, 0xffffffff);
    var value = sample(&source_bytes, 4, 1, 20, .{ .x = 0, .y = 0, .width = 4, .height = 1 });
    value.crop = render_types.SourceRect.pixels(1, 0, 2, 1);
    var target = FakeTarget{ .width = 4, .height = 1, .stride = 16 };
    try renderFull(&renderer, &target, list(4, 1, &.{value}));
    try expectPixels(&target, &.{ 0xff00ff00, 0xff00ff00, 0xff0000ff, 0xff0000ff });
}

test "render: all wl_output transforms are exact" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 2,
        .max_source_height = 3,
    });
    defer renderer.deinit();
    var bytes: [24]u8 = undefined;
    for ([_]u32{ 0xff000001, 0xff000002, 0xff000003, 0xff000004, 0xff000005, 0xff000006 }, 0..) |pixel, index|
        putPixel(&bytes, index * 4, pixel);
    const cases = [_]struct {
        transform: render_types.Transform,
        width: u32,
        height: u32,
        expected: []const u32,
    }{
        .{ .transform = .normal, .width = 2, .height = 3, .expected = &.{ 0xff000001, 0xff000002, 0xff000003, 0xff000004, 0xff000005, 0xff000006 } },
        .{ .transform = .@"90", .width = 3, .height = 2, .expected = &.{ 0xff000002, 0xff000004, 0xff000006, 0xff000001, 0xff000003, 0xff000005 } },
        .{ .transform = .@"180", .width = 2, .height = 3, .expected = &.{ 0xff000006, 0xff000005, 0xff000004, 0xff000003, 0xff000002, 0xff000001 } },
        .{ .transform = .@"270", .width = 3, .height = 2, .expected = &.{ 0xff000005, 0xff000003, 0xff000001, 0xff000006, 0xff000004, 0xff000002 } },
        .{ .transform = .flipped, .width = 2, .height = 3, .expected = &.{ 0xff000002, 0xff000001, 0xff000004, 0xff000003, 0xff000006, 0xff000005 } },
        .{ .transform = .flipped_90, .width = 3, .height = 2, .expected = &.{ 0xff000001, 0xff000003, 0xff000005, 0xff000002, 0xff000004, 0xff000006 } },
        .{ .transform = .flipped_180, .width = 2, .height = 3, .expected = &.{ 0xff000005, 0xff000006, 0xff000003, 0xff000004, 0xff000001, 0xff000002 } },
        .{ .transform = .flipped_270, .width = 3, .height = 2, .expected = &.{ 0xff000006, 0xff000004, 0xff000002, 0xff000005, 0xff000003, 0xff000001 } },
    };
    for (cases) |case| {
        var value = sample(&bytes, 2, 3, 8, .{ .x = 0, .y = 0, .width = case.width, .height = case.height });
        value.transform = case.transform;
        var target = FakeTarget{ .width = case.width, .height = case.height, .stride = case.width * 4 };
        try renderFull(&renderer, &target, list(case.width, case.height, &.{value}));
        try expectPixels(&target, case.expected);
    }
}

test "render: premultiplied per-pixel and global alpha blend exactly" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 2,
        .max_source_width = 1,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    const blue = [_]u8{ 255, 0, 0, 255 };
    const half_red = [_]u8{ 0, 0, 128, 128 };
    const red = [_]u8{ 0, 0, 255, 255 };
    const background = sample(&blue, 1, 1, 4, .{ .x = 0, .y = 0, .width = 2, .height = 1 });
    var foreground = sample(&half_red, 1, 1, 4, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    foreground.source.format = .argb8888_premultiplied;
    foreground.sample.surface = 2;
    var global = sample(&red, 1, 1, 4, .{ .x = 1, .y = 0, .width = 1, .height = 1 });
    global.sample.surface = 3;
    global.global_alpha = 128;
    var target = FakeTarget{ .width = 2, .height = 1, .stride = 8 };
    try renderFull(&renderer, &target, list(2, 1, &.{ background, foreground }));
    // Render the global-alpha case separately because capacity is two.
    const first = std.mem.readInt(u32, target.bytes[0..4], .little);
    try renderFull(&renderer, &target, list(2, 1, &.{ background, global }));
    try std.testing.expectEqual(@as(u32, 0xff80007f), first);
    try std.testing.expectEqual(@as(u32, 0xff80007f), std.mem.readInt(u32, target.bytes[4..8], .little));
}

test "render: R10 map unmap discard recovery and no submit" {
    var renderer = try Renderer.init(std.testing.allocator, .{
        .max_samples = 1,
        .max_source_width = 1,
        .max_source_height = 1,
    });
    defer renderer.deinit();
    var target = FakeTarget{ .width = 2, .height = 1, .stride = 4 };
    const malformed = sample(&.{}, 1, 1, 4, .{ .x = 0, .y = 0, .width = 1, .height = 1 });
    try std.testing.expectError(
        error.InvalidSource,
        renderFull(&renderer, &target, list(2, 1, &.{malformed})),
    );
    try std.testing.expectEqual(@as(usize, 0), target.map_count);
    try std.testing.expectError(error.InvalidTarget, renderFull(&renderer, &target, list(2, 1, &.{})));
    try std.testing.expect(!target.mapped);
    try std.testing.expectEqual(@as(usize, 1), target.map_count);
    try std.testing.expectEqual(@as(usize, 1), target.unmap_count);
    try std.testing.expectEqual(@as(usize, 0), target.submit_count);
    try target.discard(0);
    try std.testing.expect(target.discarded);
}
