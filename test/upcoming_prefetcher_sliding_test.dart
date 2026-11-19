import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/upcoming_prefetcher.dart';

Track _track(int i) => Track(
  id: 't$i',
  source: 'tidal',
  name: 't$i',
  artistName: 'A',
  albumName: 'B',
  duration: 1,
);

Future<void> _settle() async {
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  const window = 3;
  final queue = [for (var i = 0; i < 8; i++) _track(i)];

  late Map<String, int> requests;
  late Set<String> ready;
  late List<String> cancelled;
  late List<String> failing;
  late PrefetchNetwork net;
  late UpcomingPrefetcher prefetcher;

  setUp(() {
    requests = {};
    ready = {};
    cancelled = [];
    failing = [];
    net = PrefetchNetwork.unmetered;
    prefetcher = UpcomingPrefetcher(
      prepare: (track) async {
        requests[track.id] = (requests[track.id] ?? 0) + 1;
        await Future<void>.delayed(Duration.zero);
        if (failing.contains(track.id)) throw StateError('fallo');
        ready.add(track.id);
      },
      cancel: (track) async => cancelled.add(track.id),
      isStreamingOnly: (track) async => true,
      network: () async => net,
      key: (track) => track.id,
      count: window,
    );
  });

  tearDown(() => prefetcher.stop());

  void start(int k) {
    prefetcher
      ..hold(target: queue[k])
      ..schedule(queue.skip(k + 1).toList(), current: queue[k], index: k);
  }

  test('eight songs in a row: song k+N is prepared when k starts', () async {
    for (var k = 0; k < queue.length; k++) {
      start(k);
      await _settle();
      for (var j = k + 1; j <= k + window && j < queue.length; j++) {
        expect(ready, contains('t$j'), reason: 'song $j ready at $k');
      }
    }
    expect(requests.values.every((n) => n == 1), isTrue);
    expect(requests.keys, hasLength(7));
  });

  test('requests come in queue order, one at a time', () async {
    final order = <String>[];
    var running = 0;
    var peak = 0;
    final ordered = UpcomingPrefetcher(
      prepare: (track) async {
        order.add(track.id);
        running++;
        if (running > peak) peak = running;
        await Future<void>.delayed(Duration.zero);
        running--;
      },
      cancel: (track) async {},
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      count: 4,
    )..schedule(queue.skip(1).toList(), index: 0);
    await _settle();
    expect(order, ['t1', 't2', 't3', 't4']);
    expect(peak, 1);
    ordered.stop();
  });

  test('a failing song does not stop the ones behind it', () async {
    failing.add('t1');
    start(0);
    await _settle();
    expect(ready, containsAll(['t2', 't3', 't4']));
    expect(ready, isNot(contains('t1')));
    expect(requests['t1'], 1);
  });

  test('a failed song is not marked as done for good', () async {
    var now = DateTime.utc(2026, 11, 18);
    failing.add('t1');
    final retrying = UpcomingPrefetcher(
      prepare: (track) async {
        requests[track.id] = (requests[track.id] ?? 0) + 1;
        if (failing.contains(track.id)) throw StateError('fallo');
        ready.add(track.id);
      },
      cancel: (track) async {},
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      count: 2,
      clock: () => now,
    )..schedule(queue.skip(1).toList(), index: 0);
    await _settle();
    expect(ready, {'t2', 't3'});
    failing.clear();
    now = now.add(const Duration(minutes: 3));
    retrying.schedule(queue.skip(1).toList(), index: 0);
    await _settle();
    expect(ready, containsAll(['t1', 't2']));
    retrying.stop();
  });

  test('jumping far away cancels songs left behind', () async {
    final gate = Completer<void>();
    final slow = UpcomingPrefetcher(
      prepare: (track) => gate.future,
      cancel: (track) async {
        cancelled.add(track.id);
        if (!gate.isCompleted) gate.completeError(StateError('cancelled'));
      },
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      count: window,
    )..schedule(queue.skip(1).toList(), index: 0);
    await _settle();
    slow
      ..hold(target: queue[6])
      ..schedule([queue[7]], current: queue[6], index: 6);
    await _settle();
    expect(cancelled, ['t1']);
    slow.stop();
  });

  test('the end of the queue prepares nothing more', () async {
    start(7);
    await _settle();
    expect(requests, isEmpty);
  });

  test('a single song queue prepares nothing', () async {
    prefetcher.schedule(const [], current: queue[0], index: 0);
    await _settle();
    expect(requests, isEmpty);
  });

  test('a window of zero prepares nothing', () async {
    prefetcher.count = 0;
    start(0);
    await _settle();
    expect(requests, isEmpty);
  });

  test('mobile data keeps the window to a single song', () async {
    net = PrefetchNetwork.metered;
    start(0);
    await _settle();
    expect(ready, {'t1'});
  });

  test('returning to wifi resumes preparing the whole window', () async {
    net = PrefetchNetwork.offline;
    start(0);
    await _settle();
    expect(requests, isEmpty);
    net = PrefetchNetwork.unmetered;
    prefetcher.networkChanged();
    await _settle();
    expect(ready, containsAll(['t1', 't2', 't3']));
  });

  test('a pause keeps the window but prepares no more', () async {
    start(0);
    await _settle();
    expect(ready, hasLength(window));
    prefetcher.setPaused(true);
    await _settle();
    expect(ready, hasLength(window));
    expect(requests.values.every((n) => n == 1), isTrue);
  });

  test('a failure after the plan was refreshed is not retried at once', () async {
    final gate = Completer<void>();
    final attempts = <String>[];
    final churn = UpcomingPrefetcher(
      prepare: (track) async {
        attempts.add(track.id);
        await gate.future;
        throw StateError('fallo');
      },
      cancel: (track) async {},
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
      count: 3,
    )..schedule(queue.skip(1).toList(), current: queue[0], index: 0);
    await _settle();
    expect(attempts, ['t1']);
    churn.schedule(queue.skip(1).toList(), current: queue[0], index: 0);
    await _settle();
    gate.complete();
    await _settle();
    expect(attempts.where((id) => id == 't1'), hasLength(1));
    expect(attempts, containsAll(['t1', 't2']));
    churn.stop();
  });
}
