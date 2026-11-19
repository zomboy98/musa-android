import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_tls_server.dart';
import 'support/jam_track_fixture.dart';

const _pin = '89c840e396a5c37ea4bb79a4d1b7dba919b3fe76c05732c1e79c8e6164679b3e';

void main() {
  test(
    'abrupt TLS client disconnect and server close do not leak errors',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final server = await JamTlsServer.start(
        address: InternetAddress.loopbackIPv4,
        identity: identity,
      );
      final socket = await SecureSocket.connect(
        '127.0.0.1',
        server.endpoint.port,
        onBadCertificate: (_) => true,
      );
      socket.write(
        'POST /pair HTTP/1.1\r\nHost: 127.0.0.1:${server.endpoint.port}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{',
      );
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      socket.destroy();
      await server.close();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    },
  );
  test('LAN binding is unavailable until pre-HTTP limits exist', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    await expectLater(
      JamTlsServer.start(
        address: InternetAddress('192.168.1.1'),
        identity: identity,
      ),
      throwsUnsupportedError,
    );
  });

  test(
    'real TLS pairing is single use and guest permissions are enforced',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final server = await JamTlsServer.start(
        address: InternetAddress.loopbackIPv4,
        identity: identity,
      );
      addTearDown(server.close);
      final client = JamPinnedClient(server.endpoint, _pin);
      addTearDown(client.close);
      final badPin = JamPinnedClient(server.endpoint, '0' * 64);
      addTearDown(badPin.close);
      await expectLater(
        badPin.send('GET', '/queue'),
        throwsA(isA<HandshakeException>()),
      );
      final grant = server.issueGrant();
      final body = utf8.encode(jsonEncode({'grant': grant}));
      final results = await Future.wait([
        client.send('POST', '/pair', body: body),
        client.send('POST', '/pair', body: body),
      ]);
      expect(results.map((r) => r.statusCode).toSet(), {200, 401});
      final token =
          (jsonDecode(
                    utf8.decode(
                      results.firstWhere((r) => r.statusCode == 200).body,
                    ),
                  )
                  as Map)['credential']
              as String;
      expect(
        (await client.send('GET', '/queue', bearer: token)).statusCode,
        200,
      );
      expect(server.setGuestEditing(false), JamOutcome.applied);
      final add = await client.send(
        'POST',
        '/queue',
        bearer: token,
        body: utf8.encode(
          jsonEncode({
            'id': 'one',
            'revision': server.snapshot.revision,
            'type': 'add',
            'occurrenceId': 'o',
            'trackId': jamTestTrack('t'),
          }),
        ),
      );
      expect((jsonDecode(utf8.decode(add.body)) as Map)['outcome'], 'applied');
      final remove = await client.send(
        'POST',
        '/queue',
        bearer: token,
        body: utf8.encode(
          jsonEncode({
            'id': 'two',
            'revision': server.snapshot.revision,
            'type': 'remove',
            'occurrenceId': 'o',
          }),
        ),
      );
      expect(
        (jsonDecode(utf8.decode(remove.body)) as Map)['outcome'],
        'forbidden',
      );
      expect(server.revoke(token), isTrue);
      expect(
        (await client.send('GET', '/queue', bearer: token)).statusCode,
        401,
      );
    },
  );
}
