import 'dart:async' show unawaited;
import 'dart:convert' show utf8;
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/shader_preset.dart';
import '../utils/app_logger.dart';

/// Utility class for loading GLSL shader assets for MPV video enhancement.
///
/// Extracts shader files from Flutter assets to the app's cache directory
/// where MPV can access them at runtime.
class ShaderAssetLoader {
  static const String _shaderAssetBase = 'assets/shaders';
  static String? _cachedShaderDir;
  static final RegExp _customShaderFileNamePattern = RegExp(r'^[A-Za-z0-9-]+\.glsl$', caseSensitive: false);
  static final Map<String, String> _verifiedBuiltInShaderPaths = {};
  static final Map<String, Future<String?>> _inFlightBuiltInShaders = {};
  static int _cacheGeneration = 0;

  /// NVScaler shader file
  static const String _nvscalerShader = 'nvscaler/NVScaler.glsl';

  /// ArtCNN shader files organized by preset model and variant.
  static const Map<String, String> _artcnnShaders = {
    'c4f16_neutral': 'artcnn/ArtCNN_C4F16.glsl',
    'c4f16_dn': 'artcnn/ArtCNN_C4F16_DN.glsl',
    'c4f16_ds': 'artcnn/ArtCNN_C4F16_DS.glsl',
    'c4f32_neutral': 'artcnn/ArtCNN_C4F32.glsl',
    'c4f32_dn': 'artcnn/ArtCNN_C4F32_DN.glsl',
    'c4f32_ds': 'artcnn/ArtCNN_C4F32_DS.glsl',
  };

  /// Anime4K shader files organized by function
  static const Map<String, String> _anime4kShaders = {
    'clamp': 'anime4k/Anime4K_Clamp_Highlights.glsl',
    'restore_m': 'anime4k/Anime4K_Restore_CNN_M.glsl',
    'restore_vl': 'anime4k/Anime4K_Restore_CNN_VL.glsl',
    'restore_ul': 'anime4k/Anime4K_Restore_CNN_UL.glsl',
    'upscale_m': 'anime4k/Anime4K_Upscale_CNN_x2_M.glsl',
    'upscale_vl': 'anime4k/Anime4K_Upscale_CNN_x2_VL.glsl',
    'upscale_ul': 'anime4k/Anime4K_Upscale_CNN_x2_UL.glsl',
    'downscale': 'anime4k/Anime4K_AutoDownscalePre_x2.glsl',
    'downscale_post': 'anime4k/Anime4K_AutoDownscalePre_x4.glsl',
  };

  /// Heuristic pseudo-3D SBS shader (PLAN_3D.md Phase 2). Not keyed to any
  /// [ShaderPresetType] -- [ThreeDConfig] is an orthogonal overlay appended
  /// on top of whichever preset (including none) is already active.
  ///
  /// This file is for the **flat** player's mpv shader chain only: strength has
  /// to be baked into a per-strength copy of it, since mpv's `//!PARAM`
  /// mechanism is unavailable on the classic `vo=gpu` backend that chain can
  /// land on (see [materializePseudo3DShader]). The theater's own 2D->3D path
  /// deliberately does *not* use it -- it runs as a shader this app compiles
  /// inside its mpv render-API pass, where strength is a uniform. See
  /// [loadTheater3DWarpShaders] and HANDOFF_RENDER_API.md.
  static const String _pseudo3DShader = 'pseudo3d/Pseudo3DSbs.glsl';

  /// The theater's render-API warp pair (HANDOFF_RENDER_API.md). Two plain
  /// GLSL ES 3.0 stages the native render host compiles itself, unlike every
  /// other shader here: they are handed to the platform channel as *source
  /// text*, never written to a file, because no mpv instance ever parses them.
  /// See [loadTheater3DWarpShaders].
  static const String _theater3DVertexShader = 'theater3d/Pseudo3DWarp.vert.glsl';
  static const String _theater3DFragmentShader = 'theater3d/Pseudo3DWarp.frag.glsl';

