#version 300 es
// Pseudo-3D warp + side-by-side pack for the theater's render-API pass.
//
// This is a plain GLSL ES 3.0 program this app compiles and owns, not an mpv
// user shader. Everything the previous user-shader revision fought is gone by
// construction: no `PARAM` metadata to be rejected on one backend, no
// `HOOKED_pos` orientation question, no header-marker trap, and no mpv
// path-keyed shader cache. Strength is a UNIFORM, so the in-scene slider
// updates live with no file rewrite and no recompile.
//
// Inputs, all set by render_gl.cpp:
//   uFrame      mpv's frame, already fitted to the panel by gl_video
//               (mpv_run_src_dst_rects honouring video-zoom/panscan/aspect)
//   uStrength   depth strength, 0..1, live
//   uResolution panel size in pixels
//   uSynthetic  0 = passthrough, 1 = synthesize depth and pack SBS
//
// Two modes, one program: a uniform branch, so the cost of the unused path is
// nothing. Passthrough is what real SBS/OU sources need -- they already carry
// parallax, and the compositor's StereoMode does the per-eye split, so the
// frame must reach it untouched. Synthetic is the heuristic 2D->3D path: the
// shader invents a depth field from the frame itself and packs the result as
// an SBS pair for the compositor to split.
//
// Geometry in synthetic mode, and why it is what it is: the compositor's
// StereoMode.LeftRight shows the output's left half to the left eye and its
// right half to the right eye, each stretched across the panel. Both halves
// therefore have to carry the WHOLE source frame at half width -- not one half
// each -- so the output coordinate is mapped back to the full [0,1] source
// range before anything is sampled (srcUv below). The compositor's per-eye
// stretch undoes the horizontal squeeze, so each eye ends up with a
// correctly-proportioned copy of the frame.
//
// Depth convention: 1.0 = near, 0.0 = far, 0.5 = the convergence plane. An
// eye's sample offset is (depth - 0.5) * strength * MAX_DISPARITY, negative
// for the left half and positive for the right: below the convergence plane
// the samples are crossed (perceived nearer), above it uncrossed (farther).

precision highp float;

uniform sampler2D uFrame;
uniform float uStrength;
uniform vec2 uResolution;
uniform int uSynthetic;

in vec2 vUv;
out vec4 fragColor;

// Fixed tuning. These were tuned on-device against real footage in the
// user-shader revision and carry over unchanged.
const float DETAIL_GAIN = 3.0;
const float DETAIL_MIX = 0.6;
const float BLUR_RADIUS = 0.02;
const float EDGE_K = 12.0;
// Disparity at full strength across the full depth range, as a fraction of
// the frame. The slider scales this.
const float MAX_DISPARITY = 0.02;

