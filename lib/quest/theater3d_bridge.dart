// Quest / Horizon OS "3D Theater" side-mode -- see PLAN_3D.md Phase 1.
//
// Dart side of `MethodChannel('com.edde746.plezy/theater3d')` +
// `EventChannel('com.edde746.plezy/theater3d/events')`, whose native
// counterpart is android/app/src/theater3d/.../Theater3DChannel.kt. Quest-only:
// the channel only exists in THEATER_MODE=1 builds, so `open` on any other
// build rejects with [MissingPluginException] -- callers must treat that the
// same as a [TheaterErrorEvent] (see `Theater3DBridge.open`'s doc comment).
//
// This file is additive, mirroring `lib/quest/quest_platform.dart`: nothing
// outside `lib/quest/` (and, from Phase 2 on, the player screens that gate on
// [QuestPlatform.isQuest]) imports it.

import 'package:flutter/services.dart';

import 'quest_platform.dart';

/// Build-time marker set by the Quest theater-mode build command:
/// `--dart-define=THEATER_MODE_BUILD=true`, alongside `THEATER_MODE=1` (the
/// Kotlin-side gate for android/app/build.gradle.kts's `:theater3d` source
/// set). Dart cannot probe whether the platform channel actually exists
/// without invoking it, so this mirrors [kQuestBuild]'s advisory
/// `bool.fromEnvironment` idiom instead: real builds pass both flags
/// together (see QUEST_BUILD.md), so this const-folds true exactly when the
/// native channel is really compiled in.
const bool kTheaterModeBuild = bool.fromEnvironment('THEATER_MODE_BUILD');

/// Selected 3D playback mode for [Theater3DBridge.open]'s `stereoMode`
/// payload. Mirrors the native `StereoModeResolver` mapping exactly (see
/// PLAN_3D.md 1.5): `off`/`sbs`/`ou` are content already mastered as
/// SBS/OU 3D; `synthetic` is Phase 2's heuristic-depth shader, which always
/// packs its output as SBS on the native side regardless of this value.
enum TheaterStereoMode {
  off('off'),
  sbs('sbs'),
  ou('ou'),
  synthetic('synthetic');

  const TheaterStereoMode(this.wireValue);

  /// The exact string `StereoModeResolver.resolve` expects.
  final String wireValue;
}

/// A theater session ended cleanly -- the in-scene exit affordance, or a
/// swipe-dismiss of the panel -- at [positionMs] into the source. The
/// caller resumes its own paused flat-panel player there (see PLAN_3D.md
/// 1.3: the flat mpv session is paused, not disposed, for the duration).
///
/// [strength] is the depth strength the in-scene control was left at. The
/// native session owns no preferences, so persisting it is the caller's job
/// (see `theater3d.dart`).
class TheaterExitEvent {
  const TheaterExitEvent(this.positionMs, this.strength);

  final int positionMs;
  final double strength;

  @override
  String toString() => 'TheaterExitEvent(positionMs: $positionMs, strength: $strength)';

  @override
  bool operator ==(Object other) =>
      other is TheaterExitEvent && other.positionMs == positionMs && other.strength == strength;

  @override
  int get hashCode => Object.hash(positionMs, strength);
}

/// Theater session setup or playback failed (e.g. Spatial runtime
/// unavailable, panel registration failed, mpv init/load failed). The
/// native session is already torn down by the time this arrives; the panel
/// never opened, or was force-finished.
class TheaterErrorEvent {
  const TheaterErrorEvent(this.reason);

  final String reason;

  @override
  String toString() => 'TheaterErrorEvent(reason: $reason)';

  @override
  bool operator ==(Object other) => other is TheaterErrorEvent && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;
}

/// Dart side of the theater-mode MethodChannel/EventChannel pair. One
/// instance per caller is fine -- both channels are plain names, not
/// per-instance state, and [onExit]/[onError] are broadcast streams so
/// multiple listeners (or multiple instances) all observe every event.
class Theater3DBridge {
  Theater3DBridge() : _methodChannel = const MethodChannel(_methodChannelName), _eventChannel = const EventChannel(_eventChannelName);

  static const _methodChannelName = 'com.edde746.plezy/theater3d';
  static const _eventChannelName = 'com.edde746.plezy/theater3d/events';

