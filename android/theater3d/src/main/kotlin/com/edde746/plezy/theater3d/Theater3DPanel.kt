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
 * [VideoSurfacePanelRegistration], the type the official `MediaPlayerSample`
 * uses. Its Surface is the target of the app's render-API pass rather than a
 * `vo`'s `wid`: `MpvPlayerCore.setRenderSurface` makes it the window surface of
 * an EGL context this app owns, mpv renders the decoded frame into an FBO we
 * own, and our own shader warps/packs that frame onto this Surface
 * (`android/libmpv/src/main/cpp/render_gl.cpp`, HANDOFF_RENDER_API.md).
 *
 * That is why the registration type no longer decides what can be done to the
 * frame. Under the `vo` path it did: the `Readable` variant rejected the
 * fork's direct hwdec output ("Failed to create HW uploader for format
 * yuv420p"), and the only place a shader could run was mpv's user-shader
 * chain, which can only consume static TEXTURE bytes read once at parse time.
 *
 * Real per-eye stereo still comes entirely from [StereoModeResolver]: the frame
 * the app presents is an SBS (or OU) pair, and the compositor splits it per
 * eye per [StereoMode]. See PLAN_3D.md 1.5.
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
