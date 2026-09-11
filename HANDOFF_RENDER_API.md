# HANDOFF — mpv render-API migration (for real depth-based stereo)

**Status: NOT STARTED. Plan only. Written 2026-09-11.**

Goal: replace the theater session's `vo`-based rendering with mpv's **render
API** (`mpv_render_context`), so that video frames arrive in a GL context *we*
own. That is the prerequisite for everything else — a depth model's per-frame
output has nowhere to go on the current path, because an mpv user shader can
only consume static `TEXTURE` bytes loaded once at parse time.

Read `PLAN_3D.md` § Phase 3 first for the model research; this file is the
migration itself.

---

## 0. Decision to confirm BEFORE writing any code

This migration has a cost that is easy to miss, and it is large enough to
warrant a deliberate call rather than a default.

**What we gain**: arbitrary post-processing of decoded frames (depth-warp, SBS
pack, anything), full compositing control, and the end of the entire bug class
fought through Phase 2 (vo selection, the `PARAM` rejection, user-shader parse
failures, mpv's path-keyed shader cache, `HOOKED_pos` orientation).

**What we give up**: the fork's `vo=mediacodec` fast path (
`edde746/mpv-build`, `patches/mpv/`). That vo exists specifically to hand
MediaCodec decoder buffers **straight to the Android compositor** with
per-frame presentation timestamps — no GLES pass, 10-bit and the decoder's
dataspace (HDR10/HLG) intact. The render API renders through **our** GL into an
FBO, which means:

- a GLES pass per frame per eye that does not exist today (power + thermals on
  a headset; this is the main risk of the whole change),
- HDR/10-bit correctness becomes **our** problem instead of the decoder's,
- the fork's OSD/subtitle plane and its freestanding scheduler
  (`scripts/test_mediacodec_osd.sh` in the mpv-build repo) are bypassed, so
  subtitles must be re-solved,
- the fork's MediaCodec timing work (cadence prediction, prepare/draw/flip
  lead) no longer applies to the theater path.

### The alternative worth weighing first

**Extend the fork vo instead of leaving it.** The fork is ours
(`edde746/mpv-build`), and a custom vo can accept extra inputs. Adding a
depth-map texture channel to `vo=mediacodec` — fed from the app over a surface
or a shared buffer — would preserve the zero-copy path, the OSD plane, the HDR
dataspace handling and the timing work, and give the warp a place to run. Cost:
C changes in a second repo with its own build/publish cycle
(content-addressed binary keys in `artifacts.json`), and a bespoke surface
handoff protocol.

| | Render API | Extend the fork vo |
|---|---|---|
| Zero-copy MediaCodec→compositor | **lost** | kept |
| HDR / 10-bit / DV dataspace | ours to maintain | kept |
| Subtitles / OSD plane | ours to re-solve | kept |
| Power cost | +1 GLES pass/frame | minimal |
| Where the depth warp runs | our GL, easy | in the fork vo (C) |
| Repos touched | this one | this one **and** mpv-build |
| Reversibility | config switch, both paths can coexist | needs a new binary |

If the priority is *shipping depth-based 3D with acceptable thermal behaviour*,
the fork-vo route is likely cheaper. If the priority is *not touching a second
repo and owning the pipeline*, the render API is right. **Do not start without
choosing.** Both are viable; this document details the render-API one because
that is what was asked for.

---

## 1. Current architecture — what owns what today

Everything below is what the migration has to replace or re-home. File paths are
from the repo root.

### Rendering / vo

