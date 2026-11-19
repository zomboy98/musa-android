import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:path/path.dart' as p;

import 'support/music_player_automix_harness.dart';

class FailingTimestampStore extends CatalogAudioStore {
  FailingTimestampStore(Directory root)
    : super(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );

  bool fail = false;
  bool failNext = false;

  @override
  Future<void> recordPlaybackLease(CatalogAudioLease lease) {
    if (fail || failNext) {
      failNext = false;
      throw FileSystemException('timestamp failed');
    }
    return super.recordPlaybackLease(lease);
  }
}

String _variant(CatalogPlayback playback, Track track) => jsonEncode([
  'catalog-audio-v5',
  playback.key(track),
  128,
  'ac4',
  'test-provider',
  true,
]);

void main() {
  setUpMusicPlayerHarness();

  for (final action in ['stop', 'change', 'dispose', 'start', 'resume']) {
    test('releases catalog lease after timestamp failure on $action', () async {
      const first = Track(
        id: 'one',
        source: 'spotify',
        name: 'One',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      const second = Track(
        id: 'two',
        source: 'spotify',
        name: 'Two',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      final root = await Directory.systemTemp.createTemp('catalog-retire-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final store = FailingTimestampStore(root);
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      );
      final source = File(p.join(root.path, 'fixture.mp3'));
      await source.writeAsBytes([1, 2, 3]);
      playback.resolveDownloadService = (_, _) async => 'test-provider';
      for (final track in [first, second]) {
        await store.putTemporary(
          _variant(playback, track),
          source,
          extension: '.m4a',
          qualityMetadata: {'provider': 'test-provider'},
        );
      }
      await handler.dispose();
      handler = MusicPlayerHandler(catalogPlaybackOverride: playback);
      if (action == 'start') store.fail = true;
      await handler.setQueueAndPlay([
        playableFromCatalogTrack(first),
        playableFromCatalogTrack(second),
      ]);
      if (action == 'start' || action == 'resume') {
        if (action == 'resume') {
          await handler.pause();
          store.fail = true;
          await handler.play();
        }
        expect(handler.playbackState.value.playing, isTrue);
        await store.clearTemporary();
        expect(await store.lookup(_variant(playback, first)), isNotNull);
        await handler.stop();
        await store.clearTemporary();
        expect(await store.lookup(_variant(playback, first)), isNull);
        return;
      }
      store.fail = true;
      if (action == 'stop') {
        await handler.stop();
      } else if (action == 'dispose') {
        await handler.dispose();
      } else {
        // Only the outgoing timestamp fails; incoming playback can record its own.
        store.failNext = true;
        store.fail = false;
        await handler.skipToNext();
        expect(handler.playbackState.value.queueIndex, 1);
        expect(handler.playbackState.value.playing, isTrue);
      }
      await store.clearTemporary();
      expect(await store.lookup(_variant(playback, first)), isNull);
    });
  }
}
