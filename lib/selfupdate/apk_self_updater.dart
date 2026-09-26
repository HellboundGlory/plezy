// Downloads and launches the install of a newer APK, for sideloaded builds.
//
// Deliberately thin: it reuses background_downloader (already a Plezy
// dependency) for both halves of the job.
//
//   * The download is an ordinary DownloadTask, so it inherits Plezy's existing
//     notification and retry behaviour.
//   * openFile() builds the install intent — ACTION_VIEW with a FileProvider
//     content:// URI, FLAG_GRANT_READ_URI_PERMISSION and the APK mime type.
//     That is exactly what Android's package installer requires, so no native
//     code and no MainActivity changes are needed. Verified on Quest 3, where
//     com.android.packageinstaller/.InstallStart resolves the intent.
//
// The user still confirms the install in the system dialog; REQUEST_INSTALL_PACKAGES
// (see android/selfupdate) only makes the app eligible to ask.

import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import 'self_update_target.dart';

/// Mime type that routes an intent to Android's package installer.
const String apkMimeType = 'application/vnd.android.package-archive';

/// Why a self-update attempt could not proceed. The caller falls back to
/// opening the release page in a browser for every one of these.
enum SelfUpdateFailure { notSupported, noAsset, downloadFailed, installLaunchFailed }

class SelfUpdateResult {
  const SelfUpdateResult.started() : failure = null;
  const SelfUpdateResult.failed(this.failure);

  final SelfUpdateFailure? failure;

  /// True once the system installer has been handed the APK.
  bool get isStarted => failure == null;
}

class ApkSelfUpdater {
  /// Whether this build can install its own updates.
  static bool get isSupported => selfUpdateTarget != null;

  /// Fetches the latest release, picks this target's APK, downloads it and
  /// hands it to the system installer.
  ///
  /// [repo] is `owner/name`. [client] and [downloader] are injectable so the
  /// flow can be tested without network or platform channels.
  static Future<SelfUpdateResult> downloadAndInstall({
    required String repo,
    MediaServerHttpClient? client,
    FileDownloader? downloader,
  }) async {
    final target = selfUpdateTarget;
    if (target == null) return const SelfUpdateResult.failed(SelfUpdateFailure.notSupported);

    final assetUrl = await _resolveAssetUrl(repo: repo, target: target, client: client);
    if (assetUrl == null) return const SelfUpdateResult.failed(SelfUpdateFailure.noAsset);

    final fileDownloader = downloader ?? FileDownloader();
    final task = DownloadTask(
      url: assetUrl,
      filename: 'plezy-${target.id}-update.apk',
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      allowPause: false,
      // A partially written APK must never be handed to the installer.
      retries: 2,
    );

    try {
      final result = await fileDownloader.download(task);
      if (result.status != TaskStatus.complete) {
        appLogger.w('Self-update download ended as ${result.status}');
        return const SelfUpdateResult.failed(SelfUpdateFailure.downloadFailed);
      }
    } catch (error, stackTrace) {
      appLogger.e('Self-update download threw', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.downloadFailed);
    }

    try {
      final launched = await fileDownloader.openFile(task: task, mimeType: apkMimeType);
      if (!launched) return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
      return const SelfUpdateResult.started();
    } catch (error, stackTrace) {
      appLogger.e('Self-update install launch threw', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
    }
  }

  static Future<String?> _resolveAssetUrl({
    required String repo,
    required SelfUpdateTarget target,
    MediaServerHttpClient? client,
  }) async {
    try {
      final response = await (client ?? httpClient).get(
        'https://api.github.com/repos/$repo/releases/latest',
        headers: {'Accept': 'application/vnd.github+json'},
      );
      if (response.statusCode != 200) return null;
      final data = response.data is String ? jsonDecode(response.data as String) : response.data;
      if (data is! Map) return null;
      final assets = data['assets'];
      if (assets is! Iterable) return null;
      return selectAssetUrl(assets, target);
    } catch (error, stackTrace) {
      appLogger.e('Self-update asset lookup failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  @visibleForTesting
  static Future<String?> debugResolveAssetUrl({
    required String repo,
    required SelfUpdateTarget target,
    MediaServerHttpClient? client,
  }) => _resolveAssetUrl(repo: repo, target: target, client: client);
}
