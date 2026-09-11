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

    // Every mode runs this app's own GL program on mpv's output; only what it
    // *does* differs. Real SBS/OU passthrough copies the frame through, since
    // the source already carries parallax and re-processing it would split the
    // split rather than add depth; the synthetic mode invents a depth field and
    // packs a side-by-side pair. The shaders are plain asset text now -- no
    // per-strength bake, no file for mpv to parse, no shader cache to defeat.
    final shaders = await ShaderAssetLoader.loadTheater3DWarpShaders();
    final synthetic = stereoMode == TheaterStereoMode.synthetic;

    // Decoder backend for the theater session's own mpv core. It must be
    // carried explicitly: the flat player writes `hwdec` from Dart
    // (`_getHwdecValue` below), and the theater core is a second, headless
    // session that no Dart property write reaches -- so left alone it sat on
    // mpv's default of `no` and decoded on the CPU, which is what made theater
    // mode play at a fraction of real time and drift out of sync with the
    // audio.
    //
    // The value is the same one the flat player uses, zero-copy included: the
    // render-API pass is a GL pass this app owns, and mpv reaches GL from
    // MediaCodec through its `aimagereader` interop. The old
    // `mediacodec-copy` downgrade here existed only to hand a *user shader*
    // ordinary textures, which no longer exists.
    final hwdec = _getHwdecValue(SettingsService.instance.read(SettingsService.enableHardwareDecoding));

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

    if (shaders == null) {
      settle();
      appLogger.e('Theater 3D shader assets unavailable; theater mode cannot render');
      if (mounted) {
        showErrorSnackBar(context, t.videoControls.theaterModeFailed(reason: 'shader assets missing'));
      }
      await resumeFlatPlayer(resumePosition);
      return;
    }

    exitSubscription = _theater3d.onExit.listen((event) {
      settle();
      // The in-scene depth control has no way back to prefs on its own, so
      // whatever it was left at becomes the remembered strength for this
      // title -- same scope the settings sheet writes to.
      if (synthetic) {
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
        vertexShader: shaders.vertex,
        fragmentShader: shaders.fragment,
        synthetic: synthetic,
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
