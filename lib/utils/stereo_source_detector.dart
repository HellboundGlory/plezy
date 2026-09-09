// Stereo 3D source detection for [ThreeDMode.auto] -- see PLAN_3D.md Phase 2
// section 2.4.
//
// Two independent heuristics, tried in order: a filename tag (the convention
// already used by every VR player) and a source-aspect-ratio fallback for
// untagged files whose frame is simply twice as wide (SBS) or twice as tall
// (OU) as the program's declared aspect ratio. Neither heuristic is
// authoritative -- a miss just means [ThreeDMode.auto] falls through to the
// synthetic heuristic shader instead of stereo passthrough (see
// `ShaderService.applyPreset`), which still looks correct on a flat source.

/// Detected stereo packing of a source, or [none] when neither heuristic
/// matched anything.
enum DetectedStereoLayout { none, sbs, ou }

abstract final class StereoSourceDetector {
  /// Matches `_SBS`, `_HSBS`, `_Half-SBS` (case-insensitive) as a distinct
  /// filename tag, not merely a substring of an unrelated word.
  static final RegExp _sbsPattern = RegExp(r'(?:^|[ _.\-])(half-sbs|hsbs|sbs)(?:[ _.\-]|$)', caseSensitive: false);

  /// Matches `_OU`, `_TAB`, `_Half-OU` (case-insensitive), same boundary rule.
  static final RegExp _ouPattern = RegExp(r'(?:^|[ _.\-])(half-ou|tab|ou)(?:[ _.\-]|$)', caseSensitive: false);

  /// Relative tolerance for the aspect-ratio fallback: real-world sources
  /// round to a handful of standard resolutions, never an exact doubling.
  static const double _aspectRatioTolerance = 0.02;

  /// Filename heuristic: `_SBS`/`_HSBS`/`_Half-SBS` -> [DetectedStereoLayout.sbs];
  /// `_OU`/`_TAB`/`_Half-OU` -> [DetectedStereoLayout.ou]; otherwise [DetectedStereoLayout.none].
  static DetectedStereoLayout detectFromFileName(String fileName) {
    if (_sbsPattern.hasMatch(fileName)) return DetectedStereoLayout.sbs;
    if (_ouPattern.hasMatch(fileName)) return DetectedStereoLayout.ou;
    return DetectedStereoLayout.none;
  }

  /// Flags a source frame whose aspect ratio is exactly double the program's
  /// declared aspect ratio (SBS: two full-height eye views side by side, e.g.
  /// a 3840x1080 stream where metadata reports a 16:9 program) or exactly
  /// half of it (OU: two full-width eye views stacked).
  static DetectedStereoLayout detectFromAspectRatio({
    required double sourceWidth,
    required double sourceHeight,
    required double expectedAspectRatio,
  }) {
    if (sourceWidth <= 0 || sourceHeight <= 0 || expectedAspectRatio <= 0) return DetectedStereoLayout.none;
    final sourceAspectRatio = sourceWidth / sourceHeight;
    if (_isCloseTo(sourceAspectRatio, expectedAspectRatio * 2)) return DetectedStereoLayout.sbs;
    if (_isCloseTo(sourceAspectRatio, expectedAspectRatio / 2)) return DetectedStereoLayout.ou;
    return DetectedStereoLayout.none;
  }

  static bool _isCloseTo(double value, double target) =>
      target > 0 && (value - target).abs() / target <= _aspectRatioTolerance;

  /// Filename heuristic first, aspect-ratio fallback only when the source's
  /// dimensions and the program's expected aspect ratio are both known.
  static DetectedStereoLayout detect({
    required String fileName,
    double? sourceWidth,
    double? sourceHeight,
    double? expectedAspectRatio,
  }) {
    final byName = detectFromFileName(fileName);
    if (byName != DetectedStereoLayout.none) return byName;
    if (sourceWidth != null && sourceHeight != null && expectedAspectRatio != null) {
      return detectFromAspectRatio(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        expectedAspectRatio: expectedAspectRatio,
      );
    }
    return DetectedStereoLayout.none;
  }
}
