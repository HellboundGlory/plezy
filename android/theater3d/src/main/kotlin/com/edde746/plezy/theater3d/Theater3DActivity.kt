package com.edde746.plezy.theater3d

import android.content.Context
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import com.meta.spatial.core.Entity
import com.meta.spatial.core.Pose
import com.meta.spatial.core.Quaternion
import com.meta.spatial.core.SpatialFeature
import com.meta.spatial.core.Vector3
import com.meta.spatial.toolkit.AppSystemActivity
import com.meta.spatial.toolkit.DpPerMeterDisplayOptions
import com.meta.spatial.toolkit.MeshCollision
import com.meta.spatial.toolkit.Panel
import com.meta.spatial.toolkit.PanelRegistration
import com.meta.spatial.toolkit.QuadShapeOptions
import com.meta.spatial.toolkit.Scale
import com.meta.spatial.toolkit.Transform
import com.meta.spatial.toolkit.UIPanelSettings
import com.meta.spatial.toolkit.Visible
import com.meta.spatial.toolkit.ViewPanelRegistration
import com.meta.spatial.vr.VRFeature

/**
 * Quest-only Spatial SDK "3D Theater" host. See PLAN_3D.md Phase 1.
 *
 * Deliberately thin: one video panel (real per-eye stereo via
 * [Theater3DPanel]) plus a small, grab-free play/pause/exit affordance
 * (see [buildControlsPanelRegistration]). No text entry, no resize, no
 * `IsdkGrabbable` -- none of the interaction surface the fork's 3D/SBS
 * research pass traced Holoplex's keyboard/dictation regression to exists
 * here.
 *
 * android/app (MainActivity, the flat 2D panel) never imports this class
 * directly -- it reaches [Theater3DBridge] instead, reflectively, since
 * this module is only on the classpath for THEATER_MODE=1 builds (see
 * android/app/build.gradle.kts). If this Activity fails to initialize for
 * any reason it reports [Theater3DBridge.Listener.onError] and finishes;
 * MainActivity's flat player never loses state, per PLAN_3D.md's
 * non-negotiable #0.
 */
class Theater3DActivity : AppSystemActivity() {
  companion object {
    private const val TAG = "Theater3DActivity"
    private const val VIDEO_PANEL_REGISTRATION_ID = 1
    private const val CONTROLS_PANEL_REGISTRATION_ID = 2

    /**
     * `scene.getViewerPose()` returns an exact zeroed pose
     * (`t=(0,0,0)`) before head tracking has populated a real sample --
     * confirmed on-device during the Phase 0 spike by logging, not
     * inferred. A panel placed at that raw pose lands on the floor; this
     * is the fallback standing eye height used whenever the reported
     * height looks implausible.
     */
    private const val FALLBACK_EYE_HEIGHT_M = 1.6f
    private const val MIN_PLAUSIBLE_EYE_HEIGHT_M = 0.5f
    private const val PANEL_DISTANCE_M = 1.5f
    private const val CONTROLS_WIDTH_M = 0.7f
    private const val CONTROLS_HEIGHT_M = 0.14f
    private const val CONTROLS_GAP_M = 0.12f
    private const val CONTROLS_DP_PER_METER = 900f
  }

