package com.edde746.plezy.libmpv

import android.view.Surface

/**
 * Kotlin face of the mpv render-API host
 * (`android/libmpv/src/main/cpp/render_gl.cpp`): an EGL context this app owns,
 * an `mpv_render_context` bound to it, and the app's own fragment shader
 * running between mpv's frame and the presented Surface.
 *
 * Contrast with [MpvPlayer.attachSurfaces], which hands a Surface to a `vo` and
 * lets mpv drive everything from there. Here mpv renders into an FBO this app
 * owns, so the frame is a texture we can sample -- which is the whole point:
 * a per-frame input (a depth map, a steering value) has somewhere to go. mpv's
 * user-shader chain cannot do this, since a user shader's only per-frame inputs
 * are the frame it is handed plus static TEXTURE bytes read once at parse time.
 *
 * One host per process, like the mpv session underneath it. The two steps that
 * own ordering are both here:
 *
 *  1. Create it **after** mpv is initialized and **before** playback starts
 *     (`mpv/render.h`: video initialization reverts to a window-creating vo if
 *     no render context exists yet, and `vo=libmpv`'s `preinit` fails outright
 *     when there is none).
 *  2. Close it **before** the mpv session is destroyed, on a thread that is not
 *     the render thread. `mpv_render_context_free()` must run while its mpv
 *     core is still alive; [MpvPlayerCore] enforces this from its disposal
 *     thread (`renderHostTeardown`), so a caller that forgets costs nothing.
 */
class MpvRenderHost private constructor(
  private val player: MpvPlayer
) : AutoCloseable {

  @Volatile private var closed = false

  /**
   * Depth strength and mode for the warp pass, applied as shader uniforms
   * rather than baked into shader source. That is what retires the whole
   * recompile dance the mpv user-shader path needed: no per-strength file
   * names, no atomic rename, no mpv path-keyed shader cache. A change lands on
   * the next frame.
   */
  fun setStrength(strength: Double, synthetic: Boolean) {
    if (closed) return
    val result = MpvPlayer.nativeRenderSetStrength(player.session, strength.toFloat(), synthetic)
    if (result < 0) {
      android.util.Log.w(TAG, "setStrength($strength, $synthetic) rejected: error $result")
    }
  }

  override fun close() {
    if (closed) return
    closed = true
    synchronized(lock) {
      if (active === this) active = null
    }
    // Deliberately not session-checked natively: this must still reclaim a host
    // belonging to a session that has since been retired, or a successor's
    // create() would collide with it.
    MpvPlayer.nativeRenderDestroy(player.session)
  }

  companion object {
    private const val TAG = "MpvRenderHost"

    private val lock = Any()

    @Volatile private var active: MpvRenderHost? = null

    /**
     * Creates the host for [player] against [surface] (the compositor's own,
     * e.g. a Spatial SDK panel's), compiling [vertexShader] and [fragmentShader]
     * with it. [player] must be initialized and must have been configured with
     * `vo=libmpv`.
     *
     * Throws [MpvException] if EGL, the shader compile, the FBO or
     * `mpv_render_context_create` fails -- the specific stage is in logcat under
     * the `MpvRenderGl` tag; caller-visible detail here is the mpv error code.
     */
    fun create(
      player: MpvPlayer,
      surface: Surface,
      vertexShader: String,
      fragmentShader: String
    ): MpvRenderHost {
      synchronized(lock) {
        // A live host would make the native side reject this one (it holds a
        // single host per process); reclaim it first instead of failing, since
        // the only way to reach that state is a session that died without its
        // teardown running.
        active?.let {
          android.util.Log.w(TAG, "Replacing the render host left over from a previous session")
          it.close()
        }
        val result = MpvPlayer.nativeRenderCreate(player.session, surface, vertexShader, fragmentShader)
        if (result < 0) {
          throw MpvException("Failed to create the mpv render host: error $result")
        }
        return MpvRenderHost(player).also { active = it }
      }
    }
  }
}
