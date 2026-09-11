package com.edde746.plezy.theater3d

import android.content.Context
import android.graphics.Color
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
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
import java.util.Locale

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
    private const val CONTROLS_WIDTH_M = 1.0f
    private const val CONTROLS_HEIGHT_M = 0.32f
    private const val CONTROLS_GAP_M = 0.12f
    private const val CONTROLS_DP_PER_METER = 900f

    /** Skip step for the transport buttons. */
    private const val SKIP_MS = 10_000L

    /** Fixed per-mille scale for the scrubber; see `buildControlsView`. */
    private const val SEEK_SCALE = 1000

    /** Depth-strength resolution: 1% steps. */
    private const val STRENGTH_SCALE = 100

    private const val PROGRESS_INTERVAL_MS = 500L
  }

  private var request: Theater3DBridge.TheaterOpenRequest? = null
  private var listener: Theater3DBridge.Listener? = null
  private var videoEntity: Entity? = null
  private var controlsEntity: Entity? = null
  private var playPauseButton: Button? = null
  private var seekBar: SeekBar? = null
  private var timeLabel: TextView? = null
  private var strengthBar: SeekBar? = null
  private var strengthLabel: TextView? = null
  private var isPaused = false
  private var finishing = false

  /** Non-null while the user is dragging the scrubber, so the ticker keeps
   * the label on the thumb instead of overwriting it with playback position. */
  private var scrubOffsetMs: Long? = null

  /** Depth strength as the in-scene control last set it; reported on exit. */
  private var currentStrength: Double = 0.5

  private val mainHandler = Handler(Looper.getMainLooper())

  override fun onCreate(savedInstanceState: Bundle?) {
    val session = Theater3DBridge.takePendingSession()
    // AppSystemActivity.onCreate() calls registerPanels() synchronously
    // (twice) as part of super.onCreate() itself, before this method's own
    // body would otherwise run -- request/listener must already be set
    // when that happens or registerPanels()'s `request ?: return
    // emptyList()` guard silently registers nothing and every panel
    // creation crashes with "No panel creator found".
    if (session != null) {
      request = session.first
      listener = session.second
      currentStrength = session.first.strength
    }
    super.onCreate(savedInstanceState)
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
  }


  // Matches the Phase 0 spike's proven-working configuration exactly
  // (recovered from that session's transcript after the spike directory
  // was deleted) -- plain VRFeature(this), no explicit inputSystemType.
  override fun registerFeatures(): List<SpatialFeature> = listOf(VRFeature(this))

  override fun registerPanels(): List<PanelRegistration> {
    val req = request ?: return emptyList()
    Log.i(TAG, "registerPanels: building registrations for stereoMode=${req.stereoMode}")
    return try {
      val regs = listOf(
        Theater3DPanel.registration(VIDEO_PANEL_REGISTRATION_ID, req.stereoMode) { _, surface ->
          Log.i(TAG, "Video panel surfaceConsumer fired: surface=$surface")
          listener?.onSurfaceReady(surface, Theater3DPanel.PANEL_PIXEL_WIDTH, Theater3DPanel.PANEL_PIXEL_HEIGHT)
        },
        buildControlsPanelRegistration()
      )
      Log.i(TAG, "registerPanels: built ${regs.size} registrations")
      regs
    } catch (e: Exception) {
      Log.e(TAG, "Failed to register theater panels", e)
      failAndFinish(e.message ?: "panel registration failed")
      emptyList()
    }
  }

  override fun onSceneReady() {
    super.onSceneReady()
    Log.i(TAG, "onSceneReady: finishing=$finishing request=${request != null}")
    if (finishing) return
    if (request == null) return

    try {
      val reportedEyeHeight = scene.getViewerPose().t.y
      val eyeHeight = if (reportedEyeHeight < MIN_PLAUSIBLE_EYE_HEIGHT_M) FALLBACK_EYE_HEIGHT_M else reportedEyeHeight
      val identity = Quaternion(0f, 0f, 0f)
      Log.i(TAG, "onSceneReady: reportedEyeHeight=$reportedEyeHeight eyeHeight=$eyeHeight")

      videoEntity = Entity.create(
        Transform(Pose(Vector3(0f, eyeHeight, PANEL_DISTANCE_M), identity)),
        Panel(VIDEO_PANEL_REGISTRATION_ID, MeshCollision.NoCollision),
        Visible(true),
        Scale(Vector3(1f))
      )
      Log.i(TAG, "onSceneReady: created videoEntity=${videoEntity?.id}")

      val controlsY = eyeHeight - (Theater3DPanel.HEIGHT_METERS / 2f) - CONTROLS_GAP_M
      controlsEntity = Entity.create(
        Transform(Pose(Vector3(0f, controlsY, PANEL_DISTANCE_M), identity)),
        Panel(CONTROLS_PANEL_REGISTRATION_ID, MeshCollision.LineTest),
        Visible(true),
        Scale(Vector3(1f))
      )
      Log.i(TAG, "onSceneReady: created controlsEntity=${controlsEntity?.id}")
      mainHandler.postDelayed(progressTicker, PROGRESS_INTERVAL_MS)
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
    val column = LinearLayout(context).apply {
      orientation = LinearLayout.VERTICAL
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.MATCH_PARENT)
    }

    // Row 1: elapsed / total, so a seek has somewhere to be read from.
    timeLabel = TextView(context).apply {
      textSize = 18f
      setTextColor(Color.WHITE)
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f)
    }
    column.addView(timeLabel)

    // Row 2: scrubber. max is a fixed per-mille scale, not the duration, so
    // the bar does not have to be rebuilt when a stream reports its duration
    // late (or never, for a live source).
    seekBar = SeekBar(context).apply {
      max = SEEK_SCALE
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1.4f)
      setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
        override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
          if (fromUser) previewSeek(progress)
        }

        override fun onStartTrackingTouch(bar: SeekBar) = Unit

        override fun onStopTrackingTouch(bar: SeekBar) {
          val durationMs = listener?.transportSnapshot()?.durationMs ?: 0L
          if (durationMs > 0) {
            listener?.onSeekRequested(durationMs * bar.progress / SEEK_SCALE)
          }
          scrubOffsetMs = null
        }
      })
    }
    column.addView(seekBar)

    // Row 3: transport.
    val transport = LinearLayout(context).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER
      layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1.2f)
    }
    transport.addView(Button(context).apply {
      text = "\u23EA 10s"
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
      setOnClickListener { skipBy(-SKIP_MS) }
    })
    playPauseButton = Button(context).apply {
      text = if (isPaused) "Play" else "Pause"
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1.2f)
      setOnClickListener { togglePlayPause() }
    }
    transport.addView(playPauseButton)
    transport.addView(Button(context).apply {
      text = "10s \u23E9"
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
      setOnClickListener { skipBy(SKIP_MS) }
    })
    transport.addView(Button(context).apply {
      text = "Exit"
      layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.MATCH_PARENT, 1f)
      setOnClickListener { exitTheater() }
    })
    column.addView(transport)

    // Row 4: depth strength. Only meaningful when a depth shader is in the
    // chain; hidden for real SBS/OU passthrough, where it would do nothing.
    if (request?.shaderPath != null) {
      val strengthRow = LinearLayout(context).apply {
        orientation = LinearLayout.HORIZONTAL
        gravity = Gravity.CENTER_VERTICAL
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1.2f)
      }
      strengthLabel = TextView(context).apply {
        text = "Depth"
        textSize = 16f
        setTextColor(Color.WHITE)
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
      }
      strengthRow.addView(strengthLabel)
      strengthBar = SeekBar(context).apply {
        max = STRENGTH_SCALE
        progress = (currentStrength * STRENGTH_SCALE).toInt()
        layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 2.4f)
        setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
          override fun onProgressChanged(bar: SeekBar, progress: Int, fromUser: Boolean) {
            strengthLabel?.text = "Depth ${progress * 100 / STRENGTH_SCALE}%"
            // Applied on release only: each change rewrites the shader and
            // forces mpv to recompile the chain, which would stutter if it
            // ran for every intermediate position during a drag.
          }

          override fun onStartTrackingTouch(bar: SeekBar) = Unit

          override fun onStopTrackingTouch(bar: SeekBar) {
            currentStrength = bar.progress.toDouble() / STRENGTH_SCALE
            listener?.onStrengthChanged(currentStrength)
          }
        })
      }
      strengthRow.addView(strengthBar)
      column.addView(strengthRow)
      strengthLabel?.text = "Depth ${(currentStrength * 100).toInt()}%"
    }

    return column
  }

  private fun togglePlayPause() {
    isPaused = !isPaused
    playPauseButton?.text = if (isPaused) "Play" else "Pause"
    listener?.onPlayPauseToggled(isPaused)
  }

  private fun skipBy(deltaMs: Long) {
    val snapshot = listener?.transportSnapshot() ?: return
    val durationMs = snapshot.durationMs
    val target = (snapshot.positionMs + deltaMs).coerceAtLeast(0L)
    listener?.onSeekRequested(if (durationMs > 0) target.coerceAtMost(durationMs) else target)
    scrubOffsetMs = null
  }

  /** While the user drags, the label follows the thumb rather than playback. */
  private fun previewSeek(progress: Int) {
    val durationMs = listener?.transportSnapshot()?.durationMs ?: 0L
    if (durationMs <= 0) return
    scrubOffsetMs = durationMs * progress / SEEK_SCALE
    timeLabel?.text = formatTime(scrubOffsetMs!!) + " / " + formatTime(durationMs)
  }

  /**
   * Keeps the progress UI in step with playback. A poll rather than a push:
   * the controls are plain views redrawn from the main thread, so reading on
   * a timer cannot leave a stale label behind across a lifecycle transition,
   * and the snapshot is two volatile reads plus a subtraction.
   */
  private val progressTicker = object : Runnable {
    override fun run() {
      if (finishing) return
      val snapshot = listener?.transportSnapshot()
      if (snapshot != null) {
        val durationMs = snapshot.durationMs
        seekBar?.isEnabled = durationMs > 0
        if (durationMs > 0) {
          val shown = scrubOffsetMs ?: snapshot.positionMs
          seekBar?.progress = ((shown.coerceIn(0L, durationMs) * SEEK_SCALE) / durationMs).toInt()
          if (scrubOffsetMs == null) {
            timeLabel?.text = formatTime(shown) + " / " + formatTime(durationMs)
          }
        } else {
          timeLabel?.text = formatTime(snapshot.positionMs)
        }
        // Playback can be paused from outside these controls (end of file,
        // a hardware media key), so the button follows the real state.
        if (snapshot.paused != isPaused) {
          isPaused = snapshot.paused
          playPauseButton?.text = if (isPaused) "Play" else "Pause"
        }
      }
      mainHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
    }
  }

  private fun formatTime(ms: Long): String {
    val totalSeconds = ms / 1000
    val hours = totalSeconds / 3600
    val minutes = (totalSeconds % 3600) / 60
    val seconds = totalSeconds % 60
    return if (hours > 0) {
      String.format(Locale.US, "%d:%02d:%02d", hours, minutes, seconds)
    } else {
      String.format(Locale.US, "%d:%02d", minutes, seconds)
    }
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
    mainHandler.removeCallbacks(progressTicker)
    // Defensive backstop for any teardown that did not go through
    // exitTheater()/failAndFinish() -- e.g. the user swipe-dismissed the
    // panel from Horizon's shell. A listener that already tore down via
    // onExitRequested()/onError() treats this as a no-op.
    listener?.onSurfaceLost()
    listener = null
    super.onDestroy()
  }
}
