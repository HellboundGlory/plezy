package com.edde746.plezy.theater3d

import android.app.Activity
import android.util.Log
import android.view.Surface
import com.edde746.plezy.libmpv.MpvRenderHost
import com.edde746.plezy.mpv.MpvPlayerCore
import com.edde746.plezy.shared.PlayerDelegate
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Drives a second, headless [MpvPlayerCore] rendering **through mpv's render
 * API** into the raw compositor [Surface] a [Theater3DPanel] hands back — see
 * [MpvPlayerCore.setRenderSurface]. mpv draws the decoded frame into an FBO
 * this app owns, the app's own shader warps and packs it, and the result is
 * presented to the panel's Surface by the app's EGL surface
 * (`android/libmpv/src/main/cpp/render_gl.cpp`). The flat-panel core in
 * `MainActivity` stays paused (not torn down) for the duration; see
 * PLAN_3D.md 1.3/1.4.
 *
 * That indirection is what the depth strength needs: strength is a shader
 * *uniform* here, so the in-scene slider takes effect on the next frame with no
 * shader rewrite and no recompile — and no exposure to mpv's path-keyed user
 * shader cache, which is what the previous `glsl-shaders` implementation
 * fought. See HANDOFF_RENDER_API.md.
 *
 * One instance per [Theater3DBridge.TheaterOpenRequest.launch] — owned by
 * [Theater3DChannel], which is also the only caller of [release].
 *
 * The open sequence mirrors `player_native.dart`'s `open()` exactly (same
 * `change-list http-header-fields` dance for header values containing
 * commas, same pre-load `sid=no`/`secondary-sid=no` defaults, same
 * post-load unpause) since this is, structurally, a second native mpv
 * session opening the same kind of source — just without a Flutter
 * MethodChannel round trip in front of it.
 */
