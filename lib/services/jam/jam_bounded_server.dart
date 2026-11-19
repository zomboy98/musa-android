import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'jam_bounded_http_request.dart';
import 'jam_bounded_tls_listener.dart';
import 'jam_ephemeral_identity.dart';
import 'jam_network_address.dart';
import 'jam_pairing.dart';
import 'jam_queue.dart';
import 'jam_session.dart';
import 'jam_track_reference.dart';
import 'jam_transport_limits.dart';

/// Experimental transport, loopback by default. Identity and pin distribution
/// are the caller's responsibility; no application code starts this server.
class JamBoundedServer {
  JamBoundedServer._(this._session, this._certificateSha256, this._address)
    : _host = _session.hostId;
  final String _host;
  final String? _certificateSha256;
  final InternetAddress _address;
  final JamSession _session;
  final JamPairing _pairing = JamPairing();
  late final JamBoundedTlsListener _listener;
  bool _closed = false;
  Future<void>? _closeFuture;

  static Future<JamBoundedServer> start({
    required SecurityContext identity,
    JamSession? session,
    InternetAddress? address,
  }) async {
    if (session?.isClosed ?? false) throw StateError('Session closed');
    final server = JamBoundedServer._(
      session ?? JamSession(hostId: _secret()),
      null,
      validateJamAddress(address ?? InternetAddress.loopbackIPv4),
    );
    server._listener = await JamBoundedTlsListener.start(
      identity: identity,
      address: server._address,
      handler: server._handle,
    );
    return server;
  }

  /// Creates a fresh identity for this server. The invitation must be
  /// delivered through an authenticated, confidential channel.
  static Future<JamBoundedServer> startEphemeral({
    JamSession? session,
    InternetAddress? address,
  }) async {
    if (session?.isClosed ?? false) throw StateError('Session closed');
    final identity = JamEphemeralIdentity.generate();
    final server = JamBoundedServer._(
      session ?? JamSession(hostId: _secret()),
      identity.certificateSha256,
      validateJamAddress(address ?? InternetAddress.loopbackIPv4),
    );
    server._listener = await JamBoundedTlsListener.start(
      identity: identity.context,
      address: server._address,
      handler: server._handle,
    );
    return server;
  }

  int get port => _listener.port;
  Uri get endpoint => Uri(scheme: 'https', host: _address.address, port: port);
  JamQueue get snapshot => _session.snapshot;
  String issueGrant() {
    if (_closed) throw StateError('Server closed');
    return _pairing.issue();
  }

  JamInvitation issueInvitation({
    Duration lifetime = const Duration(minutes: 2),
  }) {
    if (_closed) throw StateError('Server closed');
    final pin = _certificateSha256;
    if (pin == null) throw StateError('Identity was supplied externally');
    return JamInvitation._(endpoint, pin, _pairing.issue(lifetime: lifetime));
  }

  bool revoke(String credential) {
    if (_closed) return false;
    final actor = _pairing.authenticateGuest(credential);
    if (actor == null || !_pairing.revoke(credential)) return false;
    return _session
            .revokeGuest(authenticatedActorId: _host, guestId: actor)
            .outcome ==
        JamOutcome.applied;
  }

  JamOutcome setGuestEditing(bool enabled) {
    if (_closed) throw StateError('Server closed');
    return _session
        .submit(
          authenticatedActorId: _host,
          command: SetGuestEditing(
            _secret(),
            _host,
            snapshot.revision,
            enabled,
          ),
        )
        .outcome;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    _pairing.close();
    await _listener.close();
  }

  static String _secret() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Future<void> _handle(
    RawSecureSocket socket,
    JamConnectionCancellation cancellation,
  ) async {
    var status = 200;
    Object payload = <String, Object>{};
    JamBoundedHttpRequest? request;
    try {
      final req = await JamBoundedHttpRequest.read(
        socket,
        cancellation,
        keepSocketOpen: true,
      );
      request = req;
      cancellation.throwIfCancelled();
      if (_closed) return;
      if (req.headers['host'] != '${_address.address}:$port' ||
          req.headers.containsKey('origin') ||
          req.headers.containsKey('referer')) {
        status = 403;
      } else if (req.target != '/pair' && req.target != '/queue') {
        status = 404;
      } else {
        final auth = req.headers['authorization'] ?? '';
        final token = auth.startsWith('Bearer ') ? auth.substring(7) : '';
        final actor = _pairing.authenticateGuest(token);
        if (req.target == '/queue' && actor == null) {
          status = 401;
        } else if (req.target == '/queue' &&
            req.method == 'GET' &&
            req.body.isEmpty) {
          payload = _snapshot();
        } else if (req.method != 'POST' ||
            req.headers['content-type'] != 'application/json') {
          status = 405;
        } else {
          final value = jsonDecode(utf8.decode(req.body));
          if (value is! Map<String, dynamic>) throw const FormatException();
          cancellation.throwIfCancelled();
          if (_closed) return;
          if (req.target == '/pair') {
            if (value.length != 1 || value['grant'] is! String) {
              throw const FormatException();
            }
            final credential = _pairing.redeem(value['grant'] as String);
            if (credential == null) {
              status = 401;
            } else {
              final guest = _pairing.authenticateGuest(credential)!;
              final result = _session.submit(
                authenticatedActorId: _host,
                command: SetJamGuest(
                  _secret(),
                  _host,
                  snapshot.revision,
                  guest,
                  true,
                ),
              );
              if (result.outcome != JamOutcome.applied) {
                _pairing.revoke(credential);
                status = 503;
              } else {
                payload = {'credential': credential};
              }
            }
          } else {
            if (_pairing.authenticateGuest(token) != actor) {
              status = 401;
            } else {
              final command = _command(value, actor!);
              cancellation.throwIfCancelled();
              if (_closed) return;
              final result = await _session.submitRemote(
                authenticatedActorId: actor,
                command: command,
                isAuthorized: () =>
                    !_closed &&
                    !cancellation.isCancelled &&
                    _pairing.authenticateGuest(token) == actor,
              );
              if (result.outcome == JamOutcome.conflict) status = 409;
              payload = {'outcome': result.outcome.name, ..._snapshot()};
            }
          }
        }
      }
    } on FormatException {
      status = 400;
    } on TimeoutException {
      status = 408;
    } catch (_) {
      return;
    }
    if (request == null) return;
    if (_closed || cancellation.isCancelled) {
      await request.responseSubscription?.cancel();
      return;
    }
    await _respond(
      socket,
      cancellation,
      request.responseSubscription!,
      status,
      payload,
    );
  }

