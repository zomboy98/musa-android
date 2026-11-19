import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

const _settings = AppSettings(
  downloadDirectory: '/fixture/output',
  filenameFormat: '{track} - {title}',
  singleFilenameFormat: '{title}',
  audioQuality: 'HIGH',
  autoFallback: false,
  allowQualityVariants: true,
  networkDownloadFolder: 'smb://example.test/music',
);
const _tracks = [
  Track(
    id: 'example:one',
    name: 'First — 音楽',
    artistName: 'Artist & Guest',
    albumArtist: 'Artist & Guest',
    albumName: 'Album',
    duration: 180,
    isrc: 'XX0000000001',
    genre: 'Rock',
  ),
  Track(
    id: 'example:two',
    name: 'Second',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 200,
    trackNumber: 2,
  ),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => _settings;
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'broken',
        name: 'broken',
        displayName: 'Broken',
        version: '1',
        description: '',
        enabled: true,
        status: 'error',
        hasDownloadProvider: true,
        capabilities: {
          'replacesBuiltInProviders': ['example', 'broken-only'],
        },
      ),
      Extension(
        id: 'replacement',
        name: 'replacement',
        displayName: 'Replacement',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        capabilities: {
          'replacesBuiltInProviders': ['example', 'exact'],
        },
      ),
      Extension(
        id: 'exact',
        name: 'exact',
        displayName: 'Exact',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  _Queue(this._initial)
    : super(
        queuePersistenceForTesting: (items, error) => DownloadQueuePersistence(
          currentItems: items,
          onError: error,
          loadRows: () async => [],
          loadSelectionEvents: () async => [],
          applyChanges: ({required upserts, required deletedIds}) async {},
          applySelectionChanges:
              ({
                required upserts,
                required deletedIds,
                required selectionEvents,
              }) async {},
        ),
      );
  final DownloadQueueState _initial;

  @override
  DownloadQueueState build() {
    // Keep the real restore/dispose gate. Tests dispose synchronously before
    // its startup microtask, so no storage or network is used here.
    super.build();
    return _initial;
  }
}

