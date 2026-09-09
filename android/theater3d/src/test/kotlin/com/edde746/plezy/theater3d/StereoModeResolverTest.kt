package com.edde746.plezy.theater3d

import com.meta.spatial.runtime.StereoMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Pure mapping table, no device needed -- see PLAN_3D.md's testing plan.
 */
class StereoModeResolverTest {
  @Test
  fun `off maps to None`() {
    assertEquals(StereoMode.None, StereoModeResolver.resolve("off"))
  }

  @Test
  fun `sbs maps to LeftRight`() {
    assertEquals(StereoMode.LeftRight, StereoModeResolver.resolve("sbs"))
  }

  @Test
  fun `ou maps to UpDown`() {
    assertEquals(StereoMode.UpDown, StereoModeResolver.resolve("ou"))
  }

  @Test
  fun `unknown mode throws`() {
    assertThrows(IllegalArgumentException::class.java) {
      StereoModeResolver.resolve("synthetic")
    }
  }
}
