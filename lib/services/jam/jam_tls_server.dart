import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'jam_pairing.dart';
import 'jam_queue.dart';
import 'jam_session.dart';
import 'jam_track_reference.dart';

/// Opt-in transport. The caller must securely provision the certificate and
/// private key and transfer the matching certificate pin and grant out of band.
/// Nothing in the application starts this server automatically. Non-loopback
/// binding is disabled until pre-HTTP socket and TLS handshake limits exist.
class JamTlsServer {
  JamTlsServer._(this._server, this._address, this._session, this._host) {
    _server.listen((request) {
      // Stream callbacks do not await futures; a peer can disconnect while a
      // response or body is closing, so consume that failure explicitly.
      unawaited(_handle(request).catchError((Object _, StackTrace _) {}));
    }, onError: (Object _, StackTrace _) {});
  }

  /// Binds only the specified, concrete IPv4 address. Never use an identity
  /// from an untrusted network or a certificate whose private key is public.
  static Future<JamTlsServer> start({
    required InternetAddress address,
    required SecurityContext identity,
  }) async {
    final bytes = address.rawAddress;
    final privateV4 =
        address.type == InternetAddressType.IPv4 &&
        (bytes[0] == 10 ||
            bytes[0] == 127 ||
            bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31 ||
            bytes[0] == 192 && bytes[1] == 168 ||
            bytes[0] == 169 && bytes[1] == 254);
    if (!privateV4) {
      throw ArgumentError.value(address, 'address');
    }
    if (!address.isLoopback) {
      throw UnsupportedError(
        'LAN transport requires pre-HTTP connection limits',
      );
    }
    final server = await HttpServer.bindSecure(address, 0, identity);
    final host = _secret();
    return JamTlsServer._(server, address, JamSession(hostId: host), host);
  }

  final HttpServer _server;
  final InternetAddress _address;
  final JamSession _session;
  final String _host;
  final _pairing = JamPairing();
  int _active = 0;
  bool _closed = false;

  Uri get endpoint =>
      Uri(scheme: 'https', host: _address.address, port: _server.port);
  JamQueue get snapshot => _session.snapshot;

  static String _secret() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  String issueGrant({Duration lifetime = const Duration(minutes: 2)}) {
    if (_closed) throw StateError('Server closed');
    return _pairing.issue(lifetime: lifetime);
  }

  bool revoke(String credential) {
    final actor = _pairing.authenticateGuest(credential);
    if (actor == null || !_pairing.revoke(credential)) return false;
    return _session
            .revokeGuest(authenticatedActorId: _host, guestId: actor)
            .outcome ==
        JamOutcome.applied;
  }

  JamOutcome setGuestEditing(bool enabled) => _session
      .submit(
        authenticatedActorId: _host,
        command: SetGuestEditing(_secret(), _host, snapshot.revision, enabled),
      )
      .outcome;

  Future<void> close() async {
    _closed = true;
    _pairing.close();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (_active >= 32) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    _active++;
    StreamIterator<List<int>>? body;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.contentType = ContentType.json;
    try {
      if (request.headers.value(HttpHeaders.hostHeader) !=
              '${_address.address}:${_server.port}' ||
          request.headers.value('origin') != null ||
          request.headers.value('referer') != null) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.uri.hasQuery ||
          request.uri.path != '/pair' && request.uri.path != '/queue') {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      final token = auth != null && auth.startsWith('Bearer ')
          ? auth.substring(7)
          : '';
      final actor = _pairing.authenticateGuest(token);
      if (request.uri.path == '/queue' && actor == null) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.uri.path == '/queue' && request.method == 'GET') {
        response.write(jsonEncode(_snapshot()));
        return;
      }
      if (request.method != 'POST' ||
          request.headers.contentType?.mimeType != 'application/json') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (request.contentLength > 4096) throw const _TooLarge();
      body = StreamIterator<List<int>>(request);
      final bytes = <int>[];
      final stopwatch = Stopwatch()..start();
      while (true) {
        final remaining = const Duration(seconds: 5) - stopwatch.elapsed;
        if (remaining <= Duration.zero) throw TimeoutException('body');
        if (!await body.moveNext().timeout(remaining)) break;
        if (body.current.length > 4096 - bytes.length) throw const _TooLarge();
        bytes.addAll(body.current);
      }
      final value = jsonDecode(utf8.decode(bytes));
      if (value is! Map<String, dynamic>) throw const FormatException();
      if (request.uri.path == '/pair') {
        if (value.length != 1 || value['grant'] is! String) {
          throw const FormatException();
        }
        final credential = _pairing.redeem(value['grant'] as String);
        if (credential == null) {
          response.statusCode = HttpStatus.unauthorized;
          return;
        }
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
          response.statusCode = HttpStatus.serviceUnavailable;
          return;
        }
        response.write(jsonEncode({'credential': credential}));
        return;
      }
      if (_pairing.authenticateGuest(token) != actor) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (value['id'] is! String ||
          value['revision'] is! int ||
          value['type'] is! String ||
          value.containsKey('actorId')) {
        throw const FormatException();
      }
      final id = value['id'] as String;
      final rev = value['revision'] as int;
      final occurrence = value['occurrenceId'];
      final JamCommand command;
      switch (value['type']) {
        case 'add':
          if (occurrence is! String || value['trackId'] is! String) {
            throw const FormatException();
          }
          // Host-only tokens are not capabilities that a guest may add.
          if (JamTrackReference.tryDecode(value['trackId'] as String) == null) {
            throw const FormatException();
          }
          command = AddJamEntry(
            id,
            actor!,
            rev,
            occurrence,
            value['trackId'] as String,
          );
        case 'move':
          if (occurrence is! String ||
              value['beforeOccurrenceId'] != null &&
                  value['beforeOccurrenceId'] is! String) {
            throw const FormatException();
          }
          command = MoveJamEntry(
            id,
            actor!,
            rev,
            occurrence,
            value['beforeOccurrenceId'] as String?,
          );
        case 'remove':
          if (occurrence is! String) throw const FormatException();
          command = RemoveJamEntry(id, actor!, rev, occurrence);
        default:
          throw const FormatException();
      }
      final result = await _session.submitRemote(
        authenticatedActorId: actor,
        command: command,
        isAuthorized: () =>
            !_closed && _pairing.authenticateGuest(token) == actor,
      );
      if (result.outcome == JamOutcome.conflict) {
        response.statusCode = HttpStatus.conflict;
      }
      response.write(
        jsonEncode({'outcome': result.outcome.name, ..._snapshot()}),
      );
    } on _TooLarge {
      response.statusCode = HttpStatus.requestEntityTooLarge;
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } on TimeoutException {
      response.statusCode = HttpStatus.requestTimeout;
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        await response.close();
      } finally {
        try {
          await body?.cancel();
        } finally {
          _active--;
        }
      }
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
}

class _TooLarge implements Exception {
  const _TooLarge();
}
