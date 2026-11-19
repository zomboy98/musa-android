import 'dart:convert';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/background_favorites.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/cover_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:path/path.dart' as p;

class _Library implements LibraryDatabase {
  @override
  Future<Map<String, dynamic>?> getById(String id) async => null;
  @override
  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String trackName,
    String artistName,
  ) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _History implements HistoryDatabase {
  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Favorites implements LibraryCollectionsDatabase {
  final rows = <String, String>{};
  @override
  Future<bool> containsLovedTrack(String trackKey) async =>
      rows.containsKey(trackKey);
  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    rows[trackKey] = trackJson;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'catalog player favorite retains identity and can replay offline cached audio',
    () async {
      final root = await Directory.systemTemp.createTemp('catalog-favorite-');
      addTearDown(() async => root.delete(recursive: true));
      final covers = CoverStore(directory: () async => root);
      addTearDown(covers.dispose);
      const track = Track(
        id: 'song-1',
        source: 'spotify',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        albumId: 'album-id',
        albumType: 'single',
        duration: 90,
        isrc: 'EXAMPLE12345',
        coverUrl: 'https://example.com/art.jpg',
        trackNumber: 3,
      );
      final media = playableFromCatalogTrack(track).toMediaItem(covers: covers);
      final rows = _Favorites();
      final favorites = BackgroundFavorites(
        library: _Library(),
        history: _History(),
        collections: rows,
        covers: covers,
      );
      expect(await favorites.toggle(media), isTrue);
      final saved = Track.fromJson(
        jsonDecode(rows.rows.values.single) as Map<String, dynamic>,
      );
      expect(saved.toJson(), track.toJson());
      expect(await favorites.isLoved(media), isTrue);
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      )..resolveDownloadService = (_, _) async => 'test-provider';
      final source = File(p.join(root.path, 'fixture.m4a'));
      await source.writeAsBytes([1, 2, 3]);
      await store.putTemporary(
        jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          128,
          'LOSSLESS',
          'test-provider',
          true,
        ]),
        source,
        qualityMetadata: {'provider': 'test-provider'},
      );
      final lease = await playback.acquire(saved);
      expect(await File(lease.path).readAsBytes(), [1, 2, 3]);
      await lease.release();
    },
  );

  test('malformed catalog and ordinary files cannot become remote tracks', () {
    for (final item in [
      const MediaItem(
        id: 'catalog:broken',
        title: 'Bad',
        extras: {'source': 'catalog:broken'},
      ),
      const MediaItem(
        id: '/file.mp3',
        title: 'File',
        extras: {'source': '/file.mp3'},
      ),
      const MediaItem(
        id: '/file.mp3',
        title: 'File',
        extras: {'source': 'catalog:e30='},
      ),
      const MediaItem(
        id: 'https://example.com/file',
        title: 'URL',
        extras: {'source': 'https://example.com/file'},
      ),
    ]) {
      expect(collectionTrackForMedia(item, null).source, 'local');
    }
  });
  test('existing download match retains its library identity', () {
    final history = DownloadHistoryItem(
      id: 'history-id',
      trackName: 'Saved',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: '/saved.mp3',
      service: 'example',
      downloadedAt: DateTime.utc(2025),
    );
    final match = UnifiedLibraryItem.fromDownloadHistory(history);
    final item = playableFromCatalogTrack(
      const Track(
        id: 'remote',
        source: 'spotify',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 90,
      ),
    ).toMediaItem();
    expect(
      collectionTrackForMedia(item, match).toJson(),
      match.toTrack().toJson(),
    );
    final local = UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'local-id',
        trackName: 'Local',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: '/local.mp3',
        scannedAt: DateTime.utc(2025),
      ),
    );
    expect(
      collectionTrackForMedia(item, local).toJson(),
      local.toTrack().toJson(),
    );
  });
}
