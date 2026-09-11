# PLAN_3D.md — Quest 3D / SBS Playback

Full scope for the recommended path from the 3D/SBS research pass
(`plezy_quest_3d_sbs_research.html`): a Quest-only "3D Theater" side-mode built
on the Meta Spatial SDK, entered only during playback, with a heuristic
2D→3D shader for ordinary content and pass-through stereo for already-3D
masters. The main app — browsing, keyboard, snap points — is never touched.

Real ML-based depth conversion is explicitly **out of scope** for this plan
(see Phase 3) and gets its own design pass after Phase 1+2 ship and are
validated on-device.

---

## 0. Non-negotiables carried from the research pass

- The main `MainActivity` / `android/quest` module stays a plain 2D panel.
  Nothing in this plan adds `com.oculus.intent.category.VR` or any immersive
  metadata to it.
- Spatial SDK code lives **only** in the new theater module below. If the
  theater Activity fails to initialize for any reason, the user lands back on
  the flat 2D player with no partial state — never a broken half-immersive
  screen.
- Phase 0 must pass on real Quest 3 hardware before Phase 1 gets committed to.
  The upside-down-panel bug that killed Holoplex's Spatial SDK usage is a
  platform-level defect, not something this plan's architecture can design
  around in advance.

---

## Phase 0 — De-risk spike (1-2 days, blocks everything else)

**Goal:** answer one question — does a Spatial SDK panel reliably render
right-side-up and cleanly hand control back to a plain 2D Activity on this
hardware/OS build — before any production code is written.

**Tasks**

1. New throwaway module `android/theater3d_spike` (deleted at the end of the
   phase, not merged): minimal `AppSystemActivity` registering one
   `ReadableVideoSurfacePanelRegistration` panel.
2. Feed the panel a static test pattern (a bundled left/right-labeled test
   image) via a plain `Canvas`-drawn `Surface`, no mpv involved yet.
3. Launch from the real `MainActivity` via `startActivity`, confirm:
   - Panel orientation is correct on first launch and on 10 consecutive
     relaunches (this is where Holoplex saw intermittent upside-down loads).
   - `finish()` on the theater Activity returns focus to the still-alive
     `MainActivity` 2D panel with no visual corruption, no dropped keyboard
     capability afterward.
   - Cold start latency from tap to first visible stereo frame.
4. Record results in this file's changelog (bottom). **A failing or flaky
   result here is a stop-ship signal for Phase 1** — fall back to shipping
   Phase 2's pass-through-only mode is not an option without Phase 1's panel,
   so a Phase-0 failure means re-scoping the whole feature, not just delaying
   it.

**Exit criterion:** 10/10 clean launches, correct orientation, clean handback.

---

## Phase 1 — Real-3D passthrough via Spatial SDK theater mode (1-2 weeks)

**Status: shipped 2026-09-08** — native module, headless mpv session and
Flutter bridge are all in place and unit-tested; see the changelog entry
below for what was verified on-device and what remains (there is no
player-UI trigger yet, that is Phase 2's own file list).

Ships genuine per-eye stereo for content that is **already** mastered as
SBS/OU 3D. No synthetic depth involved — this is the highest-value, lowest-risk
slice, and Phase 2's shader rides on top of the same panel.

### 1.1 New Gradle module: `android/theater3d`

Mirrors `android/quest`'s shape (a library module contributing manifest +
code, gated by an env var) but pulls in the Spatial SDK:

**Corrected 2026-09-08 (Phase 0 work) — the plan below was wrong on two
load-bearing points, found by actually attempting this exact wiring:**

1. **There is no `libs.meta.spatial.sdk` alias in this repo.**
   `android/` has no Gradle version catalog (no `libs.versions.toml`) at
   all — every dependency here is a plain string coordinate
   (`implementation("group:artifact:version")`), same as `media3Version` in
   `android/app/build.gradle.kts`. The "alias already present" claim
   describes Holoplex's `gradle/libs.versions.toml` (a different repo,
   confirmed via OpenViking sibling-project memory), not this one.
2. **`:theater3d` CAN be a normal subproject of `android/` — but only
   without `com.meta.spatial.plugin`.** Actually
   wiring `com.meta.spatial.plugin:0.13.2` into a `:theater3d_spike`
   subproject failed Gradle configuration outright: the plugin pulls in
   Kotlin Gradle Plugin build-report-metrics classes binary-incompatible
   with this repo's pinned Kotlin 2.4.10
   (`class BuildTimeMetric has interface BuildPerformanceMetric as super
   class`). Gradle resolves exactly one KGP version per multi-module build,
   so there is no way to pin an older KGP for one subproject while
   `android/`'s other ~20 subprojects (Flutter plugins included) stay on
   2.4.10. See `android/theater3d_spike/README.md` for the full repro.
   **RESOLVED 2026-09-08.** The conflict is caused specifically by
   `com.meta.spatial.plugin` itself, not by the SDK runtime AARs.
   Confirmed with a throwaway probe module (`android/_kgp_probe`,
   registered standalone in `settings.gradle.kts`, never wired into
   `:app`): a plain `com.android.library` module depending on
   `meta-spatial-sdk` / `-toolkit` / `-vr` 0.13.2 — with **no**
   `com.meta.spatial.plugin` and no explicit `org.jetbrains.kotlin.android`
   plugin (this repo's modules use AGP 9.3.1's built-in Kotlin, matching
   `android/app/build.gradle.kts`'s own `kotlin { compilerOptions {...} }`
   block, not the legacy KGP plugin) — both `compileDebugKotlin` and a full
   `assembleDebug` succeed cleanly against the repo's pinned Kotlin 2.4.10.
   `com.meta.spatial.plugin` was independently confirmed to be
   authoring-time-only tooling (Spatial Editor scene-export/hot-reload/
   shader-compile, via `unzip -l` on the AAR) that `TheaterSpikeActivity`
   never used at runtime — it doesn't load `.metaspatial` scene files —
   so dropping it costs nothing for a code-only `AppSystemActivity` +
   panel. **Phase 1.1's real `:theater3d` module must not apply
   `com.meta.spatial.plugin`.** Delete `android/_kgp_probe/` once Phase
   1.1 lands the real module using this same shape.

