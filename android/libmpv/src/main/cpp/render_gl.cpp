// mpv render API host: an EGL context WE own, an mpv_render_context bound to
// it, and the app's own fragment shader between mpv's frame and the compositor.
//
// Why this exists (see HANDOFF_RENDER_API.md): the `vo` path hands decoded
// frames to a video output mpv drives, so the only place an app shader can run
// is mpv's user-shader chain -- where the input is static TEXTURE bytes read
// once at parse time and nothing per-frame can be injected. The render API
// instead makes mpv render into an FBO we own, which leaves the frame in a
// texture we can sample, warp and repack ourselves.
//
// Ownership, and why it is split the way it is:
//
//  - The JNI thread (Kotlin) creates EGL, the GL objects and the
//    mpv_render_context with the context current on itself, then hands the
//    context to the GL thread. That keeps every use of the mpv_handle on a
//    thread that holds session admission (SessionGuard), so this file never
//    reasons about handle lifetime. mpv explicitly permits calling
//    mpv_render_*() from a thread other than the one that called
//    mpv_render_context_create() as of API 1.105 / mpv 0.30 (render.h's "Note
//    about old libmpv version").
//
//  - A dedicated GL thread does all rendering, always with the context
//    current. mpv's update callback fires on an mpv thread and does nothing
//    but set a flag and signal a condition variable: render.h forbids calling
//    any mpv_render_*() function from inside that callback.
//
//  - The GL thread never touches the mpv_handle, the JVM or the Java Surface;
//    it only calls that context's mpv_render_context_*() functions and
//    GL/EGL. The frame loop therefore crosses JNI zero times and allocates
//    nothing.
//
// No MPV_RENDER_PARAM_ADVANCED_CONTROL. That flag changes who owns
// presentation timing (HANDOFF_RENDER_API.md section 7) and turns any
// render-thread stall into a real deadlock instead of a time-out; its only
// benefits here would be direct rendering and GPU screenshots.
//
// Timing stays mpv's without it, and the handshake is worth stating exactly
// because it is easy to get wrong. Per frame, in vo_libmpv.c:
//   vo thread  draw_frame()  -> stores next_frame, calls the update callback
//   vo thread  flip_page()   -> waits for next_frame to clear (200 ms cap)
//   GL thread  render()      -> clears next_frame, rasterizes, then honours
//                               MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, whose
//                               default is 1 (BLOCK) when the param is absent
//   vo thread  flip_page()   -> present_count += 1, releasing that wait
// So the two threads rendezvous once per frame and `report_swap` is genuinely
// optional: flip_page's own flip_count wait breaks out immediately while
// flip_count is still 0, which is why presentation is left entirely to
// eglSwapBuffers. Passing BLOCK_FOR_TARGET_TIME=0 would not "skip blocking" --
// the param is absent from our array either way -- it would be a no-op.

#include <jni.h>
#include <mpv/client.h>
#include <mpv/render.h>
#include <mpv/render_gl.h>

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <pthread.h>

#include <atomic>
#include <cstdio>
#include <new>
#include <string>

#include "globals.h"
#include "jni_utils.h"

// EGL and GLES are needed by this file alone; CMakeLists links libEGL and
// libGLESv3 into `player` for it.
#include <EGL/egl.h>
#include <GLES3/gl3.h>

#ifndef EGL_OPENGL_ES3_BIT_KHR
#define EGL_OPENGL_ES3_BIT_KHR 0x0040
#endif

#define RENDER_TAG "MpvRenderGl"
#define RLOGI(...) __android_log_print(ANDROID_LOG_INFO, RENDER_TAG, __VA_ARGS__)
#define RLOGE(...) __android_log_print(ANDROID_LOG_ERROR, RENDER_TAG, __VA_ARGS__)

