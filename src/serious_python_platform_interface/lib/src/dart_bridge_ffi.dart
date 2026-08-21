import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'persistent_runtime_completion_registry.dart';

/// FFI bindings for the `dart_bridge` C library published by
/// [flet-dev/dart-bridge](https://github.com/flet-dev/dart-bridge).
///
/// One binding lives in this platform-interface package so every
/// `serious_python_*` plugin can share it. The library handle resolution
/// differs by platform:
///
/// - Apple (macOS/iOS): statically linked into the host app via
///   `dart_bridge.xcframework` — looked up through [DynamicLibrary.process].
/// - Android: bundled as `libdart_bridge.so` in jniLibs — opened by name.
/// - Linux: bundled next to the executable — opened by name.
/// - Windows: the release-ABI `dart_bridge.dll` is bundled next to the .exe
///   for every Flutter build mode. This keeps embedded CPython compatible
///   with native extension wheels published on PyPI.
///
/// Mirrors the C surface declared in
/// [dart-bridge/src/dart_bridge.c](https://github.com/flet-dev/dart-bridge/blob/main/src/dart_bridge.c)
/// and [dart-bridge/src/serious_python_run.c](https://github.com/flet-dev/dart-bridge/blob/main/src/serious_python_run.c).

// ---------------------------------------------------------------------------
// C struct layout for serious_python_run
// ---------------------------------------------------------------------------

final class SpRunConfig extends Struct {
  @Int32()
  external int mode; // SP_RUN_PATH=0, SP_RUN_SCRIPT=1

  external Pointer<Utf8> appPath;
  external Pointer<Utf8> scriptSource;
  external Pointer<Utf8> programName;
  external Pointer<Pointer<Utf8>> modulePaths; // NULL-terminated
  external Pointer<Pointer<Utf8>> envKeys; // NULL-terminated
  external Pointer<Pointer<Utf8>> envValues; // parallel to envKeys

  @Int32()
  external int sync;

  @Int64()
  external int completionPort;
}

const int spRunPath = 0;
const int spRunScript = 1;

// ---------------------------------------------------------------------------
// Native + Dart function signatures
// ---------------------------------------------------------------------------

typedef _SeriousPythonRunNative = Int32 Function(Pointer<SpRunConfig>);
typedef _SeriousPythonRunDart = int Function(Pointer<SpRunConfig>);

typedef _DartBridgeInitDartApiDLNative = IntPtr Function(Pointer<Void>);
typedef _DartBridgeInitDartApiDLDart = int Function(Pointer<Void>);

typedef _DartBridgeEnqueueMessageNative = Int32 Function(
    Int64, Pointer<Uint8>, IntPtr);
typedef _DartBridgeEnqueueMessageDart = int Function(int, Pointer<Uint8>, int);

typedef _DartBridgeIsPythonInitializedNative = Int32 Function();
typedef _DartBridgeIsPythonInitializedDart = int Function();

typedef _DartBridgeSignalDartSessionNative = Void Function(
    Int32, Pointer<Pointer<Utf8>>, Pointer<Int64>);
typedef _DartBridgeSignalDartSessionDart = void Function(
    int, Pointer<Pointer<Utf8>>, Pointer<Int64>);

// ---------------------------------------------------------------------------
// Library binding
// ---------------------------------------------------------------------------

/// Loaded dart_bridge symbols. Use [DartBridge.instance] for the default
/// per-platform handle, or [DartBridge.open] / [DartBridge.process] to load
/// from a specific source (mostly useful for tests).
class DartBridge {
  DartBridge._(this._lib) {
    _run = _lib
        .lookup<NativeFunction<_SeriousPythonRunNative>>('serious_python_run')
        .asFunction<_SeriousPythonRunDart>();
    _initApiDL = _lib
        .lookup<NativeFunction<_DartBridgeInitDartApiDLNative>>(
            'DartBridge_InitDartApiDL')
        .asFunction<_DartBridgeInitDartApiDLDart>();
    _enqueueMessage = _lib
        .lookup<NativeFunction<_DartBridgeEnqueueMessageNative>>(
            'DartBridge_EnqueueMessage')
        .asFunction<_DartBridgeEnqueueMessageDart>();
    // dart_bridge >= 1.3.0 exports. Use lookupOrNull so older binaries
    // still load (calls into the wrappers below become safe no-ops);
    // makes the Dart/Python rollout decoupled from the libdart_bridge
    // release cadence.
    _isPythonInitialized = _lookupOrNull<_DartBridgeIsPythonInitializedNative,
        _DartBridgeIsPythonInitializedDart>(
      'dart_bridge_is_python_initialized',
      (f) => f.asFunction<_DartBridgeIsPythonInitializedDart>(),
    );
    _signalDartSession = _lookupOrNull<_DartBridgeSignalDartSessionNative,
        _DartBridgeSignalDartSessionDart>(
      'dart_bridge_signal_dart_session',
      (f) => f.asFunction<_DartBridgeSignalDartSessionDart>(),
    );
  }

  // Generic helper for soft symbol lookup — returns null if the binary
  // doesn't export the symbol (e.g. running against a pre-1.3.0
  // libdart_bridge).
  T? _lookupOrNull<N extends Function, T extends Function>(
      String name, T Function(Pointer<NativeFunction<N>>) bind) {
    try {
      final ptr = _lib.lookup<NativeFunction<N>>(name);
      return bind(ptr);
    } on ArgumentError {
      return null;
    }
  }

  final DynamicLibrary _lib;
  late final _SeriousPythonRunDart _run;
  late final _DartBridgeInitDartApiDLDart _initApiDL;
  late final _DartBridgeEnqueueMessageDart _enqueueMessage;
  late final _DartBridgeIsPythonInitializedDart? _isPythonInitialized;
  late final _DartBridgeSignalDartSessionDart? _signalDartSession;

  static DartBridge? _instance;

  /// Reserved entry included in every native session-restart signal.
  static const dartSessionTokenLabel = '__serious_python_dart_session__';

  static final int dartSessionToken = _createDartSessionToken();

  static int _createDartSessionToken() {
    final random = Random.secure();
    final high = random.nextInt(1 << 31);
    final low = random.nextInt(1 << 31);
    final token = (high << 31) | low;
    return token == 0 ? 1 : token;
  }

  /// Default per-platform loader. Cached after the first call.
  static DartBridge get instance => _instance ??= DartBridge._(_loadDefault());