| Concern | Where | Notes |
|---|---|---|
| vo choice | `MpvPlayerCore.initialVideoOutput(hardwareDecoding)` (MpvPlayerCore.kt:125) | `hardwareDecoding ? "mediacodec,gpu" : "gpu,gpu-next"` |
| "is the video plane in use" | `MpvPlayerCore.usesMediaCodecVo` (MpvPlayerCore.kt:210) | `!audioOnly && hardwareDecoding` — gates most of the code below |
| Leaving the plane for a GL vo | `GpuVoPolicy` (138 lines) + `setGpuVoRequirement` / `applyGpuVoTarget` / `refreshVideoOutput` | Reasons: `REASON_DV_RESHAPE`, `REASON_SW_DECODE`, `REASON_SHADERS`, `REASON_HDR_SDR`. `targetFor()` → `gpu-next` for DV reshape, else `gpu` |
| GL context | `gpu-context=android`, `opengl-es=yes` options | created by mpv inside the vo |
| glsl chain | `change-list glsl-shaders` (`ShaderService`, plus the theater session's own append) | becomes unnecessary for our warp under the render API |

### Surface / geometry / OSD

| Concern | Where | Notes |
|---|---|---|
| Surface plumbing | `shared/PlayerSurfaceHost.kt` (107 lines) | container, video SurfaceView, OSD SurfaceView, Flutter-overlay stacking |
| OSD/subtitle plane | `mpv/OsdPlanePolicy.kt` (41 lines) + `osdSurfaceView` + `osdRenderScale` | vo=mediacodec's OSD is itself a SurfaceView-backed plane |
| OSD surface option | `render.cpp` → `vo-mediacodec-osd-surface` (`nativeAttachSurfaces`) | the only thing `render.cpp` does today |
| Vision geometry | `mpv/VideoRectPolicy.kt` (53 lines) | the fork vo scales buffers to the whole Surface and implements none of mpv's src/dst rect math, so aspect/cover/zoom are **View geometry**. Under the render API this becomes real mpv/GL rect math again |
| Panel surface (theater) | `theater3d/Theater3DPanel.kt` | `VideoSurfacePanelRegistration`, fixed 1920×1080 compositor buffer, `stereoMode` via `MediaPanelRenderOptions` |
| Panel surface (flat) | `shared/PlayerSurfaceHost.createVideoSurface` | normal SurfaceView |

### HDR / DV / decode policy

| Concern | Where | Notes |
|---|---|---|
| DV profile → reshaping | `DoviBridge`, `GpuVoPolicy.REASON_DV_RESHAPE`, `applyDvReshapePolicy` | P5 (IPT-PQ-c2) has no compatible base layer |
| Software-decode routing | `applySoftwareDecodePolicy`, `GpuVoPolicy.needsSoftwareRender(hwdecCurrent)` | `hwdec-current != "mediacodec"` ⇒ needs a GL vo |
| AV1 film grain | `vd-lavc-film-grain=cpu` option | keeps grain in dav1d, avoids the gpu-next GLES luma flip bug |
| HDR tone mapping | `collectHdrToneMapState`, `GpuVoPolicy.needsHdrToneMapping` | |
| Frame rate / display | `FrameRateManager`, `DisplayModeSelector`, `display-fps-override` | |

### Flutter / channel plumbing (unchanged by this work)

`MainActivity` ↔ `PlayerChannelBinding` ↔ `MpvPlayerPlugin`, `ExoPlayerPlugin`,
`lib/mpv/player/player_native.dart`. **ExoPlayer is a separate decode path and
is not affected** — do not let this migration touch it.

### Native

`android/libmpv/src/main/cpp/`: `main.cpp`, `event.cpp`, `property.cpp`,
`render.cpp`, `globals.h`, `jni_utils.*`. JNI surface is
`nativeCreate/Init/Destroy`, `nativeCommand`, `nativeSetProperty*`,
`nativeGetProperty*`, `nativeObserveProperty`, `nativeSetOptionString`,
`nativeSetLogLevel`, `nativeHookContinue`, `nativeAttachSurfaces`.

**There is no render-API JNI whatsoever.** `mpv_render_context` appears only in
the shipped headers (`include/mpv/render.h`, `render_gl.h`) — grep-verified
across `android/**`.

---

## 2. The target architecture

```
mpv decode ──► mpv_render_context_render() into an FBO texture WE own
                        │
                        ├── depth model (optional, out of frame rate) ──► depth texture
                        │
                        └──► OUR shader: sample frame + depth
                                     apply per-eye horizontal disparity
                                     pack SBS
                                     │
                                     ▼
                        EGL surface = Spatial SDK panel's Surface
```

Concretely:

1. `mpv_render_context_create` with `MPV_RENDER_PARAM_API_TYPE =
   MPV_RENDER_API_TYPE_OPENGL`, an EGL display/context we created, and
   `MPV_RENDER_PARAM_OPENGL_INIT_PARAMS`.
2. `mpv_render_context_set_update_callback` → render when mpv signals a new
   frame (on our GL thread, **not** the Android main thread).
3. `mpv_render_context_render` with `MPV_RENDER_PARAM_OPENGL_FBO` pointing at an
   FBO whose colour attachment is a texture we can then sample.
4. Our own fragment shader does the disparity warp and SBS pack, sampling that
   texture (+ the depth texture when the model is in), and draws to the panel's
   Surface via an EGL window surface.
5. `MPV_RENDER_PARAM_ADVANCED_CONTROL` if we want mpv's frame-stepping/timing
   cooperation; decide deliberately, it changes who owns presentation timing.

Note the SBS pack now happens **in our shader**, so `MediaPanelRenderOptions`
`stereoMode` may still be `LeftRight` (the compositor still does the per-eye
split) — i.e. mpv and the compositor contract is unchanged, only the frame
source changes. That keeps the Phase 1 stereo work valid.

---

## 3. Work breakdown

Ordered; each step should be independently verifiable.

### 3.1 Native: render-API JNI (new)
- New file `android/libmpv/src/main/cpp/render_gl.cpp` (keep `render.cpp` as the
  surface-attach file it is today).
- Entry points: `nativeRenderCreate`, `nativeRenderRender(fbo, w, h)`,
  `nativeRenderDestroy`, `nativeRenderSetUpdateCallback`,
  `nativeRenderReportFlip` (if using advanced control).
- EGL setup/teardown, GL context current on one dedicated thread, and the
  callback marshalled back to Kotlin.
- `MPV_RENDER_PARAM_OPENGL_FBO` per render call; decide whether to render to the
  default framebuffer or an FBO texture (the warp needs the texture).
- Reuse the existing lifetime discipline: `globals.h`'s `SessionGuard`, the
  admission/teardown ordering that `render.cpp`'s comments describe. The
  existing locking rules are load-bearing — read them before adding a second
  surface-owning subsystem.

### 3.2 Kotlin: GL renderer host (new)
- A small class owning: EGL display/context/surface, the FBO + colour texture,
  the GL thread, and the warp shader program.
- Wire to `MpvPlayerCore` behind a flag (mirroring the `headless` constructor
  parameter precedent) so **both paths coexist** and the migration is
  reversible per build.
- `MpvPlayerCore` is already 2230 lines. Do not grow it: introduce the renderer
  as a collaborator and keep the vo path's removal to a later, separate step.

### 3.3 Depth-warp shader (new, GLSL ES 3.0 — not mpv user shader)
A plain shader we compile. Along the way this **retires** the pile of mpv
user-shader landmines recorded in `PLAN_3D.md`: no `PARAM` metadata, no
`HOOKED_pos` orientation question, no `bstr_split_tok` header-marker trap, no
path-keyed shader cache. It also removes the need to recompile anything to
change strength — strength becomes a uniform, so the depth slider updates
**live** with no re-append.
- Port the current maths as the starting point:
  `assets/shaders/pseudo3d/Pseudo3DSbs.glsl` (joint-bilateral depth, unwrapped
  coordinates, no derivative terms). Its tests in
  `test/services/shader_asset_loader_test.dart` encode the constraints that were
  expensive to learn — keep them as the spec even though the file becomes a
  plain asset.

### 3.4 Subtitles / OSD (re-solve)
- Under the render API mpv can render subtitles **into the video frame**
  (`blend-subtitles`) or we draw them ourselves. Decide, but note Phase 2 shipped
  with **no subtitle rendering in the theater session at all** (the headless
  core has no OSD plane), so this is not a regression to fix — it is a feature
  that finally becomes possible. Scoping it is a separate task.
- For the **flat** player this *is* a regression risk: it currently relies on the
  fork's OSD plane + `OsdPlanePolicy` + `subtitleRenderScale`. If the flat path
  also moves to the render API, that must be re-implemented. **Recommendation:
  migrate the theater path only, first**, leaving the flat player on the vo.

### 3.5 HDR / DV (decide explicitly)
- Today the fork vo preserves 10-bit + dataspace to the compositor. Under the
  render API, `gpu-hwdec-interop` + EGL is the route, and formats/transfer are
  ours to get right.
- Known trap already in this repo's comments: `gpu-next` under *hardware* decode
  was broken on Tegra (`samplerExternalOES` double declaration) — Quest is
  Adreno, so it may be fine, but **test on-device, do not assume**.
- `GpuVoPolicy`'s logic (leaving the plane for DV reshape / software decode /
  shaders / HDR) exists because the plane could not do those things. Under the
  render API much of that routing collapses — **but do not delete it until the
  flat path stops using it**.