namespace {

// One render host at a time, exactly like the mpv session it belongs to.
//
// Lock order (see globals.h): L -> S -> R. `host_lock` (R) is only ever taken
// by nativeRenderCreate/nativeRenderSetStrength/nativeRenderDestroy, and never
// after releasing S. The GL thread takes neither: it is driven through the
// per-host `lock`/`cond` pair and, once running, touches only GL/EGL and its
// own context's mpv_render_*() calls -- so joining it can never deadlock
// against an in-flight JNI entry.
struct RenderHost {
  pthread_t thread{};
  bool thread_started = false;

  // Signalling between the update callback (and destroy) and the GL thread.
  pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
  pthread_cond_t cond = PTHREAD_COND_INITIALIZER;
  bool exit_requested = false;
  bool wake = false;

  // Immutable once the GL thread starts.
  jobject surface = nullptr;  // global ref, released by the JNI thread
  std::string vertex_shader;
  std::string fragment_shader;

  // Cross-thread shader inputs: written by JNI, read once per frame by the GL
  // thread. Atomics rather than the host lock so a slider drag never blocks a
  // frame and a frame never blocks the UI thread.
  std::atomic<float> strength{0.5f};
  std::atomic<bool> synthetic{false};

  // GL thread only.
  mpv_render_context* mpv_ctx = nullptr;
  EGLDisplay display = EGL_NO_DISPLAY;
  EGLContext context = EGL_NO_CONTEXT;
  EGLSurface window = EGL_NO_SURFACE;
  ANativeWindow* native_window = nullptr;
  GLuint fbo = 0;
  GLuint frame_texture = 0;
  GLuint program = 0;
  GLuint vbo = 0;
  GLint attr_pos = -1;
  GLint u_frame = -1;
  GLint u_strength = -1;
  GLint u_resolution = -1;
  GLint u_synthetic = -1;
  int width = 0;
  int height = 0;
  uint64_t frames = 0;  // guarded by `lock`
};

RenderHost* g_host = nullptr;
pthread_mutex_t host_lock = PTHREAD_MUTEX_INITIALIZER;

class HostGuard {
 public:
  HostGuard() { pthread_mutex_lock(&host_lock); }
  ~HostGuard() { pthread_mutex_unlock(&host_lock); }
  HostGuard(const HostGuard&) = delete;
  HostGuard& operator=(const HostGuard&) = delete;
};

// Resolves GL entry points for mpv. Mirrors mpv's own Android loader
// (video/out/opengl/egl_helpers.c: mpegl_get_proc_address): EGL 1.5 requires
// eglGetProcAddress() to answer for client-API functions too, with a
// dlsym(RTLD_DEFAULT) fallback for drivers that only answer for extensions.
// libGLESv3 is linked, so RTLD_DEFAULT resolves the core functions.
void* gl_proc_address(void* /*ctx*/, const char* name) {
  void* address = reinterpret_cast<void*>(eglGetProcAddress(name));
  if (!address) address = dlsym(RTLD_DEFAULT, name);
  return address;
}

// mpv's "there is a new frame" notification, on an mpv thread. Must not touch
// mpv_render_*() -- see render.h's threading section.
void update_callback(void* arg) {
  auto* host = static_cast<RenderHost*>(arg);
  pthread_mutex_lock(&host->lock);
  host->wake = true;
  pthread_cond_broadcast(&host->cond);
  pthread_mutex_unlock(&host->lock);
}

std::string egl_error_text(const char* stage) {
  char buffer[160];
  snprintf(buffer, sizeof(buffer), "%s failed (EGL error 0x%04x)", stage, eglGetError());
  return std::string(buffer);
}

bool make_current(RenderHost* host) {
  return eglMakeCurrent(host->display, host->window, host->window, host->context) == EGL_TRUE;
}

bool unset_current(RenderHost* host) {
  const bool ok = eglMakeCurrent(host->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT) == EGL_TRUE;
  eglReleaseThread();
  return ok;
}

bool setup_gl_objects(RenderHost* host) {
  glGenTextures(1, &host->frame_texture);
  glBindTexture(GL_TEXTURE_2D, host->frame_texture);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, host->width, host->height, 0, GL_RGBA, GL_UNSIGNED_BYTE, nullptr);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  glGenFramebuffers(1, &host->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, host->fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, host->frame_texture, 0);
  const GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (status != GL_FRAMEBUFFER_COMPLETE) {
    RLOGE("Frame FBO incomplete: 0x%04x", status);
    return false;
  }

