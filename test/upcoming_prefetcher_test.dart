import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/prefetch_planner.dart';
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
  final started = <String>[];
  final cancelled = <String>[];
  final finished = <String>[];
  final gates = <String, Completer<void>>{};
  final local = <String>{};
  var network = PrefetchNetwork.unmetered;
  var running = 0;
  var maxRunning = 0;

  Future<void> prepare(Track track) async {
    started.add(track.id);
    running++;
    if (running > maxRunning) maxRunning = running;
    final gate = gates.putIfAbsent(track.id, Completer<void>.new);
    try {
      await gate.future;
      finished.add(track.id);
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

  UpcomingPrefetcher build({
    int count = 2,
    Duration pauseLimit = const Duration(minutes: 3),
  }) => UpcomingPrefetcher(
    prepare: prepare,
    cancel: cancel,
    isStreamingOnly: (track) async => !local.contains(track.id),
    network: () async => network,
    key: (track) => track.id,
    count: count,
    pauseLimit: pauseLimit,
  );
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  final a = _track('a'), b = _track('b'), c = _track('c'), d = _track('d');

  test('prepares the next songs one at a time up to the count', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build(count: 2)..schedule([a, b, c]);
    await _settle();
    expect(fakes.started, ['a']);
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    fakes.open('b');
    await _settle();
    expect(fakes.started, ['a', 'b']);
    expect(fakes.finished, ['a', 'b']);
    expect(fakes.maxRunning, 1);
    prefetcher.stop();
  });

  test('keeps three songs ahead, one at a time, sliding as the queue advances',
      () async {
    final fakes = _Fakes();
    final e = _track('e');
    final prefetcher = fakes.build(count: 3)..schedule([a, b, c, d]);
    await _settle();
    expect(fakes.started, ['a']);
    fakes.open('a');
    await _settle();
    fakes.open('b');
    await _settle();
    fakes.open('c');
    await _settle();
    expect(fakes.started, ['a', 'b', 'c']);
    expect(fakes.maxRunning, 1);
    prefetcher.hold(target: a);
    prefetcher.schedule([b, c, d, e], current: a);
    await _settle();
    expect(fakes.started.where((id) => id == 'd' || id == 'e'), ['d']);
    prefetcher.stop();
  });

  test('default count is the maximum', () {
    final fakes = _Fakes();
    final prefetcher = UpcomingPrefetcher(
      prepare: fakes.prepare,
      cancel: fakes.cancel,
      isStreamingOnly: (track) async => true,
      network: () async => PrefetchNetwork.unmetered,
      key: (track) => track.id,
    );
    expect(prefetcher.count, defaultPrefetchWindow);
  });

  test('stays idle while the current song is being prepared', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..hold(target: a);
    await _settle();
    expect(fakes.started, isEmpty);
    prefetcher.schedule([b]);
    await _settle();
    expect(fakes.started, ['b']);
    prefetcher.stop();
  });

  test('a played request stops queued work but keeps its own target', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule([a, b]);
    await _settle();
    prefetcher.hold(target: a);
    await _settle();
    expect(fakes.cancelled, isEmpty);
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a']);
    prefetcher.stop();
  });

  test('a played request cancels preparation of any other song', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule([a, b]);
    await _settle();
    prefetcher.hold(target: c);
    await _settle();
    expect(fakes.cancelled, ['a']);
    expect(fakes.started, ['a']);
    prefetcher.stop();
  });

  test('changing the queue cancels what is no longer upcoming', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule([a, b]);
    await _settle();
    prefetcher.schedule([c, d], current: _track('z'));
    await _settle();
    expect(fakes.cancelled, ['a']);
    expect(fakes.started, ['a', 'c']);
    fakes.open('c');
    await _settle();
    expect(fakes.started, ['a', 'c', 'd']);
    prefetcher.stop();
  });

  test('songs with a local copy are never prepared', () async {
    final fakes = _Fakes()..local.add('a');
    final prefetcher = fakes.build(count: 2)..schedule([a, b, c]);
    await _settle();
    fakes.open('b');
    await _settle();
    fakes.open('c');
    await _settle();
    expect(fakes.started, ['b', 'c']);
    prefetcher.stop();
  });

  test('mobile data prepares a single song ahead', () async {
    final fakes = _Fakes()..network = PrefetchNetwork.metered;
    final prefetcher = fakes.build(count: 3)..schedule([a, b, c]);
    await _settle();
    fakes.open('a');
    await _settle();
    expect(fakes.started, ['a']);
    prefetcher.stop();
  });

  test('offline and a count of zero prepare nothing', () async {
    final fakes = _Fakes()..network = PrefetchNetwork.offline;
    final prefetcher = fakes.build()..schedule([a, b]);
    await _settle();
    expect(fakes.started, isEmpty);
    fakes.network = PrefetchNetwork.unmetered;
    prefetcher.count = 0;
    prefetcher.schedule([a, b]);
    await _settle();
    expect(fakes.started, isEmpty);
    prefetcher.stop();
  });

  test('a long pause drops the work and resuming restarts it', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build(pauseLimit: const Duration(milliseconds: 20))
      ..schedule([a, b]);
    await _settle();
    prefetcher.setPaused(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(fakes.cancelled, ['a']);
    fakes.open('b');
    await _settle();
    expect(fakes.started, ['a']);
    fakes.gates.remove('a');
    fakes.open('a');
    prefetcher.setPaused(false);
    await _settle();
    expect(fakes.started, ['a', 'a', 'b']);
    prefetcher.stop();
  });

  test('a short pause keeps preparing', () async {
    final fakes = _Fakes();
    final prefetcher = fakes.build()..schedule([a]);
    await _settle();
    prefetcher.setPaused(true);
    prefetcher.setPaused(false);
    fakes.open('a');
    await _settle();
    expect(fakes.cancelled, isEmpty);
    expect(fakes.finished, ['a']);
    prefetcher.stop();
  });

  test('network classification favours unmetered links', () {
    expect(
      prefetchNetworkFor([ConnectivityResult.none]),
      PrefetchNetwork.offline,
    );
    expect(
      prefetchNetworkFor([ConnectivityResult.mobile, ConnectivityResult.wifi]),
      PrefetchNetwork.unmetered,
    );
    expect(
      prefetchNetworkFor([ConnectivityResult.mobile]),
      PrefetchNetwork.metered,
    );
    expect(
      prefetchNetworkFor([ConnectivityResult.ethernet]),
      PrefetchNetwork.unmetered,
    );
  });

  test('the next song reuses the temporary prepared ahead', () async {
    final root = await Directory.systemTemp.createTemp('prefetch-reuse-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    var downloads = 0;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
      resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) async {
          downloads++;
          return File('${dir.path}/input').writeAsString('audio');
        },
        takeQualityMetadata: (_) => {'provider': 'A'},
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    )..resolveDownloadService = (_, __) async => 'A';
    final next = _track('next');
    expect(await playback.hasLocalCopy(next), isFalse);
    await playback.prefetch(next);
    expect(downloads, 1);
    final lease = await playback
        .acquire(next)
        .timeout(const Duration(seconds: 5));
    expect(downloads, 1);
    expect(await File(lease.path).readAsString(), 'audio');
    await lease.release();
  });
}
