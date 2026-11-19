import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final saved in [false, true]) {
    test(
      'staging disposal failure releases publication guard: saved=$saved',
      () async {
        final root = await Directory.systemTemp.createTemp('dispose-guard-');
        addTearDown(() => root.delete(recursive: true));
        const track = Track(
          id: 'dispose',
          source: 'spotify',
          name: 'Dispose',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        );
        final store = CatalogAudioStore(
          cacheDirectory: Directory(p.join(root.path, 'cache')),
          libraryDirectory: Directory(p.join(root.path, 'library')),
        );
        await store.initialize();
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => saved,
          disposePrepared: (prepared) async {
            await prepared.dispose();
            throw FileSystemException('staging cleanup failed');
          },
          preparerFactory: (_) => TemporaryTrackPreparer(
            stagingRoot: Directory(p.join(root.path, 'staging')),
            download: (directory, _) async {
              final input = File(p.join(directory.path, 'input'));
              await input.writeAsBytes([1]);
              return input;
            },
            cancelDownload: (_) async {},
            codec: (_) async => 'aac',
            container: (_) async => 'mp4',
            validate: (_) async => true,
          ),
        );
        await expectLater(
          playback.acquire(track),
          throwsA(isA<CatalogPlaybackException>()),
        );
        final variantId = jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          128,
          'LOSSLESS',
          '',
          true,
        ]);
        final temporary = await store.lookup(variantId);
        final published = temporary;
        expect(published, isNotNull);
        expect(temporary, isNotNull);
        expect(await File(published!.path).exists(), isTrue);
        expect(await store.clearTemporary(), 1);
        expect(await File(temporary!.path).exists(), isFalse);
        expect(await File(published.path).exists(), isFalse);
      },
    );
  }
  for (final scenario in ['success', 'cancel', 'failure']) {
    test('saving does not wait for preparation: $scenario', () async {
      final cancel = scenario == 'cancel';
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('save-pending-');
      addTearDown(() => root.delete(recursive: true));
      const track = Track(
        id: 'save',
        source: 'spotify',
        name: 'Save',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      final started = Completer<void>();
      final resume = Completer<void>();
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory(p.join(root.path, 'staging')),
          download: (directory, _) async {
            started.complete();
            await resume.future;
            if (scenario == 'failure') throw StateError('download failed');
            final input = File(p.join(directory.path, 'input'));
            await input.writeAsBytes([1]);
            return input;
          },
          cancelDownload: (_) async {},
          codec: (_) async => 'aac',
          container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      );
      final container = ProviderContainer(
        overrides: [
          savedCatalogRetentionLockProvider.overrideWithValue(
            playback.withRetentionLock,
          ),
          promoteSavedCatalogAudioProvider.overrideWithValue(playback.promote),
          pendingSavedCatalogPromotionProvider.overrideWithValue(
            playback.pendingSavedPromotion,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(savedLibraryTracksProvider.future);
      final acquired = playback
          .acquire(track)
          .then<Object>((value) => value, onError: (Object error) => error);
      await started.future;
      final saved = container
          .read(savedLibraryTracksProvider.notifier)
          .addWithRetention(track);
      // Reaching this lock means the reference was persisted and its lock released.
      await playback.withRetentionLock(() async {});
      if (cancel) await playback.cancel(track);
      resume.complete();
      final result = await saved;
      final value = await acquired;
      expect(result.added, isTrue);
      expect(result.promoted, isFalse);
      expect(result.retentionError, isNull);
      if (cancel) expect(value, isA<CatalogPlaybackException>());
      expect(container.read(savedLibraryTracksProvider).value, contains(track));
      if (value is CatalogAudioLease) await value.release();
      if (cancel) {
        final staging = Directory(p.join(root.path, 'staging'));
        for (var i = 0; i < 100 && await staging.exists() && !(await staging.list().where((entry) => entry is Directory).isEmpty); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(await staging.exists() && !(await staging.list().where((entry) => entry is Directory).isEmpty), isFalse);
      }
    });
  }
  for (final cancel in [false, true]) {
    test(
      'queued cleanup and cancellation during publication: $cancel',
      () async {
        SharedPreferences.setMockInitialValues({});
        final root = await Directory.systemTemp.createTemp('publication-race-');
        addTearDown(() => root.delete(recursive: true));
        const track = Track(
          id: 'race',
          source: 'spotify',
          name: 'Race',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        );
        final copying = Completer<void>();
        final resume = Completer<void>();
        final store = CatalogAudioStore(
          cacheDirectory: Directory(p.join(root.path, 'cache')),
          libraryDirectory: Directory(p.join(root.path, 'library')),
          copyFile: (file, destination) async {
            copying.complete();
            await resume.future;
            return File(
              destination,
            ).writeAsBytes(await file.readAsBytes(), flush: true);
          },
        );
        await store.initialize();
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => false,
          preparerFactory: (_) => TemporaryTrackPreparer(
            stagingRoot: Directory(p.join(root.path, 'staging')),
            download: (directory, _) async {
              final input = File(p.join(directory.path, 'input'));
              await input.writeAsBytes([1, 2, 3]);
              return input;
            },
            cancelDownload: (_) async {},
            codec: (_) async => 'aac',
            container: (_) async => 'mp4',
            validate: (_) async => true,
          ),
        );
        final result = playback
            .acquire(track)
            .then<Object>((lease) => lease, onError: (Object error) => error);
        await copying.future;
        final cleanup = playback.clearTemporary();
        if (cancel) await playback.cancel(track);
        resume.complete();
        final value = await result;
        await cleanup;
        if (cancel) {
          expect(value, isA<CatalogPlaybackException>());
        } else {
          expect(value, isA<CatalogAudioLease>());
          final lease = value as CatalogAudioLease;
          expect(await File(lease.path).exists(), isTrue);
          await lease.release();
        }
      },
    );
  }
}