  const char* vertex_source = host->vertex_shader.c_str();
  const GLuint vertex = glCreateShader(GL_VERTEX_SHADER);
  glShaderSource(vertex, 1, &vertex_source, nullptr);
  glCompileShader(vertex);
  GLint ok = GL_FALSE;
  glGetShaderiv(vertex, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[1024] = {0};
    glGetShaderInfoLog(vertex, sizeof(log), nullptr, log);
    RLOGE("Vertex shader compile failed: %s", log);
    glDeleteShader(vertex);
    return false;
  }

  const char* fragment_source = host->fragment_shader.c_str();
  const GLuint fragment = glCreateShader(GL_FRAGMENT_SHADER);
  glShaderSource(fragment, 1, &fragment_source, nullptr);
  glCompileShader(fragment);
  glGetShaderiv(fragment, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    char log[2048] = {0};
    glGetShaderInfoLog(fragment, sizeof(log), nullptr, log);
    RLOGE("Fragment shader compile failed: %s", log);
    glDeleteShader(vertex);
    glDeleteShader(fragment);
    return false;
  }

  host->program = glCreateProgram();
  glAttachShader(host->program, vertex);
  glAttachShader(host->program, fragment);
  glLinkProgram(host->program);
  glGetProgramiv(host->program, GL_LINK_STATUS, &ok);
  // Attaching transfers ownership to the program; delete either way.
  glDeleteShader(vertex);
  glDeleteShader(fragment);
  if (!ok) {
    char log[2048] = {0};
    glGetProgramInfoLog(host->program, sizeof(log), nullptr, log);
    RLOGE("Shader program link failed: %s", log);
    return false;
  }

  host->u_frame = glGetUniformLocation(host->program, "uFrame");
  host->u_strength = glGetUniformLocation(host->program, "uStrength");
  host->u_resolution = glGetUniformLocation(host->program, "uResolution");
  host->u_synthetic = glGetUniformLocation(host->program, "uSynthetic");
  host->attr_pos = glGetAttribLocation(host->program, "aPos");
  if (host->u_frame < 0 || host->u_strength < 0 || host->u_resolution < 0 || host->u_synthetic < 0 || host->attr_pos < 0) {
    RLOGE("Warp shader is missing a required input among aPos/uFrame/uStrength/uResolution/uSynthetic");
    return false;
  }

