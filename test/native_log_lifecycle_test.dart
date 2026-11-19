import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/native_log_lifecycle.dart';

void main() {
  testWidgets('collects only while resumed and unregisters on disposal', (
    tester,
  ) async {
    final binding = tester.binding;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final active = <bool>[];
    final lifecycle = NativeLogLifecycle(active.add)..start();
    expect(active, [true]);
    lifecycle.start();
    expect(active, [true]);

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.detached,
    ]) {
      binding.handleAppLifecycleStateChanged(state);
      expect(active.last, isFalse, reason: '$state must stop collection');
    }
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(active.last, isTrue);
    lifecycle.dispose();
    expect(active.last, isFalse);
    final count = active.length;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(active, hasLength(count));
  });

  testWidgets('starting a background shell leaves collection stopped', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final active = <bool>[];
    final lifecycle = NativeLogLifecycle(active.add)..start();
    expect(active, [false]);
    lifecycle.dispose();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}
