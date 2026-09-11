package com.edde746.plezy.theater3d

import android.app.Activity
import android.util.Log
import android.view.Surface
import com.edde746.plezy.mpv.MpvPlayerCore
import com.edde746.plezy.shared.PlayerDelegate
import java.io.File
import java.util.Locale
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Drives a second, headless [MpvPlayerCore] against the raw compositor
 * [Surface] a [Theater3DPanel] hands back — see [MpvPlayerCore]'s
 * `headless` constructor parameter. The flat-panel core in `MainActivity`
 * stays paused (not torn down) for the duration; see PLAN_3D.md 1.3/1.4.
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
  private var attachedSurface: Surface? = null

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
    // vo=mediacodec's autoconvert hwupload step fails against this
    // compositor-owned Surface regardless of panel registration type
    // ("Failed to create HW uploader for format yuv420p" / "Could not
    // initialize video chain", confirmed on-device with both
    // VideoSurfacePanelRegistration and ReadableVideoSurfacePanelRegistration).
    // hardwareDecoding=false selects vo=gpu,gpu-next from the start instead
    // of after a failed mediacodec attempt.
    val playerCore = MpvPlayerCore(context = activity, headless = true, hardwareDecoding = false)
    playerCore.delegate = this
    core = playerCore
    attachedSurface = surface

    playerCore.initialize { success ->
      if (ended.get()) return@initialize
      if (!success) {
        failAndRelease("mpv init failed")
        return@initialize
      }
      playerCore.attachHeadlessSurface(surface, width, height)
      playerCore.observeProperty("time-pos", "double")
      playerCore.observeProperty("duration", "double")
      playerCore.observeProperty("pause", "flag")
      // What mpv actually settled on, which can differ from the requested
      // value (fallback order, per-file decode routing). First thing to check
      // if playback is ever slow or out of sync again.
      playerCore.observeProperty("hwdec-current", "string")
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

    // The heuristic pseudo-3D shader, when this mode synthesizes depth at all
    // (null for real SBS/OU passthrough -- see
    // [Theater3DBridge.TheaterOpenRequest.shaderPath]). Appended before
    // `loadfile` so the list is already populated when the GL vo initializes
    // on the first frame: vo=gpu compiles the whole user-shader chain during
    // that init, and a fresh session's list starts empty, so there is
    // nothing to clear first.
    request.shaderPath?.let { shaderPath ->
      Log.i(TAG, "Appending pseudo-3D shader: $shaderPath")
      playerCore.command(arrayOf("change-list", "glsl-shaders", "append", shaderPath))
    }

    // Decoder backend, before the load. Without this the session decodes in
    // software: the flat player writes `hwdec` from Dart, and this second,
    // headless core has nothing in front of it doing that, so mpv sits on its
    // default of `no`. That was the whole cause of the theater session
    // playing at a fraction of real time and drifting out of sync with the
    // audio -- and, earlier, of the fork vo=mediacodec failing here with
    // "Failed to create HW uploader for format yuv420p", because it was being
    // handed CPU frames to composite.
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
   * Re-bakes the depth strength and swaps the shader chain over.
   *
   * Strength lives in the shader's own source (a plain GLSL constant -- mpv's
   * parameter metadata is unavailable on the vo=gpu backend this session
   * prefers), so changing it means rewriting that one literal and getting mpv
   * to recompile. A sibling file is written rather than editing the one Dart
   * materialized: that one is Dart's cache and is verified by byte comparison
   * on the next launch, so clobbering it would only force a rewrite.
   *
   * The clear-then-append pair is what actually triggers the recompile --
   * re-appending the same path would be a no-op.
   */
  override fun onStrengthChanged(strength: Double) {
    val playerCore = core ?: return
    val templatePath = request.shaderPath ?: return
    this.strength = strength

    val template = File(templatePath)
    val source = try {
      template.readText()
    } catch (e: Exception) {
      Log.w(TAG, "Failed to read shader for strength=$strength", e)
      return
    }
    val match = STRENGTH_PATTERN.find(source)
    if (match == null) {
      Log.w(TAG, "Shader has no STRENGTH literal to rewrite; ignoring strength change")
      return
    }
    val value = String.format(Locale.US, "%.2f", strength)
    val rewritten = source.replaceRange(match.range, match.groupValues[1] + value + match.groupValues[3])

    val baked = try {
      File(template.parentFile, LIVE_SHADER_NAME).apply { writeText(rewritten) }
    } catch (e: Exception) {
      Log.w(TAG, "Failed to write live shader for strength=$strength", e)
      return
    }

    Log.i(TAG, "Strength -> $strength (${baked.absolutePath})")
    playerCore.command(arrayOf("change-list", "glsl-shaders", "clr", ""))
    playerCore.command(arrayOf("change-list", "glsl-shaders", "append", baked.absolutePath))
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
    val surface = attachedSurface
    attachedSurface = null
    if (surface != null) playerCore.detachHeadlessSurface(surface)
    playerCore.dispose()
  }

  companion object {
    private const val TAG = "TheaterMpvSession"

    /** Sibling of the materialized shader that live strength changes rewrite. */
    private const val LIVE_SHADER_NAME = "Pseudo3DSbs_live.glsl"

    /**
     * Must match the literal `ShaderAssetLoader.materializePseudo3DShader`
     * substitutes on the Dart side -- `assets/shaders/pseudo3d/Pseudo3DSbs.glsl`
     * declares `const float STRENGTH = <value>;` for exactly this reason. Two
     * implementations exist only because the live control cannot round-trip
     * through Flutter; `shader_asset_loader_test.dart` pins the asset's shape
     * and `TheaterMpvSessionTest` pins this pattern against it.
     */
    private val STRENGTH_PATTERN =
      Regex("""(const\s+float\s+STRENGTH\s*=\s*)([0-9]*\.?[0-9]+)(\s*;)""")
  }
}
