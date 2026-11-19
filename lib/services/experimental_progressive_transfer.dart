import 'dart:async';
import 'dart:math';

import 'package:flutter/services.dart';

/// One temporary transfer. Disabled unless explicitly enabled at compile time.
class ExperimentalProgressiveTransfer {
  ExperimentalProgressiveTransfer({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel('com.zarz.mornye/experimental_progressive') {
    _router = _ProgressiveEventRouter.acquire(_channel);
  }

  static const enabled = bool.fromEnvironment(
    'MORNYE_EXPERIMENTAL_PROGRESSIVE',
    defaultValue: false,
  );
  static const media3Enabled = bool.fromEnvironment(
    'MORNYE_EXPERIMENTAL_MEDIA3',
    defaultValue: false,
  );
  final MethodChannel _channel;
  late final _ProgressiveEventRouter _router;
  final Map<String, ExperimentalProgressiveAttempt> _attempts = {};
  final Random _random = Random.secure();
  bool _disposed = false;

  Future<ExperimentalProgressiveAttempt?> start({
    required String playerId,
    required String requestJson,
    bool? enabledForTesting,
  }) async {
    if (_disposed || !(enabledForTesting ?? enabled)) return null;
    final id = List.generate(
      16,
      (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final attempt = ExperimentalProgressiveAttempt._(id, this);
    _attempts[id] = attempt;
    _router.attempts[id] = attempt;
    try {
      final accepted = await _channel.invokeMethod<bool>('start', {
        'enabled': true,
        'attemptId': id,
        'playerId': playerId,
        'requestJson': requestJson,
        'media3': media3Enabled,
      });
      if (accepted != true) {
        _attempts.remove(id);
        _router.attempts.remove(id);
        return null;
      }
      return attempt;
    } catch (_) {
      _attempts.remove(id);
      _router.attempts.remove(id);
      return null;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final attempts = _attempts.values.toList();
    for (final attempt in attempts) {
      await attempt.cancel();
    }
    _router.release();
  }
}

class _ProgressiveEventRouter {
  _ProgressiveEventRouter(this.channel) {
    channel.setMethodCallHandler(_onEvent);
  }
  static final Expando<Map<String, _ProgressiveEventRouter>> _byMessenger =
      Expando();
  static _ProgressiveEventRouter acquire(MethodChannel channel) {
    final channels = _byMessenger[channel.binaryMessenger] ??= {};
    final router = channels.putIfAbsent(
      channel.name,
      () => _ProgressiveEventRouter(channel),
    );
    router.owners++;
    return router;
  }

  final MethodChannel channel;
  final Map<String, ExperimentalProgressiveAttempt> attempts = {};
  int owners = 0;
  Future<void> _onEvent(MethodCall call) async {
    if (call.method != 'event' || call.arguments is! Map) return;
    final args = Map<Object?, Object?>.from(call.arguments as Map);
    final attempt = attempts[args['attemptId']];
    if (attempt == null) return;
    switch (args['kind']) {
      case 'attached':
        attempt._attached();
      case 'result':
        final result = args['resultJson'];
        if (result is String) attempt._result(result);
      case 'invalidated':
        attempt._invalidated(args['positionMs']);
      case 'retiring':
        attempt._retiring();
      case 'retired':
        attempt._retiring();
        attempt._retire(args['positionMs']);
      case 'fallback':
        attempt._invalidated(args['positionMs']);
        attempt._fallback();
      case 'failed':
        attempt._invalidated(args['positionMs']);
        attempt._failed();
    }
  }

  void release() {
    if (--owners != 0) return;
    channel.setMethodCallHandler(null);
    _byMessenger[channel.binaryMessenger]?.remove(channel.name);
  }
}

class ExperimentalProgressiveAttempt {
  ExperimentalProgressiveAttempt._(this._id, this._owner) {
    _resultCompleter.future.ignore();
  }
  final String _id;
  final ExperimentalProgressiveTransfer _owner;
  final _source = Completer<bool>();
  final _resultCompleter = Completer<String?>();
  final _retiredCompleter = Completer<Duration?>();
  final _retiringCompleter = Completer<bool>();
  bool _closed = false;
  bool _wasInvalidated = false;
  Duration? _invalidatedPosition;
  bool get wasInvalidated => _wasInvalidated;
  Duration? get invalidatedPosition => _invalidatedPosition;
  Future<bool>? _cancellation;
  bool get isCancelled => _closed;

  /// True means source accepted for preparation; it does not mean playback.
  Future<bool> get sourceAttached => _source.future;

  /// Null means fallback to the normal complete-download path.
  Future<String?> get result => _resultCompleter.future;

  /// Independent of download completion; null means retirement lacked a safe position.
  Future<Duration?> get retired => _retiredCompleter.future;
  Future<bool> get retiring => _retiringCompleter.future;
  void _retiring() {
    if (!_closed && !_retiringCompleter.isCompleted)
      _retiringCompleter.complete(true);
  }

  void _retire(Object? position) {
    if (_closed || _retiredCompleter.isCompleted) return;
    _retiredCompleter.complete(
      position is int && position >= 0
          ? Duration(milliseconds: position)
          : null,
    );
  }

  void _attached() {
    if (!_closed && !_source.isCompleted) _source.complete(true);
  }

  void _invalidated(Object? position) {
    if (_closed) return;
    _wasInvalidated = true;
    if (position is int && position >= 0)
      _invalidatedPosition = Duration(milliseconds: position);
  }

  void _result(String value) {
    if (_closed || _resultCompleter.isCompleted) return;
    if (!_source.isCompleted) _source.complete(false);
    _resultCompleter.complete(value);
  }

  void _fallback() {
    if (_closed || _resultCompleter.isCompleted) return;
    if (!_source.isCompleted) _source.complete(false);
    _resultCompleter.complete(null);
  }

  void _failed() {
    if (_closed || _resultCompleter.isCompleted) return;
    if (!_source.isCompleted) _source.complete(false);
    _resultCompleter.completeError(
      StateError('Progressive cancellation did not finish'),
    );
  }

  Future<bool> cancel() => _cancellation ??= _cancel();
  Future<bool> _cancel() async {
    _closed = true;
    _owner._attempts.remove(_id);
    _owner._router.attempts.remove(_id);
    if (!_source.isCompleted) _source.complete(false);
    if (!_resultCompleter.isCompleted) _resultCompleter.complete(null);
    if (!_retiredCompleter.isCompleted) _retiredCompleter.complete(null);
    if (!_retiringCompleter.isCompleted) _retiringCompleter.complete(false);
    return await _owner._channel.invokeMethod<bool>('cancel', {
          'attemptId': _id,
        }) ==
        true;
  }
}