float lumaOf(vec3 c) {
  return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

// Ground-plane prior: vUv.y = 0 is the bottom of the panel (see the vertex
// stage) and the frame arrives with the image's bottom at v = 0, so the lower
// part of the picture is the ground plane and reads near.
float groundPrior(float y) {
  return 1.0 - y;
}

// Structure cue: how much local detail this region carries. Textured and
// high-contrast regions read near; flat haze, sky and bare walls read far.
//
// A high-pass magnitude against the *local mean*, NOT a per-pixel derivative.
// That distinction is the whole point: an earlier revision used fwidth() of
// the sampled colour, which peaks exactly along object silhouettes, so depth
// jumped at every edge and each eye sampled a different distance across it --
// a doubled outline that shimmered with the video.
//
// Do not over-read this: it is *smoother* than a per-pixel derivative, not
// edge-free. `lumaMean` is a wide blur and continuous by construction, but the
// cue is `abs(luma(tap) - lumaMean)`, which still responds strongly at a
// silhouette -- and this is a contrast/texture measure, not a depth estimate.
// The measured consequence is the edge artifact reported on-device: depth (and
// so the sample offset) changes across a couple of texels, `srcUv.x + offset`
// stops being monotonic, and the warp folds over along silhouettes. Worst on
// high-contrast, detailed subjects -- people. See HANDOFF_RENDER_API.md §8.7
// for the mechanism and the ranked fixes (gradient clamp first).
//
// Backgrounds read far because they are flat; that is the same statement as
// "detail reads near", and both are the heuristic's whole content.
float structureCue(vec3 tap, float lumaMean) {
  return clamp(abs(lumaOf(tap) - lumaMean) * DETAIL_GAIN, 0.0, 1.0);
}

void main() {
  if (uSynthetic == 0) {
    fragColor = vec4(texture(uFrame, vUv).rgb, 1.0);
    return;
  }

  bool isLeftHalf = vUv.x < 0.5;
  // The source coordinate, *unwrapped*: 0..1 across the whole frame within
  // EACH half. The right half's panel x runs 0.5..1.0, so its source
  // coordinate runs 1.0..2.0 and only needs folding back for the texture
  // lookup -- but every tap below is taken at this continuous value, never at
  // the folded one, because a tap window straddling the fold at 0.5 would mix
  // the two halves' images and leave a seam.
  //
  // This, and not the panel coordinate, is what the depth field is indexed by.
  // Indexing it by the panel coordinate is what an earlier revision did (it
  // tapped `HOOKED_pos`, the output position), and it is wrong for a stereo
  // pair: the left half's panel x maps to frame x = 2x, the right half's to
  // frame x = 2x - 1920, so the same scene point would be assigned the depth
  // of two different places in the frame. The two eyes then disagree about how
  // far that point is, which reads as ghosting, swimming and -- where the two
  // disagreements oppose -- a fully inverted pair.
  vec2 srcUv = vec2(vUv.x * 2.0 - (isLeftHalf ? 0.0 : 1.0), vUv.y);

  // One 5-tap neighbourhood, reused for everything below.
  vec2 r = vec2(BLUR_RADIUS, BLUR_RADIUS * uResolution.x / uResolution.y);
  vec3 c0 = texture(uFrame, srcUv).rgb;
  vec3 c1 = texture(uFrame, srcUv + vec2(r.x, 0.0)).rgb;
  vec3 c2 = texture(uFrame, srcUv - vec2(r.x, 0.0)).rgb;
  vec3 c3 = texture(uFrame, srcUv + vec2(0.0, r.y)).rgb;
  vec3 c4 = texture(uFrame, srcUv - vec2(0.0, r.y)).rgb;

  // Wide local mean: the low-frequency field the structure cue measures
  // against.
  vec3 mean3 = (c0 + c1 + c2 + c3 + c4) * 0.2;
  float lumaMean = lumaOf(mean3);
  float lumaCentre = lumaOf(c0);

  // Each tap's own depth. The horizontal taps (c1, c2) keep the centre's y:
  // they only moved in x, and attributing the centre row's ground prior to a
  // sample taken a row away was a plain copy-paste slip in the previous
  // revision.
  float depth0 = mix(groundPrior(vUv.y), structureCue(c0, lumaMean), DETAIL_MIX);
  float depth1 = mix(groundPrior(vUv.y), structureCue(c1, lumaMean), DETAIL_MIX);
  float depth2 = mix(groundPrior(vUv.y), structureCue(c2, lumaMean), DETAIL_MIX);
  float depth3 = mix(groundPrior(vUv.y + r.y), structureCue(c3, lumaMean), DETAIL_MIX);
  float depth4 = mix(groundPrior(vUv.y - r.y), structureCue(c4, lumaMean), DETAIL_MIX);

  // Joint-bilateral combination: each tap's depth is weighted by how
  // *colour-similar* it is to the centre, not by distance. Samples across an
  // object boundary are a different colour, so they are rejected and depth is
  // averaged only within a region -- which keeps depth edges aligned with
  // object edges instead of smeared across them, while still smoothing
  // interior noise. This is the edge-aware part; a plain box blur here would
  // soften exactly the boundaries that matter. It costs no extra texture
  // fetches: it reuses the five taps above.
  float w0 = 1.0;
  float w1 = 1.0 / (1.0 + EDGE_K * abs(lumaOf(c1) - lumaCentre));
  float w2 = 1.0 / (1.0 + EDGE_K * abs(lumaOf(c2) - lumaCentre));
  float w3 = 1.0 / (1.0 + EDGE_K * abs(lumaOf(c3) - lumaCentre));
  float w4 = 1.0 / (1.0 + EDGE_K * abs(lumaOf(c4) - lumaCentre));
  float wSum = w0 + w1 + w2 + w3 + w4;
  float depth = clamp(
      (w0 * depth0 + w1 * depth1 + w2 * depth2 + w3 * depth3 + w4 * depth4) / wSum,
      0.0, 1.0);

  float shift = (depth - 0.5) * uStrength * MAX_DISPARITY;
  vec2 offset = vec2(isLeftHalf ? -shift : shift, 0.0);
  vec3 color = texture(uFrame, clamp(srcUv + offset, 0.0, 1.0)).rgb;
  fragColor = vec4(color, 1.0);
}
