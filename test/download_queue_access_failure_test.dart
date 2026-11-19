import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial)
    : super(
        queuePersistenceForTesting: (items, error) => DownloadQueuePersistence(
          currentItems: items,
          onError: error,
          loadRows: () async => [],
          loadSelectionEvents: () async => [],
          applyChanges: ({required upserts, required deletedIds}) async {},
        ),
      );
  final DownloadQueueState _initial;
  @override
  DownloadQueueState build() {
    // Preserve production restore and disposal with in-memory queue storage.
    super.build();
    return _initial;
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(downloadDirectory: '/selected');
}

DownloadItem _item(int index, DownloadStatus status) => DownloadItem(
  id: 'item-$index',
  track: Track(
    id: 'track-${index ~/ 2}',
    name: 'Track $index — 音楽',
    artistName: 'Artist & Guest',
    albumName: 'Album',
    albumArtist: 'Artist',
    duration: 180,
    coverUrl: 'https://example.test/cover.jpg',
    isrc: 'XX0000000001',
  ),
  service: 'example',
  createdAt: DateTime.utc(2026),
  status: status,
  progress: 0.25,
  speedMBps: 1.5,
  bytesReceived: 4,
  bytesTotal: 16,
  filePath: '/old/$index',
  error: 'old error',
  errorType: DownloadErrorType.network,
  preparationStage: 'old stage',
  playlistName: 'Playlist',
  playlistPosition: index + 1,
  qualityOverride: 'HIGH',
  fromBatch: true,
  preserveQualityVariant: true,
  networkDownloadFolder: index.isEven ? 'smb://example.test/music' : '',
);