  // One oversized triangle covering the clip square: cheaper and seam-free
  // versus two triangles, and it needs no index buffer.
  static const GLfloat vertices[] = {-1.0f, -1.0f, 3.0f, -1.0f, -1.0f, 3.0f};
  glGenBuffers(1, &host->vbo);
  glBindBuffer(GL_ARRAY_BUFFER, host->vbo);
  glBufferData(GL_ARRAY_BUFFER, sizeof(vertices), vertices, GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  return true;
}

// Creates everything that needs a current GL context, on the calling thread,
// then releases the context so the GL thread becomes its only owner.
int setup(JNIEnv* env, RenderHost* host, mpv_handle* mpv) {
  host->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  if (host->display == EGL_NO_DISPLAY) {
    RLOGE("eglGetDisplay returned no display");
    return MPV_ERROR_UNSUPPORTED;
  }

  EGLint major = 0;
  EGLint minor = 0;
  if (!eglInitialize(host->display, &major, &minor)) {
    RLOGE("%s", egl_error_text("eglInitialize").c_str());
    return MPV_ERROR_UNSUPPORTED;
  }

  const EGLint config_attribs[] = {
      EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
      EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
      EGL_RED_SIZE, 8,
      EGL_GREEN_SIZE, 8,
      EGL_BLUE_SIZE, 8,
      EGL_ALPHA_SIZE, 8,
      EGL_NONE};
  EGLConfig config = nullptr;
  EGLint config_count = 0;
  if (!eglChooseConfig(host->display, config_attribs, &config, 1, &config_count) || config_count < 1) {
    RLOGE("%s", egl_error_text("eglChooseConfig").c_str());
    return MPV_ERROR_UNSUPPORTED;
  }

  host->native_window = ANativeWindow_fromSurface(env, host->surface);
  if (!host->native_window) {
    RLOGE("ANativeWindow_fromSurface returned null");
    return MPV_ERROR_INVALID_PARAMETER;
  }

  host->window = eglCreateWindowSurface(host->display, config, host->native_window, nullptr);
  if (host->window == EGL_NO_SURFACE) {
    RLOGE("Panel Surface cannot be an EGL window surface: %s", egl_error_text("eglCreateWindowSurface").c_str());
    return MPV_ERROR_UNSUPPORTED;
  }

  const EGLint context_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
  host->context = eglCreateContext(host->display, config, EGL_NO_CONTEXT, context_attribs);
  if (host->context == EGL_NO_CONTEXT) {
    RLOGE("%s", egl_error_text("eglCreateContext").c_str());
    return MPV_ERROR_UNSUPPORTED;
  }
  if (!make_current(host)) {
    RLOGE("%s", egl_error_text("eglMakeCurrent").c_str());
    return MPV_ERROR_UNSUPPORTED;
  }

  if (!eglQuerySurface(host->display, host->window, EGL_WIDTH, &host->width) ||
      !eglQuerySurface(host->display, host->window, EGL_HEIGHT, &host->height) || host->width <= 0 || host->height <= 0) {
    RLOGE("Panel Surface reports no usable size");
    return MPV_ERROR_UNSUPPORTED;
  }

  RLOGI(
      "egl %d.%d ready: %dx%d, GL_RENDERER=%s, GL_VERSION=%s",
      major, minor, host->width, host->height,
      reinterpret_cast<const char*>(glGetString(GL_RENDERER)),
      reinterpret_cast<const char*>(glGetString(GL_VERSION)));

  if (!setup_gl_objects(host)) return MPV_ERROR_GENERIC;

  mpv_opengl_init_params init_params{};
  init_params.get_proc_address = &gl_proc_address;
  init_params.get_proc_address_ctx = nullptr;
  int advanced_control = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init_params},
      {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced_control},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  const int result = mpv_render_context_create(&host->mpv_ctx, mpv, params);
  if (result < 0) {
    RLOGE("mpv_render_context_create: %s", mpv_error_string(result));
    return result;
  }
  // set_update_callback() invokes the callback once immediately, on this
  // thread, which is why it is installed before the GL thread exists.
  mpv_render_context_set_update_callback(host->mpv_ctx, &update_callback, host);

  unset_current(host);
  return 0;
}

