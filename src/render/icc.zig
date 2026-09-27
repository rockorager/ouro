//! Bounded, renderer-neutral ICC profile parsing and LUT compilation.
//!
//! Little CMS is synchronous and may do substantial work. `compile` is intended
//! to be called only from a future bounded worker thread, never the render loop.

const std = @import("std");
const c = @cImport({
    @cInclude("lcms2.h");
});

pub const max_profile_bytes: usize = 32 * 1024 * 1024;
pub const edge_length: usize = 33;
pub const texel_count: usize = edge_length * edge_length * edge_length;

pub const Lut = struct {
    /// SHA-256 of the exact bytes supplied to `compile`.
    profile_hash: [32]u8,
    /// SHA-256 of the compiled transform texels. Unlike `profile_hash`, this
    /// distinguishes source and output transforms from the same ICC file.
    lut_hash: [32]u8,
    /// R varies fastest, followed by G and B. Alpha is always one.
    rgba: []const [4]f16,
    /// Linear RGB produced by source LUTs / consumed (gamma-shaped) by output
    /// LUTs. Matrix-profile outputs use their native gamut to avoid interpolating
    /// across clipped device channels at gamut boundaries.
    working_primaries: @import("color.zig").Primaries = @import("color.zig").Description.icc_working.primaries,

    pub fn deinit(self: *Lut, allocator: std.mem.Allocator) void {
        allocator.free(@constCast(self.rgba));
        self.* = undefined;
    }
};

pub const CompileError = error{
    ProfileTooLarge,
    MalformedProfile,
    UnsupportedProfileVersion,
    UnsupportedColorSpace,
    UnsupportedProfileClass,
    TransformCreationFailed,
    InvalidTransformOutput,
} || std.mem.Allocator.Error;

/// Parses an in-memory ICC v2/v4 RGB Display or ColorSpace profile and
/// compiles encoded profile RGB to extended linear-light ProPhoto with perceptual intent.
/// The returned immutable storage is owned by `allocator` and must be released
/// with `Lut.deinit`.
pub fn compile(allocator: std.mem.Allocator, profile_bytes: []const u8) CompileError!Lut {
    return compileDirection(allocator, profile_bytes, .source);
}

/// Compiles gamma-2.2-shaped working RGB to the output device encoding.
/// Shaping allocates LUT samples to shadows instead of uniformly in linear light.
/// A VCGT calibration tag, when present, is folded into the immutable LUT so
/// the KMS scanout image already contains calibrated device values.
pub fn compileOutput(allocator: std.mem.Allocator, profile_bytes: []const u8) CompileError!Lut {
    return compileDirection(allocator, profile_bytes, .output);
}

const Direction = enum { source, output };

fn compileDirection(allocator: std.mem.Allocator, profile_bytes: []const u8, direction: Direction) CompileError!Lut {
    if (profile_bytes.len > max_profile_bytes) return error.ProfileTooLarge;
    if (profile_bytes.len == 0) return error.MalformedProfile;

    const profile = c.cmsOpenProfileFromMem(profile_bytes.ptr, @intCast(profile_bytes.len)) orelse
        return error.MalformedProfile;
    defer _ = c.cmsCloseProfile(profile);

    const version = c.cmsGetProfileVersion(profile);
    if (!((version >= 2 and version < 3) or (version >= 4 and version < 5)))
        return error.UnsupportedProfileVersion;
    if (c.cmsGetColorSpace(profile) != c.cmsSigRgbData)
        return error.UnsupportedColorSpace;
    const class = c.cmsGetDeviceClass(profile);
    if (class != c.cmsSigDisplayClass and class != c.cmsSigColorSpaceClass)
        return error.UnsupportedProfileClass;

    const working = if (direction == .output) outputPrimaries(profile) else @import("color.zig").Description.icc_working.primaries;
    const linear = createLinearWorking(working) orelse return error.TransformCreationFailed;
    defer _ = c.cmsCloseProfile(linear);
    const transform = c.cmsCreateTransform(
        if (direction == .source) profile else linear,
        c.TYPE_RGB_FLT,
        if (direction == .source) linear else profile,
        c.TYPE_RGB_FLT,
        c.INTENT_PERCEPTUAL,
        c.cmsFLAGS_NOCACHE,
    ) orelse return error.TransformCreationFailed;
    defer c.cmsDeleteTransform(transform);

    const rgba = try allocator.alloc([4]f16, texel_count);
    errdefer allocator.free(rgba);
    var index: usize = 0;
    for (0..edge_length) |b| for (0..edge_length) |g| for (0..edge_length) |r| {
        var input = [3]f32{
            @as(f32, @floatFromInt(r)) / @as(f32, @floatFromInt(edge_length - 1)),
            @as(f32, @floatFromInt(g)) / @as(f32, @floatFromInt(edge_length - 1)),
            @as(f32, @floatFromInt(b)) / @as(f32, @floatFromInt(edge_length - 1)),
        };
        if (direction == .output) for (&input) |*component| {
            component.* = std.math.pow(f32, component.*, 2.2);
        };
        var output: [3]f32 = undefined;
        c.cmsDoTransform(transform, &input, &output, 1);
        if (direction == .output) applyVcgt(profile, &output);
        for (&output) |*component| {
            if (!std.math.isFinite(component.*) or @abs(component.*) > std.math.floatMax(f16))
                return error.InvalidTransformOutput;
            // Only device encoding is bounded. Source colors outside the
            // working gamut need negative / >1 components until output mapping.
            if (direction == .output) component.* = std.math.clamp(component.*, 0, 1);
        }
        rgba[index] = .{
            @floatCast(output[0]),
            @floatCast(output[1]),
            @floatCast(output[2]),
            1,
        };
        index += 1;
    };

    var profile_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(profile_bytes, &profile_hash, .{});
    var lut_hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(rgba), &lut_hash, .{});
    return .{
        .profile_hash = profile_hash,
        .lut_hash = lut_hash,
        .rgba = rgba,
        .working_primaries = working,
    };
}

