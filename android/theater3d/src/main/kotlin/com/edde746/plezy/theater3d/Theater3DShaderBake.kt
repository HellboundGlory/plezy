package com.edde746.plezy.theater3d

import java.util.Locale

/**
 * Pure shader-file policy for the theater's heuristic 3D pass: how a strength
 * value is written into a shader's source, and what that shader's file is
 * called.
 *
 * Lives here rather than beside its only caller (`TheaterMpvSession`, in
 * android/app's `theater3d` source set) so it is JVM-unit-testable without a
 * device or a Spatial runtime -- the same reason [StereoModeResolver] does. The
 * caller keeps the Android-side concerns (atomic file publication, mpv commands,
 * pruning), which cannot be tested here anyway.
 *
 * Nothing here writes files or knows about mpv: it is string policy only.
 */
object Theater3DShaderBake {
  /**
   * The `STRENGTH` literal `ShaderAssetLoader.materializePseudo3DShader` writes
   * on the Dart side (`assets/shaders/pseudo3d/Pseudo3DSbs.glsl` declares
   * `const float STRENGTH = <value>;` for exactly this reason).
   *
   * Two implementations of the substitution exist because the in-scene depth
   * control cannot round-trip through Flutter -- Dart bakes the initial value,
   * this re-bakes on change. `shader_asset_loader_test.dart` pins the asset's
   * shape and `Theater3DShaderBakeTest` pins this pattern, so a divergence
   * fails loudly instead of silently leaving the control inert.
   */
  private val STRENGTH_PATTERN = Regex("""(const\s+float\s+STRENGTH\s*=\s*)([0-9]*\.?[0-9]+)(\s*;)""")

  /**
   * Prefix for live strength shaders. One file per strength value, never
   * reused -- see [liveShaderName].
   */
  const val LIVE_SHADER_PREFIX = "Pseudo3DSbs_live_"

  /** Strength as it is written into the shader: two decimals, US locale. */
  fun format(strength: Double): String = String.format(Locale.US, "%.2f", strength)

  /**
   * Returns [source] with its `STRENGTH` literal set to [strength], or null when
   * the shader declares no such literal -- the caller logs and ignores the
   * change rather than publishing a shader identical to the previous one.
   *
   * Substitution is anchored to the literal, so a greedy rewrite cannot reach
   * the neighbouring tuning constants and silently change the depth model
   * rather than just its strength.
   */
  fun rewriteStrength(source: String, strength: Double): String? {
    val match = STRENGTH_PATTERN.find(source) ?: return null
    return source.replaceRange(match.range, match.groupValues[1] + format(strength) + match.groupValues[3])
  }

  /**
   * File name for a live shader baked at [value] (as returned by [format]).
   *
   * Distinct per value deliberately. mpv caches user shaders **by path**
   * (`load_cached_file` in video/out/gpu/video.c returns the body it first read
   * for a path it has already seen, and never re-reads it), so rewriting one
   * fixed file name and re-appending it re-parses the *original* source and the
   * change silently does nothing. That was an on-device bug: the depth slider
   * appeared inert after the first move.
   *
   * Kept distinct from the Dart-materialized template's name as well, since the
   * loader byte-verifies that one against the bundle and would rewrite it.
   */
  fun liveShaderName(value: String): String = "$LIVE_SHADER_PREFIX$value.glsl"

  /** Staging name for the atomic publish of [liveShaderName]. */
  fun liveShaderStagingName(value: String): String = "${liveShaderName(value)}.pending"

  /** Whether [fileName] is a live strength shader this policy owns. */
  fun isLiveShaderFile(fileName: String): Boolean =
    fileName.startsWith(LIVE_SHADER_PREFIX) && fileName.endsWith(".glsl")
}
