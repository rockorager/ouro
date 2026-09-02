//! Renderer-neutral compositor-owned themed cursor state.
//!
//! Images and their pixel bytes are borrowed from `cursor_theme.Cache`; the
//! caller must keep that cache alive while an image is installed. The maximum
//! generational values below are reserved for this synthetic surface and must
//! never be allocated by normal surface or presentation queues.

const std = @import("std");
const cursor_theme = @import("../cursor_theme.zig");
const damage = @import("damage.zig");
const geometry = @import("geometry.zig");
const render = @import("../render/types.zig");

pub const synthetic_surface_index = std.math.maxInt(u32);
pub const synthetic_surface_generation = std.math.maxInt(u32);
pub const synthetic_surface = std.math.maxInt(u64);
pub const synthetic_presentation_slot = std.math.maxInt(u32);
pub const synthetic_presentation_generation = std.math.maxInt(u32);
pub const synthetic_presentation: render.PresentationIdentity = .{
    .slot = synthetic_presentation_slot,
    .generation = synthetic_presentation_generation,
};

/// The exact surface key physical should put in its `SampleBinding`.
pub fn syntheticSurfaceId(comptime SurfaceId: type) SurfaceId {
    return .{ .index = synthetic_surface_index, .generation = synthetic_surface_generation };
}

pub const Cursor = struct {
    pub const Error = render.ValidationError || error{InvalidGeometry};

    image: ?cursor_theme.Image = null,
    position: geometry.Point = .{ .x = 0, .y = 0 },
    pointer_available: bool = false,
    generation: u64 = 1,

    /// Installs borrowed pixels or hides the cursor. Returns whether state
    /// changed. Shape changes advance the nonzero wrapping commit identity.
    pub fn setImage(self: *Cursor, image: ?cursor_theme.Image) bool {
        if (sameImage(self.image, image)) return false;
        self.image = image;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        return true;
    }

    pub fn setPointerAvailable(self: *Cursor, available: bool) void {
        self.pointer_available = available;
    }

    pub fn move(self: *Cursor, position: geometry.Point) void {
        self.position = position;
    }

    pub fn sampleIdentity(self: Cursor) render.SampleIdentity {
        return .{ .surface = synthetic_surface, .commit_sequence = self.generation };
    }

    /// Forms the exact structural binding used by physical without importing
    /// that output-owned type at this scene boundary.
    pub fn sampleBinding(self: Cursor, comptime Binding: type) Binding {
        const SurfaceId = @TypeOf(@as(Binding, undefined).surface);
        return .{
            .surface = syntheticSurfaceId(SurfaceId),
            .sample = self.sampleIdentity(),
            .presentation = synthetic_presentation,
        };
    }

    pub fn sample(self: Cursor, output: geometry.Rect) Error!?render.SurfaceSample {
        if (!self.pointer_available) return null;
        const image = self.image orelse return null;
        try output.validate();
        if (image.width == 0 or image.height == 0 or
            image.width > std.math.maxInt(i32) / render.fixed_one or
            image.height > std.math.maxInt(i32) / render.fixed_one or
            image.x_hotspot >= image.width or image.y_hotspot >= image.height)
            return error.InvalidSource;
        const stride = std.math.mul(u32, image.width, 4) catch return error.InvalidSource;
        if (stride > std.math.maxInt(i32)) return error.InvalidSource;
        const byte_len = std.math.mul(usize, stride, image.height) catch return error.InvalidSource;
        if (image.pixels.len != byte_len) return error.InvalidSource;
        const x = std.math.sub(i32, self.position.x, @as(i32, @intCast(image.x_hotspot))) catch
            return error.InvalidDestination;
        const y = std.math.sub(i32, self.position.y, @as(i32, @intCast(image.y_hotspot))) catch
            return error.InvalidDestination;
        const right = @min(@as(i64, output.x) + output.width, @as(i64, x) + image.width);
        const bottom = @min(@as(i64, output.y) + output.height, @as(i64, y) + image.height);
        const left = @max(@as(i64, output.x), x);
        const top = @max(@as(i64, output.y), y);
        if (right <= left or bottom <= top) return null;
        var upload_damage: render.UploadDamage = .{};
        upload_damage.rects[0] = .{
            .min_x = 0,
            .min_y = 0,
            .max_x = image.width,
            .max_y = image.height,
        };
        upload_damage.count = 1;

        const result: render.SurfaceSample = .{
            .sample = self.sampleIdentity(),
            .presentation = synthetic_presentation,
            .source = .{
                .size = .{ .width = image.width, .height = image.height },
                .stride = stride,
                .format = .argb8888_premultiplied,
                .bytes = image.pixels,
            },
            // Cursor images use adjacent synthetic commit identities. Mark
            // the whole replacement dirty so a same-sized shape refreshes
            // the renderer's persistent texture rather than only its scene
            // geometry.
            .upload_damage = upload_damage,
            .crop = render.SourceRect.pixels(0, 0, @intCast(image.width), @intCast(image.height)),
            .destination = .{ .x = x, .y = y, .width = image.width, .height = image.height },
            .clip = .{
                .x = @intCast(left),
                .y = @intCast(top),
                .width = @intCast(right - left),
                .height = @intCast(bottom - top),
            },
        };
        _ = try render.validateSample(result);
        return result;
    }

    /// Captures output-dependent geometry for scene damage before/after a
    /// cursor mutation. A caller captures `previous`, mutates, then calls
    /// `damageChange`; no client-content damage is attached.
    pub fn damageState(self: Cursor, output: geometry.Rect) Error!?damage.SurfaceState {
        const value = try self.sample(output) orelse return null;
        return damage.SurfaceState.fromSample(value, value.source.size);
    }

    pub fn damageChange(
        self: Cursor,
        previous: ?damage.SurfaceState,
        output: geometry.Rect,
    ) Error!damage.Change {
        return .{ .previous = previous, .current = try self.damageState(output) };
    }
};