  /// Test/override entry point: open a specific library path. Replaces the
  /// cached instance.
  static DartBridge open(String path) =>
      _instance = DartBridge._(DynamicLibrary.open(path));

  /// Test/override entry point: resolve from the host process (Apple).
  /// Replaces the cached instance.
  static DartBridge process() =>
      _instance = DartBridge._(DynamicLibrary.process());

  static DynamicLibrary _loadDefault() {
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.process();
    }
    if (Platform.isAndroid || Platform.isLinux) {
      return DynamicLibrary.open('libdart_bridge.so');
    }
    if (Platform.isWindows) {
      return DynamicLibrary.open('dart_bridge.dll');
    }
    throw UnsupportedError(
        'serious_python: dart_bridge has no binary for this platform');
  }

  /// Initialize the Dart Native API DL hooks so the worker thread spawned by
  /// `serious_python_run` and `send_bytes` (Python→Dart) can post to ports.
  /// Idempotent — calling more than once is a cheap no-op past the first.
  bool _apiDLInitialized = false;
  void initDartApiDL() {
    if (_apiDLInitialized) return;
    final rc = _initApiDL(NativeApi.initializeApiDLData);
    if (rc != 0) {
      throw StateError('DartBridge_InitDartApiDL failed with code $rc');
    }
    _apiDLInitialized = true;
  }

  /// Run a Python program (`appPath` mode) or source string (`script` mode).
  /// See [SpRunConfig] / `serious_python_run`.
  int run(Pointer<SpRunConfig> cfg) => _run(cfg);

  /// Deliver bytes to the Python handler registered for [port]. Returns 0 on
  /// successful delivery, -1 if no handler is registered (caller may retry),
  /// or -2 if the interpreter is not initialized.
  int enqueueMessage(int port, Pointer<Uint8> data, int len) =>
      _enqueueMessage(port, data, len);

  /// True if libdart_bridge has already brought up an embedded CPython.
  /// On Android process reuse (OS keeps the process alive across a Dart
  /// VM restart), this returns true on the second Dart VM's PythonBridge
  /// construction.
  ///
  /// Returns false when running against a pre-1.3.0 libdart_bridge that
  /// doesn't export the underlying C function — callers should treat that
  /// as "fresh start path", which is the correct behaviour on every
  /// platform that hasn't seen this binary update yet.
  bool get isPythonInitialized {
    final f = _isPythonInitialized;
    if (f == null) return false;
    return f() != 0;
  }

  /// Signal the running Python program that a new Dart VM session is
  /// active. On a fresh start where Python isn't loaded yet, this is a
  /// cheap no-op inside libdart_bridge. On Android process reuse it fires
  /// every Python callback registered via
  /// `dart_bridge.add_session_restart_handler(...)`, carrying the new
  /// native port numbers as a `{label: port}` map.
  ///
  /// [portMap] keys are arbitrary labels — current callers use
  /// `"protocol"` and `"exit"` to match flet's build template wiring.
  ///
  /// No-op when running against a pre-1.3.0 libdart_bridge.
  void signalDartSession(Map<String, int> portMap) {
    final f = _signalDartSession;
    if (f == null || portMap.isEmpty) return;
    final sessionPorts = {
      ...portMap,
      dartSessionTokenLabel: dartSessionToken,
    };
    using((Arena arena) {
      final labels = arena<Pointer<Utf8>>(sessionPorts.length);
      final ports = arena<Int64>(sessionPorts.length);
      var i = 0;
      for (final entry in sessionPorts.entries) {
        labels[i] = entry.key.toNativeUtf8(allocator: arena);
        ports[i] = entry.value;
        i++;
      }
      f(sessionPorts.length, labels, ports);
    });
  }
}

// ---------------------------------------------------------------------------
// High-level helper: build SpRunConfig, run, free.
// ---------------------------------------------------------------------------

/// Allocates a NULL-terminated `char**` for a list of strings using [arena].
Pointer<Pointer<Utf8>>? _toCStringArray(Arena arena, List<String>? strings) {
  if (strings == null) return null;
  final ptr = arena<Pointer<Utf8>>(strings.length + 1);
  for (var i = 0; i < strings.length; i++) {
    ptr[i] = strings[i].toNativeUtf8(allocator: arena);
  }
  ptr[strings.length] = nullptr;
  return ptr;
}

/// Run a Python program via dart_bridge.
///
/// - `sync: false` (default): spawn a worker thread and return immediately
///   with 0 on successful spawn. The Python run continues in the background;
///   bridge traffic flows over Dart ↔ Python ports independently.
/// - `sync: true`: block the calling thread inside the Python interpreter
///   until the program finishes, then return its exit code.
///
/// If [completionPort] is provided, the exit code is also posted to that
/// Dart port via `Dart_PostInteger_DL` when Python finishes. Default `0`
/// disables the post.
int runPython({
  required DartBridge bridge,
  String? appPath,
  String? script,
  String? programName,
  List<String>? modulePaths,
  Map<String, String>? environmentVariables,
  bool sync = false,
  int completionPort = 0,
}) {
  if ((appPath == null) == (script == null)) {
    throw ArgumentError(
        'Provide exactly one of appPath / script (got both or neither)');
  }

  // Worker thread needs the Dart Native API DL hooks so it can post to a
  // completion port. Idempotent past the first call; cheap to do every time.
  bridge.initDartApiDL();

  return using((Arena arena) {
    final cfg = arena<SpRunConfig>();
    cfg.ref
      ..mode = script != null ? spRunScript : spRunPath
      ..appPath =
          appPath != null ? appPath.toNativeUtf8(allocator: arena) : nullptr
      ..scriptSource =
          script != null ? script.toNativeUtf8(allocator: arena) : nullptr
      ..programName = programName != null
          ? programName.toNativeUtf8(allocator: arena)
          : nullptr
      ..modulePaths = _toCStringArray(arena, modulePaths) ?? nullptr
      ..sync = sync ? 1 : 0
      ..completionPort = completionPort;

    if (environmentVariables != null && environmentVariables.isNotEmpty) {
      final keys = environmentVariables.keys.toList();
      final values = keys.map((k) => environmentVariables[k]!).toList();
      cfg.ref.envKeys = _toCStringArray(arena, keys)!;
      cfg.ref.envValues = _toCStringArray(arena, values)!;
    } else {
      cfg.ref.envKeys = nullptr;
      cfg.ref.envValues = nullptr;
    }

    return bridge.run(cfg);
  });
}

