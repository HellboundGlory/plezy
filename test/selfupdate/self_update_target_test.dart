import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/selfupdate/self_update_target.dart';

void main() {
  group('parseSelfUpdateTarget', () {
    test('maps the quest define', () {
      expect(parseSelfUpdateTarget('quest'), SelfUpdateTarget.quest);
    });

    test('maps the firetv define', () {
      expect(parseSelfUpdateTarget('firetv'), SelfUpdateTarget.fireTv);
    });

    test('maps the flatpak define', () {
      expect(parseSelfUpdateTarget('flatpak'), SelfUpdateTarget.flatpak);
    });

    test('is case- and whitespace-insensitive', () {
      expect(parseSelfUpdateTarget('  QUEST '), SelfUpdateTarget.quest);
    });

    test('leaves self-update off for an unset define', () {
      expect(parseSelfUpdateTarget(''), isNull);
    });

    test('leaves self-update off for an unknown target', () {
      expect(parseSelfUpdateTarget('playstore'), isNull);
    });
  });

  group('selectAssetUrl', () {
    List<Map<String, String>> assetsFor(List<String> names) => [
      for (final name in names) {'name': name, 'browser_download_url': 'https://example.test/$name'},
    ];

    test('picks the Quest APK out of a mixed release', () {
      final url = selectAssetUrl(
        assetsFor(['plezy-firetv-2.17.2.apk', 'plezy-quest-2.17.2-arm64.apk', 'plezy-2.17.2.dmg']),
        SelfUpdateTarget.quest,
      );
      expect(url, 'https://example.test/plezy-quest-2.17.2-arm64.apk');
    });

    test('picks the Fire TV APK out of the same release', () {
      final url = selectAssetUrl(
        assetsFor(['plezy-firetv-2.17.2.apk', 'plezy-quest-2.17.2-arm64.apk']),
        SelfUpdateTarget.fireTv,
      );
      expect(url, 'https://example.test/plezy-firetv-2.17.2.apk');
    });

    test('does not hand the Quest build a Fire TV APK', () {
      expect(selectAssetUrl(assetsFor(['plezy-firetv-2.17.2.apk']), SelfUpdateTarget.quest), isNull);
    });

    test('ignores non-APK assets that mention the target', () {
      expect(selectAssetUrl(assetsFor(['plezy-quest-2.17.2-arm64.apk.sha256']), SelfUpdateTarget.quest), isNull);
    });

    test('returns null for a desktop-only release', () {
      expect(selectAssetUrl(assetsFor(['plezy-2.17.2.dmg', 'plezy-2.17.2.exe']), SelfUpdateTarget.quest), isNull);
    });

    test('tolerates malformed asset entries', () {
      final url = selectAssetUrl([
        'not-a-map',
        {'name': 42},
        {'name': 'plezy-quest-2.17.2-arm64.apk'},
        {'name': 'plezy-quest-2.17.2-arm64.apk', 'browser_download_url': 'https://example.test/ok.apk'},
      ], SelfUpdateTarget.quest);
      expect(url, 'https://example.test/ok.apk');
    });

    test('handles an empty asset list', () {
      expect(selectAssetUrl(const [], SelfUpdateTarget.quest), isNull);
    });
  });

  group('flatpakAssetArch', () {
    test('maps the Flatpak [Instance] arch to the bundle name', () {
      expect(flatpakAssetArch('x86_64'), 'x64');
      expect(flatpakAssetArch('aarch64'), 'arm64');
    });

    test('has no bundle for any other arch', () {
      expect(flatpakAssetArch('arm'), isNull);
      expect(flatpakAssetArch('i386'), isNull);
      expect(flatpakAssetArch(''), isNull);
    });
  });

  group('selectAssetUrl for flatpak', () {
    List<Map<String, String>> assetsFor(List<String> names) => [
      for (final name in names) {'name': name, 'browser_download_url': 'https://example.test/$name'},
    ];

    final mixedRelease = assetsFor([
      'plezy-linux-x64.flatpak',
      'plezy-linux-arm64.flatpak',
      'plezy-quest-2.26.0.1-arm64.apk',
      'plezy-firetv-2.26.0.1.apk',
      'plezy-2.26.0.1.dmg',
    ]);

    test('picks the x64 bundle', () {
      expect(
        selectAssetUrl(mixedRelease, SelfUpdateTarget.flatpak, arch: 'x64'),
        'https://example.test/plezy-linux-x64.flatpak',
      );
    });

    test('picks the arm64 bundle', () {
      expect(
        selectAssetUrl(mixedRelease, SelfUpdateTarget.flatpak, arch: 'arm64'),
        'https://example.test/plezy-linux-arm64.flatpak',
      );
    });

    test('never picks an APK', () {
      final url = selectAssetUrl(mixedRelease, SelfUpdateTarget.flatpak, arch: 'arm64');
      expect(url, isNot(endsWith('.apk')));
    });

    test('returns null when this arch has no bundle', () {
      expect(selectAssetUrl(assetsFor(['plezy-linux-x64.flatpak']), SelfUpdateTarget.flatpak, arch: 'arm64'), isNull);
      expect(selectAssetUrl(mixedRelease, SelfUpdateTarget.flatpak, arch: null), isNull);
    });

    test('matches the bundle name case-insensitively but exactly', () {
      final assets = assetsFor(['PLEZY-LINUX-X64.FLATPAK', 'plezy-linux-x64.flatpak.sha256']);
      expect(
        selectAssetUrl(assets, SelfUpdateTarget.flatpak, arch: 'x64'),
        'https://example.test/PLEZY-LINUX-X64.FLATPAK',
      );
    });
  });
}
