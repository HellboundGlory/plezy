import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/models/shader_preset.dart';
import 'package:plezy/mpv/player/player.dart';
import 'package:plezy/services/shader_asset_loader.dart';
import 'package:plezy/services/shader_service.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory root;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('plezy_shader_service_test_');
    PathProviderPlatform.instance = FakePathProvider(root);
    ShaderAssetLoader.clearCache();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    ShaderAssetLoader.clearCache();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('an escaped custom preset never reaches the MPV shader append command', () async {
    final supportDirectory = Directory(path.join(root.path, 'support'))..createSync(recursive: true);
    final sentinel = File(path.join(supportDirectory.path, 'sentinel.glsl'))..writeAsStringSync('sentinel');
    final player = _RecordingPlayer();
    final service = ShaderService(player);
    const preset = ShaderPreset(
      id: 'custom_traversal',
      name: 'Traversal',
      type: ShaderPresetType.custom,
      fileName: '../sentinel.glsl',
    );

    await service.applyPreset(preset);

    expect(player.commands.where((command) => command.length > 2 && command[2] == 'append'), isEmpty);
    expect(player.commands.single, ['change-list', 'glsl-shaders', 'clr', '']);
    expect(await sentinel.readAsString(), 'sentinel');
  });

  test('appends the pseudo-3D shader after the preset when a synthetic 3D config is given', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);

    await service.applyPreset(
      ShaderPreset.nvscalerDefault,
      threeDConfig: const ThreeDConfig(mode: ThreeDMode.auto, strength: 0.5),
    );

    final appended = player.commands.where((c) => c.length > 2 && c[2] == 'append').map((c) => c[3]).toList();
    expect(appended, hasLength(2));
    expect(path.basename(appended[0]), 'NVScaler.glsl');
    expect(path.basename(appended[1]), 'Pseudo3DSbs.glsl');
  });

  test('applies the pseudo-3D shader alone even when the base preset is none', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);

    await service.applyPreset(ShaderPreset.none, threeDConfig: const ThreeDConfig(mode: ThreeDMode.sbs, strength: 0.5));

    final appended = player.commands.where((c) => c.length > 2 && c[2] == 'append').map((c) => c[3]).toList();
    expect(appended, hasLength(1));
    expect(path.basename(appended.single), 'Pseudo3DSbs.glsl');
  });

  test('skips the pseudo-3D shader entirely for already-3D passthrough content', () async {
    final player = _RecordingPlayer();
    final service = ShaderService(player);

    await service.applyPreset(
      ShaderPreset.none,
      threeDConfig: const ThreeDConfig(mode: ThreeDMode.sbs, strength: 0.5),
      isPassthroughSource: true,
    );

    expect(player.commands.where((c) => c.length > 2 && c[2] == 'append'), isEmpty);
    expect(player.commands.single, ['change-list', 'glsl-shaders', 'clr', '']);
  });
}

class _RecordingPlayer implements Player {
  final commands = <List<String>>[];

  @override
  String get playerType => 'mpv';

  @override
  Future<void> command(List<String> args) async {
    commands.add(List.unmodifiable(args));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
