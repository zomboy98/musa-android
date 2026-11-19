import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/upcoming_prefetcher.dart';

Track _track(String id) => Track(
  id: id,
  source: 'tidal',
  name: id,
  artistName: 'A',
  albumName: 'B',
  duration: 1,
);

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final a = _track('a'), b = _track('b');

  group('precarga y enfriamiento', () {
    late DateTime now;
    late Duration wait;
    late List<String> asked;
    late bool failing;

    setUp(() {
      now = DateTime.utc(2026, 11, 16, 12);
      wait = Duration.zero;
      asked = [];
      failing = true;
    });

    UpcomingPrefetcher build() => UpcomingPrefetcher(
      prepare: (track) async {
        asked.add(track.id);
        if (failing) throw StateError('fallo');
      },
      cancel: (track) async {},
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      providerWait: () => wait,
      clock: () => now,
      count: 1,
    );

    test('no pide nada mientras el proveedor esta en enfriamiento', () async {
      wait = const Duration(seconds: 60);
      final prefetcher = build()..schedule([a, b]);
      await _settle();
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, isEmpty);
      prefetcher.stop();
    });

    test('pide de nuevo cuando termina la espera', () async {
      wait = const Duration(seconds: 60);
      failing = false;
      final prefetcher = build()..schedule([a, b]);
      await _settle();
      expect(asked, isEmpty);
      wait = Duration.zero;
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['a']);
      prefetcher.stop();
    });

    test('tras un fallo no repite la pista y sigue con la siguiente', () async {
      final prefetcher = build()..schedule([a, b]);
      await _settle();
      expect(asked, ['a', 'b']);
      prefetcher.schedule([a, b]);
      await _settle();
      prefetcher.hold();
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['a', 'b']);
      prefetcher.stop();
    });

    test('pasada la espera de fallo la pista vuelve a intentarse', () async {
      final prefetcher = build()..schedule([a, b]);
      await _settle();
      expect(asked, ['a', 'b']);
      failing = false;
      now = now.add(const Duration(minutes: 3));
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['a', 'b', 'a']);
      prefetcher.stop();
    });

    test('con dos pistas fallando a la vez no pide la tercera', () async {
      final c = _track('c');
      final prefetcher = build()..schedule([a, b, c]);
      await _settle();
      expect(asked, ['a', 'b']);
      prefetcher.stop();
    });

    test('un fallo con el proveedor en enfriamiento espera ese enfriamiento',
        () async {
      final prefetcher = UpcomingPrefetcher(
        prepare: (track) async {
          asked.add(track.id);
          wait = const Duration(minutes: 10);
          throw StateError('timeout');
        },
        cancel: (track) async {},
        isStreamingOnly: (track) async => true,
        network: () async => PrefetchNetwork.unmetered,
        key: (track) => track.id,
        providerWait: () => wait,
        clock: () => now,
        count: 1,
      )..schedule([a, b]);
      await _settle();
      expect(asked, ['a']);
      now = now.add(const Duration(minutes: 3));
      wait = const Duration(minutes: 7);
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['a']);
      prefetcher.stop();
    });

    test('la precarga salta una pista en retroceso de su proveedor', () async {
      var blocked = const Duration(seconds: 30);
      final prefetcher = UpcomingPrefetcher(
        prepare: (track) async => asked.add(track.id),
        cancel: (track) async {},
        isStreamingOnly: (track) async => true,
        network: () async => PrefetchNetwork.unmetered,
        key: (track) => track.id,
        trackWait: (track) => track.id == 'a' ? blocked : Duration.zero,
        clock: () => now,
        count: 1,
      )..schedule([a, b]);
      await _settle();
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['b']);
      blocked = Duration.zero;
      prefetcher.schedule([a, b]);
      await _settle();
      expect(asked, ['b', 'a']);
      prefetcher.stop();
    });
  });
}