### 3.6 Model integration (only after 3.1–3.3 are green)
- Infer at low resolution (256×256) and a fraction of video framerate; hold the
  map and reuse across frames.
- **Joint-bilateral upsample** the low-res depth using the full-res frame as
  guide — this is what makes 256×256 acceptable at 1080p and is the answer to
  "better edges". The current heuristic already does the cheap single-pass form
  of this (colour-similarity weights, `EDGE_K` in the shader).
- Temporal smoothing is mandatory. See §4 for the model choice.

---

## 4. Model choice — researched 2026-09-11

| Candidate | Params | Size (quantized) | Licence | Verdict |
|---|---|---|---|---|
| **Depth Anything V2 Small** | 24.8M | **19.2 MB** (`q4f16`)<br>27.3 MB (`int8`) | Apache-2.0 | **Safe first step.** Prebuilt fused quantized ONNX (256 and 512 in) already proven on Android via ONNX Runtime: `shubham0204/Depth-Anything-Android` releases |
| **Video Depth Anything Small** | 28.4M | ~28 MB (no official quantized export) | Apache-2.0 | **Better for this use case, higher risk.** See below |
| DA V2 / VDA Base + Large | 97.5M+ | — | **CC-BY-NC-4.0** | Disqualified: non-commercial, regardless of size |
| DA V2 Small via ncnn/Vulkan | 24.8M | 50.6 MB fp16 | Apache-2.0 | Its own README warns small models often run **slower on GPU than CPU** on Android — do not assume Vulkan wins |

