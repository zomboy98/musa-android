import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: 'q',
    source: 'spotify',
    name: 'Q',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );

  Future<CatalogPlayback> build() async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('quality-service-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    return CatalogPlayback(storage: store)..defaultService = 'tidal';
  }

  Future<List<String>> requested(CatalogPlayback playback) async {
    final seen = <String>[];
    playback
      ..resolveStreaming = (quality, service, _) async {
        seen
          ..add(quality)
          ..add(service);
        return StreamingRequest(service, quality);
      }
      ..resolveDownloadService = (_, _) async => throw StateError('stop');
    try {
      await playback.acquire(track);
    } catch (_) {}
    return seen;
  }

  test('the chosen format is requested from the provider that offers it', () async {
    final playback = await build();
    playback.setQualityOverride(track, 'best', service: 'amazon');
    expect(await requested(playback), ['best', 'amazon']);
  });

  test('without a chosen provider the default one is used', () async {
    final playback = await build();
    playback.setQualityOverride(track, 'LOSSLESS');
    expect(await requested(playback), ['LOSSLESS', 'tidal']);
  });

  test('clearing the override clears the provider too', () async {
    final playback = await build();
    playback.setQualityOverride(track, 'best', service: 'amazon');
    playback.setQualityOverride(track, null);
    expect(playback.serviceOverrideFor(track), isNull);
    expect(playback.qualityOverrideFor(track), isNull);
  });
}
