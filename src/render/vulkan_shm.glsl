// PixelFormat ABI from types.zig. Integer UNORM, never half-float.
uint shm_pixel_bytes(uint format) { return format == 2u ? 8u : 4u; }

vec4 unpack_shm(uint low, uint high, uint format) {
    if (format == 2u)
        return vec4(low & 65535u, low >> 16u, high & 65535u, high >> 16u) / 65535.0;
    if (format == 3u || format == 4u) {
        vec3 rgb = vec3((low >> 20u) & 1023u, (low >> 10u) & 1023u, low & 1023u) / 1023.0;
        return vec4(format == 3u ? rgb : rgb.bgr, float(low >> 30u) / 3.0);
    }
    return vec4((low >> 16u) & 255u, (low >> 8u) & 255u, low & 255u, low >> 24u) / 255.0;
}
