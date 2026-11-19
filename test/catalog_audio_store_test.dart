import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'explicit provider resolves initialized downloader with fallback disabled',
    () async {
      final initialized = Completer<ExtensionState>();
      final selected = resolveCatalogDownloadService(
        'deezer.download',
        () => initialized.future,
        autoFallback: false,
      );
      initialized.complete(
        ExtensionState(
          extensions: [
            Extension(
              id: 'deezer.download',
              name: 'Deezer',
              displayName: 'Deezer',
              version: '1',
              description: '',
              enabled: true,
              status: 'loaded',
              hasDownloadProvider: true,
            ),
          ],
        ),
      );
      final service = await selected;
      expect(service, 'deezer.download');
      const track = Track(
        id: 'spotify-id',
        source: 'spotify',
        name: 'Track',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 120,
      );
      final payload = buildCatalogDownloadPayload(
        track: track,
        directory: Directory('staging'),
        transferId: 'transfer',
        service: service,
        quality: 'LOSSLESS',
        useExtensions: true,
        useFallback: false,
      );
      expect(payload.service, 'deezer.download');
      expect(payload.downloadProvider, 'deezer.download');
      expect(payload.providerTrackId, isEmpty);
      expect(payload.spotifyId, 'spotify-id');
      expect(payload.useFallback, isFalse);
      final fallbackPayload = buildCatalogDownloadPayload(
        track: track,
        directory: Directory('staging'),
        transferId: 'transfer',
        service: service,
        quality: 'LOSSLESS',
        useExtensions: true,
        useFallback: true,
      );
      expect(fallbackPayload.service, 'deezer.download');
      expect(fallbackPayload.toJson()['use_fallback'], isTrue);
      expect(payload.toJson()['allow_quality_fallback'], isTrue);
      expect(payload.quality, 'LOSSLESS');
      const ordinary = DownloadRequestPayload(
        trackName: 'a',
        artistName: 'b',
        albumName: 'c',
        outputDir: '.',
        filenameFormat: 'x',
      );
      expect(ordinary.toJson().containsKey('allow_quality_fallback'), isFalse);
      expect(
        await resolveCatalogDownloadService(
          'retired',
          () async => const ExtensionState(),
        ),
        isEmpty,
      );
    },
  );
  late Directory root;
  late DateTime now;
  late CatalogAudioStore store;
  late File source;
  CatalogAudioStore makeStore() => CatalogAudioStore(
    cacheDirectory: Directory(p.join(root.path, 'cache')),
    libraryDirectory: Directory(p.join(root.path, 'library')),
    clock: () => now,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('catalog-store-');
    now = DateTime.utc(2026, 1, 1);
    store = makeStore();
    await store.initialize();
    source = File(p.join(root.path, 'source'));
    await source.writeAsBytes([1, 2, 3]);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test(
    'supported formats retain their extension and bytes when saved',
    () async {
      for (final extension in ['.m4a', '.opus', '.flac', '.mp3', '.wav', '.bin']) {
        final id = 'track$extension';
        final entry = await store.putTemporary(
          id,
          source,
          extension: extension,
        );
        final lease = await store.acquire(id);
        final saved = (await store.promote(id))!;
        expect(saved.path, endsWith(extension));
        expect(await File(saved.path).readAsBytes(), [1, 2, 3]);
        expect(await File(entry.path).exists(), isTrue);
        await lease!.release();
        expect(await File(entry.path).exists(), isFalse);
        final restarted = makeStore();
        await restarted.initialize();
        expect((await restarted.lookup(id))!.path, saved.path);
      }
    },
  );

  test('v5 and v4 variants survive restart and can be promoted', () async {
    const track = 'track-id';
    final v5 = jsonEncode(['catalog-audio-v5', track, 128, 'LOSSLESS', 'soundcloud', true]);
    final v4 = jsonEncode(['catalog-aac-v4', track, 128, 'LOSSLESS', 'deezer', true]);
    await store.putTemporary(v5, source, extension: '.flac');
    await store.putTemporary(v4, source, extension: '.mp3');
    store = makeStore();
    await store.initialize();
    expect(await store.variantsForTrack(track), containsAll([v5, v4]));
    final saved = (await store.promoteVariant(track, v5))!;
    expect(saved.path, endsWith('.flac'));
    expect(await File(saved.path).readAsBytes(), [1, 2, 3]);
    expect(await store.clearTemporary(), 2);
    expect(await File(saved.path).exists(), isTrue);
    for (final extension in ['../wav', '.m3u8', '.json', '.part', '.MP3', '.mp3/evil', '.toolongformat']) {
      await expectLater(store.putTemporary('invalid', source, extension: extension), throwsArgumentError);
    }
  });

  test(
    'quality metadata survives playback, promotion and restart; legacy remains readable',
    () async {
      await store.putTemporary('legacy', source);
      expect((await store.lookup('legacy'))!.qualityMetadata, isEmpty);
      final metadata = DownloadResult.fromMap({
        'requested_quality': 'LOSSLESS',
        'resolved_quality': 'aac_160',
        'quality_fallback_used': true,
        'quality_identity_unverified': true,
        'provider': 'deezer',
        'decryption_key': 'secret',
      }).qualityMetadata;
      await store.putTemporary('quality', source, qualityMetadata: metadata);
      await store.putTemporary('verified-output', source, qualityMetadata: {
        'output_codec': 'aac',
        'output_decode_validated': true,
      });
      await store.putTemporary('ambiguous-format', source, extension: '.bin', qualityMetadata: {
        'output_container': 'mov,mp4,m4a,3gp,3g2,mj2',
        'output_validation': 'decode_unverified',
        'output_decode_validated': false,
      });
      await store.recordPlayback('quality');
      await store.promote('quality');
      final restarted = makeStore();
      await restarted.initialize();
      expect((await restarted.lookup('quality'))!.qualityMetadata, metadata);
      expect((await restarted.lookup('verified-output'))!.qualityMetadata, {
        'output_codec': 'aac',
        'output_decode_validated': true,
      });
      expect((await restarted.lookup('ambiguous-format'))!.qualityMetadata, {
        'output_container': 'mov,mp4,m4a,3gp,3g2,mj2',
        'output_validation': 'decode_unverified',
        'output_decode_validated': false,
      });
      expect(metadata, {
        'requested_quality': 'LOSSLESS',
        'resolved_quality': 'aac_160',
        'quality_fallback_used': true,
        'quality_identity_unverified': true,
        'provider': 'deezer',
      });
      expect((await restarted.lookup('legacy'))!.qualityMetadata, isEmpty);
      expect(
        DownloadResult.fromMap({
          'provider': 'https://host/?token=secret',
        }).qualityMetadata,
        isEmpty,
      );
    },
  );

  test('providers are not barred from promotion by identity', () async {
    for (final provider in ['soundcloud', 'YouTube', 'ytmusic-spotiflac']) {
      final entry = await store.putTemporary(provider, source, qualityMetadata: {'provider': provider});
      final lease = (await store.acquire(provider))!;
      expect(await store.promoteLease('saved-$provider', lease), isNotNull);
      expect(await store.promoteVariant('variant-$provider', provider), isNotNull);
      expect(await store.promote(provider), isNotNull);
      expect(await File(entry.path).readAsBytes(), [1, 2, 3]);
      expect((await store.lookup(provider))!.persistent, isTrue);
      await lease.release();
    }
  });

  test('playback does not promote without verified download equivalence', () async {
    const track = Track(id: 'a', source: 'spotify', name: 'A', artistName: 'Artist', albumName: 'Album', duration: 1);
    final playback = CatalogPlayback(storage: store, savedLookup: (_) async => true);
    final id = playback.key(track);
    final allowed = jsonEncode(['catalog-aac-v4', id, 128, 'LOSSLESS', 'deezer', true]);
    final restricted = jsonEncode(['catalog-aac-v4', id, 128, 'LOSSLESS', 'soundcloud', true]);
    await store.putTemporary(allowed, source, qualityMetadata: {'provider': 'deezer'});
    now = now.add(const Duration(seconds: 1));
    final cached = await store.putTemporary(restricted, source, qualityMetadata: {'provider': 'soundcloud'});
    expect(await playback.promote(track), isFalse);
    expect(await store.lookup(id), isNull);
    expect((await store.lookup(allowed))!.persistent, isFalse);
    expect((await store.lookup(restricted))!.persistent, isFalse);
    expect(await File(cached.path).exists(), isTrue);
  });

  test('acquire hides sensitive exception details', () async {
    const track = Track(
      id: 'a',
      name: 'A',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async =>
          throw Exception('https://example.com/?token=secret'),
    );
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.toString(),
          'safe error',
          'CatalogPlaybackException: preparation failed',
        ),
      ),
    );
  });

  for (final unsupportedFormat in [true, false]) {
    test(
      'acquire safely reports unsupported or invalid original audio: $unsupportedFormat',
      () async {
        const track = Track(
          id: 'secret-token',
          name: 'A',
          artistName: 'B',
          albumName: 'C',
          duration: 1,
        );
        var converted = false;
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => false,
          preparerFactory: (_) => TemporaryTrackPreparer(
            stagingRoot: Directory(p.join(root.path, 'staging')),
            download: (dir, _) =>
                File(p.join(dir.path, 'input')).writeAsString('audio'),
            cancelDownload: (_) async {},
            codec: (_) async => 'mp3',
            container: (_) async => unsupportedFormat ? 'ogg' : 'mp3',
            validate: (_) async => false,
          ),
        );
        await expectLater(
          playback.acquire(track),
          throwsA(
            isA<CatalogPlaybackException>().having(
              (e) => e.category,
              'category',
              'preparation failed',
            ),
          ),
        );
        expect(converted, isFalse);
      },
    );
  }

  test('cancelled preparation A cannot replace or publish after B', () async {
    const a = Track(
      id: 'a',
      source: 'spotify',
      name: 'A',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    const b = Track(
      id: 'b',
      source: 'spotify',
      name: 'B',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 1,
    );
    final aStarted = Completer<Directory>();
    final releaseA = Completer<void>();
    var cancelled = false;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
      preparerFactory: (track) => TemporaryTrackPreparer(
        stagingRoot: Directory(p.join(root.path, 'staging')),
        download: (directory, _) async {
          if (track.id == 'a') {
            aStarted.complete(directory);
            await releaseA.future;
          }
          final file = File(p.join(directory.path, 'input'));
          await file.writeAsBytes(track.id == 'a' ? [1] : [2]);
          return file;
        },
        cancelDownload: (_) async {
          cancelled = true;
        },
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    );
    final old = playback
        .acquire(a)
        .then<Object>((lease) => lease, onError: (Object error) => error);
    final aStaging = await aStarted.future;
    await playback.cancel(a);
    final current = await playback.acquire(b);
    expect(await File(current.path).readAsBytes(), [2]);
    releaseA.complete();
    expect(await old, isA<Exception>());
    // Consumer cancellation can complete while the preparer still owns staging.
    final cleanupWait = Stopwatch()..start();
    var stagingExists = await aStaging.exists();
    while (stagingExists && cleanupWait.elapsed < const Duration(seconds: 5)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      stagingExists = await aStaging.exists();
    }
    expect(stagingExists, isFalse, reason: 'A must finish cleaning up staging');
    expect(cancelled, isTrue);
    expect(
      await store.lookup(
        jsonEncode([
          'catalog-aac-v4',
          playback.key(a),
          128,
          'LOSSLESS',
          '',
          true,
        ]),
      ),
      isNull,
    );
    expect((await store.lookup(current.id))?.path, current.path);
    await current.release();
  });

  test(
    'automatic cleanup removes eight-day audio without downloading',
    () async {
      await store.putTemporary('old', source);
      final cleaned = Completer<void>();
      var runs = 0;
      final scheduler = CatalogCleanupScheduler(() async {
        final count = await store.cleanupExpired();
        if (++runs == 1) {
          expect(count, 0);
          now = now.add(const Duration(days: 8));
        } else if (!cleaned.isCompleted) {
          expect(count, 1);
          cleaned.complete();
        }
        return count;
      }, interval: const Duration(milliseconds: 30));
      scheduler.start();
      await cleaned.future;
      scheduler.stop();
      expect(await store.lookup('old'), isNull);
    },
  );

  test(
    'catalog identity matches ISRC across providers and distinguishes IDs otherwise',
    () {
      const a = Track(
        id: 'one',
        source: 'spotify',
        isrc: 'usabc1234567',
        name: 'A',
        artistName: 'A',
        albumName: 'A',
        duration: 1,
      );
      const b = Track(
        id: 'two',
        source: 'deezer',
        isrc: 'USABC1234567',
        name: 'A',
        artistName: 'A',
        albumName: 'A',
        duration: 1,
      );
      expect(catalogPlayback.key(a), catalogPlayback.key(b));
      expect(
        catalogPlayback.key(a.copyWith(isrc: '')),
        isNot(catalogPlayback.key(b.copyWith(isrc: ''))),
      );
    },
  );

  test(
    'TTL is renewed only by actual playback and persists after restart',
    () async {
      await store.putTemporary('../untrusted', source);
      now = now.add(const Duration(days: 6));
      await store.lookup('../untrusted');
      await store.recordPlayback('../untrusted');
      store = makeStore();
      await store.initialize();
      now = now.add(const Duration(days: 6));
      expect(await store.cleanupExpired(), 0);
      now = now.add(const Duration(days: 1));
      expect(await store.cleanupExpired(), 1);
      expect(await store.lookup('../untrusted'), isNull);
    },
  );

  test(
    'promotion survives restart and an active lease retains its old path',
    () async {
      await store.putTemporary('track', source);
      final lease = (await store.acquire('track'))!;
      final promoted = (await store.promote('track'))!;
      expect(promoted.persistent, isTrue);
      expect(await File(lease.path).exists(), isTrue);
      await lease.release();
      expect(await File(lease.path).exists(), isFalse);
      store = makeStore();
      await store.initialize();
      now = now.add(const Duration(days: 30));
      expect(await store.cleanupExpired(), 0);
      expect(await File((await store.lookup('track'))!.path).readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test('cleanup leaves leased temporary audio until a later cleanup', () async {
    await store.putTemporary('track', source);
    final lease = (await store.acquire('track'))!;
    now = now.add(const Duration(days: 8));
    expect(await store.cleanupExpired(), 0);
    await lease.release();
    expect(await store.cleanupExpired(), 1);
  });

  test('rejects nested storage roots', () async {
    final invalid = CatalogAudioStore(
      cacheDirectory: root,
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await expectLater(invalid.initialize(), throwsArgumentError);
  });

  test('failed promotion preserves the published temporary copy', () async {
    await store.putTemporary('track', source);
    final original = (await store.lookup('track'))!;
    store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
      clock: () => now,
      copyFile: (_, _) async => throw FileSystemException('copy failed'),
    );
    await store.initialize();
    await expectLater(
      store.promote('track'),
      throwsA(isA<FileSystemException>()),
    );
    expect((await store.lookup('track'))!.path, original.path);
    expect(await File(original.path).readAsBytes(), [1, 2, 3]);
  });

  test('incomplete publication is ignored on restart', () async {
    await store.putTemporary('track', source);
    final original = (await store.lookup('track'))!;
    await File(
      p.join(root.path, 'library', 'interrupted.part'),
    ).writeAsString('partial');
    store = makeStore();
    await store.initialize();
    expect((await store.lookup('track'))!.path, original.path);
  });

  test(
    'restart after clock rollback keeps promotion as newest publication',
    () async {
      await store.putTemporary('track', source);
      now = now.subtract(const Duration(days: 100));
      store = makeStore();
      await store.initialize();
      final promoted = (await store.promote('track'))!;
      store = makeStore();
      await store.initialize();
      expect((await store.lookup('track'))!.path, promoted.path);
      expect((await store.lookup('track'))!.persistent, isTrue);
    },
  );

  test(
    'restart preserves recent abandoned files until eligible cleanup',
    () async {
      final original = await store.putTemporary('track', source);
      final lease = (await store.acquire('track'))!;
      final promoted = (await store.promote('track'))!;
      expect(await File(original.path).exists(), isTrue);
      final part = File('${original.path}.part');
      final unrelated = File(p.join(root.path, 'cache', 'someone-else.part'));
      await part.writeAsString('partial');
      await unrelated.writeAsString('keep');
      // Simulates process termination while the old lease was still held.
      store = makeStore();
      await store.initialize();
      expect(await File(original.path).exists(), isTrue);
      expect(await part.exists(), isTrue);
      expect(await unrelated.exists(), isTrue);
      expect(await File(promoted.path).exists(), isTrue);
      // The old process no longer exists in production; do not release its lease.
      expect(lease.path, original.path);
    },
  );

  test('clearTemporary skips leased and persistent entries', () async {
    await store.putTemporary('leased', source);
    final lease = (await store.acquire('leased'))!;
    await store.putTemporary('remove', source);
    await store.putTemporary('saved', source);
    await store.promote('saved');
    expect(await store.clearTemporary(), 1);
    expect(await store.lookup('remove'), isNull);
    expect(await store.lookup('leased'), isNotNull);
    expect((await store.lookup('saved'))!.persistent, isTrue);
    await lease.release();
    expect(await store.clearTemporary(), 1);
  });

  test('successful updates keep only one manifest per item', () async {
    await store.putTemporary('track', source);
    for (var i = 0; i < 10; i++) {
      await store.recordPlayback('track');
    }
    final manifests = await Directory(
      p.join(root.path, 'library'),
    ).list().where((entity) => entity.path.endsWith('.json')).toList();
    expect(manifests, hasLength(1));
  });
  test(
    'expired manifests are removed across restart and protected entries survive',
    () async {
      for (var i = 0; i < 80; i++) {
        await store.putTemporary('expired-$i', source);
      }
      await store.putTemporary('protected', source);
      now = now.add(const Duration(days: 8));
      expect(await store.cleanupExpired(protectedIds: {'protected'}), 80);
      expect(
        await Directory(
          p.join(root.path, 'library'),
        ).list().where((e) => e.path.endsWith('.json')).length,
        1,
      );
      store = makeStore();
      await store.initialize();
      expect(await store.lookup('protected'), isNotNull);
      expect(await store.cleanupExpired(), 1);
      expect(
        await Directory(
          p.join(root.path, 'library'),
        ).list().where((e) => e.path.endsWith('.json')).length,
        0,
      );
    },
  );

  test('queued promotion and cleanup preserve saved audio', () async {
    await store.putTemporary('saved-concurrent', source);
    now = now.add(const Duration(days: 8));
    final promotion = store.promote('saved-concurrent');
    final cleanup = store.cleanupExpired();
    expect((await promotion)!.persistent, isTrue);
    expect(await cleanup, 0);
    expect((await store.lookup('saved-concurrent'))!.persistent, isTrue);
  });

  test(
    'failed playback manifest write protects audio until reconciliation',
    () async {
      var fail = false;
      final guardedStore = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
        clock: () => now,
        writeManifest: (file, contents) async {
          if (fail) {
            await file.writeAsString('partial', flush: true);
            throw const FileSystemException('disk full');
          }
          await file.writeAsString(contents, flush: true);
        },
      );
      await guardedStore.initialize();
      final audio = await guardedStore.putTemporary('played', source);
      await guardedStore.putTemporary('other', source);
      now = now.add(const Duration(days: 8));
      fail = true;
      await expectLater(
        guardedStore.recordPlayback('played'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await guardedStore.cleanupExpired(), 1);
      expect(await guardedStore.clearTemporary(), 0);
      expect(await File(audio.path).exists(), isTrue);
      fail = false;
      await guardedStore.recordPlayback('played');
      expect(await guardedStore.cleanupExpired(), 0);
      now = now.add(const Duration(days: 7));
      expect(await guardedStore.cleanupExpired(), 1);
      expect(await File(audio.path).exists(), isFalse);
    },
  );

  test(
    'cleanup protects saved temporary audio and rejects corrupt preferences',
    () async {
      const saved = Track(
        id: 'saved',
        source: 'spotify',
        name: 'Saved',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      const savedOther = Track(
        id: 'saved-other',
        source: 'spotify',
        name: 'Saved other',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      const unsaved = Track(
        id: 'unsaved',
        source: 'spotify',
        name: 'Unsaved',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      final playback = CatalogPlayback(storage: store);
      final savedAudio = await store.putTemporary(playback.key(saved), source);
      await store.putTemporary(playback.key(savedOther), source);
      final unsavedAudio = await store.putTemporary(
        playback.key(unsaved),
        source,
      );
      now = now.add(const Duration(days: 8));
      SharedPreferences.setMockInitialValues({
        'saved_library_tracks_v1': jsonEncode([
          saved.toJson(),
          savedOther.toJson(),
        ]),
      });
      final failingStore = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
        clock: () => now,
      );
      await failingStore.initialize();
      final failingPlayback = CatalogPlayback(storage: failingStore);
      expect(await failingPlayback.cleanupExpired(), 1);
      expect(await File(savedAudio.path).exists(), isTrue);
      expect(await File(unsavedAudio.path).exists(), isFalse);
      expect(await failingStore.lookup(playback.key(saved)), isNotNull);
      expect(
        (await failingStore.lookup(playback.key(savedOther)))!.persistent,
        isFalse,
      );

      await store.putTemporary(playback.key(unsaved), source);
      now = now.add(const Duration(days: 8));
      SharedPreferences.setMockInitialValues({
        'saved_library_tracks_v1': '{broken',
      });
      await expectLater(
        failingPlayback.cleanupExpired(),
        throwsFormatException,
      );
      expect(await failingStore.lookup(playback.key(unsaved)), isNotNull);
      expect(await File(savedAudio.path).exists(), isTrue);
    },
  );
}
