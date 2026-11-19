import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/music_player_automix_harness.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  setUpMusicPlayerHarness();

  const track = Track(
    id: 'start-guard-track',
    source: 'spotify',
    name: 'S',
    artistName: 'A',
    albumName: 'B',
    duration: 200,
  );

  test('reproducir otra vez la misma pista en preparacion no la reinicia',
      () async {
    final root = await Directory.systemTemp.createTemp('start-guard-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        return;
      }
    });
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await store.initialize();
    final gate = Completer<void>();
    var downloads = 0;
    final cancelled = <String>[];
    final playback =
        CatalogPlayback(
            storage: store,
            savedLookup: (_) async => false,
            resolvedPreparerFactory: (_, service, _) => TemporaryTrackPreparer(
              stagingRoot: Directory(p.join(root.path, 'staging')),
              download: (directory, _) async {
                downloads++;
                await gate.future;
                return File(
                  p.join(directory.path, 'input'),
                ).writeAsBytes([1, 2, 3]);
              },
              takeQualityMetadata: (_) => {'provider': service},
              cancelDownload: (id) async => cancelled.add(id),
              codec: (_) async => 'aac',
              container: (_) async => 'mp4',
              validate: (_) async => true,
            ),
          )
          ..defaultService = 'a'
          ..resolveDownloadService = (requested, _) async =>
              requested.isEmpty ? 'a' : requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service.isEmpty ? 'a' : service, 'aac_160');
    await handler.dispose();
    handler = MusicPlayerHandler(catalogPlaybackOverride: playback);
    final media = playableFromCatalogTrack(track);
    final first = handler.setQueueAndPlay([media]);
    for (var i = 0; i < 200 && downloads == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(downloads, 1);
    final second = handler.skipToQueueItem(0);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(cancelled, isEmpty);
    expect(downloads, 1);
    gate.complete();
    await Future.wait([first, second]);
    expect(downloads, 1);
    expect(handler.playbackState.value.playing, isTrue);
  });
}