The dependency coordinates that DO resolve (verified against Maven Central,
`meta-spatial-sdk` 0.13.2, the current latest release as of 2026-09-08):

```kotlin
// android/theater3d/build.gradle.kts
dependencies {
    implementation("com.meta.spatial:meta-spatial-sdk:0.13.2")
    implementation("com.meta.spatial:meta-spatial-sdk-toolkit:0.13.2")
    implementation("com.meta.spatial:meta-spatial-sdk-vr:0.13.2")
}
```

Included only when `THEATER_MODE=1` is passed at build time, same idiom as
`QUEST=1` / `AMAZON=1` — additive, no product flavors, no effect on the
default or Fire TV builds. `QUEST_BUILD.md`'s build matrix gets a new row.

### 1.2 `Theater3DActivity` (Kotlin, new file)

```
android/theater3d/src/main/kotlin/com/edde746/plezy/theater3d/
  Theater3DActivity.kt       — AppSystemActivity host, one panel, minimal chrome
  Theater3DPanel.kt          — ReadableVideoSurfacePanelRegistration setup
  StereoModeResolver.kt      — maps ThreeDMode (see 2.2) -> StereoMode enum
  Theater3DBridge.kt         — MethodChannel handler, see 1.3
```

- `Theater3DActivity` is deliberately thin: one video panel entity, a small
  in-scene play/pause/exit affordance (grab-free — a fixed reticle-target
  button is enough; this activity never needs `IsdkGrabbable`/resize, which
  is where a chunk of Holoplex's complexity and bug surface lived).
- No text entry anywhere in this Activity. This is the concrete reason the
  keyboard/`SpeechRecognizer` failures Holoplex hit don't apply here — those
  bugs were about IME/dictation reaching a Spatial panel, and nothing in a
  video-only theater screen ever requests it.
- `ReadableVideoSurfacePanelRegistration` (not the plain
  `VideoSurfacePanelRegistration`) specifically because Phase 2's shader needs
  to post-process frames before they hit the panel's surface — confirmed
  supported for exactly this purpose in the Spatial SDK docs.

### 1.3 Flutter ↔ native handoff

New `MethodChannel('com.edde746.plezy/theater3d')`, owned by a new
`lib/quest/theater3d_bridge.dart`:

| Direction | Method | Payload | Purpose |
|---|---|---|---|
| Dart → native | `open` | `{ uri, headers, positionMs, audioTrackId, subtitleTrackId, stereoMode, shaderStrength }` | Launches `Theater3DActivity` with everything needed to resume the exact session |
| native → Dart | `onExit` (event channel) | `{ positionMs }` | Fired when the user exits theater mode; Dart seeks the flat mpv player to `positionMs` and resumes |
| native → Dart | `onError` (event channel) | `{ reason }` | Panel init failed (e.g. Spatial runtime unavailable) — Dart shows a snackbar and never opens the Activity, or force-finishes it if already open |

`VideoPlayerScreenState` pauses (not disposes) its own mpv session on `open`,
holding position/tracks, and resumes it from `onExit`'s `positionMs` — same
pattern already used for the existing PiP-mode pause/resume path
(`_pipService` handling in `video_controls.dart`), reused rather than
invented.

### 1.4 Decode path inside the theater Activity

- `Theater3DPanel`'s `surfaceConsumer` receives a plain Android `Surface`
  from the Spatial SDK.
- That `Surface` is handed to a **second** `MpvPlayerCore` instance (the
  flat-panel one stays paused, not torn down) — no ExoPlayer migration
  required, confirmed against `PlayerSurfaceHost.kt`'s existing
  `createVideoSurface` abstraction, which already targets an arbitrary
  `Surface`.
- `GpuVoPolicy` already forces `vo=gpu` whenever shaders are attached
  (`REASON_SHADERS`) — Phase 2's shader triggers this automatically, no new
  native logic needed here.

### 1.5 Stereo signal

`StereoModeResolver` maps the user's selected mode to
`MediaPanelRenderOptions.stereoMode`:

| `ThreeDMode` (Dart) | `StereoMode` (Spatial SDK) | When used |
|---|---|---|
| `off` | `None` | Flat playback — theater mode isn't entered at all |
| `sbs` | `LeftRight` | User forces SBS, or auto-detect matches `_SBS`/`_HSBS`/2×-width heuristics |
| `ou` | `UpDown` | User forces OU, or auto-detect matches `_OU`/`_TAB`/2×-height heuristics |
| `synthetic` | `LeftRight` | Phase 2's heuristic-depth shader always packs SBS |

### Phase 1 file list

| File | Change |
|---|---|
| `android/theater3d/build.gradle.kts` | new |
| `android/theater3d/src/main/AndroidManifest.xml` | new — declares `Theater3DActivity` only, no VR intent on `MainActivity` |
| `android/theater3d/src/main/kotlin/.../Theater3DActivity.kt` | new |
| `android/theater3d/src/main/kotlin/.../Theater3DPanel.kt` | new |
| `android/theater3d/src/main/kotlin/.../StereoModeResolver.kt` | new |
| `android/theater3d/src/main/kotlin/.../Theater3DBridge.kt` | new |
| `android/settings.gradle.kts` | `include(":theater3d")` guarded by `System.getenv("THEATER_MODE")`, same idiom as `:quest`/`:selfupdate` |
| `android/app/build.gradle.kts` | wire `THEATER_MODE` env var alongside existing `QUEST`/`AMAZON` blocks |
| `lib/quest/theater3d_bridge.dart` | new — MethodChannel + EventChannel wrapper |
| `QUEST_BUILD.md` | new build-flag row + a short "Theater mode" section |

---

## Phase 2 — Heuristic 2D→3D shader + player UI (3-5 days, depends on Phase 1)

**Status: shipped 2026-09-09** — all five open decisions below were
resolved using the plan's own stated defaults; see the changelog entry at
the bottom for what was built, what deviated from the literal plan text
(and why), and what still needs an on-device pass.

### 2.1 GLSL shader: heuristic depth + SBS pack

New asset `assets/shaders/pseudo3d/Pseudo3DSbs.glsl`, following the existing
`//!HOOK` asset format used by ArtCNN/NVScaler:

```glsl
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
```

This is the **heuristic** tier from the research report, deliberately — no
model inference inside mpv's shader stage. `strength` is a real mpv
user-shader `//!PARAM`, so unlike `ambient_lighting_service.dart`'s
regenerate-on-change approach, this one can expose a live-updating uniform
via `change-list glsl-opts` if mpv's version in use supports param overrides;
if not, fall back to the regenerate-and-re-append pattern already proven
there. Confirm which at implementation time — a `//!PARAM` slider is strictly
nicer UX (drag the strength slider during playback with no re-append
stutter) if the pinned mpv build supports it.

### 2.2 Data model

```dart
// lib/models/shader_preset.dart — add alongside existing preset configs
enum ThreeDMode { off, auto, sbs, ou }

class ThreeDConfig {
  final ThreeDMode mode;
  final double strength; // 0.0-1.0, only meaningful for synthetic conversion
  const ThreeDConfig({required this.mode, required this.strength});
  // toJson/fromJson mirroring NVScalerConfig/ArtCNNConfig's shape
}
```

### 2.3 Persistence

```dart
// lib/services/scoped_player_prefs.dart — alongside boxFitMode
static final threeDMode = ScopedPlayerPref<int>._(
  'three_d_mode', SettingsService.threeDModeScope, SettingsService.defaultThreeDMode, _decodeThreeDMode);
static final threeDStrength = ScopedPlayerPref<double>._(
  'three_d_strength', SettingsService.threeDModeScope, SettingsService.defaultThreeDStrength, _decodeDouble);
```

`SettingsService` gets `defaultThreeDMode` (`Pref<int>`, default `ThreeDMode.off.index`),
`defaultThreeDStrength` (`Pref<double>`, default `0.5`), and
`threeDModeScope` (`EnumPref<PlayerSettingScope>`, default `.title` — see
Open Decisions below on whether title-scope is the right default). Both prefs
added to the master registry list per the `boxFitMode` template.

### 2.4 Auto-detect (feeds `ThreeDMode.auto`)

New `lib/utils/stereo_source_detector.dart`:
- Filename heuristics: `_SBS`/`_HSBS`/`_Half-SBS` → `sbs`; `_OU`/`_TAB`/`_Half-OU` → `ou` (case-insensitive, matches the convention every VR player already uses per the research pass).
- Fallback: source aspect ratio exactly 2× the display's expected ratio (e.g. a 3840×1080 stream where metadata reports a 16:9 program) → `sbs`; equivalent 2×-height check → `ou`.
- No match → treat as flat 2D; `ThreeDMode.auto` then means "run the synthetic shader," not "do nothing."

### 2.5 Player UI wiring

| File | Change |
|---|---|
| `lib/widgets/video_controls/widgets/track_chapter_controls.dart:356-372` | Replace the fullscreen button block with a 3D button: `icon: Symbols.view_in_ar_rounded`, `isActive: state.is3DActive`, `checked: state.is3DActive`, `onPressed: state.onOpen3DMenu`. Visibility gate changes from `isDesktop` (OS-level) to a new `Theater3DBridge.isAvailable` check (Quest + `THEATER_MODE` build only) rather than any desktop condition — this button simply doesn't exist on non-Quest builds. |
| `lib/widgets/video_controls/models/track_controls_state.dart:38,46` | `isFullscreen`/`onToggleFullscreen` → `is3DActive` (bool) / `onOpen3DMenu` (`VoidCallback?`). Fullscreen's own fields are **removed**, not kept alongside — Quest never had a working fullscreen concept to preserve, and the desktop fullscreen button/handler continue to exist for desktop builds unchanged (this button was never rendered together with the 3D one; they're mutually exclusive per platform). |
| `lib/widgets/video_controls/parts/track_controls.dart:155-210` | Build `is3DActive`/`onOpen3DMenu` from a new `_threeDConfig` field + a handler that calls `OverlaySheetController.of(context)` to open `VideoSettingsSheet` pre-navigated to `_SettingsView.threeD`. |
| `lib/widgets/video_controls/sheets/video_settings_sheet.dart` | Add `_SettingsView.threeD` to the enum (line 43); add `_buildThreeDView()` modeled on `_buildZoomView()` (mode list with checkmarks) plus a `Slider` row modeled on `volume_control.dart`'s `_buildVolumeSlider()` for strength; wire into the view switch. |
| `lib/services/shader_service.dart` | `applyPreset()` gains a branch appending `Pseudo3DSbs.glsl` when `ThreeDConfig.mode != off` and the source isn't already-3D-passthrough (passthrough content skips the shader entirely and only sets `stereoMode` — no need to synthesize depth for material that already has real parallax). Ordered before `_reappendAmbientLighting`, same as every other preset today. |
| `lib/services/shader_asset_loader.dart` | Register `Pseudo3DSbs.glsl` alongside the existing NVScaler/ArtCNN/Anime4K entries in `getShadersForPreset()`. |
| `lib/quest/quest_platform.dart` | Gains the first real behavioral read of `QuestPlatform.isQuest` in the codebase — gates the 3D button's existence and default mode. |

