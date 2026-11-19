import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_coordinator.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';
import 'support/jam_track_fixture.dart';

void main() {
  test('active stream drain completes on close', () async {
    final session = JamSession(hostId: 'host');
    final drained = session.events.drain<void>();
    session.submit(
      authenticatedActorId: 'host',
      command: const AddJamEntry('one', 'host', 0, 'o', 't'),
    );
    final first = session.close();
    final second = session.close();
    expect(identical(first, second), isTrue);
    await Future.wait([
      first,
      second,
      drained,
    ]).timeout(const Duration(seconds: 1));
  });
  test('closing cancels paused listeners and shares cleanup', () async {
    final session = JamSession(hostId: 'host');
    final received = <int>[];
    final subscription = session.events.listen((s) => received.add(s.revision));
    addTearDown(subscription.cancel);
    subscription.pause();
    session.submit(
      authenticatedActorId: 'host',
      command: const AddJamEntry('one', 'host', 0, 'o', 't'),
    );
    final first = session.close();
    final second = session.close();
    expect(identical(first, second), isTrue);
    await Future.wait([first, second]).timeout(const Duration(seconds: 1));
    subscription.resume();
    await Future<void>.delayed(Duration.zero);
    expect(received, isEmpty);
    expect(
      () => session.submit(
        authenticatedActorId: 'host',
        command: const AddJamEntry('two', 'host', 1, 'p', 't'),
      ),
      throwsStateError,
    );
    expect(session.snapshot.revision, 1);
  });
  test('host and two TLS guests share one revisioned session', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final coordinator = await JamCoordinator.start(
      hostId: 'host',
      identity: identity,
    );
    addTearDown(coordinator.close);
    final observed = <int>[];
    final subscription = coordinator.events.listen(
      (s) => observed.add(s.revision),
    );
    addTearDown(subscription.cancel);

    Future<(int, Map<String, dynamic>)> request(
      String path, {
      String? token,
      Map<String, Object>? data,
    }) async {
      final client = await SecureSocket.connect(
        '127.0.0.1',
        coordinator.server.port,
        onBadCertificate: (_) => true,
      );
      final body = data == null ? '' : jsonEncode(data);
      client.write(
        '${data == null ? 'GET' : 'POST'} $path HTTP/1.1\r\nHost: 127.0.0.1:${coordinator.server.port}\r\n${token == null ? '' : 'Authorization: Bearer $token\r\n'}${data == null ? '' : 'Content-Type: application/json\r\nContent-Length: ${utf8.encode(body).length}\r\n'}\r\n$body',
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
              data: {'grant': coordinator.server.issueGrant()},
            )).$2['credential']
            as String;
    final second =
        (await request(
              '/pair',
              data: {'grant': coordinator.server.issueGrant()},
            )).$2['credential']
            as String;
    final revision = coordinator.snapshot.revision;
    final hostAdd = AddJamEntry(
      'host-add',
      'host',
      revision,
      'host-entry',
      'track',
    );
    expect(coordinator.submitHost(hostAdd).outcome, JamOutcome.applied);
    expect(coordinator.submitHost(hostAdd).outcome, JamOutcome.duplicate);
    expect((await request('/queue', token: first)).$2['entries'], hasLength(1));
    final sharedRevision = coordinator.snapshot.revision;
    final results = await Future.wait([
      request(
        '/queue',
        token: first,
        data: {
          'id': 'guest-a',
          'revision': sharedRevision,
          'type': 'add',
          'occurrenceId': 'a',
          'trackId': jamTestTrack('a'),
        },
      ),
      request(
        '/queue',
        token: second,
        data: {
          'id': 'guest-b',
          'revision': sharedRevision,
          'type': 'add',
          'occurrenceId': 'b',
          'trackId': jamTestTrack('b'),
        },
      ),
    ]);
    expect(
      results.map((r) => r.$2['outcome']),
      containsAll(['applied', 'conflict']),
    );
    expect(coordinator.snapshot.entries, hasLength(2));
    expect(coordinator.server.snapshot, same(coordinator.snapshot));
    final other = coordinator.snapshot.entries.last.occurrenceId;
    expect(
      coordinator
          .submitHost(
            MoveJamEntry(
              'host-move',
              'host',
              coordinator.snapshot.revision,
              other,
              'host-entry',
            ),
          )
          .outcome,
      JamOutcome.applied,
    );
    final guestEntries =
        (await request('/queue', token: second)).$2['entries'] as List<dynamic>;
    expect((guestEntries.first as Map<String, dynamic>)['occurrenceId'], other);
    expect(
      coordinator
          .submitHost(
            RemoveJamEntry(
              'host-remove',
              'host',
              coordinator.snapshot.revision,
              other,
            ),
          )
          .outcome,
      JamOutcome.applied,
    );
    expect(
      coordinator
          .submitHost(
            AddJamEntry(
              'bad',
              'other',
              coordinator.snapshot.revision,
              'x',
              'x',
            ),
          )
          .outcome,
      JamOutcome.forbidden,
    );
    await Future<void>.delayed(Duration.zero);
    expect(observed, [1, 2, 3, 4, 5, 6]);
    await coordinator.close();
    expect(() => coordinator.submitHost(hostAdd), throwsStateError);
    expect(coordinator.snapshot.entries, hasLength(1));
  });
}
