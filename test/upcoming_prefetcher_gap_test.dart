import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/upcoming_prefetcher.dart';

Track _track(String id) => Track(
  id: id,
  source: 'spotify',
  name: id,
  artistName: 'A',
  albumName: 'B',
  duration: 1,
);

class _Fakes {
  final List<String> started = [];
  final List<DateTime> startedAt = [];
  final Map<String, Completer<void>> gates = {};

  Future<void> prepare(Track track) async {
    started.add(track.id);
    startedAt.add(DateTime.now());
    await gates.putIfAbsent(track.id, Completer<void>.new).future;
  }

  Future<void> cancel(Track track) async {
    final gate = gates.putIfAbsent(track.id, Completer<void>.new);
    if (!gate.isCompleted) gate.completeError(StateError('cancelled'));
  }

  void open(String id) {
    final gate = gates.putIfAbsent(id, Completer<void>.new);
    if (!gate.isCompleted) gate.complete();
  }

  UpcomingPrefetcher build({int? count, Duration gap = Duration.zero}) {
    if (count == null) {
      return UpcomingPrefetcher(
        prepare: prepare,
        cancel: cancel,
        isStreamingOnly: (track) async => true,
        network: () async => PrefetchNetwork.unmetered,
        key: (track) => track.id,
        gap: gap,
      );
    }
    return UpcomingPrefetcher(
      prepare: prepare,
      cancel: cancel,
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      count: count,
      gap: gap,
    );
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final tracks = {for (final id in 'abcde'.split('')) id: _track(id)};
  List<Track> pick(String ids) => [for (final id in ids.split('')) tracks[id]!];

  test('el maximo son cinco canciones por delante', () {
    expect(UpcomingPrefetcher.maxCount, 5);
  });

  test('por defecto prepara la ventana de tres, de una en una', () async {
    final fakes = _Fakes();
    final prefetcher = UpcomingPrefetcher(
      prepare: fakes.prepare,
      cancel: fakes.cancel,
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
    )..schedule(pick('abcde'));
    await _settle();
    expect(fakes.started, ['a']);
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    fakes.open('b');
    await _settle();
    fakes.open('c');
    await _settle();
    expect(fakes.started, ['a', 'b', 'c']);
    prefetcher.stop();
  });

  test('al avanzar la lista pide la siguiente, de una en una', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    fakes.open('a');
    await _settle();
    prefetcher.schedule(pick('bc'));
    await _settle();
    expect(fakes.started, ['a', 'b']);
    prefetcher.stop();
  });

  test('sin espacio entre peticiones arranca de inmediato', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build(count: 2)..schedule(pick('ab'));
    await _settle();
    expect(fakes.started, ['a']);
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    prefetcher.stop();
  });

  test('el espacio retrasa cada peticion', () async {
    const gap = Duration(milliseconds: 300);
    final fakes = _Fakes();
    final prefetcher = fakes.build(count: 2, gap: gap)..schedule(pick('ab'));
    await _settle();
    expect(fakes.started, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(fakes.started, ['a']);
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a']);
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(fakes.started, ['a', 'b']);
    final between = fakes.startedAt[1].difference(fakes.startedAt[0]);
    expect(between, greaterThanOrEqualTo(gap));
    fakes.open('b');
    prefetcher.stop();
  });

  test('retener durante el espacio cancela la peticion pendiente', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build(gap: const Duration(milliseconds: 200))
      ..schedule(pick('ab'));
    await _settle();
    prefetcher.hold();
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(fakes.started, isEmpty);
    prefetcher.stop();
  });
}
