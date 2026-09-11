package com.edde746.plezy.theater3d

import com.meta.spatial.runtime.StereoMode

/**
 * Maps the Dart-facing stereo mode string (see
 * [Theater3DBridge.TheaterOpenRequest.stereoMode]) to the Spatial SDK's
 * per-eye compositing mode ([MediaPanelRenderOptions.stereoMode] --
 * PLAN_3D.md 1.5).
 *
 * Real per-eye stereo comes entirely from this mapping: mpv decodes the
 * source's already-combined SBS/OU frame untouched into the panel's
 * Surface, and the *compositor* -- not mpv -- samples a different half per
 * eye according to the resolved [StereoMode]. `synthetic` (the heuristic
 * 2D->3D path) is no exception: its user shader packs synthesized depth as
 * an SBS pair, so it resolves to [StereoMode.LeftRight] exactly like `sbs`.
 * The difference between the two is entirely whether that shader ran --
 * [Theater3DBridge.TheaterOpenRequest.shaderPath] is set for `synthetic`
 * and null for `sbs`, and this mapping cannot and does not see it.
 *
 * Pure and device-free by design, per PLAN_3D.md's testing plan, so this
 * module's own JVM unit tests (StereoModeResolverTest) exercise it without
 * a Quest.
 */
object StereoModeResolver {
  fun resolve(mode: String): StereoMode = when (mode) {
    "off" -> StereoMode.None
    "sbs" -> StereoMode.LeftRight
    "ou" -> StereoMode.UpDown
    "synthetic" -> StereoMode.LeftRight
    else -> throw IllegalArgumentException("Unknown Theater3D stereo mode: '$mode'")
  }
}
