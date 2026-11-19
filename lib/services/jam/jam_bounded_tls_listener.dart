import 'dart:async';
import 'dart:io';
import 'jam_network_address.dart';

/// Experimental TLS listener, loopback by default. It does not parse HTTP and is not
/// connected to JamTlsServer. The handler owns request framing and limits.
/// Cooperative cancellation for trusted handlers. A handler must check this
/// immediately before each state mutation and stop waiting when [cancelled]
/// completes. It cannot forcibly interrupt arbitrary asynchronous Dart code.
class JamConnectionCancellation {
  final Completer<void> _cancelled = Completer<void>();

  Future<void> get cancelled => _cancelled.future;
  bool get isCancelled => _cancelled.isCompleted;

  void throwIfCancelled() {
    if (isCancelled) throw StateError('Connection cancelled');
  }

  void _cancel() {
    if (!isCancelled) _cancelled.complete();
  }
}

class JamBoundedTlsListener {
  JamBoundedTlsListener._(
    this._server,
    this._identity,
    this._handler,
    this._maxConnections,
    this._handshakeTimeout,
    this._connectionTimeout,
  ) {
    _server.listen(_accept, onError: (Object _) {});
  }

  static Future<JamBoundedTlsListener> start({
    required SecurityContext identity,
    required Future<void> Function(RawSecureSocket, JamConnectionCancellation)
    handler,
    InternetAddress? address,
    int maxConnections = 16,
    Duration handshakeTimeout = const Duration(seconds: 5),
    Duration connectionTimeout = const Duration(seconds: 10),
  }) async {
    if (maxConnections < 1 ||
        handshakeTimeout <= Duration.zero ||
        connectionTimeout <= Duration.zero) {
      throw ArgumentError('Invalid connection limits');
    }
    final server = await RawServerSocket.bind(
      validateJamAddress(address ?? InternetAddress.loopbackIPv4),
      0,
    );
    return JamBoundedTlsListener._(
      server,
      identity,
      handler,
      maxConnections,
      handshakeTimeout,
      connectionTimeout,
    );
  }

  final RawServerSocket _server;
  final SecurityContext _identity;
  final Future<void> Function(RawSecureSocket, JamConnectionCancellation)
  _handler;
  final int _maxConnections;
  final Duration _handshakeTimeout;
  final Duration _connectionTimeout;
  final Set<RawSocket> _connections = {};
  final Set<Future<void>> _tasks = {};
  final Map<RawSocket, JamConnectionCancellation> _cancellations = {};
  bool _closed = false;
  Future<void>? _closeFuture;

  int get port => _server.port;
  int get activeConnections => _connections.length;
  int get pendingTasks => _tasks.length;

  void _accept(RawSocket raw) {
    if (_closed || _connections.length >= _maxConnections) {
      raw.close();
      return;
    }
    _connections.add(raw);
    _cancellations[raw] = JamConnectionCancellation();
    late final Future<void> task;
    task = _serve(raw).whenComplete(() => _tasks.remove(task));
    _tasks.add(task);
  }

  Future<void> _serve(RawSocket raw) async {
    RawSecureSocket? secure;
    var abandoned = false;
    final cancellation = _cancellations[raw]!;
    final deadline = Timer(_connectionTimeout, () {
      cancellation._cancel();
      secure?.close();
      raw.close();
    });
    try {
      final handshake = RawSecureSocket.secureServer(raw, _identity);
      unawaited(
        handshake.then((socket) {
          if (abandoned) socket.close();
        }, onError: (Object _) {}),
      );
      secure = await handshake.timeout(
        _handshakeTimeout,
        onTimeout: () {
          abandoned = true;
          cancellation._cancel();
          raw.close();
          throw TimeoutException('TLS handshake');
        },
      );
      if (!_closed && !cancellation.isCancelled) {
        await _handler(secure, cancellation);
      }
    } catch (_) {
      // Disconnects, failed handshakes and handler failures end the connection.
    } finally {
      abandoned = true;
      cancellation._cancel();
      deadline.cancel();
      secure?.close();
      raw.close();
      _connections.remove(raw);
      _cancellations.remove(raw);
    }
  }

  /// Concurrent callers share the same shutdown. Uncooperative handlers are
  /// not awaited: they keep their slots until they finish and must honor the
  /// cancellation token before mutating state.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final raw in _connections.toList()) {
      _cancellations[raw]?._cancel();
      raw.close();
    }
    await _server.close();
  }
}
