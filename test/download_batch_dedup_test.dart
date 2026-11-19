import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(allowQualityVariants: true);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState(isPaused: true, isProcessing: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = Track(
    id: '1',
    source: 'alpha',
    name: 'Song',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 100,
  );
  const b = Track(
    id: '1',
    source: 'beta',
    name: 'Other',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 100,
  );
  test(
    'deduplicates batches and individual requests while retaining variants and positions',
    () {
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(_Queue.new),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      queue.addToQueue(a, 'example');
      final admitted = queue.addBatchesToQueue([
        const DownloadQueueBatch(
          tracks: [a, b, b],
          playlistName: 'List',
          playlistPositions: [4, 8, 9],
        ),
      ], 'example');
      final duplicates = queue.addBatchesToQueue([
        const DownloadQueueBatch(tracks: [a, b], playlistName: 'Again'),
      ], 'example');
      queue.addIndividualTracksToQueue([a, b], 'example');
      var items = container.read(downloadQueueProvider).items;
      expect(items, hasLength(2));
      expect(admitted, [items.last.id]);
      expect(duplicates, isEmpty);
      expect(items.last.track.source, 'beta');
      expect(items.last.playlistName, 'List');
      expect(items.last.playlistPosition, 8);
      queue.addBatchesToQueue(
        [
          const DownloadQueueBatch(tracks: [a], playlistName: 'Lossless'),
        ],
        'example',
        qualityOverride: 'LOSSLESS',
      );
      items = container.read(downloadQueueProvider).items;
      expect(items, hasLength(3));
      expect(items.last.qualityOverride, 'LOSSLESS');
    },
  );

  test('legacy tracks without provider or ISRC do not match by ID alone', () {
    const legacy = Track(
      id: '42',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 100,
    );
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.addToQueue(legacy, 'example');
    queue.addToQueue(Track.fromJson(legacy.toJson()), 'example');
    expect(container.read(downloadQueueProvider).items, hasLength(2));
  });

  test('quality variants use the provider and ASCII manifest identity', () {
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    final first = queue.addToQueue(a, 'example', qualityOverride: '\u0085ÄAC ');
    expect(queue.addToQueue(a, ' EXAMPLE ', qualityOverride: 'Äac'), first);
    queue.addMultipleToQueue([a], 'example', qualityOverride: 'äAC');
    queue.addMultipleToQueue([a], 'other', qualityOverride: 'ÄAC');
    final items = container.read(downloadQueueProvider).items;
    expect(items.map((item) => (item.service, item.qualityOverride)), [
      ('example', '\u0085ÄAC '),
      ('example', 'äAC'),
      ('other', 'ÄAC'),
    ]);
  });
}
