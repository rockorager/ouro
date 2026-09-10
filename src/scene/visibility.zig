//! Cached, renderer-neutral geometric visibility tracking.

const std = @import("std");
const render = @import("../render/types.zig");
const damage = @import("damage.zig");

const Entry = struct {
    output: u64,
    owner: ?u64,
    rect: render.Rect,
    is_opaque: bool,
    group: usize,
    needs_backdrop: bool = false,
};

pub const Tracker = struct {
    candidates: std.ArrayListUnmanaged(Entry) = .empty,
    previous: std.ArrayListUnmanaged(Entry) = .empty,
    visible: std.ArrayListUnmanaged(u64) = .empty,
    next_visible: std.ArrayListUnmanaged(u64) = .empty,
    fragments: std.ArrayListUnmanaged(render.Rect) = .empty,
    next_fragments: std.ArrayListUnmanaged(render.Rect) = .empty,
    backdrop_needed: std.ArrayListUnmanaged(bool) = .empty,

    pub fn deinit(self: *Tracker, allocator: std.mem.Allocator) void {
        self.backdrop_needed.deinit(allocator);
        self.next_fragments.deinit(allocator);
        self.fragments.deinit(allocator);
        self.next_visible.deinit(allocator);
        self.visible.deinit(allocator);
        self.previous.deinit(allocator);
        self.candidates.deinit(allocator);
        self.* = undefined;
    }

    pub fn begin(self: *Tracker) void {
        self.candidates.clearRetainingCapacity();
    }

    pub fn append(
        self: *Tracker,
        allocator: std.mem.Allocator,
        output: u64,
        owner: ?u64,
        sample: render.SurfaceSample,
    ) !void {
        // Alpha does not affect backdrop blur, so retain a fully transparent
        // sample only when its blur can still contribute visible output.
        if (sample.global_alpha == 0 and !render.hasVisibleBlur(sample)) return;
        const rect = damage.intersect(sample.destination, sample.clip) orelse return;
        const group = self.candidates.items.len;
        const is_opaque = sample.global_alpha == 255 and
            (sample.source.format == .xrgb8888 or render.effectRegionCoversSurface(
                sample.opaque_region,
                sample.effect_size,
            ));
        try self.candidates.append(allocator, .{
            .output = output,
            .owner = owner,
            .rect = rect,
            .is_opaque = is_opaque,
            .group = group,
            .needs_backdrop = render.hasVisibleBlur(sample),
        });
        if (is_opaque or sample.global_alpha != 255 or sample.effect_size.width == 0 or
            sample.effect_size.height == 0) return;

        // CSD buffers commonly declare only their interior opaque, excluding
        // shadows. Preserve the exact ordered add/subtract program so a hole
        // never becomes an occluder, and two opaque pieces can jointly cover.
        self.fragments.clearRetainingCapacity();
        const local_bounds: render.Rect = .{ .x = 0, .y = 0, .width = sample.effect_size.width, .height = sample.effect_size.height };
        for (sample.opaque_region) |operation| {
            const value = switch (operation) {
                .add, .subtract => |value| value,
            };
            const local = damage.intersect(.{
                .x = value.x,
                .y = value.y,
                .width = @intCast(value.width),
                .height = @intCast(value.height),
            }, local_bounds) orelse continue;
            switch (operation) {
                .add => try self.fragments.append(allocator, local),
                .subtract => {
                    self.next_fragments.clearRetainingCapacity();
                    for (self.fragments.items) |fragment|
                        try damage.subtractRect(allocator, &self.next_fragments, fragment, local);
                    std.mem.swap(std.ArrayListUnmanaged(render.Rect), &self.fragments, &self.next_fragments);
                },
            }
        }
        for (self.fragments.items) |fragment| {
            const cover = damage.intersect(mapOpaqueRect(fragment, sample) orelse continue, rect) orelse continue;
            try self.candidates.append(allocator, .{
                .output = output,
                .owner = null,
                .rect = cover,
                .is_opaque = true,
                .group = group,
            });
        }
    }

    /// Publishes a new visibility result only after all recomputation succeeds.
    pub fn finish(self: *Tracker, allocator: std.mem.Allocator) !bool {
        if (entriesEqual(self.previous.items, self.candidates.items)) return false;

        self.next_visible.clearRetainingCapacity();
        try self.backdrop_needed.resize(allocator, self.candidates.items.len);
        @memset(self.backdrop_needed.items, false);
        var index = self.candidates.items.len;
        while (index != 0) {
            index -= 1;
            const entry = self.candidates.items[index];
            if (entry.owner == null and !entry.needs_backdrop) continue;
            const owner_visible = if (entry.owner) |owner|
                std.mem.indexOfScalar(u64, self.next_visible.items, owner) != null
            else
                false;
            if (owner_visible and !entry.needs_backdrop) continue;
            self.fragments.clearRetainingCapacity();
            try self.fragments.append(allocator, entry.rect);
            for (self.candidates.items[index + 1 ..], index + 1..) |cover, cover_index| {
                if (cover.output != entry.output or cover.group == entry.group) continue;
                // Blur samples the already-composited backdrop, including
                // pixels outside its own bounds. Do not suspend its producers
                // merely because a later opaque surface hides them directly.
                if (self.backdrop_needed.items[cover_index]) break;
                if (!cover.is_opaque) continue;
                self.next_fragments.clearRetainingCapacity();
                for (self.fragments.items) |fragment|
                    try damage.subtractRect(allocator, &self.next_fragments, fragment, cover.rect);
                std.mem.swap(std.ArrayListUnmanaged(render.Rect), &self.fragments, &self.next_fragments);
                if (self.fragments.items.len == 0) break;
            }
            if (self.fragments.items.len != 0) {
                self.backdrop_needed.items[index] = entry.needs_backdrop;
                if (!owner_visible) if (entry.owner) |owner|
                    try self.next_visible.append(allocator, owner);
            }
        }

        std.mem.swap(std.ArrayListUnmanaged(Entry), &self.previous, &self.candidates);
        std.mem.swap(std.ArrayListUnmanaged(u64), &self.visible, &self.next_visible);
        return true;
    }

    pub fn isVisible(self: Tracker, owner: u64) bool {
        return std.mem.indexOfScalar(u64, self.visible.items, owner) != null;
    }
};

