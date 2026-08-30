import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/selfupdate/apk_self_updater.dart';
import 'package:plezy/selfupdate/self_update_button.dart';

void main() {
  group('selfUpdateButtonLabel', () {
    test('offers to install rather than to view the release when idle', () {
      // The bug this replaced: sideload builds showed upstream's "View
      // Release", so the button described a browser it was never going to open.
      expect(selfUpdateButtonLabel(null, null), 'Download & Install');
      expect(selfUpdateButtonLabel(null, null), isNot(contains('View')));
    });

    test('names the GitHub lookup, which happens before any progress exists', () {
      expect(selfUpdateButtonLabel(SelfUpdatePhase.resolving, null), 'Finding update…');
    });

    test('shows downloading without a number until the first reading arrives', () {
      expect(selfUpdateButtonLabel(SelfUpdatePhase.downloading, null), 'Downloading…');
    });

    test('renders progress as whole percent', () {
      expect(selfUpdateButtonLabel(SelfUpdatePhase.downloading, 0), 'Downloading 0%');
      expect(selfUpdateButtonLabel(SelfUpdatePhase.downloading, 0.4237), 'Downloading 42%');
      expect(selfUpdateButtonLabel(SelfUpdatePhase.downloading, 1), 'Downloading 100%');
    });

    test('covers the gap between a finished download and the system installer', () {
      // ~1-2s on a headset, and the phase the user reported as "doing nothing".
      expect(selfUpdateButtonLabel(SelfUpdatePhase.launchingInstaller, 1), 'Opening installer…');
    });

    test('every phase says something different', () {
      final labels = {
        selfUpdateButtonLabel(null, null),
        selfUpdateButtonLabel(SelfUpdatePhase.resolving, null),
        selfUpdateButtonLabel(SelfUpdatePhase.downloading, 0.5),
        selfUpdateButtonLabel(SelfUpdatePhase.launchingInstaller, null),
      };
      expect(labels, hasLength(4));
    });
  });

  testWidgets('mounts showing the install label, with no spinner until pressed', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SelfUpdateActionButton(
            repo: 'HellboundGlory/plezy',
            releaseUrl: 'https://example.invalid/releases/latest',
            onFinished: _noop,
          ),
        ),
      ),
    );

    expect(find.text('Download & Install'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}

void _noop() {}
