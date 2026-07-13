import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:serious_python_platform_interface/serious_python_platform_interface.dart';

/// Android implementation of [SeriousPythonPlatform].
class SeriousPythonAndroid extends SeriousPythonPlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('android_plugin');

  static void registerWith() {
    SeriousPythonPlatform.instance = SeriousPythonAndroid();
  }

  Future<String> _base() async {
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'flet');
  }

  Future<String> _runtimeKey() async {
    final appVersion = await _appVersion();
    return appVersion != null ? 'runtime:$appVersion' : 'runtime:dev';
  }

  /// Materializes the interpreter assets without requiring a packaged app.
  ///
  /// Pyrite executes boot and plugin files from runtime-extracted assets, so
  /// it needs stdlib/site-packages even when SERIOUS_PYTHON_APP was not set
  /// and the APK intentionally has no app.zip.
  Future<void> _prepareRuntime() async {
    final base = await _base();
    final stdlibZip = p.join(base, 'stdlib.zip');
    final siteZip = p.join(base, 'sitepackages.zip');
    final extractDir = p.join(base, 'extract');
    final key = await _runtimeKey();
    final marker = File(p.join(base, '.runtime-key'));
    final upToDate =
        await marker.exists() && (await marker.readAsString()) == key;
    if (upToDate) return;

    await Directory(base).create(recursive: true);
    if (await Directory(extractDir).exists()) {
      await Directory(extractDir).delete(recursive: true);
    }
    await methodChannel.invokeMethod(
        'extractAsset', {'asset': 'stdlib.zip', 'dest': stdlibZip});
    await methodChannel.invokeMethod(
        'extractAsset', {'asset': 'sitepackages.zip', 'dest': siteZip});
    await methodChannel.invokeMethod(
        'unzipAsset', {'asset': 'extract.zip', 'dest': extractDir});
    await marker.writeAsString(key);
  }

  @override
  Future<String> prepareApp() async {
    await _prepareRuntime();

    final base = await _base();
    final appDir = p.join(base, 'app');
    final key = await _runtimeKey();
    final marker = File(p.join(base, '.app-key'));
    final upToDate =
        await marker.exists() && (await marker.readAsString()) == key;
    if (!upToDate) {
      if (await Directory(appDir).exists()) {
        await Directory(appDir).delete(recursive: true);
      }
      await methodChannel
          .invokeMethod('unzipAsset', {'asset': 'app.zip', 'dest': appDir});
      await marker.writeAsString(key);
    }
    return appDir;
  }

  @override
  Future<String?> run(String appPath,
      {String? script,
      List<String>? modulePaths,
      Map<String, String>? environmentVariables,
      bool? sync}) async {
    await _prepareRuntime();

    final base = await _base();
    final stdlibZip = p.join(base, 'stdlib.zip');
    final siteZip = p.join(base, 'sitepackages.zip');
    final extractDir = p.join(base, 'extract');
    final programDir = p.dirname(appPath);

    final pythonPaths = <String>[
      ...?modulePaths,
      programDir,
      extractDir,
      siteZip,
      stdlibZip,
    ];

    var jniReady = false;
    try {
      await methodChannel.invokeMethod('loadLibrary', {'libname': 'pyjni'});
      jniReady = true;
    } catch (_) {
      // pyjnius is optional.
    }

    final env = <String, String>{
      'PYTHONDONTWRITEBYTECODE': '1',
      'PYTHONNOUSERSITE': '1',
      'PYTHONUNBUFFERED': '1',
      'LC_CTYPE': 'UTF-8',
      'PYTHONHOME': base,
      'PYTHONPATH': pythonPaths.join(':'),
      if (jniReady) 'FLET_JNI_READY': '1',
      ...?environmentVariables,
    };

    final rc = await runPersistentPython(
      bridge: DartBridge.instance,
      appPath: script == null || script.isEmpty ? appPath : null,
      script: script == null || script.isEmpty ? null : script,
      modulePaths: pythonPaths,
      environmentVariables: env,
      sync: sync ?? false,
    );
    return rc != 0 ? 'Python exited with code $rc' : null;
  }

  Future<String?> _appVersion() async {
    try {
      return await methodChannel.invokeMethod<String>('getAppVersion');
    } catch (_) {
      return null;
    }
  }
}
