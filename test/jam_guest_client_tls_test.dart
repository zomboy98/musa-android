import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_guest_client.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_tls_server.dart';
import 'support/jam_track_fixture.dart';

const pin = '89c840e396a5c37ea4bb79a4d1b7dba919b3fe76c05732c1e79c8e6164679b3e';

void main() {
  late JamTlsServer server;
  late JamGuestClient guest;
  setUp(() async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    server = await JamTlsServer.start(
      address: InternetAddress.loopbackIPv4,
      identity: identity,
    );
    guest = JamGuestClient(JamPinnedClient(server.endpoint, pin));
  });
  tearDown(() async {
    guest.close();
    await server.close();
  });

  test(
    'pairs and applies idempotent queue commands with conflict snapshots',
    () async {
      final grant = server.issueGrant();
      await guest.pair(grant);
      final initial = await guest.fetchSnapshot();
      expect(initial.entries, isEmpty);
      final added = await guest.add(
        commandId: 'add',
        revision: initial.revision,
        occurrenceId: 'one',
        trackId: jamTestTrack('track'),
      );
      expect(added.outcome, JamOutcome.applied);
      final duplicate = await guest.add(
        commandId: 'add',
        revision: initial.revision,
        occurrenceId: 'one',
        trackId: jamTestTrack('track'),
      );
      expect(duplicate.outcome, JamOutcome.duplicate);
      final conflict = await guest.add(
        commandId: 'other',
        revision: initial.revision,
        occurrenceId: 'two',
        trackId: jamTestTrack('other'),
      );
      expect(conflict.outcome, JamOutcome.conflict);
      expect(conflict.snapshot.entries.single.trackId, jamTestTrack('track'));
      final second = await guest.add(
        commandId: 'other',
        revision: conflict.snapshot.revision,
        occurrenceId: 'two',
        trackId: jamTestTrack('other'),
      );
      final moved = await guest.move(
        commandId: 'move',
        revision: second.snapshot.revision,
        occurrenceId: 'two',
        beforeOccurrenceId: 'one',
      );
      expect(moved.snapshot.entries.map((e) => e.occurrenceId), ['two', 'one']);
      final removed = await guest.remove(
        commandId: 'remove',
        revision: moved.snapshot.revision,
        occurrenceId: 'one',
      );
      expect(removed.snapshot.entries.single.occurrenceId, 'two');
      guest.close();
      await expectLater(guest.fetchSnapshot(), throwsStateError);
    },
  );

  test('rejects consumed grant and incorrect certificate pin', () async {
    final grant = server.issueGrant();
    await guest.pair(grant);
    final other = JamGuestClient(JamPinnedClient(server.endpoint, pin));
    addTearDown(other.close);
    await expectLater(
      other.pair(grant),
      throwsA(
        isA<JamGuestException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    final bad = JamGuestClient(JamPinnedClient(server.endpoint, '0' * 64));
    addTearDown(bad.close);
    await expectLater(
      bad.pair(server.issueGrant()),
      throwsA(isA<HandshakeException>()),
    );
  });
  test('clears its credential after a revoked response over TLS', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final peer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity,
    );
    addTearDown(() => peer.close(force: true));
    peer.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/pair') {
        request.response.write('{"credential":"temporary"}');
      } else {
        request.response.statusCode = HttpStatus.unauthorized;
      }
      await request.response.close();
    });
    final revoked = JamGuestClient(
      JamPinnedClient(Uri.parse('https://127.0.0.1:${peer.port}'), pin),
    );
    addTearDown(revoked.close);
    await revoked.pair('grant');
    await expectLater(
      revoked.fetchSnapshot(),
      throwsA(
        isA<JamGuestException>().having((e) => e.statusCode, 'status', 401),
      ),
    );
    expect(revoked.isPaired, isFalse);
    await expectLater(revoked.fetchSnapshot(), throwsStateError);
  });
  test('stale responses cannot affect a newly paired credential', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final peer = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      identity,
    );
    addTearDown(() => peer.close(force: true));
    final arrived = Completer<void>();
    final release = Completer<void>();
    var pairs = 0;
    var oldRequests = 0;
    peer.listen((request) async {
      await request.drain<void>();
      if (request.uri.path == '/pair') {
        pairs++;
        request.response.write('{"credential":"${pairs == 1 ? 'A' : 'B'}"}');
      } else if (request.headers.value('authorization') == 'Bearer A') {
        oldRequests++;
        if (oldRequests == 1) {
          arrived.complete();
          await release.future;
        }
        request.response.statusCode = HttpStatus.unauthorized;
      } else {
        request.response.write(
          '{"revision":0,"guestEditingEnabled":true,"entries":[]}',
        );
      }
      await request.response.close();
    });
    final client = JamGuestClient(
      JamPinnedClient(Uri.parse('https://127.0.0.1:${peer.port}'), pin),
    );
    addTearDown(client.close);
    await client.pair('first');
    final old = client.fetchSnapshot();
    final oldCheck = expectLater(old, throwsStateError);
    await arrived.future;
    await expectLater(
      client.fetchSnapshot(),
      throwsA(isA<JamGuestException>()),
    );
    await client.pair('second');
    release.complete();
    await oldCheck;
    expect(client.isPaired, isTrue);
    expect((await client.fetchSnapshot()).revision, 0);
  });

  test('invalid grants are not included in errors', () async {
    final secret = 's' * 257;
    try {
      await guest.pair(secret);
      fail('Expected invalid grant');
    } on ArgumentError catch (error) {
      expect(error.toString(), isNot(contains(secret)));
    }
  });
}
