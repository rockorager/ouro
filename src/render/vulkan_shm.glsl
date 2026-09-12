// PixelFormat ABI from types.zig. UNORM16 and binary16 are distinct layouts.
uint shm_pixel_bytes(uint format) {
    if (format == 12u) return 16u;
    return format == 2u || (format >= 9u && format <= 11u) ? 8u : 4u;
}

bool shm_opaque(uint format) {
    return format == 1u || format == 6u || format == 7u || format == 8u || format == 9u || format == 11u;
}

vec4 unpack_shm(uint low, uint high, uint format) {
    if (format == 10u || format == 11u)
        return vec4(unpackHalf2x16(low), unpackHalf2x16(high));
    if (format == 2u || format == 9u)
        return vec4(low & 65535u, low >> 16u, high & 65535u, high >> 16u) / 65535.0;
    if (format == 3u || format == 4u || format == 7u || format == 8u) {
        vec3 rgb = vec3((low >> 20u) & 1023u, (low >> 10u) & 1023u, low & 1023u) / 1023.0;
        return vec4(format == 3u || format == 7u ? rgb : rgb.bgr, float(low >> 30u) / 3.0);
    }
    vec4 rgba = vec4((low >> 16u) & 255u, (low >> 8u) & 255u, low & 255u, low >> 24u) / 255.0;
    return format == 5u || format == 6u ? rgba.bgra : rgba;
}