fn entriesEqual(a: []const Entry, b: []const Entry) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (left.output != right.output or left.owner != right.owner or
            left.rect.x != right.rect.x or left.rect.y != right.rect.y or
            left.rect.width != right.rect.width or left.rect.height != right.rect.height or
            left.is_opaque != right.is_opaque or left.group != right.group or
            left.needs_backdrop != right.needs_backdrop) return false;
    }
    return true;
}

/// Round opaque edges inward: fractional scaling must not invent coverage of
/// a partly transparent boundary pixel. Effects use surface-local coordinates
/// mapped over destination, independently of buffer transform and crop.
fn mapOpaqueRect(rect: render.Rect, sample: render.SurfaceSample) ?render.Rect {
    const x0 = std.math.divCeil(u64, @as(u64, @intCast(rect.x)) * sample.destination.width, sample.effect_size.width) catch unreachable;
    const y0 = std.math.divCeil(u64, @as(u64, @intCast(rect.y)) * sample.destination.height, sample.effect_size.height) catch unreachable;
    const x1 = (@as(u64, @intCast(rect.x)) + rect.width) * sample.destination.width / sample.effect_size.width;
    const y1 = (@as(u64, @intCast(rect.y)) + rect.height) * sample.destination.height / sample.effect_size.height;
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intCast(@as(i64, sample.destination.x) + @as(i64, @intCast(x0))),
        .y = @intCast(@as(i64, sample.destination.y) + @as(i64, @intCast(y0))),
        .width = @intCast(x1 - x0),
        .height = @intCast(y1 - y0),
    };
}

