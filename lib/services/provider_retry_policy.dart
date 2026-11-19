import 'dart:async';

import 'package:mornye/services/provider_cooldown.dart';

class ProviderRetryPolicy {
  ProviderRetryPolicy({
    DateTime Function()? clock,
    ProviderCooldown? cooldown,
    this.spacing = defaultSpacing,
    this.backoff = defaultBackoff,
    this.maxAttempts = defaultMaxAttempts,
    this.maxBackoff = const Duration(minutes: 10),
  }) : _clock = clock ?? DateTime.now,
       _cooldown = cooldown;

  static const defaultSpacing = Duration(milliseconds: 1500);
  static const defaultBackoff = [
    Duration(seconds: 30),
    Duration(seconds: 60),
    Duration(seconds: 120),
  ];
  static const defaultMaxAttempts = 4;

  static ProviderRetryPolicy instance = ProviderRetryPolicy();

  final DateTime Function() _clock;
  final ProviderCooldown? _cooldown;
  final Duration spacing;
  final List<Duration> backoff;
  final int maxAttempts;
  final Duration maxBackoff;

  final Map<String, DateTime> _nextSlot = {};
  final Map<String, DateTime> _retryAt = {};
  final Map<String, int> _failures = {};
  final Map<String, int> _attempts = {};

  ProviderCooldown get _cool => _cooldown ?? ProviderCooldown.instance;

  static String _provider(String provider) => provider.trim().toLowerCase();

  static String _pair(String provider, String trackKey) =>
      '${_provider(provider)}|$trackKey';

  static String _quality(String provider, String trackKey, String quality) =>
      '${_pair(provider, trackKey)}|${quality.trim().toLowerCase()}';

  Duration blockedFor(
    String provider,
    String trackKey, {
    bool manual = false,
    String? quality,
  }) {
    final id = _provider(provider);
    if (id.isEmpty) return Duration.zero;
    final cooling = _cool.remaining(id);
    var wait = cooling;
    if (manual) return wait;
    final key = _pair(id, trackKey);
    if ((_attempts[key] ?? 0) >= maxAttempts) {
      return maxBackoff > wait ? maxBackoff : wait;
    }
    final at = _retryAt[key];
    if (at != null) {
      final left = at.difference(_clock());
      if (left > wait) wait = left;
    }
    if (quality != null && quality.trim().isNotEmpty) {
      final qualityAt = _retryAt[_quality(id, trackKey, quality)];
      if (qualityAt != null) {
        final left = qualityAt.difference(_clock());
        if (left > wait) wait = left;
      }
    }
    return wait;
  }

  bool exhausted(String provider, String trackKey) =>
      (_attempts[_pair(provider, trackKey)] ?? 0) >= maxAttempts;

  Future<void> spaceRequest(String provider) async {
    final id = _provider(provider);
    if (id.isEmpty || spacing <= Duration.zero) return;
    final now = _clock();
    final slot = _nextSlot[id];
    final start = slot != null && slot.isAfter(now) ? slot : now;
    _nextSlot[id] = start.add(spacing);
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  void recordAttempt(String provider, String trackKey) {
    final key = _pair(provider, trackKey);
    _attempts[key] = (_attempts[key] ?? 0) + 1;
  }

  void recordFailure(
    String provider,
    String trackKey, {
    Duration? retryAfter,
    String? quality,
  }) {
    final id = _provider(provider);
    if (id.isEmpty) return;
    final scoped = quality != null && quality.trim().isNotEmpty;
    final key = scoped ? _quality(id, trackKey, quality) : _pair(id, trackKey);
    final count = (_failures[key] ?? 0) + 1;
    _failures[key] = count;
    var wait = retryAfter;
    if (!scoped && (wait == null || wait <= Duration.zero)) {
      final last = _cool.lastFailure(id);
      final seconds = last?.retryAfterSeconds;
      if (last != null &&
          seconds != null &&
          seconds > 0 &&
          _clock().difference(last.at) < const Duration(seconds: 30)) {
        wait = Duration(seconds: seconds);
      }
    }
    wait ??= backoff.isEmpty
        ? Duration.zero
        : backoff[count > backoff.length ? backoff.length - 1 : count - 1];
    if (wait > maxBackoff) wait = maxBackoff;
    _retryAt[key] = _clock().add(wait);
  }

  void recordSuccess(String provider, String trackKey) {
    final key = _pair(provider, trackKey);
    final prefix = '$key|';
    _failures.remove(key);
    _retryAt.remove(key);
    _attempts.remove(key);
    _failures.removeWhere((entry, _) => entry.startsWith(prefix));
    _retryAt.removeWhere((entry, _) => entry.startsWith(prefix));
  }

  void resetSession() {
    _nextSlot.clear();
    _retryAt.clear();
    _failures.clear();
    _attempts.clear();
  }
}
