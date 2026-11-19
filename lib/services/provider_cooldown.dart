import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract class ProviderCooldownStore {
  Future<Map<String, int>> readAll();
  void write(String key, int value);
  void remove(String key);
}

abstract class ProviderFailureStore {
  Future<Map<String, String>> readAllFailures();
  void writeFailure(String key, String value);
  void removeFailure(String key);
}

class ProviderFailure {
  const ProviderFailure({
    required this.type,
    required this.at,
    this.httpCode,
    this.retryAfterSeconds,
  });

  final String type;
  final DateTime at;
  final int? httpCode;
  final int? retryAfterSeconds;

  String encode() => jsonEncode({
    't': type,
    'at': at.millisecondsSinceEpoch,
    if (httpCode != null) 'c': httpCode,
    if (retryAfterSeconds != null) 'r': retryAfterSeconds,
  });

  static ProviderFailure? decode(String raw) {
    try {
      final json = jsonDecode(raw);
      if (json is! Map) return null;
      final type = json['t'];
      final at = json['at'];
      if (type is! String || at is! int) return null;
      if (!RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(type)) return null;
      final code = json['c'];
      final retry = json['r'];
      return ProviderFailure(
        type: type,
        at: DateTime.fromMillisecondsSinceEpoch(at),
        httpCode: code is int && code >= 100 && code <= 599 ? code : null,
        retryAfterSeconds: retry is int && retry >= 0 && retry <= 86400
            ? retry
            : null,
      );
    } catch (_) {
      return null;
    }
  }
}

class SharedPreferencesCooldownStore
    implements ProviderCooldownStore, ProviderFailureStore {
  SharedPreferencesCooldownStore();

  Future<SharedPreferences>? _preferences;

  Future<SharedPreferences> get _prefs =>
      _preferences ??= SharedPreferences.getInstance();

  @override
  Future<Map<String, int>> readAll() async {
    final prefs = await _prefs;
    final out = <String, int>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(ProviderCooldown.keyPrefix)) continue;
      final value = prefs.get(key);
      if (value is int) out[key] = value;
    }
    return out;
  }

  @override
  void write(String key, int value) {
    _prefs.then((prefs) => prefs.setInt(key, value)).catchError((Object _) {
      return false;
    });
  }

  @override
  void remove(String key) {
    _prefs.then((prefs) => prefs.remove(key)).catchError((Object _) {
      return false;
    });
  }

  @override
  Future<Map<String, String>> readAllFailures() async {
    final prefs = await _prefs;
    final out = <String, String>{};
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(ProviderCooldown.failureKeyPrefix)) continue;
      final value = prefs.get(key);
      if (value is String) out[key] = value;
    }
    return out;
  }

  @override
  void writeFailure(String key, String value) {
    _prefs.then((prefs) => prefs.setString(key, value)).catchError((Object _) {
      return false;
    });
  }

  @override
  void removeFailure(String key) => remove(key);
}

class ProviderCooldown {
  ProviderCooldown({
    DateTime Function()? clock,
    ProviderCooldownStore? store,
    ProviderFailureStore? failureStore,
  }) : _clock = clock ?? DateTime.now,
       _store = store ?? SharedPreferencesCooldownStore(),
       _failureStore =
           failureStore ??
           (store == null
               ? SharedPreferencesCooldownStore()
               : (store is ProviderFailureStore
                     ? store as ProviderFailureStore
                     : null));

  static const keyPrefix = 'provider_cooldown_until.';
  static const failureKeyPrefix = 'provider_last_failure.';
  static const failureLifetime = Duration(hours: 24);
  static const _ignoredFailureTypes = {'none', 'cancelled'};
  static const minimumSeconds = 60;
  static const minimumTimeoutSeconds = 30;
  static const maximumSeconds = 86400;
  static const _attemptTypes = {'rate_limit', 'rate_limited', 'timeout'};

  static ProviderCooldown instance = ProviderCooldown();