fn testSample(rect: render.Rect, format: render.PixelFormat, alpha: u8) render.SurfaceSample {
    const pixel = [_]u8{ 0, 0, 0, 0 };
    return .{
        .sample = .{ .surface = 1, .commit_sequence = 1 },
        .presentation = .{ .slot = 0, .generation = 1 },
        .source = .{ .size = .{ .width = 1, .height = 1 }, .stride = 4, .format = format, .bytes = &pixel },
        .crop = render.SourceRect.pixels(0, 0, 1, 1),
        .destination = rect,
        .clip = rect,
        .global_alpha = alpha,
        .effect_size = .{ .width = rect.width, .height = rect.height },
    };
}

test "damage: visibility unions covers without bounding-box false occlusion" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    const target = testSample(.{ .x = 0, .y = 0, .width = 10, .height = 10 }, .xrgb8888, 255);
    var left = testSample(.{ .x = 0, .y = 0, .width = 4, .height = 10 }, .xrgb8888, 255);
    var right = testSample(.{ .x = 6, .y = 0, .width = 4, .height = 10 }, .xrgb8888, 255);
    try tracker.append(allocator, 1, 1, target);
    try tracker.append(allocator, 1, null, left);
    try tracker.append(allocator, 1, null, right);
    try std.testing.expect(try tracker.finish(allocator));
    try std.testing.expect(tracker.isVisible(1));

    left.destination.width = 5;
    left.clip = left.destination;
    right.destination.x = 5;
    right.destination.width = 5;
    right.clip = right.destination;
    tracker.begin();
    try tracker.append(allocator, 1, 1, target);
    try tracker.append(allocator, 1, null, left);
    try tracker.append(allocator, 1, null, right);
    _ = try tracker.finish(allocator);
    try std.testing.expect(!tracker.isVisible(1));
}

test "damage: visibility considers opacity independently of other outputs" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    const root = testSample(.{ .x = -3, .y = 2, .width = 11, .height = 7 }, .xrgb8888, 255);
    for ([_]u64{ 1, 2 }) |output| for ([_]u8{ 0, 254, 255 }) |alpha| {
        tracker.begin();
        var cover = root;
        cover.global_alpha = alpha;
        try tracker.append(allocator, 1, 7, root);
        try tracker.append(allocator, output, 8, cover);
        _ = try tracker.finish(allocator);
        try std.testing.expectEqual(output != 1 or alpha != 255, tracker.isVisible(7));
        try std.testing.expectEqual(alpha != 0, tracker.isVisible(8));
    };
}

test "damage: visibility aggregates children and outputs and reuses pixel-only results" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    var root = testSample(.{ .x = 0, .y = 0, .width = 9, .height = 7 }, .xrgb8888, 255);
    const child = testSample(.{ .x = 9, .y = 1, .width = 2, .height = 3 }, .xrgb8888, 255);
    for ([_]u64{ 1, 2 }) |output| {
        for (0..3) |iteration| {
            tracker.begin();
            root.sample.commit_sequence += 1;
            try tracker.append(allocator, 1, 7, root);
            try tracker.append(allocator, 1, 8, root);
            if (iteration != 2) try tracker.append(allocator, output, 7, child);
            const changed = try tracker.finish(allocator);
            try std.testing.expectEqual(iteration != 1, changed);
            try std.testing.expectEqual(iteration != 2, tracker.isVisible(7));
            try std.testing.expect(tracker.isVisible(8));
        }
    }

    tracker.begin();
    try std.testing.expect(try tracker.finish(allocator));
    try std.testing.expect(!tracker.isVisible(7));
    try std.testing.expect(!tracker.isVisible(8));
}

test "damage: visibility reuses allocations for cached and changing geometry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    var target = testSample(.{ .x = 0, .y = 0, .width = 7, .height = 3 }, .xrgb8888, 255);
    const cover = target;
    for (0..8) |iteration| {
        if (iteration == 4) {
            failing.fail_index = failing.alloc_index;
            failing.resize_fail_index = failing.resize_index;
        }
        tracker.begin();
        target.destination.x = @intCast((iteration / 2) % 2);
        target.clip = target.destination;
        target.sample.commit_sequence += 1;
        try tracker.append(allocator, 1, 1, target);
        try tracker.append(allocator, 1, 2, cover);
        try std.testing.expectEqual(iteration % 2 == 0, try tracker.finish(allocator));
        try std.testing.expectEqual(target.destination.x != 0, tracker.isVisible(1));
        try std.testing.expect(tracker.isVisible(2));
    }
    try std.testing.expect(!failing.has_induced_failure);
}

