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
   * [vertexShader] / [fragmentShader] are the GLSL ES 3.0 sources the app
   * compiles and runs *after* mpv renders a frame, in the render-API pipeline
   * (`android/libmpv/src/main/cpp/render_gl.cpp`, HANDOFF_RENDER_API.md).
   * They are ordinary strings rather than a path because nothing else reads
   * them: this is the app's own GL program, not an mpv user shader, so there is
   * no file for mpv to parse and no cache to defeat.
   *
   * [synthetic] selects what that program does with the frame: `true`
   * synthesizes a depth field from the picture and packs the result as a
   * side-by-side pair, `false` passes the frame through untouched for real
   * SBS/OU sources, which already carry parallax. It mirrors
   * [stereoMode]'s `synthetic` value, and is carried separately because the
   * shader needs it as a uniform whatever the compositor's stereo mode is.
   *
   * [strength] is the depth strength (0.0-1.0). Under the render API it is a
   * plain shader uniform, so the in-scene control changes the picture on the
   * next frame with no rewrite and no recompile.
   *
   * [hwdec] is the mpv `hwdec` value to apply before the load, e.g.
   * `"mediacodec,mediacodec-copy"` or `"no"`. It has to be carried
   * explicitly: the flat player writes this property from Dart
   * (`_getHwdecValue`), and this second, headless core has no Dart in front
   * of it, so without it mpv falls back to its default of `no` and decodes
   * on the CPU.
   */
  data class TheaterOpenRequest(
    val uri: String,
    val headers: Map<String, String>,
    val positionMs: Long,
    val audioTrackId: Int?,
    val subtitleTrackId: Int?,
    val stereoMode: String,
    val vertexShader: String,
    val fragmentShader: String,
    val synthetic: Boolean,
    val strength: Double,
    val hwdec: String
  )

  /**
   * One reading of the session's playback state, for the controls panel's
   * progress UI. Polled by [Theater3DActivity] on a UI-rate timer rather than
   * pushed, because the controls are plain Android views that need a value at
   * the moment they redraw, and a poll cannot leave a stale label behind if a
   * push is missed during a lifecycle transition.
   */
  data class TransportSnapshot(
    val positionMs: Long,
    val durationMs: Long,
    val paused: Boolean
  )

  interface Listener {
    /**
     * The panel's compositor-owned Surface is ready. [width]/[height] are the
     * fixed pixel dimensions the panel was configured with
     * ([Theater3DPanel.PANEL_PIXEL_WIDTH]/`_HEIGHT`).
     *
     * The Surface is the render-API target, not a `vo`'s `wid`: the listener
     * hands it to `MpvPlayerCore.setRenderSurface`, which makes it the window
     * surface of the app's own EGL context.
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

    /** Absolute seek request from the in-scene transport controls. */
    fun onSeekRequested(positionMs: Long)

    /**
     * Live depth-strength change from the in-scene control, 0.0-1.0.
     *
     * This is a *display* change the session can make on its own: strength is
     * a shader uniform in the app's render-API pass, so the session writes it
     * and the next presented frame reflects it. Persisting it is the caller's
     * job, which is why the exit payload carries the final value back to Dart.
     */
    fun onStrengthChanged(strength: Double)

    /** Current playback state for the controls panel; see [TransportSnapshot]. */
    fun transportSnapshot(): TransportSnapshot
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