void draw_frame(RenderHost* host) {
  mpv_opengl_fbo target{};
  target.fbo = static_cast<int>(host->fbo);
  target.w = host->width;
  target.h = host->height;
  // 8-bit target, stated explicitly: mpv picks its dithering from this.
  target.internal_format = GL_RGBA8;
  // FLIP_Y=1 is not the "rendering to a screen" case from render.h's doc; it
  // is the storage layout the warp pass wants. gl_video's flip transform
  // (video/out/gpu/video.c: get_transform) mirrors y while writing, so with it
  // row 0 of our texture holds the image's bottom row -- and EGL presents a
  // window surface the same way round, so a plain texture-mapped quad comes
  // out upright with no extra inversion.
  int flip_y = 1;
  int depth_bits = 8;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &target},
      {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
      {MPV_RENDER_PARAM_DEPTH, &depth_bits},
      {MPV_RENDER_PARAM_INVALID, nullptr},
  };
  const int result = mpv_render_context_render(host->mpv_ctx, params);
  if (result < 0) {
    static bool logged = false;
    if (!logged) {
      logged = true;
      RLOGE("mpv_render_context_render: %s", mpv_error_string(result));
    }
    // A redraw request with nothing to draw is not an error worth skipping
    // presentation for: mpv is expected to leave the frame target intact.
  }

  // Back to the panel's own surface for the warp/pack pass. mpv leaves the
  // viewport/scissor/blend state to us (render_gl.h's "OpenGL state" list).
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glViewport(0, 0, host->width, host->height);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_SCISSOR_TEST);
  glUseProgram(host->program);
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, host->frame_texture);
  glUniform1i(host->u_frame, 0);
  glUniform1f(host->u_strength, host->strength.load());
  glUniform2f(host->u_resolution, static_cast<GLfloat>(host->width), static_cast<GLfloat>(host->height));
  glUniform1i(host->u_synthetic, host->synthetic.load() ? 1 : 0);
  glBindBuffer(GL_ARRAY_BUFFER, host->vbo);
  glEnableVertexAttribArray(host->attr_pos);
  glVertexAttribPointer(host->attr_pos, 2, GL_FLOAT, GL_FALSE, 0, nullptr);
  glDrawArrays(GL_TRIANGLES, 0, 3);
  glDisableVertexAttribArray(host->attr_pos);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  eglSwapBuffers(host->display, host->window);
}

// Render context first, while its GL context is current: render.h requires the
// context to be freed before the mpv core is destroyed, and freeing it needs
// the same current context it was created with.
void teardown(RenderHost* host) {
  const bool gl_ready = host->display != EGL_NO_DISPLAY && host->context != EGL_NO_CONTEXT;
  if (gl_ready) make_current(host);

  if (host->mpv_ctx) {
    mpv_render_context_free(host->mpv_ctx);
    host->mpv_ctx = nullptr;
  }
  if (gl_ready) {
    if (host->program) glDeleteProgram(host->program);
    if (host->vbo) glDeleteBuffers(1, &host->vbo);
    if (host->fbo) glDeleteFramebuffers(1, &host->fbo);
    if (host->frame_texture) glDeleteTextures(1, &host->frame_texture);
    unset_current(host);
  }
  if (host->display != EGL_NO_DISPLAY) {
    if (host->window != EGL_NO_SURFACE) eglDestroySurface(host->display, host->window);
    if (host->context != EGL_NO_CONTEXT) eglDestroyContext(host->display, host->context);
    eglTerminate(host->display);
    host->display = EGL_NO_DISPLAY;
    host->window = EGL_NO_SURFACE;
    host->context = EGL_NO_CONTEXT;
  }
  if (host->native_window) {
    ANativeWindow_release(host->native_window);
    host->native_window = nullptr;
  }
}

void* gl_thread_main(void* arg) {
  auto* host = static_cast<RenderHost*>(arg);
  if (!make_current(host)) {
    RLOGE("%s", egl_error_text("eglMakeCurrent").c_str());
  }
  RLOGI("Render thread started");

  pthread_mutex_lock(&host->lock);
  for (;;) {
    while (!host->exit_requested && !host->wake) pthread_cond_wait(&host->cond, &host->lock);
    if (host->exit_requested) break;
    host->wake = false;
    const bool first = host->frames == 0;
    const uint64_t frames = ++host->frames;
    pthread_mutex_unlock(&host->lock);

    draw_frame(host);

    // Milestones rather than a per-frame line: this is the on-device proof that
    // the render loop is alive (HANDOFF_RENDER_API.md's verification plan).
    if (first) RLOGI("First frame rendered");
    else if (frames % 300 == 0) RLOGI("%llu frames rendered", static_cast<unsigned long long>(frames));

    pthread_mutex_lock(&host->lock);
  }
  pthread_mutex_unlock(&host->lock);

  teardown(host);
  RLOGI("Render thread stopped");
  return nullptr;
}

}  // namespace