  /// Reads the theater render-API shader pair out of the asset bundle.
  ///
  /// Returns null if either stage is missing or unreadable, which the caller
  /// must treat as "no theater session": a session without its warp/pack
  /// program has nothing to put on the panel.
  static Future<({String vertex, String fragment})?> loadTheater3DWarpShaders() async {
    try {
      final vertex = await _readShaderAsset(_theater3DVertexShader);
      final fragment = await _readShaderAsset(_theater3DFragmentShader);
      if (vertex == null || fragment == null) {
        appLogger.e('Theater 3D warp shader missing from the asset bundle: '
            'vertex=${vertex != null}, fragment=${fragment != null}');
        return null;
      }
      return (vertex: vertex, fragment: fragment);
    } catch (e, st) {
      appLogger.w('Failed to load theater 3D warp shaders', error: e, stackTrace: st);
      return null;
    }
  }

  static Future<String?> _readShaderAsset(String assetPath) async {
    final data = await rootBundle.load('$_shaderAssetBase/$assetPath');
    return utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  }

  /// Get the application-owned shader cache directory, creating it if needed.
  static Future<String> _getShaderDirectory() async {
    if (_cachedShaderDir != null) return _cachedShaderDir!;

    final cacheDir = await getApplicationCacheDirectory();
    final shaderDir = Directory(path.join(cacheDir.path, 'shaders'));
    if (!await shaderDir.exists()) {
      await shaderDir.create(recursive: true);
    }

    _cachedShaderDir = shaderDir.path;
    return shaderDir.path;
  }

