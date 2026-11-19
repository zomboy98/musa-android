import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_origin_inference.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _song(int index) => Track(
  id: 'track-$index',
  name: 'Song $index',
  artistName: 'Artist',
  albumName: 'Album ${index % 3}',
  duration: 1,
  isrc: 'ISRC$index',
);

UserPlaylistCollection _playlist(String id, String name, List<Track> tracks) =>
    UserPlaylistCollection(
      id: id,
      name: name,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      tracks: [
        for (final track in tracks)
          CollectionTrackEntry(
            key: trackCollectionKey(track),
            track: track,
            addedAt: DateTime.utc(2026),
          ),
      ],
    );

void main() {
  test('queue items keep their origin through the stored queue', () {
    final item = DownloadItem(
      id: 'a',
      track: _song(1),
      service: 's',
      createdAt: DateTime.utc(2026),
      origin: DownloadOrigin.playlistOf('list-1'),
    );
    expect(
      DownloadItem.fromJson(
        (jsonDecode(jsonEncode(item)) as Map<String, dynamic>),
      ).origin,
      DownloadOrigin.playlistOf('list-1'),
    );
    final legacy = (jsonDecode(jsonEncode(item)) as Map<String, dynamic>)
      ..remove('origin');
    expect(DownloadItem.fromJson(legacy).origin, isNull);
  });

  group('songs queued before origins were stored', () {
    final inList = [for (var i = 0; i < 6; i++) _song(i)];
    final outside = _song(99);
    final collections = LibraryCollectionsState(
      isLoaded: true,
      playlists: [
        _playlist('big', 'Mi lista', inList),
        _playlist('other', 'Otra', [inList.first]),
      ],
    );

    DownloadOrigin? infer(
      Track track, {
      DownloadOrigin? stated,
      String? name,
      List<String> kept = const [],
      LibraryCollectionsState? state,
    }) => inferDownloadOrigin(
      stated: stated,
      track: track,
      playlistName: name,
      collections: state ?? collections,
      keptPlaylistIds: kept,
    );

    test('a song of a list becomes a playlist download of that list', () {
      for (final track in inList.skip(1)) {
        expect(infer(track), DownloadOrigin.playlistOf('big'));
      }
      expect(
        infer(inList.first, name: 'Otra'),
        DownloadOrigin.playlistOf('other'),
      );
      expect(
        infer(inList.first, kept: ['big']),
        DownloadOrigin.playlistOf('big'),
      );
      expect(infer(inList.first), DownloadOrigin.playlist);
    });

    test('a song outside the lists and a stated origin stay as they are', () {
      expect(infer(outside), isNull);
      expect(
        infer(outside, stated: DownloadOrigin.track),
        DownloadOrigin.track,
      );
      expect(
        infer(inList[2], stated: DownloadOrigin.album),
        DownloadOrigin.album,
      );
      expect(
        infer(inList[2], stated: DownloadOrigin.playlistOf('x')),
        DownloadOrigin.playlistOf('x'),
      );
    });

    test('nothing is inferred before the collections are loaded', () {
      expect(infer(inList[1], state: LibraryCollectionsState()), isNull);
    });
  });

  test(
    'a download of a list moves it to the top of the recent order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final order = container.read(libraryPlaylistOrderProvider.notifier);
      await container.read(libraryPlaylistOrderProvider.future);
      await order.recordDownloadActivity('big');
      final first = container.read(libraryPlaylistOrderProvider).value!;
      expect(first.played['big'], isNotNull);
      await order.recordDownloadActivity('big');
      expect(
        container.read(libraryPlaylistOrderProvider).value!.played['big'],
        first.played['big'],
      );
    },
  );
}