fn sameImage(a: ?cursor_theme.Image, b: ?cursor_theme.Image) bool {
    if (a == null or b == null) return a == null and b == null;
    const x = a.?;
    const y = b.?;
    return x.width == y.width and x.height == y.height and
        x.x_hotspot == y.x_hotspot and x.y_hotspot == y.y_hotspot and
        x.delay == y.delay and x.pixels.ptr == y.pixels.ptr and x.pixels.len == y.pixels.len;
}

const pixels_a = [_]u8{0xff} ** (4 * 3 * 4);
const pixels_b = [_]u8{0x80} ** (4 * 3 * 4);

fn testImage(pixels: []const u8) cursor_theme.Image {
    return .{ .width = 4, .height = 3, .x_hotspot = 2, .y_hotspot = 1, .delay = 0, .pixels = pixels };
}

test "theme cursor: reserved identities and exact synthetic binding fields" {
    const Id = packed struct { index: u32, generation: u32 };
    const Binding = struct {
        surface: Id,
        sample: render.SampleIdentity,
        presentation: render.PresentationIdentity,
    };
    const cursor = Cursor{};
    const binding = cursor.sampleBinding(Binding);
    try std.testing.expectEqual(std.math.maxInt(u64), synthetic_surface);
    try std.testing.expectEqual(Id{ .index = std.math.maxInt(u32), .generation = std.math.maxInt(u32) }, syntheticSurfaceId(Id));
    try std.testing.expectEqual(render.PresentationIdentity{ .slot = std.math.maxInt(u32), .generation = std.math.maxInt(u32) }, synthetic_presentation);
    try std.testing.expectEqual(syntheticSurfaceId(Id), binding.surface);
    try std.testing.expectEqual(cursor.sampleIdentity(), binding.sample);
    try std.testing.expectEqual(synthetic_presentation, binding.presentation);
}

