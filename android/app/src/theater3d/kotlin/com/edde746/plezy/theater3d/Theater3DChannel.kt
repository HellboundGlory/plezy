package com.edde746.plezy.theater3d

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * `MethodChannel('com.edde746.plezy/theater3d')` +
 * `EventChannel('com.edde746.plezy/theater3d/events')` handler — see
 * PLAN_3D.md 1.3. Owned by `MainActivity`, which reaches this class only
 * reflectively (THEATER_MODE=1 builds only); see this class's own
 * [AutoCloseable] contract and android/app/build.gradle.kts's
 * `src/theater3d` source set.
 *
 * `open` launches [Theater3DBridge] with a fresh [TheaterMpvSession]; the
 * session reports back through [Theater3DBridge.Listener], and this class
 * forwards `onExit`/`onError` to Dart as stream events, matching Phase 1's
 * `lib/quest/theater3d_bridge.dart` MethodChannel/EventChannel wrapper.
 */
class Theater3DChannel(
  private val activity: Activity,
  messenger: BinaryMessenger
) : AutoCloseable {
  private val methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
  private val eventChannel = EventChannel(messenger, EVENT_CHANNEL)
  private val mainHandler = Handler(Looper.getMainLooper())

  @Volatile private var eventSink: EventChannel.EventSink? = null
  private var activeSession: TheaterMpvSession? = null

  init {
    methodChannel.setMethodCallHandler { call, result ->
      when (call.method) {
        "open" -> handleOpen(call.arguments, result)
        else -> result.notImplemented()
      }
    }
    eventChannel.setStreamHandler(
      object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
          eventSink = sink
        }

        override fun onCancel(arguments: Any?) {
          eventSink = null
        }
      }
    )
  }

  private fun handleOpen(arguments: Any?, result: MethodChannel.Result) {
    val args = arguments as? Map<*, *>
    val uri = args?.get("uri") as? String
    if (args == null || uri == null) {
      result.error("bad_args", "theater3d open requires at least 'uri'", null)
      return
    }
    // Only one theater session at a time (Theater3DBridge.launch's own
    // contract) -- Phase 2's UI hides the affordance while active, so a
    // second `open` here is a caller bug, not a state transition to
    // reconcile. The already-active session's native teardown is driven
    // entirely by its own Theater3DActivity's lifecycle, independently of
    // this channel.
    if (activeSession != null) {
      Log.w(TAG, "open() while a theater session is already active; rejecting")
      result.error("already_open", "A theater session is already active", null)
      return
    }

    val request =
      Theater3DBridge.TheaterOpenRequest(
        uri = uri,
        headers = (args["headers"] as? Map<*, *>)?.entries?.associate { (k, v) -> k.toString() to v.toString() } ?: emptyMap(),
        positionMs = (args["positionMs"] as? Number)?.toLong() ?: 0L,
        audioTrackId = (args["audioTrackId"] as? Number)?.toInt(),
        subtitleTrackId = (args["subtitleTrackId"] as? Number)?.toInt(),
        stereoMode = args["stereoMode"] as? String ?: "off",
        shaderPath = args["shaderPath"] as? String
      )

    val session = TheaterMpvSession(activity, request, sessionCallback)
    activeSession = session
    Theater3DBridge.launch(activity, request, session)
    result.success(null)
  }

  private val sessionCallback =
    object : TheaterMpvSession.Callback {
      override fun onExit(positionMs: Long) {
        activeSession = null
        sendEvent(mapOf("event" to "onExit", "positionMs" to positionMs))
      }

      override fun onError(reason: String) {
        activeSession = null
        sendEvent(mapOf("event" to "onError", "reason" to reason))
      }
    }

  private fun sendEvent(payload: Map<String, Any?>) {
    mainHandler.post { eventSink?.success(payload) }
  }

  override fun close() {
    // No native teardown here: an active session's Theater3DActivity keeps
    // running and driving TheaterMpvSession's own lifecycle independently
    // of this Flutter-side channel (see [handleOpen]'s comment). Only stop
    // delivering events Dart can no longer receive.
    activeSession = null
    methodChannel.setMethodCallHandler(null)
    eventChannel.setStreamHandler(null)
    eventSink = null
  }

  companion object {
    private const val TAG = "Theater3DChannel"
    private const val METHOD_CHANNEL = "com.edde746.plezy/theater3d"
    private const val EVENT_CHANNEL = "com.edde746.plezy/theater3d/events"
  }
}