### Phase 2 file list

| File | Change |
|---|---|
| `assets/shaders/pseudo3d/Pseudo3DSbs.glsl` | new |
| `lib/models/shader_preset.dart` | + `ThreeDMode`, `ThreeDConfig` |
| `lib/services/scoped_player_prefs.dart` | + `threeDMode`, `threeDStrength` |
| `lib/services/settings_service.dart` | + 3 new `Pref`s, registry entries |
| `lib/services/shader_service.dart` | + pseudo-3D branch in `applyPreset()` |
| `lib/services/shader_asset_loader.dart` | + shader registration |
| `lib/utils/stereo_source_detector.dart` | new |
| `lib/widgets/video_controls/widgets/track_chapter_controls.dart` | fullscreen → 3D button |
| `lib/widgets/video_controls/models/track_controls_state.dart` | field swap |
| `lib/widgets/video_controls/parts/track_controls.dart` | state wiring |
| `lib/widgets/video_controls/sheets/video_settings_sheet.dart` | new view |
| `test/quest/` | new unit tests, see Testing below |

---

## Phase 3 — ML-based monocular depth (explicitly deferred)

Not scoped here. After Phase 1+2 ship and the heuristic shader's quality is
validated against real usage, a follow-on plan should separately decide:
model choice (Depth-Anything-V2-small class), on-device inference path
(NNAPI vs. GPU delegate), frame-rate/resolution budget on XR2 Gen2, and
temporal-stability strategy (naive per-frame inference will flicker without
smoothing). Do not fold this into the v1 estimate — it is its own project.

