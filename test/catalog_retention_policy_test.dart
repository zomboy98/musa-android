import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late CatalogAudioStore store;
  late DateTime now;

  Track trackOf(int n) => Track(
    id: 'ret-$n',
    source: 'spotify',
    name: 'T$n',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('musa-retention-policy-');
    now = DateTime.utc(2026, 1, 1);
    store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
      clock: () => now,
    );
    await store.initialize();
  });
  tearDown(() => root.delete(recursive: true));

  String variant(CatalogPlayback playback, Track track) => jsonEncode([
    'catalog-audio-v5',
    playback.key(track),
    128,
    'aac_160',
    'a',
    true,
  ]);

  Future<void> put(
    CatalogPlayback playback,
    Track track,
    int bytes,
    int age,
  ) async {
    final input = File('${root.path}/in-${track.id}');
    await input.writeAsBytes(List.filled(bytes, 1));
    await store.putTemporary(
      variant(playback, track),
      input,
      extension: '.m4a',
      qualityMetadata: {'provider': 'a'},
    );
    final entry = await store.lookup(variant(playback, track));
    await File(
      entry!.path,
    ).setLastModified(DateTime.utc(2026, 1, 1).add(Duration(minutes: age)));
  }

  Future<bool> present(CatalogPlayback playback, Track track) async =>
      await store.lookup(variant(playback, track)) != null;

  test('el tope LRU quita primero lo menos usado y respeta lo protegido',
      () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    );
    for (var n = 1; n <= 5; n++) {
      await put(playback, trackOf(n), 100, n);
    }
    final lines = <String>[];
    final evicted = await store.enforceTemporaryBudget(
      maxBytes: 250,
      protectedTracks: {playback.key(trackOf(1))},
      trace: lines.add,
    );
    expect(evicted, 3);
    expect(await present(playback, trackOf(1)), isTrue);
    expect(await present(playback, trackOf(2)), isFalse);
    expect(await present(playback, trackOf(3)), isFalse);
    expect(await present(playback, trackOf(4)), isFalse);
    expect(await present(playback, trackOf(5)), isTrue);
    expect(lines.every((l) => l.startsWith('retention: evict')), isTrue);
  });

  test('una pista con lease activo nunca se expulsa por el tope', () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    );
    await put(playback, trackOf(1), 100, 1);
    await put(playback, trackOf(2), 100, 2);
    final lease = await store.acquire(variant(playback, trackOf(1)));
    await store.enforceTemporaryBudget(maxBytes: 50);
    expect(await present(playback, trackOf(1)), isTrue);
    expect(await present(playback, trackOf(2)), isFalse);
    await lease!.release();
  });

  test('se retienen las 3 anteriores y la actual aunque el tope sea minimo',
      () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    );
    for (var n = 1; n <= 6; n++) {
      await put(playback, trackOf(n), 100, n);
    }
    for (var n = 1; n <= 6; n++) {
      final lease = await store.acquire(variant(playback, trackOf(n)));
      playback.selectLease(trackOf(n), lease!);
      await lease.release();
    }
    final evicted = await playback.enforceTemporaryBudget(maxBytes: 0);
    expect(evicted, 2);
    expect(await present(playback, trackOf(1)), isFalse);
    expect(await present(playback, trackOf(2)), isFalse);
    for (var n = 3; n <= 6; n++) {
      expect(await present(playback, trackOf(n)), isTrue);
    }
  });

  test('el TTL de temporales sigue quitando lo viejo y conserva lo reciente',
      () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    );
    await put(playback, trackOf(1), 10, 0);
    final fresh = trackOf(2);
    await put(playback, fresh, 10, 0);
    now = DateTime.utc(2026, 1, 5);
    await File(
      (await store.lookup(variant(playback, fresh)))!.path,
    ).setLastModified(now);
    now = DateTime.utc(2026, 1, 10);
    await store.cleanupExpired();
    expect(await present(playback, trackOf(1)), isFalse);
    expect(await present(playback, fresh), isTrue);
  });

  group('preparacion', () {
    Future<(CatalogPlayback, List<String>, Completer<void>)> build() async {
      final gate = Completer<void>();
      final downloads = <String>[];
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => false,
              resolvedPreparerFactory: (track, service, _) =>
                  TemporaryTrackPreparer(
                    stagingRoot: Directory(p.join(root.path, 'staging')),
                    download: (directory, _) async {
                      downloads.add(track.id);
                      if (track.id == 'ret-1') await gate.future;
                      return File(
                        p.join(directory.path, 'input'),
                      ).writeAsBytes([1, 2, 3]);
                    },
                    takeQualityMetadata: (_) => {'provider': service},
                    cancelDownload: (_) async {},
                    codec: (_) async => 'aac',
                    container: (_) async => 'mp4',
                    validate: (_) async => true,
                  ),
            )
            ..defaultService = 'a'
            ..resolveDownloadService = (requested, _) async =>
                requested.isEmpty ? 'a' : requested;
      playback.resolveStreaming = (quality, service, _) async =>
          StreamingRequest(service.isEmpty ? 'a' : service, 'aac_160');
      return (playback, downloads, gate);
    }

    test('volver a una pista ya escuchada no la descarga otra vez', () async {
      final (playback, downloads, gate) = await build();
      gate.complete();
      final first = await playback.acquire(trackOf(1), initial: true);
      playback.selectLease(trackOf(1), first);
      await first.release();
      final other = await playback.acquire(trackOf(2), initial: true);
      playback.selectLease(trackOf(2), other);
      await other.release();
      final again = await playback.acquire(trackOf(1), initial: true);
      await again.release();
      expect(downloads, ['ret-1', 'ret-2']);
    });

    test('saltar de pista durante la descarga la deja terminar y se reutiliza',
        () async {
      final (playback, downloads, gate) = await build();
      final pending = playback
          .acquire(trackOf(1), initial: true)
          .then<Object?>((lease) => lease, onError: (Object e) => e);
      for (var i = 0; i < 200 && downloads.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(downloads, ['ret-1']);
      await playback.cancel(trackOf(1), retain: true);
      expect(await pending, isA<CatalogPlaybackException>());
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final back = await playback.acquire(trackOf(1), initial: true);
      await back.release();
      expect(downloads, ['ret-1']);
    });

    test('sin retener, saltar descarta la descarga en curso', () async {
      final (playback, downloads, gate) = await build();
      final pending = playback
          .acquire(trackOf(1), initial: true)
          .then<Object?>((lease) => lease, onError: (Object e) => e);
      for (var i = 0; i < 200 && downloads.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await playback.cancel(trackOf(1));
      expect(await pending, isA<CatalogPlaybackException>());
      gate.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await store.lookup(variantForTest(playback, trackOf(1))), isNull);
    });
  });
}

String variantForTest(CatalogPlayback playback, Track track) => jsonEncode([
  'catalog-audio-v5',
  playback.key(track),
  128,
  'aac_160',
  'a',
  true,
]);