fn applyVcgt(profile: c.cmsHPROFILE, value: *[3]f32) void {
    const raw = c.cmsReadTag(profile, c.cmsSigVcgtTag) orelse return;
    const curves: *const [3]?*const c.cmsToneCurve = @ptrCast(@alignCast(raw));
    inline for (0..3) |channel| {
        if (curves[channel]) |curve|
            value[channel] = c.cmsEvalToneCurveFloat(curve, value[channel]);
    }
}

fn outputPrimaries(profile: c.cmsHPROFILE) @import("color.zig").Primaries {
    const fallback = @import("color.zig").Description.icc_working.primaries;
    if (c.cmsIsMatrixShaper(profile) == 0) return fallback;
    // ICC colorants are already adapted to PCS D50. Their sum, not the physical
    // media-white tag, is the white of the matrix used by the profile transform.
    var points: [3]@import("color.zig").Chromaticity = undefined;
    var white = c.cmsCIEXYZ{ .X = 0, .Y = 0, .Z = 0 };
    for ([_]c.cmsTagSignature{ c.cmsSigRedColorantTag, c.cmsSigGreenColorantTag, c.cmsSigBlueColorantTag }, 0..) |tag, i| {
        const raw = c.cmsReadTag(profile, tag) orelse return fallback;
        const xyz: *const c.cmsCIEXYZ = @ptrCast(@alignCast(raw));
        const sum = xyz.X + xyz.Y + xyz.Z;
        if (sum <= 0 or xyz.Y <= 0) return fallback;
        points[i] = .{ .x = @floatCast(xyz.X / sum), .y = @floatCast(xyz.Y / sum) };
        white.X += xyz.X;
        white.Y += xyz.Y;
        white.Z += xyz.Z;
    }
    const sum = white.X + white.Y + white.Z;
    return .{
        .red = points[0],
        .green = points[1],
        .blue = points[2],
        .white = .{ .x = @floatCast(white.X / sum), .y = @floatCast(white.Y / sum) },
    };
}

fn createLinearWorking(working: @import("color.zig").Primaries) c.cmsHPROFILE {
    const white = c.cmsCIExyY{ .x = working.white.x, .y = working.white.y, .Y = 1.0 };
    const primaries = c.cmsCIExyYTRIPLE{
        .Red = .{ .x = working.red.x, .y = working.red.y, .Y = 1.0 },
        .Green = .{ .x = working.green.x, .y = working.green.y, .Y = 1.0 },
        .Blue = .{ .x = working.blue.x, .y = working.blue.y, .Y = 1.0 },
    };
    const curve = c.cmsBuildGamma(null, 1.0) orelse return null;
    defer c.cmsFreeToneCurve(curve);
    var curves = [3]*c.cmsToneCurve{ curve, curve, curve };
    return c.cmsCreateRGBProfile(&white, &primaries, &curves);
}

/// Creates an in-memory sRGB profile. Intended for tests of ICC consumers.
pub fn testSrgbBytes(allocator: std.mem.Allocator) ![]u8 {
    const profile = c.cmsCreate_sRGBProfile() orelse return error.ProfileCreationFailed;
    defer _ = c.cmsCloseProfile(profile);
    return testProfileBytes(allocator, profile);
}

fn testProfileBytes(allocator: std.mem.Allocator, profile: c.cmsHPROFILE) ![]u8 {
    var size: c.cmsUInt32Number = 0;
    if (c.cmsSaveProfileToMem(profile, null, &size) == 0) return error.ProfileCreationFailed;
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);
    if (c.cmsSaveProfileToMem(profile, bytes.ptr, &size) == 0) return error.ProfileCreationFailed;
    return bytes;
}

