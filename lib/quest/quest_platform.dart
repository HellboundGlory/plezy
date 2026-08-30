// Quest / Horizon OS detection.
//
// This file is additive: nothing in upstream Plezy imports it, which is what
// keeps the fork's Dart surface identical to upstream. It exists as the
// integration seam for Quest-specific behaviour — window/panel handling,
// future immersive work — so that when something genuinely needs to branch on
// Horizon OS there is one tested place to ask.
//
// Horizon OS runs Plezy as an ordinary Android 2D panel app, so on purpose
// *no* playback, layout or input behaviour is gated on this today.

import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Build-time marker set by the Quest build command:
/// `--dart-define=QUEST_BUILD=true`.
///
/// Preferred over runtime probing because it is deterministic and const-folds,
/// but it is only a hint: a Quest APK is a plain Android APK and will install
/// anywhere, so [QuestPlatform.isQuest] still confirms against the device.
const bool kQuestBuild = bool.fromEnvironment('QUEST_BUILD');

/// `Build.MANUFACTURER` / `Build.BRAND` values used by Horizon OS headsets.
/// Quest 1–3 report `Oculus`; Horizon OS images have begun reporting `Meta`.
/// No other Android OEM ships either value, so an exact match is safe.
const Set<String> _questVendors = {'oculus', 'meta'};

/// Horizon-only system features. Secondary to the vendor check — they are a
/// backstop in case a future Horizon image changes its vendor string.
const Set<String> _questSystemFeatures = {
  'oculus.hardware.standalone_vr',
  'com.oculus.feature.PANEL_APP',
  'oculus.software.overlay_keyboard',
};

/// Pure form of the detection, so it can be tested without a device.
///
/// [systemFeatures] is optional: `device_info_plus` populates it on Android,
/// and an empty list simply falls back to the vendor strings.
bool detectQuestFromAndroidBuild({
  required String manufacturer,
  required String brand,
  Iterable<String> systemFeatures = const <String>[],
}) {
  final vendor = manufacturer.trim().toLowerCase();
  final brandName = brand.trim().toLowerCase();
  if (_questVendors.contains(vendor) || _questVendors.contains(brandName)) return true;
  return systemFeatures.any(_questSystemFeatures.contains);
}

/// Cached async detector, mirroring how [TvDetectionService] is initialised.
class QuestPlatform {
  static bool? _isQuest;

  /// True once [ensureInitialized] has run on a Horizon OS headset.
  /// False (never null) before initialisation, so callers cannot accidentally
  /// treat "not yet known" as "is Quest".
  static bool get isQuest => _isQuest ?? false;

  /// True when detection has completed.
  static bool get isInitialized => _isQuest != null;

  /// Resolves [isQuest]. Safe to call repeatedly; the probe runs once.
  static Future<bool> ensureInitialized() async {
    final cached = _isQuest;
    if (cached != null) return cached;
    if (!Platform.isAndroid) return _isQuest = false;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      return _isQuest = detectQuestFromAndroidBuild(
        manufacturer: info.manufacturer,
        brand: info.brand,
        systemFeatures: info.systemFeatures,
      );
    } catch (_) {
      // Detection is advisory; never let it break startup.
      return _isQuest = kQuestBuild;
    }
  }

  @visibleForTesting
  static void debugSetIsQuest(bool? value) => _isQuest = value;
}
