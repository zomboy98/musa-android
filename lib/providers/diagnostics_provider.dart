import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/constants/legal_links.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/analytics/anonymous_metrics.dart';
import 'package:mornye/services/diagnostics/report_service.dart';

/// Whether anonymous counters may leave the phone.
///
/// Both conditions must hold: the person turned the counters on in Settings
/// (on by default) and accepted the terms and privacy policy. This is the one
/// place that joins the two; if the policy gate changes how acceptance is
/// stored, only this provider needs to follow it.
final analyticsAllowedProvider = Provider<bool>((ref) {
  final enabled = ref.watch(settingsProvider.select((s) => s.analyticsEnabled));
  final accepted = ref.watch(
    settingsProvider.select(
      (s) => s.acceptedLegalVersion >= legalPolicyVersion,
    ),
  );
  return enabled && accepted;
});

final anonymousMetricsProvider = Provider<AnonymousMetrics>(
  (ref) => AnonymousMetrics.instance,
);

final reportServiceProvider = Provider<ReportService>((ref) => ReportService());

class _ForegroundObserver with WidgetsBindingObserver {
  _ForegroundObserver(this.onChanged);

  final void Function(AppLifecycleState state) onChanged;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => onChanged(state);
}

/// Keeps the anonymous counters and the pending report queue running while
/// the app is in the foreground. Read it once from the app root.
final diagnosticsRuntimeProvider = Provider<AnonymousMetrics>((ref) {
  final metrics = ref.read(anonymousMetricsProvider);
  final reports = ref.read(reportServiceProvider);
  metrics.setAllowed(ref.read(analyticsAllowedProvider));
  ref.listen<bool>(analyticsAllowedProvider, (_, next) {
    metrics.setAllowed(next);
  });

  void apply(AppLifecycleState? state) {
    final foreground =
        state == null ||
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    metrics.setForeground(foreground);
    if (state == AppLifecycleState.resumed) {
      unawaited(reports.flushPending().then<void>((_) {}, onError: (_) {}));
    }
  }

  final observer = _ForegroundObserver(apply);
  WidgetsBinding.instance.addObserver(observer);
  ref.onDispose(() => WidgetsBinding.instance.removeObserver(observer));
  apply(WidgetsBinding.instance.lifecycleState);
  return metrics;
});
