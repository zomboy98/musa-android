import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_server.dart';
import 'package:mornye/services/jam/jam_network_address.dart';
import 'package:mornye/services/jam/jam_pinned_client.dart';

void main() {
  test('rejects wildcard, public, multicast, IPv6 and DNS endpoints', () async {
    for (final host in [
      '0.0.0.0',
      '8.8.8.8',
      '224.0.0.1',
      '169.254.1.2',
      '::1',
    ]) {
      final address = InternetAddress(host);
      expect(isJamAddress(address), isFalse, reason: host);
      await expectLater(
        JamBoundedServer.startEphemeral(address: address),
        throwsArgumentError,
      );
    }
    for (final host in ['example.com', '8.8.8.8', '0.0.0.0']) {
      expect(
        () => JamPinnedClient(Uri.parse('https://$host:1234'), '0' * 64),
        throwsArgumentError,
      );
    }
  });

  test('announced bound endpoint pairs with pin and rejects wrong Host', () async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    final private = interfaces
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback && isJamAddress(a))
        .toList();
    // Use a real LAN interface if present; otherwise exercise identical logic on loopback.
    final address = private.isEmpty
        ? InternetAddress.loopbackIPv4
        : private.first;
    // Report the exercised interface so CI output distinguishes LAN from fallback.
    // ignore: avoid_print
    print('Jam test bind: ${address.address}');
    final server = await JamBoundedServer.startEphemeral(address: address);
    addTearDown(server.close);
    final invitation = server.issueInvitation();
    expect(invitation.endpoint.host, address.address);
    final client = JamPinnedClient(
      invitation.endpoint,
      invitation.certificateSha256,
    );
    addTearDown(client.close);
    final response = await client.send(
      'POST',
      '/pair',
      body: utf8.encode(jsonEncode({'grant': invitation.grant})),
    );
    expect(response.statusCode, 200);
    final credential =
        (jsonDecode(utf8.decode(response.body)) as Map)['credential'] as String;
    expect(
      (await client.send('GET', '/queue', bearer: credential)).statusCode,
      200,
    );
    final wrongPin = JamPinnedClient(invitation.endpoint, '0' * 64);
    addTearDown(wrongPin.close);
    await expectLater(
      wrongPin.send('GET', '/queue', bearer: credential),
      throwsA(isA<HandshakeException>()),
    );
    final socket = await SecureSocket.connect(
      address.address,
      server.port,
      onBadCertificate: (_) => true,
    );
    socket.write(
      'GET /queue HTTP/1.1\r\nHost: 127.0.0.2:${server.port}\r\nAuthorization: Bearer $credential\r\n\r\n',
    );
    await socket.flush();
    final raw = await utf8.decoder
        .bind(socket)
        .join()
        .timeout(const Duration(seconds: 5));
    expect(raw, startsWith('HTTP/1.1 403 '));
    socket.destroy();
    expect(server.revoke(credential), isTrue);
    expect(
      (await client.send('GET', '/queue', bearer: credential)).statusCode,
      401,
    );
  });
}
