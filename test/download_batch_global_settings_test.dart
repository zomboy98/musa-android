import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/download_provider_order.dart';

import 'support/fixed_settings.dart';

Extension _provider(String id, List<Map<String, String>> qualities) =>
    Extension.fromJson({
      'id': id,
      'name': id,
      'version': '1',
      'status': 'loaded',
      'enabled': true,
      'has_download_provider': true,
      'quality_options': qualities,
    });

final _extensions = [
  _provider('amazon', [
    {'id': 'best', 'label': 'FLAC Best Available', 'kind': 'lossless'},
    {'id': 'opus', 'label': 'Opus 320kbps', 'kind': 'lossy'},
  ]),
  _provider('deezer', [
    {'id': 'flac', 'label': 'FLAC', 'kind': 'lossless'},
    {'id': 'mp3_320', 'label': 'MP3 320 kbps', 'kind': 'lossy'},
  ]),
];

class _Settings extends FixedSettingsNotifier {
  _Settings()
    : super(
        const AppSettings(
          defaultService: 'deezer',
          allowQualityVariants: true,
          downloadQualityByProvider: {'deezer': 'mp3_320'},
        ),
      );
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: _extensions,
    providerPriority: defaultDownloadProviderOrder(_extensions),
  );
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState(isPaused: true, isProcessing: true);
  }
}

const _tracks = [
  Track(
    id: '1',
    source: 'amazon',
    name: 'One',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 200,
  ),
  Track(
    id: '2',
    source: 'amazon',
    name: 'Two',
    artistName: 'Artist',
    albumName: 'Album',
    duration: 210,
  ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer container() {
    final c = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        extensionProvider.overrideWith(_Extensions.new),
        downloadQueueProvider.overrideWith(_Queue.new),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('a batch without override keeps the global provider and quality', () {
    final c = container();
    final settings = c.read(settingsProvider);
    final service = resolveConfiguredDownloadService(
      settings.defaultService,
      c.read(extensionProvider),
    );
    c.read(downloadQueueProvider.notifier).addBatchesToQueue([
      const DownloadQueueBatch(tracks: _tracks, playlistName: 'List'),
    ], service);
    final items = c.read(downloadQueueProvider).items;
    expect(items, hasLength(2));
    for (final item in items) {
      expect(item.service, 'deezer');
      expect(item.qualityOverride, isNull);
      expect(item.fromBatch, isTrue);
    }
    expect(settings.downloadQualityByProvider['deezer'], 'mp3_320');
  });

  test('a batch with override applies it to every track', () {
    final c = container();
    c
        .read(downloadQueueProvider.notifier)
        .addBatchesToQueue(
          [const DownloadQueueBatch(tracks: _tracks, playlistName: 'List')],
          'deezer',
          qualityOverride: 'flac',
        );
    final items = c.read(downloadQueueProvider).items;
    expect(items, hasLength(2));
    for (final item in items) {
      expect(item.service, 'deezer');
      expect(item.qualityOverride, 'flac');
    }
  });

  test('without a chosen provider downloads start on Deezer, not Amazon', () {
    final c = container();
    expect(
      resolveConfiguredDownloadService('', c.read(extensionProvider)),
      'deezer',
    );
  });
}
