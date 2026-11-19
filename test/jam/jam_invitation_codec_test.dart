import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_ephemeral_identity.dart';
import 'package:mornye/services/jam/jam_guest_client.dart';
import 'package:mornye/services/jam/jam_invitation_codec.dart';
import 'package:mornye/services/jam/jam_pairing.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';
import 'package:mornye/services/jam/jam_tls_server.dart';

void main() {
  final pin = 'a' * 64;
  final grant = JamPairing().issue();
  String wire(String json) =>
      'jam1.${base64Url.encode(utf8.encode(json)).replaceAll('=', '')}';

  test('round trips canonical bounded opaque text', () {
    final invitation = JamInvitation(
      endpoint: Uri.parse('https://192.168.1.8:1234'),
      certificateSha256: pin,
      grant: grant,
    );
    final encoded = JamInvitationCodec.encode(invitation);
    final decoded = JamInvitationCodec.decode(encoded);
    expect(encoded, startsWith('jam1.'));
    expect(encoded.length, lessThan(JamInvitationCodec.maxEncodedLength));
    expect(decoded.endpoint, invitation.endpoint);
    expect(decoded.certificateSha256, pin);
    expect(decoded.grant, grant);
    expect(JamInvitationCodec.encode(decoded), encoded);
  });

  test('rejects malformed, oversized and structurally modified input', () {
    final valid = jsonEncode({
      'v': 1,
      'endpoint': 'https://127.0.0.1:443',
      'pin': pin,
      'grant': grant,
    });
    final invalid = [
      '',
      'jam2.abc',
      'jam1.!',
      'jam1.${'A' * 1024}',
      wire(valid.replaceFirst('"v":1', '"v":2')),
      wire(valid.replaceFirst('"v":1', '"v":1,"v":1')),
      wire(valid.replaceFirst('127.0.0.1', '8.8.8.8')),
      wire(valid.replaceFirst('https:', 'http:')),
      wire(valid.replaceFirst(':443', ':443/path')),
      wire(valid.replaceFirst(pin, 'z' * 64)),
      wire(valid.replaceFirst(grant, 'bad')),
      wire(valid.replaceFirst('"v":1', '"v":1,"extra":true')),
      '${wire(valid)}=',
    ];
    for (final value in invalid) {
      expect(() => JamInvitationCodec.decode(value), throwsFormatException);
    }
  });

  test(
    'decoded invitation pairs once with a real pinned loopback client',
    () async {
      final identity = JamEphemeralIdentity.generate();
      final server = await JamTlsServer.start(
        address: InternetAddress.loopbackIPv4,
        identity: identity.context,
      );
      final source = JamInvitation(
        endpoint: server.endpoint,
        certificateSha256: identity.certificateSha256,
        grant: server.issueGrant(),
      );
      final invitation = JamInvitationCodec.decode(
        JamInvitationCodec.encode(source),
      );
      final client = JamGuestClient(
        JamPinnedClient(invitation.endpoint, invitation.certificateSha256),
      );
      final second = JamGuestClient(
        JamPinnedClient(invitation.endpoint, invitation.certificateSha256),
      );
      try {
        await client.pair(invitation.grant);
        expect(client.isPaired, isTrue);
        expect((await client.fetchSnapshot()).entries, isEmpty);
        await expectLater(
          second.pair(invitation.grant),
          throwsA(isA<JamGuestException>()),
        );
      } finally {
        client.close();
        second.close();
        await server.close();
      }
    },
  );
}
