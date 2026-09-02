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
/// compiles encoded profile RGB to linear-light sRGB with perceptual intent.
/// The returned immutable storage is owned by `allocator` and must be released
/// with `Lut.deinit`.
pub fn compile(allocator: std.mem.Allocator, profile_bytes: []const u8) CompileError!Lut {
    return compileDirection(allocator, profile_bytes, .source);
}

/// Compiles linear-light sRGB working values to the output device encoding.
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

    const linear = createLinearSrgb() orelse return error.TransformCreationFailed;
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
        var output: [3]f32 = undefined;
        c.cmsDoTransform(transform, &input, &output, 1);
        if (direction == .output) applyVcgt(profile, &output);
        for (output) |component|
            if (!std.math.isFinite(component)) return error.InvalidTransformOutput;
        rgba[index] = .{
            @floatCast(std.math.clamp(output[0], 0, 1)),
            @floatCast(std.math.clamp(output[1], 0, 1)),
            @floatCast(std.math.clamp(output[2], 0, 1)),
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

fn createLinearSrgb() c.cmsHPROFILE {
    const white = c.cmsCIExyY{ .x = 0.3127, .y = 0.3290, .Y = 1.0 };
    const primaries = c.cmsCIExyYTRIPLE{
        .Red = .{ .x = 0.64, .y = 0.33, .Y = 1.0 },
        .Green = .{ .x = 0.30, .y = 0.60, .Y = 1.0 },
        .Blue = .{ .x = 0.15, .y = 0.06, .Y = 1.0 },
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
        try std.testing.expect(component >= 0 and component <= 1);
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