Map<String, dynamic> _stableItem(DownloadItem item) =>
    (jsonDecode(jsonEncode(item.toJson())) as Map<String, dynamic>)
      ..remove('id')
      ..remove('createdAt');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/backend'),
          (call) async => null,
        );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/backend'),
          null,
        ),
  );

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 100));

  ProviderContainer scope(DownloadQueueState initial) => ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(_Settings.new),
      extensionProvider.overrideWith(_Extensions.new),
      downloadQueueProvider.overrideWith(() => _Queue(initial)),
    ],
  );

  test('latest chosen variant wins regardless of completion order', () async {
    final container = scope(
      const DownloadQueueState().copyWith(isPaused: true),
    );
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue();
      await queue.flushQueuePersistence();
      final a = queue.addToQueue(
        _tracks.first,
        'example',
        qualityOverride: 'HIGH',
      );
      final b = queue.addToQueue(
        _tracks.first,
        'example',
        qualityOverride: 'LOSSLESS',
      );
      await settle();
      final items = container.read(downloadQueueProvider).items;
      final first = items.firstWhere((item) => item.id == a);
      final second = items.firstWhere((item) => item.id == b);
      expect(queue.isSelectedPermanentDownloadForTesting(second), isTrue);
      expect(queue.isSelectedPermanentDownloadForTesting(first), isFalse);
      queue.updateItemStatus(b, DownloadStatus.completed, filePath: '/b.flac');
      expect(queue.isSelectedPermanentDownloadForTesting(first), isFalse);
    } finally {
      container.dispose();
    }
  });

  for (final batch in [false, true]) {
    for (final entry in {
      ' ExAcT ': 'exact',
      'example': 'replacement',
      'broken-only': 'broken-only',
      'unavailable': 'unavailable',
    }.entries) {
      test('queue resolves ${entry.key} with fallback off (batch: $batch)', () {
        final container = scope(
          const DownloadQueueState().copyWith(isPaused: true),
        );
        try {
          final queue = container.read(downloadQueueProvider.notifier);
          if (batch) {
            queue.addMultipleToQueue(_tracks, entry.key);
          } else {
            queue.addToQueue(_tracks.first, entry.key);
          }
          final state = container.read(downloadQueueProvider);
          expect(state.items, hasLength(batch ? _tracks.length : 1));
          expect(
            state.items.map((item) => item.service),
            everyElement(entry.value),
          );
          expect(state.autoFallback, isFalse);
        } finally {
          container.dispose();
        }
      });
    }
  }

  test('restored ambiguous variants do not infer a choice', () {
    final items = [
      for (final id in ['a', 'b'])
        DownloadItem(
          id: id,
          track: _tracks.first,
          service: 'example',
          createdAt: DateTime.utc(2026),
        ),
    ];
    final container = scope(
      const DownloadQueueState().copyWith(items: items, isPaused: true),
    );
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      expect(queue.isSelectedPermanentDownloadForTesting(items.first), isFalse);
      expect(queue.isSelectedPermanentDownloadForTesting(items.last), isFalse);
    } finally {
      container.dispose();
    }
  });

  test('manual retry chooses its variant; internal retry does not', () async {
    final items = [
      for (final id in ['a', 'b'])
        DownloadItem(
          id: id,
          track: _tracks.first,
          service: 'example',
          status: DownloadStatus.failed,
          createdAt: DateTime.utc(2026),
        ),
    ];
    final container = scope(
      const DownloadQueueState().copyWith(items: items, isPaused: true),
    );
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue();
      await queue.flushQueuePersistence();
      await queue.retryItem('b');
      await settle();
      expect(queue.isSelectedPermanentDownloadForTesting(items.last), isTrue);
      await queue.retryItem('a', selectForPlayback: false);
      await settle();
      expect(queue.isSelectedPermanentDownloadForTesting(items.last), isTrue);
      queue.updateItemStatus('a', DownloadStatus.failed);
      await queue.retryItem('a');
      await settle();
      expect(queue.isSelectedPermanentDownloadForTesting(items.first), isTrue);
      expect(queue.isSelectedPermanentDownloadForTesting(items.last), isFalse);
    } finally {
      container.dispose();
    }
  });

  test(
    'removing or cancelling the selected variant does not revive an older one',
    () async {
      for (final remove in [false, true]) {
        final container = scope(
          const DownloadQueueState().copyWith(isPaused: true),
        );
        try {
          final queue = container.read(downloadQueueProvider.notifier);
          queue.pauseQueue();
          await queue.flushQueuePersistence();
          final a = queue.addToQueue(
            _tracks.first,
            'example',
            qualityOverride: 'HIGH',
          );
          final b = queue.addToQueue(
            _tracks.first,
            'example',
            qualityOverride: 'LOSSLESS',
          );
          await settle();
          final first = container
              .read(downloadQueueProvider)
              .items
              .firstWhere((item) => item.id == a);
          if (remove) {
            queue.removeItem(b);
          } else {
            queue.cancelItem(b);
          }
          await settle();
          expect(queue.isSelectedPermanentDownloadForTesting(first), isFalse);
        } finally {
          container.dispose();
        }
      }
    },
  );

  for (final processing in [false, true]) {
    test('selection matches individual requests (processing: $processing)', () {
      final existing = DownloadItem(
        id: 'existing',
        track: _tracks.first,
        service: 'example',
        createdAt: DateTime.utc(2026),
        qualityOverride: 'LOSSLESS',
        fromBatch: true,
      );
      final initial = const DownloadQueueState().copyWith(
        items: [existing],
        isPaused: true,
        isProcessing: processing,
        currentDownload: processing ? existing : null,
      );
      final baseline = scope(initial);
      final selection = scope(initial);
      try {
        final tracks = [..._tracks, _tracks.first];
        final singles = baseline.read(downloadQueueProvider.notifier);
        for (final track in tracks) {
          singles.addToQueue(track, ' example ');
        }
        final queue = selection.read(downloadQueueProvider.notifier);
        var publications = 0;
        selection.listen(downloadQueueProvider, (_, _) => publications++);
        final before = DateTime.now();
        queue.addIndividualTracksToQueue(tracks, ' example ');
        final after = DateTime.now();
        final state = selection.read(downloadQueueProvider);
        final expected = baseline.read(downloadQueueProvider);
        expect(state.items.map(_stableItem), expected.items.map(_stableItem));
        expect(publications, 1);
        expect(state.items.first, same(existing));
        expect(state.items.map((item) => item.id).toSet(), hasLength(3));
        expect(state.isPaused, true);
        expect(state.isProcessing, processing);
        expect(state.currentDownload, same(initial.currentDownload));
        expect(state.outputDir, expected.outputDir);
        expect(state.filenameFormat, expected.filenameFormat);
        expect(state.singleFilenameFormat, expected.singleFilenameFormat);
        expect(state.audioQuality, expected.audioQuality);
        expect(state.autoFallback, expected.autoFallback);
        for (var i = 0; i < 2; i++) {
          final item = state.items[i + 1];
          expect(item.track, same(tracks[i]));
          expect(item.service, 'replacement');
          expect(item.fromBatch, false);
          expect(item.qualityOverride, isNull);
          expect(item.playlistName, isNull);
          expect(item.playlistPosition, isNull);
          expect(item.createdAt.isBefore(before), false);
          expect(item.createdAt.isAfter(after), false);
        }
        tracks.clear();
        expect(state.items, hasLength(3));
        queue.addIndividualTracksToQueue([_tracks.first], 'example');
        expect(selection.read(downloadQueueProvider).items, hasLength(3));
        expect(
          selection
              .read(downloadQueueProvider)
              .items
              .map((item) => item.id)
              .toSet(),
          hasLength(3),
        );
      } finally {
        selection.dispose();
        baseline.dispose();
      }
    });
  }

  test('empty selection does not publish or change settings', () {
    const initial = DownloadQueueState(outputDir: '/old');
    final container = scope(initial);
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      var publications = 0;
      container.listen(downloadQueueProvider, (_, _) => publications++);
      queue.addIndividualTracksToQueue([], 'example');
      expect(container.read(downloadQueueProvider), same(initial));
      expect(publications, 0);
    } finally {
      container.dispose();
    }
  });

  test(
    'album batches still normalize credits and retain playlist positions',
    () {
      final container = scope(const DownloadQueueState(isPaused: true));
      try {
        container
            .read(downloadQueueProvider.notifier)
            .addMultipleToQueue(
              _tracks,
              ' example ',
              qualityOverride: 'LOSSLESS',
              playlistName: 'Playlist',
              playlistPositions: [7, null],
            );
        final items = container.read(downloadQueueProvider).items;
        expect(items.map((item) => item.track.albumArtist), [
          'Artist',
          'Artist',
        ]);
        expect(items.map((item) => item.fromBatch), everyElement(true));
        expect(
          items.map((item) => item.qualityOverride),
          everyElement('LOSSLESS'),
        );
        expect(items.map((item) => item.playlistPosition), [7, 2]);
      } finally {
        container.dispose();
      }
    },
  );

  for (final processing in [false, true]) {
    test(
      'multiple batches keep independent metadata (processing: $processing)',
      () {
        final existing = DownloadItem(
          id: 'existing',
          track: _tracks.first,
          service: 'example',
          createdAt: DateTime.utc(2026),
        );
        final initial = const DownloadQueueState(outputDir: '/old').copyWith(
          items: [existing],
          isPaused: true,
          isProcessing: processing,
          currentDownload: processing ? existing : null,
        );
        final baseline = scope(initial);
        final bulk = scope(initial);
        final mutable = _tracks.toList();
        final batches = [
          DownloadQueueBatch(
            tracks: mutable,
            playlistName: ' One ',
            playlistPositions: [7, null],
          ),
          DownloadQueueBatch(
            tracks: [_tracks.first],
            playlistName: 'Second',
            playlistPositions: [0],
          ),
          DownloadQueueBatch(
            tracks: [_tracks.first, _tracks.first],
            playlistName: ' ',
            playlistPositions: [-1, 9, 99],
          ),
          const DownloadQueueBatch(tracks: [], playlistName: 'Empty'),
          DownloadQueueBatch(tracks: [_tracks.last], playlistPositions: [4]),
        ];
        try {
          final loop = baseline.read(downloadQueueProvider.notifier);
          for (final batch in batches) {
            loop.addMultipleToQueue(
              batch.tracks,
              ' example ',
              qualityOverride: 'HIGH',
              playlistName: batch.playlistName,
              playlistPositions: batch.playlistPositions,
            );
          }
          final queue = bulk.read(downloadQueueProvider.notifier);
          var publications = 0;
          bulk.listen(downloadQueueProvider, (_, _) => publications++);
          queue.addBatchesToQueue(
            batches,
            ' example ',
            qualityOverride: 'HIGH',
          );
          final state = bulk.read(downloadQueueProvider);
          final expected = baseline.read(downloadQueueProvider);
          expect(state.items.map(_stableItem), expected.items.map(_stableItem));
          expect(publications, 1);
          expect(state.items.first, same(existing));
          expect(state.items.map((item) => item.id).toSet(), hasLength(4));
          expect(state.isPaused, true);
          expect(state.isProcessing, processing);
          expect(state.currentDownload, same(initial.currentDownload));
          expect(state.outputDir, _settings.downloadDirectory);
          expect(state.filenameFormat, _settings.filenameFormat);
          expect(state.audioQuality, _settings.audioQuality);
          expect(state.autoFallback, _settings.autoFallback);
          final added = state.items.skip(1).toList();
          expect(added.map((item) => item.track.albumArtist), [
            'Artist',
            'Artist',
            _tracks.last.albumArtist,
          ]);
          expect(added.map((item) => item.fromBatch), [true, true, false]);
          expect(added.map((item) => item.playlistPosition), [7, 2, 4]);
          expect(added.map((item) => item.playlistName), [
            ' One ',
            ' One ',
            null,
          ]);
          expect(
            added.map((item) => item.service),
            everyElement('replacement'),
          );
          expect(
            added.map((item) => item.qualityOverride),
            everyElement('HIGH'),
          );
          expect(
            added.map((item) => item.preserveQualityVariant),
            everyElement(true),
          );
          expect(
            added.map((item) => item.networkDownloadFolder),
            everyElement(_settings.networkDownloadFolder),
          );
          mutable.clear();
          batches.clear();
          expect(state.items, hasLength(4));
          queue.addBatchesToQueue([
            DownloadQueueBatch(tracks: [_tracks.first]),
          ], 'example');
          expect(
            bulk
                .read(downloadQueueProvider)
                .items
                .map((item) => item.id)
                .toSet(),
            hasLength(4),
          );
        } finally {
          bulk.dispose();
          baseline.dispose();
        }
      },
    );
  }

  test(
    'no batches is a no-op, an explicit empty batch still applies settings',
    () {
      const initial = DownloadQueueState(outputDir: '/old', isPaused: true);
      final container = scope(initial);
      try {
        final queue = container.read(downloadQueueProvider.notifier);
        var publications = 0;
        container.listen(downloadQueueProvider, (_, _) => publications++);
        queue.addBatchesToQueue([], 'example');
        expect(container.read(downloadQueueProvider), same(initial));
        expect(publications, 0);
        queue.addBatchesToQueue([
          const DownloadQueueBatch(tracks: []),
        ], 'example');
        expect(publications, 1);
        expect(container.read(downloadQueueProvider).items, isEmpty);
        expect(container.exists(extensionProvider), false);
        expect(
          container.read(downloadQueueProvider).outputDir,
          _settings.downloadDirectory,
        );
      } finally {
        container.dispose();
      }
    },
  );

  test('queued tracks leave a network cover behind', () {
    // A Loved entry of a network song, and a catalog track.
    const network = Track(
      id: 'network://nas/Album/song.flac',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      coverUrl: 'network://nas/Album/cover.jpg',
      duration: 180,
      source: 'local',
      availability: ServiceAvailability(tidal: true, tidalUrl: 'https://t'),
    );
    const web = Track(
      id: 'example:web',
      name: 'Web',
      artistName: 'Other',
      albumName: 'Other album',
      coverUrl: 'https://example.com/cover.jpg',
      duration: 200,
    );
    final container = scope(const DownloadQueueState(isPaused: true));
    try {
      final queue = container.read(downloadQueueProvider.notifier);
      queue.addToQueue(network, 'example');
      queue.addIndividualTracksToQueue([network, web], 'example');
      queue.addMultipleToQueue([network, web], 'example');
      final items = container.read(downloadQueueProvider).items;
      expect(items, hasLength(3));
      Map<String, dynamic> json(Track track) =>
          jsonDecode(jsonEncode(track.toJson())) as Map<String, dynamic>;
      for (final item in items) {
        if (item.track.id == web.id) {
          expect(item.track.coverUrl, web.coverUrl);
        } else {
          expect(json(item.track), {...json(network), 'coverUrl': null});
        }
      }
      expect(items[2].track, same(web));
    } finally {
      container.dispose();
    }
  });
}
