import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// Diagnostic entrypoint: no application bootstrap, audio, extensions or files.
void main() {
  debugPrint('RUNNER_STARTUP: main entered');
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  debugPrint('RUNNER_STARTUP: binding initialized');

  testWidgets('Android integration runner renders a minimal frame', (
    tester,
  ) async {
    debugPrint('RUNNER_STARTUP: frame test started');
    expect(binding, isA<IntegrationTestWidgetsFlutterBinding>());
    await tester.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Text('Runner ready'),
      ),
    );
    expect(find.text('Runner ready'), findsOneWidget);
    debugPrint('RUNNER_STARTUP: frame test passed');
  });

  testWidgets('Android integration runner reaches the native backend', (
    tester,
  ) async {
    debugPrint('RUNNER_STARTUP: backend probe started');
    const channel = MethodChannel('com.zarz.mornye/backend');
    final implementations = await channel
        .invokeMapMethod<String, String>('getBackendImplementations')
        .timeout(const Duration(seconds: 10));
    expect(implementations, isNotNull);
    expect(implementations!['downloads'], 'rust');
    expect(implementations['extensions'], 'rust');
    debugPrint('RUNNER_STARTUP: backend probe passed');
  });
}
