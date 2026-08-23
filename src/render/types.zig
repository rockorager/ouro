//! Renderer-neutral M2 surface render contract.
//!
//! Pixels are 8-bit premultiplied ARGB or opaque XRGB. On little-endian hosts
//! each pixel is stored in byte order B, G, R, A/X. Source coordinates are
//! signed 16.16 fixed point, allowing Wayland viewport crops to be represented
//! without choosing a renderer API. Samples are ordered back-to-front.

const std = @import("std");

pub const fixed_one: i32 = 1 << 16;

pub const PixelFormat = enum {
    argb8888_premultiplied,
    xrgb8888,
};

pub const Color = struct {
    /// Straight-alpha channels. Renderers premultiply these for storage.
    a: u8 = 255,
    r: u8,
    g: u8,
    b: u8,
};

pub const Size = struct { width: u32, height: u32 };

pub const Rect = struct {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
};

/// Plan geometry may conservatively extend beyond i32 output coordinates after
/// an output transform. Renderers clip this to `DamagePlan.output` before
/// converting to an API-specific rectangle.
pub const PlanRect = struct {
    x: i64,
    y: i64,
    width: u32,
    height: u32,
};

pub const SourceRect = struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,

    pub fn pixels(x: i32, y: i32, width: i32, height: i32) SourceRect {
        return .{
            .x = x * fixed_one,
            .y = y * fixed_one,
            .width = width * fixed_one,
            .height = height * fixed_one,
        };
    }
};

/// wl_output transform semantics: rotations are counter-clockwise and flips
/// mirror around the vertical axis before the named rotation.
pub const Transform = enum(u3) {
    normal,
    @"90",
    @"180",
    @"270",
    flipped,
    flipped_90,
    flipped_180,
    flipped_270,
};

/// Identifies the exact applied surface content sampled by one list entry.
pub const SampleIdentity = struct {
    surface: u64,
    commit_sequence: u64,
};

/// Identifies the imported presentation whose bytes back the sample.
pub const PresentationIdentity = struct {
    slot: u32,
    generation: u32,
};

pub const Source = struct {
    size: Size,
    stride: u32,
    format: PixelFormat,
    bytes: []const u8,
};

pub const SurfaceSample = struct {
    sample: SampleIdentity,
    presentation: PresentationIdentity,
    source: Source,
    crop: SourceRect,
    destination: Rect,
    clip: Rect,
    transform: Transform = .normal,
    global_alpha: u8 = 255,
};

/// Damage is intentionally absent in M2. A renderer clears the complete output
/// and composites every sample on every accepted render.
pub const List = struct {
    output: Size,
    output_format: PixelFormat,
    clear: Color,
    samples: []const SurfaceSample,
};

/// One immutable R12 sample selected by an R13 plan. Geometry is in physical
/// output coordinates after the output transform. `source_index` indexes the
/// exact validated `List.samples` entry identified by both generational IDs.
pub const PlannedSample = struct {
    source_index: u32,
    sample: SampleIdentity,
    presentation: PresentationIdentity,
    crop: SourceRect,
    destination: PlanRect,
    clip: PlanRect,
    transform: Transform,
    global_alpha: u8,
};

/// Renderer-neutral bounded R13 result. Damage classes remain separate so
/// output-buffer repair can be rendered without becoming future scene damage.
/// All slices borrow the planner until its next successful prepare.
pub const DamagePlan = struct {
    output: Size,
    samples: []const PlannedSample,
    client_damage: []const Rect,
    scene_damage: []const Rect,
    repair_damage: []const Rect,
    render_damage: []const Rect,
    client_full: bool,
    scene_full: bool,
    repair_full: bool,
    render_full: bool,

    pub fn fullOutput(plan: DamagePlan) bool {
        return plan.render_full;
    }
};

pub const ValidationError = error{
    InvalidOutput,
    InvalidIdentity,
    InvalidSource,
    InvalidCrop,
    InvalidDestination,
    InvalidClip,
};

pub fn validateList(list: List) ValidationError!void {
    try validateOutput(list.output);
    for (list.samples) |sample| _ = try validateSample(sample);
}

pub fn validateOutput(output: Size) ValidationError!void {
    if (output.width == 0 or output.height == 0 or
        output.width > std.math.maxInt(i32) or output.height > std.math.maxInt(i32))
        return error.InvalidOutput;
}

pub fn validateSample(sample: SurfaceSample) ValidationError!usize {
    if (sample.sample.surface == 0 or sample.sample.commit_sequence == 0 or
        sample.presentation.generation == 0)
        return error.InvalidIdentity;
    if (sample.source.size.width == 0 or sample.source.size.height == 0 or
        sample.source.size.width > std.math.maxInt(i32) or
        sample.source.size.height > std.math.maxInt(i32))
        return error.InvalidSource;
    const row_bytes = std.math.mul(u32, sample.source.size.width, 4) catch
        return error.InvalidSource;
    if (sample.source.stride < row_bytes or sample.source.stride > std.math.maxInt(i32))
        return error.InvalidSource;
    const length = std.math.mul(usize, sample.source.stride, sample.source.size.height) catch
        return error.InvalidSource;
    if (sample.source.bytes.len < length) return error.InvalidSource;

    if (sample.crop.x < 0 or sample.crop.y < 0 or
        sample.crop.width <= 0 or sample.crop.height <= 0)
        return error.InvalidCrop;
    const right = @as(i64, sample.crop.x) + sample.crop.width;
    const bottom = @as(i64, sample.crop.y) + sample.crop.height;
    if (right > @as(i64, sample.source.size.width) * fixed_one or
        bottom > @as(i64, sample.source.size.height) * fixed_one)
        return error.InvalidCrop;
    if (!validRect(sample.destination)) return error.InvalidDestination;
    if (!validRect(sample.clip)) return error.InvalidClip;
    return length;
}

fn validRect(rect: Rect) bool {
    if (rect.width == 0 or rect.height == 0) return false;
    _ = std.math.add(i32, rect.x, std.math.cast(i32, rect.width) orelse return false) catch
        return false;
    _ = std.math.add(i32, rect.y, std.math.cast(i32, rect.height) orelse return false) catch
        return false;
    return true;
}