class TheaterMpvSession(
  private val activity: Activity,
  private val request: Theater3DBridge.TheaterOpenRequest,
  private val callback: Callback
) : Theater3DBridge.Listener, PlayerDelegate {
  interface Callback {
    /** The session ended (in-scene exit, swipe-dismiss, or error) at [positionMs]. */
    fun onExit(positionMs: Long, strength: Double)

    /** Session setup failed before or during playback; already released. */
    fun onError(reason: String)
  }

  private var core: MpvPlayerCore? = null

  /** The app-owned GL host presenting into the panel; see [onStrengthChanged]. */
  private var renderHost: MpvRenderHost? = null

  @Volatile private var lastKnownPositionMs: Long = request.positionMs
  @Volatile private var durationMs: Long = 0L
  @Volatile private var paused: Boolean = false

  /** Current depth strength; changes as the in-scene control moves, and is
   * reported back on exit so the caller can persist it. */
  @Volatile private var strength: Double = request.strength

  private val ended = AtomicBoolean(false)

  override fun onSurfaceReady(surface: Surface, width: Int, height: Int) {
    if (core != null) {
      Log.w(TAG, "onSurfaceReady called twice; ignoring")
      return
    }
    // The panel Surface is not handed to a `vo`: it becomes the window surface
    // of this app's own EGL context, and mpv renders into an FBO we own
    // (renderApi = true -> `vo=libmpv`, no `wid`, no OSD plane). That is also
    // why `hardwareDecoding` no longer decides the vo chain here — the flag
    // only feeds `initialVideoOutput`, which the render API replaces. Decoding
    // still hardware-decodes; `hwdec` below selects it, and mpv reaches GL
    // through its aimagereader interop.
    val playerCore = MpvPlayerCore(context = activity, headless = true, hardwareDecoding = true, renderApi = true)
    playerCore.delegate = this
    core = playerCore
    // Must precede initialize(): the host is created inside it, between
    // mpv_initialize and the first possible load. See setRenderSurface.
    //
    // letterbox=false: the panel's whole output is a packed stereo pair the
    // compositor splits per eye, and a letterboxed frame would put the pair
    // inside black bars and squash both eyes. Stretching to fill is also what
    // the previous vo=mediacodec path did (VideoRectPolicy implements none of
    // mpv's src/dst rect math), so this preserves the panel's geometry.
    playerCore.setRenderSurface(
      surface,
      request.vertexShader,
      request.fragmentShader,
      letterbox = false
    )

    playerCore.initialize { success ->
      if (ended.get()) return@initialize
      if (!success) {
        // Include what actually failed, not just that something did. A failed
        // render-API setup reports only through this string on the Dart side
        // (the log carries the stack), and "mpv init failed" alone cost a
        // full on-device round trip to diagnose once already.
        failAndRelease(playerCore.initFailure?.let { "mpv init failed: ${it.javaClass.simpleName}: ${it.message}" } ?: "mpv init failed")
        return@initialize
      }
      renderHost = playerCore.renderHost
      if (renderHost == null) {
        failAndRelease("render host unavailable after init")
        return@initialize
      }
      // The in-scene slider's value may already have moved while init ran.
      renderHost?.setStrength(strength, synthetic = request.synthetic)
      playerCore.observeProperty("time-pos", "double")
      playerCore.observeProperty("duration", "double")
      playerCore.observeProperty("pause", "flag")
      // What mpv actually settled on, which can differ from the requested
      // value (fallback order, per-file decode routing). First thing to check
      // if playback is ever slow or out of sync again.
      playerCore.observeProperty("hwdec-current", "string")
      Log.i(TAG, "Render pipeline ready: ${width}x$height, synthetic=${request.synthetic}, strength=$strength")
      openRequestedMedia(playerCore)
    }
  }

  private fun openRequestedMedia(playerCore: MpvPlayerCore) {
    // Pipelined, not awaited between sends -- matches player_native.dart's
    // open(): the ordered mpv write dispatcher preserves submission order,
    // and a header value containing a comma (`X-Plex-Device: Mac17,9`)
    // must ride its own `-append` entry rather than a joined list.
    playerCore.command(arrayOf("change-list", "http-header-fields", "clr", ""))
    for ((key, value) in request.headers) {
      playerCore.command(arrayOf("change-list", "http-header-fields", "append", "$key: $value"))
    }

    // No shader chain to install. The warp/pack shader is this app's own GL
    // program now (compiled in the render host), not an mpv user shader, so
    // there is nothing to append to `glsl-shaders`, nothing to prune, and no
    // mpv shader cache to defeat.

    // Decoder backend, before the load. Without this the session decodes in
    // software: the flat player writes `hwdec` from Dart, and this second,
    // headless core has nothing in front of it doing that, so mpv sits on its
    // default of `no`. That was the whole cause of the theater session
    // playing at a fraction of real time and drifting out of sync with the
    // audio -- and, earlier, of the fork vo=mediacodec failing here with
    // "Failed to create HW uploader for format yuv420p", because it was being
    // handed CPU frames to composite.
    //
    // Under the render API `mediacodec` keeps its zero-copy path: mpv maps the
    // decoder's buffers through its `aimagereader` interop (AImageReader +
    // GL_OES_EGL_image_external, both compiled into the pinned libmpv) instead
    // of the app forcing `mediacodec-copy` to get ordinary textures for a user
    // shader. `hwdec-current` below reports what mpv settled on.
    playerCore.setProperty("hwdec", request.hwdec)
    Log.i(TAG, "hwdec=${request.hwdec}")

    if (request.positionMs > 0) {
      playerCore.setProperty("start", (request.positionMs / 1000.0).toString())
    } else {
      playerCore.setProperty("start", "none")
    }
    // Prevent mpv's own default subtitle selection from racing the explicit
    // aid/sid applied below once the load resolves.
    playerCore.setProperty("sid", "no")
    playerCore.setProperty("secondary-sid", "no")

    playerCore.setPauseIntentForLoad(paused = false)
    playerCore.commandForSource(arrayOf("loadfile", request.uri, "replace")) { outcome ->
      if (ended.get()) return@commandForSource
      outcome.onSuccess {
        request.audioTrackId?.let { playerCore.setProperty("aid", it.toString()) }
        request.subtitleTrackId?.let { playerCore.setProperty("sid", it.toString()) }
        // mpv's pause property survives loadfile; explicitly unpause after,
        // same ordering player_native.dart uses, so the replaced file never
        // audibly unpauses pre-replace.
        playerCore.setProperty("pause", "no")
      }
      outcome.onFailure { e -> failAndRelease("loadfile failed: ${e.message}") }
    }
  }

  override fun onSurfaceLost() {
    // Defensive backstop for a swipe-dismiss with no in-scene exit press --
    // the only teardown signal in that case, so it must itself report the
    // exit position the first time it fires (handleExit is idempotent).
    handleExit()
  }

  override fun onExitRequested() = handleExit()

  override fun onError(reason: String) {
    if (!ended.compareAndSet(false, true)) return
    release()
    callback.onError(reason)
  }

  override fun onPlayPauseToggled(paused: Boolean) {
    this.paused = paused
    core?.setProperty("pause", if (paused) "yes" else "no")
  }

  /**
   * Absolute seek, in seconds with mpv's `absolute` flag so it is not
   * interpreted as relative to the current position.
   */
  override fun onSeekRequested(positionMs: Long) {
    val seconds = (positionMs.coerceAtLeast(0L) / 1000.0)
    core?.command(arrayOf("seek", seconds.toString(), "absolute"))
    // Optimistic, so the progress bar jumps to where the user dropped it
    // instead of snapping back to the pre-seek position until the next
    // `time-pos` observation arrives.
    lastKnownPositionMs = positionMs.coerceAtLeast(0L)
  }

  /**
   * Applies the in-scene depth slider: a single shader uniform, read once per
   * frame by the render thread, so it lands on the next presented frame.
   *
   * What this replaces, and why it is worth spelling out: strength used to be a
   * `const float` in an mpv user shader, so every change meant rewriting that
   * literal to a fresh file name (mpv caches user shaders by path forever) with
   * an atomic rename (a truncate-and-write can be caught mid-flight, and a
   * truncated shader makes `parse_user_shader` abandon the whole file), then a
   * `change-list glsl-shaders clr` + `append` to force a recompile. All of
   * that existed to route around mpv's shader handling, and none of it exists
   * under the render API.
   */
  override fun onStrengthChanged(strength: Double) {
    this.strength = strength
    renderHost?.setStrength(strength, synthetic = request.synthetic)
  }

  override fun transportSnapshot(): Theater3DBridge.TransportSnapshot =
    Theater3DBridge.TransportSnapshot(lastKnownPositionMs, durationMs, paused)

  override fun onPropertyChange(name: String, value: Any?) {
    when (name) {
      "time-pos" -> {
        val seconds = value as? Double ?: return
        lastKnownPositionMs = (seconds * 1000.0).toLong()
      }
      "duration" -> {
        val seconds = value as? Double ?: return
        durationMs = (seconds * 1000.0).toLong()
      }
      "pause" -> paused = value == true
      "hwdec-current" -> Log.i(TAG, "hwdec-current=${value ?: "none"}")
    }
  }

  override fun onEvent(name: String, data: Map<String, Any>?) {
    // The flat player forwards this to Dart, which prints it; a headless
    // session has no MethodChannel listener, so without this the mpv-side
    // vo=gpu/EGL diagnostics for a black-screen session are invisible.
    if (name != "log-message") return
    val level = data?.get("level") as? String ?: "info"
    val prefix = data?.get("prefix") as? String ?: "mpv"
    val text = data?.get("text") as? String ?: return
    when (level) {
      "fatal", "error" -> Log.e(TAG, "[$prefix] $text")
      "warn" -> Log.w(TAG, "[$prefix] $text")
      else -> Log.d(TAG, "[$prefix] $text")
    }
  }

  private fun handleExit() {
    if (!ended.compareAndSet(false, true)) return
    val positionMs = lastKnownPositionMs
    val finalStrength = strength
    release()
    callback.onExit(positionMs, finalStrength)
  }

  private fun failAndRelease(reason: String) {
    if (!ended.compareAndSet(false, true)) return
    release()
    callback.onError(reason)
  }

  /** Idempotent; safe to call after [handleExit]/[failAndRelease] already released. */
  private fun release() {
    val playerCore = core ?: return
    core = null
    // dispose() tears the render host down immediately before it closes the
    // mpv session, which is the order an mpv_render_context requires (see
    // MpvPlayerCore.renderHostTeardown). The panel Surface needs no handoff
    // here: closing the host destroys the EGL surface that was using it.
    renderHost = null
    playerCore.dispose()
  }

  companion object {
    private const val TAG = "TheaterMpvSession"
  }
}
