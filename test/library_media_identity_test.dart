import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/apple_animated_artwork.dart';
import 'package:mornye/services/library_media_identity.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/library_database.dart';

class _Library implements LibraryDatabase {
  _Library(this.row, [this.matches = const []]);
  final Map<String, dynamic>? row;
  final List<Map<String, dynamic>> matches;
  @override
  Future<Map<String, dynamic>?> getById(String id) async => row;
  @override
  Future<List<Map<String, dynamic>>> findByTrackAndArtist(
    String title,
    String artist,
  ) async => matches;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('a reused media id cannot select an unrelated library file', () async {
    Map<String, dynamic> row(String id, String path) => LocalLibraryItem(
      id: id,
      trackName: 'Song',
      artistName: 'Artist',
      albumName: '',
      filePath: path,
      scannedAt: DateTime.utc(2025),
    ).toJson();
    final old = row('shared-id', '/old.mp3');
    final actual = row('new-id', '/actual.mp3');
    Future<String?> resolve(
      String source,
      List<Map<String, dynamic>> matches,
    ) async => (await libraryItemForMedia(
      id: 'shared-id',
      source: source,
      title: 'Song',
      artist: 'Artist',
      historyByPath: (_) async => null,
      library: _Library(old, matches),
    ))?.localItem?.id;
    expect(await resolve('/actual.mp3', [actual]), 'new-id');
    expect(await resolve('/unrelated.mp3', []), isNull);
    expect(await resolve('/old.mp3', []), 'shared-id');
  });
  test('a loved song keeps only a cover that outlasts this run', () {
    String? cover(String artUri) => collectionTrackForMedia(
      MediaItem(
        id: 'network://nas/Album/song.flac',
        title: 'Song',
        artUri: Uri.parse(artUri),
      ),
      null,
    ).coverUrl;

    for (final durable in [
      'file:///data/user/0/app/files/covers/a_b.image',
      'https://example.com/cover.jpg',
    ]) {
      expect(cover(durable), durable);
    }
    for (final temporary in [
      'http://127.0.0.1:41234/7f3a',
      'file:///data/user/0/app/cache/network_metadata/a1.jpg',
      Uri.file('${Directory.systemTemp.path}/cover.jpg').toString(),
    ]) {
      expect(cover(temporary), isNull, reason: temporary);
    }
  });

  group('animated artwork ISRC', () {
    MediaItem item({Map<String, dynamic>? extras, String id = 'song-1'}) =>
        MediaItem(id: id, title: 'Song', artist: 'Artist', extras: extras);

    test('the fallback track keeps the ISRC the media item carries', () {
      final direct = collectionTrackForMedia(
        item(extras: {'isrc': 'us-aaa 12 34567'}),
        null,
      );
      expect(direct.isrc, 'USAAA1234567');
      expect(animatedArtworkRequestParams(direct)['isrc'], 'USAAA1234567');
      expect(
        animatedArtworkIsrcSource(
          item(extras: {'isrc': 'USAAA1234567'}),
          direct,
        ),
        'fallback',
      );
      final display = collectionTrackForMedia(
        item(
          extras: {
            'displayMetadata': {'isrc': 'USAAA1234567'},
          },
        ),
        null,
      );
      expect(display.isrc, 'USAAA1234567');
      final none = collectionTrackForMedia(item(), null);
      expect(none.isrc, isNull);
      expect(animatedArtworkIsrcSource(item(), none), 'none');
    });

    test('a catalog item reports the catalog as the ISRC source', () {
      final catalog = playableFromCatalogTrack(
        Track(
          id: 'spotify-id',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          isrc: 'USAAA1234567',
          duration: 200,
          source: 'deezer',
        ),
      );
      final media = catalog.toMediaItem();
      final track = collectionTrackForMedia(media, null);
      expect(track.isrc, 'USAAA1234567');
      expect(animatedArtworkIsrcSource(media, track), 'catalog');
    });

    test('a library record without ISRC takes the one the item carries', () {
      final record = LocalLibraryItem(
        id: 'lib-1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: '',
        filePath: '/song.mp3',
        scannedAt: DateTime.utc(2025),
      );
      final match = UnifiedLibraryItem.fromLocalLibrary(record);
      final media = item(id: 'other', extras: {'isrc': 'USAAA1234567'});
      final track = collectionTrackForMedia(media, match);
      expect(track.id, 'lib-1');
      expect(track.isrc, 'USAAA1234567');
      expect(animatedArtworkIsrcSource(media, track), 'library');
    });
  });
}
