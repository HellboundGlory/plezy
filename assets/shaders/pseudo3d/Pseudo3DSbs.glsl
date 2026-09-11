//!HOOK MAIN
//!BIND HOOKED
//!DESC Pseudo-3D SBS: heuristic depth + horizontal parallax

// Depth strength, 0.0-1.0. Plain GLSL constants rather than mpv shader
// parameters on purpose. STRENGTH is the one the loader substitutes (see
// ShaderAssetLoader.materializePseudo3DShader and the theater session's live
// strength control), so it must stay a bare numeric literal on its own line
// in exactly this form; the others are fixed tuning.
//
// mpv's PARAM parameter metadata is a libplacebo (vo=gpu-next) feature.
// Classic vo=gpu's user-shader parser has no case for it: it reports
// "Unrecognized command 'PARAM ...'", parse_hook() returns false, and
// parse_user_shader() abandons the *entire file* -- so a vo=gpu session
// registers no hook and silently renders the untouched frame. The theater
// path cannot rely on which backend it lands on (MpvPlayerCore picks the vo
// per file, gpu first), so this file has to parse on both.
//
// NOTE for future edits: the two-character header marker must never appear
// anywhere below the metadata block, not even inside a comment. mpv locates
// the end of the shader body with a plain substring search for that marker
// (bstr_split_tok in user_shaders.c), not a line-anchored one, so a stray
// mention in a comment truncates the body before hook() and the shader stops
// compiling. Refer to "mpv's PARAM metadata" in prose instead.
const float STRENGTH = 0.5;
const float DETAIL_GAIN = 3.0;
const float DETAIL_MIX = 0.6;
const float BLUR_RADIUS = 0.02;

float lumaOf(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

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

    // Wide, smooth local mean of the frame. Every tap is taken in the
    // CONTINUOUS coordinate (uv), never srcUv: srcUv.x wraps through fract(),
    // so a derivative or a multi-tap window straddling the wrap at
    // uv.x == 0.5 would mix the two eye images and leave a seam there.
    vec2 r = vec2(BLUR_RADIUS, BLUR_RADIUS * HOOKED_size.x / HOOKED_size.y);
    vec3 centre = HOOKED_tex(uv).rgb;
    vec3 mean3 = centre
               + HOOKED_tex(uv + vec2( r.x, 0.0)).rgb
               + HOOKED_tex(uv + vec2(-r.x, 0.0)).rgb
               + HOOKED_tex(uv + vec2(0.0,  r.y)).rgb
               + HOOKED_tex(uv + vec2(0.0, -r.y)).rgb;
    mean3 *= 0.2;

    // Structure cue: how much local detail a region carries (textured and/or
    // high-contrast reads "near", flat haze/sky/walls read "far"). This is a
    // high-pass magnitude taken against the *blurred* field above, NOT a
    // per-pixel derivative. That distinction is the whole point: an earlier
    // revision used fwidth() of the sampled colour here, which peaks precisely
    // along object silhouettes, so depth jumped at every edge and each eye
    // sampled a different distance across it -- a doubled outline/halo that
    // shimmered with the video. A wide blur is continuous by construction, so
    // the depth field it produces is smooth: no edge response, no halos.
    float detail = clamp(abs(lumaOf(centre) - lumaOf(mean3)) * DETAIL_GAIN, 0.0, 1.0);

    // Ground-plane prior: in most footage the bottom of frame is nearer than
    // the top. HOOKED_pos.y is 0 at the image's top and 1 at its bottom in
    // both storage orientations -- mpv's get_transform() folds each plane's
    // bottom-up/stride<0 storage into a flip, so that holds however the frame
    // was uploaded.
    float farness = 1.0 - srcUv.y;

    // Blended rather than either alone: a pure ramp has no structure to
    // perceive as depth (it reads as a flat, slightly tilted plane), and a
    // pure detail field has no global layout. Together they give structure
    // that stays stable frame to frame.
    float depth = clamp(mix(farness, 1.0 - detail, DETAIL_MIX), 0.0, 1.0);

    // Disparity is strictly horizontal and opposite per eye, and 0.5 is the
    // convergence plane: below it the eye samples are crossed (perceived
    // nearer, in front of the panel), above it uncrossed (perceived farther,
    // behind it).
    float shift = (depth - 0.5) * STRENGTH * 0.02; // fraction of the frame
    vec2 offset = vec2(isLeftHalf ? -shift : shift, 0.0);
    vec3 color = HOOKED_tex(clamp(srcUv + offset, 0.0, 1.0)).rgb;
    return vec4(color, 1.0);
}
