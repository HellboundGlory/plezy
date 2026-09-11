package com.edde746.plezy.theater3d

import android.app.Activity
import android.content.Intent
import android.view.Surface

/**
 * Same-process, Flutter-free handoff between android/app's Theater3D glue
 * (android/app/src/theater3d -- THEATER_MODE=1 builds only, see
 * PLAN_3D.md Phase 1.3/1.4) and [Theater3DActivity].
 *
 * PLAN_3D.md originally scoped this file as "the MethodChannel handler."
 * Building it that way would have meant every consumer of :theater3d --
 * including this module itself -- needing Flutter's embedding classes on
 * its compile classpath, which are resolvable only from android/app's own
 * build script (`dev.flutter.flutter-gradle-plugin` is applied there
 * only). Every existing native-player integration in this repo keeps a
 * different boundary instead: the library module underneath a player
 * (:libmpv, and now this module) stays Flutter-free, and the
 * MethodChannel/EventChannel glue lives in android/app
 * (MpvPlayerPlugin.kt, ExoPlayerPlugin.kt, WatchNextPlugin.kt,
 * ExternalPlayerChannel.kt). Theater3DBridge follows that same shape:
 * android/app/src/theater3d/.../Theater3DChannel.kt is the actual
 * MethodChannel handler, and it talks to this object using only
 * `android.view.Surface` and this file's own plain Kotlin types -- never a
 * `com.meta.spatial.*` class. Corrected 2026-09-08; see PLAN_3D.md's
 * changelog.
 *
 * A same-process static registry -- not a Bundle/Intent extra -- is what
 * carries [Listener] and [TheaterOpenRequest] to [Theater3DActivity],
 * since neither is Parcelable and both are only ever meaningful within the
 * process that is about to launch the theater session. A process kill
 * while theater mode is open (PLAN_3D.md's on-device test checklist) loses
 * this state along with everything else in memory, which is why
 * [Theater3DActivity.onCreate] finishes immediately when nothing is
 * pending rather than showing an empty scene.
 */
object Theater3DBridge {
  /**
   * [stereoMode] is a plain string ("off" | "sbs" | "ou"), not the Spatial
   * SDK's own `StereoMode` enum -- see [StereoModeResolver] -- so that
   * android/app's Theater3DChannel, which builds this request, never needs
   * a Spatial SDK dependency either.
   *
   * [shaderPath] is an already-materialized mpv user-shader file for
   * [TheaterMpvSession] to append to the headless session's `glsl-shaders`
   * before its `loadfile`, or null for real SBS/OU passthrough content.
   * It is a path rather than a strength value because mpv can only override
   * a user shader's `//!PARAM` on `vo=gpu-next`, and the theater session's
   * GL backend is chosen per file -- so the strength is baked into the
   * shader's source by Dart (`ShaderAssetLoader.materializePseudo3DShader`,
   * which also owns the extraction directory), and the native side only
   * ever consumes a file path.
   */
  data class TheaterOpenRequest(
    val uri: String,
    val headers: Map<String, String>,
    val positionMs: Long,
    val audioTrackId: Int?,
    val subtitleTrackId: Int?,
    val stereoMode: String,
    val shaderPath: String?
  )

  interface Listener {
    /**
     * The panel's compositor-owned Surface is ready for decoded frames.
     * [width]/[height] are the fixed pixel dimensions the panel was
     * configured with ([Theater3DPanel.PANEL_PIXEL_WIDTH]/`_HEIGHT`).
     */
    fun onSurfaceReady(surface: Surface, width: Int, height: Int)

    /**
     * The Activity is tearing down; the surface is no longer valid and
     * must not be written to. Called from [Theater3DActivity.onDestroy]
     * as a defensive backstop (e.g. the user swipe-dismissed the panel
     * rather than pressing the in-scene exit button) -- a listener that
     * already tore down from [onExitRequested] must treat this as a
     * no-op.
     */
    fun onSurfaceLost()

    /**
     * The in-scene exit affordance was pressed. The Activity finishes on
     * its own right after this call; the listener owns reporting the
     * session's exit position back to Dart (it is the one tracking
     * playback position, via its own headless mpv core).
     */
    fun onExitRequested()

    /** Panel registration or Spatial runtime init failed before any frame rendered. */
    fun onError(reason: String)

    /** The in-scene play/pause affordance was pressed. */
    fun onPlayPauseToggled(paused: Boolean)
  }

  @Volatile private var pendingRequest: TheaterOpenRequest? = null

  @Volatile private var pendingListener: Listener? = null

  /**
   * Starts [Theater3DActivity] with [request], routing its lifecycle back
   * to [listener]. Only one theater session can be pending or active at a
   * time -- launching while one is already active is a caller bug (Phase
   * 2's UI hides the affordance while active).
   */
  fun launch(activity: Activity, request: TheaterOpenRequest, listener: Listener) {
    pendingRequest = request
    pendingListener = listener
    activity.startActivity(Intent(activity, Theater3DActivity::class.java))
  }

  /** Consumed exactly once, from [Theater3DActivity.onCreate]. */
  internal fun takePendingSession(): Pair<TheaterOpenRequest, Listener>? {
    val request = pendingRequest ?: return null
    val listener = pendingListener ?: return null
    pendingRequest = null
    pendingListener = null
    return request to listener
  }
}