test "icc: lcms in-memory sRGB profile compiles deterministic bounded LUT" {
    const allocator = std.testing.allocator;
    const bytes = try testSrgbBytes(allocator);
    defer allocator.free(bytes);
    var first = try compile(allocator, bytes);
    defer first.deinit(allocator);
    var second = try compile(allocator, bytes);
    defer second.deinit(allocator);
    try std.testing.expectEqual(texel_count, first.rgba.len);
    try std.testing.expectEqualSlices(u8, &first.profile_hash, &second.profile_hash);
    try std.testing.expectEqualSlices(u8, &first.lut_hash, &second.lut_hash);
    try std.testing.expectEqualSlices([4]f16, first.rgba, second.rgba);
    for (first.rgba) |texel| for (texel) |component| {
        try std.testing.expect(std.math.isFinite(component));
        try std.testing.expect(component >= -0.001 and component <= 1.001);
    };
}

test "icc: output profile compiles a bounded working-to-device LUT" {
    const allocator = std.testing.allocator;
    const bytes = try testSrgbBytes(allocator);
    defer allocator.free(bytes);
    var lut = try compileOutput(allocator, bytes);
    defer lut.deinit(allocator);
    try std.testing.expectEqual(texel_count, lut.rgba.len);
    try std.testing.expectApproxEqAbs(@as(f16, 0), lut.rgba[0][0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f16, 1), lut.rgba[lut.rgba.len - 1][0], 0.01);
}

test "icc: source and output transforms have distinct cache identities" {
    const allocator = std.testing.allocator;
    const bytes = try testSrgbBytes(allocator);
    defer allocator.free(bytes);
    var source = try compile(allocator, bytes);
    defer source.deinit(allocator);
    var output = try compileOutput(allocator, bytes);
    defer output.deinit(allocator);
    try std.testing.expectEqualSlices(u8, &source.profile_hash, &output.profile_hash);
    try std.testing.expect(!std.mem.eql(u8, &source.lut_hash, &output.lut_hash));
}

test "icc: malformed input is rejected" {
    try std.testing.expectError(error.MalformedProfile, compile(std.testing.allocator, "not an ICC profile"));
}

test "icc: profile size is bounded before reading input" {
    const oversized: []const u8 = @as([*]const u8, @ptrFromInt(1))[0 .. max_profile_bytes + 1];
    try std.testing.expectError(error.ProfileTooLarge, compile(std.testing.allocator, oversized));
}

// CPU trilinear reference for testing the compiled grid, not the CMM itself.
fn sampleTestLut(lut: Lut, value: [3]f32) [3]f32 {
    var lower: [3]usize = undefined;
    var upper: [3]usize = undefined;
    var fraction: [3]f32 = undefined;
    for (value, 0..) |component, i| {
        const position = std.math.clamp(component, 0, 1) * (edge_length - 1);
        lower[i] = @intFromFloat(@floor(position));
        upper[i] = @min(lower[i] + 1, edge_length - 1);
        fraction[i] = position - @as(f32, @floatFromInt(lower[i]));
    }
    var result: [3]f32 = @splat(0);
    for (0..2) |b| for (0..2) |g| for (0..2) |r| {
        const index = (if (r == 0) lower[0] else upper[0]) + edge_length *
            ((if (g == 0) lower[1] else upper[1]) + edge_length * (if (b == 0) lower[2] else upper[2]));
        const weight = (if (r == 0) 1 - fraction[0] else fraction[0]) *
            (if (g == 0) 1 - fraction[1] else fraction[1]) * (if (b == 0) 1 - fraction[2] else fraction[2]);
        for (0..3) |channel| result[channel] += @as(f32, lut.rgba[index][channel]) * weight;
    };
    return result;
}

