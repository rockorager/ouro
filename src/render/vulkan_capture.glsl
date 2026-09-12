// Neither raw Wayland capture protocol carries a color description. Ouro's
// raw contract is SDR desktop gamma22, not monitor PQ/HLG/ICC or assumed sRGB.
// Internal color-managed export may request explicit sRGB (transfer 0).
// Export from linear composition before output encoding and quantization.
layout(std430, set = 0, binding = 10) writeonly buffer CaptureBefore { uint capture_before[]; };
layout(std430, set = 0, binding = 11) writeonly buffer CaptureAfter { uint capture_after[]; };

void capture_pixel(ivec2 pixel, vec4 color) {
    uint phases = uint(frame.capture_color[0].w);
    if (phases == 0u) return;
    mat3 transform = mat3(frame.capture_color[0].xyz,
                          frame.capture_color[1].xyz,
                          frame.capture_color[2].xyz);
    vec3 straight = transpose(transform) * color.rgb / max(color.a, 0.000001);
    uint export_flags = uint(frame.capture_color[2].w);
    if ((export_flags & 1u) != 0u) {
        // Simple SDR shoulder, not an HDR mastering transform. Keep shadows
        // through 0.5 unchanged; compress the maximum RGB component towards
        // one and scale all channels together to retain their ratios. SDR
        // reference white maps to 0.75, leaving headroom for HDR highlights.
        float peak = max(max(straight.r, straight.g), straight.b);
        if (peak > 0.5) {
            float shoulder = 0.5 + (peak - 0.5) / (1.0 + 2.0 * (peak - 0.5));
            straight *= shoulder / peak;
        }
    }
    // Negative out-of-gamut values still clip at SDR export.
    vec3 encoded = clamp(encode_transfer(straight, uint(frame.capture_color[1].w)), 0.0, 1.0) * color.a;
    uint packed = packUnorm4x8(vec4(encoded.bgr, color.a));
    uint offset = uint(pixel.y) * frame.output_info.x + uint(pixel.x);
    uint precise_offset = frame.output_info.x * frame.output_info.y + 2u * offset;
    uvec2 packed16 = uvec2(packUnorm2x16(encoded.rg), packUnorm2x16(vec2(encoded.b, color.a)));
    if ((phases & 1u) != 0u) {
        capture_before[offset] = packed;
        if ((export_flags & 2u) != 0u) {
            capture_before[precise_offset] = packed16.x;
            capture_before[precise_offset + 1u] = packed16.y;
        }
    }
    if ((phases & 2u) != 0u) {
        capture_after[offset] = packed;
        if ((export_flags & 2u) != 0u) {
            capture_after[precise_offset] = packed16.x;
            capture_after[precise_offset + 1u] = packed16.y;
        }
    }
}
