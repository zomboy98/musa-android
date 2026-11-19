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
  final List<String> cancelled = [];
  final Map<String, Completer<void>> gates = {};
  PrefetchNetwork network = PrefetchNetwork.unmetered;
  int running = 0;
  int maxRunning = 0;

  Future<void> prepare(Track track) async {
    started.add(track.id);
    running++;
    if (running > maxRunning) maxRunning = running;
    final gate = gates.putIfAbsent(track.id, Completer<void>.new);
    try {
      await gate.future;
    } finally {
      running--;
    }
  }

  Future<void> cancel(Track track) async {
    cancelled.add(track.id);
    final gate = gates.putIfAbsent(track.id, Completer<void>.new);
    if (!gate.isCompleted) gate.completeError(StateError('cancelled'));
  }

  void open(String id) {
    final gate = gates.putIfAbsent(id, Completer<void>.new);
    if (!gate.isCompleted) gate.complete();
  }

  UpcomingPrefetcher build({int count = 3}) => UpcomingPrefetcher(
    prepare: prepare,
    cancel: cancel,
    isStreamingOnly: (track) async => true,
    network: () async => network,
    key: (track) => track.id,
    count: count,
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final tracks = {for (final id in 'abcdefgh'.split('')) id: _track(id)};
  List<Track> pick(String ids) => [for (final id in ids.split('')) tracks[id]!];

  Future<_Fakes> readyAhead(UpcomingPrefetcher Function(_Fakes) build) async {
    final fakes = _Fakes();
    final prefetcher = build(fakes)..schedule(pick('abc'));
    await _settle();
    for (final id in 'abc'.split('')) {
      fakes.open(id);
      await _settle();
    }
    expect(fakes.started, ['a', 'b', 'c']);
    prefetcher.stop();
    return fakes;
  }

  test('with three ready, advancing asks for the fourth right away', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    for (final id in 'abc'.split('')) {
      fakes.open(id);
      await _settle();
    }
    fakes.started.clear();
    prefetcher.hold(target: tracks['a']);
    prefetcher.schedule(pick('bcd'), current: tracks['a']);
    await _settle();
    expect(fakes.started, ['d']);
    expect(fakes.cancelled, isEmpty);
    expect(fakes.maxRunning, 1);
    prefetcher.stop();
  });

  test('does not wait for earlier songs before asking for the next', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    prefetcher.hold(target: tracks['a']);
    prefetcher.schedule(pick('bcd'), current: tracks['a']);
    await _settle();
    expect(fakes.cancelled, ['b']);
    expect(fakes.started.take(3), ['a', 'b', 'b']);
    expect(fakes.maxRunning, 1);
    prefetcher.stop();
  });

  test('a song that played leaves the count and never exceeds three', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    for (final id in 'abc'.split('')) {
      fakes.open(id);
      await _settle();
    }
    var current = 'a';
    for (final next in 'bcd'.split('')) {
      final index = 'abcdefgh'.indexOf(next);
      prefetcher.hold(target: tracks[current]);
      prefetcher.schedule(
        pick('abcdefgh'.substring(index, index + 3)),
        current: tracks[current],
      );
      await _settle();
      fakes.open('abcdefgh'[index + 2]);
      await _settle();
      current = next;
    }
    expect(fakes.started, ['a', 'b', 'c', 'd', 'e', 'f']);
    expect(fakes.maxRunning, 1);
    prefetcher.stop();
  });

  test('skipping several songs recomputes the window', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    prefetcher.hold(target: tracks['e']);
    prefetcher.schedule(pick('fgh'), current: tracks['e']);
    await _settle();
    expect(fakes.cancelled, ['b']);
    expect(fakes.started, ['a', 'b', 'f']);
    prefetcher.stop();
  });

  test('skipping keeps the requested song and drops those left behind',
      () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule(pick('abcd'));
    await _settle();
    expect(fakes.started, ['a']);
    prefetcher.hold(target: tracks['a']);
    prefetcher.schedule(pick('abc'), current: tracks['a']);
    await _settle();
    expect(fakes.cancelled, isEmpty);
    prefetcher.stop();
  });

  test('mobile data keeps a single song ahead', () async {
    final fakes = _Fakes()..network = PrefetchNetwork.metered;
    final prefetcher = fakes.build()..schedule(pick('abc'));
    await _settle();
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a']);
    prefetcher.hold(target: tracks['a']);
    prefetcher.schedule(pick('bcd'), current: tracks['a']);
    await _settle();
    expect(fakes.started, ['a', 'b']);
    prefetcher.stop();
  });

  test('ready songs are reused', () async {
    final fakes = await readyAhead((f) => f.build());
    expect(fakes.started.length, 3);
  });
}