### Video Depth Anything — why it is attractive and why it is risky

`DepthAnything/Video-Depth-Anything`, CVPR 2025 Highlight (ByteDance). Same
DINOv2 ViT-S + DPT backbone as DA V2, plus a temporal attention module. **The
entire point is temporal consistency for long video**, which is exactly the
requirement that kills naive per-frame inference (flicker → depth swimming →
nausea in a headset).

- **Streaming mode exists** (2025-07-03, experimental, training-free): it caches
  the temporal-attention hidden states and feeds **one frame per inference**,
  reusing past hidden states. That is precisely the realtime shape we need.
- Size/latency per the project's own numbers: 28.4M params; **7.5 ms FP16** for
  a `1×32×518×518` batch on an A100. Divide by 32 for a per-frame figure, then
  scale for XR2 Gen2 — treat any on-device number as **unmeasured** until we
  measure it.
- **Honest caveat from the authors**: streaming mode degrades quality — ScanNet
  `δ1` drops `0.926 → 0.836` offline→streaming, and they explicitly call it
  experimental with fine-tuning left as future work.
- **Integration risk**: no off-the-shelf quantized ONNX (DA V2 Small has one),
  and the streaming cache reuse is a *modified pipeline*, not a standard graph
  export. Expect to write and validate the export yourself.

**Recommendation**: do **DA V2 Small quantized first** — smallest, off-the-shelf,
proven Android path — and plan VDA-Small streaming as the follow-up once the
plumbing works. The switch is not a rewrite: both are the same
DINOv2-ViT-S + DPT family, so an export/quantization pipeline built for one
transfers to the other. Do not block first integration on VDA.

---

## 5. Landmines already paid for (do not rediscover)

These cost real on-device debugging time in Phases 0–2 and all still apply.

1. **`Vector3.Forward` is `(0,0,+1)`** in Spatial SDK 0.13.2 — +Z is forward. A
   naive `-Z` offset spawns panels behind the user.
2. **`VRFeature` goes on `VrActivity.registerFeatures()`**, a different hook from
   `AppSystemActivity.registerSystemFeatures()`. Wrong hook ⇒ panels register
   and spawn with valid entity ids and never render, with **zero exceptions**.
3. **`com.oculus.intent.category.VR`** is required on the theater Activity or
   Horizon never grants an immersive compositor session — Kotlin runs to
   completion, `onSceneReady` fires, nothing composites.
4. **`scene.getViewerPose()` returns an exact zeroed pose** inside
   `onSceneReady()` before head tracking populates; fall back to 1.6 m eye
   height when reported height `< 0.5`.
5. **Set the pending session's `request`/`listener` before `super.onCreate()`** —
   `AppSystemActivity.onCreate()` calls `registerPanels()` synchronously.
6. **R8 strips resources loaded by name** (`@drawable/dot_cursor` via
   `BitmapFactory.decodeResource`) — `tools:keep` in a raw `keep.xml`.
7. **`kotlin-reflect` is required** by `SystemDAG`'s topological sort in
   `:theater3d`, or every system lookup silently returns a stub.
8. **A `--` inside an XML comment body** breaks manifest parsing (hit twice).
9. **`adb exec-out screencap` does not reliably show Spatial panels.** The
   physical headset was the only reliable oracle in Phase 0. It *does* work for
   the theater panel in a later session, but never trust it as sole evidence.