test "icc: shaped output LUT preserves shadows and P3 colors outside sRGB" {
    const allocator = std.testing.allocator;
    const white = c.cmsCIExyY{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const p3 = c.cmsCIExyYTRIPLE{
        .Red = .{ .x = 0.68, .y = 0.32, .Y = 1 },
        .Green = .{ .x = 0.265, .y = 0.69, .Y = 1 },
        .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1 },
    };
    const curve = c.cmsBuildGamma(null, 2.2).?;
    defer c.cmsFreeToneCurve(curve);
    var curves = [3]*c.cmsToneCurve{ curve, curve, curve };
    const profile = c.cmsCreateRGBProfile(&white, &p3, &curves).?;
    defer _ = c.cmsCloseProfile(profile);
    const bytes = try testProfileBytes(allocator, profile);
    defer allocator.free(bytes);
    var source = try compile(allocator, bytes);
    defer source.deinit(allocator);
    var output = try compileOutput(allocator, bytes);
    defer output.deinit(allocator);
    const linear_working = createLinearWorking(output.working_primaries).?;
    defer _ = c.cmsCloseProfile(linear_working);
    const exact = c.cmsCreateTransform(profile, c.TYPE_RGB_FLT, linear_working, c.TYPE_RGB_FLT, c.INTENT_PERCEPTUAL, c.cmsFLAGS_NOCACHE).?;
    defer c.cmsDeleteTransform(exact);
    var source_description = @import("color.zig").Description.srgb;
    source_description.lut = &source;
    var output_description = @import("color.zig").Description.srgb;
    output_description.lut = &output;
    const conversion = try @import("color.zig").compile(source_description, output_description);
    const samples = [_][3]f32{
        .{ 1, 0, 0 },             .{ 0, 1, 0 },          .{ 0, 0, 1 },
        .{ 0.9, 0.25, 0.1 },      .{ 0.15, 0.85, 0.2 },  .{ 0.2, 0.1, 0.9 },
        .{ 0.015, 0.015, 0.015 }, .{ 0.08, 0.08, 0.08 }, .{ 0.5, 0.5, 0.5 },
    };
    for (samples) |input| {
        var linear: [3]f32 = undefined;
        c.cmsDoTransform(exact, &input, &linear, 1);
        const decoded = sampleTestLut(source, input);
        var composed: [3]f32 = @splat(0);
        for (0..3) |row| for (0..3) |column| {
            composed[row] += conversion.matrix[row][column] * decoded[column];
        };
        for (composed, linear) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.001);
        var shaped: [3]f32 = undefined;
        for (composed, 0..) |component, i| shaped[i] = std.math.pow(f32, @max(0, component), 1.0 / 2.2);
        const actual = sampleTestLut(output, shaped);
        for (actual, input) |got, want| try std.testing.expectApproxEqAbs(want, got, 0.015);
    }
    const srgb_bytes = try testSrgbBytes(allocator);
    defer allocator.free(srgb_bytes);
    var srgb_output = try compileOutput(allocator, srgb_bytes);
    defer srgb_output.deinit(allocator);
    for (0..256) |i| {
        const encoded = @as(f32, @floatFromInt(i)) / 255;
        const linear = if (encoded <= 0.04045) encoded / 12.92 else std.math.pow(f32, (encoded + 0.055) / 1.055, 2.4);
        const actual = sampleTestLut(srgb_output, @splat(std.math.pow(f32, linear, 1.0 / 2.2)));
        for (actual) |channel| try std.testing.expectApproxEqAbs(encoded, channel, 1.5 / 255.0);
    }
}

test "icc: source LUT retains finite negative and above-one working values" {
    const allocator = std.testing.allocator;
    const white = c.cmsCIExyY{ .x = 0.3127, .y = 0.3290, .Y = 1 };
    const primaries = c.cmsCIExyYTRIPLE{
        .Red = .{ .x = 0.74, .y = 0.26, .Y = 1 },
        .Green = .{ .x = 0.01, .y = 0.99, .Y = 1 },
        .Blue = .{ .x = 0.03, .y = 0.01, .Y = 1 },
    };
    const curve = c.cmsBuildGamma(null, 1).?;
    defer c.cmsFreeToneCurve(curve);
    var curves = [3]*c.cmsToneCurve{ curve, curve, curve };
    const profile = c.cmsCreateRGBProfile(&white, &primaries, &curves).?;
    defer _ = c.cmsCloseProfile(profile);
    const bytes = try testProfileBytes(allocator, profile);
    defer allocator.free(bytes);
    var lut = try compile(allocator, bytes);
    defer lut.deinit(allocator);
    const green = lut.rgba[edge_length * (edge_length - 1)];
    try std.testing.expect(green[0] < -0.01);
    const magenta = lut.rgba[(edge_length - 1) * (1 + edge_length * edge_length)];
    try std.testing.expect(magenta[0] > 1.01);
    const linear = createLinearWorking(lut.working_primaries).?;
    defer _ = c.cmsCloseProfile(linear);
    const exact = c.cmsCreateTransform(profile, c.TYPE_RGB_FLT, linear, c.TYPE_RGB_FLT, c.INTENT_PERCEPTUAL, c.cmsFLAGS_NOCACHE).?;
    defer c.cmsDeleteTransform(exact);
    for ([_][3]f32{ .{ 0, 1, 0 }, .{ 1, 0, 1 } }, [_][4]f16{ green, magenta }) |input, actual| {
        var expected: [3]f32 = undefined;
        c.cmsDoTransform(exact, &input, &expected, 1);
        for (expected, actual[0..3]) |want, got| try std.testing.expectApproxEqAbs(want, @as(f32, got), 0.001);
    }
}
