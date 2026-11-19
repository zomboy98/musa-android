import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_server.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';

void main() {
  test('fresh identity pins real TLS and grants are single use', () async {
    final first = await JamBoundedServer.startEphemeral();
    final second = await JamBoundedServer.startEphemeral();
    addTearDown(first.close);
    addTearDown(second.close);
    final invitation = first.issueInvitation();
    expect(
      invitation.certificateSha256,
      isNot(second.issueInvitation().certificateSha256),
    );
    final client = JamPinnedClient(
      invitation.endpoint,
      invitation.certificateSha256,
    );
    addTearDown(client.close);
    final body = utf8.encode(jsonEncode({'grant': invitation.grant}));
    expect((await client.send('POST', '/pair', body: body)).statusCode, 200);
    expect((await client.send('POST', '/pair', body: body)).statusCode, 401);
    final wrong = JamPinnedClient(invitation.endpoint, '0' * 64);
    addTearDown(wrong.close);
    await expectLater(
      wrong.send('POST', '/pair', body: body),
      throwsA(anything),
    );
  });

  test('expired invitation cannot be redeemed over TLS', () async {
    final server = await JamBoundedServer.startEphemeral();
    addTearDown(server.close);
    final invite = server.issueInvitation(
      lifetime: const Duration(microseconds: 1),
    );
    final client = JamPinnedClient(invite.endpoint, invite.certificateSha256);
    addTearDown(client.close);
    final response = await client.send(
      'POST',
      '/pair',
      body: utf8.encode(jsonEncode({'grant': invite.grant})),
    );
    expect(response.statusCode, 401);
  });
}
