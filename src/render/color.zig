//! Renderer-neutral color descriptions and transform compilation.
//!
//! Descriptions are immutable values. Protocol resources, ICC caches, and
//! output policy own their lifetimes; a surface commit snapshots only this
//! compact renderer contract.

const std = @import("std");
const icc = @import("icc.zig");

pub const Chromaticity = struct {
    x: f32,
    y: f32,
};

pub const Primaries = struct {
    red: Chromaticity,
    green: Chromaticity,
    blue: Chromaticity,
    white: Chromaticity,
};

pub const TransferFunction = enum(u8) {
    srgb,
    linear,
    gamma22,
    gamma28,
    st2084_pq,
    hlg,
};

pub const Description = struct {
    primaries: Primaries,
    transfer: TransferFunction,
    /// Reference white in cd/m². SDR sRGB defaults to 80 cd/m² as specified
    /// by color-management-v1.
    reference_luminance: f32 = 80,
    min_luminance: f32 = 0.2,
    max_luminance: f32 = 80,
    target_max_cll: ?u32 = null,
    target_max_fall: ?u32 = null,
    /// Optional compositor-owned ICC transform. The immutable LUT and its
    /// storage must remain alive until renderer teardown.
    lut: ?*const icc.Lut = null,

    pub const srgb: Description = .{
        .primaries = .{
            .red = .{ .x = 0.64, .y = 0.33 },
            .green = .{ .x = 0.30, .y = 0.60 },
            .blue = .{ .x = 0.15, .y = 0.06 },
            .white = .{ .x = 0.3127, .y = 0.3290 },
        },
        .transfer = .srgb,
    };

    pub fn validate(value: Description) !void {
        inline for (.{
            value.primaries.red,
            value.primaries.green,
            value.primaries.blue,
            value.primaries.white,
        }) |point| {
            if (!std.math.isFinite(point.x) or !std.math.isFinite(point.y) or
                point.x <= 0 or point.y <= 0 or point.x + point.y > 1)
                return error.InvalidColorDescription;
        }
        if (!std.math.isFinite(value.reference_luminance) or
            !std.math.isFinite(value.min_luminance) or
            !std.math.isFinite(value.max_luminance) or
            value.reference_luminance <= 0 or value.min_luminance < 0 or
            value.max_luminance < value.reference_luminance or
            value.min_luminance >= value.max_luminance)
            return error.InvalidColorDescription;
        if (value.target_max_cll != null and value.target_max_fall != null and
            value.target_max_fall.? > value.target_max_cll.?)
            return error.InvalidColorDescription;
        _ = try rgbToXyz(value.primaries);
    }
};

pub const AlphaMode = enum(u8) {
    premultiplied_electrical,
    premultiplied_optical,
    straight,
};

pub const Representation = struct {
    alpha_mode: AlphaMode = .premultiplied_electrical,
};

pub const Matrix3 = [3][3]f32;

pub const Transform = struct {
    matrix: Matrix3,
    source_transfer: TransferFunction,
    output_transfer: TransferFunction,
    luminance_scale: f32,
};

pub fn compile(source: Description, output: Description) !Transform {
    try source.validate();
    try output.validate();
    // ICC LUTs produce linear-light sRGB. Keep the source luminance metadata,
    // but start the analytical output transform in that working space.
    var working = source;
    if (source.lut != null) {
        working.primaries = Description.srgb.primaries;
        working.transfer = .linear;
        working.lut = null;
    }
    const source_xyz = try rgbToXyz(working.primaries);
    // An output ICC LUT consumes linear-light sRGB. Compositing therefore
    // stays in that working space and the final LUT performs device encoding.
    const destination_primaries = if (output.lut != null)
        Description.srgb.primaries
    else
        output.primaries;
    const source_to_output_reference = if (output.lut != null)
        Description.srgb.reference_luminance
    else
        output.reference_luminance;
    const output_xyz = try rgbToXyz(destination_primaries);
    const output_inverse = inverse(output_xyz) orelse return error.InvalidColorDescription;
    const adaptation = try chromaticAdaptation(working.primaries.white, destination_primaries.white);
    return .{
        .matrix = multiply(output_inverse, multiply(adaptation, source_xyz)),
        .source_transfer = working.transfer,
        .output_transfer = output.transfer,
        .luminance_scale = if (working.transfer == .st2084_pq)
            10_000 / source_to_output_reference
        else
            source.reference_luminance / source_to_output_reference,
    };
}

