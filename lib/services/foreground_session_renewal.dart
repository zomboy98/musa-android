import 'dart:async';
import 'package:mornye/services/platform_bridge.dart';

/// Contains only result categories and timestamps, never provider/session IDs.
class ForegroundSessionDiagnostic {
  const ForegroundSessionDiagnostic({
    this.checking = false,
    this.counts = const {},
    this.unknown = 0,
    this.earliestExpiry,
  });
  final bool checking;
  final Map<SessionRenewalStatus, int> counts;
  final int unknown;
  final DateTime? earliestExpiry;

  ForegroundSessionDiagnostic record(
    SessionRenewalResult? result,
    DateTime now,
  ) {
    if (result == null) {
      return ForegroundSessionDiagnostic(
        checking: checking,
        counts: counts,
        unknown: unknown + 1,
        earliestExpiry: earliestExpiry,
      );
    }
    DateTime? expiry;
    if (result.status == SessionRenewalStatus.validUntil ||
        result.status == SessionRenewalStatus.refreshed) {
      expiry = DateTime.tryParse(result.expiresAt ?? '');
      if (expiry == null || !expiry.isAfter(now)) {
        return ForegroundSessionDiagnostic(
          checking: checking,
          counts: counts,
          unknown: unknown + 1,
          earliestExpiry: earliestExpiry,
        );
      }
    }
    final next = Map<SessionRenewalStatus, int>.of(counts);
    next[result.status] = (next[result.status] ?? 0) + 1;
    return ForegroundSessionDiagnostic(
      checking: checking,
      counts: Map.unmodifiable(next),
      unknown: unknown,
      earliestExpiry:
          expiry != null &&
              (earliestExpiry == null || expiry.isBefore(earliestExpiry!))
          ? expiry
          : earliestExpiry,
    );
  }

  ForegroundSessionDiagnostic finished() => ForegroundSessionDiagnostic(
    counts: counts,
    unknown: unknown,
    earliestExpiry: earliestExpiry,
  );
}

/// Checks existing sessions only while the caller permits foreground work.
class ForegroundSessionRenewal {
  ForegroundSessionRenewal(
    this._renew, {
    DateTime Function()? now,
    this.onBegin,
    this.onResult,
    this.onEnd,
    this.onStop,
  }) : _now = now ?? DateTime.now;
  final Future<SessionRenewalResult?> Function(String) _renew;
  final DateTime Function() _now;
  final void Function()? onBegin;
  final void Function(SessionRenewalResult?)? onResult;
  final void Function()? onEnd;
  final void Function()? onStop;
  Future<void>? _inFlight;
  int? _inFlightGeneration;
  Timer? _timer;
  int _generation = 0;

  void stop() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    onStop?.call();
  }

  Future<void> run({
    required bool enabled,
    required Iterable<String> providerIds,
    bool Function(String)? canContinue,
  }) async {
    if (!enabled) {
      stop();
      return;
    }
    final ids = providerIds.toList(growable: false);
    final prior = _inFlight;
    if (prior != null) {
      final oldGeneration = _inFlightGeneration;
      await prior;
      if (oldGeneration != _generation) {
        await run(enabled: enabled, providerIds: ids, canContinue: canContinue);
      }
      return;
    }
    _timer?.cancel();
    _timer = null;
    final generation = _generation;
    onBegin?.call();
    final future = _run(ids, canContinue, generation);
    _inFlight = future;
    _inFlightGeneration = generation;
    try {
      await future;
    } finally {
      if (_generation == generation) onEnd?.call();
      if (identical(_inFlight, future)) {
        _inFlight = null;
        _inFlightGeneration = null;
      }
    }
  }

  Future<void> _run(
    List<String> ids,
    bool Function(String)? canContinue,
    int generation,
  ) async {
    DateTime? next;
    for (final id in ids) {
      if (_generation != generation) return;
      if (canContinue != null && !canContinue(id)) continue;
      try {
        final result = await _renew(id);
        if (_generation != generation) return;
        if (canContinue != null && !canContinue(id)) continue;
        onResult?.call(result);
        if (result?.status != SessionRenewalStatus.validUntil &&
            result?.status != SessionRenewalStatus.refreshed) {
          continue;
        }
        final expiry = DateTime.tryParse(result?.expiresAt ?? '');
        if (expiry == null) continue;
        final due = expiry.subtract(const Duration(minutes: 30));
        if (!due.isAfter(_now())) continue;
        if (next == null || due.isBefore(next)) next = due;
      } catch (_) {
        if (_generation == generation &&
            (canContinue == null || canContinue(id))) {
          onResult?.call(null);
        }
        /* Continue with other providers. */
      }
    }
    if (next != null && _generation == generation) {
      final delay = next.difference(_now());
      // The deadline was future when observed, but another provider may have
      // consumed the remaining time. Run once immediately in that case.
      _timer = Timer(delay > Duration.zero ? delay : Duration.zero, () {
        unawaited(
          run(enabled: true, providerIds: ids, canContinue: canContinue),
        );
      });
    }
  }
}