  final DateTime Function() _clock;
  final ProviderCooldownStore _store;
  final ProviderFailureStore? _failureStore;
  final Map<String, int> _until = {};
  final Map<String, ProviderFailure> _failures = {};
  Future<void>? _loading;

  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    try {
      final stored = await _store.readAll();
      for (final entry in stored.entries) {
        if (!entry.key.startsWith(keyPrefix)) continue;
        final current = _until[entry.key];
        if (current == null || entry.value > current) {
          _until[entry.key] = entry.value;
        }
      }
    } catch (_) {
      _loading = null;
      return;
    }
    try {
      final stored = await _failureStore?.readAllFailures() ?? const {};
      for (final entry in stored.entries) {
        if (!entry.key.startsWith(failureKeyPrefix)) continue;
        final failure = ProviderFailure.decode(entry.value);
        if (failure == null) {
          _failureStore?.removeFailure(entry.key);
          continue;
        }
        final current = _failures[entry.key];
        if (current == null || failure.at.isAfter(current.at)) {
          _failures[entry.key] = failure;
        }
      }
    } catch (_) {
      return;
    }
  }

  static String _key(String provider) =>
      '$keyPrefix${provider.trim().toLowerCase()}';

  static String _failureKey(String id) => '$failureKeyPrefix$id';

  static String _label(String provider) {
    final id = provider.trim().toLowerCase();
    return RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(id) ? id : 'other';
  }

  void note(String provider, int retryAfterSeconds) {
    if (provider.trim().isEmpty || retryAfterSeconds <= 0) return;
    _record(
      provider,
      retryAfterSeconds > minimumTimeoutSeconds
          ? retryAfterSeconds
          : minimumTimeoutSeconds,
    );
  }

  void noteRateLimited(String provider, int retryAfterSeconds) {
    if (provider.trim().isEmpty) return;
    _record(
      provider,
      retryAfterSeconds > minimumSeconds ? retryAfterSeconds : minimumSeconds,
    );
  }

  void _record(String provider, int retryAfterSeconds) {
    final seconds = retryAfterSeconds > maximumSeconds
        ? maximumSeconds
        : retryAfterSeconds;
    final key = _key(provider);
    final until = _clock().millisecondsSinceEpoch + seconds * 1000;
    final current = _until[key];
    if (current != null && current >= until) return;
    _until[key] = until;
    _store.write(key, until);
    _trace(provider, 'noted', Duration(seconds: seconds));
  }

  void noteFailure(
    String provider,
    String errorType, {
    int? httpCode,
    int? retryAfterSeconds,
  }) {
    final id = provider.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]{1,32}$').hasMatch(id)) return;
    final type = errorType.trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{1,40}$').hasMatch(type) ||
        _ignoredFailureTypes.contains(type)) {
      return;
    }
    final failure = ProviderFailure(
      type: type,
      at: _clock(),
      httpCode: httpCode != null && httpCode >= 100 && httpCode <= 599
          ? httpCode
          : null,
      retryAfterSeconds:
          retryAfterSeconds != null &&
              retryAfterSeconds >= 0 &&
              retryAfterSeconds <= maximumSeconds
          ? retryAfterSeconds
          : null,
    );
    final key = _failureKey(id);
    _failures[key] = failure;
    _failureStore?.writeFailure(key, failure.encode());
  }

  ProviderFailure? lastFailure(String provider) {
    final key = _failureKey(provider.trim().toLowerCase());
    final failure = _failures[key];
    if (failure == null) return null;
    if (_clock().difference(failure.at) > failureLifetime) {
      _failures.remove(key);
      _failureStore?.removeFailure(key);
      return null;
    }
    return failure;
  }

  Map<String, ProviderFailure> failureSnapshot() {
    final out = <String, ProviderFailure>{};
    for (final key in _failures.keys.toList()) {
      final id = key.substring(failureKeyPrefix.length);
      final failure = lastFailure(id);
      if (failure != null) out[id] = failure;
    }
    return out;
  }

  Map<String, DateTime> untilSnapshot() {
    final out = <String, DateTime>{};
    for (final key in _until.keys.toList()) {
      final id = key.substring(keyPrefix.length);
      if (remaining(id) > Duration.zero) {
        out[id] = DateTime.fromMillisecondsSinceEpoch(_until[key]!);
      }
    }
    return out;
  }

  void noteAttempts(Object? attempts) {
    if (attempts is! List) return;
    for (final entry in attempts) {
      if (entry is! Map) continue;
      final provider = entry['provider'];
      final type = entry['error_type'];
      final retryAfter = entry['retry_after_s'];
      if (provider is String && type is String) {
        final code = entry['http_status'] ?? entry['http'];
        noteFailure(
          provider,
          type,
          httpCode: code is int ? code : null,
          retryAfterSeconds: retryAfter is int ? retryAfter : null,
        );
      }
      if (provider is String &&
          type is String &&
          _attemptTypes.contains(type) &&
          retryAfter is int) {
        if (type == 'timeout') {
          note(provider, retryAfter);
        } else {
          noteRateLimited(provider, retryAfter);
        }
      }
    }
  }

  Duration remaining(String provider, {bool trace = false}) {
    final key = _key(provider);
    final until = _until[key];
    if (until == null) return Duration.zero;
    final left = until - _clock().millisecondsSinceEpoch;
    if (left <= 0) {
      _until.remove(key);
      _store.remove(key);
      _trace(provider, 'expired', Duration.zero);
      return Duration.zero;
    }
    final remaining = Duration(milliseconds: left);
    if (trace) _trace(provider, 'skipped', remaining);
    return remaining;
  }

  Map<String, Duration> snapshot() {
    final out = <String, Duration>{};
    for (final key in _until.keys.toList()) {
      final id = key.substring(keyPrefix.length);
      final left = remaining(id);
      if (left > Duration.zero) out[id] = left;
    }
    return out;
  }

  bool isCoolingDown(String provider, {bool trace = false}) =>
      remaining(provider, trace: trace) > Duration.zero;

  static void _trace(String provider, String event, Duration remaining) {
    if (!kDebugMode) return;
    debugPrint(
      '[provider_cooldown] provider=${_label(provider)} event=$event '
      'remaining_s=${remaining.inSeconds}',
    );
  }
}
