import 'dart:async';

import 'jam_queue.dart';

/// Resolves an opaque Jam track ID against the host's authorized local library.
/// Implementations must not fetch, stream, or interpret the ID as a path/URL.
abstract interface class JamTrackResolver<T extends Object> {
  Future<T?> resolveLocal(String trackId);
}

/// Optional snapshot-scoped batch resolution, in the same order as the IDs.
abstract interface class JamBatchTrackResolver<T extends Object> {
  Future<List<T?>> resolveLocalBatch(List<String> trackIds);
}

class JamPlaybackEntry<T extends Object> {
  const JamPlaybackEntry(this.occurrenceId, this.track);
  final String occurrenceId;
  final T track;
}

/// Host-local queue capability. This interface deliberately has no transport
/// controls. Reconciliation must preserve the current source, position and
/// playing/paused state, and must never start playback on an empty player.
/// It must identify duplicate songs by occurrenceId. If those guarantees cannot
/// be met, it must reject the operation without changing the player's queue.
abstract interface class JamPlaybackPort<T extends Object> {
  Future<void> reconcileQueue(List<JamPlaybackEntry<T>> entries);
}

/// Optional lifecycle for ports that temporarily suppress local queue automation.
abstract interface class JamPlaybackLifecycle {
  Future<void> closeJamPlayback();
}

/// Serializes projections of the authoritative Jam queue onto a host port.
/// Missing occurrences remain in the authoritative queue and are reported.
class JamPlaybackBinding<T extends Object> {
  JamPlaybackBinding({
    required Stream<JamQueue> events,
    required JamQueue initial,
    required this.resolver,
    required this.port,
    this.onError,
    this.onSuccess,
    this.onPending,
    this.onAvailability,
    this.onPartial,
    this.allowPartial,
    this.currentRevision,
  }) {
    _subscription = events.listen(_schedule, onError: _report);
    _schedule(initial);
  }

  final JamTrackResolver<T> resolver;
  final JamPlaybackPort<T> port;
  final void Function(Object, StackTrace)? onError;
  final void Function(int revision)? onSuccess;
  final void Function(int revision)? onPending;
  final void Function(int revision, Set<String> unavailable)? onAvailability;
  final void Function(int revision)? onPartial;
  final bool Function()? allowPartial;
  final int Function()? currentRevision;
  late final StreamSubscription<JamQueue> _subscription;
  Future<void> _tail = Future.value();
  int _latestRevision = -1;
  JamQueue? _latestSnapshot;
  bool _failed = false;
  bool _closed = false;
  Future<void>? _closeFuture;

  void _report(Object error, StackTrace stack) {
    try {
      onError?.call(error, stack);
    } catch (_) {
      // An observer must not poison the serialized reconciliation chain.
    }
  }

  bool _isCurrent(JamQueue snapshot) =>
      !_closed &&
      snapshot.revision == _latestRevision &&
      (currentRevision == null || currentRevision!() == snapshot.revision);

  void _schedule(JamQueue snapshot) {
    if (_closed || snapshot.revision <= _latestRevision) return;
    _latestRevision = snapshot.revision;
    _latestSnapshot = snapshot;
    _enqueue(snapshot);
  }

  /// Retry only the latest failed projection, without changing the Jam queue.
  bool retry() {
    final snapshot = _latestSnapshot;
    if (_closed || !_failed || snapshot == null || !_isCurrent(snapshot)) {
      return false;
    }
    _enqueue(snapshot);
    return true;
  }

  void _enqueue(JamQueue snapshot) {
    _failed = false;
    try {
      onPending?.call(snapshot.revision);
    } catch (_) {
      // Observer failures do not affect reconciliation.
    }
    _tail = _tail
        .then((_) async {
          if (!_isCurrent(snapshot)) return;
          final entries = <JamPlaybackEntry<T>>[];
          final unavailable = <String>{};
          final batchResolver = resolver;
          final List<T?>? batch;
          if (batchResolver is JamBatchTrackResolver<T>) {
            final resolved = await (batchResolver as JamBatchTrackResolver<T>)
                .resolveLocalBatch([
                  for (final entry in snapshot.entries) entry.trackId,
                ]);
            if (!_isCurrent(snapshot)) return;
            if (resolved.length != snapshot.entries.length) {
              throw StateError('Invalid Jam resolver result');
            }
            batch = resolved;
          } else {
            batch = null;
          }
          for (var i = 0; i < snapshot.entries.length; i++) {
            final entry = snapshot.entries[i];
            final track = batch == null
                ? await resolver.resolveLocal(entry.trackId)
                : batch[i];
            if (!_isCurrent(snapshot)) return;
            if (track == null) {
              unavailable.add(entry.occurrenceId);
              continue;
            }
            entries.add(JamPlaybackEntry(entry.occurrenceId, track));
          }
          if (_isCurrent(snapshot)) {
            try {
              onAvailability?.call(
                snapshot.revision,
                Set.unmodifiable(unavailable),
              );
            } catch (_) {}
            if (!_isCurrent(snapshot)) return;
            if (unavailable.isNotEmpty && !(allowPartial?.call() ?? true)) {
              throw StateError('Jam bootstrap requires the complete queue');
            }
            if (unavailable.contains(snapshot.currentOccurrenceId) ||
                unavailable.contains(snapshot.pendingOccurrenceId)) {
              throw StateError('Jam current or pending source unavailable');
            }
            await port.reconcileQueue(List.unmodifiable(entries));
            if (_isCurrent(snapshot)) {
              try {
                if (unavailable.isEmpty) {
                  onSuccess?.call(snapshot.revision);
                } else {
                  _failed = true;
                  onPartial?.call(snapshot.revision);
                }
              } catch (_) {
                // Observer failures do not affect reconciliation.
              }
            }
          }
        })
        .catchError((Object error, StackTrace stack) {
          if (_isCurrent(snapshot)) {
            _failed = true;
            _report(error, stack);
          }
        });
  }

  /// Waits for work scheduled so far, including reported failures.
  Future<void> get settled => _tail;

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    await _subscription.cancel();
    await _tail;
    final playback = port;
    if (playback is JamPlaybackLifecycle) {
      await (playback as JamPlaybackLifecycle).closeJamPlayback();
    }
  }
}
