import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';

const _pin = '89c840e396a5c37ea4bb79a4d1b7dba919b3fe76c05732c1e79c8e6164679b3e';

void main() {
  late HttpServer server;
  late Uri endpoint;
  var redirectLocation = '/target';

  setUp(() async {
    redirectLocation = '/target';
    final context = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    endpoint = Uri.parse('https://127.0.0.1:${server.port}');
    server.listen((request) async {
      if (request.uri.path == '/wait') {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        request.response.write('ok');
        await request.response.close();
        return;
      }
      if (request.uri.path == '/drip') {
        try {
          for (var i = 0; i < 30; i++) {
            request.response.write('x');
            await request.response.flush();
            await Future<void>.delayed(const Duration(milliseconds: 30));
          }
          await request.response.close();
        } catch (_) {
          // The client closes the timed-out connection.
        }
        return;
      }
      if (request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          redirectLocation,
        );
      } else {
        request.response.write('ok');
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('accepts matching certificate during real TLS handshake', () async {
    final client = JamPinnedClient(endpoint, _pin);
    addTearDown(client.close);
    final response = await client.send('GET', '/queue');
    expect(response.statusCode, HttpStatus.ok);
  });

  test('rejects a different pin during real TLS handshake', () async {
    final client = JamPinnedClient(endpoint, '0' * 64);
    addTearDown(client.close);
    await expectLater(
      client.send('GET', '/queue'),
      throwsA(isA<HandshakeException>()),
    );
  });

  test('does not follow redirects even on the pinned server', () async {
    final client = JamPinnedClient(endpoint, _pin);
    addTearDown(client.close);
    final response = await client.send('GET', '/redirect', bearer: 'test');
    expect(response.statusCode, HttpStatus.found);
    expect(response.location, '/target');
  });

  test(
    'does not send credentials to a redirect outside the pinned endpoint',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final other = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => other.close(force: true));
      var received = false;
      other.listen((request) async {
        received = true;
        await request.response.close();
      });
      redirectLocation = 'https://127.0.0.1:${other.port}/steal';
      final client = JamPinnedClient(endpoint, _pin);
      addTearDown(client.close);
      final response = await client.send('GET', '/redirect', bearer: 'secret');
      expect(response.statusCode, HttpStatus.found);
      expect(response.location, redirectLocation);
      expect(received, isFalse);
    },
  );

  test(
    'total deadline stops a dripping body without cancelling another request',
    () async {
      final client = JamPinnedClient(
        endpoint,
        _pin,
        deadline: const Duration(milliseconds: 300),
      );
      addTearDown(client.close);
      final slow = client.send('GET', '/drip');
      final fast = await client.send('GET', '/queue');
      expect(fast.statusCode, HttpStatus.ok);
      await expectLater(slow, throwsA(isA<TimeoutException>()));
      expect((await client.send('GET', '/queue')).statusCode, HttpStatus.ok);
    },
  );

  test('total deadline includes a stalled TLS handshake', () async {
    final socketServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final sockets = <Socket>[];
    socketServer.listen(sockets.add);
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await socketServer.close();
    });
    final client = JamPinnedClient(
      Uri.parse('https://127.0.0.1:${socketServer.port}'),
      _pin,
      deadline: const Duration(milliseconds: 300),
    );
    addTearDown(client.close);
    await expectLater(
      client.send('GET', '/queue'),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('an active request survives another request timing out', () async {
    final client = JamPinnedClient(
      endpoint,
      _pin,
      deadline: const Duration(milliseconds: 500),
    );
    addTearDown(client.close);
    final slowResult = expectLater(
      client.send('GET', '/drip'),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final other = client.send('GET', '/wait');
    await slowResult;
    expect((await other).statusCode, HttpStatus.ok);
  });

  test('close interrupts a response body and rejects later sends', () async {
    final client = JamPinnedClient(endpoint, _pin);
    final pending = client.send('GET', '/drip');
    final failed = expectLater(pending, throwsA(anything));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    client.close();
    await failed;
    await expectLater(client.send('GET', '/queue'), throwsStateError);
  });

  test('close interrupts a stalled handshake', () async {
    final socketServer = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final accepted = Completer<void>();
    final sockets = <Socket>[];
    socketServer.listen((socket) {
      sockets.add(socket);
      accepted.complete();
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await socketServer.close();
    });
    final client = JamPinnedClient(
      Uri.parse('https://127.0.0.1:${socketServer.port}'),
      _pin,
    );
    final failed = expectLater(client.send('GET', '/queue'), throwsA(anything));
    await accepted.future;
    client.close();
    await failed;
    await expectLater(client.send('GET', '/queue'), throwsStateError);
  });
}
