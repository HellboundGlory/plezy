package com.edde746.plezy.theater3d

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins [Theater3DShaderBake] -- the substitution that keeps the in-scene depth
 * control working, and the file naming that keeps mpv from serving it a cached
 * shader body.
 *
 * The pattern here must stay in lockstep with
 * `ShaderAssetLoader.materializePseudo3DShader` on the Dart side;
 * `shader_asset_loader_test.dart` pins the real asset this rewrites.
 */
class Theater3DShaderBakeTest {
  /** The shape `ShaderAssetLoader.materializePseudo3DShader` produces. */
  private val loaderShape = """
    //!HOOK MAIN
    const float STRENGTH = 0.50;
    const float DETAIL_GAIN = 3.0;
    vec4 hook() { return vec4(0.0); }
  """.trimIndent()

  @Test
  fun rewritesOnlyTheStrengthLiteral() {
    val baked = Theater3DShaderBake.rewriteStrength(loaderShape, 0.85)
    assertEquals(loaderShape.replace("STRENGTH = 0.50", "STRENGTH = 0.85"), baked)
    // The neighbouring constant must survive -- a greedy pattern would clobber
    // DETAIL_GAIN and change the depth model, not merely its strength.
    assertTrue(baked!!.contains("DETAIL_GAIN = 3.0"))
    assertEquals(1, baked.split("STRENGTH").size - 1)
  }

  @Test
  fun formatsToTwoDecimalsSoTheRewriteIsIdempotent() {
    // 0.999 would otherwise round to "1.00" and then keep drifting on re-save.
    val once = Theater3DShaderBake.rewriteStrength(loaderShape, 0.999)!!
    val twice = Theater3DShaderBake.rewriteStrength(once, 0.999)!!
    assertEquals(once, twice)
    assertTrue(once.contains("STRENGTH = 1.00"))
  }

  @Test
  fun handlesIntegerAndSpacingVariants() {
    assertTrue(Theater3DShaderBake.rewriteStrength("const float STRENGTH = 0.5;", 0.25)!!.contains("0.25"))
    assertTrue(Theater3DShaderBake.rewriteStrength("  const   float  STRENGTH =0.50 ;", 0.10)!!.contains("0.10"))
  }

  @Test
  fun returnsNullWhenTheShaderOffersNoStrengthLiteral() {
    assertNull(Theater3DShaderBake.rewriteStrength("//!HOOK MAIN\nvec4 hook() { return vec4(0.0); }", 0.75))
  }

  /**
   * Regression guard for the on-device bug where moving the slider "just looked
   * like nothing changed": mpv caches user shaders by path and returns the body
   * it first read for a path it has already seen, so rewriting one fixed file
   * name re-parsed the original source.
   */
  @Test
  fun everyStrengthGetsItsOwnShaderPath() {
    val values = listOf("0.10", "0.28", "0.49", "0.50", "0.57", "0.79", "0.90", "1.00")
    val names = values.map { Theater3DShaderBake.liveShaderName(it) }

    assertEquals("names must be unique or mpv serves a stale cached body", names.size, names.toSet().size)
    // And never the Dart-materialized template, which the loader byte-verifies
    // against the bundle on the next launch.
    assertEquals(false, names.any { it == "Pseudo3DSbs_s050.glsl" })
  }

  @Test
  fun stagingNamePublishesOntoTheLiveName() {
    val value = "0.42"
    assertEquals(Theater3DShaderBake.liveShaderName(value) + ".pending", Theater3DShaderBake.liveShaderStagingName(value))
    // A staging file must not itself look like a publishable live shader.
    assertEquals(false, Theater3DShaderBake.isLiveShaderFile(Theater3DShaderBake.liveShaderStagingName(value)))
  }

  @Test
  fun ownsOnlyItsOwnLiveShaders() {
    assertTrue(Theater3DShaderBake.isLiveShaderFile(Theater3DShaderBake.liveShaderName("0.50")))
    // Pruning must never reach Dart's cache or an unrelated shader.
    assertEquals(false, Theater3DShaderBake.isLiveShaderFile("Pseudo3DSbs_s050.glsl"))
    assertEquals(false, Theater3DShaderBake.isLiveShaderFile("NVScaler.glsl"))
  }
}
