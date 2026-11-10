// Downloads and installs a newer build, for sideloaded packages.
//
// Two targets share the download half: the Quest/Fire TV APK is handed to
// Android's package installer, the Linux Flatpak is installed through the
// host's `flatpak` command, which then relaunches the app on the new version.
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
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';

import '../utils/app_logger.dart';
import '../utils/media_server_http_client.dart';
import 'self_update_target.dart';

/// Mime type that routes an intent to Android's package installer.
const String apkMimeType = 'application/vnd.android.package-archive';

/// Why a self-update attempt could not proceed. The caller falls back to
/// opening the release page in a browser for every one of these.
/// [relaunchFailed] means the update is installed but nothing will restart the
/// app, so the caller must neither quit nor send the user to the release page.
enum SelfUpdateFailure { notSupported, noAsset, downloadFailed, installLaunchFailed, relaunchFailed }

/// What the update is doing right now, so the UI can say so.
///
/// The APKs are 95-170 MB, and on a headset that is long enough that a button
/// which merely stays pressed reads as broken. [resolving] and
/// [launchingInstaller] are both short but neither is instant, so every phase
/// gets its own label rather than sharing one spinner.
enum SelfUpdatePhase { resolving, downloading, launchingInstaller, restarting }

class SelfUpdateResult {
  const SelfUpdateResult.started() : failure = null;
  const SelfUpdateResult.failed(this.failure);

  final SelfUpdateFailure? failure;

  /// True once the system installer has been handed the APK, or the Flatpak
  /// install has been applied.
  bool get isStarted => failure == null;
}

/// Runs one command on the host through `flatpak-spawn --host`.
typedef HostCommandRunner = Future<ProcessResult> Function(List<String> args);

/// Starts the detached helper that relaunches the app once the update is in.
typedef HostRelauncher = Future<void> Function();

/// Whether a build compiled for [target] can install its own updates.
///
/// Pure form of [SelfUpdater.isSupported], so the sandbox check is testable on
/// any host. The Flatpak target only qualifies inside the Flatpak sandbox: run
/// unpacked, the same binary has no host `flatpak` to talk to.
@visibleForTesting
bool supportsSelfUpdate({required SelfUpdateTarget? target, required bool isLinux, required String? flatpakId}) {
  if (target == null) return false;
  if (target != SelfUpdateTarget.flatpak) return true;
  return isLinux && flatpakId == SelfUpdater.flatpakAppId;
}

class SelfUpdater {
  /// The Flatpak app id of this build, which is what the host installs and runs.
  static const String flatpakAppId = 'com.edde746.plezy';

  /// Whether this build can install its own updates.
  ///
  /// The Flatpak target also needs the sandbox it was built for: run unpacked,
  /// the same binary has no host `flatpak` to talk to.
  static bool get isSupported => supportsSelfUpdate(
    target: selfUpdateTarget,
    isLinux: Platform.isLinux,
    flatpakId: Platform.environment['FLATPAK_ID'],
  );

