import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/provider_cooldown.dart';

final providerCooldownServiceProvider = Provider<ProviderCooldown>(
  (ref) => ProviderCooldown.instance,
);

final providerCooldownSnapshotProvider =
    StreamProvider.autoDispose<Map<String, Duration>>((ref) {
      final cooldown = ref.watch(providerCooldownServiceProvider);
      final controller = StreamController<Map<String, Duration>>();
      Timer? timer;
      void emit() {
        if (!controller.isClosed) controller.add(cooldown.snapshot());
      }

      cooldown.load().then((_) {
        if (controller.isClosed) return;
        emit();
        timer = Timer.periodic(const Duration(seconds: 1), (_) => emit());
      });
      ref.onDispose(() {
        timer?.cancel();
        controller.close();
      });
      return controller.stream;
    });

class ProviderStatusView {
  const ProviderStatusView({
    this.until = const {},
    this.remaining = const {},
    this.failures = const {},
  });

  final Map<String, DateTime> until;
  final Map<String, Duration> remaining;
  final Map<String, ProviderFailure> failures;
}

final providerStatusProvider = StreamProvider.autoDispose<ProviderStatusView>((
  ref,
) {
  final cooldown = ref.watch(providerCooldownServiceProvider);
  final controller = StreamController<ProviderStatusView>();
  Timer? timer;
  void emit() {
    if (controller.isClosed) return;
    controller.add(
      ProviderStatusView(
        until: cooldown.untilSnapshot(),
        remaining: cooldown.snapshot(),
        failures: cooldown.failureSnapshot(),
      ),
    );
  }

  cooldown.load().then((_) {
    if (controller.isClosed) return;
    emit();
    timer = Timer.periodic(const Duration(seconds: 1), (_) => emit());
  });
  ref.onDispose(() {
    timer?.cancel();
    controller.close();
  });
  return controller.stream;
});
