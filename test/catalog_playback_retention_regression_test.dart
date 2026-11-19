import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: 't',
    source: 'spotify',
    name: 'T',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );
  late Directory root;
  late CatalogAudioStore store;
  late DateTime now;
  setUp(() async {
    ProviderRequestGate.instance = ProviderRequestGate();
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('musa-retention-profile-');
    now = DateTime.utc(2026);
    store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
      clock: () => now,
    );
    await store.initialize();
  });
  tearDown(() => root.delete(recursive: true));

  String variant(
    CatalogPlayback playback,
    int bitrate, [
    String service = 'test-provider',
  ]) => jsonEncode([
    'catalog-audio-v5',
    playback.key(track),
    bitrate,
    'LOSSLESS',
    service,
    true,
  ]);

  test('released variant remains available without unverified promotion', () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    )..resolveDownloadService = (_, _) async => 'test-provider';
    final input = await File('${root.path}/input').writeAsString('old-128');
    await store.putTemporary(
      variant(playback, 128),
      input,
      extension: '.m4a',
      qualityMetadata: {'provider': 'test-provider'},
    );
    final lease = await playback.acquire(track);
    playback.selectLease(track, lease);
    await store.recordPlayback(lease.id);
    await lease.release();
    expect(await playback.promote(track), isFalse);
    final saved = await store.lookup(lease.id);
    expect(saved?.persistent, isFalse);
    expect(await File(saved!.path).readAsString(), 'old-128');
    final reused = await playback.acquire(track);
    expect(await File(reused.path).readAsString(), 'old-128');
    await reused.release();
  });

  test('acquire does not promote after a saved reference is removed', () async {
    var reads = 0;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => ++reads == 1,
    )..resolveDownloadService = (_, _) async => 'test-provider';
    final id = variant(playback, 128);
    final input = await File('${root.path}/removed-save').writeAsString('cached');
    await store.putTemporary(
      id,
      input,
      extension: '.m4a',
      qualityMetadata: {'provider': 'test-provider'},
    );
    final retired = (await store.acquire(id))!;
    playback.selectLease(track, retired);
    await retired.release();

    final lease = await playback.acquire(track);
    addTearDown(lease.release);
    expect(lease.id, id);
    expect(await store.lookup(playback.key(track)), isNull);
    expect(await File(lease.path).readAsString(), 'cached');

    expect(await playback.promote(track), isFalse);
    expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
  });

  test('released and restarted variant remains temporary offline', () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    )..resolveDownloadService = (_, _) async => 'test-provider';
    final input = await File('${root.path}/input').writeAsString('old-128');
    await store.putTemporary(
      variant(playback, 128),
      input,
      extension: '.m4a',
      qualityMetadata: {'provider': 'test-provider'},
    );
    final lease = await playback.acquire(track);
    playback.selectLease(track, lease);
    await store.recordPlayback(lease.id);
    await lease.release();
    final restarted = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
      clock: () => now,
    );
    await restarted.initialize();
    final offline = CatalogPlayback(
      storage: restarted,
      savedLookup: (_) async => false,
    )..playbackBitrateKbps = 256;
    expect(await offline.promote(track), isFalse);
    final saved = await restarted.lookup(lease.id);
    expect(saved?.persistent, isFalse);
    expect(await File(saved!.path).readAsString(), 'old-128');
  });

  test('saved preparation remains temporary after previous selection retired', () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => true,
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) =>
            File('${dir.path}/source').writeAsString('new-256'),
        cancelDownload: (_) async {},
        codec: (_) async => 'aac', container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    )..playbackBitrateKbps = 256;
    final old = await File('${root.path}/previous').writeAsString('old-128');
    await store.putTemporary(variant(playback, 128), old, extension: '.m4a');
    final retired = (await store.acquire(variant(playback, 128)))!;
    playback.selectLease(track, retired);
    await retired.release();
    now = now.add(const Duration(days: 8));
    await store.cleanupExpired();

    final lease = await playback.acquire(track);
    addTearDown(lease.release);
    final saved = await store.lookup(playback.key(track));
    expect(saved?.persistent, isNot(true));
    expect(await File(lease.path).readAsString(), 'new-256');
  });

  test('legacy Opus temporary of unknown quality is not replayed', () async {
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
    );
    final input = await File('${root.path}/opus').writeAsString('legacy-opus');
    await store.putTemporary(playback.key(track), input, extension: '.opus');
    await expectLater(
      playback.acquire(track),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(await playback.promote(track), isFalse);
    expect(
      await File(
        (await store.lookup(playback.key(track)))!.path,
      ).readAsString(),
      'legacy-opus',
    );
  });

  test(
    'legacy M4A is not replayed or promoted without download evidence',
    () async {
      final original = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      );
      final input = await File(
        '${root.path}/legacy-m4a',
      ).writeAsString('legacy-128');
      await store.putTemporary(original.key(track), input, extension: '.m4a');
      final restarted = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        clock: () => now,
      );
      await restarted.initialize();
      final offline = CatalogPlayback(
        storage: restarted,
        savedLookup: (_) async => false,
      );
      await expectLater(
        offline.acquire(track),
        throwsA(isA<CatalogPlaybackException>()),
      );
      offline.playbackBitrateKbps = 256;
      await expectLater(
        offline.acquire(track),
        throwsA(isA<CatalogPlaybackException>()),
      );
      expect(await offline.promote(track), isFalse);
      expect((await restarted.lookup(offline.key(track)))?.persistent, isFalse);
      now = now.add(const Duration(days: 8));
      await restarted.cleanupExpired();
      final saved = await restarted.lookup(offline.key(track));
      expect(saved, isNull);
    },
  );

  test('saving leaves the active variant and older legacy temporary intact', () async {
    final playback =
        CatalogPlayback(storage: store, savedLookup: (_) async => false)
          ..playbackBitrateKbps = 256
          ..resolveDownloadService = (_, _) async => 'test-provider';
    final legacy = await File('${root.path}/legacy').writeAsString('old-128');
    final current = await File(
      '${root.path}/current',
    ).writeAsString('current-256');
    await store.putTemporary(playback.key(track), legacy, extension: '.m4a');
    await store.putTemporary(
      variant(playback, 256),
      current,
      extension: '.m4a',
      qualityMetadata: {'provider': 'test-provider'},
    );
    final lease = await playback.acquire(track);
    playback.selectLease(track, lease);
    expect(await playback.promote(track), isFalse);
    final saved = await store.lookup(playback.key(track));
    expect(await File(saved!.path).readAsString(), 'old-128');
    expect(await File(lease.path).readAsString(), 'current-256');
    await lease.release();
  });

  test(
    'cleanup protects the active variant and older saved temporary',
    () async {
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => true,
      )..playbackBitrateKbps = 256;
      final legacy = await File(
        '${root.path}/clean-legacy',
      ).writeAsString('old-128');
      final current = await File(
        '${root.path}/clean-current',
      ).writeAsString('current-256');
      await store.putTemporary(playback.key(track), legacy, extension: '.m4a');
      await store.putTemporary(
        variant(playback, 256),
        current,
        extension: '.m4a',
        qualityMetadata: {'provider': 'test-provider'},
      );
      final lease = (await store.acquire(variant(playback, 256)))!;
      playback.selectLease(track, lease);
      SharedPreferences.setMockInitialValues({
        'saved_library_tracks_v1': jsonEncode([track.toJson()]),
      });
      await playback.clearTemporary();
      expect(
        await File(
          (await store.lookup(playback.key(track)))!.path,
        ).readAsString(),
        'old-128',
      );
      expect(await File(lease.path).readAsString(), 'current-256');
      await lease.release();
    },
  );

  test(
    'restart preserves most recently played variant without promotion',
    () async {
      final playback =
          CatalogPlayback(storage: store, savedLookup: (_) async => false)
            ..playbackBitrateKbps = 256
            ..resolveDownloadService = (_, _) async => 'test-provider';
      final legacy = await File(
        '${root.path}/legacy2',
      ).writeAsString('old-128');
      final current = await File(
        '${root.path}/current2',
      ).writeAsString('current-256');
      await store.putTemporary(playback.key(track), legacy, extension: '.m4a');
      now = now.add(const Duration(seconds: 1));
      await store.putTemporary(
        variant(playback, 256),
        current,
        extension: '.m4a',
        qualityMetadata: {'provider': 'test-provider'},
      );
      final lease = await playback.acquire(track);
      playback.selectLease(track, lease);
      now = now.add(const Duration(seconds: 1));
      await store.recordPlayback(lease.id);
      await lease.release();
      final restarted = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        clock: () => now,
      );
      await restarted.initialize();
      final offline = CatalogPlayback(
        storage: restarted,
        savedLookup: (_) async => false,
      );
      expect(await offline.promote(track), isFalse);
      expect(
        await File(
          (await restarted.lookup(lease.id))!.path,
        ).readAsString(),
        'current-256',
      );
    },
  );

  test(
    'cancelling a saved pending consumer does not cancel saved preparation',
    () async {
      var saved = false;
      final started = Completer<void>();
      final finish = Completer<void>();
      var transfers = 0;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => saved,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            transfers++;
            if (transfers > 1) throw StateError('offline');
            started.complete();
            await finish.future;
            return File('${dir.path}/input').writeAsString('saved');
          },
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final acquisition = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await started.future;
      saved = true;
      expect(playback.pendingSavedPromotion(track), isNull);
      await playback.cancel(track);
      expect(
        await acquisition.timeout(const Duration(seconds: 2)),
        isA<CatalogPlaybackException>(),
      );
      expect(finish.isCompleted, isFalse);
      final reacquired = playback.acquire(track);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(transfers, 1);
      finish.complete();
      final newLease = await reacquired.timeout(const Duration(seconds: 5));
      expect(await File(newLease.path).readAsString(), 'saved');
      await newLease.release();
      expect((await store.lookup(playback.key(track)))?.persistent, isNot(true));
    },
  );

  test(
    'saved permanent copy does not protect redundant expired variants',
    () async {
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => true,
      );
      final input = await File('${root.path}/input').writeAsString('audio');
      final id = variant(playback, 128);
      final temporary = await store.putTemporary(id, input, extension: '.m4a');
      await store.promoteVariant(playback.key(track), id);
      SharedPreferences.setMockInitialValues({
        'saved_library_tracks_v1': jsonEncode([track.toJson()]),
      });
      now = now.add(const Duration(days: 8));
      expect(await playback.cleanupExpired(), 1);
      expect(await File(temporary.path).exists(), isFalse);
      final saved = await store.lookup(playback.key(track));
      expect(saved?.persistent, isTrue);
      expect(await File(saved!.path).readAsString(), 'audio');
    },
  );

  test('new save does not reattach a cancelled old preparation', () async {
    var saved = false;
    var cancelLookup = false;
    final decision = Completer<bool>();
    final oldStarted = Completer<void>();
    final oldFinish = Completer<void>();
    final newStarted = Completer<void>();
    var transfers = 0;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) {
        if (cancelLookup) {
          cancelLookup = false;
          return decision.future;
        }
        return Future.value(saved);
      },
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) async {
          final number = ++transfers;
          if (number == 1) {
            oldStarted.complete();
            await oldFinish.future;
          } else {
            newStarted.complete();
          }
          return File(
            '${dir.path}/input',
          ).writeAsString(number == 1 ? 'old' : 'new');
        },
        cancelDownload: (_) async {
            if (!oldFinish.isCompleted) oldFinish.complete();
          },
        codec: (_) async => 'aac', container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    );
    final first = playback
        .acquire(track)
        .then<Object>((v) => v, onError: (Object e) => e);
    await oldStarted.future;
    cancelLookup = true;
    final cancellation = playback.cancel(track);
    expect(
      await first.timeout(const Duration(seconds: 2)),
      isA<CatalogPlaybackException>(),
    );
    saved = true;
    final second = playback.acquire(track);
    decision.complete(false);
    await cancellation;
    await newStarted.future.timeout(const Duration(seconds: 5));
    final lease = await second.timeout(const Duration(seconds: 5));
    expect(await File(lease.path).readAsString(), 'new');
    if (!oldFinish.isCompleted) oldFinish.complete();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(
      await File(lease.path).readAsString(),
      'new',
    );
    await lease.release();
  });

  test(
    'second cancellation invalidates previously retained preparation',
    () async {
      var saved = false;
      var transfers = 0;
      final firstStarted = Completer<void>();
      final finishOld = Completer<void>();
      final secondStarted = Completer<void>();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => saved,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            final n = ++transfers;
            if (n == 1) {
              firstStarted.complete();
              await finishOld.future;
            } else {
              secondStarted.complete();
            }
            return File(
              '${dir.path}/source',
            ).writeAsString(n == 1 ? 'old' : 'new');
          },
          cancelDownload: (_) async {
            if (!finishOld.isCompleted) finishOld.complete();
          },
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final first = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await firstStarted.future;
      saved = true;
      await playback.cancel(track);
      expect(
        await first.timeout(const Duration(seconds: 2)),
        isA<CatalogPlaybackException>(),
      );
      final again = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(transfers, 1);
      saved = false;
      await playback.cancel(track);
      expect(
        await again.timeout(const Duration(seconds: 2)),
        isA<CatalogPlaybackException>(),
      );
      saved = true;
      final finalAcquisition = playback.acquire(track);
      await secondStarted.future.timeout(const Duration(seconds: 5));
      final lease = await finalAcquisition.timeout(const Duration(seconds: 5));
      expect(await File(lease.path).readAsString(), 'new');
      if (!finishOld.isCompleted) finishOld.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await File(lease.path).readAsString(),
        'new',
      );
      await lease.release();
    },
  );
  test(
    'store rejects permanent publication when save is withdrawn during copy',
    () async {
      var saved = true;
      var copies = 0;
      final copyStarted = Completer<void>();
      final resumeCopy = Completer<void>();
      final guardedStore = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        copyFile: (source, destination) async {
          copies++;
          if (copies == 2) {
            copyStarted.complete();
            await resumeCopy.future;
          }
          return File(
            destination,
          ).writeAsBytes(await source.readAsBytes(), flush: true);
        },
      );
      await guardedStore.initialize();
      final input = await File('${root.path}/source').writeAsString('candidate');
      await guardedStore.putTemporary('variant', input, extension: '.m4a');
      final acquired = guardedStore.promoteVariant('saved', 'variant', canPublish: () async => saved);
      await copyStarted.future.timeout(const Duration(seconds: 5));
      saved = false;
      resumeCopy.complete();
      expect(await acquired.timeout(const Duration(seconds: 2)), isNull);
      expect(await guardedStore.lookup('saved'), isNull);
      final temp = await guardedStore.lookup('variant');
      expect(await File(temp!.path).readAsString(), 'candidate');
    },
  );
  test(
    'store rejects publication when save is withdrawn during manifest write',
    () async {
      var saved = true;
      var writes = 0;
      final manifestStarted = Completer<void>();
      final resumeManifest = Completer<void>();
      final guardedStore = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        writeManifest: (file, content) async {
          writes++;
          await file.writeAsString(content, flush: true);
          if (writes == 2) {
            manifestStarted.complete();
            await resumeManifest.future;
          }
        },
      );
      await guardedStore.initialize();
      final input = await File('${root.path}/source').writeAsString('candidate');
      await guardedStore.putTemporary('variant', input, extension: '.m4a');
      final acquired = guardedStore.promoteVariant('saved', 'variant', canPublish: () async => saved);
      await manifestStarted.future.timeout(const Duration(seconds: 5));
      saved = false;
      resumeManifest.complete();
      expect(await acquired.timeout(const Duration(seconds: 2)), isNull);
      expect(await guardedStore.lookup('saved'), isNull);
      expect(
        await File(
          (await guardedStore.lookup('variant'))!.path,
        ).readAsString(),
        'candidate',
      );
    },
  );
  test(
    'cancelling retained preparation twice without reattachment invalidates it',
    () async {
      var saved = false;
      var transfers = 0;
      final firstStarted = Completer<void>();
      final finishOld = Completer<void>();
      final secondStarted = Completer<void>();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => saved,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            final n = ++transfers;
            if (n == 1) {
              firstStarted.complete();
              await finishOld.future;
            } else {
              secondStarted.complete();
            }
            return File(
              '${dir.path}/source',
            ).writeAsString(n == 1 ? 'old' : 'new');
          },
          cancelDownload: (_) async {
            if (!finishOld.isCompleted) finishOld.complete();
          },
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final first = playback
          .acquire(track)
          .then<Object>((v) => v, onError: (Object e) => e);
      await firstStarted.future;
      saved = true;
      await playback.cancel(track);
      expect(
        await first.timeout(const Duration(seconds: 2)),
        isA<CatalogPlaybackException>(),
      );
      saved = false;
      await playback.cancel(track);
      saved = true;
      final next = playback.acquire(track);
      await secondStarted.future.timeout(const Duration(seconds: 5));
      final lease = await next.timeout(const Duration(seconds: 5));
      expect(await File(lease.path).readAsString(), 'new');
      if (!finishOld.isCompleted) finishOld.complete();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        await File(lease.path).readAsString(),
        'new',
      );
      await lease.release();
    },
  );
}
