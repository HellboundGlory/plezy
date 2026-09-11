import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plezy/models/shader_preset.dart';
import 'package:plezy/services/shader_asset_loader.dart';

import '../test_helpers/io_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PathProviderPlatform originalPathProvider;
  late Directory root;
  late Directory supportDirectory;
  late File sentinel;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    root = await Directory.systemTemp.createTemp('plezy_shader_asset_loader_test_');
    PathProviderPlatform.instance = FakePathProvider(root);
    supportDirectory = Directory(path.join(root.path, 'support'))..createSync(recursive: true);
    sentinel = File(path.join(supportDirectory.path, 'sentinel.glsl'))..writeAsStringSync('sentinel');
    ShaderAssetLoader.clearCache();
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    ShaderAssetLoader.clearCache();
    if (await root.exists()) await root.delete(recursive: true);
  });

  ShaderPreset customPreset(String fileName) {
    return ShaderPreset(id: 'custom_$fileName', name: fileName, type: ShaderPresetType.custom, fileName: fileName);
  }

  Future<List<int>> bundledBytes(String assetPath) async {
    final data = await rootBundle.load('assets/shaders/$assetPath');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> expectBundledFile(String filePath, String assetPath) async {
    expect(await File(filePath).readAsBytes(), await bundledBytes(assetPath));
  }

  Future<String> bundledText(String assetPath) async => utf8.decode(await bundledBytes(assetPath));

  /// The value a materialized shader actually carries in its `const float
  /// STRENGTH` declaration -- what the hook body multiplies disparity by, as
  /// opposed to a substring that happens to appear somewhere in the file.
  String bakedPseudo3DStrength(File file) {
    final match = RegExp(r'const\s+float\s+STRENGTH\s*=\s*([0-9]*\.?[0-9]+)\s*;').firstMatch(file.readAsStringSync());
    expect(match, isNotNull, reason: 'materialized shader must keep its STRENGTH constant');
    return match!.group(1)!;
  }

  test('traversal and absolute names cannot load or delete outside managed directory', () async {
    for (final fileName in ['../sentinel.glsl', sentinel.path]) {
      expect(await ShaderAssetLoader.getShadersForPreset(customPreset(fileName)), isEmpty);
      await ShaderAssetLoader.deleteCustomShader(fileName);
      expect(await sentinel.readAsString(), 'sentinel');
    }
  });

  test('repairs stale built-in bytes in the application cache without touching temporary storage', () async {
    final cacheFile = File(path.join(root.path, 'cache', 'shaders', 'nvscaler', 'NVScaler.glsl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('stale');
    final oldTemporaryFile = File(path.join(root.path, 'temp', 'shaders', 'nvscaler', 'NVScaler.glsl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('old temporary sentinel');

    final shaders = await ShaderAssetLoader.getShadersForPreset(ShaderPreset.nvscalerDefault);

    expect(shaders, [cacheFile.path]);
    await expectBundledFile(shaders.single, 'nvscaler/NVScaler.glsl');
    expect(await oldTemporaryFile.readAsString(), 'old temporary sentinel');
  });

  test('recovers a truncated built-in final through a complete staged replacement', () async {
    final targetDirectory = Directory(path.join(root.path, 'cache', 'shaders', 'nvscaler'))
      ..createSync(recursive: true);
    final target = File(path.join(targetDirectory.path, 'NVScaler.glsl'))..writeAsBytesSync([1, 2, 3]);
    final unrelatedPending = File('${target.path}.pending.interrupted')..writeAsBytesSync([1]);

    final shaders = await ShaderAssetLoader.getNVScalerShaders();

    expect(shaders, [target.path]);
    await expectBundledFile(target.path, 'nvscaler/NVScaler.glsl');
    expect(unrelatedPending.existsSync(), isTrue);
    final ownedPending = await targetDirectory
        .list()
        .where((entry) => entry.path.contains('.pending.') && entry.path != unrelatedPending.path)
        .toList();
    expect(ownedPending, isEmpty);
  });

  test('does not return a partial path when final-file promotion fails', () async {
    final target = Directory(path.join(root.path, 'cache', 'shaders', 'nvscaler', 'NVScaler.glsl'))
      ..createSync(recursive: true);

    expect(await ShaderAssetLoader.getNVScalerShaders(), isEmpty);

    final siblings = await target.parent.list().toList();
    expect(siblings.where((entry) => entry.path.contains('.pending.')), isEmpty);
    expect(target.existsSync(), isTrue);
  });

  test('coalesces concurrent built-in loads onto one complete final path', () async {
    final results = await Future.wait([ShaderAssetLoader.getNVScalerShaders(), ShaderAssetLoader.getNVScalerShaders()]);

    expect(results[0], results[1]);
    expect(results[0], hasLength(1));
    await expectBundledFile(results[0].single, 'nvscaler/NVScaler.glsl');
    final directory = File(results[0].single).parent;
    expect((await directory.list().toList()).where((entry) => entry.path.contains('.pending.')), isEmpty);
  });

  test('materializes representative built-in chains in MPV order with bundled bytes', () async {
    final nvscaler = await ShaderAssetLoader.getNVScalerShaders();
    final artcnn = await ShaderAssetLoader.getArtCNNShaders(
      const ArtCNNConfig(model: ArtCNNModel.c4f16, variant: ArtCNNVariant.denoise),
    );
    final anime4k = await ShaderAssetLoader.getAnime4KShaders(
      const Anime4KConfig(quality: Anime4KQuality.fast, mode: Anime4KMode.modeB),
    );

    final expected = {
      nvscaler.single: 'nvscaler/NVScaler.glsl',
      artcnn.single: 'artcnn/ArtCNN_C4F16_DN.glsl',
      anime4k[0]: 'anime4k/Anime4K_Clamp_Highlights.glsl',
      anime4k[1]: 'anime4k/Anime4K_Restore_CNN_M.glsl',
      anime4k[2]: 'anime4k/Anime4K_Upscale_CNN_x2_M.glsl',
      anime4k[3]: 'anime4k/Anime4K_AutoDownscalePre_x2.glsl',
    };
    expect(anime4k.map(path.basename).toList(), [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
    ]);
    for (final entry in expected.entries) {
      expect(path.isWithin(path.join(root.path, 'cache'), entry.key), isTrue);
      await expectBundledFile(entry.key, entry.value);
    }
  });

  /// The theater's render-API pair is the one shader in this app that is *not*
  /// an mpv user shader: `render_gl.cpp` compiles it, and it resolves these
  /// exact names with glGetUniformLocation/glGetAttribLocation, failing setup
  /// outright if any is missing. So the names are an interface between two
  /// languages, and a rename on either side silently kills theater mode.
  group('theater 3D warp shaders (render API)', () {
    test('loads both stages and declares the inputs the native pass resolves', () async {
      final shaders = await ShaderAssetLoader.loadTheater3DWarpShaders();
      expect(shaders, isNotNull);

      // render_gl.cpp's setup_gl_objects() requires all five.
      expect(shaders!.vertex, contains('aPos'));
      for (final uniform in ['uFrame', 'uStrength', 'uResolution', 'uSynthetic']) {
        expect(shaders.fragment, contains(uniform), reason: 'render_gl.cpp resolves $uniform');
      }
      // The vertex stage must hand the fragment stage an interpolated
      // coordinate under the name the fragment stage declares.
      expect(shaders.vertex, contains('vUv'));
      expect(shaders.fragment, contains('vUv'));
    });

    /// The two pseudo-3D implementations live side by side and do much the same
    /// maths: `pseudo3d/Pseudo3DSbs.glsl` is mpv's, `theater3d/*` is ours. This
    /// pins the difference so an edit meant for one cannot silently land in the
    /// other -- mpv's parser would reject GLSL ES 3.0, and our GL would reject
    /// a `hook()` body.
    test('are plain GLSL ES 3.0, with no mpv user-shader metadata', () async {
      final shaders = await ShaderAssetLoader.loadTheater3DWarpShaders();
      expect(shaders, isNotNull);

      for (final source in [shaders!.vertex, shaders.fragment]) {
        expect(source.trimLeft(), startsWith('#version 300 es'));
        expect(source, isNot(contains('//!')));
      }
      expect(shaders.fragment, isNot(contains('hook(')));
      expect(shaders.fragment, contains('fragColor'));
    });
  });

  test('materializes the pseudo-3D shader with the requested strength baked into its source', () async {
    final shaderPath = await ShaderAssetLoader.materializePseudo3DShader(0.75);
    expect(shaderPath, isNotNull);

    final bundledLines = (await bundledText('pseudo3d/Pseudo3DSbs.glsl')).split('\n');
    final bakedLines = (await File(shaderPath!).readAsString()).split('\n');

    expect(bakedLines, hasLength(bundledLines.length));
    final differing = [
      for (var i = 0; i < bundledLines.length; i++)
        if (bundledLines[i] != bakedLines[i]) i,
    ];
    // Only the STRENGTH literal changes: the metadata and the whole hook body
    // must survive byte-for-byte.
    expect(differing, hasLength(1));
    expect(bundledLines[differing.single].trim(), 'const float STRENGTH = 0.5;');
    expect(bakedLines[differing.single].trim(), 'const float STRENGTH = 0.75;');
  });

  /// Protects the failure this shipped with once: the shader carried an mpv
  /// `//!PARAM` block, which the classic `vo=gpu` user-shader parser has no
  /// case for -- it errors ("Unrecognized command 'PARAM strength'!") and
  /// abandons the entire file, so the hook never registered and the
  /// compositor raw-split a flat frame instead of synthesizing depth. Parsing
  /// on both backends is a hard requirement, since the theater session's vo is
  /// chosen per file.
  test('the pseudo-3D shader uses only metadata commands classic vo=gpu can parse', () async {
    // The complete command set of parse_hook()/parse_tex() in mpv v0.41.0's
    // video/out/gpu/user_shaders.c. Anything else makes vo=gpu drop the file.
    const voGpuCommands = {
      'HOOK', 'BIND', 'SAVE', 'DESC', 'OFFSET', 'WIDTH', 'HEIGHT', 'WHEN', 'COMPONENTS', 'COMPUTE', // hook
      'TEXTURE', 'SIZE', 'FORMAT', 'FILTER', 'BORDER', // texture
    };

    final source = await bundledText('pseudo3d/Pseudo3DSbs.glsl');
    final commands = <String>[
      for (final line in source.split('\n'))
        if (line.trimLeft().startsWith('//!'))
          if (RegExp(r'^//!([A-Z]+)').firstMatch(line.trimLeft()) case final match?) match.group(1)!,
    ];

    expect(commands, isNotEmpty);
    expect(commands.toSet().difference(voGpuCommands), isEmpty,
        reason: 'a command outside this set makes vo=gpu reject the whole shader file');
    // Named explicitly: this is the exact regression, and the reason strength
    // is materialized into a constant instead.
    expect(commands, isNot(contains('PARAM')));
    expect(source, contains('const float STRENGTH'));
  });

  /// mpv finds the end of a shader's body with a plain substring search for the
  /// two-character header marker (bstr_split_tok in user_shaders.c), not a
  /// line-anchored one. So the marker appearing anywhere but at the start of a
  /// metadata line -- including inside a comment -- truncates the body before
  /// hook() and the shader stops compiling.
  test('the pseudo-3D shader never mentions the header marker outside its metadata block', () async {
    final source = await bundledText('pseudo3d/Pseudo3DSbs.glsl');

    final offenders = [
      for (final (index, line) in source.split('\n').indexed)
        if (line.contains('//!') && !line.trimLeft().startsWith('//!')) '${index + 1}: $line',
    ];

    expect(offenders, isEmpty, reason: 'these lines would truncate the shader body');
  });

  /// The depth proxy must not be derived from image gradients. An earlier
  /// revision mixed `fwidth()` of the sampled colour into depth as a
  /// "soft regions are far" cue, which rendered as a doubled outline / halo
  /// around every object edge: fwidth is an edge detector, so it is peaked
  /// exactly along silhouettes, and a depth discontinuity there makes the two
  /// eyes disagree about where the edge is. No unit test can see that, so this
  /// is the tripwire.
  test('the pseudo-3D depth proxy derives nothing from image derivatives', () async {
    final source = await bundledText('pseudo3d/Pseudo3DSbs.glsl');
    // Comments discuss the removed term on purpose; only code is checked.
    final code = source
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    for (final builtin in ['fwidth', 'dFdx', 'dFdy']) {
      expect(code, isNot(contains(builtin)), reason: '$builtin reintroduces edge-boundary depth artifacts');
    }
    // Local detail comes from a wide blur instead, which is continuous by
    // construction. Bounded so the fetch count cannot creep up unnoticed --
    // this shader runs per pixel per eye, so taps are the cost that matters.
    expect(RegExp(r'HOOKED_tex\(').allMatches(code).length, lessThanOrEqualTo(8));
  });

  /// The blur and the disparity sample are both taken in full-frame
  /// coordinates. Sampling either through srcUv would straddle the fract()
  /// wrap at uv.x == 0.5 and mix the two eye images into each other.
  test('the pseudo-3D shader takes its multi-tap samples in unwrapped coordinates', () async {
    final source = await bundledText('pseudo3d/Pseudo3DSbs.glsl');

    final wrappedSamples = [
      for (final (index, line) in source.split('\n').indexed)
        if (!line.trimLeft().startsWith('//') &&
            RegExp(r'HOOKED_tex\(\s*srcUv\s*[+-]').hasMatch(line))
          '${index + 1}: ${line.trim()}',
    ];

    expect(wrappedSamples, isEmpty,
        reason: 'a windowed sample through srcUv spans the fract() wrap and mixes the eye halves');
  });

  test('materializes one stable file per quantized strength', () async {
    final first = await ShaderAssetLoader.materializePseudo3DShader(0.25);
    final repeat = await ShaderAssetLoader.materializePseudo3DShader(0.25);
    final other = await ShaderAssetLoader.materializePseudo3DShader(0.8);

    expect(first, isNotNull);
    // A repeat launch at the same setting must reuse the file rather than
    // write a sibling, and 0.8 must not collide with 0.25.
    expect(repeat, first);
    expect(other, isNot(first));
    expect(bakedPseudo3DStrength(File(other!)), '0.80');
    // Out-of-range input is clamped rather than written raw into the source.
    expect(bakedPseudo3DStrength(File((await ShaderAssetLoader.materializePseudo3DShader(4))!)), '1.00');
  });

  test('getShadersForPreset appends the pseudo-3D shader at the configured strength', () async {
    final shaders = await ShaderAssetLoader.getShadersForPreset(
      ShaderPreset.nvscalerDefault,
      threeDConfig: const ThreeDConfig(mode: ThreeDMode.auto, strength: 0.75),
    );

    expect(shaders, hasLength(2));
    await expectBundledFile(shaders[0], 'nvscaler/NVScaler.glsl');
    expect(bakedPseudo3DStrength(File(shaders[1])), '0.75');
  });

  test('getShadersForPreset appends the pseudo-3D shader even when the base preset is none', () async {
    final shaders = await ShaderAssetLoader.getShadersForPreset(
      ShaderPreset.none,
      threeDConfig: const ThreeDConfig(mode: ThreeDMode.sbs, strength: 0.6),
    );

    expect(shaders, hasLength(1));
    expect(bakedPseudo3DStrength(File(shaders.single)), '0.60');
  });

  test('getShadersForPreset omits the pseudo-3D shader when the 3D mode is off', () async {
    final shaders = await ShaderAssetLoader.getShadersForPreset(
      ShaderPreset.nvscalerDefault,
      threeDConfig: const ThreeDConfig(mode: ThreeDMode.off, strength: 0.5),
    );

    expect(shaders, hasLength(1));
    await expectBundledFile(shaders.single, 'nvscaler/NVScaler.glsl');
  });

  test('getShadersForPreset omits the pseudo-3D shader when no 3D config is given', () async {
    final shaders = await ShaderAssetLoader.getShadersForPreset(ShaderPreset.nvscalerDefault);

    expect(shaders, hasLength(1));
    await expectBundledFile(shaders.single, 'nvscaler/NVScaler.glsl');
  });

  test('repeats the restore pass in place for doubled Anime4K modes', () async {
    final shaders = await ShaderAssetLoader.getAnime4KShaders(
      const Anime4KConfig(quality: Anime4KQuality.fast, mode: Anime4KMode.modeBB),
    );

    expect(shaders.map(path.basename).toList(), [
      'Anime4K_Clamp_Highlights.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Restore_CNN_M.glsl',
      'Anime4K_Upscale_CNN_x2_M.glsl',
      'Anime4K_AutoDownscalePre_x2.glsl',
    ]);
    expect(shaders[1], shaders[2]);
  });

  test('nested and non-GLSL names are rejected without touching matching files', () async {
    final customDirectory = Directory(path.join(supportDirectory.path, 'custom_shaders'))..createSync(recursive: true);
    final nested = File(path.join(customDirectory.path, 'subdir', 'name.glsl'))
      ..createSync(recursive: true)
      ..writeAsStringSync('nested');
    final extraExtension = File(path.join(customDirectory.path, 'name.glsl.txt'))..writeAsStringSync('extra');

    for (final fileName in ['subdir/name.glsl', r'subdir\name.glsl', '.', '..', 'name.glsl.txt', 'name.txt']) {
      expect(ShaderAssetLoader.isValidCustomShaderFileName(fileName), isFalse);
      expect(await ShaderAssetLoader.getShadersForPreset(customPreset(fileName)), isEmpty);
      await ShaderAssetLoader.deleteCustomShader(fileName);
    }

    expect(await nested.readAsString(), 'nested');
    expect(await extraExtension.readAsString(), 'extra');
  });

  test('non-GLSL import fails before creating a managed file', () async {
    final source = File(path.join(root.path, 'shader.txt'))..writeAsStringSync('not glsl');

    await expectLater(ShaderAssetLoader.importCustomShader(source.path), throwsArgumentError);

    final customDirectory = Directory(path.join(supportDirectory.path, 'custom_shaders'));
    expect(customDirectory.existsSync(), isFalse);
  });

  test('imports a direct UUID GLSL child and deletes only that file', () async {
    final source = File(path.join(root.path, 'shader.GLSL'))..writeAsStringSync('shader');

    final storedName = await ShaderAssetLoader.importCustomShader(source.path);
    expect(storedName, matches(RegExp(r'^[0-9a-f-]+\.glsl$')));
    expect(ShaderAssetLoader.isValidCustomShaderFileName(storedName), isTrue);

    final shaders = await ShaderAssetLoader.getShadersForPreset(customPreset(storedName));
    expect(shaders, hasLength(1));
    expect(path.equals(path.dirname(shaders.single), path.join(supportDirectory.path, 'custom_shaders')), isTrue);
    expect(await File(shaders.single).readAsString(), 'shader');

    await ShaderAssetLoader.deleteCustomShader(storedName);
    expect(File(shaders.single).existsSync(), isFalse);
    expect(await source.readAsString(), 'shader');
  });

  test('legacy base-36 managed names remain loadable and deletable', () async {
    const storedName = 'ks9p7.glsl';
    final customDirectory = Directory(path.join(supportDirectory.path, 'custom_shaders'))..createSync(recursive: true);
    final managedFile = File(path.join(customDirectory.path, storedName))..writeAsStringSync('legacy');

    expect(ShaderAssetLoader.isValidCustomShaderFileName(storedName), isTrue);
    final shaders = await ShaderAssetLoader.getShadersForPreset(customPreset(storedName));
    expect(shaders, hasLength(1));
    expect(path.equals(shaders.single, managedFile.path), isTrue);

    await ShaderAssetLoader.deleteCustomShader(storedName);
    expect(managedFile.existsSync(), isFalse);
  });
}
