// Per-surface HDR -> SDR mapping, before blending. Adjacent SDR surfaces never
// inherit an HDR window's shoulder. Work on straight optical RGB, not alpha.
vec3 map_hdr_to_sdr(vec3 rgb, float source_peak) {
    float peak = max(max(rgb.r, rgb.g), rgb.b);
    const float knee = 0.5;
    if (peak > knee) {
        float limit = max(source_peak, 1.0);
        float t = min(peak, limit) - knee;
        // Unit slope at the knee; the declared source peak maps to SDR white.
        float mapped = knee + t / (1.0 + t * (2.0 - 1.0 / (limit - knee)));
        rgb *= mapped / peak;
    }
    // Compress out-of-gamut RGB toward the neutral axis instead of clipping
    // channels independently. This preserves RGB hue, not perceptual lightness.
    float lo = min(min(rgb.r, rgb.g), rgb.b);
    float hi = max(max(rgb.r, rgb.g), rgb.b);
    float neutral = clamp((lo + hi) * 0.5, 0.0, 1.0);
    float chroma = 1.0;
    if (lo < 0.0) chroma = min(chroma, neutral / (neutral - lo));
    if (hi > 1.0) chroma = min(chroma, (1.0 - neutral) / (hi - neutral));
    return mix(vec3(neutral), rgb, chroma);
}
