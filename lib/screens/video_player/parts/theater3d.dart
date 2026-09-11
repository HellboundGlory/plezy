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
      );
    } catch (e, st) {
      settle();
      appLogger.w('Failed to open theater mode', error: e, stackTrace: st);
      if (mounted) showErrorSnackBar(context, t.videoControls.theaterModeFailed(reason: e.toString()));
      await resumeFlatPlayer(resumePosition);
    }
  }
}
