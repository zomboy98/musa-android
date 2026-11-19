import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/app_state_database.dart';

import 'support/fixed_settings.dart';
import 'support/virtual_time.dart';

const _earlyTrack = Track(
  id: 'example:early',
  name: 'Immediate addition',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

class _HistoryFixture extends DownloadHistoryNotifier {
  DownloadHistoryItem? item;
  DownloadHistoryItem? alternate;
  DownloadHistoryItem? older;
  bool fail = false;
  Completer<void>? lookupStarted;
  Completer<void>? lookupRelease;

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<List<DownloadHistoryItem>> findTrackCandidatesAsync(
    HistoryLookupRequest request,
  ) async {
    if (fail) throw StateError('history unavailable');
    lookupStarted?.complete();
    if (lookupRelease != null) await lookupRelease!.future;
    return [?item, ?alternate, ?older];
  }
}

class _DecisionQueue extends DownloadQueueNotifier {
  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) => 'enqueued';
}

class _LocalFixture extends LocalLibraryNotifier {
  LocalLibraryItem? item;
  Completer<void>? lookupStarted;
  Completer<void>? lookupRelease;
  @override
  LocalLibraryState build() => LocalLibraryState();
  @override
  Future<LocalLibraryItem?> getByIsrcAsync(String isrc) async => item;
  @override
  Future<LocalLibraryItem?> findByTrackAndArtistAsync(
    String name,
    String artist,
  ) async {
    lookupStarted?.complete();
    if (lookupRelease != null) await lookupRelease!.future;
    return item;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The waits run on virtual time, including the 350 ms persistence debounce
  // they must outlast.
  test(
    'startup restores, merges and retries only complete owned snapshots',
    () => VirtualTime().run(() async {
      SharedPreferences.setMockInitialValues({
        'app_state_migrated_queue_to_sqlite_v1': true,
        'download_queue_user_paused_v1': true,
      });
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactorySqflitePlugin;
      addTearDown(() => databaseFactory = previousFactory);
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const sqlite = MethodChannel('com.tekartik.sqflite');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        paths,
        (_) async => '/fixture/documents',
      );
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      final items = List.generate(
        128,
        (index) => DownloadItem(
          id: 'queue-$index',
          track: Track(
            id: 'example:$index',
            source: 'example',
            name: 'Song $index',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 180,
          ),
          // Avoid extension/native download work; the persisted queue is paused.
          service: '',
          createdAt: DateTime.utc(2026).add(Duration(seconds: index)),
        ),
      );
      final rows = <String, Map<String, Object?>>{
        for (final item in items)
          item.id: {
            'id': item.id,
            'item_json': encodeDownloadQueueItemForPersistence(item),
            'status': 'queued',
            'created_at': item.createdAt.toIso8601String(),
            'updated_at': item.createdAt.toIso8601String(),
          },
      };
      var started = Completer<void>();
      var release = Completer<void>();
      var queueReads = 0;
      var deletes = 0;
      var writes = 0;
      var failRead = false;
      messenger.setMockMethodCallHandler(sqlite, (call) async {
        if (call.method == 'openDatabase') return {'id': 1};
        final arguments = call.arguments as Map? ?? {};
        final sql = arguments['sql'] as String? ?? '';
        if (call.method == 'query') {
          if (sql.toLowerCase().contains('pragma user_version')) {
            return {
              'columns': ['user_version'],
              'rows': [
                [4],
              ],
            };
          }
          if (!sql.contains('download_queue_items')) {
            return {'columns': <String>[], 'rows': <List<Object?>>[]};
          }
          queueReads++;
          final snapshot = rows.values.toList();
          started.complete();
          await release.future;
          if (failRead) {
            throw PlatformException(code: 'sqlite_error', message: 'Try again');
          }
          const columns = [
            'id',
            'item_json',
            'status',
            'created_at',
            'updated_at',
          ];
          return {
            'columns': columns,
            'rows': [
              for (final row in snapshot)
                [for (final column in columns) row[column]],
            ],
          };
        }
        if (call.method == 'batch') {
          for (final raw in arguments['operations'] as List) {
            final operation = raw as Map;
            final statement = operation['sql'] as String;
            final values = operation['arguments'] as List;
            if (statement.startsWith('DELETE FROM download_queue_items')) {
              rows.remove(values.first as String);
              deletes++;
            } else if (statement.startsWith('INSERT')) {
              const columns = [
                'id',
                'item_json',
                'status',
                'created_at',
                'updated_at',
              ];
              rows[values.first as String] = {
                for (var i = 0; i < columns.length; i++) columns[i]: values[i],
              };
              writes++;
            } else {
              fail('Unexpected queue mutation: $statement');
            }
          }
          return null;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
      ProviderContainer scope({
        _HistoryFixture? history,
        bool realQueue = false,
        _LocalFixture? local,
      }) => ProviderContainer(
        overrides: [
          if (history != null)
            downloadHistoryProvider.overrideWith(() => history),
          if (local != null) localLibraryProvider.overrideWith(() => local),
          if (history != null && !realQueue)
            downloadQueueProvider.overrideWith(_DecisionQueue.new),
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                downloadDirectory: '/fixture/output',
                localLibraryEnabled: local != null,
              ),
            ),
          ),
        ],
      );

      final container = scope();
      final queue = container.read(downloadQueueProvider.notifier);
      await started.future;
      expect(container.read(downloadQueueProvider).items, isEmpty);
      var flushed = false;
      final background = queue.flushQueuePersistence().then(
        (_) => flushed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(flushed, false);
      expect([writes, deletes], [0, 0]);
      release.complete();
      await background;
      expect(
        container.read(downloadQueueProvider).items.map((item) => item.id),
        items.map((item) => item.id),
      );
      expect(rows.keys, items.map((item) => item.id));
      expect(
        [writes, deletes],
        [0, 0],
        reason:
            'restored canonical rows must survive the first background flush',
      );
      expect(queueReads, 1);
      container.dispose();

      // Disposal completes the restore gate but must not access provider state
      // or persist an empty snapshot after ownership has ended.
      started = Completer();
      release = Completer();
      final disposed = scope();
      final disposedQueue = disposed.read(downloadQueueProvider.notifier);
      await started.future;
      final pending = disposedQueue.flushQueuePersistence();
      disposed.dispose();
      await pending;
      expect(rows.keys, items.map((item) => item.id));
      expect([writes, deletes], [0, 0]);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));

      // All public add paths publish immediately, but neither processing nor
      // the 350 ms debounce may act on this incomplete startup snapshot.
      started = Completer();
      release = Completer();
      final additions = scope();
      final additionsQueue = additions.read(downloadQueueProvider.notifier);
      await started.future;
      final singleId = additionsQueue.addToQueue(
        items.first.track.copyWith(source: ''),
        '',
        qualityOverride: 'lossless',
      );
      additionsQueue.addMultipleToQueue(
        [items.first.track.copyWith(source: ''), _earlyTrack],
        '',
        qualityOverride: 'high',
        playlistName: 'Immediate playlist',
        playlistPositions: [7, 9],
      );
      additionsQueue.addIndividualTracksToQueue([_earlyTrack, _earlyTrack], '');
      final earlyItems = additions.read(downloadQueueProvider).items.toList();
      expect(earlyItems.length, 5);
      expect(earlyItems.map((item) => item.id).toSet(), hasLength(5));
      expect(earlyItems.first.id, singleId);
      expect(earlyItems.map((item) => item.qualityOverride), [
        'lossless',
        'high',
        'high',
        null,
        null,
      ]);
      final additionsFlush = additionsQueue.flushQueuePersistence();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(additions.read(downloadQueueProvider).isProcessing, false);
      expect(
        additions.read(downloadQueueProvider).items.map((item) => item.status),
        everyElement(DownloadStatus.queued),
      );
      expect([writes, deletes], [0, 0]);
      release.complete();
      await additionsFlush;
      final merged = additions.read(downloadQueueProvider);
      expect(merged.items.map((item) => item.id), [
        ...items.map((item) => item.id),
        ...earlyItems.map((item) => item.id),
      ]);
      for (var index = 0; index < earlyItems.length; index++) {
        expect(merged.items[items.length + index], same(earlyItems[index]));
      }
      expect(merged.items[items.length + 2].playlistPosition, 9);
      expect(merged.items[items.length + 2].fromBatch, true);
      expect(merged.items.last.playlistPosition, isNull);
      expect(merged.items.last.fromBatch, false);
      expect(merged.isPaused, true);
      expect(rows.keys, merged.items.map((item) => item.id));
      expect([writes, deletes], [5, 0]);
      additions.dispose();

      // Even disposal cannot flush an early add over the restored disk rows.
      final savedIds = rows.keys.toList();
      started = Completer();
      release = Completer();
      final earlyDisposed = scope();
      final earlyDisposedQueue = earlyDisposed.read(
        downloadQueueProvider.notifier,
      );
      await started.future;
      earlyDisposedQueue.addIndividualTracksToQueue([_earlyTrack], '');
      final disposeFlush = earlyDisposedQueue.flushQueuePersistence();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      earlyDisposed.dispose();
      await disposeFlush;
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(rows.keys, savedIds);
      expect([writes, deletes], [5, 0]);

      // A failed restore retains the new UI item and existing disk contents.
      // A subsequent add starts one fresh attempt shared by concurrent flushes.
      started = Completer();
      release = Completer();
      failRead = true;
      final recovery = scope();
      final recoveryQueue = recovery.read(downloadQueueProvider.notifier);
      await started.future;
      final firstRecoveryId = recoveryQueue.addToQueue(_earlyTrack, '');
      recoveryQueue.pauseQueue();
      final failedFlush = expectLater(
        recoveryQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      release.complete();
      await failedFlush;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(rows.keys, savedIds);
      expect([writes, deletes], [5, 0]);
      expect(
        recovery.read(downloadQueueProvider).items.single.id,
        firstRecoveryId,
      );
      expect(recovery.read(downloadQueueProvider).isProcessing, false);

      started = Completer();
      release = Completer();
      failRead = false;
      final readsBeforeRetry = queueReads;
      recoveryQueue.addIndividualTracksToQueue([_earlyTrack], '');
      final secondRecoveryId = recovery
          .read(downloadQueueProvider)
          .items
          .last
          .id;
      await started.future;
      recoveryQueue.resumeQueue();
      expect(recovery.read(downloadQueueProvider).isPaused, false);
      final selectionRetry = recoveryQueue.retrySelectionPersistence();
      bool? resumedPublication;
      final subscription = recovery.listen(downloadQueueProvider, (_, next) {
        if (resumedPublication == null &&
            next.items.length == savedIds.length + 2) {
          resumedPublication = next.isPaused;
          // Pause immediately after observing the merged publication so the
          // fixture never starts extension/download work after gate release.
          recoveryQueue.pauseQueue();
        }
      });
      release.complete();
      await selectionRetry;
      final retryFlushes = Future.wait([
        recoveryQueue.flushQueuePersistence(),
        recoveryQueue.flushQueuePersistence(),
      ]);
      await retryFlushes;
      subscription.close();
      expect(
        resumedPublication,
        false,
        reason: 'newer resume overrides the persisted paused preference',
      );
      final recovered = recovery.read(downloadQueueProvider);
      expect(recovered.items.map((item) => item.id), [
        ...savedIds,
        firstRecoveryId,
        secondRecoveryId,
      ]);
      expect(
        recovered.isPaused,
        true,
        reason: 'the latest pause while publishing also wins',
      );
      expect(rows.keys, recovered.items.map((item) => item.id));
      expect(queueReads, readsBeforeRetry + 1);
      expect([writes, deletes], [7, 0]);
      recovery.dispose();

      // Explicit flush and resume also retry a failed startup without needing
      // another addition. Failed attempts may not touch the saved queue.
      final recoveredIds = rows.keys.toList();
      started = Completer();
      release = Completer();
      failRead = true;
      final explicitRetry = scope();
      final explicitQueue = explicitRetry.read(downloadQueueProvider.notifier);
      await started.future;
      explicitQueue.pauseQueue();
      final firstFailure = expectLater(
        explicitQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      release.complete();
      await firstFailure;
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);

      started = Completer();
      release = Completer();
      final flushRetryReads = queueReads;
      final secondFailure = expectLater(
        explicitQueue.flushQueuePersistence(),
        throwsA(isA<StateError>()),
      );
      await started.future;
      release.complete();
      await secondFailure;
      expect(queueReads, flushRetryReads + 1);
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);

      started = Completer();
      release = Completer();
      failRead = false;
      final resumeRetryReads = queueReads;
      explicitQueue.resumeQueue();
      await started.future;
      final resumedFlush = explicitQueue.flushQueuePersistence();
      bool? explicitResumePublication;
      final resumedSubscription = explicitRetry.listen(downloadQueueProvider, (
        _,
        next,
      ) {
        if (explicitResumePublication == null &&
            next.items.length == recoveredIds.length) {
          explicitResumePublication = next.isPaused;
          explicitQueue.pauseQueue();
        }
      });
      release.complete();
      await resumedFlush;
      resumedSubscription.close();
      expect(explicitResumePublication, false);
      expect(queueReads, resumeRetryReads + 1);
      expect(rows.keys, recoveredIds);
      expect([writes, deletes], [7, 0]);
      explicitRetry.dispose();

      // Verify the notifier's actual decision against a readable history file,
      // a deleted file and an unavailable history provider.
      started = Completer();
      release = Completer();
      final directory = await Directory.systemTemp.createTemp('saved-queue-');
      final file = File('${directory.path}/track.flac');
      await file.writeAsBytes([1, 2, 3]);
      final fixture = _HistoryFixture()
        ..item = DownloadHistoryItem(
          id: 'history',
          spotifyId: 'saved-history',
          trackName: 'History song',
          artistName: 'Artist',
          albumName: 'Album',
          filePath: file.path,
          service: 'provider',
          downloadedAt: DateTime(2026),
        );
      const historyTrack = Track(
        id: 'saved-history',
        name: 'History song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      );
      final withHistory = scope(history: fixture);
      final historyQueue = withHistory.read(downloadQueueProvider.notifier);
      await started.future;
      historyQueue.pauseQueue();
      release.complete();
      expect(await historyQueue.addSavedTrackToQueue(historyTrack, ''), isNull);
      await file.delete();
      final alternateFile = File('${directory.path}/alternate.flac');
      await alternateFile.writeAsBytes([4]);
      fixture.alternate = DownloadHistoryItem(
        id: 'alternate',
        spotifyId: 'saved-history',
        trackName: 'History song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: alternateFile.path,
        service: 'provider',
        downloadedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      expect(await historyQueue.addSavedTrackToQueue(historyTrack, ''), isNull);
      expect(
        await historyQueue.addSavedTrackToQueue(
          historyTrack.copyWith(isrc: 'USABC1234568'),
          '',
        ),
        isNotNull,
      );
      fixture.older = fixture.alternate;
      fixture.alternate = null;
      expect(await historyQueue.addSavedTrackToQueue(historyTrack, ''), isNull);
      expect(
        await historyQueue.addSavedTrackToQueue(
          historyTrack.copyWith(name: 'Different recording'),
          '',
        ),
        isNotNull,
      );
      await alternateFile.delete();
      expect(
        await historyQueue.addSavedTrackToQueue(historyTrack, ''),
        isNotNull,
      );
      historyQueue.pauseQueue();
      fixture.fail = true;
      const errorTrack = Track(
        id: 'history-error',
        name: 'Other song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      );
      expect(
        await historyQueue.addSavedTrackToQueue(errorTrack, ''),
        isNotNull,
      );
      withHistory.dispose();

      // A scanned file with no download-history entry also suppresses an
      // automatic download, but a deleted file or conflicting ISRC does not.
      started = Completer();
      release = Completer();
      await file.writeAsBytes([1]);
      final local = _LocalFixture()
        ..item = LocalLibraryItem(
          id: 'scan',
          trackName: historyTrack.name,
          artistName: historyTrack.artistName,
          albumName: '',
          filePath: file.path,
          scannedAt: DateTime(2026),
          isrc: 'USABC1234567',
        );
      final localScope = scope(history: _HistoryFixture(), local: local);
      final localQueue = localScope.read(downloadQueueProvider.notifier);
      await started.future;
      localQueue.pauseQueue();
      release.complete();
      expect(await localQueue.addSavedTrackToQueue(historyTrack, ''), isNull);
      expect(
        await localQueue.addSavedTrackToQueue(
          historyTrack.copyWith(isrc: 'USXYZ7654321'),
          '',
        ),
        isNotNull,
      );
      await file.delete();
      expect(
        await localQueue.addSavedTrackToQueue(historyTrack, ''),
        isNotNull,
      );
      localScope.dispose();
      await directory.delete(recursive: true);

      // Automatic additions must check the restored snapshot, not the initial
      // empty UI state. Simultaneous callers also share one atomic insertion.
      started = Completer();
      release = Completer();
      final automatic = scope();
      final automaticQueue = automatic.read(downloadQueueProvider.notifier);
      await started.future;
      automaticQueue.pauseQueue();
      var automaticFinished = false;
      final duplicate = automaticQueue
          .addSavedTrackToQueue(items.first.track, '')
          .then((id) {
            automaticFinished = true;
            return id;
          });
      const newSaved = Track(
        id: 'example:auto',
        source: 'example',
        name: 'Saved song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      );
      final concurrentFirst = automaticQueue.addSavedTrackToQueue(newSaved, '');
      final concurrentSecond = automaticQueue.addSavedTrackToQueue(
        newSaved,
        '',
      );
      await Future<void>.delayed(Duration.zero);
      expect(automaticFinished, isFalse);
      expect(automatic.read(downloadQueueProvider).items, isEmpty);
      release.complete();
      expect(await duplicate, isNull);
      expect(await concurrentFirst, isNotNull);
      expect(await concurrentSecond, isNull);
      expect(
        automatic
            .read(downloadQueueProvider)
            .items
            .where((item) => item.track.id == newSaved.id),
        hasLength(1),
      );
      automaticQueue.addToQueue(newSaved, '', qualityOverride: 'high');
      expect(
        automatic
            .read(downloadQueueProvider)
            .items
            .where((item) => item.track.id == newSaved.id),
        hasLength(1),
        reason: 'quality variants are disabled in these settings',
      );
      await automaticQueue.flushQueuePersistence();
      automatic.dispose();

      // A manual download can finish and be dismissed while history is slow.
      // The pending automatic decision must still see its actual output.
      started = Completer();
      release = Completer();
      final raceHistory = _HistoryFixture()
        ..lookupStarted = Completer<void>()
        ..lookupRelease = Completer<void>();
      final race = scope(history: raceHistory, realQueue: true);
      final raceQueue = race.read(downloadQueueProvider.notifier);
      await started.future;
      raceQueue.pauseQueue();
      release.complete();
      final raceFile = File('${directory.path}-race.flac');
      await raceFile.writeAsBytes([1]);
      final raceTrack = newSaved.copyWith(id: 'race-unique');
      final pendingSave = raceQueue.addSavedTrackToQueue(raceTrack, '');
      await raceHistory.lookupStarted!.future;
      final raceId = raceQueue.addToQueue(raceTrack, '');
      raceQueue.updateItemStatus(
        raceId,
        DownloadStatus.completed,
        filePath: raceFile.path,
      );
      raceQueue.dismissItem(raceId);
      raceHistory.lookupRelease!.complete();
      expect(await pendingSave, isNull);
      await raceFile.delete();
      race.dispose();

      started = Completer();
      release = Completer();
      final guardedHistory = _HistoryFixture()
        ..lookupStarted = Completer<void>()
        ..lookupRelease = Completer<void>();
      final guarded = scope(history: guardedHistory, realQueue: true);
      final guardedQueue = guarded.read(downloadQueueProvider.notifier);
      await started.future;
      guardedQueue.pauseQueue();
      release.complete();
      var current = true;
      final guardedTrack = newSaved.copyWith(id: 'guarded-race');
      final pendingGuarded = guardedQueue.addCurrentSavedTrackToQueue(
        guardedTrack,
        '',
        () => current,
      );
      await guardedHistory.lookupStarted!.future;
      current = false;
      guardedHistory.lookupRelease!.complete();
      expect(await pendingGuarded, isNull);
      expect(
        guarded
            .read(downloadQueueProvider)
            .items
            .where((item) => item.track.id == guardedTrack.id),
        isEmpty,
      );
      guardedQueue.addToQueue(guardedTrack, '');
      expect(
        guarded
            .read(downloadQueueProvider)
            .items
            .where((item) => item.track.id == guardedTrack.id),
        hasLength(1),
      );
      guarded.dispose();

      // The completion race must also remain closed while the added local
      // library lookup is pending, including after the manual item is hidden.
      started = Completer();
      release = Completer();
      final slowLocal = _LocalFixture()
        ..lookupStarted = Completer<void>()
        ..lookupRelease = Completer<void>();
      final localRace = scope(
        history: _HistoryFixture(),
        local: slowLocal,
        realQueue: true,
      );
      final localRaceQueue = localRace.read(downloadQueueProvider.notifier);
      await started.future;
      localRaceQueue.pauseQueue();
      release.complete();
      await raceFile.writeAsBytes([1]);
      final localRaceTrack = newSaved.copyWith(id: 'local-race-unique');
      final localPendingSave = localRaceQueue.addSavedTrackToQueue(
        localRaceTrack,
        '',
      );
      await slowLocal.lookupStarted!.future;
      final localRaceId = localRaceQueue.addToQueue(localRaceTrack, '');
      localRaceQueue.updateItemStatus(
        localRaceId,
        DownloadStatus.completed,
        filePath: raceFile.path,
      );
      localRaceQueue.dismissItem(localRaceId);
      slowLocal.lookupRelease!.complete();
      expect(await localPendingSave, isNull);
      await raceFile.delete();
      localRace.dispose();

      started = Completer();
      release = Completer();
      final identities = scope();
      final identitiesQueue = identities.read(downloadQueueProvider.notifier);
      await started.future;
      identitiesQueue.pauseQueue();
      release.complete();
      final withIsrc = newSaved.copyWith(isrc: 'USABC1234567');
      identitiesQueue.addToQueue(newSaved, '');
      expect(await identitiesQueue.addSavedTrackToQueue(withIsrc, ''), isNull);
      final differentVersion = newSaved.copyWith(
        id: 'version',
        isrc: 'USABC1234567',
      );
      identitiesQueue.addToQueue(differentVersion, '');
      expect(
        await identitiesQueue.addSavedTrackToQueue(
          differentVersion.copyWith(isrc: 'USXYZ7654321'),
          '',
        ),
        isNotNull,
      );
      identities.dispose();

      // Failed restoration cannot safely deduplicate or start an automatic
      // download. Disposal releases waiters without accessing dead state.
      started = Completer();
      release = Completer();
      failRead = true;
      final failedAutomatic = scope();
      final failedAutomaticQueue = failedAutomatic.read(
        downloadQueueProvider.notifier,
      );
      await started.future;
      final failedAddition = expectLater(
        failedAutomaticQueue.addSavedTrackToQueue(newSaved, ''),
        throwsA(isA<StateError>()),
      );
      release.complete();
      await failedAddition;
      failedAutomatic.dispose();

      started = Completer();
      release = Completer();
      failRead = false;
      final disposedAutomatic = scope();
      final disposedAutomaticQueue = disposedAutomatic.read(
        downloadQueueProvider.notifier,
      );
      await started.future;
      final disposedAddition = disposedAutomaticQueue.addSavedTrackToQueue(
        newSaved,
        '',
      );
      disposedAutomatic.dispose();
      expect(await disposedAddition, isNull);
      release.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await (await AppStateDatabase.instance.database).close();
    }),
  );
}
