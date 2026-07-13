import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:serious_python_platform_interface/serious_python_platform_interface.dart';

export 'package:serious_python_platform_interface/src/utils.dart';

/// Provides cross-platform functionality for running Python programs.
class SeriousPython {
  SeriousPython._();

  /// Prepares the packaged app on disk and returns its directory.
  static Future<String> prepareApp() {
    WidgetsFlutterBinding.ensureInitialized();
    return SeriousPythonPlatform.instance.prepareApp();
  }

  /// Runs the packaged Python app.
  ///
  /// The app is resolved via [prepareApp] and runs with a writable per-app
  /// data directory as its current directory.
  static Future<String?> run(
      {String? appFileName,
      List<String>? modulePaths,
      Map<String, String>? environmentVariables,
      bool? sync}) async {
    final appDir = await prepareApp();
    final appPath = await _resolveEntryPoint(appDir, appFileName);

    final supportDir = await getApplicationSupportDirectory();
    final dataDir = Directory(path.join(supportDir.path, 'data'));
    if (!await dataDir.exists()) {
      await dataDir.create(recursive: true);
    }
    Directory.current = dataDir.path;

    return runProgram(appPath,
        modulePaths: modulePaths,
        environmentVariables: environmentVariables,
        sync: sync);
  }

  /// Runs a Python program from a Flutter asset.
  ///
  /// Zip assets are extracted on demand. [targetPath], [checkHash], and
  /// [invalidateKey] control the extraction cache.
  static Future<String?> runAsset(String assetPath,
      {String? appFileName,
      List<String>? modulePaths,
      Map<String, String>? environmentVariables,
      bool? sync,
      String? targetPath,
      bool checkHash = false,
      String? invalidateKey}) async {
    late String appPath;
    if (path.extension(assetPath) == '.zip') {
      final appDir = await extractAssetZip(assetPath,
          targetPath: targetPath,
          checkHash: checkHash,
          invalidateKey: invalidateKey);
      appPath = await _resolveEntryPoint(appDir, appFileName);
    } else {
      appPath = await extractAsset(assetPath);
    }

    Directory.current = path.dirname(appPath);
    return runProgram(appPath,
        modulePaths: modulePaths,
        environmentVariables: environmentVariables,
        sync: sync);
  }

  /// Runs a Python program from a path.
  ///
  /// [script] executes source text instead of [appPath]. An empty script is
  /// treated as the pre-4.0 Windows sentinel for path mode.
  static Future<String?> runProgram(String appPath,
      {String? script,
      List<String>? modulePaths,
      Map<String, String>? environmentVariables,
      bool? sync}) async {
    final normalizedScript = script != null && script.isEmpty ? null : script;
    return SeriousPythonPlatform.instance.run(appPath,
        script: normalizedScript,
        modulePaths: modulePaths,
        environmentVariables: environmentVariables,
        sync: sync);
  }

  static void terminate() {
    SeriousPythonPlatform.instance.terminate();
  }

  static Future<String> _resolveEntryPoint(
      String appDir, String? appFileName) async {
    if (appFileName != null) {
      return path.join(appDir, appFileName);
    }
    if (await File(path.join(appDir, 'main.pyc')).exists()) {
      return path.join(appDir, 'main.pyc');
    }
    if (await File(path.join(appDir, 'main.py')).exists()) {
      return path.join(appDir, 'main.py');
    }
    throw Exception('App must contain either `main.py` or `main.pyc`; '
        'otherwise `appFileName` must be specified.');
  }
}
