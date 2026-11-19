import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_server.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';
import 'package:mornye/services/jam/jam_transport_limits.dart';

void main() {
  test('maximal escaped queue is delivered after a command', () async {
    final session = JamSession(hostId: 'host');
    addTearDown(session.close);
    for (var i = 0; i < JamQueue.maxEntries; i++) {
      final prefix = i.toString().padLeft(4, '0');
      final result = session.submit(
        authenticatedActorId: 'host',
        command: AddJamEntry(
          'c$i',
          'host',
          i,
          '$prefix${'\u0001' * 252}',
          '\u0001' * 256,
        ),
      );
      expect(result.outcome, JamOutcome.applied);
    }
    final server = await JamBoundedServer.startEphemeral(session: session);
    addTearDown(server.close);
    final invitation = server.issueInvitation();
    final client = JamPinnedClient(
      invitation.endpoint,
      invitation.certificateSha256,
    );
    addTearDown(client.close);
    final paired = await client.send(
      'POST',
      '/pair',
      body: utf8.encode(jsonEncode({'grant': invitation.grant})),
    );
    final credential =
        (jsonDecode(utf8.decode(paired.body)) as Map)['credential'] as String;
    final result = await client.send(
      'POST',
      '/queue',
      bearer: credential,
      body: utf8.encode(
        jsonEncode({
        'id': 'move',
          'revision': server.snapshot.revision,
        'type': 'move',
        'occurrenceId': '0000${'\u0001' * 252}',
        }),
      ),
    );
    expect(result.statusCode, 200);
    expect(result.body.length, greaterThan(65536));
    expect(result.body.length, lessThanOrEqualTo(jamMaxResponseBytes));
    final payload = jsonDecode(utf8.decode(result.body)) as Map;
    expect(payload['outcome'], 'applied');
    expect(payload['entries'], hasLength(JamQueue.maxEntries));
  });

  test(
    'client accepts the exact byte budget and rejects one byte more',
    () async {
      final context = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final count =
            jamMaxResponseBytes + (request.uri.path == '/over' ? 1 : 0);
        request.response.contentLength = count;
        request.response.add(List<int>.filled(count, 65));
        await request.response.close();
      });
      final client = JamPinnedClient(
        Uri.parse('https://127.0.0.1:${server.port}'),
        '89c840e396a5c37ea4bb79a4d1b7dba919b3fe76c05732c1e79c8e6164679b3e',
      );
      addTearDown(client.close);
      expect(
        (await client.send('GET', '/exact')).body.length,
        jamMaxResponseBytes,
      );
      await expectLater(
        client.send('GET', '/over'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('byte limit'),
          ),
        ),
      );
    },
  );
}
