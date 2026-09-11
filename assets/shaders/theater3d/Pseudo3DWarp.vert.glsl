#version 300 es
// Fullscreen-triangle vertex stage for the theater-3D render-API pass.
//
// One oversized triangle covers the whole clip square instead of two
// triangles: no index buffer, no diagonal seam, and one fewer vertex to
// interpolate. The vertex positions come from render_gl.cpp.
//
// ORIENTATION. `vUv` is the output coordinate over the panel's framebuffer,
// with v = 0 at the BOTTOM -- that is the GL convention for a window surface,
// and it is what the identity mapping below produces (`aPos.y = -1` is the
// bottom of the viewport). render_gl.cpp renders mpv's frame with
// MPV_RENDER_PARAM_FLIP_Y, which mirrors the image on the way in, so texture
// v = 0 holds the image's bottom row too -- the two conventions agree, and a
// pixel-for-pixel copy comes out upright. Do not add a flip here without
// changing FLIP_Y there; the pair is one decision in two files.
in vec2 aPos;

out vec2 vUv;

void main() {
  vUv = aPos * 0.5 + 0.5;
  gl_Position = vec4(aPos, 0.0, 1.0);
}
