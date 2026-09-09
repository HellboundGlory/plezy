//!HOOK MAIN
//!BIND HOOKED
//!DESC Pseudo-3D SBS: heuristic depth + horizontal parallax
//!PARAM strength
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.5

vec4 hook() {
    vec2 uv = HOOKED_pos;
    // Fake depth proxy from cheap, already-available signals: vertical
    // position (bottom-of-frame reads "closer" in most footage) blended with
    // a local-contrast edge term (soft/blurry regions read "farther").
    float vpos   = 1.0 - uv.y;
    float edge   = length(fwidth(HOOKED_tex(uv).rgb)) * 4.0;
    float depth  = clamp(mix(vpos, edge, 0.35), 0.0, 1.0);

    float shift = (depth - 0.5) * strength * 0.02; // fraction of width
    vec3 left  = HOOKED_tex(clamp(uv - vec2(shift, 0.0), 0.0, 1.0)).rgb;
    vec3 right = HOOKED_tex(clamp(uv + vec2(shift, 0.0), 0.0, 1.0)).rgb;

    // Pack into one SBS frame: left half of output = left eye, right half = right eye.
    bool isLeftHalf = uv.x < 0.5;
    vec2 srcUv = vec2(fract(uv.x * 2.0), uv.y);
    vec3 color = isLeftHalf ? left : right;
    return vec4(color, 1.0);
}