---

## Testing & verification plan

- **Unit (Dart):** `ThreeDConfig` JSON round-trip; `stereo_source_detector.dart` filename/aspect-ratio cases (SBS/HSBS/OU/TAB/no-match); `ScopedPlayerPrefs.threeDMode`/`.threeDStrength` resolve/write round-trip at each `PlayerSettingScope`; `StereoModeResolver`'s mode→`StereoMode` mapping table (pure function, no device needed).
- **Widget:** `VideoSettingsSheet`'s new `_buildThreeDView()` — selecting a mode updates the checkmark and persists; dragging the strength slider updates the displayed percentage.
- **On-device (Quest 3, manual — no automated harness exists for Spatial SDK panels today):**
  - Phase 0's 10-launch orientation/handback check (gating criterion, see above).
  - Play an already-3D `_SBS` tagged file end-to-end: theater mode opens, real stereo depth is visible, exiting resumes the flat player at the correct position.
  - Play an ordinary flat file with `ThreeDMode.auto`/synthetic strength at 0%, 50%, 100%: confirm 0% looks flat (sanity check the shader's identity case), and strength visibly scales the effect.
  - Kill the app while theater mode is open; confirm relaunch doesn't leave the flat player stuck paused with stale position.
- **No project-wide test-suite claims beyond what's touched** — this plan doesn't run `flutter test` project-wide as "proof"; it runs the specific new/changed tests above plus the on-device checklist.

---

## Effort estimate

| Phase | Estimate | Depends on |
|---|---|---|
| 0 — spike | 1-2 days | — |
| 1 — theater mode + passthrough | 1-2 weeks | Phase 0 pass |
| 2 — shader + UI | 3-5 days | Phase 1 |
| **Total v1** | **~2.5-3.5 weeks** | |
| 3 — ML depth | separate project, unscoped | v1 shipped + validated |

---

## Open decisions (need your call before implementation starts)

1. **Icon.** Plan assumes `Symbols.view_in_ar_rounded` for the 3D button. Alternatives: `Symbols.3d_rotation_rounded`, a custom glyph. Any of these swap in as a one-line change.
2. **Default persistence scope.** Plan defaults `threeDModeScope` to per-title (a nature documentary and a screen recording want different defaults) — confirm, or fall back to global like `boxFitMode`.
3. **Auto-detect in v1 or v2.** Filename/aspect-ratio auto-detect (§2.4) is cheap and can ship in Phase 2; if you'd rather ship "Off/SBS/OU/Synthetic" as an explicit user choice first and add Auto later, that trims Phase 2 slightly.
4. **Default strength value.** Plan defaults to `0.5`; this is a pure taste call best made after seeing the shader on real footage in Phase 2.
5. **Theater-mode entry affordance beyond the button.** Should exiting theater mode (in-headset) be a dedicated in-scene button only, or also bound to the physical Oculus/Meta button long-press? Plan assumes in-scene button only for v1.

---

## Changelog

- **2026-09-08 — Phase 0 spike: PASS on Quest 3, two real platform bugs found
  and fixed along the way.** Device: Quest 3, wireless adb. 10/10 cold
  launches (`am force-stop` + `am start`, independent per iteration) showed
  clean `onCreate → onSceneReady → drawTestPattern → canvas posted` in
  logcat with zero `FATAL`/`AndroidRuntime` crashes. Panel orientation
  confirmed **right-side-up** by direct visual check on-device (red/blue
  split, "L"/"R" labels, "BOTTOM EDGE" marker at the bottom) — the
  Holoplex upside-down regression did **not** reproduce here. Two unrelated
  bugs blocked the panel from appearing at all before these fixes:
  1. **Missing `com.oculus.intent.category.VR` on the theater Activity.**
     Without it Horizon OS never grants the activity an immersive
     compositor session — the Kotlin scene code runs to completion
     (`onSceneReady`/`drawTestPattern` logs fire normally) but nothing
     visually composites; the wearer just keeps seeing whatever 2D panel
     was already focused. This cost the most diagnosis time because every
     signal *except the actual pixels on the headset* said success.
     `adb exec-out screencap` did **not** reliably surface this — it kept
     showing the flat host panel even while logcat proved the theater
     Activity was alive and drawing; the physical headset was the only
     reliable oracle. Fix: add an `<intent-filter>` with
     `<category android:name="com.oculus.intent.category.VR" />` (plus
     `MAIN`) to the theater Activity's manifest entry.
  2. **Floor-level panel placement.** `scene.getViewerPose()` called
     synchronously inside `onSceneReady()` returned an exact zeroed pose
     (`viewerPose.t=(0.0, 0.0, 0.0)`, confirmed via logging on-device, not
     inferred) before head tracking had populated a real sample, so a panel
     placed at `viewerPose.t + forward*1.5` landed on the floor. Fix:
     fall back to a standing eye-height (`1.6f`) whenever the reported head
     height is implausibly low (`< 0.5f`). User-confirmed placement is now
     close to eye level ("a bit too high", acceptable — will be user-movable
     in a later phase anyway, not a Phase 0 blocker).
  - **XML pitfall hit while fixing #1**: a `--` inside an XML comment body
     (not just at the very end) is illegal and silently breaks manifest
     parsing — matches the same landmine Holoplex's postmortem documented.
  - **System keyboard/dictation mic confirmed intact** (the specific
    Holoplex regression): user tested typing and mic-dictation from a text
    field on-device immediately after the 10x theater-session churn loop
    — both worked normally. Holoplex's regression did **not** reproduce here.
  - **Exit criterion MET, unconditionally: 10/10 clean launches, correct
    orientation, clean handback, no lost keyboard/dictation capability.**
    Phase 0 PASSES. Phase 1 is unblocked to start (pending the user's
    go-ahead — not started automatically).
  What did get done and verified:
  - Attempted the plan's original design (`:theater3d_spike` as a normal
    `android/` subproject). **Hard blocker found**: `com.meta.spatial.plugin:0.13.2`
    is binary-incompatible with this repo's pinned Kotlin Gradle Plugin
    2.4.10 (`BuildTimeMetric`/`BuildPerformanceMetric` class-hierarchy
    mismatch) — Gradle configuration fails outright, and there is no way to
    scope a different KGP version to one subproject of a single build. This
    is a **new blocker for Phase 1.1**, independent of the on-device result
    — see the correction inline in Phase 1.1 above and
    `android/theater3d_spike/README.md`.
  - Rebuilt the spike as a fully standalone Gradle project at
    `android/theater3d_spike/` (own wrapper pinned to Gradle 9.4.1, AGP
    8.11.1, Kotlin 2.2.0 — Meta's documented tested combo for SDK 0.13.2).
    `./gradlew :app:assembleDebug` succeeds; produces a real APK
    (`com.edde746.plezy.theater3dspike`) with a plain 2D `MainActivity`
    that `startActivity()`s an `AppSystemActivity`
    (`TheaterSpikeActivity`) registering one `ReadableVideoSurfacePanelRegistration`
    panel, fed a Canvas-drawn red/blue "L"/"R"-labelled test pattern with a
    `BOTTOM EDGE` marker, placed via `scene.getViewerPose()` (avoids the
    documented spawn-behind-user trap). Auto-finishes after 6s (also
    accepts an `ACTION_FINISH` broadcast) so a scripted `adb` loop can drive
    all 10 iterations headlessly via `adb exec-out screencap`, per
    Holoplex's proven verification technique.
  - Every Spatial SDK call was checked against the real 0.13.2 API via
    `javap` on the resolved AARs (not docs alone) and 3 real bugs were
    found and fixed this way: `StereoMode` is `com.meta.spatial.runtime`,
    not `.toolkit`; `Quaternion` has no `Vector3`-euler constructor (use
    `Quaternion(x, y, z)` degrees directly); the docs' `ksp("com.meta.spatial.plugin:...")`
    coordinate has no real KSP processor in it and isn't needed for a
    component-free panel anyway.
  - **Phase 0 closed out.** `android/theater3d_spike/` deleted (THROWAWAY
    per its own header, never merged); its findings live entirely in this
    changelog entry and the Phase 1.1 correction above. `android/_kgp_probe/`
    (Phase 1 KGP-blocker investigation, not part of the Phase 0 spike
    itself) is left in place — see Phase 1.1 for why it stays until the
    real `:theater3d` module lands.

- **2026-09-08 — Phase 1 shipped: native module, headless mpv session,
  Flutter bridge; verified on Quest 3.** `android/_kgp_probe/` deleted (its
  question is answered by `:theater3d` itself building and running).
  - **`android/theater3d`** (new Gradle module, `THEATER_MODE`-gated):
    `Theater3DActivity` (thin `AppSystemActivity` host, one video panel +
    a grab-free play/pause/exit `ViewPanelRegistration`, the Phase 0
    eye-height fallback and `VR` intent category carried over verbatim),
    `Theater3DPanel` (`ReadableVideoSurfacePanelRegistration`, 1920×1080
    fixed compositor buffer, 2.4×1.35m quad), `StereoModeResolver`
    (`off`/`sbs`/`ou` → `StereoMode`, 4 passing unit tests), and
    `Theater3DBridge` (a same-process, **Flutter-free** static registry
    handing a `TheaterOpenRequest` + `Listener` to the Activity — plan's
    original "Theater3DBridge.kt is the MethodChannel handler" wording
    was corrected in code: a Flutter dependency inside a library module
    every other native-player integration in this repo keeps Flutter-free
    was the wrong shape, so the actual channel handler moved to
    `android/app/src/theater3d/`, matching `MpvPlayerPlugin.kt`/
    `ExoPlayerPlugin.kt`'s existing boundary).
  - **`android/app/src/theater3d`** (new source set, compiled only when
    `THEATER_MODE` is set): `Theater3DChannel.kt` owns
    `MethodChannel('com.edde746.plezy/theater3d')` +
    `EventChannel('.../events')`; `TheaterMpvSession.kt` drives a second,
    **headless** `MpvPlayerCore` against the panel's raw compositor
    `Surface`, replaying `player_native.dart`'s exact `open()` sequence
    natively (the same `change-list http-header-fields` dance for
    comma-bearing header values, `sid=no`/`secondary-sid=no` pre-load
    defaults, post-load unpause) since this is structurally a second
    native mpv session, just without a MethodChannel round trip in front
    of it. `MainActivity.kt` reaches `Theater3DChannel` only reflectively
    (`Class.forName`) so it keeps compiling unchanged on every non-Quest
    target, where the class does not exist on the classpath at all.
  - **`MpvPlayerCore.kt` grew a `headless` constructor parameter** that
    skips every Activity-window concern (the `FrameLayout` container, both
    `SurfaceView`s, `PlayerSurfaceHost`'s content-view attach, the
    Flutter-overlay layout listener) and two new public methods,
    `attachHeadlessSurface`/`detachHeadlessSurface`, which feed a
    compositor-owned `Surface` through the exact same
    `surfaceCreated`/`surfaceChanged`/`surfaceDestroyed` pipeline every
    SurfaceView-backed session already goes through, via a minimal
    `SurfaceHolder` shim (only `getSurface()` is real; every other member
    throws, since nothing else on that pipeline is reachable without a
    real Android View). Verified not to affect the default build: default
    and `THEATER_MODE=1` `:app:compileDebugKotlin` both pass.
  - **`lib/quest/theater3d_bridge.dart`** (new): typed Dart wrapper —
    `TheaterStereoMode` enum, `TheaterExitEvent`/`TheaterErrorEvent`,
    `Theater3DBridge.open()`/`.onExit`/`.onError` demuxed from one raw
    `EventChannel` stream by an `event` tag. 7 passing tests
    (`test/quest/theater3d_bridge_test.dart`) cover the wire payload shape,
    defaults, a `PlatformException` surfacing cleanly, and stream demuxing.
  - **Two real XML bugs found and fixed** writing the manifests, both the
    exact `--`-inside-an-XML-comment landmine the Phase 0 entry above
    already named — hit again anyway, this time in
    `android/theater3d/src/main/AndroidManifest.xml` and a new comment
    added to `android/app/src/main/AndroidManifest.xml`, caught only by an
    actual `assembleDebug` (manifest merging never runs during a bare
    `compileDebugKotlin`, which is why compiling first didn't catch it).
  - **A real minSdk conflict**, not anticipated by the plan: `:theater3d`
    declares `minSdk 29` (Spatial SDK's floor) but the app's own `minSdk`
    is pinned to `25` for Fire OS 6.x — raising the app floor was not an
    option, so `android/app/src/main/AndroidManifest.xml` gained a
    `<uses-sdk tools:overrideLibrary="com.edde746.plezy.theater3d">`,
    inert on every build that doesn't put `:theater3d` on the classpath.
  - **Verified on the user's real Quest 3**, in place over the existing
    signed install (release-signed `THEATER_MODE=1 QUEST=1` build,
    `versionCode` bumped so the update installed without wiping app data):
    `MainActivity` still launches/resumes as an ordinary `QUEST=1` build
    with no VR intent category anywhere on it (non-negotiable #0 holds on
    real hardware, not just by manifest inspection), and
    `Theater3DActivity` is registered with `com.oculus.intent.category.VR`
    and correctly rejects an external `am start` with a `SecurityException`
    (`android:exported="false"` enforced by the OS). No crashes in logcat.
  - **What's deliberately not done**: no player-UI trigger. Nothing calls
    `Theater3DBridge.open()` yet — that, plus the `VideoPlayerScreenState`
    pause/resume-around-theater-mode wiring PLAN_3D.md 1.3 describes, is
    Phase 2's "Player UI wiring" (2.5), not Phase 1's file list. This also
    means the full open → real per-eye stereo → exit → resume path is
    unverified end-to-end on-device; only the pieces reachable without
    that trigger were.

- **2026-09-09 -- Phase 2 shipped: 3D button, settings sheet, heuristic
  shader, prefs, auto-detect.** All five open decisions resolved using the
  plan's own stated defaults (icon `Symbols.view_in_ar_rounded`, `.title`
  persistence scope, auto-detect shipped in v1, default strength `0.5`,
  in-scene exit affordance only -- no new Dart work needed there, it is
  native and already shipped in Phase 1).
  - **Player UI**: `track_chapter_controls.dart`'s dead fullscreen button is
    replaced by the 3D button on `Theater3DBridge.isAvailable` builds; it
    opens a new `_SettingsView.threeD` in `VideoSettingsSheet` (mode list
    with checkmarks modeled on `_buildZoomView()`, strength slider modeled
    on `volume_control.dart`'s `_buildVolumeSlider()`, live preview +
    commit-on-release persistence).
  - **Deviation from the literal plan text, and why**: the plan says
    `isFullscreen`/`onToggleFullscreen` are "removed, not kept alongside."
    Taken literally that would delete desktop fullscreen's only wiring path.
    Resolution: `TrackControlsState.isFullscreen`/`.onToggleFullscreen` *are*
    removed (renamed to `is3DActive`/`onOpen3DMenu`, nothing kept alongside
    on that model), but the desktop fullscreen button in
    `track_chapter_controls.dart` now reads `FullscreenStateManager()`
    directly via its own `ListenableBuilder` -- a pattern this file already
    used for `SleepTimerService` a few lines above -- instead of routing
    through `TrackControlsState` at all. Desktop fullscreen behavior is
    unchanged; only its plumbing moved.
  - **Data model**: `ThreeDMode`/`ThreeDConfig` added to
    `lib/models/shader_preset.dart`, mirroring `NVScalerConfig`'s freezed
    shape exactly (JSON round-trip covered by
    `test/models/shader_preset_test.dart`).
  - **Persistence**: `ScopedPlayerPrefs.threeDMode`/`.threeDStrength` added
    to `scoped_player_prefs.dart`, `defaultThreeDMode`/`defaultThreeDStrength`/
    `threeDModeScope` (default `.title`) added to `settings_service.dart`,
    both mirroring `boxFitMode`'s existing template and registered in the
    master pref list.
  - **Shader**: `assets/shaders/pseudo3d/Pseudo3DSbs.glsl` added verbatim
    from section 2.1, registered in `shader_asset_loader.dart`. Because
    `ThreeDConfig` is explicitly orthogonal to `ShaderPresetType` (per this
    plan's own 2.2 data model -- there is no `ShaderPresetType.pseudo3d`),
    `getShadersForPreset()` gained an optional `threeDConfig` parameter that
    appends the pseudo-3D shader after whatever the base preset resolves to
    (including `none`), and `shader_service.dart`'s `applyPreset()` threads
    it through before `_reappendAmbientLighting`, skipping it entirely for
    already-3D passthrough sources. A real bug was found and fixed along the
    way: `getShadersForPreset()`'s empty-`shaderPaths` early return would
    have silently dropped a bare pseudo-3D shader when the base preset was
    `none` -- covered by a regression test in `shader_service_test.dart`.
  - **Auto-detect**: `lib/utils/stereo_source_detector.dart` (new) covers
    the filename tags (`_SBS`/`_HSBS`/`_Half-SBS`/`_OU`/`_TAB`/`_Half-OU`,
    case-insensitive) and the aspect-ratio doubling/halving fallback from
    section 2.4, filename taking precedence, both covered by
    `test/utils/stereo_source_detector_test.dart`.
  - **A real gap found and closed**: `QuestPlatform.ensureInitialized()` was
    never called anywhere in the app (confirmed by grep before this phase),
    so `QuestPlatform.isQuest` -- and therefore `Theater3DBridge.isAvailable`
    -- would have stayed `false` forever, even on real Quest hardware. Now
    called from `lib/main.dart`'s existing `deviceCapabilities` startup
    gate, alongside `TvDetectionService`/`DevicePerformance`/
    `VideoDecodeCapabilities` -- the plan's own anticipated "first real
    behavioral read of `QuestPlatform.isQuest`."
  - **A second real gap found and closed**: `Theater3DBridge.isAvailable`
    needs a synchronous, compile-time-influenced check usable inside a
    `build()` method (Dart cannot probe platform-channel existence without
    invoking it). Added `kTheaterModeBuild = bool.fromEnvironment('THEATER_MODE_BUILD')`,
    mirroring the existing `kQuestBuild` idiom, so `isAvailable =
    QuestPlatform.isQuest && kTheaterModeBuild`. This is a **second,
    separate dart-define** from the native `THEATER_MODE=1` Gradle env var
    -- `QUEST_BUILD.md`'s theater-mode build command now passes both;
    omitting the dart-define compiles a `THEATER_MODE=1` build fine but
    silently hides the button.
  - **Verification**: `dart analyze` on every changed/created file -- no
    issues. `dart test` on every new/changed suite plus the directly
    affected pre-existing suites (`video_controls_test.dart`,
    `video_settings_sheet_test.dart`, `track_sheet_test.dart`) -- 187 tests,
    all passed, no regressions.
  - **Not yet done**: on-device verification. The full
    open -> real per-eye stereo -> exit -> resume path through this new
    button is still unverified on a physical Quest 3 -- Phase 1's device
    pass predates this trigger existing. A `THEATER_MODE=1 QUEST=1
    --dart-define=THEATER_MODE_BUILD=true` release build install-over-existing
    on the same device is the next concrete step before calling Phase 1+2
    fully done end-to-end.

- **2026-09-09 -- End-to-end on-device verification: real per-eye stereo
  confirmed working. Five real bugs found and fixed, in the order hit:**
  1. **`Theater3DBridge.open()` had zero callers.** Phase 2 shipped the 3D
     button/settings sheet but never wired it to the bridge. Fixed:
     `lib/screens/video_player/parts/theater3d.dart` (new) launches theater
     mode from the settings sheet's mode selection, reusing the flat
     player's already-open source URL/headers cached at the
     `_openMediaOnPlayer` call site.
  2. **Release resource shrinker stripped `@drawable/dot_cursor`**
     (loaded by class name via `BitmapFactory.decodeResource`, invisible to
     R8's static analysis) -- crashed `Theater3DActivity.onCreate`. Fixed
     with `android/theater3d/src/main/res/raw/keep.xml`
     (`tools:keep="@drawable/dot_cursor"`).
  3. **`kotlin-reflect` missing from `:theater3d`'s runtime classpath.**
     `SystemDAG`'s topological sort reflects on registered system classes;
     without it every lookup silently returns the "(Kotlin reflection is
     not available)" stub and the sort fails as if no systems were
     registered, even though they were. Fixed: added
     `kotlin-reflect:2.4.10` to `android/theater3d/build.gradle.kts`.
  4. **`request`/`listener` set after `super.onCreate()`.**
     `AppSystemActivity.onCreate()` calls `registerPanels()` synchronously
     as part of its own body (confirmed via `javap` bytecode, called
     twice); setting the pending session's fields after that call meant
     `registerPanels()`'s `request ?: return emptyList()` guard always saw
     `null` and registered zero panels, crashing with "No panel creator
     found for key". Fixed by reordering in `Theater3DActivity.onCreate()`.
  5. **The real blocker: wrong panel placement axis, wrong SpatialFeature
     hook, and a stale unimplemented mode -- three separate bugs that
     together produced "registers fine, spawns fine, zero exceptions
     anywhere, but absolutely nothing renders, not even the independent
     ViewPanelRegistration controls panel, no matter which way the wearer
     turns."** Root-caused only by recovering the (deleted, never-committed)
     Phase 0 spike's source from this machine's local agent session
     history (`~/.omp/agent/sessions/`) after every other on-device
     hypothesis (mediacodec vo, panel registration type, input system
     type, DV decoder options) was tested and ruled out:
     - **`Vector3.Forward` is `(0, 0, +1)` in this SDK** (confirmed via
       `javap` bytecode of `Vector3`'s static initializer), i.e. **+Z is
       forward**, not the more common -Z convention. `Theater3DActivity`
       placed both panels at `Vector3(0, eyeHeight, -PANEL_DISTANCE_M)` --
       exactly the "naive fixed offset spawns the panel BEHIND the user"
       trap the spike's own (deleted) source comment warned about by name.
       Fixed: flipped to `+PANEL_DISTANCE_M`.
     - **`VRFeature` belongs on `VrActivity.registerFeatures()`**, a
       separate base-class hook from `AppSystemActivity`'s own
       `registerSystemFeatures()` (confirmed via `javap` on both
       `meta-spatial-sdk-0.13.2` and `meta-spatial-sdk-toolkit-0.13.2`).
       The working spike used `registerFeatures() = listOf(VRFeature(this))`
       exactly, matching the official `MediaPlayerSample`. An earlier pass
       this session had `VRFeature` on `registerSystemFeatures()` instead --
       it compiled, didn't crash, panels spawned with valid entity ids and
       the video surface consumer fired, but nothing ever reached the real
       render/compositor pipeline. Fixed by moving it to the correct hook.
     - **`vo=mediacodec`'s hardware-upload path fails against the Spatial
       SDK panel's compositor-owned `Surface`** regardless of
       `VideoSurfacePanelRegistration` vs `ReadableVideoSurfacePanelRegistration`
       -- `[autoconvert] Failed to create HW uploader for format yuv420p` /
       `Could not initialize video chain`, confirmed on-device with both.
       `TheaterMpvSession`'s headless `MpvPlayerCore` now constructs with
       `hardwareDecoding = false` (selects `vo=gpu,gpu-next` from the
       start), which decodes and renders cleanly. Switched the panel
       registration to plain `VideoSurfacePanelRegistration` (matching the
       official sample) while investigating; left in place since it's the
       now-proven-working configuration -- Phase 2's shader post-process
       will need a different mechanism against this registration type,
       since it depended on the Readable variant's surface semantics.
     - **`StereoModeResolver.resolve("synthetic")` threw** --
       `ThreeDMode.auto`'s fallback when filename/aspect-ratio detection
       finds nothing resolves to `TheaterStereoMode.synthetic` on the Dart
       side, but the resolver only ever handled `off`/`sbs`/`ou`; its own
       doc comment admitted `synthetic` was "intentionally absent" pending
       a Phase 2 native hookup that never happened. This crashed
       `registerPanels()` immediately for `auto` mode. Fixed: `synthetic`
       now resolves to `StereoMode.LeftRight` (same as `sbs` -- the actual
       heuristic shader pass itself is still not wired into the native
       theater path; this only stops the crash and gives `auto` mode the
       same raw-SBS-split behavior as manually selecting `sbs`).
  - **Diagnostic technique that closed this out**: added explicit
    success-path `Log.i` calls through `registerPanels()`/`onSceneReady()`
    (entity ids, surface-consumer firing) since both previously only had
    failure-path logging -- proved panels/entities were being created
    successfully with zero exceptions, which is what made "nothing renders
    despite zero errors anywhere" legible as a placement/feature-hook bug
    rather than a crash to chase further.
  - **Verified on-device, by the user, end-to-end**: theater panel and
    controls panel both render at the correct position; per-eye stereo
    compositor split confirmed genuine via an eye-closing test (closing
    one eye shows only that eye's half); `auto`/`sbs`/`ou` modes all open
    theater mode without error. Real stereo *depth* (as opposed to the
    split mechanism) was **not** confirmable at this point -- every test
    file used turned out not to be genuine frame-packed SBS/OU source
    data (plays back as an ordinary flat video with no doubling in the
    regular 2D player, which is the tell -- true frame-packed 3D looks
    visibly squished/doubled even in a non-stereo-aware player). **Closed
    2026-09-11: user-confirmed on-device with genuine frame-packed SBS 3D
    masters -- `sbs` and `auto` both display correctly.** See the
    2026-09-11 entry below.
  - **Not yet done**: Phase 2's heuristic `Pseudo3DSbs.glsl` shader is
    still not wired into the native theater path at all -- `auto` mode on
    genuinely flat content currently does a raw (incorrect) SBS split of
    the flat frame rather than applying the heuristic shader, since
    `TheaterMpvSession`'s native `open()` sequence has no shader-chain
    equivalent of the flat player's `getShadersForPreset()`. Scoping that
    is unstarted -- and per the 2026-09-11 entry below, it is now the
    **sole** remaining item on the feature's headline claim.

- **2026-09-11 -- Real-stereo passthrough confirmed on-device with genuine
  frame-packed SBS source.** User tested actual SBS 3D masters on the Quest
  3; both `sbs` and `auto` display correctly. This closes the last
  verification gap in the Phase 1 passthrough path -- the earlier
  2026-09-09 pass could only confirm the *split mechanism* (eye-closing
  test) because every file available then decoded as ordinary flat video.
  - **Net state of the feature**: genuine 3D sources (frame-packed SBS/OU)
    work end-to-end. `auto` detect -> `sbs` on a real SBS file is correct
    behavior and the raw compositor split is exactly right for it.
  - **What this does *not* validate**: the heuristic 2D->3D tier. The
    `Pseudo3DSbs.glsl` shader is still never executed on any path --
    confirmed by grep, none of the five `ShaderService.applyPreset` call
    sites (`visual_effects_controller.dart:65/92`, `shader_service.dart:140`,
    `track_controls.dart:121`, `video_settings_sheet.dart:1349/1379/1402`)
    passes `threeDConfig`, and `android/app/src/theater3d/` contains zero
    `glsl-shaders` references. Consequence, unchanged from 2026-09-09:
    `auto` mode on **flat** content still does a raw SBS split of a flat
    frame -- double vision, not synthesized depth (the same symptom the
    user originally reported for non-3D video). The API surface for the
    fix exists and is unit-tested; only the native theater-path wiring is
    missing.
  - **Sharpest single indicator of that gap**: `shaderStrength` is plumbed
    all the way across the boundary -- `theater3d.dart` -> 
    `theater3d_bridge.dart` -> `Theater3DChannel.kt`
    (`args["shaderStrength"]`) -> `Theater3DBridge.TheaterOpenRequest` --
    and then **dead-ends**: nothing in `TheaterMpvSession` reads it. The
    wire contract for a strength-controlled shader pass is complete and
    unused, so the remaining work is purely native: append the extracted
    `Pseudo3DSbs.glsl` path to the headless session's `glsl-shaders` list
    before/at load, and set its `strength` param from
    `request.shaderStrength`. Note the panel is now a plain
    `VideoSurfacePanelRegistration` (chosen 2026-09-09 so MediaCodec
    hwdec output works at all), so the shader must run inside mpv's own
    vo chain -- `MpvPlayerCore` already forces `vo=gpu,gpu-next` for the
    headless session, which is what makes a `glsl-shaders` append viable
    at all.
