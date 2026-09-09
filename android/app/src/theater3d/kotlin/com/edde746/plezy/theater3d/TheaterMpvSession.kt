package com.edde746.plezy.theater3d

import android.app.Activity
import android.util.Log
import android.view.Surface
import com.edde746.plezy.mpv.MpvPlayerCore
import com.edde746.plezy.shared.PlayerDelegate
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
    fun onExit(positionMs: Long)

    /** Session setup failed before or during playback; already released. */
    fun onError(reason: String)
  }

  private var core: MpvPlayerCore? = null
  private var attachedSurface: Surface? = null

  @Volatile private var lastKnownPositionMs: Long = request.positionMs
  private val ended = AtomicBoolean(false)

  override fun onSurfaceReady(surface: Surface, width: Int, height: Int) {
    if (core != null) {
      Log.w(TAG, "onSurfaceReady called twice; ignoring")
      return
    }
    val playerCore = MpvPlayerCore(context = activity, headless = true)
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
    core?.setProperty("pause", if (paused) "yes" else "no")
  }

  override fun onPropertyChange(name: String, value: Any?) {
    if (name == "time-pos") {
      val seconds = value as? Double ?: return
      lastKnownPositionMs = (seconds * 1000.0).toLong()
    }
  }

  override fun onEvent(name: String, data: Map<String, Any>?) = Unit

  private fun handleExit() {
    if (!ended.compareAndSet(false, true)) return
    val positionMs = lastKnownPositionMs
    release()
    callback.onExit(positionMs)
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
  }
}
