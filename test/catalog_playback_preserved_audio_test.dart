import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new preparation does not reuse an old converted AAC variant', () async {
    final root = await Directory.systemTemp.createTemp('catalog-audio-v5-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    const track = Track(id: 'track', source: 'spotify', name: 'Track', artistName: 'Artist', albumName: 'Album', duration: 1);
    var downloads = 0;
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (directory, _) async {
          downloads++;
          return File('${directory.path}/source').writeAsString('new');
        },
        takeQualityMetadata: (_) => {'provider': 'A'},
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    )..defaultService = 'A';
    final oldKey = jsonEncode(['catalog-aac-v4', playback.key(track), 128, 'LOSSLESS', 'A', true]);
    final old = await File('${root.path}/old').writeAsString('old');
    await store.putTemporary(oldKey, old, extension: '.m4a', qualityMetadata: {'provider': 'A'});
    final lease = await playback.acquire(track);
    expect(downloads, 1);
    expect(await File(lease.path).readAsString(), 'new');
    expect(await store.lookup(oldKey), isNotNull);
    await lease.release();
  });

  test('unrecognized container is not published', () async {
    final root = await Directory.systemTemp.createTemp('catalog-invalid-audio-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    const track = Track(id: 'bad', source: 'spotify', name: 'Track', artistName: 'Artist', albumName: 'Album', duration: 1);
    final playback = CatalogPlayback(
      storage: store,
      savedLookup: (_) async => false,
      preparerFactory: (_) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (directory, _) => File('${directory.path}/source').writeAsString('invalid'),
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'unknown',
        validate: (_) async => true,
      ),
    );
    await expectLater(playback.acquire(track), throwsA(isA<CatalogPlaybackException>()));
    expect(await store.variantsForTrack(playback.key(track)), isEmpty);
  });

  for (final format in [
    ('aac', 'mp4', '.m4a'),
    ('opus', 'ogg', '.opus'),
    ('flac', 'flac', '.flac'),
    ('mp3', 'mp3', '.mp3'),
    ('pcm_s16le', 'wav', '.wav'),
    ('pcm_s24le', 'wav', '.wav'),
    ('pcm_s32le', 'wav', '.wav'),
    ('pcm_f32le', 'wav', '.wav'),
    ('vorbis', 'ogg', '.ogg'),
  ]) {
    test('publishes verified ${format.$1} with ${format.$3}', () async {
      final root = await Directory.systemTemp.createTemp('catalog-format-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      const track = Track(id: 'format', source: 'spotify', name: 'Track', artistName: 'Artist', albumName: 'Album', duration: 1);
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (directory, _) => File('${directory.path}/input').writeAsString('verified bytes'),
          takeQualityMetadata: (_) => {'provider': 'A'},
          cancelDownload: (_) async {},
          codec: (_) async => format.$1,
          container: (_) async => format.$2,
          validate: (_) async => true,
        ),
      )..defaultService = 'A';
      final lease = await playback.acquire(track);
      expect(lease.path, endsWith(format.$3));
      expect(await File(lease.path).readAsString(), 'verified bytes');
      final entry = (await store.lookup(lease.id))!;
      expect(entry.qualityMetadata['output_codec'], format.$1);
      expect(entry.qualityMetadata['output_container'], format.$2);
      expect(entry.qualityMetadata['output_decode_validated'], isTrue);
      await lease.release();
    });
  }
}