  /// Fetches the latest release, picks this target's package, downloads it and
  /// hands it to the installer.
  ///
  /// [repo] is `owner/name`. [client] and [downloader] are injectable so the
  /// flow can be tested without network or platform channels.
  ///
  /// [onPhase] fires on every phase change and [onProgress] on download
  /// progress as a 0..1 fraction. Both are optional: a caller that passes
  /// neither gets exactly the old fire-and-await behaviour.
  static Future<SelfUpdateResult> downloadAndInstall({
    required String repo,
    MediaServerHttpClient? client,
    FileDownloader? downloader,
    HostCommandRunner? runCommand,
    HostRelauncher? startRelaunch,
    void Function(SelfUpdatePhase phase)? onPhase,
    void Function(double progress)? onProgress,
  }) async {
    final target = selfUpdateTarget;
    if (target == null) return const SelfUpdateResult.failed(SelfUpdateFailure.notSupported);

    final isFlatpak = target == SelfUpdateTarget.flatpak;
    onPhase?.call(SelfUpdatePhase.resolving);
    final arch = isFlatpak ? await _flatpakArch() : null;
    final assetUrl = await _resolveAssetUrl(repo: repo, target: target, arch: arch, client: client);
    if (assetUrl == null) return const SelfUpdateResult.failed(SelfUpdateFailure.noAsset);

    final fileDownloader = downloader ?? FileDownloader();
    final task = DownloadTask(
      url: assetUrl,
      filename: isFlatpak ? 'plezy-flatpak-update.flatpak' : 'plezy-${target.id}-update.apk',
      baseDirectory: BaseDirectory.applicationSupport,
      updates: Updates.statusAndProgress,
      allowPause: false,
      // A partially written package must never be handed to the installer.
      retries: 2,
    );

    onPhase?.call(SelfUpdatePhase.downloading);
    try {
      final result = await fileDownloader.download(
        task,
        // background_downloader signals paused/retrying/failed as negative
        // sentinels on the same callback (progressWaitingToRetry is -4.0).
        // Forwarding those verbatim would render as "-400%", so anything
        // outside 0..1 is dropped and the UI holds its last real reading.
        onProgress: onProgress == null
            ? null
            : (progress) {
                if (progress >= 0 && progress <= 1) onProgress(progress);
              },
      );
      if (result.status != TaskStatus.complete) {
        appLogger.w('Self-update download ended as ${result.status}');
        return const SelfUpdateResult.failed(SelfUpdateFailure.downloadFailed);
      }
    } catch (error, stackTrace) {
      appLogger.e('Self-update download threw', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.downloadFailed);
    }

    if (isFlatpak) {
      final String filePath;
      try {
        filePath = await task.filePath();
      } catch (error, stackTrace) {
        appLogger.e('Could not locate the downloaded Flatpak bundle', error: error, stackTrace: stackTrace);
        return const SelfUpdateResult.failed(SelfUpdateFailure.downloadFailed);
      }
      return installFlatpakBundle(
        filePath: filePath,
        runCommand: runCommand,
        startRelaunch: startRelaunch,
        onPhase: onPhase,
      );
    }

    onPhase?.call(SelfUpdatePhase.launchingInstaller);
    try {
      final launched = await fileDownloader.openFile(task: task, mimeType: apkMimeType);
      if (!launched) return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
      return const SelfUpdateResult.started();
    } catch (error, stackTrace) {
      appLogger.e('Self-update install launch threw', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
    }
  }

  /// Installs a downloaded bundle into the same Flatpak installation the app
  /// came from, then starts the helper that relaunches it.
  ///
  /// Split out from [downloadAndInstall] so the host commands can be exercised
  /// with a fake runner instead of a real `flatpak`.
  static Future<SelfUpdateResult> installFlatpakBundle({
    required String filePath,
    HostCommandRunner? runCommand,
    HostRelauncher? startRelaunch,
    void Function(SelfUpdatePhase phase)? onPhase,
  }) async {
    final run = runCommand ?? _runOnHost;

    onPhase?.call(SelfUpdatePhase.launchingInstaller);
    try {
      // Updating a --user install must stay in --user: the same app in both
      // installations gets two copies and no way to tell which one starts.
      final probe = await run(['flatpak', 'info', '--user', flatpakAppId]);
      final scope = probe.exitCode == 0 ? '--user' : '--system';
      final install = await run(['flatpak', 'install', scope, '--noninteractive', '-y', filePath]);
      if (install.exitCode != 0) {
        appLogger.e('Flatpak update install failed: ${install.stderr}');
        return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
      }
    } catch (error, stackTrace) {
      appLogger.e('Flatpak update install threw', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.installLaunchFailed);
    }

    try {
      await File(filePath).delete();
    } on FileSystemException catch (error) {
      appLogger.w('Could not remove the downloaded Flatpak bundle: $error');
    }

    onPhase?.call(SelfUpdatePhase.restarting);
    try {
      await (startRelaunch ?? _startRelaunchOnHost)();
    } catch (error, stackTrace) {
      appLogger.e('Flatpak relaunch helper failed to start', error: error, stackTrace: stackTrace);
      return const SelfUpdateResult.failed(SelfUpdateFailure.relaunchFailed);
    }
    return const SelfUpdateResult.started();
  }

  static Future<ProcessResult> _runOnHost(List<String> args) => Process.run('flatpak-spawn', ['--host', ...args]);

  /// Waits for the old instance to leave `flatpak ps` before starting the new
  /// one: a second launch hands off to the running app and exits instead.
  static const String _relaunchScript =
      'i=0; while [ \$i -lt 60 ]; do '
      'if out=\$(flatpak ps --columns=application); then '
      'printf \'%s\\n\' "\$out" | grep -qxF $flatpakAppId || break; fi; '
      'sleep 0.5; i=\$((i + 1)); done; '
      'flatpak run $flatpakAppId';

  @visibleForTesting
  static String get debugRelaunchScript => _relaunchScript;

  static Future<void> _startRelaunchOnHost() =>
      Process.start('flatpak-spawn', ['--host', 'sh', '-c', _relaunchScript], mode: ProcessStartMode.detached);

  /// The `<arch>` in this Flatpak's release asset name, or null when the
  /// release has no bundle for it.
  static Future<String?> _flatpakArch() async {
    try {
      return _archFromFlatpakInfo(await File('/.flatpak-info').readAsString());
    } catch (error, stackTrace) {
      appLogger.e('Could not read the Flatpak instance info', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  static String? _archFromFlatpakInfo(String info) {
    var inInstance = false;
    for (final line in const LineSplitter().convert(info)) {
      final trimmed = line.trim();
      if (trimmed.startsWith('[')) {
        inInstance = trimmed == '[Instance]';
        continue;
      }
      if (inInstance && trimmed.startsWith('arch=')) {
        return flatpakAssetArch(trimmed.substring('arch='.length));
      }
    }
    return null;
  }

  @visibleForTesting
  static String? debugArchFromFlatpakInfo(String info) => _archFromFlatpakInfo(info);

  static Future<String?> _resolveAssetUrl({
    required String repo,
    required SelfUpdateTarget target,
    String? arch,
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
      return selectAssetUrl(assets, target, arch: arch);
    } catch (error, stackTrace) {
      appLogger.e('Self-update asset lookup failed', error: error, stackTrace: stackTrace);
      return null;
    }
  }

  @visibleForTesting
  static Future<String?> debugResolveAssetUrl({
    required String repo,
    required SelfUpdateTarget target,
    String? arch,
    MediaServerHttpClient? client,
  }) => _resolveAssetUrl(repo: repo, target: target, arch: arch, client: client);
}
