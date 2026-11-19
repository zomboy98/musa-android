import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_http_request.dart';
import 'package:mornye/services/jam/jam_bounded_tls_listener.dart';

void main() {
  test('real TLS sockets enforce framing and absolute request deadline', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final results = StreamController<Object>();
    final listener = await JamBoundedTlsListener.start(
      identity: identity,
      handler: (socket, cancellation) async {
        try {
          results.add(
            await JamBoundedHttpRequest.read(
              socket,
              cancellation,
              maxHeaderBytes: 128,
              maxBodyBytes: 4,
              timeout: const Duration(milliseconds: 300),
            ),
          );
        } catch (e) {
          results.add(e);
        }
      },
    );
    addTearDown(() async {
      await listener.close();
      await results.close();
    });
    final iterator = StreamIterator<Object>(results.stream);
    Future<Object> request(String data) async {
      final client = await SecureSocket.connect(
        '127.0.0.1',
        listener.port,
        onBadCertificate: (_) => true,
      );
      client.add(ascii.encode(data));
      await client.flush();
      await iterator.moveNext().timeout(const Duration(seconds: 2));
      final result = iterator.current;
      client.destroy();
      return result;
    }

    final ok = await request(
      'POST /pair HTTP/1.1\r\nHost: local\r\nContent-Length: 2\r\n\r\n{}',
    );
    expect(ok, isA<JamBoundedHttpRequest>());
    expect((ok as JamBoundedHttpRequest).body, ascii.encode('{}'));
    expect(
      await request('POST / HTTP/1.1\r\nHost: a\r\nContent-Length:\t2 \t\r\n\r\n{}'),
      isA<JamBoundedHttpRequest>(),
    );
    for (final data in [
      'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\r\n\r\n{}',
      'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: \u000b2\r\n\r\n{}',
      'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}',
      'POST / HTTP/1.1\r\nHost: a\r\nTransfer-Encoding: chunked\r\nContent-Length: 0\r\n\r\n',
      'POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\n\r\n',
      'GET / HTTP/1.1\r\nHost: ${'a' * 130}',
    ]) {
      expect(await request(data), isA<FormatException>());
    }
    expect(await request('GET / HTTP/1.1\r\nHost: a'), isA<TimeoutException>());
    await iterator.cancel();
  });
}
