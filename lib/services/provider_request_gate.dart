import 'dart:async';

enum ProviderRequestPriority { foreground, queue, prefetch }

class ProviderRequestCancelled implements Exception {
  const ProviderRequestCancelled();

  @override
  String toString() => 'ProviderRequestCancelled';
}

class ProviderTurnTimeout implements Exception {
  const ProviderTurnTimeout(this.limit);

  final Duration limit;

  @override
  String toString() => 'ProviderTurnTimeout: ${limit.inSeconds}s';
}

class ProviderTurn {
  ProviderTurn._(this._gate, this._priority, this._sequence);

  final ProviderRequestGate _gate;
  final int _sequence;
  final Completer<void> _granted = Completer<void>();
  ProviderRequestPriority _priority;
  bool _holding = false;
  bool _released = false;

  ProviderRequestPriority get priority => _priority;
  Future<void> get granted => _granted.future;
  bool get isHolding => _holding;
  bool get isReleased => _released;

  void promote(ProviderRequestPriority next) {
    if (_released || _holding || next.index >= _priority.index) return;
    _priority = next;
  }

  void release() => _gate._release(this);
}

class ProviderRequestGate {
  ProviderRequestGate({this.defaultMaxTurn = const Duration(minutes: 10)});

  static ProviderRequestGate instance = ProviderRequestGate();

  final Duration defaultMaxTurn;
  final List<ProviderTurn> _waiting = [];
  ProviderTurn? _holder;
  int _serial = 0;

  bool get busy => _holder != null;
  int get waiting => _waiting.length;

  ProviderTurn request(ProviderRequestPriority priority) {
    final turn = ProviderTurn._(this, priority, _serial++);
    _waiting.add(turn);
    _dispatch();
    return turn;
  }

  void _dispatch() {
    if (_holder != null || _waiting.isEmpty) return;
    var best = _waiting.first;
    for (final candidate in _waiting.skip(1)) {
      final byPriority = candidate._priority.index.compareTo(
        best._priority.index,
      );
      if (byPriority < 0 ||
          (byPriority == 0 && candidate._sequence < best._sequence)) {
        best = candidate;
      }
    }
    _waiting.remove(best);
    _holder = best;
    best._holding = true;
    best._granted.complete();
  }

  void _release(ProviderTurn turn) {
    if (turn._released) return;
    turn._released = true;
    if (identical(_holder, turn)) {
      _holder = null;
      turn._holding = false;
      _dispatch();
    } else {
      _waiting.remove(turn);
    }
  }

  Future<T> run<T>(
    Future<T> Function() action, {
    ProviderRequestPriority priority = ProviderRequestPriority.queue,
    Future<void>? cancelled,
    Duration? maxTurn,
    FutureOr<void> Function()? onTimeout,
    void Function(ProviderTurn turn)? onRequested,
  }) async {
    final turn = request(priority);
    try {
      onRequested?.call(turn);
      final ready = Completer<void>();
      unawaited(
        turn.granted.then((_) {
          if (!ready.isCompleted) ready.complete();
        }),
      );
      if (cancelled != null) {
        unawaited(
          cancelled.then<void>((_) {
            if (!ready.isCompleted) {
              ready.completeError(const ProviderRequestCancelled());
            }
          }, onError: (Object _) {}),
        );
      }
      await ready.future;
      final limit = maxTurn ?? defaultMaxTurn;
      final outcome = Completer<T>();
      final timer = Timer(limit, () {
        if (outcome.isCompleted) return;
        outcome.completeError(ProviderTurnTimeout(limit));
        try {
          final pending = onTimeout?.call();
          if (pending is Future<void>) {
            unawaited(pending.catchError((Object _) {}));
          }
        } catch (_) {}
      });
      final running = Future<T>.sync(action);
      unawaited(
        running.then<void>(
          (value) {
            if (!outcome.isCompleted) outcome.complete(value);
          },
          onError: (Object error, StackTrace stack) {
            if (!outcome.isCompleted) outcome.completeError(error, stack);
          },
        ),
      );
      try {
        return await outcome.future;
      } finally {
        timer.cancel();
      }
    } finally {
      turn.release();
    }
  }
}