  /// Extract a single shader file from assets to the cache directory.
  /// Returns the absolute file path of the extracted shader.
  static Future<String?> _extractShader(String assetPath) {
    final generation = _cacheGeneration;
    final operationKey = '$generation:$assetPath';
    final active = _inFlightBuiltInShaders[operationKey];
    if (active != null) return active;

    final operation = _materializeBuiltInShader(assetPath, generation);
    _inFlightBuiltInShaders[operationKey] = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_inFlightBuiltInShaders[operationKey], operation)) {
          _inFlightBuiltInShaders.remove(operationKey);
        }
      }),
    );
    return operation;
  }

  static Future<String?> _materializeBuiltInShader(String assetPath, int generation) async {
    File? pendingFile;
    try {
      final verifiedPath = _verifiedBuiltInShaderPaths[assetPath];
      if (verifiedPath != null) {
        if (await File(verifiedPath).exists()) return verifiedPath;
        _verifiedBuiltInShaderPaths.remove(assetPath);
      }

      final shaderDir = await _getShaderDirectory();
      final targetDir = Directory(path.join(shaderDir, path.dirname(assetPath)));
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      final targetFile = File(path.join(targetDir.path, path.basename(assetPath)));
      final data = await rootBundle.load('$_shaderAssetBase/$assetPath');
      final bundledBytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);

      if (await _fileMatches(targetFile, bundledBytes)) {
        if (generation == _cacheGeneration) {
          _verifiedBuiltInShaderPaths[assetPath] = targetFile.path;
        }
        return targetFile.path;
      }

      pendingFile = File('${targetFile.path}.pending.${const Uuid().v4()}');
      await pendingFile.writeAsBytes(bundledBytes, flush: true);
      if (!await _promotePendingShader(pendingFile, targetFile, bundledBytes)) {
        return null;
      }
      if (!await _fileMatches(targetFile, bundledBytes)) return null;

      if (generation == _cacheGeneration) {
        _verifiedBuiltInShaderPaths[assetPath] = targetFile.path;
      }
      return targetFile.path;
    } catch (e, st) {
      appLogger.w('Failed to extract shader $assetPath', error: e, stackTrace: st);
      return null;
    } finally {
      if (pendingFile != null) {
        try {
          if (await pendingFile.exists()) await pendingFile.delete();
        } on FileSystemException {
          // The pending path is never returned and can be reclaimed with cache.
        }
      }
    }
  }

  static Future<bool> _promotePendingShader(File pendingFile, File targetFile, List<int> bundledBytes) async {
    try {
      await pendingFile.rename(targetFile.path);
      return true;
    } on FileSystemException {
      if (await _fileMatches(targetFile, bundledBytes)) return true;
    }

    try {
      if (await targetFile.exists()) await targetFile.delete();
      await pendingFile.rename(targetFile.path);
      return true;
    } on FileSystemException {
      return _fileMatches(targetFile, bundledBytes);
    }
  }

  static Future<bool> _fileMatches(File file, List<int> expected) async {
    try {
      if (!await file.exists()) return false;
      final actual = await file.readAsBytes();
      if (actual.length != expected.length) return false;
      for (var index = 0; index < expected.length; index++) {
        if (actual[index] != expected[index]) return false;
      }
      return true;
    } on FileSystemException {
      return false;
    }
  }

  /// Get the shader file paths for NVScaler preset.
  /// Returns a list containing the single NVScaler shader path.
  static Future<List<String>> getNVScalerShaders() async {
    final shaderPath = await _extractShader(_nvscalerShader);
    if (shaderPath == null) return [];
    return [shaderPath];
  }

  /// Get the shader file path for an ArtCNN preset.
  /// Returns a list containing exactly one ArtCNN shader path.
  static Future<List<String>> getArtCNNShaders(ArtCNNConfig config) async {
    final shaderPath = await _extractShader(_artcnnShaders['${config.model.name}_${config.variant.slug}']!);
    if (shaderPath == null) return [];
    return [shaderPath];
  }

  /// Get the shader file paths for an Anime4K preset.
  /// Returns a list of shader paths in the correct order for MPV.
  static Future<List<String>> getAnime4KShaders(Anime4KConfig config) async {
    final (restoreVariant, upscaleVariant) = switch (config.quality) {
      Anime4KQuality.fast => ('restore_m', 'upscale_m'),
      Anime4KQuality.hq => ('restore_vl', 'upscale_vl'),
    };

    // All modes start with Clamp, then apply their own ordered chain.
    final chain = <String>[
      'clamp',
      ...switch (config.mode) {
        Anime4KMode.modeA => [restoreVariant],
        Anime4KMode.modeB => [restoreVariant, upscaleVariant, 'downscale'],
        Anime4KMode.modeC => [upscaleVariant, 'downscale'],
        Anime4KMode.modeAA => [restoreVariant, restoreVariant],
        Anime4KMode.modeBB => [restoreVariant, restoreVariant, upscaleVariant, 'downscale'],
        Anime4KMode.modeCA => [upscaleVariant, restoreVariant, 'downscale'],
      },
    ];

    final shaders = <String>[];
    final extracted = <String, String?>{};
    for (final key in chain) {
      if (!extracted.containsKey(key)) {
        extracted[key] = await _extractShader(_anime4kShaders[key]!);
      }
      final shaderPath = extracted[key];
      if (shaderPath != null) shaders.add(shaderPath);
    }

    return shaders;
  }

  /// Strength granularity baked into a materialized pseudo-3D shader. The
  /// value is rounded to this before being written, so the resulting path is
  /// a stable function of the percentage the settings sheet displays
  /// (`_formatThreeDStrength`) and a repeat launch at the same setting
  /// reuses the same file.
  static const double pseudo3DStrengthGranularity = 0.01;

  static final Map<String, Future<String?>> _inFlightBakedPseudo3D = {};
  static final Map<String, String> _verifiedBakedPseudo3D = {};

  /// Materializes [Pseudo3DSbs.glsl] with [strength] written into its
  /// `const float STRENGTH` value, returning the path to that copy (null if
  /// it could not be written).
  ///
  /// Strength is baked into a per-strength copy rather than left as an mpv
  /// parameter because mpv's `//!PARAM` blocks are a libplacebo
  /// (`vo=gpu-next`) feature: classic `vo=gpu`'s user-shader parser has no
  /// `PARAM` case, so it reports `Unrecognized command 'PARAM ...'` and
  /// abandons the *entire shader file* — a `vo=gpu` session then renders the
  /// untouched frame with no hook registered, and no error past that one log
  /// line. That is exactly how this shipped broken once. The theater path
  /// picks its GL backend per file (`MpvPlayerCore.initialVideoOutput`, gpu
  /// first), so the shader has to parse on both, and baking is the only
  /// mechanism that does not depend on which one a session lands on. See
  /// PLAN_3D.md Phase 2 section 2.1 and the changelog entries that resolved
  /// it.
  static Future<String?> materializePseudo3DShader(double strength) {
    final steps = (strength.clamp(0.0, 1.0) / pseudo3DStrengthGranularity).round();
    final quantized = steps * pseudo3DStrengthGranularity;
    final key = quantized.toStringAsFixed(2);
    final generation = _cacheGeneration;
    final operationKey = '$generation:$key';
    final active = _inFlightBakedPseudo3D[operationKey];
    if (active != null) return active;

    final operation = _writeBakedPseudo3DShader(key, generation);
    _inFlightBakedPseudo3D[operationKey] = operation;
    unawaited(
      operation.whenComplete(() {
        if (identical(_inFlightBakedPseudo3D[operationKey], operation)) {
          _inFlightBakedPseudo3D.remove(operationKey);
        }
      }),
    );
    return operation;
  }

  static Future<String?> _writeBakedPseudo3DShader(String key, int generation) async {
    try {
      final verified = _verifiedBakedPseudo3D[key];
      if (verified != null) {
        if (await File(verified).exists()) return verified;
        _verifiedBakedPseudo3D.remove(key);
      }

      final data = await rootBundle.load('$_shaderAssetBase/$_pseudo3DShader');
      final source = utf8.decode(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
      final baked = _bakePseudo3DStrength(source, key);
      if (baked == null) {
        // Only reachable if the bundled shader stops exposing `strength`;
        // the shader's own default is then used rather than failing the
        // session. `shader_asset_loader_test.dart` pins the block's shape so
        // this cannot rot silently.
        appLogger.e('Pseudo-3D shader exposes no strength parameter to bake; falling back to its bundled default');
        return await _extractShader(_pseudo3DShader);
      }
      final bytes = utf8.encode(baked);

      final shaderDir = await _getShaderDirectory();
      final targetDir = Directory(path.join(shaderDir, 'pseudo3d'));
      if (!await targetDir.exists()) {
        await targetDir.create(recursive: true);
      }
      final targetFile = File(path.join(targetDir.path, 'Pseudo3DSbs_s${key.replaceAll('.', '')}.glsl'));

      if (!await _fileMatches(targetFile, bytes)) {
        await targetFile.writeAsBytes(bytes, flush: true);
      }
      if (generation == _cacheGeneration) {
        _verifiedBakedPseudo3D[key] = targetFile.path;
      }
      return targetFile.path;
    } catch (e, st) {
      appLogger.w('Failed to materialize pseudo-3D shader at strength $key', error: e, stackTrace: st);
      return null;
    }
  }

  /// Replaces the `const float STRENGTH = <value>;` literal with [value],
  /// returning null when the file declares no such constant.
  ///
  /// The shader deliberately carries strength as a plain GLSL constant rather
  /// than an mpv `//!PARAM` block: `PARAM` is a libplacebo (vo=gpu-next)
  /// feature, and classic vo=gpu's parser has no case for it -- it errors and
  /// abandons the entire shader file, so a vo=gpu session would silently
  /// render the untouched frame. See the shader's own header comment.
  static String? _bakePseudo3DStrength(String source, String value) {
    final pattern = RegExp(r'^([ \t]*const[ \t]+float[ \t]+STRENGTH[ \t]*=[ \t]*)([0-9]*\.?[0-9]+)([ \t]*;)',
        multiLine: true);
    if (!pattern.hasMatch(source)) return null;
    return source.replaceFirstMapped(pattern, (match) => '${match[1]}$value${match[3]}');
  }

  /// The heuristic pseudo-3D SBS shader as an mpv `glsl-shaders` entry, with
  /// [strength] baked into its source. Returns the single materialized path, or
  /// an empty list on failure.
  ///
  /// **Flat player only.** The Quest theater path does not use this: it runs
  /// its own GL pass inside mpv's render API, where strength is a uniform (see
  /// [loadTheater3DWarpShaders] and HANDOFF_RENDER_API.md). This mechanism
  /// exists for the flat player's shader chain, which can land on classic
  /// `vo=gpu` and therefore has to bake strength into the source -- mpv's
  /// `//!PARAM` block is a libplacebo feature that vo=gpu rejects outright.
  static Future<List<String>> getPseudo3DShaders({required double strength}) async {
    final shaderPath = await materializePseudo3DShader(strength);
    if (shaderPath == null) return [];
    return [shaderPath];
  }

  /// Whether [fileName] is a direct managed GLSL shader basename.
  ///
  /// UUID names generated by current builds and alphanumeric names generated
  /// by older builds are both accepted.
  static bool isValidCustomShaderFileName(String fileName) {
    return _customShaderFileNamePattern.hasMatch(fileName);
  }

  /// Get the custom shader directory path, creating it if necessary.
  /// Uses app support directory (persistent) rather than temp/cache.
  static Future<String> _getCustomShaderDirectory() async {
    final supportDir = await getApplicationSupportDirectory();
    final customDir = Directory(path.join(supportDir.path, 'custom_shaders'));

    if (!await customDir.exists()) {
      await customDir.create(recursive: true);
    }

    return customDir.path;
  }

  /// Import a custom shader file into the custom shaders directory.
  /// Returns the stored file name (UUID-based to avoid collisions).
  static Future<String> importCustomShader(String sourcePath) async {
    if (path.extension(sourcePath).toLowerCase() != '.glsl') {
      throw ArgumentError.value(sourcePath, 'sourcePath', 'Custom shaders must use the .glsl extension');
    }

    final customDir = await _getCustomShaderDirectory();
    final storedName = '${const Uuid().v4()}.glsl';
    await File(sourcePath).copy(path.join(customDir, storedName));
    return storedName;
  }

  /// Delete a custom shader file from the custom shaders directory.
  static Future<void> deleteCustomShader(String fileName) async {
    final file = await _resolveManagedCustomShaderFile(fileName);
    if (file != null && await file.exists()) {
      await file.delete();
    }
  }

  static Future<File?> _resolveManagedCustomShaderFile(String fileName) async {
    if (!isValidCustomShaderFileName(fileName)) return null;

    final customDir = path.canonicalize(await _getCustomShaderDirectory());
    final candidate = path.canonicalize(path.join(customDir, fileName));
    if (!path.equals(path.dirname(candidate), customDir)) return null;
    return File(candidate);
  }

  /// Get shader paths for a given preset.
  /// Returns an empty list for ShaderPresetType.none.
  ///
  /// [threeDConfig] appends the heuristic pseudo-3D SBS shader after the
  /// preset's own shaders (PLAN_3D.md Phase 2) when its mode is anything but
  /// [ThreeDMode.off], materialized with [ThreeDConfig.strength] baked in.
  /// Pass null for already-3D passthrough content -- it needs [ThreeDMode]
  /// only to select `stereoMode`, never this shader (see
  /// `ShaderService.applyPreset`).
  /// The `glsl-shaders` chain for [preset], with the pseudo-3D overlay appended
  /// when [threeDConfig] asks for one. See [getPseudo3DShaders] for why this
  /// path bakes strength into the shader source and the theater path does not.
  static Future<List<String>> getShadersForPreset(ShaderPreset preset, {ThreeDConfig? threeDConfig}) async {
    final baseShaders = await _shadersForPresetType(preset);
    if (threeDConfig == null || threeDConfig.mode == ThreeDMode.off) return baseShaders;
    return [...baseShaders, ...await getPseudo3DShaders(strength: threeDConfig.strength)];
  }

  static Future<List<String>> _shadersForPresetType(ShaderPreset preset) async {
    switch (preset.type) {
      case ShaderPresetType.none:
        return [];
      case ShaderPresetType.nvscaler:
        return getNVScalerShaders();
      case ShaderPresetType.artcnn:
        if (preset.artcnnConfig == null) return [];
        return getArtCNNShaders(preset.artcnnConfig!);
      case ShaderPresetType.anime4k:
        if (preset.anime4kConfig == null) return [];
        return getAnime4KShaders(preset.anime4kConfig!);
      case ShaderPresetType.custom:
        final fileName = preset.fileName;
        if (fileName == null) return [];
        final shaderFile = await _resolveManagedCustomShaderFile(fileName);
        if (shaderFile == null || !await shaderFile.exists()) return [];
        return [shaderFile.path];
    }
  }

  /// Clear cached shader directory reference.
  /// Call when clearing app cache.
  static void clearCache() {
    _cacheGeneration++;
    _cachedShaderDir = null;
    _verifiedBuiltInShaderPaths.clear();
    _verifiedBakedPseudo3D.clear();
  }
}
