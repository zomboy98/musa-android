import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'jam_queue.dart';
import 'jam_session.dart';
import 'jam_track_reference.dart';

/// Loopback-only, in-memory queue transport. No audio or playback controls.
class JamLocalServer {
  JamLocalServer._(this._server, this._session, this._host) {
    _server.listen((request) {
      unawaited(_handle(request).catchError((Object _, StackTrace _) {}));
    }, onError: (Object _, StackTrace _) {});
  }
  static Future<JamLocalServer> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final host = _id();
    return JamLocalServer._(server, JamSession(hostId: host), host);
  }

  final HttpServer _server;
  final JamSession _session;
  final String _host;
  final Map<String, String> _credentials = {};
  static const _maxActiveRequests = 32;
  static const _maxBodyBytes = 4096;
  static const _bodyDeadline = Duration(seconds: 5);
  int _activeRequests = 0;
  Uri get endpoint =>
      Uri(scheme: 'http', host: '127.0.0.1', port: _server.port);
  JamQueue get snapshot => _session.snapshot;
  static String _id() {
    final random = Random.secure();
    return base64Url
        .encode(List.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  /// Local host action: create a distinct guest and bearer credential.
  String? invite() {
    final actor = _id();
    final result = _session.submit(
      authenticatedActorId: _host,
      command: SetJamGuest(_id(), _host, snapshot.revision, actor, true),
    );
    if (result.outcome != JamOutcome.applied) return null;
    final token = _id();
    _credentials[token] = actor;
    return token;
  }

  bool revoke(String token) {
    // Invalidate first even when the queue cannot record another command.
    final actor = _credentials.remove(token);
    if (actor == null) return false;
    return _session
            .revokeGuest(authenticatedActorId: _host, guestId: actor)
            .outcome ==
        JamOutcome.applied;
  }

  Future<void> close() async {
    _credentials.clear();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    StreamIterator<List<int>>? body;
    if (_activeRequests >= _maxActiveRequests) {
      response.statusCode = HttpStatus.serviceUnavailable;
      await response.close();
      return;
    }
    _activeRequests++;
    response.headers.set('Cache-Control', 'no-store');
    response.headers.contentType = ContentType.json;
    try {
      if (request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:${_server.port}' ||
          request.headers.value('origin') != null ||
          request.headers.value('referer') != null) {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      final auth = request.headers.value(HttpHeaders.authorizationHeader);
      final token = auth != null && auth.startsWith('Bearer ')
          ? auth.substring(7)
          : '';
      final actor = _credentials[token];
      if (actor == null) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      if (request.uri.path != '/queue' || request.uri.hasQuery) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (request.method == 'GET') {
        response.write(jsonEncode(_snapshot()));
        return;
      }
      if (request.method != 'POST' ||
          request.headers.contentType?.mimeType != 'application/json') {
        response.statusCode = HttpStatus.methodNotAllowed;
        return;
      }
      if (request.contentLength > _maxBodyBytes) {
        response.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
      body = StreamIterator<List<int>>(request);
      final bytes = await _readBody(body);
      if (_credentials[token] != actor) {
        response.statusCode = HttpStatus.unauthorized;
        return;
      }
      final v = jsonDecode(utf8.decode(bytes));
      if (v is! Map<String, dynamic> ||
          v['id'] is! String ||
          v['revision'] is! int ||
          v['type'] is! String ||
          v.containsKey('actorId')) {
        throw const FormatException();
      }
      final id = v['id'] as String;
      final revision = v['revision'] as int;
      final occurrence = v['occurrenceId'];
      JamCommand command;
      switch (v['type']) {
        case 'add':
          if (occurrence is! String || v['trackId'] is! String) {
            throw const FormatException();
          }
          // Apply the same remote identity boundary as the TLS transports.
          if (JamTrackReference.tryDecode(v['trackId'] as String) == null) {
            throw const FormatException();
          }
          command = AddJamEntry(
            id,
            actor,
            revision,
            occurrence,
            v['trackId'] as String,
          );
        case 'move':
          if (occurrence is! String ||
              (v['beforeOccurrenceId'] != null &&
                  v['beforeOccurrenceId'] is! String)) {
            throw const FormatException();
          }
          command = MoveJamEntry(
            id,
            actor,
            revision,
            occurrence,
            v['beforeOccurrenceId'] as String?,
          );
        case 'remove':
          if (occurrence is! String) throw const FormatException();
          command = RemoveJamEntry(id, actor, revision, occurrence);
        default:
          throw const FormatException();
      }
      final result = await _session.submitRemote(
        authenticatedActorId: actor,
        command: command,
        isAuthorized: () => _credentials[token] == actor,
      );
      if (result.outcome == JamOutcome.conflict) {
        response.statusCode = HttpStatus.conflict;
      }
      response.write(
        jsonEncode({'outcome': result.outcome.name, ..._snapshot()}),
      );
    } on _BodyTooLarge {
      response.statusCode = HttpStatus.requestEntityTooLarge;
    } on FormatException {
      response.statusCode = HttpStatus.badRequest;
    } on TimeoutException {
      response.statusCode = HttpStatus.requestTimeout;
    } catch (_) {
      response.statusCode = HttpStatus.internalServerError;
    } finally {
      try {
        // Cancelling an unfinished request body first tears down its socket,
        // preventing the client from receiving the rejection (408 or 413).
        await response.close();
      } finally {
        try {
          await body?.cancel();
        } finally {
          _activeRequests--;
        }
      }
    }
  }

  Future<List<int>> _readBody(StreamIterator<List<int>> iterator) async {
    final stopwatch = Stopwatch()..start();
    final bytes = <int>[];
    while (true) {
      final remaining = _bodyDeadline - stopwatch.elapsed;
      if (remaining <= Duration.zero) throw TimeoutException('Body deadline');
      if (!await iterator.moveNext().timeout(remaining)) break;
      final chunk = iterator.current;
      if (chunk.length > _maxBodyBytes - bytes.length) throw _BodyTooLarge();
      bytes.addAll(chunk);
    }
    return bytes;
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

class _BodyTooLarge implements Exception {}