test "damage: visibility partial opaque regions preserve holes and surface ownership" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    const target = testSample(.{ .x = 2, .y = 1, .width = 6, .height = 4 }, .xrgb8888, 255);
    var cover = testSample(.{ .x = 0, .y = 0, .width = 10, .height = 8 }, .argb8888_premultiplied, 255);
    const operations = [_]render.RegionOperation{
        .{ .add = .{ .x = 2, .y = 1, .width = 3, .height = 4 } },
        .{ .add = .{ .x = 5, .y = 1, .width = 3, .height = 4 } },
        .{ .subtract = .{ .x = 6, .y = 2, .width = 1, .height = 1 } },
        .{ .add = .{ .x = 6, .y = 2, .width = 1, .height = 1 } },
    };
    for ([_]usize{ 0, 1, 2, 3, 4 }) |count| {
        tracker.begin();
        cover.opaque_region = operations[0..count];
        try tracker.append(allocator, 1, 1, target);
        try tracker.append(allocator, 1, 2, cover);
        _ = try tracker.finish(allocator);
        try std.testing.expectEqual(count != 2 and count != 4, tracker.isVisible(1));
        try std.testing.expect(tracker.isVisible(2));
    }
}

test "damage: visibility clips candidates and rounds scaled opaque edges inward" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    var cover = testSample(.{ .x = -2, .y = 3, .width = 9, .height = 6 }, .argb8888_premultiplied, 255);
    cover.effect_size = .{ .width = 6, .height = 4 };
    cover.opaque_region = &.{.{ .add = .{ .x = 1, .y = 0, .width = 3, .height = 4 } }};
    // Opaque x edges map to -0.5 and 4; only [0,4) is certainly covered.
    for ([_]i32{ -1, 0, 4 }) |x| {
        tracker.begin();
        const candidate = testSample(.{ .x = x, .y = 4, .width = 1, .height = 2 }, .xrgb8888, 255);
        try tracker.append(allocator, 1, 1, candidate);
        try tracker.append(allocator, 1, 2, cover);
        _ = try tracker.finish(allocator);
        try std.testing.expectEqual(x != 0, tracker.isVisible(1));
    }
    tracker.begin();
    var offscreen = cover;
    offscreen.clip = .{ .x = 20, .y = 0, .width = 3, .height = 2 };
    try tracker.append(allocator, 1, 1, offscreen);
    _ = try tracker.finish(allocator);
    try std.testing.expect(!tracker.isVisible(1));
}

test "damage: visibility retains blur producers even behind later opaque covers" {
    const allocator = std.testing.allocator;
    var tracker: Tracker = .{};
    defer tracker.deinit(allocator);
    const target = testSample(.{ .x = 0, .y = 0, .width = 7, .height = 9 }, .xrgb8888, 255);
    var blur = target;
    blur.global_alpha = 0;
    blur.blur_region = &.{.{ .add = .{ .x = 0, .y = 0, .width = 7, .height = 9 } }};
    try tracker.append(allocator, 1, 1, target);
    try tracker.append(allocator, 1, 2, blur);
    try tracker.append(allocator, 1, 3, target);
    _ = try tracker.finish(allocator);
    try std.testing.expect(!tracker.isVisible(1));
    try std.testing.expect(!tracker.isVisible(2));
    try std.testing.expect(tracker.isVisible(3));

    tracker.begin();
    blur.destination.x = 5;
    blur.clip = blur.destination;
    try tracker.append(allocator, 1, 1, target);
    try tracker.append(allocator, 1, 2, blur);
    try tracker.append(allocator, 1, 3, target);
    _ = try tracker.finish(allocator);
    try std.testing.expect(tracker.isVisible(1));
    try std.testing.expect(tracker.isVisible(2));
    try std.testing.expect(tracker.isVisible(3));
}
