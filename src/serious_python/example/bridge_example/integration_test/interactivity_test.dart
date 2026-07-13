import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:serious_python/serious_python.dart';

import '_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('counter responds to inc/dec via control channel',
      (tester) async {
    final handle = await bootAndAwaitReady(tester);
    expect(find.byKey(const Key('counter')), findsOneWidget);
    expect(find.text('0'), findsOneWidget);

    // Increment once: Python returns {event: count, value: 1}.
    await tester.tap(find.byKey(const Key('increment')));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    // Decrement twice: 1 -> 0 -> -1.
    await tester.tap(find.byKey(const Key('decrement')));
    await tester.tap(find.byKey(const Key('decrement')));
    await tester.pumpAndSettle();
    expect(find.text('-1'), findsOneWidget);

    // Optional version assertion: only when the test harness passes
    // EXPECTED_PYTHON_VERSION (CI does; local runs may not).
    const expected = String.fromEnvironment('EXPECTED_PYTHON_VERSION');
    if (expected.isNotEmpty) {
      expect(handle.pythonVersion.value, isNotNull);
      expect(handle.pythonVersion.value, startsWith('$expected.'));
      expect(
        find.text('Python version: ${handle.pythonVersion.value}'),
        findsOneWidget,
      );
    }

    // Pyrite runs boot/setup/plugin targets in one interpreter. Verify that a
    // second target executes while main.py is still alive, and that a later
    // target observes both interpreter state and newly supplied environment.
    expect(
      await SeriousPython.runProgram(
        'unused.py',
        script: 'import builtins; builtins._persistent_run_marker = 42',
        sync: true,
      ),
      isNull,
    );
    expect(
      await SeriousPython.runProgram(
        'unused.py',
        script: '''
import builtins
import os
assert builtins._persistent_run_marker == 42
assert os.environ["PERSISTENT_RUN_ENV"] == "updated"
''',
        environmentVariables: const {'PERSISTENT_RUN_ENV': 'updated'},
        sync: true,
      ),
      isNull,
    );
  });
}
