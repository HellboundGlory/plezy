// Which sideloaded build this is, and which release asset it should install.
//
// Additive: upstream Plezy has no concept of a sideload target. Set at build
// time so the running app never has to guess which package it came from:
//
//   QUEST=1  ... --dart-define=SELF_UPDATE_TARGET=quest
//   AMAZON=1 ... --dart-define=SELF_UPDATE_TARGET=firetv
//   Flatpak  ... --dart-define=SELF_UPDATE_TARGET=flatpak
//
// Anything else (the default Play/desktop builds) leaves self-update off, which
// is what keeps Play policy and the desktop Sparkle path untouched.

/// A sideload target that can install its own updates.
enum SelfUpdateTarget {
  /// Meta Quest / Horizon OS. arm64-only APK, versionCode +4000.
  quest('quest'),

  /// Amazon Fire TV. arm64 + armeabi-v7a APK, versionCode +3000.
  fireTv('firetv'),

  /// Linux Flatpak bundle from the fork's own release.
  flatpak('flatpak');

  const SelfUpdateTarget(this.id);

  /// The `--dart-define=SELF_UPDATE_TARGET=` value that selects this target.
  final String id;

  /// Substring that must appear in a release asset's filename for it to be the
  /// APK for this target. Matching on a substring rather than an exact name
  /// keeps the version and architecture free to change in the filename.
  String get assetMarker => 'plezy-$id';
}

const String _configuredTarget = String.fromEnvironment('SELF_UPDATE_TARGET');

/// The target this build was compiled for, or null when self-update is off.
SelfUpdateTarget? get selfUpdateTarget => parseSelfUpdateTarget(_configuredTarget);

/// Pure form, so the mapping is testable without rebuilding with defines.
SelfUpdateTarget? parseSelfUpdateTarget(String value) {
  final normalized = value.trim().toLowerCase();
  for (final target in SelfUpdateTarget.values) {
    if (target.id == normalized) return target;
  }
  return null;
}

/// Maps a Flatpak `[Instance] arch=` value to the `<arch>` in the release's
/// `plezy-linux-<arch>.flatpak`. Null when no bundle is built for that arch.
String? flatpakAssetArch(String arch) => switch (arch.trim().toLowerCase()) {
  'x86_64' => 'x64',
  'aarch64' => 'arm64',
  _ => null,
};

/// Picks the download URL for [target] out of a GitHub release's `assets`.
///
/// [assets] is the raw decoded `assets` array from the GitHub releases API.
/// [arch] is only read for [SelfUpdateTarget.flatpak]: the value of
/// [flatpakAssetArch], i.e. `x64` or `arm64`.
///
/// Returns null when the release has nothing for this target, which is the
/// normal case for a release that only shipped desktop builds — the caller
/// then falls back to opening the release page in a browser.
String? selectAssetUrl(Iterable<dynamic> assets, SelfUpdateTarget target, {String? arch}) {
  final bool Function(String name) matches;
  if (target == SelfUpdateTarget.flatpak) {
    if (arch == null) return null;
    final wanted = 'plezy-linux-${arch.toLowerCase()}.flatpak';
    matches = (name) => name.toLowerCase() == wanted;
  } else {
    final marker = target.assetMarker;
    matches = (name) => name.toLowerCase().endsWith('.apk') && name.toLowerCase().contains(marker);
  }

  for (final asset in assets) {
    if (asset is! Map) continue;
    final name = asset['name'];
    final url = asset['browser_download_url'];
    if (name is! String || url is! String) continue;
    if (matches(name)) return url;
  }
  return null;
}