/// Runs targets in one process-wide Python interpreter.
///
/// dart_bridge 1.5 normally finalizes CPython after a short target and ignores
/// additional targets while a long target is active. Pyrite needs to run a
/// bootstrap script, a per-plugin environment script, and multiple plugin
/// entry points in the same interpreter. A small Python dispatcher is
/// therefore kept alive as the one native target; later calls are delivered
/// to it through dart_bridge and run in Python threads under the interpreter's
/// normal GIL.
Future<int> runPersistentPython({
  required DartBridge bridge,
  String? appPath,
  String? script,
  String? programName,
  List<String>? modulePaths,
  Map<String, String>? environmentVariables,
  bool sync = false,
}) {
  final normalizedScript = script != null && script.isEmpty ? null : script;
  if ((appPath == null) == (normalizedScript == null)) {
    throw ArgumentError(
        'Provide exactly one of appPath / script (got both or neither)');
  }

  final runtime = _persistentRuntime ??= _PersistentPythonRuntime(bridge);
  if (!identical(runtime.bridge, bridge)) {
    throw StateError(
        'Persistent Python runtime is already using another bridge');
  }
  return runtime.run(
    appPath: appPath,
    script: normalizedScript,
    programName: programName,
    modulePaths: modulePaths,
    environmentVariables: environmentVariables,
    sync: sync,
  );
}

/// Runs a target and returns both its exit code and Python diagnostic output.
///
/// The detailed error is populated for synchronous targets that fail while
/// executing Python code. Asynchronous targets return immediately with a
/// successful spawn result and therefore have no completion diagnostic.
Future<PersistentPythonRunResult> runPersistentPythonDetailed({
  required DartBridge bridge,
  String? appPath,
  String? script,
  String? programName,
  List<String>? modulePaths,
  Map<String, String>? environmentVariables,
  bool sync = false,
}) {
  final normalizedScript = script != null && script.isEmpty ? null : script;
  if ((appPath == null) == (normalizedScript == null)) {
    throw ArgumentError(
        'Provide exactly one of appPath / script (got both or neither)');
  }

  final runtime = _persistentRuntime ??= _PersistentPythonRuntime(bridge);
  if (!identical(runtime.bridge, bridge)) {
    throw StateError(
        'Persistent Python runtime is already using another bridge');
  }
  return runtime.runDetailed(
    appPath: appPath,
    script: normalizedScript,
    programName: programName,
    modulePaths: modulePaths,
    environmentVariables: environmentVariables,
    sync: sync,
  );
}

/// The result of a persistent Python target.
final class PersistentPythonRunResult {
  const PersistentPythonRunResult(this.exitCode, {this.error});

  final int exitCode;
  final String? error;
}

/// Restores the shared interpreter to the snapshot captured by the runtime
/// bootstrap without finalizing CPython.
Future<int> resetPersistentPython({required DartBridge bridge}) {
  final runtime = _persistentRuntime;
  if (runtime == null) return Future<int>.value(0);
  if (!identical(runtime.bridge, bridge)) {
    throw StateError('Persistent Python runtime is using another bridge');
  }
  return runtime.reset();
}

_PersistentPythonRuntime? _persistentRuntime;

int _runtimeEpochCounter = 0;

String _newRuntimeEpoch(int port) {
  final counter = _runtimeEpochCounter++;
  return '${DateTime.now().microsecondsSinceEpoch}-$port-$counter';
}

/// Keep the native interpreter bootstrap independent from the first target.
///
/// The Darwin/Linux/Windows adapters put the target's directories in
/// `PYTHONPATH` so CPython can start from the bundled runtime.  CPython reads
/// that variable while it builds its initial `sys.path`; passing the complete
/// value to the persistent dispatcher would therefore make the first plugin
/// path part of the process-wide baseline.  Only paths below `PYTHONHOME` are
/// runtime-owned and may be captured by that baseline.
Map<String, String>? _persistentBootstrapEnvironment(
  Map<String, String>? environmentVariables,
  List<String>? modulePaths,
) {
  final environment = <String, String>{
    ...?environmentVariables,
  };
  final pythonHome = _normalizedRuntimePath(environment['PYTHONHOME']);
  if (pythonHome.isEmpty) {
    return environment.isEmpty ? null : environment;
  }

  final separator = Platform.isWindows ? ';' : ':';
  final candidates = <String>[];
  final configuredPath = environment['PYTHONPATH'];
  if (configuredPath != null) {
    candidates.addAll(configuredPath.split(separator));
  }
  candidates.addAll(modulePaths ?? const <String>[]);

  final runtimePaths = <String>[];
  for (final candidate in candidates) {
    final normalized = _normalizedRuntimePath(candidate);
    if (normalized.isEmpty ||
        (normalized != pythonHome && !normalized.startsWith('$pythonHome/'))) {
      continue;
    }
    if (!runtimePaths.contains(candidate)) {
      runtimePaths.add(candidate);
    }
  }

  // Keep the original value if it cannot be classified.  This preserves
  // startup compatibility for custom embedders whose PYTHONHOME is not a
  // filesystem root, while the bundled runtime takes the isolated path.
  if (runtimePaths.isNotEmpty) {
    environment['PYTHONPATH'] = runtimePaths.join(separator);
  }
  return environment.isEmpty ? null : environment;
}

