import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/selfupdate/self_update_target.dart';
import 'package:plezy/selfupdate/self_updater.dart';

void main() {
  late String bundlePath;
  late List<List<String>> commands;
  late int relaunches;

  setUp(() async {
    commands = [];
    relaunches = 0;
    final directory = await Directory.systemTemp.createTemp('self-update-test');
    addTearDown(() => directory.delete(recursive: true));
    bundlePath = '${directory.path}/plezy-flatpak-update.flatpak';
    await File(bundlePath).writeAsString('bundle');
  });

  Future<SelfUpdateResult> install({int infoExit = 0, int installExit = 0, List<SelfUpdatePhase>? phases}) {
    return SelfUpdater.installFlatpakBundle(
      filePath: bundlePath,
      runCommand: (args) async {
        commands.add(args);
        if (args[1] == 'info') return ProcessResult(1, infoExit, '', '');
        return ProcessResult(1, installExit, '', installExit == 0 ? '' : 'installer said no');
      },
      startRelaunch: () async => relaunches++,
      onPhase: phases?.add,
    );
  }

  test('installs a user installation in place', () async {
    final result = await install();

    expect(result.failure, isNull);
    expect(commands, [
      ['flatpak', 'info', '--user', SelfUpdater.flatpakAppId],
      ['flatpak', 'install', '--user', '--noninteractive', '-y', bundlePath],
    ]);
    expect(relaunches, 1);
    expect(File(bundlePath).existsSync(), isFalse);
  });

  test('targets the system installation when the app is not installed per user', () async {
    await install(infoExit: 1);

    expect(commands.last, ['flatpak', 'install', '--system', '--noninteractive', '-y', bundlePath]);
  });

  test('reports a failed install and keeps the bundle', () async {
    final result = await install(installExit: 1);

    expect(result.failure, SelfUpdateFailure.installLaunchFailed);
    expect(relaunches, 0);
    expect(File(bundlePath).existsSync(), isTrue);
  });

  test('reports a failed install when the host runner throws', () async {
    final result = await SelfUpdater.installFlatpakBundle(
      filePath: bundlePath,
      runCommand: (args) async => throw const ProcessException('flatpak-spawn', ['--host']),
      startRelaunch: () async => relaunches++,
    );

    expect(result.failure, SelfUpdateFailure.installLaunchFailed);
    expect(relaunches, 0);
  });

  test('reports an installed update that could not schedule its relaunch', () async {
    final result = await SelfUpdater.installFlatpakBundle(
      filePath: bundlePath,
      runCommand: (args) async => ProcessResult(1, 0, '', ''),
      startRelaunch: () async => throw const ProcessException('flatpak-spawn', ['--host']),
    );

    expect(result.failure, SelfUpdateFailure.relaunchFailed);
  });

  group('relaunch script', () {
    test('waits for the running instance to exit before starting the app', () async {
      final log = await _runRelaunchScript(psScript: '[ \$n -lt 2 ] && echo ${SelfUpdater.flatpakAppId}; true');

      expect(log, ['ps 1', 'ps 2', 'run ${SelfUpdater.flatpakAppId}']);
    });

    test('keeps waiting while flatpak ps fails instead of starting early', () async {
      final log = await _runRelaunchScript(psScript: '[ \$n -lt 2 ] && exit 1; true');

      expect(log, ['ps 1', 'ps 2', 'run ${SelfUpdater.flatpakAppId}']);
    });
  });

  test('says it is installing and then restarting', () async {
    final phases = <SelfUpdatePhase>[];
    await install(phases: phases);

    expect(phases, [SelfUpdatePhase.launchingInstaller, SelfUpdatePhase.restarting]);
  });

  test('reads the bundle arch from the sandbox instance section', () {
    const info = '''
[Application]
name=com.edde746.plezy
runtime=org.freedesktop.Platform/x86_64/25.08

[Instance]
instance-id=1234
app-path=/app
arch=x86_64
''';
    expect(SelfUpdater.debugArchFromFlatpakInfo(info), 'x64');
  });

  test('ignores an arch outside the instance section', () {
    const info = '''
[Application]
arch=aarch64

[Instance]
instance-id=1234
''';
    expect(SelfUpdater.debugArchFromFlatpakInfo(info), isNull);
  });

  group('supportsSelfUpdate', () {
    test('covers the APK targets on any platform', () {
      expect(supportsSelfUpdate(target: SelfUpdateTarget.quest, isLinux: false, flatpakId: null), isTrue);
      expect(supportsSelfUpdate(target: SelfUpdateTarget.fireTv, isLinux: true, flatpakId: null), isTrue);
    });

    test('needs the Flatpak sandbox for the flatpak target', () {
      expect(
        supportsSelfUpdate(target: SelfUpdateTarget.flatpak, isLinux: true, flatpakId: 'com.edde746.plezy'),
        isTrue,
      );
      expect(supportsSelfUpdate(target: SelfUpdateTarget.flatpak, isLinux: true, flatpakId: null), isFalse);
      expect(
        supportsSelfUpdate(target: SelfUpdateTarget.flatpak, isLinux: false, flatpakId: 'com.edde746.plezy'),
        isFalse,
      );
    });

    test('is off with no define', () {
      expect(supportsSelfUpdate(target: null, isLinux: true, flatpakId: 'com.edde746.plezy'), isFalse);
    });
  });
}

Future<List<String>> _runRelaunchScript({required String psScript}) async {
  final dir = await Directory.systemTemp.createTemp('relaunch-test');
  addTearDown(() => dir.delete(recursive: true));
  final log = File('${dir.path}/log');
  final fake = File('${dir.path}/flatpak');
  await fake.writeAsString('''
#!/bin/sh
if [ "\$1" = ps ]; then
  n=\$(cat "${dir.path}/count" 2>/dev/null || echo 0); n=\$((n + 1)); echo \$n > "${dir.path}/count"
  echo "ps \$n" >> "${log.path}"
  $psScript
else
  echo "\$*" >> "${log.path}"
fi
''');
  await Process.run('chmod', ['+x', fake.path]);
  final result = await Process.run(
    'sh',
    ['-c', SelfUpdater.debugRelaunchScript],
    environment: {'PATH': '${dir.path}:${Platform.environment['PATH']}'},
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return log.readAsLinesSync();
}