10. **`vo=mediacodec` fails against a Spatial panel Surface** with "Failed to
    create HW uploader for format yuv420p" — and the real cause was **software
    frames**, i.e. `hwdec` not being set (see below).
11. **`hwdec` is written from Dart**, not Kotlin: `video_player_screen.dart`
    `_getHwdecValue` → `'mediacodec,mediacodec-copy'`. Any *second* mpv session
    created natively must set `hwdec` itself or it decodes on the CPU. This cost
    a full diagnosis round: it looked like a compositor bug and was a missing
    property.
12. **mpv caches user shaders by path** (`load_cached_file`), forever. Rewriting
    one filename and re-appending re-parses the original. And a truncated read
    of a mid-write shader makes `parse_user_shader` abandon the whole file ⇒ no
    hook ⇒ raw split. Under the render API this whole class disappears.
13. **mpv v0.41.0** (per `mpv-build`'s README badge / `mpv-build.lock.json`),
    **ffmpeg n8.0.1**. Verify any mpv-API assumption against *that* source, not
    docs and not memory — every API claim in Phase 1/2 was checked with `javap`
    or upstream source and several documented claims were wrong.

---

## 6. Verification plan

Reusable techniques from Phases 0–2; all of them earned their place.

- **Parser emulation (no device needed).** mpv's shader parser was
  reimplemented in ~40 lines from upstream `video/out/gpu/user_shaders.c` and run
  over the real asset to prove parse success/failure independently of hardware.
  Do the same for any GLSL we compile ourselves (e.g. validate the ES 3.0 warp
  shader's source against a desktop GL context before shipping).
- **Stereo screencap measurement.** A `adb exec-out screencap -p` of stereo
  content can be split into eye halves and the per-row horizontal offset
  measured by SAD minimisation. That is how the "looks 2D" claim was tested and
  it produced a real regression slope. Reuse it to *quantify* the warp rather
  than eyeball it: with the render API we control disparity directly, so
  measure the realised offset against the intended one.
- **Sustained logcat capture** via `hub start` into a file, with a recorded line
  baseline before each test, so a test session can be diffed out afterwards.
  Enlarge the ring buffer first (`adb logcat -G 16M`) — at 256 KB the compositor
  rotates it out within minutes.
- **Device-side artefact inspection.** `adb shell run-as com.edde746.plezy cat
  <path>` to prove what the app actually wrote (this is how the per-strength
  shader names were confirmed) and `ls -la cache/shaders/...` for state.
- **Explicit success-path logging.** Both `registerPanels()` and `onSceneReady()`
  originally had *only* failure-path logging, which made "nothing renders with
  zero errors" unreadable. Keep success-path `Log.i` calls in the new renderer
  (context created, FBO complete, first frame rendered, callback fired count).
- **Gates**: `dart analyze`, `flutter test`, `:app:compileDebugKotlin` on both
  default and `THEATER_MODE=1`, `:theater3d:testDebugUnitTest` (JVM), and
  `adb install -r` over the existing install (same debug keystore ⇒ data
  preserved; **never delete the Dart-materialized shader template mid-test** —
  that was done once and produced a spurious `Failed to read shader` error).
- **Perf claim discipline**: `--hwdec` and vo behaviour must be read from
  `hwdec-current` / `vo` logging on-device, not inferred. The A/V desync incident
  was diagnosed only because the log carried mpv's own warning.

---

## 7. Open questions

1. **Render API vs extending the fork vo** (§0) — the blocking decision.
2. **Who owns presentation timing.** `MPV_RENDER_PARAM_ADVANCED_CONTROL`
   changes it; the fork currently owns cadence/PTS/swap lead. Pick one owner.
3. **Single or dual GL context.** The Spatial SDK compositor, mpv's interop and
   our FBO may each want a context; sharing/`EGL_KHR_fence_sync` semantics must
   be settled before coding.
4. **Does 10-bit/HDR survive** the render-API path on Adreno? Unmeasured.
5. **Thermals.** A per-frame GLES pass per eye at 1920×1080 on XR2 Gen2 is not
   free. Measure before committing to full-rate; the flat player's `vo` path
   exists precisely to avoid this.
6. **Where depth inference runs.** Same GPU as compositing ⇒ contention. A
   separate thread with a bounded queue, and a defined drop policy, is required;
   NNAPI/Hexagon may be preferable to GPU for exactly this reason.
7. **Subtitle strategy** for the theater path (§3.4).
