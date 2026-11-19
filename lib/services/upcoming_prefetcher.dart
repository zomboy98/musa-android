import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/prefetch_planner.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('Prefetch');

enum PrefetchNetwork { offline, metered, unmetered }

PrefetchNetwork prefetchNetworkFor(List<ConnectivityResult> results) {
  if (results.isEmpty || results.every((r) => r == ConnectivityResult.none)) {
    return PrefetchNetwork.offline;
  }
  if (results.contains(ConnectivityResult.wifi) ||
      results.contains(ConnectivityResult.ethernet)) {
    return PrefetchNetwork.unmetered;
  }
  return PrefetchNetwork.metered;
}

Future<PrefetchNetwork> currentPrefetchNetwork() async =>
    prefetchNetworkFor(await Connectivity().checkConnectivity());

/// Keeps the songs queued after the one playing prepared: a window of
/// [count] songs that slides forward each time the current song changes.
/// They are prepared one at a time, in play order, and only while nothing
/// more urgent is being prepared, so they start sooner.
class UpcomingPrefetcher {
  UpcomingPrefetcher({
    required this.prepare,
    required this.cancel,
    required this.isStreamingOnly,
    required this.network,
    required this.key,
    this.count = defaultPrefetchWindow,
    this.meteredLimit = 1,
    this.pauseLimit = const Duration(minutes: 3),
    this.gap = Duration.zero,
    this.providerWait,
    this.trackWait,
    this.failureBackoff = prefetchRetryBase,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  static const maxCount = maxPrefetchWindow;

  /// Makes the song ready the same way playing it would, then lets go of it.
  final Future<void> Function(Track track) prepare;
  final Future<void> Function(Track track) cancel;
  final Future<bool> Function(Track track) isStreamingOnly;
  final Future<PrefetchNetwork> Function() network;
  final String Function(Track track) key;

  int count;
  final int meteredLimit;
  final Duration pauseLimit;
  final Duration gap;
  final Duration Function()? providerWait;
  final Duration Function(Track track)? trackWait;
  final Duration failureBackoff;
  final DateTime Function() _clock;

  List<Track> _wanted = const [];
  final Set<String> _done = {};
  final Set<String> _skipped = {};
  Track? _inFlight;
  Track? _dropped;
  bool _held = false;
  bool _stale = false;
  bool _running = false;
  bool _stopped = false;
  int _generation = 0;
  Timer? _pauseTimer;
  Timer? _wakeTimer;
  final Map<String, DateTime> _failedUntil = {};
  final Map<String, int> _failures = {};
  int? _index;

  Track? get inFlight => _inFlight;

  /// A new song is being prepared or has been asked for: the one in [target]
  /// keeps its work, everything else queued here stops and the current song
  /// gets the provider to itself.
  void hold({Track? target}) {
    _held = true;
    _generation++;
    _wanted = const [];
    _skipped.clear();
    _dropInFlight(except: target);
  }

  /// The current song is playing; [upcoming] lists the next ones in order.
  void schedule(List<Track> upcoming, {Track? current, int? index}) {
    if (_stopped) return;
    _held = false;
    _generation++;
    _index = index;
    _wanted = List.unmodifiable(upcoming);
    final upcomingKeys = {for (final t in upcoming) key(t)};
    _done.retainAll(upcomingKeys);
    _failures.removeWhere((id, _) => !upcomingKeys.contains(id));
    _failedUntil.removeWhere((id, _) => !upcomingKeys.contains(id));
    final now = _clock();
    final running = _inFlight;
    final plan = planPrefetch(
      upcoming: [
        for (final t in upcoming)
          if (!_skipped.contains(key(t))) key(t),
      ],
      count: count,
      ready: _done,
      inFlight: {if (running != null) key(running)},
      blocked: {
        for (final entry in _failedUntil.entries)
          if (entry.value.isAfter(now)) entry.key,
      },
    );
    var cancelled = const <String>[];
    if (running != null && plan.toCancel.contains(key(running))) {
      if (current == null || key(current) != key(running)) {
        cancelled = plan.toCancel;
        _dropInFlight(except: current);
      }
    }
    _logDecision(plan, cancelled: cancelled);
    unawaited(_run());
  }

  void _logDecision(
    PrefetchPlan plan, {
    List<String> started = const [],
    List<String> cancelled = const [],
  }) {
    String ids(List<String> keys) =>
        keys.isEmpty ? '-' : keys.map(shortPrefetchId).join(',');
    final line =
        'prefetch: current=${_index ?? -1} window=${plan.window.length} '
        'ready=${plan.ready} started=${ids(started)} '
        'cancelled=${ids(cancelled)}';
    debugPrint(line);
    _log.i(line);
  }

  /// The connection changed: a song being prepared that the new connection
  /// does not allow stops, and preparing resumes when it allows more.
  void networkChanged() {
    if (_stopped || _held) return;
    _generation++;
    unawaited(_reconcileNetwork());
    unawaited(_run());
  }

  Future<void> _reconcileNetwork() async {
    final running = _inFlight;
    if (running == null) return;
    final PrefetchNetwork net;
    try {
      net = await network();
    } catch (_) {
      return;
    }
    if (_inFlight == null || key(_inFlight!) != key(running)) return;
    var allowed = net != PrefetchNetwork.offline;
    if (allowed && net == PrefetchNetwork.metered) {
      final position = _wanted
          .where((t) => !_skipped.contains(key(t)))
          .map(key)
          .toList()
          .indexOf(key(running));
      allowed = position >= 0 && position < meteredLimit;
    }
    if (!allowed) _dropInFlight();
  }

  void setPaused(bool paused) {
    if (_stopped) return;
    if (!paused) {
      _pauseTimer?.cancel();
      _pauseTimer = null;
      if (_stale) {
        _stale = false;
        _generation++;
        unawaited(_run());
      }
      return;
    }
    _pauseTimer ??= Timer(pauseLimit, () {
      _pauseTimer = null;
      _stale = true;
      _generation++;
      _dropInFlight();
    });
  }

  void stop() {
    _stopped = true;
    _wakeTimer?.cancel();
    _wakeTimer = null;
    _pauseTimer?.cancel();
    _pauseTimer = null;
    _wanted = const [];
    _generation++;
    _dropInFlight();
  }

  void _dropInFlight({Track? except}) {
    final running = _inFlight;
    if (running == null) return;
    if (except != null && key(except) == key(running)) return;
    if (identical(_dropped, running)) return;
    _dropped = running;
    unawaited(
      cancel(running).catchError((Object _) {}),
    );
  }

  void _wakeAfter(Duration wait) {
    if (_stopped) return;
    _wakeTimer?.cancel();
    _wakeTimer = Timer(wait + const Duration(seconds: 1), () {
      _wakeTimer = null;
      if (_stopped || _held) return;
      _generation++;
      unawaited(_run());
    });
  }

  Future<Track?> _pick() async {
    if (_held || _stale || _stopped || count <= 0 || _wanted.isEmpty) {
      return null;
    }
    final wait = providerWait?.call() ?? Duration.zero;
    if (wait > Duration.zero) {
      _wakeAfter(wait);
      return null;
    }
    final net = await network();
    if (net == PrefetchNetwork.offline) return null;
    final now = _clock();
    _failedUntil.removeWhere((_, until) => !until.isAfter(now));
    final limit = net == PrefetchNetwork.unmetered
        ? count
        : (count < meteredLimit ? count : meteredLimit);
    final failing = _failedUntil.values.where((u) => u.isAfter(now)).toList();
    if (failing.length >= prefetchFailureSkipLimit) {
      final soonest = failing.reduce((a, b) => a.isBefore(b) ? a : b);
      _wakeAfter(soonest.difference(now));
      return null;
    }
    final eligible = <Track>[];
    for (final track in _wanted.toList()) {
      final id = key(track);
      if (_skipped.contains(id) || _failedUntil.containsKey(id)) continue;
      final blocked = trackWait?.call(track) ?? Duration.zero;
      if (blocked > Duration.zero) {
        _wakeAfter(blocked);
        continue;
      }
      if (!await isStreamingOnly(track)) {
        _skipped.add(id);
        continue;
      }
      eligible.add(track);
      if (eligible.length >= limit) break;
    }
    final plan = planPrefetch(
      upcoming: [for (final t in eligible) key(t)],
      count: limit,
      ready: _done,
    );
    if (plan.toStart.isEmpty) return null;
    final next = plan.toStart.first;
    _logDecision(plan, started: [next]);
    return eligible.firstWhere((t) => key(t) == next);
  }

  Future<void> _run() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final generation = _generation;
        Track? track;
        try {
          track = await _pick();
        } catch (_) {
          track = null;
        }
        if (generation != _generation) continue;
        if (track == null) return;
        if (gap > Duration.zero) {
          await Future<void>.delayed(gap);
          if (generation != _generation || _stopped) continue;
        }
        _inFlight = track;
        _dropped = null;
        final id = key(track);
        try {
          await prepare(track);
          _done.add(id);
          _failures.remove(id);
          _failedUntil.remove(id);
        } catch (_) {
          if (!_stopped && generation == _generation) {
            final failures = (_failures[id] ?? 0) + 1;
            _failures[id] = failures;
            final wait = providerWait?.call() ?? Duration.zero;
            final retry = prefetchRetryDelay(
              failures,
              base: failureBackoff,
              ceiling: failureBackoff > prefetchRetryCeiling
                  ? failureBackoff
                  : prefetchRetryCeiling,
            );
            final backoff = wait > retry ? wait : retry;
            _failedUntil[id] = _clock().add(backoff);
            _wakeAfter(backoff);
          }
        } finally {
          _inFlight = null;
        }
        if (_stopped) return;
      }
    } finally {
      _running = false;
    }
  }
}
