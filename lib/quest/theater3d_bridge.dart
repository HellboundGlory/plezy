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
class TheaterExitEvent {
  const TheaterExitEvent(this.positionMs);

  final int positionMs;

  @override
  String toString() => 'TheaterExitEvent(positionMs: $positionMs)';

  @override
  bool operator ==(Object other) => other is TheaterExitEvent && other.positionMs == positionMs;

  @override
  int get hashCode => positionMs.hashCode;
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
  Stream<TheaterExitEvent> get onExit =>
      _rawEvents.where((event) => event['event'] == 'onExit').map((event) => TheaterExitEvent((event['positionMs'] as num).toInt()));

  /// Fires for setup/playback failures. A session that reports an error
  /// never also reports an exit.
  Stream<TheaterErrorEvent> get onError =>
      _rawEvents.where((event) => event['event'] == 'onError').map((event) => TheaterErrorEvent(event['reason'] as String));

  /// Launches `Theater3DActivity` with everything needed to resume the
  /// exact session the flat-panel player is showing: [uri]/[headers]
  /// identical to what was passed to its own `open`, [position] its current
  /// playback position, and the selected [stereoMode]. [shaderPath] is the
  /// heuristic pseudo-3D shader to run inside the theater session's own mpv
  /// instance, materialized at the selected strength by
  /// `ShaderAssetLoader.materializePseudo3DShader` -- it is only meaningful
  /// for [TheaterStereoMode.synthetic], and null for real SBS/OU passthrough
  /// content, which already has parallax and must not be re-processed.
  ///
  /// Strength travels as a path, not a number, because mpv can only
  /// override a user shader's `//!PARAM` on `vo=gpu-next`; the theater
  /// session's GL backend is chosen per file, so the value is baked into the
  /// shader source instead. See that method's doc comment.
  ///
  /// Only one theater session is allowed at a time; calling this while one
  /// is already active rejects with a [PlatformException]
  /// (`already_open`). On a non-THEATER_MODE build the channel does not
  /// exist at all and this rejects with a [MissingPluginException] --
  /// callers on Quest-only surfaces should not normally hit that path, but
  /// must handle it the same as a session that reports [TheaterErrorEvent]
  /// rather than let it propagate as an unhandled platform error.
  Future<void> open({
    required String uri,
    Map<String, String> headers = const {},
    Duration position = Duration.zero,
    int? audioTrackId,
    int? subtitleTrackId,
    required TheaterStereoMode stereoMode,
    String? shaderPath,
  }) {
    return _methodChannel.invokeMethod<void>('open', {
      'uri': uri,
      'headers': headers,
      'positionMs': position.inMilliseconds,
      'audioTrackId': audioTrackId,
      'subtitleTrackId': subtitleTrackId,
      'stereoMode': stereoMode.wireValue,
      'shaderPath': shaderPath,
    });
  }
}
