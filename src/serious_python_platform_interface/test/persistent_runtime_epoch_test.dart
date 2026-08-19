import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:serious_python_platform_interface/src/persistent_runtime_completion_registry.dart';

void main() {
  group('PersistentRuntimeCompletionRegistry', () {
    test('old VM completion cannot resolve a reused command ID', () async {
      final oldSession = PersistentRuntimeCompletionRegistry('old-epoch');
      final newSession = PersistentRuntimeCompletionRegistry('new-epoch');
      final oldCompletion = Completer<int>();
      final newCompletion = Completer<int>();
      oldSession.register(1, oldCompletion);
      newSession.register(1, newCompletion);

      var newSessionCompleted = false;
      newCompletion.future.then((_) => newSessionCompleted = true);

      expect(
        newSession.complete({
          'runtimeEpoch': 'old-epoch',
          'id': 1,
          'rc': 41,
        }),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(newSessionCompleted, isFalse);

      expect(
        newSession.complete({
          'runtimeEpoch': 'new-epoch',
          'id': 1,
          'rc': 7,
        }),
        isTrue,
      );
      expect(await newCompletion.future, 7);

      expect(
        oldSession.complete({
          'runtimeEpoch': 'old-epoch',
          'id': 1,
          'rc': 41,
        }),
        isTrue,
      );
      expect(await oldCompletion.future, 41);
    });

    test('missing, malformed, and duplicate replies are ignored', () async {
      final registry = PersistentRuntimeCompletionRegistry('epoch');
      final completion = Completer<int>();
      registry.register(3, completion);

      expect(registry.complete({'id': 3, 'rc': 1}), isFalse);
      expect(
        registry.complete({
          'runtimeEpoch': 'epoch',
          'id': '3',
          'rc': 1,
        }),
        isFalse,
      );
      expect(
        registry.complete({
          'runtimeEpoch': 'epoch',
          'id': 3,
          'rc': 9,
        }),
        isTrue,
      );
      expect(await completion.future, 9);
      expect(
        registry.complete({
          'runtimeEpoch': 'epoch',
          'id': 3,
          'rc': 10,
        }),
        isFalse,
      );
    });

    test('completion diagnostics are retained until consumed', () async {
      final registry = PersistentRuntimeCompletionRegistry('epoch');
      final completion = Completer<int>();
      registry.register(4, completion);

      expect(
        registry.complete({
          'runtimeEpoch': 'epoch',
          'id': 4,
          'rc': 1,
          'error': 'Traceback (most recent call last):\nValueError: boom',
        }),
        isTrue,
      );
      expect(await completion.future, 1);
      expect(
        registry.takeError(4),
        'Traceback (most recent call last):\nValueError: boom',
      );
      expect(registry.takeError(4), isNull);
    });
  });
}
