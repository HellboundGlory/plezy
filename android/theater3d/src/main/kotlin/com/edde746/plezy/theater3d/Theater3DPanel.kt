package com.edde746.plezy.theater3d

import android.view.Surface
import com.meta.spatial.core.Entity
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.PanelInputOptions
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.PanelStyleOptions
import com.meta.spatial.toolkit.PixelDisplayOptions
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.ReadableMediaPanelRenderOptions
import com.meta.spatial.toolkit.ReadableMediaPanelSettings
import com.meta.spatial.toolkit.ReadableVideoSurfacePanelRegistration

/**
 * Builds the [PanelRegistration] for the theater's video panel: a
 * [ReadableVideoSurfacePanelRegistration], which -- unlike the plain
 * `VideoSurfacePanelRegistration` -- hands back a raw [Surface] the way
 * Phase 0's spike proved out on-device, and is the variant Phase 2's
 * shader needs to post-process frames before they hit the panel (confirmed
 * supported for exactly this purpose in the Spatial SDK docs).
 *
 * Real per-eye stereo comes entirely from [StereoModeResolver]: mpv
 * decodes the source's already-combined SBS/OU frame untouched into this
 * Surface, and the compositor splits it per eye per [StereoMode]. See
 * PLAN_3D.md 1.5.
 */
object Theater3DPanel {
  /**
   * Fixed compositor buffer size for the video panel. Unlike
   * [com.edde746.plezy.shared.PlayerSurfaceHost]'s SurfaceView, a Spatial
   * SDK panel's compositor buffer does not follow view-layout changes, so
   * there is no per-source dynamic resize here -- mpv's vo=mediacodec/gpu
   * chain renders into whatever size this Surface was configured with.
   * 1080p covers every SBS/OU master the research pass catalogued with
   * headroom on Quest 3's XR2 Gen2 to spare.
   */
  const val PANEL_PIXEL_WIDTH = 1920
  const val PANEL_PIXEL_HEIGHT = 1080

  const val WIDTH_METERS = 2.4f
  const val HEIGHT_METERS = 1.35f

  fun registration(
    registrationId: Int,
    stereoModeRaw: String,
    onSurface: (entity: Entity, surface: Surface) -> Unit
  ): PanelRegistration {
    val stereoMode: StereoMode = StereoModeResolver.resolve(stereoModeRaw)
    return ReadableVideoSurfacePanelRegistration(
      registrationId,
      { entity, surface -> onSurface(entity, surface) },
      { _ ->
        ReadableMediaPanelSettings(
          shape = QuadShapeOptions(WIDTH_METERS, HEIGHT_METERS),
          display = PixelDisplayOptions(PANEL_PIXEL_WIDTH, PANEL_PIXEL_HEIGHT),
          rendering = ReadableMediaPanelRenderOptions().copy(stereoMode = stereoMode),
          style = PanelStyleOptions(),
          input = PanelInputOptions()
        )
      },
      { _, _ -> }
    )
  }
}