// Called by Kotlin before the mpv core is destroyed (and again, defensively,
// by main.cpp's destroy_locked with the lifecycle lock held) so the render
// context is always freed while its core is still alive.
//
// Takes R only. Hosts are process-global rather than per-session, so a leaked
// host is reaped by whatever teardown comes next instead of surviving to
// outlive the mpv core it renders for.
void render_gl_shutdown(JNIEnv* env) {
  HostGuard guard;
  if (!g_host) return;
  RenderHost* host = g_host;
  g_host = nullptr;

  pthread_mutex_lock(&host->lock);
  host->exit_requested = true;
  pthread_cond_broadcast(&host->cond);
  pthread_mutex_unlock(&host->lock);
  if (host->thread_started) pthread_join(host->thread, nullptr);
  pthread_mutex_destroy(&host->lock);
  pthread_cond_destroy(&host->cond);
  if (host->surface) env->DeleteGlobalRef(host->surface);
  delete host;
}

extern "C" {
jni_func(jint, nativeRenderCreate, jlong session, jobject surface, jstring vertex_shader, jstring fragment_shader);
jni_func(void, nativeRenderDestroy, jlong session);
jni_func(jint, nativeRenderSetStrength, jlong session, jfloat strength, jboolean synthetic);
};

// Every mpv_handle use happens here, on this thread, while SessionGuard holds
// admission -- so a concurrently-retiring session either refuses this entry
// outright or waits for it, but can never terminate the core underneath it.
jni_func(jint, nativeRenderCreate, jlong session, jobject surface, jstring vertex_shader, jstring fragment_shader) {
  SessionGuard admission(session);
  if (!admission.mpv) return MPV_ERROR_UNINITIALIZED;
  if (!surface || !vertex_shader || !fragment_shader) return MPV_ERROR_INVALID_PARAMETER;

  HostGuard guard;
  if (g_host) {
    RLOGE("A render host already exists for this process");
    return MPV_ERROR_GENERIC;
  }

  const std::string vertex = java_string_to_utf8(env, vertex_shader);
  const std::string fragment = java_string_to_utf8(env, fragment_shader);
  if (env->ExceptionCheck()) return MPV_ERROR_NOMEM;

  auto* host = new (std::nothrow) RenderHost();
  if (!host) return MPV_ERROR_NOMEM;
  host->vertex_shader = vertex;
  host->fragment_shader = fragment;
  host->surface = env->NewGlobalRef(surface);
  if (!host->surface) {
    delete host;
    return MPV_ERROR_NOMEM;
  }

  const int result = setup(env, host, admission.mpv);
  if (result < 0) {
    teardown(host);
    env->DeleteGlobalRef(host->surface);
    pthread_mutex_destroy(&host->lock);
    pthread_cond_destroy(&host->cond);
    delete host;
    return result;
  }

  g_host = host;
  if (pthread_create(&host->thread, nullptr, gl_thread_main, host) != 0) {
    RLOGE("Could not start the render thread");
    g_host = nullptr;
    teardown(host);
    env->DeleteGlobalRef(host->surface);
    pthread_mutex_destroy(&host->lock);
    pthread_cond_destroy(&host->cond);
    delete host;
    return MPV_ERROR_GENERIC;
  }
  host->thread_started = true;
  pthread_setname_np(host->thread, "theater-gl");
  return 0;
}

jni_func(void, nativeRenderDestroy, jlong session) {
  (void)session;
  render_gl_shutdown(env);
}

jni_func(jint, nativeRenderSetStrength, jlong session, jfloat strength, jboolean synthetic) {
  SessionGuard admission(session);
  if (!admission.mpv) return MPV_ERROR_UNINITIALIZED;
  HostGuard guard;
  if (!g_host) return MPV_ERROR_UNINITIALIZED;
  // A uniform, so it lands on the next frame with no recompile and no shader
  // rewrite -- which is the point of owning the pass (HANDOFF_RENDER_API.md
  // section 3.3, and the mpv user-shader cache trap it retires).
  g_host->strength.store(strength);
  g_host->synthetic.store(synthetic == JNI_TRUE);
  return 0;
}