void _expectConsistentLookup(DownloadQueueState state) {
  final rebuilt = DownloadQueueLookup.fromItems(state.items);
  expect(state.lookup.byItemId, rebuilt.byItemId);
  expect(state.lookup.byTrackId, rebuilt.byTrackId);
  expect(state.lookup.indexByItemId, rebuilt.indexByItemId);
  expect(state.lookup.itemIds, rebuilt.itemIds);
  expect(state.lookup.notCompletedItemIds, rebuilt.notCompletedItemIds);
  expect(state.lookup.queuedCount, rebuilt.queuedCount);
  expect(state.lookup.failedCount, rebuilt.failedCount);
  expect(state.lookup.completedCount, rebuilt.completedCount);
  expect(state.lookup.activeDownloadsCount, rebuilt.activeDownloadsCount);
  expect(state.lookup.finalizingCount, rebuilt.finalizingCount);
  expect(state.lookup.firstDownloading, same(rebuilt.firstDownloading));
  expect(state.lookup.firstFinalizing, same(rebuilt.firstFinalizing));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer scope(DownloadQueueState state) => ProviderContainer(
    overrides: [
      downloadQueueProvider.overrideWith(() => _Queue(state)),
      settingsProvider.overrideWith(_Settings.new),
    ],
  );

  test('folder failures log once per newly failed item', () async {
    SharedPreferences.setMockInitialValues({});
    await BugLog.instance.clear();
    final initial = const DownloadQueueState().copyWith(
      items: [
        _item(0, DownloadStatus.queued),
        _item(1, DownloadStatus.queued),
        _item(2, DownloadStatus.downloading),
        _item(3, DownloadStatus.failed),
      ],
    );
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      queue.failQueuedDownloads(
        error: 'Cannot open content://private/tree/secret',
        errorType: DownloadErrorType.permission,
      );
      queue.failQueuedDownloads(error: 'Repeated validation');
    } finally {
      container.dispose();
    }

    await BugLog.instance.entries();
    await (await SharedPreferences.getInstance()).reload();
    final entries = await BugLog().entries();
    expect(entries, hasLength(2));
    for (final entry in entries) {
      expect(entry['category'], 'download');
      expect(entry['type'], 'TerminalDownloadFailure');
      expect(
        entry['frames'],
        'stage_preparing_output, error_type_permission, cause_unknown',
      );
    }
    expect(jsonEncode(entries), isNot(contains('secret')));
    expect(jsonEncode(entries), isNot(contains('example.test')));
  });

  test(
    'a second untyped folder failure after retry logs a new entry',
    () async {
      SharedPreferences.setMockInitialValues({});
      await BugLog.instance.clear();
      const backend = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'resetDownloadCancel');
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(backend, null));

      final container = scope(
        const DownloadQueueState(
          isProcessing: true,
        ).copyWith(items: [_item(0, DownloadStatus.queued)]),
      );
      try {
        final queue = container.read(downloadQueueProvider.notifier);
        queue.failQueuedDownloads(error: 'First bookmark access failure');
        expect(
          container.read(downloadQueueProvider).items.single.errorType,
          null,
        );
        expect(await BugLog.instance.entries(), hasLength(1));

        await queue.retryItem('item-0', selectForPlayback: false);
        expect(
          container.read(downloadQueueProvider).items.single.status,
          DownloadStatus.queued,
        );

        queue.failQueuedDownloads(error: 'Second bookmark access failure');
        expect(
          container.read(downloadQueueProvider).items.single.status,
          DownloadStatus.failed,
        );
        expect(
          (await BugLog.instance.entries()).map((entry) => entry['frames']),
          [
            'stage_preparing_output, error_type_unknown, cause_unknown',
            'stage_preparing_output, error_type_unknown, cause_unknown',
          ],
        );
      } finally {
        container.dispose();
      }
    },
  );

  for (final type in [DownloadErrorType.permission, null]) {
    test('bulk failure matches per-item updates (type: $type)', () {
      final items = List.generate(
        140,
        (i) =>
            _item(i, DownloadStatus.values[i % DownloadStatus.values.length]),
      );
      final initial = const DownloadQueueState(
        isProcessing: true,
        isPaused: true,
        outputDir: '/selected',
        audioQuality: 'HIGH',
        autoFallback: false,
      ).copyWith(items: items, currentDownload: items[1]);
      final loop = scope(initial);
      final bulk = scope(initial);
      try {
        final baseline = loop.read(downloadQueueProvider.notifier);
        for (final item in initial.items) {
          if (item.status == DownloadStatus.queued) {
            baseline.updateItemStatus(
              item.id,
              DownloadStatus.failed,
              error: 'Folder inaccessible',
              errorType: type,
            );
          }
        }
        final queue = bulk.read(downloadQueueProvider.notifier);
        var publications = 0;
        bulk.listen(downloadQueueProvider, (_, next) {
          publications++;
          expect(
            next.items.any((item) => item.status == DownloadStatus.queued),
            false,
          );
          _expectConsistentLookup(next);
        });
        queue.failQueuedDownloads(
          error: 'Folder inaccessible',
          errorType: type,
        );
        final after = bulk.read(downloadQueueProvider);
        final expected = loop.read(downloadQueueProvider);
        expect(publications, 1);
        expect(
          jsonEncode(after.items.map((item) => item.toJson()).toList()),
          jsonEncode(expected.items.map((item) => item.toJson()).toList()),
        );
        for (var i = 0; i < items.length; i++) {
          if (items[i].status != DownloadStatus.queued) {
            expect(after.items[i], same(items[i]));
          }
          expect(after.items[i].track, same(items[i].track));
        }
        expect(after.currentDownload, same(initial.currentDownload));
        expect(after.isProcessing, initial.isProcessing);
        expect(after.isPaused, initial.isPaused);
        expect(after.outputDir, initial.outputDir);
        expect(after.audioQuality, initial.audioQuality);
        expect(after.autoFallback, initial.autoFallback);
        for (final (actualIndex, expectedIndex) in [
          (after.lookup.byItemId, expected.lookup.byItemId),
          (after.lookup.byTrackId, expected.lookup.byTrackId),
        ]) {
          expect(
            actualIndex.map(
              (id, item) => MapEntry(id, jsonEncode(item.toJson())),
            ),
            expectedIndex.map(
              (id, item) => MapEntry(id, jsonEncode(item.toJson())),
            ),
          );
        }
        expect(after.lookup.queuedCount, expected.lookup.queuedCount);
        expect(after.lookup.failedCount, expected.lookup.failedCount);
        expect(after.lookup.completedCount, expected.lookup.completedCount);
        expect(
          after.lookup.activeDownloadsCount,
          expected.lookup.activeDownloadsCount,
        );
        expect(after.lookup.finalizingCount, expected.lookup.finalizingCount);
        expect(after.lookup.itemIds, same(initial.lookup.itemIds));
        expect(
          after.lookup.notCompletedItemIds,
          same(initial.lookup.notCompletedItemIds),
        );
        expect(initial.items, items);
        queue.failQueuedDownloads(error: 'Different error');
        expect(bulk.read(downloadQueueProvider), same(after));
        expect(publications, 1);
      } finally {
        bulk.dispose();
        loop.dispose();
      }
    });
  }

  test('status updates publish matching indexes once and preserve no-ops', () {
    final items = List.generate(
      130,
      (i) => _item(i, DownloadStatus.downloading),
    );
    final initial = const DownloadQueueState().copyWith(items: items);
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      var publications = 0;
      container.listen(downloadQueueProvider, (_, next) {
        publications++;
        _expectConsistentLookup(next);
      });
      queue.updateItemStatus('missing', DownloadStatus.failed);
      expect(container.read(downloadQueueProvider), same(initial));
      expect(publications, 0);

      queue.updateItemStatus(
        'item-64',
        DownloadStatus.completed,
        progress: 1,
        filePath: '/selected/64',
      );
      final after = container.read(downloadQueueProvider);
      expect(publications, 1);
      expect(after.items[64].status, DownloadStatus.completed);
      expect(after.items[64].progress, 1);
      expect(after.items[64].filePath, '/selected/64');
      for (var i = 0; i < items.length; i++) {
        if (i != 64) expect(after.items[i], same(items[i]));
      }
      expect(initial.items, items);
      _expectConsistentLookup(initial);

      queue.updateItemStatus(
        'item-64',
        DownloadStatus.completed,
        progress: 1,
        filePath: '/selected/64',
      );
      expect(container.read(downloadQueueProvider), same(after));
      expect(publications, 1);
    } finally {
      container.dispose();
    }
  });

  test('empty queue failure is a no-op', () {
    const initial = DownloadQueueState();
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      var publications = 0;
      container.listen(downloadQueueProvider, (_, _) => publications++);
      queue.failQueuedDownloads(error: 'Folder inaccessible');
      expect(container.read(downloadQueueProvider), same(initial));
      expect(publications, 0);
    } finally {
      container.dispose();
    }
  });
}
