import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingStore extends CatalogAudioStore {
  _CountingStore({
    required super.cacheDirectory,
    required super.libraryDirectory,
  });
  var scans = 0;
  @override
  Future<Map<String, List<String>>> variantsForTracks(Set<String> ids) {
    scans++;
    return super.variantsForTracks(ids);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: 'q',
    source: 'spotify',
    name: 'Q',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );

  test('cleanup preserves only referenced temporary audio without promotion', () async {
    const second = Track(id: 'two', source: 'spotify', name: 'Two', artistName: 'A', albumName: 'B', duration: 1);
    SharedPreferences.setMockInitialValues({'saved_library_tracks_v1': jsonEncode([track.toJson(), second.toJson()])});
    final root = await Directory.systemTemp.createTemp('cleanup-snapshot-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(cacheDirectory: Directory('${root.path}/cache'), libraryDirectory: Directory('${root.path}/library'));
    await store.initialize();
    final playback = CatalogPlayback(storage: store);
    final source = await File('${root.path}/source').writeAsString('audio');
    for (final item in [track, second]) {
      await store.putTemporary(jsonEncode(['catalog-aac-v4', playback.key(item), 128, 'LOSSLESS', 'A', true]), source, extension: '.m4a', qualityMetadata: {'provider': 'A'});
    }
    await (await SharedPreferences.getInstance()).setString('saved_library_tracks_v1', jsonEncode([track.toJson()]));
    await playback.clearTemporary();
    final firstVariant = jsonEncode(['catalog-aac-v4', playback.key(track), 128, 'LOSSLESS', 'A', true]);
    final secondVariant = jsonEncode(['catalog-aac-v4', playback.key(second), 128, 'LOSSLESS', 'A', true]);
    expect(await store.lookup(firstVariant), isNotNull);
    expect(await store.lookup(secondVariant), isNull);
    expect(await store.lookup(playback.key(track)), isNull);
  });

  test('re-added save does not wait for retained playback preparation', () async {
    final root = await Directory.systemTemp.createTemp('pending-retained-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(cacheDirectory: Directory('${root.path}/cache'), libraryDirectory: Directory('${root.path}/library'));
    await store.initialize();
    final resolving = Completer<void>(), provider = Completer<String>();
    final started = Completer<void>(), finish = Completer<void>();
    var saved = false;
    final playback = CatalogPlayback(storage: store, savedLookup: (_) async => saved,
      resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) async { if (!started.isCompleted) started.complete(); await finish.future; return File('${dir.path}/input').writeAsString('audio'); },
        takeQualityMetadata: (_) => {'provider': 'A'}, cancelDownload: (_) async {}, codec: (_) async => 'aac', container: (_) async => 'mp4',
        validate: (_) async => true),
    )..resolveDownloadService = (_, __) { if (!resolving.isCompleted) resolving.complete(); return provider.future; };
    final old = playback.acquire(track).then<Object>((v) => v, onError: (Object e) => e);
    await resolving.future; saved = true;
    await playback.cancel(track); expect(await old, isA<CatalogPlaybackException>());
    provider.complete('A'); await started.future;
    saved = false; saved = true;
    final pending = playback.pendingSavedPromotion(track);
    expect(pending, isNull);
    final reacquired = playback.acquire(track);
    finish.complete();
    final lease = await reacquired.timeout(const Duration(seconds: 5));
    expect(await File(lease.path).readAsString(), 'audio');
    expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
    await lease.release();
  });

  for (final selected in [false, true]) {
    for (final readded in [false, true]) {
      test(
        'direct promotion respects removal while copying selected=$selected readded=$readded',
        () async {
          final root = await Directory.systemTemp.createTemp('direct-copy-');
          addTearDown(() => root.delete(recursive: true));
          final copying = Completer<void>();
          final finish = Completer<void>();
          final store = CatalogAudioStore(
            cacheDirectory: Directory('${root.path}/cache'),
            libraryDirectory: Directory('${root.path}/library'),
            copyFile: (source, destination) async {
              if (destination.contains(
                '${Platform.pathSeparator}library${Platform.pathSeparator}',
              )) {
                copying.complete();
                await finish.future;
              }
              final output = File(destination).openWrite();
              await output.addStream(source.openRead());
              await output.close();
              return File(destination);
            },
          );
          await store.initialize();
          var saved = true, currentIntention = true;
          final playback = CatalogPlayback(
            storage: store,
            savedLookup: (_) async => saved,
          );
          final source = await File('${root.path}/source').writeAsString('old');
          final variant = jsonEncode([
            'catalog-aac-v4',
            playback.key(track),
            128,
            'LOSSLESS',
            'A',
            true,
          ]);
          await store.putTemporary(
            variant,
            source,
            extension: '.m4a',
            qualityMetadata: {'provider': 'A'},
          );
          final lease = selected ? await store.acquire(variant) : null;
          if (lease != null) playback.selectLease(track, lease);
          final promotion = selected
              ? store.promoteLease(playback.key(track), lease!, canPublish: () async => currentIntention && saved)
              : store.promoteVariant(playback.key(track), variant, canPublish: () async => currentIntention && saved);
          await copying.future.timeout(const Duration(seconds: 5));
          currentIntention = false;
          saved = readded;
          finish.complete();
          expect(await promotion, isNull);
          expect(
            (await store.lookup(playback.key(track)))?.persistent,
            isNot(true),
          );
          await lease?.release();
        },
      );
    }
  }

    test('store does not publish a lease released during copy', () async {
      final root = await Directory.systemTemp.createTemp('released-copy-');
      addTearDown(() => root.delete(recursive: true));
      final firstCopy = Completer<void>();
      final finishFirstCopy = Completer<void>();
      addTearDown(() {
        if (!finishFirstCopy.isCompleted) finishFirstCopy.complete();
      });
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        clock: () => DateTime.utc(2026),
        copyFile: (source, destination) async {
          if (destination.contains(
            '${Platform.pathSeparator}library${Platform.pathSeparator}',
          )) {
            firstCopy.complete();
            await finishFirstCopy.future;
          }
          final output = File(destination).openWrite();
          await output.addStream(source.openRead());
          await output.close();
          return File(destination);
        },
      );
      await store.initialize();
      var saved = true;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => saved,
      );
      final id = playback.key(track);
      final variant = jsonEncode(['catalog-aac-v4', id, 128, 'LOSSLESS', 'A', true]);
      final older = await File('${root.path}/older').writeAsString('older');
      await store.putTemporary(id, older, extension: '.m4a');
      final selected = await File('${root.path}/selected').writeAsString('selected');
      await store.putTemporary(variant, selected, extension: '.m4a');
      final lease = (await store.acquire(variant))!;
      playback.selectLease(track, lease);
      await store.recordPlaybackLease(lease);
      final promoted = store.promoteLease(id, lease, canPublish: () async => saved);
      await firstCopy.future.timeout(const Duration(seconds: 5));
      final released = lease.release();
      finishFirstCopy.complete();
      await released;
      expect(await promoted, isNull);
      final entry = await store.lookup(id);
      expect(entry?.persistent, isFalse);
      expect(await File(entry!.path).readAsString(), 'older');
    });

  test(
    'failed retained preparation settles reacquisition without blocking save',
    () async {
      final root = await Directory.systemTemp.createTemp('retained-failure-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final entered = Completer<void>();
      final resolver = Completer<String>();
      final started = Completer<void>();
      final fail = Completer<void>();
      var saved = false, resolutions = 0;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => saved,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (_, __) async {
                  started.complete();
                  await fail.future;
                  throw StateError('download failed');
                },
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..resolveDownloadService = (_, __) {
              if (++resolutions == 1) entered.complete();
              return resolver.future;
            };
      final first = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(await first, isA<CatalogPlaybackException>());
      resolver.complete('A');
      await started.future;
      final reacquired = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      while (resolutions < 2) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(playback.pendingSavedPromotion(track), isNull);
      fail.complete();
      expect(await reacquired, isA<CatalogPlaybackException>());
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
    },
  );

  test(
    'saving does not wait for active preparation or unresolved request',
    () async {
      final root = await Directory.systemTemp.createTemp('mixed-pending-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final started = Completer<void>(),
          finish = Completer<void>(),
          entered = Completer<void>();
      final blocked = Completer<String>();
      var saved = false, resolutions = 0;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => saved,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (dir, _) async {
                  started.complete();
                  await finish.future;
                  return File('${dir.path}/input').writeAsString('saved');
                },
                takeQualityMetadata: (_) => {'provider': 'A'},
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..resolveDownloadService = (_, __) {
              if (++resolutions == 1) return Future.value('A');
              entered.complete();
              return blocked.future;
            };
      final active = playback.acquire(track);
      await started.future;
      final second = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      blocked.completeError(StateError('resolver unavailable'));
      expect(await second, isA<CatalogPlaybackException>());
      finish.complete();
      final lease = await active;
      expect(await File(lease.path).readAsString(), 'saved');
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
      await lease.release();
    },
  );

  for (final concurrent in [false, true]) {
    test(
      'quality change isolates ${concurrent ? 'in-flight preparation' : 'cached audio'}',
      () async {
        final root = await Directory.systemTemp.createTemp('quality-cache-');
        addTearDown(() => root.delete(recursive: true));
        final store = CatalogAudioStore(
          cacheDirectory: Directory('${root.path}/cache'),
          libraryDirectory: Directory('${root.path}/library'),
        );
        await store.initialize();
        final started = Completer<void>();
        final finish = Completer<void>();
        var count = 0;
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => false,
          preparerFactory: (_) => TemporaryTrackPreparer(
            stagingRoot: Directory('${root.path}/staging'),
            download: (dir, _) async {
              final n = ++count;
              if (n == 1) {
                started.complete();
                if (concurrent) await finish.future;
              }
              return File('${dir.path}/input').writeAsString('audio-$n');
            },
            cancelDownload: (_) async {},
            codec: (_) async => 'aac', container: (_) async => 'mp4',
            validate: (_) async => true,
          ),
        );
        playback.quality = 'LOW';
        final lowFuture = playback.acquire(track);
        await started.future;
        final low = concurrent ? null : await lowFuture;
        playback.quality = 'LOSSLESS';
        final highFuture = playback.acquire(track);
        if (concurrent) {
          // Let a wrongly shared preparation complete without hanging the test.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          finish.complete();
        }
        final high = await highFuture;
        final first = low ?? await lowFuture;
        expect(count, 2);
        expect(first.path, isNot(high.path));
        expect(await File(first.path).readAsString(), 'audio-1');
        expect(await File(high.path).readAsString(), 'audio-2');
        await first.release();
        await high.release();
      },
    );
  }

  test('fallback resolution changes isolate temporary audio', () async {
    final root = await Directory.systemTemp.createTemp('provider-fallback-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    var effective = 'fallback';
    final playback =
        CatalogPlayback(
            storage: store,
            savedLookup: (_) async => false,
            resolvedPreparerFactory: (_, service, __) => TemporaryTrackPreparer(
              stagingRoot: Directory('${root.path}/staging'),
              download: (dir, _) =>
                  File('${dir.path}/input').writeAsString(service),
              cancelDownload: (_) async {},
              codec: (_) async => 'aac', container: (_) async => 'mp4',
              validate: (_) async => true,
            ),
          )
          ..defaultService = 'preferred'
          ..resolveDownloadService = (_, __) async => effective;
    final first = await playback.acquire(track);
    effective = 'preferred';
    final second = await playback.acquire(track);
    expect(await File(first.path).readAsString(), 'fallback');
    expect(await File(second.path).readAsString(), 'preferred');
    await first.release();
    await second.release();
  });

  for (final concurrent in [false, true]) {
    test(
      'backend fallback is isolated when fallback policy changes ${concurrent ? 'during preparation' : 'after caching'}',
      () async {
        final root = await Directory.systemTemp.createTemp('backend-fallback-');
        addTearDown(() => root.delete(recursive: true));
        final store = CatalogAudioStore(
          cacheDirectory: Directory('${root.path}/cache'),
          libraryDirectory: Directory('${root.path}/library'),
        );
        await store.initialize();
        final started = Completer<void>();
        final finish = Completer<void>();
        final policies = <bool>[];
        final playback =
            CatalogPlayback(
                storage: store,
                savedLookup: (_) async => false,
                resolvedPreparerFactory: (_, service, fallback) =>
                    TemporaryTrackPreparer(
                      stagingRoot: Directory('${root.path}/staging'),
                      download: (dir, _) async {
                        policies.add(fallback);
                        if (fallback) {
                          started.complete();
                          if (concurrent) await finish.future;
                        }
                        return File(
                          '${dir.path}/input',
                        ).writeAsString(fallback ? 'B' : 'A');
                      },
                      takeQualityMetadata: (_) => {
                        'provider': fallback ? 'B' : 'A',
                      },
                      cancelDownload: (_) async {},
                      codec: (_) async => 'aac', container: (_) async => 'mp4',
                      validate: (_) async => true,
                    ),
              )
              ..defaultService = 'A'
              ..resolveDownloadService = (_, __) async => 'A';
        final firstFuture = playback.acquire(track);
        await started.future;
        final firstReady = concurrent ? null : await firstFuture;
        playback.useFallback = false;
        final secondFuture = playback.acquire(track);
        if (concurrent) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          finish.complete();
        }
        final first = firstReady ?? await firstFuture;
        final second = await secondFuture;
        expect(policies, [true, false]);
        expect(await File(first.path).readAsString(), 'B');
        expect(await File(second.path).readAsString(), 'A');
        await first.release();
        await second.release();
      },
    );
  }

  test(
    'saved request survives cancellation while provider resolution waits',
    () async {
      final root = await Directory.systemTemp.createTemp('saved-resolving-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final entered = Completer<void>();
      final resolution = Completer<String>();
      var saved = false;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => saved,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (dir, _) =>
                    File('${dir.path}/input').writeAsString('saved'),
                takeQualityMetadata: (_) => {'provider': 'A'},
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..defaultService = 'A'
            ..resolveDownloadService = (_, __) {
              if (!entered.isCompleted) entered.complete();
              return resolution.future;
            };
      final acquired = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(await acquired, isA<CatalogPlaybackException>());
      resolution.complete('A');
      final lease = await playback.acquire(track);
      expect(await File(lease.path).readAsString(), 'saved');
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
      await lease.release();
    },
  );

  for (final reported in [null, 'invalid provider!', 'B']) {
    test('unconfirmed provider metadata $reported is never reused', () async {
      final root = await Directory.systemTemp.createTemp('unknown-provider-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      var count = 0;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) =>
              File('${dir.path}/input').writeAsString('${++count}'),
          takeQualityMetadata: (_) =>
              reported == null ? {} : {'provider': reported},
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      )..resolveDownloadService = (_, __) async => 'A';
      final first = await playback.acquire(track);
      final second = await playback.acquire(track);
      expect(count, 2);
      expect(await File(first.path).readAsString(), '1');
      expect(await File(second.path).readAsString(), '2');
      await first.release();
      await second.release();
    });
  }

  test(
    'unsaved cancellation during resolution never starts download',
    () async {
      final root = await Directory.systemTemp.createTemp('unsaved-resolving-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final entered = Completer<void>();
      final resolution = Completer<String>();
      var downloads = 0;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => false,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (dir, _) async {
                  downloads++;
                  return File('${dir.path}/input').writeAsString('bad');
                },
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..resolveDownloadService = (_, __) {
              entered.complete();
              return resolution.future;
            };
      final result = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(await result, isA<CatalogPlaybackException>());
      resolution.complete('A');
      await Future<void>.delayed(Duration.zero);
      expect(downloads, 0);
    },
  );

  for (final concurrent in [false, true]) {
    test(
      'provider change isolates ${concurrent ? 'in-flight work' : 'cached audio'}',
      () async {
        final root = await Directory.systemTemp.createTemp('provider-cache-');
        addTearDown(() => root.delete(recursive: true));
        final store = CatalogAudioStore(
          cacheDirectory: Directory('${root.path}/cache'),
          libraryDirectory: Directory('${root.path}/library'),
        );
        await store.initialize();
        final started = Completer<void>();
        final finish = Completer<void>();
        final seen = <String>[];
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => false,
          resolvedPreparerFactory: (_, service, __) => TemporaryTrackPreparer(
            stagingRoot: Directory('${root.path}/staging'),
            download: (dir, _) async {
              seen.add(service);
              if (service == 'a') {
                started.complete();
                if (concurrent) await finish.future;
              }
              return File('${dir.path}/input').writeAsString(service);
            },
            takeQualityMetadata: (_) => {'provider': service},
            cancelDownload: (_) async {},
            codec: (_) async => 'aac', container: (_) async => 'mp4',
            validate: (_) async => true,
          ),
        )..resolveDownloadService = (requested, _) async => requested;
        playback.defaultService = 'a';
        final firstFuture = playback.acquire(track);
        await started.future;
        final firstReady = concurrent ? null : await firstFuture;
        if (!concurrent) {
          final cached = await playback.acquire(track);
          expect(cached.path, firstReady!.path);
          expect(seen, ['a']);
          await cached.release();
        }
        playback.defaultService = 'b';
        final secondFuture = playback.acquire(track);
        if (concurrent) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          finish.complete();
        }
        final second = await secondFuture;
        final first = firstReady ?? await firstFuture;
        expect(seen, ['a', 'b']);
        expect(await File(first.path).readAsString(), 'a');
        expect(await File(second.path).readAsString(), 'b');
        await first.release();
        await second.release();
      },
    );
  }

  test(
    'legacy temporary entries of unknown quality are not replayed',
    () async {
      final root = await Directory.systemTemp.createTemp('quality-legacy-');
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
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            downloads++;
            return File('${dir.path}/input').writeAsString('new');
          },
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final source = await File('${root.path}/old').writeAsString('old');
      await store.putTemporary(playback.key(track), source, extension: '.m4a');
      await store.putTemporary(
        jsonEncode(['catalog-aac-v1', playback.key(track), 128]),
        source,
        extension: '.m4a',
      );
      final lease = await playback.acquire(track);
      expect(downloads, 1);
      expect(await File(lease.path).readAsString(), 'new');
      await lease.release();
    },
  );

  test(
    'custom quality remains temporary after playback and restart',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('quality-promotion-');
      addTearDown(() => root.delete(recursive: true));
      CatalogAudioStore newStore() => CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      final store = newStore();
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) =>
              File('${dir.path}/input').writeAsString('custom'),
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      playback.quality = 'provider-custom';
      final lease = await playback.acquire(track);
      await store.recordPlaybackLease(lease);
      await lease.release();
      final restarted = newStore();
      await restarted.initialize();
      final next = CatalogPlayback(storage: restarted);
      expect(await next.promote(track), isFalse);
      final retained = await restarted.lookup(lease.id);
      expect(retained?.persistent, isFalse);
      expect(await File(retained!.path).readAsString(), 'custom');
    },
  );

  test(
    'failed promotion protects custom quality through expiry after restart',
    () async {
      SharedPreferences.setMockInitialValues({
        'saved_library_tracks_v1': jsonEncode([track.toJson()]),
      });
      final root = await Directory.systemTemp.createTemp('quality-protected-');
      addTearDown(() => root.delete(recursive: true));
      var now = DateTime.utc(2026);
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        clock: () => now,
      );
      await store.initialize();
      final playback = CatalogPlayback(storage: store);
      final variant = jsonEncode([
        'catalog-aac-v2',
        playback.key(track),
        128,
        'custom-provider-quality',
      ]);
      final source = await File(
        '${root.path}/source',
      ).writeAsString('protected');
      final temporary = await store.putTemporary(
        variant,
        source,
        extension: '.m4a',
      );
      await store.putTemporary('unrelated', source, extension: '.m4a');
      now = now.add(const Duration(days: 8));
      final restarted = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        clock: () => now,
        copyFile: (_, __) async => throw const FileSystemException('disk full'),
      );
      await restarted.initialize();
      expect(await CatalogPlayback(storage: restarted).cleanupExpired(), 1);
      expect(await File(temporary.path).exists(), isTrue);
      expect(await restarted.lookup(variant), isNotNull);
      expect(await restarted.lookup('unrelated'), isNull);
    },
  );

  test('cleanup discovers variants once for all saved tracks', () async {
    final tracks = [
      for (var n = 0; n < 3; n++)
        Track(
          id: 'saved-$n',
          source: 'spotify',
          name: 'T',
          artistName: 'A',
          albumName: 'B',
          duration: 1,
        ),
    ];
    SharedPreferences.setMockInitialValues({
      'saved_library_tracks_v1': jsonEncode(
        tracks.map((t) => t.toJson()).toList(),
      ),
    });
    final root = await Directory.systemTemp.createTemp('quality-batch-');
    addTearDown(() => root.delete(recursive: true));
    final store = _CountingStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    await CatalogPlayback(storage: store).cleanupExpired();
    expect(store.scans, 1);
  });

  test(
    'saved track does not replay historical temporary across quality changes',
    () async {
      final root = await Directory.systemTemp.createTemp('quality-saved-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => true,
      )..quality = 'LOSSLESS';
      final source = await File(
        '${root.path}/source',
      ).writeAsString('previous');
      final variant = jsonEncode(['catalog-aac-v2', playback.key(track), 128, 'LOW']);
      await store.putTemporary(
        variant,
        source,
        extension: '.m4a',
      );
      await expectLater(playback.acquire(track), throwsA(isA<CatalogPlaybackException>()));
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
      expect(await File((await store.lookup(variant))!.path).readAsString(), 'previous');
    },
  );

  test('saved concurrent resolutions share one retained preparation', () async {
    final root = await Directory.systemTemp.createTemp('resolving-share-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    final entered = Completer<void>();
    final resolution = Completer<String>();
    final downloadStarted = Completer<void>();
    final finish = Completer<void>();
    var resolves = 0, downloads = 0;
    var saved = false;
    final playback =
        CatalogPlayback(
            storage: store,
            savedLookup: (_) async => saved,
            resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
              stagingRoot: Directory('${root.path}/staging'),
              download: (dir, _) async {
                downloads++;
                if (!downloadStarted.isCompleted) downloadStarted.complete();
                await finish.future;
                return File('${dir.path}/input').writeAsString('saved');
              },
              takeQualityMetadata: (_) => {'provider': 'A'},
              cancelDownload: (_) async {},
              codec: (_) async => 'aac', container: (_) async => 'mp4',
              validate: (_) async => true,
            ),
          )
          ..resolveDownloadService = (_, __) {
            if (++resolves == 2) entered.complete();
            return resolution.future;
          };
    final first = playback
        .acquire(track)
        .then<Object>((v) => v, onError: (Object e) => e);
    final second = playback
        .acquire(track)
        .then<Object>((v) => v, onError: (Object e) => e);
    await entered.future;
    saved = true;
    expect(playback.pendingSavedPromotion(track), isNull);
    await playback.cancel(track);
    expect(await first, isA<CatalogPlaybackException>());
    expect(await second, isA<CatalogPlaybackException>());
    resolution.complete('A');
    await downloadStarted.future;
    final reacquired = playback.acquire(track);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    finish.complete();
    final newLease = await reacquired;
    expect(await File(newLease.path).readAsString(), 'saved');
    await newLease.release();
    expect(downloads, 1);
    expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
  });

  test(
    'failed resolution does not hide another saved resolution success',
    () async {
      final root = await Directory.systemTemp.createTemp('resolving-partial-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final entered = Completer<void>();
      final bad = Completer<String>();
      final good = Completer<String>();
      var resolves = 0;
      var saved = false;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => saved,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (dir, _) =>
                    File('${dir.path}/input').writeAsString('saved'),
                takeQualityMetadata: (_) => {'provider': 'A'},
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..resolveDownloadService = (_, __) {
              final n = ++resolves;
              if (n == 2) entered.complete();
              return n == 1 ? bad.future : good.future;
            };
      final first = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      final second = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(await first, isA<CatalogPlaybackException>());
      expect(await second, isA<CatalogPlaybackException>());
      bad.completeError(StateError('unavailable'));
      good.complete('A');
      final lease = await playback.acquire(track).timeout(const Duration(seconds: 5));
      expect(await File(lease.path).readAsString(), 'saved');
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
      await lease.release();
    },
  );

  test(
    'removing saved reference during temporary copy prevents permanent publication',
    () async {
      final root = await Directory.systemTemp.createTemp('saved-copy-');
      addTearDown(() => root.delete(recursive: true));
      final copying = Completer<void>();
      final finishCopy = Completer<void>();
      final copied = Completer<void>();
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        copyFile: (file, destination) async {
          if (destination.contains(
            '${Platform.pathSeparator}cache${Platform.pathSeparator}',
          )) {
            copying.complete();
            await finishCopy.future;
          }
          final out = File(destination).openWrite();
          await out.addStream(file.openRead());
          await out.close();
          copied.complete();
          return File(destination);
        },
      );
      await store.initialize();
      final entered = Completer<void>();
      final resolution = Completer<String>();
      var saved = false;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => saved,
              resolvedPreparerFactory: (_, __, ___) => TemporaryTrackPreparer(
                stagingRoot: Directory('${root.path}/staging'),
                download: (dir, _) =>
                    File('${dir.path}/input').writeAsString('saved'),
                takeQualityMetadata: (_) => {'provider': 'A'},
                cancelDownload: (_) async {},
                codec: (_) async => 'aac', container: (_) async => 'mp4',
                validate: (_) async => true,
              ),
            )
            ..resolveDownloadService = (_, __) {
              entered.complete();
              return resolution.future;
            };
      final acquired = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await entered.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(await acquired, isA<CatalogPlaybackException>());
      resolution.complete('A');
      await copying.future.timeout(const Duration(seconds: 5));
      saved = false;
      await playback.cancel(track);
      finishCopy.complete();
      await copied.future.timeout(const Duration(seconds: 5));
      expect(
        (await store.lookup(playback.key(track)))?.persistent,
        isNot(true),
      );
    },
  );
}
