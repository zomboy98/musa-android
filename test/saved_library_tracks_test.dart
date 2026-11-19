import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: '1',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 120,
    source: 'catalog',
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer containerForTest({bool noRetry = false}) =>
      ProviderContainer(
        retry: noRetry ? (count, error) => null : null,
        overrides: [
          promoteSavedCatalogAudioProvider.overrideWithValue(
            (_) async => false,
          ),
        ],
      );

  test(
    'remove and re-add during copy invalidates the original save intention',
    () async {
      final root = await Directory.systemTemp.createTemp('notifier-retention-');
      addTearDown(() => root.delete(recursive: true));
      final firstCopy = Completer<void>(), firstFinish = Completer<void>();
      final secondCopy = Completer<void>(), secondFinish = Completer<void>();
      var copies = 0;
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
        copyFile: (file, destination) async {
          if (destination.contains(
            '${Platform.pathSeparator}library${Platform.pathSeparator}',
          )) {
            if (++copies == 1) {
              firstCopy.complete();
              await firstFinish.future;
            } else {
              secondCopy.complete();
              await secondFinish.future;
            }
          }
          final output = File(destination).openWrite();
          await output.addStream(file.openRead());
          await output.close();
          return File(destination);
        },
      );
      await store.initialize();
      final playback = CatalogPlayback(storage: store);
      final source = await File('${root.path}/source').writeAsString('audio');
      await store.putTemporary(
        jsonEncode([
          'catalog-aac-v4',
          playback.key(track),
          128,
          'LOSSLESS',
          'A',
          true,
        ]),
        source,
        extension: '.m4a',
        qualityMetadata: {'provider': 'A'},
      );
      final container = ProviderContainer(
        overrides: [
          promoteSavedCatalogAudioProvider.overrideWith(
            (ref) =>
                (item) async {
                  final intention = ref.read(savedLibraryTracksProvider.notifier).currentSaveIntention(item);
                  final variant = jsonEncode(['catalog-aac-v4', playback.key(item), 128, 'LOSSLESS', 'A', true]);
                  return await store.promoteVariant(playback.key(item), variant, canPublish: () async => intention()) != null;
                },
          ),
          savedCatalogRetentionLockProvider.overrideWithValue(
            playback.withRetentionLock,
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(savedLibraryTracksProvider.future);
      final notifier = container.read(savedLibraryTracksProvider.notifier);
      final oldSave = notifier.add(track);
      await firstCopy.future.timeout(const Duration(seconds: 5));
      expect(await notifier.remove(track), isTrue);
      final newSave = notifier.add(track);
      firstFinish.complete();
      expect(await oldSave, isFalse);
      await secondCopy.future.timeout(const Duration(seconds: 5));
      final manifests = await store.libraryDirectory
          .list()
          .where((entry) => entry is File && entry.path.endsWith('.json'))
          .cast<File>()
          .toList();
      for (final manifest in manifests) {
        expect(
          (jsonDecode(await manifest.readAsString()) as Map)['persistent'],
          isNot(true),
        );
      }
      secondFinish.complete();
      expect(await newSave, isTrue);
      expect((await store.lookup(playback.key(track)))?.persistent, isTrue);
    },
  );

  test('corrupt references stop both manual and expiry cleanup', () async {
    SharedPreferences.setMockInitialValues({
      SavedLibraryTracksNotifier.storageKey: 'invalid',
    });
    await expectLater(catalogPlayback.clearTemporary(), throwsFormatException);
    await expectLater(catalogPlayback.cleanupExpired(), throwsFormatException);
  });

  test('direct save and restore wait for retention cleanup', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final cleanup = catalogPlayback.withRetentionLock(() async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    final container = containerForTest();
    addTearDown(container.dispose);
    await container.read(savedLibraryTracksProvider.future);
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    final save = notifier.add(track);
    final restore = notifier.restoreFromBackup([track]);
    await Future<void>.delayed(Duration.zero);
    expect(await container.read(savedLibraryTracksProvider.future), isEmpty);
    release.complete();
    await cleanup;
    expect(await save, isTrue);
    await restore;
    expect(
      (await container.read(savedLibraryTracksProvider.future)).single,
      track,
    );
  });

  test('adds once and survives a new provider container', () async {
    final first = containerForTest();
    expect(await first.read(savedLibraryTracksProvider.future), isEmpty);
    final notifier = first.read(savedLibraryTracksProvider.notifier);
    expect(await notifier.add(track), isTrue);
    expect(await notifier.add(track), isFalse);
    first.dispose();

    final second = containerForTest();
    addTearDown(second.dispose);
    expect(
      (await second.read(savedLibraryTracksProvider.future)).single.name,
      'Song',
    );
    expect(
      await second.read(savedLibraryTracksProvider.notifier).remove(track),
      isTrue,
    );
    expect(await second.read(savedLibraryTracksProvider.future), isEmpty);
  });

  test('invalid stored data is not replaced on a failed add', () async {
    SharedPreferences.setMockInitialValues({
      SavedLibraryTracksNotifier.storageKey: 'invalid',
    });
    final container = containerForTest(noRetry: true);
    addTearDown(container.dispose);
    await expectLater(
      container.read(savedLibraryTracksProvider.future),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      container.read(savedLibraryTracksProvider.notifier).add(track),
      throwsA(isA<FormatException>()),
    );
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(SavedLibraryTracksNotifier.storageKey), 'invalid');
  });

  test('restore replaces references, including with an empty list', () async {
    final container = containerForTest();
    addTearDown(container.dispose);
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    await notifier.add(track);
    await notifier.restoreFromBackup([]);
    expect(await container.read(savedLibraryTracksProvider.future), isEmpty);
    await notifier.restoreFromBackup([track]);
    expect(
      (await container.read(savedLibraryTracksProvider.future)).single.id,
      '1',
    );
  });

  test('restore recovers corrupt storage after a failed mutation', () async {
    SharedPreferences.setMockInitialValues({
      SavedLibraryTracksNotifier.storageKey: 'invalid',
    });
    final container = containerForTest(noRetry: true);
    addTearDown(container.dispose);
    await expectLater(
      container.read(savedLibraryTracksProvider.future),
      throwsA(isA<FormatException>()),
    );
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    await expectLater(notifier.add(track), throwsA(isA<FormatException>()));

    await notifier.restoreFromBackup([track]);
    expect(
      (await container.read(savedLibraryTracksProvider.future)).single.id,
      '1',
    );
    final reopened = containerForTest();
    addTearDown(reopened.dispose);
    expect(
      (await reopened.read(savedLibraryTracksProvider.future)).single.id,
      '1',
    );
    expect(await notifier.remove(track), isTrue);
  });

  test(
    'restore during initial load can replace corrupt storage with empty data',
    () async {
      SharedPreferences.setMockInitialValues({
        SavedLibraryTracksNotifier.storageKey: 'invalid',
      });
      final container = containerForTest();
      addTearDown(container.dispose);
      final notifier = container.read(savedLibraryTracksProvider.notifier);
      await notifier.restoreFromBackup([]);
      expect(await container.read(savedLibraryTracksProvider.future), isEmpty);
      final reopened = containerForTest();
      addTearDown(reopened.dispose);
      expect(await reopened.read(savedLibraryTracksProvider.future), isEmpty);
      expect(await notifier.add(track), isTrue);
    },
  );
}
