import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_local_server.dart';
import '../support/jam_track_fixture.dart';

void main() {
  test(
    'two clients race and revocation denies only the revoked client',
    () async {
      final server = await JamLocalServer.start();
      final a = server.invite()!;
      final b = server.invite()!;
      final ca = HttpClient();
      final cb = HttpClient();
      Future<(int, Map<String, dynamic>)> send(
        HttpClient client,
        String token, {
        Map<String, Object>? body,
        String? origin,
      }) async {
        final req = body == null
            ? await client.getUrl(server.endpoint.resolve('/queue'))
            : await client.postUrl(server.endpoint.resolve('/queue'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        if (origin != null) req.headers.set('Origin', origin);
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final text = await utf8.decoder.bind(res).join();
        return (
          res.statusCode,
          text.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(text) as Map<String, dynamic>,
        );
      }

      try {
        expect((await send(ca, a)).$2['revision'], 2);
        final results = await Future.wait([
          send(
            ca,
            a,
            body: {
              'id': 'a',
              'revision': 2,
              'type': 'add',
              'occurrenceId': 'one',
              'trackId': jamTestTrack('t1'),
            },
          ),
          send(
            cb,
            b,
            body: {
              'id': 'b',
              'revision': 2,
              'type': 'add',
              'occurrenceId': 'two',
              'trackId': jamTestTrack('t2'),
            },
          ),
        ]);
        expect(results.map((r) => r.$2['outcome']).toSet(), {
          'applied',
          'conflict',
        });
        expect(results.map((r) => r.$1).toSet(), {
          HttpStatus.ok,
          HttpStatus.conflict,
        });
        expect((await send(cb, b)).$2['entries'], hasLength(1));
        expect(
          (await send(ca, a, origin: 'https://example.com')).$1,
          HttpStatus.forbidden,
        );
        expect(
          (await send(
            ca,
            a,
            body: {
              'id': 'x',
              'revision': 3,
              'type': 'add',
              'actorId': 'host',
              'occurrenceId': 'x',
              'trackId': jamTestTrack('x'),
            },
          )).$1,
          HttpStatus.badRequest,
        );
        expect(server.revoke(a), isTrue);
        expect((await send(ca, a)).$1, HttpStatus.unauthorized);
        expect((await send(cb, b)).$1, HttpStatus.ok);
      } finally {
        ca.close(force: true);
        cb.close(force: true);
        await server.close();
      }
    },
  );

  test('rejects untrusted Host and oversized bodies', () async {
    final server = await JamLocalServer.start();
    final token = server.invite()!;
    final client = HttpClient();
    try {
      final socket = await Socket.connect('127.0.0.1', server.endpoint.port);
      socket.write(
        'GET /queue HTTP/1.1\r\nHost: attacker.example:${server.endpoint.port}\r\nAuthorization: Bearer $token\r\nConnection: close\r\n\r\n',
      );
      final rejected = await utf8.decoder.bind(socket).join();
      expect(rejected, contains('403'));
      final oversized = await client.postUrl(server.endpoint.resolve('/queue'));
      oversized.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      oversized.headers.contentType = ContentType.json;
      oversized.write('x' * 5000);
      try {
        expect(
          (await oversized.close()).statusCode,
          HttpStatus.requestEntityTooLarge,
        );
      } on HttpException {
        // Closing before consuming the oversized request also rejects it.
      }
      expect(server.snapshot.revision, 1);
    } finally {
      client.close(force: true);
      await server.close();
    }
  });

  test('revocation works when the accepted command ledger is full', () async {
    final server = await JamLocalServer.start();
    final token = server.invite()!;
    final client = HttpClient();
    try {
      for (var i = 0; i < 9999; i++) {
        final req = await client.postUrl(server.endpoint.resolve('/queue'));
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        req.headers.contentType = ContentType.json;
        req.write(
          jsonEncode({
            'id': 'cmd$i',
            'revision': i + 1,
            'type': i.isEven ? 'add' : 'remove',
            'occurrenceId': 'item',
            if (i.isEven) 'trackId': jamTestTrack('track'),
          }),
        );
        final res = await req.close();
        await res.drain<void>();
        expect(res.statusCode, HttpStatus.ok);
      }
      expect(server.revoke(token), isTrue);
      final req = await client.getUrl(server.endpoint.resolve('/queue'));
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
      final res = await req.close();
      expect(res.statusCode, HttpStatus.unauthorized);
      await res.drain<void>();
    } finally {
      client.close(force: true);
      await server.close();
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
