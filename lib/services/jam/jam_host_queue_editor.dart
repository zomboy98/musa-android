import 'dart:convert';
import 'dart:math';

import 'jam_app_controller.dart';
import 'jam_queue.dart';

/// Session-local source registry. Keys are opaque and never contain a source.
class JamHostTrackRegistry<T extends Object> {
  final Map<String, T> _tracks = {};
  final Map<String, Object> _provisional = {};
  bool _bound = false;
  T? resolve(String id) => _tracks[id];
  bool contains(String id) => _tracks.containsKey(id);

  void _bind() {
    if (_bound) {
      throw StateError('Track registry already belongs to an editor');
    }
    _bound = true;
  }

  void _clear() {
    _tracks.clear();
    _provisional.clear();
  }
}

/// A fresh draft is built on each CAS retry; edits must be deterministic and
/// identify existing occurrences by ID rather than by their old list index.
class JamHostQueueDraft<T extends Object> {
  JamHostQueueDraft._(List<JamEntry> entries, this._token)
    : entries = List.of(entries);
  final List<JamEntry> entries;
  final String Function() _token;
  final Map<String, T> _newTracks = {};

  JamEntry create(T media) {
    final trackId = 'jamhost1:${_token()}';
    if (_newTracks.containsKey(trackId)) throw StateError('Token collision');
    _newTracks[trackId] = media;
    return JamEntry(occurrenceId: _token(), trackId: trackId);
  }
}

/// Host-only bridge from local edits to the authoritative Jam queue.
/// The adapter never changes the local player directly; Jam playback projects
/// accepted snapshots. Registrations are visible before submit and are rolled
/// back on rejection, conflict, or exception.
class JamHostQueueEditor<T extends Object> {
  JamHostQueueEditor({
    required this.controller,
    required this.registry,
    this.maxAttempts = 3,
  }) : assert(maxAttempts > 0),
       _generation = controller.sessionGeneration {
    if (controller.phase != JamAppPhase.hosting) {
      throw StateError('Not hosting');
    }
    registry._bind();
    controller.addListener(_sessionChanged);
  }

  final JamAppController controller;
  final JamHostTrackRegistry<T> registry;
  final int maxAttempts;
  final int _generation;
  bool _closed = false;
  final Random _random = Random.secure();
  String _token() => base64Url
      .encode(List.generate(24, (_) => _random.nextInt(256)))
      .replaceAll('=', '');

  void _sessionChanged() {
    if (controller.sessionGeneration != _generation ||
        controller.phase != JamAppPhase.hosting) {
      _detach();
    } else {
      _prune();
    }
  }

  void _prune() {
    final live = controller.snapshot;
    if (_closed || live == null) return;
    final retained = {for (final entry in live.entries) entry.trackId};
    registry._tracks.removeWhere(
      (key, _) =>
          !retained.contains(key) && !registry._provisional.containsKey(key),
    );
  }

  // Only session termination releases all sources; clearing a live registry
  // would make the authoritative queue unresolvable.
  void _detach() {
    if (_closed) return;
    _closed = true;
    controller.removeListener(_sessionChanged);
    registry._clear();
  }

  JamResult edit(void Function(JamHostQueueDraft<T> draft) transform) {
    if (maxAttempts < 1) throw StateError('At least one attempt is required');
    void checkSession() {
      if (_closed ||
          controller.phase != JamAppPhase.hosting ||
          controller.sessionGeneration != _generation) {
        throw StateError('Host session changed');
      }
    }

    checkSession();
    final initial = controller.snapshot;
    if (initial == null) throw StateError('No host snapshot');
    var revision = initial.revision;
    var entries = initial.entries;
    JamResult? result;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      checkSession();
      final draft = JamHostQueueDraft<T>._(entries, _token);
      transform(draft);
      final originalIds = {for (final entry in entries) entry.trackId};
      if (draft.entries.any(
        (entry) =>
            registry._provisional.containsKey(entry.trackId) &&
            !originalIds.contains(entry.trackId),
      )) {
        throw StateError('Cannot use another edit\'s provisional token');
      }
      // Only register media that actually occurs in the submitted queue.
      final used = {for (final entry in draft.entries) entry.trackId};
      final provisional = <String, T>{
        for (final entry in draft._newTracks.entries)
          if (used.contains(entry.key)) entry.key: entry.value,
      };
      if (provisional.keys.any(registry.contains)) {
        throw StateError('Token collision');
      }
      final owner = Object();
      registry._tracks.addAll(provisional);
      for (final key in provisional.keys) {
        registry._provisional[key] = owner;
      }
      try {
        checkSession();
        result = controller.replaceHostQueue(
          entries: List.unmodifiable(draft.entries),
          expectedRevision: revision,
          commandId: _token(),
        );
        if (result.outcome == JamOutcome.applied ||
            result.outcome == JamOutcome.duplicate) {
          for (final key in provisional.keys) {
            if (identical(registry._provisional[key], owner)) {
              registry._provisional.remove(key);
            }
          }
          // Reentrant notifications may already have advanced the queue.
          _prune();
          return result;
        }
      } finally {
        if (result?.outcome != JamOutcome.applied &&
            result?.outcome != JamOutcome.duplicate) {
          for (final key in provisional.keys) {
            if (identical(registry._provisional[key], owner)) {
              registry._provisional.remove(key);
              registry._tracks.remove(key);
            }
          }
        }
      }
      if (result.outcome != JamOutcome.conflict) return result;
      if (attempt == maxAttempts - 1) return result;
      revision = result.state.revision;
      entries = result.state.entries;
      result = null;
    }
    throw StateError('Unreachable');
  }
}