  JamCommand _command(Map<String, dynamic> v, String actor) {
    if (v['id'] is! String ||
        v['revision'] is! int ||
        v['type'] is! String ||
        v.containsKey('actorId')) {
      throw const FormatException();
    }
    final id = v['id'] as String;
    final rev = v['revision'] as int;
    final occurrence = v['occurrenceId'];
    if (occurrence is! String) throw const FormatException();
    switch (v['type']) {
      case 'add':
        if (v['trackId'] is! String) throw const FormatException();
        // Remote peers propose portable identities, never local host tokens.
        // Preserve the original encoding for command fingerprint/idempotency.
        if (JamTrackReference.tryDecode(v['trackId'] as String) == null) {
          throw const FormatException();
        }
        return AddJamEntry(id, actor, rev, occurrence, v['trackId'] as String);
      case 'move':
        if (v['beforeOccurrenceId'] != null &&
            v['beforeOccurrenceId'] is! String) {
          throw const FormatException();
        }
        return MoveJamEntry(
          id,
          actor,
          rev,
          occurrence,
          v['beforeOccurrenceId'] as String?,
        );
      case 'remove':
        return RemoveJamEntry(id, actor, rev, occurrence);
      default:
        throw const FormatException();
    }
  }

  Map<String, Object?> _snapshot() => {
    'revision': snapshot.revision,
    'currentOccurrenceId': snapshot.currentOccurrenceId,
    'pendingOccurrenceId': snapshot.pendingOccurrenceId,
    'guestEditingEnabled': snapshot.guestEditingEnabled,
    'entries': snapshot.entries
        .map((e) => {'occurrenceId': e.occurrenceId, 'trackId': e.trackId})
        .toList(),
  };

  Future<void> _respond(
    RawSecureSocket socket,
    JamConnectionCancellation cancellation,
    StreamSubscription<RawSocketEvent> subscription,
    int status,
    Object payload,
  ) async {
    final body = utf8.encode(jsonEncode(payload));
    if (body.length > jamMaxResponseBytes) {
      throw StateError('Jam response exceeds byte limit');
    }
    final headers = ascii.encode(
      'HTTP/1.1 $status ${status == 200 ? 'OK' : 'Error'}\r\nContent-Type: application/json\r\nCache-Control: no-store\r\nConnection: close\r\nContent-Length: ${body.length}\r\n\r\n',
    );
    final parts = [headers, body];
    var part = 0;
    var offset = 0;
    final done = Completer<void>();
    final peerClosed = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
      if (!peerClosed.isCompleted) peerClosed.complete();
    }

    void write() {
      if (cancellation.isCancelled) {
        finish();
        return;
      }
      while (part < parts.length) {
        final bytes = parts[part];
        final count = socket.write(bytes, offset);
        if (count == 0) {
          socket.writeEventsEnabled = true;
          return;
        }
        offset += count;
        if (offset == bytes.length) {
          part++;
          offset = 0;
        }
      }
      if (!done.isCompleted) done.complete();
    }

    subscription.onData((event) {
      try {
        if (event == RawSocketEvent.write) {
          socket.writeEventsEnabled = false;
          write();
        }
        if (event == RawSocketEvent.closed) {
          if (!done.isCompleted) done.complete();
        }
        if (event == RawSocketEvent.closed ||
            event == RawSocketEvent.readClosed) {
          if (!peerClosed.isCompleted) peerClosed.complete();
        }
      } catch (_) {
        // Socket operations can fail after an abrupt peer disconnect. Never
        // let a stream callback throw outside the owning connection task.
        finish();
      }
    });
    subscription.onError((Object _) => finish());
    subscription.onDone(finish);
    unawaited(cancellation.cancelled.then((_) => finish()));
    try {
      subscription.resume();
      write();
      await done.future;
      if (!cancellation.isCancelled) {
        socket.shutdown(SocketDirection.send);
        await peerClosed.future.timeout(
          const Duration(seconds: 1),
          onTimeout: () {},
        );
      }
    } catch (_) {
      finish();
    } finally {
      await subscription.cancel();
    }
  }
}

/// Contains a bearer secret: do not log, persist, or put it in a URL.
class JamInvitation {
  const JamInvitation._(this.endpoint, this.certificateSha256, this.grant);
  final Uri endpoint;
  final String certificateSha256;
  final String grant;
}
