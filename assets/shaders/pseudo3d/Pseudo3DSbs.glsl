//!HOOK MAIN
//!BIND HOOKED
//!DESC Pseudo-3D SBS: heuristic depth + horizontal parallax

// Depth strength, 0.0-1.0. This is a plain GLSL constant rather than an mpv
// shader parameter on purpose -- and it is the one thing about this file that
// must not change.
//
// mpv's PARAM parameter metadata is a libplacebo (vo=gpu-next) feature.
// Classic vo=gpu's user-shader parser has no case for it: it reports
// "Unrecognized command 'PARAM strength'", parse_hook() returns false, and
// parse_user_shader() abandons the *entire file* -- so a vo=gpu session
// registers no hook and silently renders the untouched frame. The theater
// path cannot rely on which backend it lands on (MpvPlayerCore's
// initialVideoOutput picks per file, gpu first), so this file has to parse
// on both.
//
// Strength is therefore baked into a per-strength copy of this file by
// ShaderAssetLoader.materializePseudo3DShader, which substitutes the literal
// below. Nothing else in the file is rewritten.
//
// NOTE for future edits: the two-character header marker must never appear
// anywhere below the metadata block, not even inside a comment. mpv locates
// the end of the shader body with a plain substring search for that marker
// (bstr_split_tok in user_shaders.c), not a line-anchored one, so a stray
// mention in a comment truncates the body before hook() and the shader stops
// compiling. Refer to "mpv's PARAM metadata" in prose instead.
const float STRENGTH = 0.5;

vec4 hook() {
    vec2 uv = HOOKED_pos;

    // The compositor's StereoMode.LeftRight shows the output's left half to
    // the left eye and its right half to the right eye, each stretched
    // across the panel. Both halves therefore have to carry the WHOLE
    // source frame at half width -- not one half of it each -- so the
    // output half is mapped back to the full [0,1] source range before
    // anything is sampled. (HOOKED_pos itself is the full-frame coordinate;
    // sampling it directly would show the left eye the left half of the
    // image and the right eye the right half, i.e. a 2x horizontal crop per
    // eye rather than a stereo pair.)
    bool isLeftHalf = uv.x < 0.5;
    vec2 srcUv = vec2(fract(uv.x * 2.0), uv.y);

    // Fake depth proxy from cheap, already-available signals: a vertical
    // term (in most footage the bottom of frame is the ground plane, so it
    // reads "near", the top "far") blended with a local-contrast edge term
    // (soft/blurry regions read "far"). HOOKED_pos.y is 0 at the image's
    // top and 1 at its bottom in both storage orientations -- mpv's
    // get_transform() folds each plane's bottom-up/stride<0 storage into a
    // flip so that holds regardless of how the frame was uploaded.
    float farness = 1.0 - srcUv.y;
    float edge    = length(fwidth(HOOKED_tex(srcUv).rgb)) * 4.0;
    float depth   = clamp(mix(farness, edge, 0.35), 0.0, 1.0);

    // Disparity is strictly horizontal and opposite per eye, and 0.5 is the
    // convergence plane: below it the eye samples are crossed (perceived
    // nearer, in front of the panel), above it uncrossed (perceived
    // farther, behind it).
    float shift = (depth - 0.5) * STRENGTH * 0.02; // fraction of the frame
    vec2 offset = vec2(isLeftHalf ? -shift : shift, 0.0);
    vec3 color = HOOKED_tex(clamp(srcUv + offset, 0.0, 1.0)).rgb;
    return vec4(color, 1.0);
}
