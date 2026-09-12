// PixelFormat 13..21: NV12, NV21, P010, P012, P016, YUV420,
// YVU420, YUYV, UYVY. Color planes occupy descriptor banks 0, 32, 64.
// Modifier auxiliary memory planes are deliberately invisible here.
float video_code(float value, uint format) {
    if (format < 15u || format > 17u) return round(value * 255.0);
    uint bits = uint(round(value * 65535.0));
    return float(format == 15u ? bits >> 6u : format == 16u ? bits >> 4u : bits);
}

vec2 video_chroma_texel(uint format, uint index, ivec2 point) {
    bool packed = format >= 20u;
    uint slot = packed ? index : index + 32u;
    point = clamp(point, ivec2(0), textureSize(source_images[slot], 0) - 1);
    vec4 value = texelFetch(source_images[slot], point, 0);
    vec2 chroma;
    if (packed) chroma = format == 20u ? value.ga : value.rb;
    else if (format >= 18u) chroma = vec2(value.r, texelFetch(source_images[index + 64u], point, 0).r);
    else chroma = value.rg;
    if (format == 14u || format == 19u) chroma = chroma.yx;
    return vec2(video_code(chroma.x, format), video_code(chroma.y, format));
}

vec4 video_pixel(Sample item, uint index, ivec2 point) {
    uint format = item.attributes.x;
    uint metadata = floatBitsToUint(item.color_matrix_1.w);
    uint coefficients = metadata & 15u;
    bool full = ((metadata >> 4u) & 15u) == 1u;
    uint location = (metadata >> 8u) & 7u;
    bool packed = format >= 20u;
    vec4 luma = texelFetch(source_images[index], packed ? ivec2(point.x / 2, point.y) : point, 0);
    float y = packed ? (format == 20u ? ((point.x & 1) == 0 ? luma.r : luma.b)
                                                  : ((point.x & 1) == 0 ? luma.g : luma.a)) : luma.r;
    y = video_code(y, format);
    // H.273 Chroma420SampleLocType 0..5. Unset means type 0.
    uint type = max(location, 1u) - 1u;
    vec2 offset = packed ? vec2(0.0) : vec2((type & 1u) == 1u ? 0.5 : 0.0,
                                      type < 2u ? 0.5 : type < 4u ? 0.0 : 1.0);
    vec2 position = (vec2(point) - offset) / (packed ? vec2(2.0, 1.0) : vec2(2.0));
    ivec2 lower = ivec2(floor(position));
    vec2 fraction = fract(position);
    vec2 cbcr = mix(mix(video_chroma_texel(format, index, lower),
                        video_chroma_texel(format, index, lower + ivec2(1, 0)), fraction.x),
                    mix(video_chroma_texel(format, index, lower + ivec2(0, 1)),
                        video_chroma_texel(format, index, lower + ivec2(1, 1)), fraction.x), fraction.y);
    float scale = format == 15u ? 4.0 : format == 16u ? 16.0 : format == 17u ? 256.0 : 1.0;
    float maximum = 256.0 * scale - 1.0;
    y = full ? y / maximum : (y - 16.0 * scale) / (219.0 * scale);
    cbcr = (cbcr - vec2(128.0 * scale)) / (full ? maximum : 224.0 * scale);
    // H.273 non-constant-luminance YCbCr. Default is BT.709 limited.
    float kr = coefficients == 3u ? 0.299 : coefficients == 4u ? 0.2627 : 0.2126;
    float kb = coefficients == 3u ? 0.114 : coefficients == 4u ? 0.0593 : 0.0722;
    float r = y + 2.0 * (1.0 - kr) * cbcr.y;
    float b = y + 2.0 * (1.0 - kb) * cbcr.x;
    float g = (y - kr * r - kb * b) / (1.0 - kr - kb);
    // Preserve headroom and footroom through EOTF and linear composition.
    return vec4(r, g, b, 1.0);
}
