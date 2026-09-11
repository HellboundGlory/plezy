package com.edde746.plezy.theater3d

import android.view.Surface
import com.meta.spatial.core.Entity
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.MediaPanelRenderOptions
import com.meta.spatial.toolkit.MediaPanelSettings
import com.meta.spatial.toolkit.PanelInputOptions
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.PanelStyleOptions
import com.meta.spatial.toolkit.PixelDisplayOptions
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.VideoSurfacePanelRegistration

/**
 * Builds the [PanelRegistration] for the theater's video panel: a
 * [VideoSurfacePanelRegistration]. The `Readable` variant was tried first
 * (for a panel-level post-process shader) but its surface rejects
 * direct MediaCodec hwdec output -- mpv's mediacodec vo fails with
 * "Failed to create HW uploader for format yuv420p" / "Could not
 * initialize video chain" against it, falls back to vo=gpu, and even that
 * renders nothing visible (black panel, audio still playing) -- confirmed
 * on-device. `VideoSurfacePanelRegistration` is what the official
 * `MediaPlayerSample` uses and is the direct-hwdec-output surface type.
 *
 * The pseudo-3D shader therefore does not post-process this panel's
 * surface at all: it runs inside the theater session's own mpv vo chain
 * as a user shader (`glsl-shaders`), which is what makes the panel
 * registration type irrelevant to it. See
 * [Theater3DBridge.TheaterOpenRequest.shaderPath] and
 * `TheaterMpvSession.openRequestedMedia`.
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
    return VideoSurfacePanelRegistration(
      registrationId,
      { entity, surface -> onSurface(entity, surface) },
      { _ ->
        MediaPanelSettings(
          shape = QuadShapeOptions(WIDTH_METERS, HEIGHT_METERS),
          display = PixelDisplayOptions(PANEL_PIXEL_WIDTH, PANEL_PIXEL_HEIGHT),
          rendering = MediaPanelRenderOptions(isDRM = false, stereoMode = stereoMode),
          style = PanelStyleOptions(),
          input = PanelInputOptions()
        )
      },
      { _, _ -> }
    )
  }
}
