import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/quest/quest_platform.dart';

void main() {
  group('detectQuestFromAndroidBuild', () {
    test('detects the Oculus vendor string used by Quest 1-3', () {
      expect(detectQuestFromAndroidBuild(manufacturer: 'Oculus', brand: 'oculus'), isTrue);
    });

    test('detects the Meta vendor string used by newer Horizon OS images', () {
      expect(detectQuestFromAndroidBuild(manufacturer: 'Meta', brand: 'meta'), isTrue);
    });

    test('is case- and whitespace-insensitive', () {
      expect(detectQuestFromAndroidBuild(manufacturer: '  OCULUS ', brand: ''), isTrue);
    });

    test('matches on brand alone when the manufacturer differs', () {
      expect(detectQuestFromAndroidBuild(manufacturer: 'QCOM', brand: 'Oculus'), isTrue);
    });

    test('falls back to Horizon-only system features', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'unknown',
          brand: 'unknown',
          systemFeatures: const ['android.hardware.usb.host', 'oculus.hardware.standalone_vr'],
        ),
        isTrue,
      );
    });

    test('does not fire on a phone', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'Google',
          brand: 'google',
          systemFeatures: const ['android.hardware.touchscreen'],
        ),
        isFalse,
      );
    });

    test('does not fire on a Fire TV stick', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'Amazon',
          brand: 'Amazon',
          systemFeatures: const ['amazon.hardware.fire_tv', 'android.software.leanback'],
        ),
        isFalse,
      );
    });

    test('does not fire on an Android TV box', () {
      expect(
        detectQuestFromAndroidBuild(
          manufacturer: 'NVIDIA',
          brand: 'nvidia',
          systemFeatures: const ['android.software.leanback'],
        ),
        isFalse,
      );
    });
  });

  group('QuestPlatform', () {
    tearDown(() => QuestPlatform.debugSetIsQuest(null));

    test('reports false, not null, before initialization', () {
      expect(QuestPlatform.isInitialized, isFalse);
      expect(QuestPlatform.isQuest, isFalse);
    });

    test('exposes the injected verdict once set', () {
      QuestPlatform.debugSetIsQuest(true);
      expect(QuestPlatform.isInitialized, isTrue);
      expect(QuestPlatform.isQuest, isTrue);
    });
  });
}
