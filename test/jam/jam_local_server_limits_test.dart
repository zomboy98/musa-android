import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_local_server.dart';

// Real sockets exercise transport admission and cancellation, including bodies
// that never finish. Removing the limit/deadline makes these assertions fail.
class PendingBody {
  PendingBody(this.socket) {
    reply = utf8.decoder.bind(socket).join();
  }
  final Socket socket;
  late final Future<String> reply;

  static Future<PendingBody> open(JamLocalServer server, String token) async {
    final pending = PendingBody(
      await Socket.connect('127.0.0.1', server.endpoint.port),
    );
    pending.socket.write(
      'POST /queue HTTP/1.1\r\n'
      'Host: 127.0.0.1:${server.endpoint.port}\r\n'
      'Authorization: Bearer $token\r\n'
      'Content-Type: application/json\r\n'
      'Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n',
    );
    await pending.socket.flush();
    return pending;
  }

  void chunk(String body) {
    socket.write('${utf8.encode(body).length.toRadixString(16)}\r\n$body\r\n');
  }
}

Future<int> getStatus(JamLocalServer server, String token) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(server.endpoint.resolve('/queue'));
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
    '32 incomplete bodies saturate admission and release every slot',
    () async {
      final server = await JamLocalServer.start();
      final token = server.invite()!;
      final pending = <PendingBody>[];
      try {
        for (var i = 0; i < 32; i++) {
          pending.add(await PendingBody.open(server, token));
        }
        // The probe follows all headers on the loopback event queue.
        expect(await getStatus(server, token), HttpStatus.serviceUnavailable);
        for (final body in pending) {
          body.socket.write('0\r\n\r\n');
        }
        final replies = await Future.wait(
          pending.map((body) => body.reply),
        ).timeout(const Duration(seconds: 3));
        expect(replies, everyElement(contains('400 Bad Request')));
        expect(await getStatus(server, token), HttpStatus.ok);
      } finally {
        for (final body in pending) {
          body.socket.destroy();
        }
        await server.close();
      }
    },
  );

  test(
    'dripping body has an absolute deadline and releases admission',
    () async {
      final server = await JamLocalServer.start();
      final token = server.invite()!;
      final pending = await PendingBody.open(server, token);
      final watch = Stopwatch()..start();
      final drip = Timer.periodic(const Duration(milliseconds: 300), (_) {
        pending.chunk(' ');
      });
      try {
        final reply = await pending.reply.timeout(const Duration(seconds: 7));
        expect(reply, startsWith('HTTP/1.1 408 '));
        expect(watch.elapsed, greaterThan(const Duration(seconds: 4)));
        expect(watch.elapsed, lessThan(const Duration(seconds: 7)));
        expect(await getStatus(server, token), HttpStatus.ok);
        expect(server.snapshot.revision, 1);
      } finally {
        drip.cancel();
        pending.socket.destroy();
        await server.close();
      }
    },
  );

  test(
    'revoking a credential during upload prevents its queued mutation',
    () async {
      final server = await JamLocalServer.start();
      final token = server.invite()!;
      final pending = await PendingBody.open(server, token);
      try {
        pending.chunk('{');
        // Ensure the handler passed authentication and is waiting on the body.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(server.revoke(token), isTrue);
        pending.chunk(
          '"id":"x","revision":2,"type":"add",'
          '"occurrenceId":"x","trackId":"x"}',
        );
        pending.socket.write('0\r\n\r\n');
        expect(await pending.reply, contains('401 Unauthorized'));
        expect(server.snapshot.entries, isEmpty);
      } finally {
        pending.socket.destroy();
        await server.close();
      }
    },
  );

  test(
    'chunked body limit rejects unknown lengths without a mutation',
    () async {
      final server = await JamLocalServer.start();
      final token = server.invite()!;
      final pending = await PendingBody.open(server, token);
      try {
        pending.chunk(' ' * 4097);
        expect(
          await pending.reply.timeout(const Duration(seconds: 2)),
          startsWith('HTTP/1.1 413 '),
        );
        expect(server.snapshot.revision, 1);
        expect(await getStatus(server, token), HttpStatus.ok);
      } finally {
        pending.socket.destroy();
        await server.close();
      }
    },
  );

  test(
    'close terminates incomplete uploads and stops accepting sockets',
    () async {
      final server = await JamLocalServer.start();
      final endpoint = server.endpoint;
      final pending = await PendingBody.open(server, server.invite()!);
      try {
        pending.chunk('{');
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await server.close().timeout(const Duration(seconds: 2));
        await pending.reply.timeout(const Duration(seconds: 2));
        await expectLater(
          Socket.connect(endpoint.host, endpoint.port),
          throwsA(isA<SocketException>()),
        );
      } finally {
        pending.socket.destroy();
      }
    },
  );
}