  private var request: Theater3DBridge.TheaterOpenRequest? = null
  private var listener: Theater3DBridge.Listener? = null
  private var videoEntity: Entity? = null
  private var controlsEntity: Entity? = null
  private var playPauseButton: Button? = null
  private var isPaused = false
  private var finishing = false

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val session = Theater3DBridge.takePendingSession()
    if (session == null) {
      // Relaunched with no session pending -- Theater3DBridge's listener is
      // a same-process static, not something a killed-and-restarted
      // process can recover (see Theater3DBridge's doc comment). There is
      // nothing to play; finish immediately rather than show an empty
      // scene the user cannot interact with.
      Log.w(TAG, "No pending Theater3D session; finishing")
      finish()
      return
    }
    request = session.first
    listener = session.second
  }

  override fun registerSystemFeatures(): List<SpatialFeature> = listOf(VRFeature(this))

  override fun registerPanels(): List<PanelRegistration> {
    val req = request ?: return emptyList()
    return try {
      listOf(
        Theater3DPanel.registration(VIDEO_PANEL_REGISTRATION_ID, req.stereoMode) { _, surface ->
          listener?.onSurfaceReady(surface, Theater3DPanel.PANEL_PIXEL_WIDTH, Theater3DPanel.PANEL_PIXEL_HEIGHT)
        },
        buildControlsPanelRegistration()
      )
    } catch (e: Exception) {
      Log.e(TAG, "Failed to register theater panels", e)
      failAndFinish(e.message ?: "panel registration failed")
      emptyList()
    }
  }

  override fun onSceneReady() {
    super.onSceneReady()
    if (finishing) return
    if (request == null) return

    try {
      val reportedEyeHeight = scene.getViewerPose().t.y
      val eyeHeight = if (reportedEyeHeight < MIN_PLAUSIBLE_EYE_HEIGHT_M) FALLBACK_EYE_HEIGHT_M else reportedEyeHeight
      val identity = Quaternion(0f, 0f, 0f)

      videoEntity = Entity.create(
        Transform(Pose(Vector3(0f, eyeHeight, -PANEL_DISTANCE_M), identity)),
        Panel(VIDEO_PANEL_REGISTRATION_ID, MeshCollision.NoCollision),
        Visible(true),
        Scale(Vector3(1f))
      )

      val controlsY = eyeHeight - (Theater3DPanel.HEIGHT_METERS / 2f) - CONTROLS_GAP_M
      controlsEntity = Entity.create(
        Transform(Pose(Vector3(0f, controlsY, -PANEL_DISTANCE_M), identity)),
        Panel(CONTROLS_PANEL_REGISTRATION_ID, MeshCollision.LineTest),
        Visible(true),
        Scale(Vector3(1f))
      )
    } catch (e: Exception) {
      Log.e(TAG, "Failed to spawn theater panels", e)
      failAndFinish(e.message ?: "panel spawn failed")
    }
  }

  private fun buildControlsPanelRegistration(): PanelRegistration = ViewPanelRegistration(
    CONTROLS_PANEL_REGISTRATION_ID,
    { _, context -> buildControlsView(context) },
    {
      UIPanelSettings(
        shape = QuadShapeOptions(CONTROLS_WIDTH_M, CONTROLS_HEIGHT_M),
        display = DpPerMeterDisplayOptions(CONTROLS_DP_PER_METER, 1f)
      )
    },
    { _, _, _ -> }
  )

  private fun buildControlsView(context: Context): View {
    val row = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT)
    }
    val buttonParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)

    playPauseButton = Button(context).apply {
      text = if (isPaused) "Play" else "Pause"
      layoutParams = buttonParams
      setOnClickListener { togglePlayPause() }
    }
    row.addView(playPauseButton)

    row.addView(Button(context).apply {
      text = "Exit"
      layoutParams = buttonParams
      setOnClickListener { exitTheater() }
    })

    return row
  }

  private fun togglePlayPause() {
    isPaused = !isPaused
    playPauseButton?.text = if (isPaused) "Play" else "Pause"
    listener?.onPlayPauseToggled(isPaused)
  }

  private fun exitTheater() {
    if (finishing) return
    finishing = true
    listener?.onExitRequested()
    listener = null
    finish()
  }

  private fun failAndFinish(reason: String) {
    if (finishing) return
    finishing = true
    listener?.onError(reason)
    listener = null
    finish()
  }

  override fun onDestroy() {
    // Defensive backstop for any teardown that did not go through
    // exitTheater()/failAndFinish() -- e.g. the user swipe-dismissed the
    // panel from Horizon's shell. A listener that already tore down via
    // onExitRequested()/onError() treats this as a no-op.
    listener?.onSurfaceLost()
    listener = null
    super.onDestroy()
  }
}
