import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_server.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'support/jam_track_fixture.dart';

void main() {
  test('closing during incomplete request prevents later mutation', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final server = await JamBoundedServer.start(identity: identity);
    final grant = server.issueGrant();
    final client = await SecureSocket.connect(
      '127.0.0.1',
      server.port,
      onBadCertificate: (_) => true,
    );
    client.write(
      'POST /pair HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{"grant":"$grant"',
    );
    await client.flush();
    await server.close();
    final revision = server.snapshot.revision;
    await client.drain<void>().timeout(const Duration(seconds: 2));
    expect(server.snapshot.revision, revision);
    expect(revision, 0);
    client.destroy();
  });
  test('two real TLS clients pair, edit, conflict and revoke', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final server = await JamBoundedServer.start(identity: identity);
    addTearDown(server.close);
    Future<(int, Map<String, dynamic>)> request(
      String path, {
      String? token,
      Map<String, Object>? data,
    }) async {
      final client = await SecureSocket.connect(
        '127.0.0.1',
        server.port,
        onBadCertificate: (_) => true,
      );
      final body = data == null ? '' : jsonEncode(data);
      client.write(
        '${data == null ? 'GET' : 'POST'} $path HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\n${token == null ? '' : 'Authorization: Bearer $token\r\n'}${data == null ? '' : 'Content-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n'}\r\n$body',
      );
      await client.flush();
      final response = await utf8.decoder
          .bind(client)
          .join()
          .timeout(const Duration(seconds: 4));
      client.destroy();
      final parts = response.split('\r\n\r\n');
      return (
        int.parse(parts.first.split(' ')[1]),
        jsonDecode(parts[1]) as Map<String, dynamic>,
      );
    }

    final first =
        (await request(
              '/pair',
              data: {'grant': server.issueGrant()},
            )).$2['credential']
            as String;
    final second =
        (await request(
              '/pair',
              data: {'grant': server.issueGrant()},
            )).$2['credential']
            as String;
    // Disconnect peers immediately after a complete request; subsequent
    // authenticated requests must still work and no zone error may escape.
    for (var i = 0; i < 8; i++) {
      final abrupt = await SecureSocket.connect(
        '127.0.0.1',
        server.port,
        onBadCertificate: (_) => true,
      );
      abrupt.write(
        'GET /queue HTTP/1.1\r\nHost: 127.0.0.1:${server.port}\r\nAuthorization: Bearer $first\r\n\r\n',
      );
      await abrupt.flush();
      abrupt.destroy();
    }
    final revision =
        (await request('/queue', token: first)).$2['revision'] as int;
    final add = await request(
      '/queue',
      token: first,
      data: {
        'id': 'one',
        'revision': revision,
        'type': 'add',
        'occurrenceId': 'o',
        'trackId': jamTestTrack('t'),
      },
    );
    expect(add.$2['outcome'], 'applied');
    final stale = await request(
      '/queue',
      token: second,
      data: {
        'id': 'two',
        'revision': revision,
        'type': 'remove',
        'occurrenceId': 'o',
      },
    );
    expect(stale.$1, 409);
    expect(server.setGuestEditing(false), JamOutcome.applied);
    final denied = await request(
      '/queue',
      token: second,
      data: {
        'id': 'three',
        'revision': server.snapshot.revision,
        'type': 'remove',
        'occurrenceId': 'o',
      },
    );
    expect(denied.$2['outcome'], 'forbidden');
    expect(server.revoke(first), isTrue);
    expect((await request('/queue', token: first)).$1, 401);
    expect(
      (await request('/queue', token: second)).$2['entries'],
      hasLength(1),
    );
    await server.close();
    final closedRevision = server.snapshot.revision;
    expect(() => server.issueGrant(), throwsStateError);
    expect(server.revoke(second), isFalse);
    expect(server.snapshot.revision, closedRevision);
  });
}