fn rgbToXyz(primaries: Primaries) !Matrix3 {
    const red = try xyz(primaries.red);
    const green = try xyz(primaries.green);
    const blue = try xyz(primaries.blue);
    const white = try xyz(primaries.white);
    const basis: Matrix3 = .{
        .{ red[0], green[0], blue[0] },
        .{ red[1], green[1], blue[1] },
        .{ red[2], green[2], blue[2] },
    };
    const scale = multiplyVector(inverse(basis) orelse return error.InvalidColorDescription, white);
    return .{
        .{ basis[0][0] * scale[0], basis[0][1] * scale[1], basis[0][2] * scale[2] },
        .{ basis[1][0] * scale[0], basis[1][1] * scale[1], basis[1][2] * scale[2] },
        .{ basis[2][0] * scale[0], basis[2][1] * scale[1], basis[2][2] * scale[2] },
    };
}

fn xyz(point: Chromaticity) ![3]f32 {
    if (point.y <= 0) return error.InvalidColorDescription;
    return .{ point.x / point.y, 1, (1 - point.x - point.y) / point.y };
}

/// Bradford adaptation preserves the intended source white while allowing
/// output calibration to use a distinct media white.
fn chromaticAdaptation(source: Chromaticity, destination: Chromaticity) !Matrix3 {
    const bradford: Matrix3 = .{
        .{ 0.8951, 0.2664, -0.1614 },
        .{ -0.7502, 1.7135, 0.0367 },
        .{ 0.0389, -0.0685, 1.0296 },
    };
    const inverse_bradford = inverse(bradford).?;
    const source_cone = multiplyVector(bradford, try xyz(source));
    const destination_cone = multiplyVector(bradford, try xyz(destination));
    var scale: Matrix3 = .{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    inline for (0..3) |index| {
        if (@abs(source_cone[index]) < 0.000001) return error.InvalidColorDescription;
        scale[index][index] = destination_cone[index] / source_cone[index];
    }
    return multiply(inverse_bradford, multiply(scale, bradford));
}

fn multiply(a: Matrix3, b: Matrix3) Matrix3 {
    var result: Matrix3 = undefined;
    inline for (0..3) |row| inline for (0..3) |column| {
        result[row][column] = 0;
        inline for (0..3) |index| result[row][column] += a[row][index] * b[index][column];
    };
    return result;
}

fn multiplyVector(matrix: Matrix3, vector: [3]f32) [3]f32 {
    var result: [3]f32 = undefined;
    inline for (0..3) |row|
        result[row] = matrix[row][0] * vector[0] + matrix[row][1] * vector[1] +
            matrix[row][2] * vector[2];
    return result;
}

fn inverse(value: Matrix3) ?Matrix3 {
    const determinant =
        value[0][0] * (value[1][1] * value[2][2] - value[1][2] * value[2][1]) -
        value[0][1] * (value[1][0] * value[2][2] - value[1][2] * value[2][0]) +
        value[0][2] * (value[1][0] * value[2][1] - value[1][1] * value[2][0]);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.000001) return null;
    const reciprocal = 1 / determinant;
    return .{
        .{
            (value[1][1] * value[2][2] - value[1][2] * value[2][1]) * reciprocal,
            (value[0][2] * value[2][1] - value[0][1] * value[2][2]) * reciprocal,
            (value[0][1] * value[1][2] - value[0][2] * value[1][1]) * reciprocal,
        },
        .{
            (value[1][2] * value[2][0] - value[1][0] * value[2][2]) * reciprocal,
            (value[0][0] * value[2][2] - value[0][2] * value[2][0]) * reciprocal,
            (value[0][2] * value[1][0] - value[0][0] * value[1][2]) * reciprocal,
        },
        .{
            (value[1][0] * value[2][1] - value[1][1] * value[2][0]) * reciprocal,
            (value[0][1] * value[2][0] - value[0][0] * value[2][1]) * reciprocal,
            (value[0][0] * value[1][1] - value[0][1] * value[1][0]) * reciprocal,
        },
    };
}

test "color: sRGB transform is identity" {
    const transform = try compile(.srgb, .srgb);
    inline for (0..3) |row| inline for (0..3) |column|
        try std.testing.expectApproxEqAbs(
            @as(f32, if (row == column) 1 else 0),
            transform.matrix[row][column],
            0.0001,
        );
}

test "color: rejects degenerate descriptions" {
    var malformed = Description.srgb;
    malformed.primaries.red = malformed.primaries.green;
    try std.testing.expectError(error.InvalidColorDescription, compile(malformed, .srgb));
}

test "color: ICC selects linear sRGB working-space transform" {
    var texel = [_][4]f16{.{ 0, 0, 0, 1 }};
    var lut: icc.Lut = .{
        .profile_hash = .{0} ** 32,
        .lut_hash = .{1} ** 32,
        .rgba = &texel,
    };
    var source = Description.srgb;
    source.transfer = .gamma28;
    source.lut = &lut;
    const transform = try compile(source, .srgb);
    try std.testing.expectEqual(.linear, transform.source_transfer);
    inline for (0..3) |row| inline for (0..3) |column|
        try std.testing.expectApproxEqAbs(
            @as(f32, if (row == column) 1 else 0),
            transform.matrix[row][column],
            0.0001,
        );
}
