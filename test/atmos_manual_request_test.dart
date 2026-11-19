import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/provider_retry_policy.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:shared_preferences/shared_preferences.dart';

Extension _provider(String id, List<(String, String)> options) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  qualityOptions: [
    for (final o in options) QualityOption(id: o.$1, label: o.$1, kind: o.$2),
  ],
);

final _tidal = _provider('tidal-web', [
  ('DOLBY_ATMOS', 'spatial'),
  ('HI_RES_LOSSLESS', 'lossless'),
  ('LOSSLESS', 'lossless'),
  ('HIGH', 'lossy'),
]);
final _amazon = _provider('amazon', [
  ('best', 'lossless'),
  ('opus', 'lossy'),
  ('eac3', 'spatial'),
  ('ac4', 'spatial'),
]);
final _qobuz = _provider('qobuz-web', [
  ('HI_RES_LOSSLESS', 'lossless'),
  ('LOSSLESS', 'lossless'),
]);

Track _track(String id) => Track(
  id: id,
  source: 'deezer',
  name: id,
  artistName: 'A',
  albumName: 'B',
  duration: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('candidatos para una peticion Atmos', () {
    test('Atmos se pide a quien lo ofrece y luego baja a sin perdida', () {
      final list = streamingRelayCandidates(
        settingsQuality: 'eac3',
        first: const StreamingRequest('amazon', 'eac3'),
        extensions: [_amazon, _tidal, _qobuz],
        providerPriority: const ['amazon', 'tidal-web', 'qobuz-web'],
      );
      expect(list.first, const StreamingRequest('tidal-web', 'DOLBY_ATMOS'));
      expect(list[1], const StreamingRequest('amazon', 'best'));
      expect(
        list.where((r) => r.serviceId == 'qobuz-web').first.qualityId,
        'HI_RES_LOSSLESS',
      );
      expect(
        list.indexOf(const StreamingRequest('amazon', 'best')) <
            list.indexOf(const StreamingRequest('amazon', 'opus')),
        isTrue,
      );
    });

    test('con solo amazon, sin Atmos baja a su mejor sin perdida', () {
      final list = streamingRelayCandidates(
        settingsQuality: 'eac3',
        first: const StreamingRequest('amazon', 'eac3'),
        extensions: [_amazon],
      );
      expect(list.first, const StreamingRequest('amazon', 'best'));
    });
  });

  group('peticion manual de Atmos', () {
    late List<String> tried;
    late CatalogPlayback playback;

    setUp(() async {
      ProviderCooldown.instance = ProviderCooldown();
      ProviderRequestGate.instance = ProviderRequestGate();
      SharedPreferences.setMockInitialValues({});
      tried = [];
      final root = await Directory.systemTemp.createTemp('atmos-manual-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      playback = CatalogPlayback(
        storage: store,
        resolvedPreparerFactory: (_, service, useFallback) =>
            TemporaryTrackPreparer(
              stagingRoot: Directory('${root.path}/staging'),
              download: (dir, _) async {
                tried.add(service);
                return File('${dir.path}/input').writeAsString('audio');
              },
              takeQualityMetadata: (_) => {'provider': service},
              cancelDownload: (_) async {},
              codec: (_) async => 'aac',
              container: (_) async => 'mp4',
              validate: (_) async => true,
            ),
      );
      playback.defaultService = 'qobuz-web';
      playback.quality = 'LOSSLESS';
      playback.retryPolicy = ProviderRetryPolicy(spacing: Duration.zero);
      playback.resolveDownloadService = (requested, _) async => requested;
      playback.resolveStreaming = (quality, service, _) async =>
          StreamingRequest(service, quality);
    });

    test('pide a tidal sin cambiar la preferencia ni el proveedor', () async {
      final lease = await playback.acquire(
        _track('x1'),
        relay: false,
        engineFallback: false,
        forced: const StreamingRequest('tidal-web', 'DOLBY_ATMOS'),
      );
      expect(tried, ['tidal-web']);
      expect(playback.defaultService, 'qobuz-web');
      expect(playback.quality, 'LOSSLESS');
      await lease.release();
    });

    test('no pide a un proveedor en enfriamiento', () async {
      ProviderCooldown.instance.noteRateLimited('tidal-web', 300);
      final track = _track('x2');
      expect(playback.providerResting(track, 'tidal-web'), isTrue);
      expect(playback.providerResting(track, 'amazon'), isFalse);
      await expectLater(
        playback.acquire(
          track,
          relay: false,
          engineFallback: false,
          forced: const StreamingRequest('tidal-web', 'DOLBY_ATMOS'),
        ),
        throwsA(isA<CatalogPlaybackException>()),
      );
      expect(tried, isEmpty);
    });

    test('la peticion manual se salta el retroceso de la pista', () async {
      final policy = playback.retryPolicy!;
      policy.recordFailure('tidal-web', playback.key(_track('x3')));
      final lease = await playback.acquire(
        _track('x3'),
        relay: false,
        engineFallback: false,
        forced: const StreamingRequest('tidal-web', 'DOLBY_ATMOS'),
      );
      expect(tried, ['tidal-web']);
      await lease.release();
    });
  });
}
