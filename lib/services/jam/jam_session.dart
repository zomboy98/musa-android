import 'dart:async';

import 'jam_queue.dart';

/// Single-isolate owner of a session. Transport must authenticate identities
/// and pass the trusted identity separately from client-supplied commands.
/// Calls perform compare-and-apply synchronously without an await boundary.
/// This is not a cross-isolate or multi-process lock and is not persistence.
class JamSession {
  JamSession({required this.hostId}) : _state = JamQueue(hostId: hostId);

  final String hostId;
  final _events = StreamController<JamQueue>.broadcast();
  final _subscriptions = <StreamSubscription<JamQueue>>{};
  late final Stream<JamQueue> _eventStream = _JamEventStream(this);
  bool _closed = false;
  Future<void>? _closeFuture;
  bool get isClosed => _closed;
  Stream<JamQueue> get events => _eventStream;

  /// Active subscribers receive pending events and then done. Paused
  /// subscribers are canceled and do not receive done, so they cannot hold
  /// shutdown open. Subscribers that pause during shutdown are also canceled.
  /// Repeated calls wait for the same resource cleanup.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final subscriptions = _subscriptions.where((s) => s.isPaused).toList();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    await _events.close();
    _subscriptions.clear();
  }

  void _publish(JamResult result) {
    _state = result.state;
    if (result.outcome == JamOutcome.applied) _events.add(_state);
  }

  JamQueue _state;
  JamQueue get snapshot => _state;

  /// Synchronous local host runtime update, never a network command.
  JamResult setCurrentOccurrence(String? occurrenceId) {
    if (_closed) throw StateError('Session closed');
    final result = _state.setCurrentOccurrence(occurrenceId);
    _publish(result);
    return result;
  }

  JamResult setPlaybackOccurrences({
    required String? currentOccurrenceId,
    String? pendingOccurrenceId,
  }) {
    if (_closed) throw StateError('Session closed');
    final result = _state.setPlaybackOccurrences(
      currentOccurrenceId: currentOccurrenceId,
      pendingOccurrenceId: pendingOccurrenceId,
    );
    _publish(result);
    return result;
  }

  JamResult revokeGuest({
    required String authenticatedActorId,
    required String guestId,
  }) {
    if (_closed) throw StateError('Session closed');
    final result = _state.revokeGuest(
      authenticatedActorId: authenticatedActorId,
      guestId: guestId,
    );
    _publish(result);
    return result;
  }

  /// Host-owned admission probe; absent for queue-only protocol sessions.
  /// Returns only availability, never a local source or inventory to peers.
  Future<bool> Function(String trackId)? canResolveGuestTrack;
  Future<bool>? _sourceProbe;
  String? _sourceProbeTrack;

  Future<bool> _probeSource(
    String trackId,
    Future<bool> Function(String) probe,
  ) {
    final active = _sourceProbe;
    if (active != null) {
      return _sourceProbeTrack == trackId ? active : Future.value(false);
    }
    _sourceProbeTrack = trackId;
    // Keep the slot until actual completion, even if callers time out. A
    // timed-out filesystem operation cannot be cancelled by Future.timeout.
    // Coalesce the same source and reject other probes while it is occupied.
    Future<bool> resolve() async {
      // Install ownership before even a synchronously throwing probe runs.
      await Future<void>.value();
      try {
        return await probe(trackId);
      } catch (_) {
        return false;
      } finally {
        _sourceProbe = null;
        _sourceProbeTrack = null;
      }
    }

    return _sourceProbe = resolve();
  }

  /// Checks rules before probing, then repeats them after the async boundary.
  /// Rejected availability is retryable with the same ID and revision.
  Future<JamResult> submitRemote({
    required String authenticatedActorId,
    required JamCommand command,
    required bool Function() isAuthorized,
  }) async {
    JamResult? validate() {
      if (_closed ||
          !isAuthorized() ||
          authenticatedActorId != command.actorId ||
          authenticatedActorId == hostId) {
        return JamResult(_state, JamOutcome.forbidden);
      }
      final result = _state.apply(command);
      return result.outcome == JamOutcome.applied ? null : result;
    }

    final rejected = validate();
    if (rejected != null) return rejected;
    final probe = canResolveGuestTrack;
    if (command is AddJamEntry && probe != null) {
      var available = false;
      try {
        available = await _probeSource(
          command.trackId,
          probe,
        ).timeout(const Duration(seconds: 5), onTimeout: () => false);
      } catch (_) {
        // Never send private resolver errors over the wire.
      }
      final changed = validate();
      if (changed != null) return changed;
      if (!available) return JamResult(_state, JamOutcome.unavailable);
    }
    return submit(authenticatedActorId: authenticatedActorId, command: command);
  }

  JamResult submit({
    required String authenticatedActorId,
    required JamCommand command,
  }) {
    if (_closed) throw StateError('Session closed');
    if (authenticatedActorId != command.actorId) {
      return JamResult(_state, JamOutcome.forbidden);
    }
    final result = _state.apply(command);
    _publish(result);
    return result;
  }
}

class _JamEventStream extends Stream<JamQueue> {
  _JamEventStream(this.session);
  final JamSession session;

  @override
  bool get isBroadcast => true;

  @override
  StreamSubscription<JamQueue> listen(
    void Function(JamQueue)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (session.isClosed) {
      return const Stream<JamQueue>.empty().listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
    }
    late _TrackedSubscription<JamQueue> subscription;
    // Ownership transfers to _TrackedSubscription and session.close().
    // ignore: cancel_subscriptions
    final inner = session._events.stream.listen(
      onData,
      onError: onError,
      onDone: () {
        session._subscriptions.remove(subscription);
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
    subscription = _TrackedSubscription(
      inner,
      () => session._subscriptions.remove(subscription),
      () => session.isClosed,
    );
    session._subscriptions.add(subscription);
    return subscription;
  }
}

class _TrackedSubscription<T> implements StreamSubscription<T> {
  _TrackedSubscription(this.inner, this.remove, this.isClosing);
  final StreamSubscription<T> inner;
  final void Function() remove;
  final bool Function() isClosing;

  @override
  Future<void> cancel() {
    remove();
    return inner.cancel();
  }

  @override
  void onData(void Function(T data)? handleData) => inner.onData(handleData);
  @override
  void onError(Function? handleError) => inner.onError(handleError);
  @override
  void onDone(void Function()? handleDone) => inner.onDone(() {
    remove();
    handleDone?.call();
  });
  @override
  void pause([Future<void>? resumeSignal]) {
    if (isClosing()) {
      unawaited(cancel());
    } else {
      inner.pause(resumeSignal);
    }
  }

  @override
  void resume() => inner.resume();
  @override
  bool get isPaused => inner.isPaused;
  @override
  Future<E> asFuture<E>([E? futureValue]) => inner.asFuture<E>(futureValue);
}
