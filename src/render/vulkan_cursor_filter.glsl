// Adaptive surface resampling, shared by image and storage-buffer compositors.
// Filter bits: 1 = Catmull-Rom, 2 = bilinear, 3 = bounded area.
// Aligned 1:1 surfaces bypass this code. Coordinates address pixel centers.

vec4 cursor_texel(Sample item, uint index, ivec2 coordinate) {
    vec4 value = raw_pixel(item, index, coordinate);
    if (shm_opaque(item.attributes.x)) value.a = 1.0;
    // Optical premultiplication must be decoded before interpolation. Other
    // surfaces reconstruct encoded premultiplied values, as authored by clients
    // and Xcursor themes, then decode once for linear-light compositing.
    if (item.affine_tail.z == 1) return decode_pixel(item, value);
    if (item.affine_tail.z == 2) value.rgb *= value.a;
    return value;
}

float cubic_weight(float distance) {
    float x = abs(distance);
    if (x <= 1.0) return 1.0 + x * x * (1.5 * x - 2.5);
    if (x < 2.0) return 2.0 + x * (-4.0 + x * (2.5 - 0.5 * x));
    return 0.0;
}

vec4 filtered_pixel(Sample item, uint index, ivec2 fixed_coordinate) {
    vec2 center = vec2(fixed_coordinate) / 65536.0;
    vec2 position = center - 0.5;
    ivec2 lower = ivec2(floor(position));
    vec2 fraction = fract(position);
    vec2 crop_start = vec2(item.crop.xy) / 65536.0;
    vec2 crop_end = crop_start + vec2(item.crop.zw) / 65536.0;
    ivec2 first = max(ivec2(floor(crop_start)), ivec2(0));
    ivec2 last = min(ivec2(ceil(crop_end)) - 1, ivec2(item.source.yz) - 1);
    uint mode = (item.attributes.y >> 28u) & 3u;
    vec4 value = vec4(0.0);
    if (mode == 3u) {
        vec2 footprint = vec2(
            abs(float(item.affine.x)) + abs(float(item.affine.y)),
            abs(float(item.affine.w)) + abs(float(item.affine_tail.x))
        ) / 65536.0;
        // Bound the cost even for extreme client viewports. A seven-texel
        // footprint intersects at most eight texels per axis, including edges.
        vec2 radius = clamp(footprint * 0.5, vec2(0.5), vec2(3.5));
        vec2 start = max(center - radius, crop_start);
        vec2 end = min(center + radius, crop_end);
        ivec2 base = ivec2(floor(start));
        float total = 0.0;
        for (int y = 0; y < 8; ++y) {
            for (int x = 0; x < 8; ++x) {
                ivec2 tap = base + ivec2(x, y);
                vec2 coverage = max(vec2(0.0), min(end, vec2(tap + 1)) - max(start, vec2(tap)));
                float weight = coverage.x * coverage.y;
                if (weight == 0.0) continue;
                value += cursor_texel(item, index, clamp(tap, first, last)) * weight;
                total += weight;
            }
        }
        value /= max(total, 0.000001);
    } else if (mode == 1u) {
        for (int y = -1; y <= 2; ++y) {
            float wy = cubic_weight(float(y) - fraction.y);
            for (int x = -1; x <= 2; ++x) {
                float weight = cubic_weight(float(x) - fraction.x) * wy;
                if (weight == 0.0) continue;
                value += cursor_texel(item, index, clamp(lower + ivec2(x, y), first, last)) * weight;
            }
        }
    } else {
        vec4 a = cursor_texel(item, index, clamp(lower, first, last));
        vec4 b = cursor_texel(item, index, clamp(lower + ivec2(1, 0), first, last));
        vec4 c = cursor_texel(item, index, clamp(lower + ivec2(0, 1), first, last));
        vec4 d = cursor_texel(item, index, clamp(lower + ivec2(1, 1), first, last));
        value = mix(mix(a, b, fraction.x), mix(c, d, fraction.x), fraction.y);
    }
    if (item.affine_tail.z == 1) {
        // Already in output linear light (possibly HDR): do not clamp RGB to
        // encoded alpha. Keep global opacity when removing cubic overshoot.
        float alpha = clamp(value.a, 0.0, float(item.attributes.z) / 255.0);
        vec3 rgb = item.attributes.x >= 10u ? value.rgb : max(value.rgb, vec3(0.0));
        value.rgb = value.a > 0.0 ? rgb * (alpha / value.a) : vec3(0.0);
        value.a = alpha;
        return value;
    }
    // Cubic negative lobes must not generate dark or colored alpha fringes.
    value.a = clamp(value.a, 0.0, 1.0);
    // Floating-point sources may intentionally carry negative or HDR RGB.
    if (item.attributes.x < 10u) value.rgb = clamp(value.rgb, vec3(0.0), vec3(value.a));
    if (item.affine_tail.z == 2) value.rgb = value.a > 0.0 ? value.rgb / value.a : vec3(0.0);
    return decode_pixel(item, value);
}
