import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n/strings.g.dart';
import '../selfupdate/apk_self_updater.dart';
import '../selfupdate/self_update_button.dart';
import '../services/update_service.dart';
import '../widgets/dialog_action_button.dart';
import 'dialogs.dart';

Future<void> showUpdateAvailableDialog(
  BuildContext context,
  Map<String, dynamic> updateInfo, {
  required String title,
  required String dismissLabel,
  bool showSkipVersion = false,
}) {
  return showScopedDialog<void>(
    context: context,
    builder: (dialogContext) {
      final latestVersion = updateInfo['latestVersion'] as String;
      final releaseUrl = updateInfo['releaseUrl'] as String;

      return AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: .min,
          crossAxisAlignment: .start,
          children: [
            Text(
              t.update.versionAvailable(version: latestVersion),
              style: Theme.of(dialogContext).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              t.update.currentVersion(version: updateInfo['currentVersion']),
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          DialogActionButton(onPressed: () => Navigator.pop(dialogContext), label: dismissLabel),
          if (showSkipVersion)
            DialogActionButton(
              onPressed: () async {
                await UpdateService.skipVersion(latestVersion);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.skipVersion,
            ),
          // Sideloaded Quest/Fire TV builds install the APK in place, and say so
          // on the button while they do it. Every other build keeps upstream's
          // open-the-release-page behaviour, unchanged, on the else branch.
          if (ApkSelfUpdater.isSupported)
            SelfUpdateActionButton(
              repo: UpdateService.githubRepo,
              releaseUrl: releaseUrl,
              onFinished: () {
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
            )
          else
            DialogActionButton(
              onPressed: () async {
                final url = Uri.parse(releaseUrl);
                if (await canLaunchUrl(url)) {
                  await launchUrl(url, mode: LaunchMode.externalApplication);
                }
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              label: t.update.viewRelease,
              isPrimary: true,
            ),
        ],
      );
    },
  );
}
