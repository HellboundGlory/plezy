// The update dialog's primary button, for builds that can install their own package.
//
// Upstream's button is a one-shot "View Release" that opens a browser, so it can
// be a plain stateless action. This one owns a 95-170 MB download that runs while
// the dialog is still on screen, which makes it a small state machine: it has to
// say what it is doing, keep saying it for the ~30s the transfer takes, and still
// fall back to the browser if any of it fails.
//
// It lives here rather than in lib/utils/update_dialog.dart so that upstream's
// button survives in that file byte-for-byte, on the `else` of a single `if`.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_exit_service.dart';
import '../utils/app_logger.dart';
import '../widgets/dialog_action_button.dart';
import 'self_update_target.dart';
import 'self_updater.dart';

/// English-only, deliberately.
///
/// Every other string in this dialog comes from `t.update.*`, but adding a key
/// there means editing `lib/i18n/en.i18n.json` and the 24 generated
/// `strings_*.g.dart` files — all of which upstream rewrites on essentially
/// every release. That trades a permanent, 25-file rebase conflict for a few
/// short strings on a sideload-only build. If upstream ever ships an
/// install-and-update label of its own, delete these and use it.
class _Label {
  static const install = 'Download & Install';
  static const resolving = 'Finding update…';
  static const downloading = 'Downloading';
  static const openingInstaller = 'Opening installer…';
  static const installing = 'Installing…';
  static const restarting = 'Restarting…';
}

/// The button's text for a given phase and progress reading.
///
/// A null [phase] means idle; a null [progress] means "downloading, but no
/// reading yet", which is a real state — the first progress callback can trail
/// the status change by a second or two on a cold connection.
@visibleForTesting
String selfUpdateButtonLabel(SelfUpdatePhase? phase, double? progress, {bool flatpak = false}) => switch (phase) {
  null => _Label.install,
  SelfUpdatePhase.resolving => _Label.resolving,
  SelfUpdatePhase.downloading =>
    progress == null ? '${_Label.downloading}…' : '${_Label.downloading} ${(progress * 100).round()}%',
  SelfUpdatePhase.launchingInstaller => flatpak ? _Label.installing : _Label.openingInstaller,
  SelfUpdatePhase.restarting => _Label.restarting,
};

class SelfUpdateActionButton extends StatefulWidget {
  const SelfUpdateActionButton({super.key, required this.repo, required this.releaseUrl, required this.onFinished});

  /// `owner/name` of the GitHub repo holding the release.
  final String repo;

  /// Opened in a browser if the self-update cannot run — upstream's behaviour.
  final String releaseUrl;

  /// Called once the installer has been handed the package, or the browser opened.
  final VoidCallback onFinished;

  @override
  State<SelfUpdateActionButton> createState() => _SelfUpdateActionButtonState();
}

class _SelfUpdateActionButtonState extends State<SelfUpdateActionButton> {
  SelfUpdatePhase? _phase;
  double? _progress;

  bool get _isRunning => _phase != null;

  bool get _isFlatpak => selfUpdateTarget == SelfUpdateTarget.flatpak;

  Future<void> _start() async {
    if (_isRunning) return;
    setState(() {
      _phase = SelfUpdatePhase.resolving;
      _progress = null;
    });

    final result = await SelfUpdater.downloadAndInstall(
      repo: widget.repo,
      onPhase: (phase) {
        if (mounted) setState(() => _phase = phase);
      },
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress);
      },
    );

    if (result.isStarted && _isFlatpak) {
      // Quit so the relaunch helper can start the new build: a launch while the
      // old process is alive is handed straight back to it.
      if (await _exitForRelaunch()) return;
    } else if (!result.isStarted && result.failure != SelfUpdateFailure.relaunchFailed) {
      await _openReleasePage();
    }
    if (mounted) widget.onFinished();
  }

  Future<bool> _exitForRelaunch() async {
    try {
      return await AppExitService.requestGracefulExit();
    } catch (error, stackTrace) {
      appLogger.e('Exit after the Flatpak update failed', error: error, stackTrace: stackTrace);
      return false;
    }
  }

  Future<void> _openReleasePage() async {
    final url = Uri.parse(widget.releaseUrl);
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DialogActionButton(
      // Stays non-null while running so the button keeps `canRequestFocus`.
      // Handing it null would drop focus mid-download, which on the TV layout
      // means the D-pad lands somewhere else entirely; `_start` returns early
      // instead. See FocusableButton.
      onPressed: _start,
      label: selfUpdateButtonLabel(_phase, _progress, flatpak: _isFlatpak),
      isPrimary: true,
      icon: _isRunning
          ? SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                // Determinate only once there is a real reading, so the ring
                // spins through the GitHub lookup rather than sitting at zero.
                value: _phase == SelfUpdatePhase.downloading ? _progress : null,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            )
          : null,
    );
  }
}