String _normalizedRuntimePath(String? value) {
  if (value == null) return '';
  var normalized = value.trim().replaceAll('\\', '/');
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

class _PersistentPythonRuntime {
  _PersistentPythonRuntime(this.bridge, {String? runtimeEpoch}) {
    _completionRegistry = PersistentRuntimeCompletionRegistry(
      runtimeEpoch ?? _newRuntimeEpoch(_port),
    );
    bridge.initDartApiDL();
    _receivePort.listen(_onMessage);
  }

  static const _sessionLabel = 'serious_python_runtime';

  final DartBridge bridge;
  final ReceivePort _receivePort = ReceivePort();
  late final PersistentRuntimeCompletionRegistry _completionRegistry;
  Future<void>? _startFuture;
  int _nextCommandId = 1;

  int get _port => _receivePort.sendPort.nativePort;
  String get _runtimeEpoch => _completionRegistry.epoch;

  Future<int> run({
    String? appPath,
    String? script,
    String? programName,
    List<String>? modulePaths,
    Map<String, String>? environmentVariables,
    required bool sync,
  }) async {
    final result = await runDetailed(
      appPath: appPath,
      script: script,
      programName: programName,
      modulePaths: modulePaths,
      environmentVariables: environmentVariables,
      sync: sync,
    );
    return result.exitCode;
  }

  Future<PersistentPythonRunResult> runDetailed({
    String? appPath,
    String? script,
    String? programName,
    List<String>? modulePaths,
    Map<String, String>? environmentVariables,
    required bool sync,
  }) async {
    await _ensureStarted(
      modulePaths: modulePaths,
      environmentVariables: environmentVariables,
    );

    final id = _nextCommandId++;
    Completer<int>? completer;
    if (sync) {
      completer = Completer<int>();
      _completionRegistry.register(id, completer);
    }

    final command = <String, Object?>{
      'op': 'run',
      'id': id,
      'appPath': appPath,
      'script': script,
      'programName': programName,
      'modulePaths': modulePaths ?? const <String>[],
      'environmentVariables': environmentVariables ?? const <String, String>{},
      'reply': sync,
    };

    final rc = await _deliver(command);
    if (rc != 0) {
      _completionRegistry.remove(id);
      return PersistentPythonRunResult(rc);
    }
    if (completer == null) {
      return const PersistentPythonRunResult(0);
    }
    final result = await completer.future;
    return PersistentPythonRunResult(
      result,
      error: _completionRegistry.takeError(id),
    );
  }

  Future<int> reset() async {
    await _ensureStarted();

    final id = _nextCommandId++;
    final completer = Completer<int>();
    _completionRegistry.register(id, completer);
    final rc = await _deliver({
      'op': 'reset',
      'id': id,
      'reply': true,
    });
    if (rc != 0) {
      _completionRegistry.remove(id);
      return rc;
    }
    return completer.future;
  }

  Future<void> _ensureStarted({
    List<String>? modulePaths,
    Map<String, String>? environmentVariables,
  }) {
    final existing = _startFuture;
    if (existing != null) {
      return existing;
    }

    late final Future<void> startFuture;
    startFuture = _start(
      modulePaths: modulePaths,
      environmentVariables: environmentVariables,
    ).onError((Object error, StackTrace stackTrace) {
      if (identical(_startFuture, startFuture)) {
        _startFuture = null;
      }
      Error.throwWithStackTrace(error, stackTrace);
    });
    _startFuture = startFuture;
    return startFuture;
  }

  Future<void> _start({
    List<String>? modulePaths,
    Map<String, String>? environmentVariables,
  }) async {
    if (bridge.isPythonInitialized) {
      bridge.signalDartSession({_sessionLabel: _port});
    } else {
      final bootstrap =
          _persistentRuntimeBootstrap.replaceAll('__CONTROL_PORT__', '$_port');
      // CPython needs the platform-provided PYTHONHOME/PYTHONPATH during
      // initialization so it can import the stdlib `encodings` package.
      // These values are only used for this native startup call; subsequent
      // plugin targets receive their own thread-local context below.
      final rc = runPython(
        bridge: bridge,
        script: bootstrap,
        // The startup environment already carries the bundled stdlib through
        // PYTHONPATH. Do not stamp the first target's app paths into the
        // interpreter snapshot; they belong only to that target.
        modulePaths: const <String>[],
        environmentVariables: _persistentBootstrapEnvironment(
          environmentVariables,
          modulePaths,
        ),
      );
      if (rc != 0) {
        throw StateError(
            'Could not start persistent Python dispatcher (code $rc)');
      }
    }

    final bindResult = await _deliverAndWait(
      const {'op': 'bind'},
      attempts: 400,
    );
    if (bindResult != 0) {
      throw StateError(
        'Persistent Python dispatcher did not bind the Dart runtime epoch '
        '(code $bindResult)',
      );
    }

    final rc = await _deliver(const {'op': 'ping'}, attempts: 400);
    if (rc != 0) {
      throw StateError(
          'Persistent Python dispatcher did not become ready (code $rc)');
    }
  }

  Future<int> _deliverAndWait(
    Map<String, Object?> message, {
    int attempts = 40,
  }) async {
    final id = _nextCommandId++;
    final completer = Completer<int>();
    _completionRegistry.register(id, completer);
    final rc = await _deliver({
      ...message,
      'id': id,
      'reply': true,
    }, attempts: attempts);
    if (rc != 0) {
      _completionRegistry.remove(id);
      return rc;
    }

    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } on TimeoutException {
      _completionRegistry.remove(id);
      return -1;
    }
  }

  Future<int> _deliver(Map<String, Object?> message,
      {int attempts = 40}) async {
    final bytes = utf8.encode(jsonEncode({
      ...message,
      'runtimeEpoch': _runtimeEpoch,
      'runtimePort': _port,
    }));
    for (var attempt = 0; attempt < attempts; attempt++) {
      final rc = _enqueue(bytes);
      if (rc == 0) {
        return 0;
      }
      if (rc != -1 && rc != -2) {
        return rc;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return -1;
  }

  int _enqueue(List<int> bytes) {
    final buffer = malloc<Uint8>(bytes.isEmpty ? 1 : bytes.length);
    try {
      if (bytes.isNotEmpty) {
        buffer.asTypedList(bytes.length).setAll(0, bytes);
      }
      return bridge.enqueueMessage(_port, buffer, bytes.length);
    } finally {
      malloc.free(buffer);
    }
  }

  void _onMessage(dynamic message) {
    final Uint8List? bytes = switch (message) {
      Uint8List value => value,
      List<int> value => Uint8List.fromList(value),
      _ => null,
    };
    if (bytes == null) return;

    try {
      final response = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      _completionRegistry.complete(response);
    } catch (_) {
      // The runtime channel only accepts JSON completion messages.
    }
  }
}

const _persistentRuntimeBootstrap = r'''
import builtins
import importlib
import importlib.machinery
import importlib.metadata
import json
import os
import re
import runpy
import subprocess as _runtime_subprocess
import sys
import threading
import traceback

import dart_bridge


_control_port = __CONTROL_PORT__
_stop_event = threading.Event()
_runtime_original_environment = dict(os.environ)
_dispatch_condition = threading.Condition()
_runtime_epoch = None
_epoch_bind_pending = True
_active_target_count = 0
_command_queue = []
_dispatch_worker_running = False
_runtime_base_sys_path = tuple(sys.path)
_runtime_base_modules = dict(sys.modules)
_runtime_base_module_names = frozenset(_runtime_base_modules)
_runtime_base_path_names = frozenset(
    os.path.abspath(value).rstrip(os.sep)
    for value in _runtime_base_sys_path
    if value and value != "."
)
_runtime_import_lock = threading.RLock()
_runtime_thread_context = threading.local()
_runtime_contexts = set()
_runtime_shared_modules = {}
_runtime_stdlib_modules = {}
_runtime_shared_package_names = set()
_runtime_extension_suffixes = tuple(importlib.machinery.EXTENSION_SUFFIXES)
_runtime_original_import = builtins.__import__
_runtime_original_import_module = importlib.import_module
_runtime_original_environ = os.environ
_runtime_original_environb = getattr(os, "environb", None)
_runtime_original_putenv = os.putenv
_runtime_original_unsetenv = os.unsetenv
_runtime_original_system = os.system
_runtime_original_popen_init = _runtime_subprocess.Popen.__init__
_runtime_original_thread_start = threading.Thread.start
_runtime_original_bootstrap_inner = threading.Thread._bootstrap_inner
_runtime_threading_patched = False
_runtime_native_environment_lock = threading.RLock()


def _current_context():
    return getattr(_runtime_thread_context, "context", None)


class _RuntimePath(list):
    """A list-shaped sys.path with a per-thread target view."""

    def __init__(self, initial):
        super().__init__(initial)
        self._base = list(initial)

    def _target(self):
        context = _current_context()
        return context.sys_path if context is not None else self._base

    def __len__(self):
        return len(self._target())

    def __iter__(self):
        return iter(self._target())

    def __getitem__(self, index):
        return self._target()[index]

    def __setitem__(self, index, value):
        self._target()[index] = value

    def __delitem__(self, index):
        del self._target()[index]

    def __contains__(self, value):
        return value in self._target()

    def __repr__(self):
        return repr(self._target())

    def __eq__(self, other):
        return self._target() == other

    def __add__(self, other):
        return self._target() + other

    def __radd__(self, other):
        return other + self._target()

    def copy(self):
        return self._target().copy()

    def count(self, value):
        return self._target().count(value)

    def index(self, value, *args):
        return self._target().index(value, *args)

    def insert(self, index, value):
        self._target().insert(index, value)

    def append(self, value):
        self._target().append(value)

    def extend(self, values):
        self._target().extend(values)

    def clear(self):
        self._target().clear()

    def pop(self, index=-1):
        return self._target().pop(index)

    def remove(self, value):
        self._target().remove(value)

    def reverse(self):
        self._target().reverse()

    def sort(self, *args, **kwargs):
        self._target().sort(*args, **kwargs)

    def __iadd__(self, values):
        self._target().extend(values)
        return self

    def __imul__(self, value):
        target = self._target()
        target *= value
        return self


def _patch_runtime_threading():
    global _runtime_threading_patched
    if _runtime_threading_patched:
        return
    _runtime_threading_patched = True

    def start(thread, *args, **kwargs):
        # The context is intentionally attached to the Thread object rather
        # than copied into a global. This keeps each plugin's child threads
        # bound to its own environment and import cache.
        thread._pyrite_runtime_context = _current_context()
        try:
            return _runtime_original_thread_start(thread, *args, **kwargs)
        except BaseException:
            thread._pyrite_runtime_context = None
            raise

    def bootstrap_inner(thread, *args, **kwargs):
        context = getattr(thread, "_pyrite_runtime_context", None)
        previous = _current_context()
        if context is not None:
            _runtime_thread_context.context = context
            _runtime_contexts.add(context)
        try:
            return _runtime_original_bootstrap_inner(thread, *args, **kwargs)
        finally:
            thread._pyrite_runtime_context = None
            if context is not None:
                _runtime_contexts.discard(context)
            if previous is None:
                try:
                    del _runtime_thread_context.context
                except AttributeError:
                    pass
            else:
                _runtime_thread_context.context = previous

    threading.Thread.start = start
    threading.Thread._bootstrap_inner = bootstrap_inner


_patch_runtime_threading()
sys.path = _RuntimePath(_runtime_base_sys_path)


def _is_native_extension(module):
    origin = getattr(module, "__file__", None)
    if not origin:
        spec = getattr(module, "__spec__", None)
        origin = getattr(spec, "origin", None) if spec is not None else None
    return bool(
        origin
        and any(str(origin).endswith(suffix) for suffix in _runtime_extension_suffixes)
    )


def _module_origin(module):
    origin = getattr(module, "__file__", None)
    if not origin:
        spec = getattr(module, "__spec__", None)
        origin = getattr(spec, "origin", None) if spec is not None else None
    if origin:
        return str(origin)
    return None


def _is_runtime_module(module):
    origin = _module_origin(module)
    if not origin or origin in ("built-in", "frozen"):
        return True
    normalized = os.path.abspath(origin).rstrip(os.sep)
    return any(
        normalized == root or normalized.startswith(root + os.sep)
        for root in _runtime_base_path_names
        if root
    )


def _is_shared_module_name(module_name):
    return any(
        module_name == package_name
        or module_name.startswith(package_name + ".")
        for package_name in _runtime_shared_package_names
    )


def _is_process_shared_module_name(module_name):
    return module_name in _runtime_stdlib_modules or _is_shared_module_name(
        module_name
    )


def _normalized_distribution_name(name):
    return re.sub(r"[-_.]+", "-", str(name)).lower()


def _native_wrapper_package_names(context, native_package_names):
    try:
        package_distributions = importlib.metadata.packages_distributions()
    except Exception:
        return set()

    native_distribution_names = {
        _normalized_distribution_name(distribution_name)
        for package_name in native_package_names
        for distribution_name in package_distributions.get(package_name, ())
    }
    if not native_distribution_names:
        return set()

    loaded_package_names = {
        module_name.partition(".")[0]
        for module_name, module in tuple(sys.modules.items())
        if context._owns_module(module)
    }
    wrappers = set()
    for package_name in loaded_package_names:
        for distribution_name in package_distributions.get(package_name, ()):
            try:
                requirements = (
                    importlib.metadata.distribution(distribution_name).requires
                    or ()
                )
            except Exception:
                continue
            for requirement in requirements:
                match = re.match(r"[A-Za-z0-9][A-Za-z0-9._-]*", requirement)
                if match and _normalized_distribution_name(
                    match.group(0)
                ) in native_distribution_names:
                    wrappers.add(package_name)
                    break
    return wrappers


def _promote_native_packages(context):
    # Native extensions are process-level CPython state. Some extensions,
    # including PyO3 modules, look their Python package up in sys.modules long
    # after import has returned. Their direct Python wrappers must share the
    # same type identities too, so keep both layers coherent instead of trying
    # to isolate or unload part of them per target.
    native_package_names = set()
    for module_name, module in tuple(sys.modules.items()):
        if context._owns_module(module) and _is_native_extension(module):
            native_package_names.add(module_name.partition(".")[0])

    if not native_package_names:
        return

    wrapper_package_names = _native_wrapper_package_names(
        context, native_package_names
    )
    _runtime_shared_package_names.update(native_package_names)
    _runtime_shared_package_names.update(wrapper_package_names)

    for module_name, module in tuple(sys.modules.items()):
        if _is_shared_module_name(module_name):
            _runtime_shared_modules[module_name] = module

    # A package may have been captured by a context before its native child
    # was imported. Once promoted, the process-wide instance is authoritative.
    for context in tuple(_runtime_contexts):
        for module_name in tuple(context.modules):
            if _is_shared_module_name(module_name):
                context.modules.pop(module_name, None)


class _RuntimeEnvironment:
    """A thread-aware view of os.environ for plugin targets."""

    def __init__(self, fallback):
        self._fallback = fallback

    def _mapping(self):
        context = _current_context()
        return context.environment if context is not None else self._fallback

    def __getitem__(self, key):
        return self._mapping()[key]

    def __setitem__(self, key, value):
        self._mapping()[str(key)] = str(value)

    def __delitem__(self, key):
        del self._mapping()[key]

    def __iter__(self):
        return iter(self._mapping())

    def __len__(self):
        return len(self._mapping())

    def __contains__(self, key):
        return key in self._mapping()

    def get(self, key, default=None):
        return self._mapping().get(key, default)

    def setdefault(self, key, default=None):
        return self._mapping().setdefault(key, default)

    def pop(self, key, *args):
        return self._mapping().pop(key, *args)

    def popitem(self):
        return self._mapping().popitem()

    def clear(self):
        self._mapping().clear()

    def update(self, *args, **kwargs):
        self._mapping().update(*args, **kwargs)

    def copy(self):
        return self._mapping().copy()

    def keys(self):
        return self._mapping().keys()

    def items(self):
        return self._mapping().items()

    def values(self):
        return self._mapping().values()

    def __repr__(self):
        return repr(self._mapping())

    def __getattr__(self, name):
        # Keep compatibility with os._Environ helpers used by subprocess and
        # a few stdlib modules (for example encodekey/encodevalue).
        helpers = {
            "encodekey": lambda value: os.fsencode(str(value)),
            "decodekey": lambda value: os.fsdecode(value),
            "encodevalue": lambda value: os.fsencode(str(value)),
            "decodevalue": lambda value: os.fsdecode(value),
        }
        helper = helpers.get(name)
        if helper is not None:
            return helper
        return getattr(self._mapping(), name)


class _RuntimeEnvironmentBytes:
    """Bytes-keyed companion view for os.environb."""

    def __init__(self, text_environment):
        self._text_environment = text_environment

    @staticmethod
    def _text_key(key):
        return os.fsdecode(key) if isinstance(key, bytes) else str(key)

    @staticmethod
    def _text_value(value):
        return os.fsdecode(value) if isinstance(value, bytes) else str(value)

    @staticmethod
    def _bytes_key(key):
        return os.fsencode(key)

    @staticmethod
    def _bytes_value(value):
        return os.fsencode(value)

    def __getitem__(self, key):
        return self._bytes_value(
            self._text_environment[self._text_key(key)]
        )

    def __setitem__(self, key, value):
        self._text_environment[self._text_key(key)] = self._text_value(value)

    def __delitem__(self, key):
        del self._text_environment[self._text_key(key)]

    def __iter__(self):
        return (self._bytes_key(key) for key in self._text_environment)

    def __len__(self):
        return len(self._text_environment)

    def __contains__(self, key):
        return self._text_key(key) in self._text_environment

    def get(self, key, default=None):
        value = self._text_environment.get(self._text_key(key), None)
        if value is None:
            return default
        return self._bytes_value(value)

    def setdefault(self, key, default=None):
        value = self._text_environment.setdefault(
            self._text_key(key), self._text_value(default) if default is not None else ""
        )
        return self._bytes_value(value)

    def pop(self, key, *args):
        value = self._text_environment.pop(self._text_key(key), *args)
        if isinstance(value, str):
            return self._bytes_value(value)
        return value

    def popitem(self):
        key, value = self._text_environment.popitem()
        return self._bytes_key(key), self._bytes_value(value)

    def clear(self):
        self._text_environment.clear()

    def update(self, *args, **kwargs):
        values = dict(*args, **kwargs)
        for key, value in values.items():
            self[self._text_key(key)] = value

    def copy(self):
        return {
            self._bytes_key(key): self._bytes_value(value)
            for key, value in self._text_environment.items()
        }

    def keys(self):
        return tuple(self)

    def items(self):
        return tuple((key, self[key]) for key in self)

    def values(self):
        return tuple(self[key] for key in self)

    def __repr__(self):
        return repr(self.copy())

    def encodekey(self, value):
        return self._bytes_key(value)

    def decodekey(self, value):
        return os.fsdecode(value)

    def encodevalue(self, value):
        return self._bytes_value(value)

    def decodevalue(self, value):
        return os.fsdecode(value)


def _as_environment_text(value):
    if isinstance(value, bytes):
        return os.fsdecode(value)
    return str(value)


def _runtime_putenv(key, value):
    context = _current_context()
    if context is None:
        return _runtime_original_putenv(key, value)
    context.environment[_as_environment_text(key)] = _as_environment_text(value)


def _runtime_unsetenv(key):
    context = _current_context()
    if context is None:
        return _runtime_original_unsetenv(key)
    context.environment.pop(_as_environment_text(key), None)


def _with_native_environment(callback, *args, **kwargs):
    """Run a native environment consumer with the current target's env."""
    context = _current_context()
    if context is None:
        return callback(*args, **kwargs)
    with _runtime_native_environment_lock:
        previous = dict(_runtime_original_environ)
        _restore_process_environment(context.environment)
        try:
            return callback(*args, **kwargs)
        finally:
            _restore_process_environment(previous)


def _runtime_popen_init(self, *args, **kwargs):
    # Popen(env=None) inherits the C-level environ, bypassing our Python proxy.
    # Materialize the current target environment so child processes cannot see
    # another plugin's PATH or package configuration.
    context = _current_context()
    if context is not None:
        if "env" in kwargs:
            if kwargs["env"] is None:
                kwargs["env"] = dict(context.environment)
        elif len(args) <= 10:
            kwargs["env"] = dict(context.environment)
        elif args[10] is None:
            args = list(args)
            args[10] = dict(context.environment)
            args = tuple(args)
    return _runtime_original_popen_init(self, *args, **kwargs)


def _restore_process_environment(values):
    for key in tuple(_runtime_original_environ):
        if key not in values:
            _runtime_original_environ.pop(key, None)
    for key, value in values.items():
        if _runtime_original_environ.get(key) != value:
            _runtime_original_environ[key] = value


os.environ = _RuntimeEnvironment(_runtime_original_environ)
if _runtime_original_environb is not None:
    os.environb = _RuntimeEnvironmentBytes(os.environ)
os.putenv = _runtime_putenv
os.unsetenv = _runtime_unsetenv
os.system = lambda command: _with_native_environment(
    _runtime_original_system, command
)
_runtime_subprocess.Popen.__init__ = _runtime_popen_init


def _wrap_inheriting_spawn(name):
    original = getattr(os, name, None)
    if original is None:
        return
    globals()["_runtime_original_" + name] = original
    setattr(
        os,
        name,
        lambda *args, _original=original, **kwargs: _with_native_environment(
            _original, *args, **kwargs
        ),
    )


for _spawn_name in ("spawnv", "spawnvp", "spawnl", "spawnlp"):
    _wrap_inheriting_spawn(_spawn_name)


class _RuntimeContext:
    """Serialized import/environment context for one plugin target."""

    def __init__(self, command):
        self.environment = dict(_runtime_original_environment)
        for key, value in (command.get("environmentVariables") or {}).items():
            self.environment[str(key)] = str(value)

        paths = []
        for value in command.get("modulePaths") or []:
            normalized = os.path.abspath(str(value)).rstrip(os.sep)
            if normalized and normalized not in paths:
                paths.append(normalized)
        self.sys_path = list(paths) + [
            value
            for value in _runtime_base_sys_path
            if value not in paths
        ]
        self.module_roots = tuple(
            value for value in paths if value not in _runtime_base_path_names
        )
        app_path = command.get("appPath")
        if app_path:
            app_root = os.path.abspath(os.path.dirname(str(app_path))).rstrip(
                os.sep
            )
            if app_root and app_root not in _runtime_base_path_names:
                if app_root not in self.module_roots:
                    self.module_roots = (app_root,) + self.module_roots
        self.modules = {}
        self._import_depth = 0

    def _owns_module(self, module):
        candidates = []
        origin = getattr(module, "__file__", None)
        if origin:
            candidates.append(origin)
        spec = getattr(module, "__spec__", None)
        if spec is not None and getattr(spec, "origin", None):
            candidates.append(spec.origin)
        package_path = getattr(module, "__path__", None)
        if package_path:
            candidates.extend(package_path)
        for candidate in candidates:
            if not candidate or candidate in ("built-in", "frozen"):
                continue
            normalized = os.path.abspath(str(candidate)).rstrip(os.sep)
            for root in self.module_roots:
                if normalized == root or normalized.startswith(root + os.sep):
                    return True
        return False

    def run(self, callback):
        previous = _current_context()
        _runtime_thread_context.context = self
        _runtime_contexts.add(self)
        try:
            return callback()
        finally:
            _runtime_contexts.discard(self)
            if previous is None:
                try:
                    del _runtime_thread_context.context
                except AttributeError:
                    pass
            else:
                _runtime_thread_context.context = previous

    def _with_import(self, callback):
        if self._import_depth:
            return callback()
        with _runtime_import_lock:
            self._import_depth += 1
            previous_path = list(sys.path)
            previous_modules = dict(sys.modules)
            try:
                # Remove modules owned by another target, then restore this
                # target's private module cache while the import is resolved.
                for other in tuple(_runtime_contexts):
                    if other is self:
                        continue
                    for module_name in tuple(other.modules):
                        if not _is_shared_module_name(module_name):
                            sys.modules.pop(module_name, None)
                sys.modules.update(self.modules)
                sys.modules.update(_runtime_shared_modules)
                sys.path[:] = self.sys_path
                result = callback()
                _promote_native_packages(self)
                self.modules = {
                    module_name: module
                    for module_name, module in sys.modules.items()
                    if self._owns_module(module)
                    and not _is_shared_module_name(module_name)
                }
                return result
            finally:
                # Restore the process-wide table exactly as it was before the
                # import. Plugin code keeps direct references to its modules.
                for module_name in tuple(sys.modules):
                    if module_name not in previous_modules:
                        sys.modules.pop(module_name, None)
                for module_name, module in previous_modules.items():
                    sys.modules[module_name] = module
                sys.modules.update(_runtime_shared_modules)
                sys.path[:] = previous_path
                self._import_depth -= 1

    def import_module(self, name, globals, locals, fromlist, level):
        return self._with_import(
            lambda: _runtime_original_import(
                name, globals, locals, fromlist, level
            )
        )

    def importlib_module(self, name, package=None):
        return self._with_import(
            lambda: _runtime_original_import_module(name, package)
        )


def _runtime_import(name, globals=None, locals=None, fromlist=(), level=0):
    context = _current_context()
    if context is None:
        return _runtime_original_import(name, globals, locals, fromlist, level)
    return context.import_module(name, globals, locals, fromlist, level)


def _runtime_import_module(name, package=None):
    context = _current_context()
    if context is None:
        return _runtime_original_import_module(name, package)
    return context.importlib_module(name, package)


builtins.__import__ = _runtime_import
importlib.import_module = _runtime_import_module


def _execute(command):
    script = command.get("script")
    if script is None or script == "":
        runpy.run_path(command["appPath"], run_name="__main__")
    else:
        filename = command.get("programName") or "<serious_python_script>"
        namespace = {
            "__name__": "__main__",
            "__file__": filename,
            "__package__": None,
            "__cached__": None,
        }
        exec(compile(script, filename, "exec"), namespace, namespace)
    return 0


def _send_result(command, result, error=None):
    if not command.get("reply"):
        return
    payload = json.dumps({
        "runtimeEpoch": command.get("runtimeEpoch"),
        "id": command.get("id"),
        "rc": result,
        "error": error,
    }).encode("utf-8")
    dart_bridge.send_bytes(_control_port, payload)


def _is_current_epoch(command):
    with _dispatch_condition:
        return command.get("runtimeEpoch") == _runtime_epoch


def _run_command(command):
    result = 0
    error = None
    context = None
    try:
        if not _is_current_epoch(command):
            result = 1
        else:
            context = _RuntimeContext(command)
            result = context.run(lambda: _execute(command))
    except SystemExit as system_exit:
        if system_exit.code is None:
            result = 0
        elif isinstance(system_exit.code, int):
            result = system_exit.code
        else:
            result = 1
            error = "SystemExit: %r" % (system_exit.code,)
    except BaseException:
        error = traceback.format_exc()
        traceback.print_exc()
        result = 1
    _send_result(command, result, error)


def _run_target(command):
    global _active_target_count
    try:
        _run_command(command)
    finally:
        with _dispatch_condition:
            _active_target_count -= 1
            if _active_target_count == 0:
                _dispatch_condition.notify_all()


def _start_target(command):
    global _active_target_count
    if not _is_current_epoch(command):
        with _dispatch_condition:
            _active_target_count -= 1
            if _active_target_count == 0:
                _dispatch_condition.notify_all()
        _send_result(command, 1)
        return
    try:
        thread = threading.Thread(
            target=_run_target,
            args=(command,),
            name="serious-python-target",
            daemon=True,
        )
        thread.start()
    except BaseException:
        with _dispatch_condition:
            _active_target_count -= 1
            if _active_target_count == 0:
                _dispatch_condition.notify_all()
        error = traceback.format_exc()
        traceback.print_exc()
        try:
            _send_result(command, 1, error)
        except BaseException:
            traceback.print_exc()


def _reset_command(command):
    result = 0
    try:
        if not _is_current_epoch(command):
            result = 1
        else:
            sys.path[:] = _runtime_base_sys_path
            for context in tuple(_runtime_contexts):
                for name in tuple(context.modules):
                    sys.modules.pop(name, None)
            for name in tuple(_runtime_shared_modules):
                sys.modules.pop(name, None)
            _runtime_shared_modules.clear()
            _runtime_shared_package_names.clear()
            sys.modules.update(_runtime_base_modules)
            _restore_process_environment(_runtime_original_environment)
            _runtime_contexts.clear()
    except BaseException:
        traceback.print_exc()
        result = 1
    _send_result(command, result)


def _dispatch_worker():
    global _active_target_count
    global _dispatch_worker_running
    while True:
        with _dispatch_condition:
            if not _command_queue:
                _dispatch_worker_running = False
                return
            command = _command_queue.pop(0)
            operation = command.get("op")
            if operation == "run":
                _active_target_count += 1
            elif operation == "reset":
                while _active_target_count > 0:
                    _dispatch_condition.wait()
            else:
                continue

        if operation == "run":
            try:
                _start_target(command)
            except BaseException:
                traceback.print_exc()
            continue

        try:
            _reset_command(command)
        except BaseException:
            # Keep the ordered dispatcher alive if native completion delivery
            # fails after the reset itself has already finished.
            traceback.print_exc()
            try:
                _send_result(command, 1)
            except BaseException:
                traceback.print_exc()


def _dispatch_command(command):
    global _dispatch_worker_running
    rejected = False
    start_worker = False
    with _dispatch_condition:
        if command.get("runtimeEpoch") != _runtime_epoch:
            rejected = True
        else:
            _command_queue.append(command)
            if not _dispatch_worker_running:
                _dispatch_worker_running = True
                start_worker = True
    if rejected:
        _send_result(command, 1)
        return
    if not start_worker:
        return
    try:
        thread = threading.Thread(
            target=_dispatch_worker,
            name="serious-python-dispatch",
            daemon=True,
        )
        thread.start()
    except BaseException:
        with _dispatch_condition:
            failed_commands = list(_command_queue)
            _command_queue.clear()
            _dispatch_worker_running = False
        traceback.print_exc()
        for failed_command in failed_commands:
            try:
                _send_result(failed_command, 1)
            except BaseException:
                traceback.print_exc()


def _handle(payload):
    global _runtime_epoch
    global _epoch_bind_pending
    command = json.loads(bytes(payload).decode("utf-8"))
    operation = command.get("op")
    if command.get("runtimePort") != _control_port:
        _send_result(command, 1)
        return
    if operation == "bind":
        epoch = command.get("runtimeEpoch")
        if not isinstance(epoch, str) or not epoch:
            _send_result(command, 1)
            return
        with _dispatch_condition:
            if not _epoch_bind_pending and epoch != _runtime_epoch:
                rejected = True
            else:
                rejected = False
                _runtime_epoch = epoch
                _epoch_bind_pending = False
                _command_queue.clear()
        if rejected:
            _send_result(command, 1)
            return
        _send_result(command, 0)
        return
    if command.get("runtimeEpoch") != _runtime_epoch:
        _send_result(command, 1)
        return
    if operation == "ping":
        return
    if operation == "shutdown":
        _stop_event.set()
        return
    if operation == "reset":
        _dispatch_command(command)
        return
    if operation != "run":
        return
    _dispatch_command(command)


def _restart_session(ports):
    global _control_port
    global _runtime_epoch
    global _epoch_bind_pending
    new_port = int(ports.get("serious_python_runtime", 0))
    if new_port <= 0:
        return
    with _dispatch_condition:
        _runtime_epoch = None
        _epoch_bind_pending = True
        _command_queue.clear()
    if new_port == _control_port:
        return
    dart_bridge.set_enqueue_handler_func(_control_port, None)
    _control_port = new_port
    dart_bridge.set_enqueue_handler_func(_control_port, _handle)


dart_bridge.set_enqueue_handler_func(_control_port, _handle)
dart_bridge.add_session_restart_handler(_restart_session)
_stop_event.wait()
''';
