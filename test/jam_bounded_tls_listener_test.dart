import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_bounded_tls_listener.dart';

void main() {
  test(
    'simultaneous close calls share shutdown and cancel active work',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final entered = Completer<void>();
      final cancelled = Completer<void>();
      final listener = await JamBoundedTlsListener.start(
        identity: identity,
        handler: (socket, cancellation) async {
          entered.complete();
          await cancellation.cancelled;
          cancelled.complete();
        },
      );
      final client = await SecureSocket.connect(
        '127.0.0.1',
        listener.port,
        onBadCertificate: (_) => true,
      );
      await entered.future;
      final first = listener.close();
      final second = listener.close();
      expect(identical(first, second), isTrue);
      await Future.wait([
        first,
        second,
        cancelled.future,
      ]).timeout(const Duration(seconds: 2));
      await client.drain<void>().timeout(const Duration(seconds: 2));
      client.destroy();
    },
  );
  test(
    'closes stalled TLS, rejects saturation, then accepts valid TLS',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final handled = Completer<void>();
      final listener = await JamBoundedTlsListener.start(
        identity: identity,
        maxConnections: 1,
        handshakeTimeout: const Duration(milliseconds: 500),
        connectionTimeout: const Duration(seconds: 2),
        handler: (socket, cancellation) async {
          handled.complete();
        },
      );
      addTearDown(listener.close);
      final stalled = await Socket.connect('127.0.0.1', listener.port);
      stalled.add([22]);
      await stalled.flush();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final rejected = await Socket.connect('127.0.0.1', listener.port);
      expect(
        await rejected.isEmpty.timeout(const Duration(seconds: 2)),
        isTrue,
      );
      expect(await stalled.isEmpty.timeout(const Duration(seconds: 2)), isTrue);
      rejected.destroy();
      stalled.destroy();
      final client = await SecureSocket.connect(
        '127.0.0.1',
        listener.port,
        onBadCertificate: (_) => true,
      );
      await handled.future.timeout(const Duration(seconds: 2));
      client.destroy();
    },
  );

  test('close releases a socket in an unfinished handshake', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final listener = await JamBoundedTlsListener.start(
      identity: identity,
      handler: (socket, cancellation) async {},
    );
    final client = await Socket.connect('127.0.0.1', listener.port);
    client.add([22]);
    await client.flush();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await listener.close().timeout(const Duration(seconds: 2));
    expect(await client.isEmpty.timeout(const Duration(seconds: 2)), isTrue);
    client.destroy();
  });

  test(
    'repeated stalled handshakes release tracked connections and tasks',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final listener = await JamBoundedTlsListener.start(
        identity: identity,
        maxConnections: 4,
        handshakeTimeout: const Duration(milliseconds: 150),
        connectionTimeout: const Duration(seconds: 1),
        handler: (socket, cancellation) async {},
      );
      addTearDown(listener.close);
      for (var round = 0; round < 5; round++) {
        final clients = await Future.wait(
          List.generate(4, (_) => Socket.connect('127.0.0.1', listener.port)),
        );
        for (final client in clients) {
          client.add([22]);
        }
        await Future.wait(clients.map((client) => client.flush()));
        await Future.wait(
          clients.map(
            (client) =>
                client.drain<void>().timeout(const Duration(seconds: 2)),
          ),
        );
        for (final client in clients) {
          client.destroy();
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(listener.activeConnections, 0);
        expect(listener.pendingTasks, 0);
      }
      await listener.close();
    },
  );

  test(
    'uncooperative handler retains its slot after deadline and close',
    () async {
      final identity = SecurityContext()
        ..useCertificateChain('test/fixtures/jam/certificate.pem')
        ..usePrivateKey('test/fixtures/jam/key.pem');
      final entered = Completer<void>();
      final finish = Completer<void>();
      var mutations = 0;
      final listener = await JamBoundedTlsListener.start(
        identity: identity,
        maxConnections: 1,
        connectionTimeout: const Duration(milliseconds: 150),
        handler: (socket, cancellation) async {
          entered.complete();
          await finish.future;
          mutations++;
        },
      );
      final client = await SecureSocket.connect(
        '127.0.0.1',
        listener.port,
        onBadCertificate: (_) => true,
      );
      await entered.future;
      await client.drain<void>().timeout(const Duration(seconds: 2));
      expect(listener.activeConnections, 1);
      await listener.close();
      expect(listener.pendingTasks, 1);
      finish.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(listener.pendingTasks, 0);
      expect(mutations, 1); // A non-cooperative handler can mutate after close.
      client.destroy();
    },
  );
  test('cooperative handler stops before mutation when closed', () async {
    final identity = SecurityContext()
      ..useCertificateChain('test/fixtures/jam/certificate.pem')
      ..usePrivateKey('test/fixtures/jam/key.pem');
    final entered = Completer<void>();
    final stopped = Completer<void>();
    var mutations = 0;
    final listener = await JamBoundedTlsListener.start(
      identity: identity,
      handler: (socket, cancellation) async {
        entered.complete();
        await cancellation.cancelled;
        try {
          cancellation.throwIfCancelled();
          mutations++;
        } on StateError {
          stopped.complete();
        }
      },
    );
    final client = await SecureSocket.connect(
      '127.0.0.1',
      listener.port,
      onBadCertificate: (_) => true,
    );
    await entered.future.timeout(const Duration(seconds: 2));
    await listener.close();
    await stopped.future.timeout(const Duration(seconds: 2));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(mutations, 0);
    expect(listener.pendingTasks, 0);
    expect(listener.activeConnections, 0);
    client.destroy();
  });
}
