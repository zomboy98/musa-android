import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_server.dart';
import 'package:mornye/services/jam/jam_local_server.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/jam/jam_session.dart';
import 'package:mornye/services/jam/jam_tls_server.dart';
import 'package:mornye/services/jam/jam_track_reference.dart';

import 'support/jam_track_fixture.dart';

void main() {
  for (final transport in ['bounded TLS', 'legacy TLS', 'loopback HTTP']) {
    test('$transport validates remote references before queue mutation', () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final session = JamSession(hostId: 'host');
      addTearDown(session.close);
      const hostToken = 'jamhost1:ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef';
      if (transport == 'bounded TLS') {
        expect(
          session
              .submit(
                authenticatedActorId: 'host',
                command: const AddJamEntry(
                  'seed',
                  'host',
                  0,
                  'host-entry',
                  hostToken,
                ),
              )
              .outcome,
          JamOutcome.applied,
        );
      }
      late Uri endpoint;
      late JamQueue Function() snapshot;
      late String token;
      String? grant;
      if (transport == 'bounded TLS') {
        final server = await JamBoundedServer.start(
          identity: identity,
          session: session,
        );
        addTearDown(server.close);
        endpoint = server.endpoint;
        snapshot = () => server.snapshot;
        grant = server.issueGrant();
      } else if (transport == 'legacy TLS') {
        final server = await JamTlsServer.start(
          address: InternetAddress.loopbackIPv4,
          identity: identity,
        );
        addTearDown(server.close);
        endpoint = server.endpoint;
        snapshot = () => server.snapshot;
        grant = server.issueGrant();
      } else {
        final server = await JamLocalServer.start();
        addTearDown(server.close);
        endpoint = server.endpoint;
        snapshot = () => server.snapshot;
        token = server.invite()!;
      }
      final client = HttpClient()..badCertificateCallback = (_, _, _) => true;
      addTearDown(() => client.close(force: true));
      final pinned = endpoint.scheme == 'https'
          ? JamPinnedClient(
              endpoint,
              '89c840e396a5c37ea4bb79a4d1b7dba919b3fe76c05732c1e79c8e6164679b3e',
            )
          : null;
      if (pinned != null) addTearDown(pinned.close);
      Future<(int, Map<String, dynamic>)> post(
        String path,
        Map<String, Object> body, {
        String? bearer,
      }) async {
        if (pinned != null) {
          final response = await pinned.send(
            'POST',
            path,
            bearer: bearer,
            body: utf8.encode(jsonEncode(body)),
          );
          final text = utf8.decode(response.body);
          return (
            response.statusCode,
            text.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(text) as Map<String, dynamic>,
          );
        }
        final request = await client.postUrl(endpoint.resolve(path));
        request.headers.contentType = ContentType.json;
        if (bearer != null) {
          request.headers.set('Authorization', 'Bearer $bearer');
        }
        request.write(jsonEncode(body));
        final response = await request.close();
        final text = await utf8.decoder.bind(response).join();
        return (
          response.statusCode,
          text.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(text) as Map<String, dynamic>,
        );
      }

      if (grant != null) {
        token =
            (await post('/pair', {'grant': grant})).$2['credential'] as String;
      }
      final revision = snapshot().revision;
      final originalEntries = snapshot().entries;
      Map<String, Object> add(
        String track, {
        String id = 'proposal',
        int? rev,
      }) => {
        'id': id,
        'revision': rev ?? revision,
        'type': 'add',
        'occurrenceId': 'guest-entry',
        'trackId': track,
      };
      final unsafeMetadata =
          'jamref1:${base64Url.encode(utf8.encode(jsonEncode({'s': 'USABC1234567', 't': 'C:/private/song.mp3', 'a': 'Artist'}))).replaceAll('=', '')}';
      for (final invalid in [
        '/private/music.flac',
        r'C:\private\music.mp3',
        'https://example.com/audio',
        'content://private/audio',
        'arbitrary-id',
        'jamref1:invalid',
        unsafeMetadata,
        hostToken,
      ]) {
        final rejected = await post('/queue', add(invalid), bearer: token);
        expect(rejected.$1, HttpStatus.badRequest, reason: invalid);
        expect(snapshot().revision, revision);
        expect(snapshot().entries, originalEntries);
        expect(jsonEncode(rejected.$2), isNot(contains(invalid)));
      }
      // Rejected inputs do not consume the command ID or expected revision.
      final track = jamTestTrack('Song');
      final applied = await post('/queue', add(track), bearer: token);
      expect(applied.$2['outcome'], 'applied');
      expect(snapshot().entries.last.trackId, track);
      final duplicate = await post('/queue', add(track), bearer: token);
      expect(duplicate.$2['outcome'], 'duplicate');
      final changed = await post(
        '/queue',
        add(jamTestTrack('Other')),
        bearer: token,
      );
      expect(changed.$2['outcome'], 'invalid');
      final conflict = await post(
        '/queue',
        add(track, id: 'stale'),
        bearer: token,
      );
      expect(conflict.$1, HttpStatus.conflict);
      expect(conflict.$2['outcome'], 'conflict');
      // Provider-only references remain valid protocol identities even when the
      // current local-library resolver cannot find a playable source for them.
      final providerOnly = JamTrackReference.create(
        provider: 'deezer',
        externalId: '123',
        title: 'Catalog',
        artist: 'Artist',
      )!.encode();
      final second = add(providerOnly, id: 'catalog', rev: snapshot().revision)
        ..['occurrenceId'] = 'catalog-entry';
      expect(
        (await post('/queue', second, bearer: token)).$2['outcome'],
        'applied',
      );
      if (transport == 'bounded TLS') {
        // A host token can be read/reordered/removed by occurrence, but cannot
        // be replayed as a new guest capability through add.
        expect(snapshot().entries.first.trackId, hostToken);
        expect(
          (await post('/queue', {
            'id': 'move-host',
            'revision': snapshot().revision,
            'type': 'move',
            'occurrenceId': 'host-entry',
          }, bearer: token)).$2['outcome'],
          'applied',
        );
        expect(
          (await post('/queue', {
            'id': 'remove-host',
            'revision': snapshot().revision,
            'type': 'remove',
            'occurrenceId': 'host-entry',
          }, bearer: token)).$2['outcome'],
          'applied',
        );
      }
    });
  }
}
