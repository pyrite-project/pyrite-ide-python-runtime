import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:serious_python/serious_python.dart';
import 'package:serious_python_platform_interface/serious_python_platform_interface.dart';

class _FakeSeriousPythonPlatform extends SeriousPythonPlatform
    with MockPlatformInterfaceMixin {
  String? receivedAppPath;
  String? receivedScript;

  @override
  Future<String?> run(String appPath,
      {String? script,
      List<String>? modulePaths,
      Map<String, String>? environmentVariables,
      bool? sync}) async {
    receivedAppPath = appPath;
    receivedScript = script;
    return null;
  }
}

void main() {
  test('empty script keeps the legacy Windows path-mode behavior', () async {
    final platform = _FakeSeriousPythonPlatform();
    SeriousPythonPlatform.instance = platform;

    await SeriousPython.runProgram('plugin.py', script: '');

    expect(platform.receivedAppPath, 'plugin.py');
    expect(platform.receivedScript, isNull);
  });

  test('non-empty script remains script mode', () async {
    final platform = _FakeSeriousPythonPlatform();
    SeriousPythonPlatform.instance = platform;

    await SeriousPython.runProgram('plugin.py', script: 'print(1)');

    expect(platform.receivedScript, 'print(1)');
  });
}
