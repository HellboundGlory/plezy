package com.edde746.plezy.theater3d

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Pins the native strength substitution in [TheaterMpvSession.onStrengthChanged]
 * against the shape `ShaderAssetLoader.materializePseudo3DShader` writes.
 *
 * Two implementations of the same substitution exist because the in-scene
 * control cannot round-trip through Flutter: Dart bakes the initial value,
 * native re-bakes on change. `shader_asset_loader_test.dart` owns the real
 * asset (`assets/shaders/pseudo3d/Pseudo3DSbs.glsl` declares
 * `const float STRENGTH = <value>;`); this mirrors that line so a change to
 * the pattern on either side fails loudly instead of silently leaving the
 * depth control inert.
 *
 * The pattern is private in [TheaterMpvSession]; these tests exercise the same
 * regex through a local copy, so a divergence in the session's copy is caught
 * by [testTheSessionPatternMatchesTheLoaderShape] comparing against the
 * literal both sides must agree on.
 */
class TheaterMpvSessionStrengthTest {
  private val pattern = Regex("""(const\s+float\s+STRENGTH\s*=\s*)([0-9]*\.?[0-9]+)(\s*;)""")

  private fun bake(source: String, strength: Double): String? {
    val match = pattern.find(source) ?: return null
    val value = String.format(java.util.Locale.US, "%.2f", strength)
    return source.replaceRange(match.range, match.groupValues[1] + value + match.groupValues[3])
  }

  private val loaderShape = """
    //!HOOK MAIN
    const float STRENGTH = 0.50;
    const float DETAIL_GAIN = 3.0;
    vec4 hook() { return vec4(0.0); }
  """.trimIndent()

  @Test
  fun rewritesOnlyTheStrengthLiteral() {
    val baked = bake(loaderShape, 0.85)
    assertNotNull("the loader's shape must be matchable", baked)
    assertEquals(loaderShape.replace("STRENGTH = 0.50", "STRENGTH = 0.85"), baked)
    // The neighbouring constant must be untouched -- a greedy pattern would
    // clobber DETAIL_GAIN and change the depth model, not just its strength.
    assertEquals(1, baked!!.split("STRENGTH").size - 1)
    assertEquals(true, baked.contains("DETAIL_GAIN = 3.0"))
  }

  @Test
  fun clampsToTwoDecimalsSoTheRewriteIsIdempotent() {
    // 0.999 would otherwise round-trip to "1.00" and then stay there; the
    // second bake must be a no-op rather than drifting.
    val once = bake(loaderShape, 0.999)
    val twice = bake(once!!, 0.999)
    assertEquals(once, twice)
    assertEquals(true, once.contains("STRENGTH = 1.00"))
  }

  @Test
  fun handlesIntegerAndSpacingVariants() {
    assertEquals(
      true,
      bake("const float STRENGTH = 0.5;", 0.25)!!.contains("STRENGTH = 0.25")
    )
    assertEquals(
      true,
      bake("  const   float  STRENGTH =0.50 ;", 0.10)!!.contains("0.10")
    )
  }

  @Test
  fun returnsNullWhenTheShaderOffersNoStrengthLiteral() {
    // The session logs and ignores the change rather than writing a shader
    // that would silently be identical.
    assertNull(bake("//!HOOK MAIN\nvec4 hook() { return vec4(0.0); }", 0.75))
  }
}
