import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/utils/stereo_source_detector.dart';

void main() {
  group('detectFromFileName', () {
    test('matches an _SBS tag', () {
      expect(StereoSourceDetector.detectFromFileName('Movie.2020.1080p_SBS.mkv'), DetectedStereoLayout.sbs);
    });

    test('matches an _HSBS tag case-insensitively', () {
      expect(StereoSourceDetector.detectFromFileName('movie.2020.hsbs.mp4'), DetectedStereoLayout.sbs);
    });

    test('matches a _Half-SBS tag', () {
      expect(StereoSourceDetector.detectFromFileName('Movie_Half-SBS_1080p.mkv'), DetectedStereoLayout.sbs);
    });

    test('matches an _OU tag', () {
      expect(StereoSourceDetector.detectFromFileName('Movie.2020.OU.mkv'), DetectedStereoLayout.ou);
    });

    test('matches a _TAB tag', () {
      expect(StereoSourceDetector.detectFromFileName('Movie_TAB_1080p.mp4'), DetectedStereoLayout.ou);
    });

    test('matches a _Half-OU tag', () {
      expect(StereoSourceDetector.detectFromFileName('Movie.Half-OU.mkv'), DetectedStereoLayout.ou);
    });

    test('does not match an ordinary filename', () {
      expect(StereoSourceDetector.detectFromFileName('Movie.2020.1080p.BluRay.x264.mkv'), DetectedStereoLayout.none);
    });

    test('does not false-positive on a substring that merely contains "ou"', () {
      expect(StereoSourceDetector.detectFromFileName('The Hours.2002.1080p.mkv'), DetectedStereoLayout.none);
    });
  });

  group('detectFromAspectRatio', () {
    test('flags a source frame twice as wide as the declared aspect ratio as SBS', () {
      final layout = StereoSourceDetector.detectFromAspectRatio(
        sourceWidth: 3840,
        sourceHeight: 1080,
        expectedAspectRatio: 16 / 9,
      );
      expect(layout, DetectedStereoLayout.sbs);
    });

    test('flags a source frame twice as tall (relative aspect ratio halved) as OU', () {
      final layout = StereoSourceDetector.detectFromAspectRatio(
        sourceWidth: 1920,
        sourceHeight: 2160,
        expectedAspectRatio: 16 / 9,
      );
      expect(layout, DetectedStereoLayout.ou);
    });

    test('does not match an ordinary flat aspect ratio', () {
      final layout = StereoSourceDetector.detectFromAspectRatio(
        sourceWidth: 1920,
        sourceHeight: 1080,
        expectedAspectRatio: 16 / 9,
      );
      expect(layout, DetectedStereoLayout.none);
    });

    test('rejects zero/negative dimensions instead of dividing by zero', () {
      expect(
        StereoSourceDetector.detectFromAspectRatio(sourceWidth: 0, sourceHeight: 1080, expectedAspectRatio: 16 / 9),
        DetectedStereoLayout.none,
      );
    });
  });

  group('detect', () {
    test('prefers the filename tag over the aspect ratio fallback', () {
      final layout = StereoSourceDetector.detect(
        fileName: 'Movie_OU.mkv',
        sourceWidth: 3840,
        sourceHeight: 1080,
        expectedAspectRatio: 16 / 9,
      );
      expect(layout, DetectedStereoLayout.ou);
    });

    test('falls back to aspect ratio when the filename has no tag', () {
      final layout = StereoSourceDetector.detect(
        fileName: 'Movie.2020.mkv',
        sourceWidth: 3840,
        sourceHeight: 1080,
        expectedAspectRatio: 16 / 9,
      );
      expect(layout, DetectedStereoLayout.sbs);
    });

    test('is none when neither the filename nor dimensions are informative', () {
      expect(StereoSourceDetector.detect(fileName: 'Movie.2020.mkv'), DetectedStereoLayout.none);
    });
  });
}
