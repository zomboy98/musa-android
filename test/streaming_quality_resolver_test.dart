import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';

Extension provider(
  String id,
  List<(String, String)> options, {
  bool enabled = true,
  String status = 'loaded',
  bool download = true,
}) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: enabled,
  status: status,
  hasDownloadProvider: download,
  qualityOptions: [
    for (final o in options) QualityOption(id: o.$1, label: o.$1, kind: o.$2),
  ],
);

// Quality tiers declared by the bundled manifests.
final tidal = provider('tidal-web', [
  ('DOLBY_ATMOS', 'spatial'),
  ('HI_RES_LOSSLESS', 'lossless'),
  ('LOSSLESS', 'lossless'),
  ('HIGH', 'lossy'),
  ('LOW', 'lossy'),
]);
final amazon = provider('amazon', [
  ('best', 'lossless'),
  ('opus', 'lossy'),
  ('eac3', 'spatial'),
  ('ac4', 'spatial'),
]);
final qobuz = provider('qobuz-web', [
  ('HI_RES_LOSSLESS', 'lossless'),
  ('HI_RES', 'lossless'),
  ('LOSSLESS', 'lossless'),
]);
final deezer = provider('deezer', [('flac', 'lossless')]);
final jio = provider('jiosaavn', [
  ('AAC_320', 'lossy'),
  ('AAC_160', 'lossy'),
  ('AAC_96', 'lossy'),
  ('AAC_48', 'lossy'),
  ('AAC_12', 'lossy'),
]);
final soundcloud = provider('soundcloud', [('aac_160', 'lossy')]);
final beatport = provider('beatport', [
  ('LOSSLESS', 'lossless'),
  ('HIGH', 'lossy'),
]);

StreamingRequest resolve(
  String quality,
  String service,
  List<Extension> all, {
  List<String> priority = const [],
  bool fallback = true,
}) => resolveStreamingRequest(
  settingsQuality: quality,
  selectedServiceId: service,
  extensions: all,
  providerPriority: priority,
  autoFallback: fallback,
);