  /// Whether theater mode can plausibly be entered here: a Horizon OS
  /// headset (see [QuestPlatform.isQuest]) running a build compiled with
  /// [kTheaterModeBuild]. Gates the player's 3D button's very existence
  /// (see track_chapter_controls.dart) -- like both inputs it is advisory,
  /// not a confirmation the platform channel is actually registered, so a
  /// false positive still fails safely through [open]'s
  /// [MissingPluginException] path.
  static bool get isAvailable => QuestPlatform.isQuest && kTheaterModeBuild;

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  Stream<Map<Object?, Object?>>? _events;

  Stream<Map<Object?, Object?>> get _rawEvents => _events ??= _eventChannel.receiveBroadcastStream().cast<Map<Object?, Object?>>();

  /// Fires once per theater session that ends without error.
  Stream<TheaterExitEvent> get onExit => _rawEvents.where((event) => event['event'] == 'onExit').map(
    (event) => TheaterExitEvent(
      (event['positionMs'] as num).toInt(),
      // Absent only if an older native session is talking to this Dart side;
      // fall back to the neutral default rather than throwing on the stream.
      (event['strength'] as num?)?.toDouble() ?? 0.5,
    ),
  );

  /// Fires for setup/playback failures. A session that reports an error
  /// never also reports an exit.
  Stream<TheaterErrorEvent> get onError =>
      _rawEvents.where((event) => event['event'] == 'onError').map((event) => TheaterErrorEvent(event['reason'] as String));

  /// Launches `Theater3DActivity` with everything needed to resume the
  /// exact session the flat-panel player is showing: [uri]/[headers]
  /// identical to what was passed to its own `open`, [position] its current
  /// playback position, and the selected [stereoMode].
  ///
  /// [vertexShader] and [fragmentShader] are the GLSL ES 3.0 sources the
  /// native render-API host compiles and runs on mpv's output
  /// (`assets/shaders/theater3d/`, see `ShaderAssetLoader
  /// .loadTheater3DWarpShaders`). They are required for every mode: even real
  /// SBS/OU passthrough needs a program to put mpv's frame on the panel.
  /// [synthetic] says which job that program does -- `true` invents a depth
  /// field and packs a side-by-side pair, `false` copies the frame through
  /// untouched, which is what content that already carries parallax needs.
  ///
  /// [strength] rides alongside as a number because it is a shader uniform in
  /// the app's own pass, not a constant baked into a file: the in-scene slider
  /// changes the picture on the next frame, and nothing is recompiled.
  ///
  /// Only one theater session is allowed at a time; calling this while one
  /// is already active rejects with a [PlatformException]
  /// (`already_open`). On a non-THEATER_MODE build the channel does not
  /// exist at all and this rejects with a [MissingPluginException] --
  /// callers on Quest-only surfaces should not normally hit that path, but
  /// must handle it the same as a session that reports [TheaterErrorEvent]
  /// rather than let it propagate as an unhandled platform error.
  ///
  /// [hwdec] is the mpv `hwdec` value the native session applies before its
  /// load. It is required rather than defaulted because a wrong-but-plausible
  /// default here silently means CPU decoding.
  ///
  /// [strength] is the depth strength the in-scene control starts at, 0.0-1.0.
  /// It travels as a number so the controls can show the current setting and
  /// change it live, without the value being encoded anywhere else.
  Future<void> open({
    required String uri,
    Map<String, String> headers = const {},
    Duration position = Duration.zero,
    int? audioTrackId,
    int? subtitleTrackId,
    required TheaterStereoMode stereoMode,
    required String vertexShader,
    required String fragmentShader,
    required bool synthetic,
    double strength = 0.5,
    required String hwdec,
  }) {
    return _methodChannel.invokeMethod<void>('open', {
      'uri': uri,
      'headers': headers,
      'positionMs': position.inMilliseconds,
      'audioTrackId': audioTrackId,
      'subtitleTrackId': subtitleTrackId,
      'stereoMode': stereoMode.wireValue,
      'vertexShader': vertexShader,
      'fragmentShader': fragmentShader,
      'synthetic': synthetic,
      'strength': strength,
      'hwdec': hwdec,
    });
  }
}
