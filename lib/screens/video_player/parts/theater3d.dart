part of '../../video_player_screen.dart';

/// Wires the 3D settings sheet to [Theater3DBridge.open] (PLAN_3D.md Phase 2).
extension _VideoPlayerTheater3DMethods on VideoPlayerScreenState {
  Theater3DBridge get _theater3d => Theater3DBridge();

  TheaterStereoMode _resolveTheaterStereoMode(ThreeDMode mode) {
    switch (mode) {
      case ThreeDMode.off:
        return TheaterStereoMode.off;
      case ThreeDMode.sbs:
        return TheaterStereoMode.sbs;
      case ThreeDMode.ou:
        return TheaterStereoMode.ou;
      case ThreeDMode.auto:
        return switch (StereoSourceDetector.detectFromFileName(_currentMetadata.title ?? '')) {
          DetectedStereoLayout.sbs => TheaterStereoMode.sbs,
          DetectedStereoLayout.ou => TheaterStereoMode.ou,
          DetectedStereoLayout.none => TheaterStereoMode.synthetic,
        };
    }
  }

  Future<void> _launchTheaterMode(ThreeDMode mode, double strength) async {
    if (mode == ThreeDMode.off || !Theater3DBridge.isAvailable) return;
    final currentPlayer = player;
    final videoUrl = _lastOpenedVideoUrl;
    if (currentPlayer == null || videoUrl == null) return;

    final resumePosition = currentPlayer.state.position;
    await currentPlayer.pause();

    final stereoMode = _resolveTheaterStereoMode(mode);
    // Only the synthetic (heuristic-depth) mode runs a shader inside the
    // theater session: real SBS/OU passthrough already carries parallax, and
    // re-processing it would split the split rather than add depth. The
    // strength is baked into the shader source by the loader because mpv can
    // only override a `//!PARAM` on vo=gpu-next, while the theater session's
    // GL backend is picked per file -- see
    // `ShaderAssetLoader.materializePseudo3DShader`.
    String? shaderPath;
    if (stereoMode == TheaterStereoMode.synthetic) {
      shaderPath = await ShaderAssetLoader.materializePseudo3DShader(strength);
      if (shaderPath == null) {
        appLogger.e(
          'Pseudo-3D shader unavailable; without it the compositor would show each eye a '
          'different half of the flat frame, so theater mode will look cropped and doubled',
        );
      }
    }

    // Decoder backend for the theater session's own mpv core. It must be
    // carried explicitly: the flat player writes `hwdec` from Dart
    // (`_getHwdecValue` below), and the theater core is a second, headless
    // session that no Dart property write reaches -- so left alone it sat on
    // mpv's default of `no` and decoded on the CPU, which is what made
    // theater mode play at a fraction of real time and drift out of sync
    // with the audio.
    //
    // `mediacodec-copy` rather than zero-copy `mediacodec` whenever a shader
    // is in the chain: zero-copy hands mpv external OES textures, while
    // `-copy` still decodes on MediaCodec but returns ordinary frames mpv
    // uploads as normal textures -- the deterministic pairing with a user
    // shader. With no shader (real SBS/OU passthrough) the full fallback list
    // is used, matching what the flat player runs on this device.
    var hwdec = _getHwdecValue(SettingsService.instance.read(SettingsService.enableHardwareDecoding));
    if (shaderPath != null && hwdec != 'no') hwdec = 'mediacodec-copy';

    late final StreamSubscription<TheaterExitEvent> exitSubscription;
    late final StreamSubscription<TheaterErrorEvent> errorSubscription;
    var settled = false;

    Future<void> resumeFlatPlayer(Duration position) async {
      if (!mounted || player != currentPlayer) return;
      await currentPlayer.seek(position);
      if (_playbackIntentShouldPlay) await currentPlayer.play();
    }

    void settle() {
      if (settled) return;
      settled = true;
      unawaited(exitSubscription.cancel());
      unawaited(errorSubscription.cancel());
    }

    exitSubscription = _theater3d.onExit.listen((event) {
      settle();
      // The in-scene depth control has no way back to prefs on its own, so
      // whatever it was left at becomes the remembered strength for this
      // title -- same scope the settings sheet writes to.
      if (stereoMode == TheaterStereoMode.synthetic) {
        unawaited(ScopedPlayerPrefs.write(ScopedPlayerPrefs.threeDStrength, _currentMetadata, event.strength));
      }
      unawaited(resumeFlatPlayer(Duration(milliseconds: event.positionMs)));
    });
    errorSubscription = _theater3d.onError.listen((event) {
      settle();
      if (mounted) showErrorSnackBar(context, t.videoControls.theaterModeFailed(reason: event.reason));
      unawaited(resumeFlatPlayer(resumePosition));
    });

    try {
      await _theater3d.open(
        uri: videoUrl,
        headers: _lastOpenedHeaders ?? const {},
        position: resumePosition,
        stereoMode: stereoMode,
        shaderPath: shaderPath,
        strength: strength,
        hwdec: hwdec,
      );
    } catch (e, st) {
      settle();
      appLogger.w('Failed to open theater mode', error: e, stackTrace: st);
      if (mounted) showErrorSnackBar(context, t.videoControls.theaterModeFailed(reason: e.toString()));
      await resumeFlatPlayer(resumePosition);
    }
  }
}