test "theme cursor: hotspot placement clipping and movement preserve identity" {
    var cursor = Cursor{};
    cursor.setPointerAvailable(true);
    _ = cursor.setImage(testImage(&pixels_a));
    cursor.move(.{ .x = 1, .y = 1 });
    const first = (try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })).?;
    try std.testing.expectEqual(render.Rect{ .x = -1, .y = 0, .width = 4, .height = 3 }, first.destination);
    try std.testing.expectEqual(render.Rect{ .x = 0, .y = 0, .width = 3, .height = 3 }, first.clip);
    try std.testing.expectEqual(@as(u8, 1), first.upload_damage.count);
    try std.testing.expectEqual(render.UploadRect{
        .min_x = 0,
        .min_y = 0,
        .max_x = 4,
        .max_y = 3,
    }, first.upload_damage.rects[0]);
    cursor.move(.{ .x = 8, .y = 8 });
    const moved = (try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })).?;
    try std.testing.expectEqual(first.sample, moved.sample);
    try std.testing.expectEqual(first.presentation, moved.presentation);
    try std.testing.expect(!std.meta.eql(first.destination, moved.destination));
}

test "theme cursor: image changes identity while identical image is a no-op" {
    var cursor = Cursor{ .pointer_available = true };
    try std.testing.expect(cursor.setImage(testImage(&pixels_a)));
    const first = (try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })).?.sample;
    try std.testing.expect(!cursor.setImage(testImage(&pixels_a)));
    try std.testing.expectEqual(first, (try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })).?.sample);
    try std.testing.expect(cursor.setImage(testImage(&pixels_b)));
    try std.testing.expect(first.commit_sequence != (try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })).?.sample.commit_sequence);
}

test "theme cursor: clear availability and clipping hide without stale image" {
    var cursor = Cursor{ .pointer_available = true };
    _ = cursor.setImage(testImage(&pixels_a));
    cursor.move(.{ .x = 20, .y = 20 });
    try std.testing.expect((try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })) == null);
    cursor.move(.{ .x = 2, .y = 1 });
    cursor.setPointerAvailable(false);
    try std.testing.expect((try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })) == null);
    cursor.setPointerAvailable(true);
    try std.testing.expect(cursor.setImage(null));
    try std.testing.expect(cursor.image == null);
    try std.testing.expect((try cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 })) == null);
}

test "theme cursor: invalid image and pointer arithmetic are rejected" {
    var cursor = Cursor{ .pointer_available = true };
    _ = cursor.setImage(.{ .width = 1, .height = 1, .x_hotspot = 0, .y_hotspot = 0, .delay = 0, .pixels = &.{ 0, 0, 0 } });
    try std.testing.expectError(error.InvalidSource, cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 }));
    _ = cursor.setImage(.{ .width = std.math.maxInt(u32), .height = 1, .x_hotspot = 0, .y_hotspot = 0, .delay = 0, .pixels = &.{} });
    try std.testing.expectError(error.InvalidSource, cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 }));
    _ = cursor.setImage(testImage(&pixels_a));
    cursor.position.x = std.math.minInt(i32);
    try std.testing.expectError(error.InvalidDestination, cursor.sample(.{ .x = 0, .y = 0, .width = 10, .height = 10 }));
    try std.testing.expectError(error.InvalidGeometry, cursor.sample(.{ .x = 0, .y = 0, .width = 0, .height = 10 }));
}

test "theme cursor: damage transition contains old and new geometry" {
    var cursor = Cursor{ .pointer_available = true };
    _ = cursor.setImage(testImage(&pixels_a));
    cursor.move(.{ .x = 4, .y = 4 });
    const old = (try cursor.damageState(.{ .x = 0, .y = 0, .width = 20, .height = 20 })).?;
    cursor.move(.{ .x = 9, .y = 7 });
    const change = try cursor.damageChange(old, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try std.testing.expectEqual(render.Rect{ .x = 2, .y = 3, .width = 4, .height = 3 }, change.previous.?.destination);
    try std.testing.expectEqual(render.Rect{ .x = 7, .y = 6, .width = 4, .height = 3 }, change.current.?.destination);
    try std.testing.expect(change.surface_damage == null and change.buffer_damage == null);
    _ = cursor.setImage(null);
    const hidden = try cursor.damageChange(change.current, .{ .x = 0, .y = 0, .width = 20, .height = 20 });
    try std.testing.expect(hidden.previous != null and hidden.current == null);
}