void main() {
  group('auto_light', () {
    test('the stable id is auto_light and the model default is Opus', () {
      expect(autoLightStreamingQuality, 'auto_light');
      expect(const AppSettings().playbackQuality, 'opus');
    });

    test('selected Tidal uses its own lossy option, never FLAC', () {
      final request = resolve('auto_light', 'tidal-web', [tidal, deezer]);
      expect(request.serviceId, 'tidal-web');
      expect(request.qualityId, 'HIGH'); // first lossy of its manifest
      expect(request.slower, isFalse);
    });

    test('lossy bitrate: lightest at or above 128 kbps, AAC before mp3', () {
      expect(
        resolve('auto_light', 'jiosaavn', [jio]).qualityId,
        'AAC_160',
      );
      final mixed = provider('mixed', [
        ('MP3_128', 'lossy'),
        ('AAC_256', 'lossy'),
        ('AAC_96', 'lossy'),
      ]);
      expect(resolve('auto_light', 'mixed', [mixed]).qualityId, 'AAC_256');
      final low = provider('low', [('AAC_96', 'lossy'), ('AAC_48', 'lossy')]);
      expect(resolve('auto_light', 'low', [low]).qualityId, 'AAC_96');
      expect(resolve('auto_light', 'amazon', [amazon]).qualityId, 'opus');
    });

    test('provider without lossy jumps to the next one by priority', () {
      final request = resolve(
        'auto_light',
        'qobuz-web',
        [qobuz, deezer, soundcloud, jio],
        priority: const ['deezer', 'jiosaavn', 'soundcloud'],
      );
      expect(request.serviceId, 'jiosaavn');
      expect(request.qualityId, 'AAC_160');
      expect(request.slower, isFalse);
    });

    test('providers outside the priority list are tried alphabetically', () {
      final request = resolve('auto_light', 'deezer', [
        deezer,
        soundcloud,
        jio,
        beatport,
      ]);
      expect(request.serviceId, 'beatport'); // alphabetical: b < j < s
      expect(request.qualityId, 'HIGH');
    });

    test('nobody has lossy: lightest option of the selected, slower', () {
      final request = resolve('auto_light', 'qobuz-web', [qobuz, deezer]);
      expect(request.serviceId, 'qobuz-web');
      expect(request.slower, isTrue);
      expect(['HI_RES_LOSSLESS', 'HI_RES', 'LOSSLESS'], contains(request.qualityId));
    });

    test('disabled, failing and download-less providers are ignored', () {
      final request = resolve(
        'auto_light',
        'deezer',
        [
          deezer,
          provider('off', [('AAC_160', 'lossy')], enabled: false),
          provider('broken', [('AAC_160', 'lossy')], status: 'error'),
          provider('metadata', [('AAC_160', 'lossy')], download: false),
          soundcloud,
        ],
      );
      expect(request.serviceId, 'soundcloud');
      expect(request.qualityId, 'aac_160');
      // A disabled selected provider behaves as missing.
      final fallback = resolve('auto_light', 'tidal-web', [
        provider('tidal-web', [('LOW', 'lossy')], enabled: false),
        jio,
      ]);
      expect(fallback.serviceId, 'jiosaavn');
    });

    test('without automatic fallback it does not jump providers', () {
      final request = resolve('auto_light', 'deezer', [
        deezer,
        jio,
      ], fallback: false);
      expect(request.serviceId, 'deezer');
      expect(request.qualityId, 'flac');
      expect(request.slower, isTrue);
    });

    test('is deterministic regardless of the extension order', () {
      final a = resolve('auto_light', 'deezer', [deezer, jio, soundcloud, beatport]);
      final b = resolve('auto_light', 'deezer', [beatport, soundcloud, jio, deezer]);
      expect(a, b);
    });

    test('no providers at all returns a heavy placeholder', () {
      final request = resolve('auto_light', 'x', const []);
      expect(request.serviceId, 'x');
      expect(request.slower, isTrue);
    });
  });

  group('explicit choice', () {
    test('lossless is respected with the selected provider and is slower', () {
      final request = resolve('LOSSLESS', 'tidal-web', [tidal, jio]);
      expect(request, const StreamingRequest('tidal-web', 'LOSSLESS', slower: true));
    });

    test('HIGH (320) is respected and slower; LOW is not slower', () {
      expect(resolve('HIGH', 'tidal-web', [tidal]).slower, isTrue);
      expect(resolve('LOW', 'tidal-web', [tidal]).slower, isFalse);
      expect(resolve('AAC_160', 'tidal-web', [tidal, jio]).slower, isFalse);
      expect(resolve('AAC_320', 'tidal-web', [tidal, jio]).slower, isTrue);
    });

    test('an id of another provider keeps the selected service (kind map)', () {
      final request = resolve('flac', 'tidal-web', [tidal, deezer]);
      expect(request.serviceId, 'tidal-web');
      expect(request.qualityId, 'flac');
      expect(request.slower, isTrue);
    });

    test('unknown legacy ids are judged by their words', () {
      expect(resolve('HI_RES', 'unknown', const []).slower, isTrue);
      expect(resolve('whatever', 'unknown', const []).slower, isFalse);
    });
  });

  group('settings migration', () {
    test('old default LOSSLESS migrates once, explicit choices survive', () {
      expect(
        AppSettings.fromJson({'playbackQuality': 'LOSSLESS'}).playbackQuality,
        'auto_light',
      );
      expect(AppSettings.fromJson(const {}).playbackQuality, 'opus');
      expect(
        AppSettings.fromJson({'playbackQuality': 'HI_RES'}).playbackQuality,
        'HI_RES',
      );
      // After migration the version is stored: a deliberate LOSSLESS stays.
      final migrated = AppSettings.fromJson({'playbackQuality': 'LOSSLESS'});
      final stored = migrated.copyWith(playbackQuality: 'LOSSLESS').toJson();
      expect(stored['playbackQualityVersion'], 2);
      expect(AppSettings.fromJson(stored).playbackQuality, 'LOSSLESS');
    });
  });
  group('provider change keeps a valid streaming choice', () {
    test('auto_light survives and nothing is ever empty', () {
      for (final target in [tidal, qobuz, deezer, jio, amazon]) {
        expect(
          reconcilePlaybackQuality('auto_light', target.qualityOptions),
          'auto_light',
        );
      }
      expect(reconcilePlaybackQuality('', tidal.qualityOptions), 'auto_light');
    });

    test('an id the new provider offers is kept', () {
      expect(
        reconcilePlaybackQuality('LOSSLESS', qobuz.qualityOptions),
        'LOSSLESS',
      );
    });

    test('explicit ids map to the equivalent of the new provider by kind', () {
      // lossless -> best lossless (manifest order) of the new provider
      expect(reconcilePlaybackQuality('flac', qobuz.qualityOptions), 'HI_RES_LOSSLESS');
      expect(reconcilePlaybackQuality('best', tidal.qualityOptions), 'HI_RES_LOSSLESS');
      // spatial -> spatial
      expect(reconcilePlaybackQuality('eac3', tidal.qualityOptions), 'DOLBY_ATMOS');
      // lossy -> closest bitrate
      expect(reconcilePlaybackQuality('AAC_320', jio.qualityOptions), 'AAC_320');
      expect(reconcilePlaybackQuality('AAC_128', jio.qualityOptions), 'AAC_160');
      expect(reconcilePlaybackQuality('opus', tidal.qualityOptions), 'HIGH');
    });

    test('without an equivalent it falls back to auto_light', () {
      expect(reconcilePlaybackQuality('eac3', qobuz.qualityOptions), 'auto_light');
      expect(reconcilePlaybackQuality('AAC_160', deezer.qualityOptions), 'auto_light');
      expect(reconcilePlaybackQuality('best', const []), 'auto_light');
    });

    test('switching provider in settings writes once and reconciles', () {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(settingsProvider.notifier);
      notifier.setPlaybackQuality('flac');
      var changes = 0;
      container.listen(settingsProvider, (_, __) => changes++);
      expect(notifier.setDefaultDownloadExtension(qobuz), isTrue);
      expect(container.read(settingsProvider).playbackQuality, 'HI_RES_LOSSLESS');
      expect(changes, 1, reason: 'a single write per provider change');
      // auto_light is kept as is.
      notifier.setPlaybackQuality('auto_light');
      changes = 0;
      expect(notifier.setDefaultDownloadExtension(jio), isTrue);
      expect(container.read(settingsProvider).playbackQuality, 'auto_light');
      expect(changes, 1);
      // No equivalent: explicit spatial id falls back to auto_light.
      notifier.setPlaybackQuality('eac3');
      expect(notifier.setDefaultDownloadExtension(deezer), isTrue);
      expect(container.read(settingsProvider).playbackQuality, 'auto_light');
    });
  });
}
