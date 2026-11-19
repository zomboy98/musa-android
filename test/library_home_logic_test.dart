import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/library_home.dart';
import 'package:mornye/models/track.dart';

Track _track(String id, {String? name, String artist = 'Artist'}) => Track(
  id: id,
  name: name ?? 'Song $id',
  artistName: artist,
  albumName: 'Album',
  duration: 180,
  source: 'catalog',
);

CollectionTrackEntry _favorite(Track track, int day) => CollectionTrackEntry(
  key: trackCollectionKey(track),
  track: track,
  addedAt: DateTime(2026, 1, day),
);

UserPlaylistCollection _playlist(
  String id,
  String name, {
  int created = 1,
  int updated = 1,
}) => UserPlaylistCollection(
  id: id,
  name: name,
  createdAt: DateTime(2026, 1, created),
  updatedAt: DateTime(2026, 1, updated),
  tracks: const [],
);

void main() {
  final a = _track('a', name: 'Zeta', artist: 'Beta');
  final b = _track('b', name: 'Árbol', artist: 'Alfa');
  final c = _track('c', name: 'Mango', artist: 'Alfa');
  final legacy = _track('legacy', name: 'Antigua', artist: 'Gamma');

  group('library = "+" songs plus favorites', () {
    test('favorites are a subset, never a second copy', () {
      final songs = mergeLibrarySongs(
        saved: [a, b, c],
        favorites: [_favorite(b, 2)],
      );
      expect(songs.map((s) => s.track.id), ['a', 'b', 'c']);
      expect(songs.where((s) => s.favorite).map((s) => s.track.id), ['b']);
      expect(songs.every((s) => s.saved), isTrue);
    });

    test('a favorite starred before the link still belongs to the library', () {
      final songs = mergeLibrarySongs(
        saved: [a],
        favorites: [_favorite(legacy, 3), _favorite(a, 2)],
      );
      expect(songs.map((s) => s.track.id), ['a', 'legacy']);
      final old = songs.last;
      expect(old.favorite, isTrue);
      expect(old.saved, isFalse);
      expect(old.addedAt, DateTime(2026, 1, 3));
    });

    test('duplicated references collapse to one row', () {
      final songs = mergeLibrarySongs(saved: [a, a, b], favorites: const []);
      expect(songs.map((s) => s.track.id), ['a', 'b']);
      expect(songs.map((s) => s.order), [0, 1]);
    });

    test('backfilling favorites into "+" is idempotent', () {
      final first = favoritesMissingFromSaved(
        saved: [a],
        favorites: [a, legacy, legacy, b],
      );
      expect(first.map((t) => t.id), ['legacy', 'b']);
      final second = favoritesMissingFromSaved(
        saved: [...first, a],
        favorites: [a, legacy, legacy, b],
      );
      expect(second, isEmpty);
    });
  });

  group('search, filter and order', () {
    final songs = mergeLibrarySongs(
      saved: [a, b, c],
      favorites: [_favorite(b, 2)],
    );

    test('search ignores case and accents across title, artist and album', () {
      expect(foldLibraryText('  CANCIÓN Ñu '), 'cancion nu');
      expect(filterLibrarySongs(songs, query: 'arbol').map((s) => s.track.id), [
        'b',
      ]);
      expect(filterLibrarySongs(songs, query: 'ALFA').map((s) => s.track.id), [
        'b',
        'c',
      ]);
      expect(filterLibrarySongs(songs, query: 'album'), hasLength(3));
      expect(filterLibrarySongs(songs, query: 'nothing'), isEmpty);
    });

    test('favorites filter keeps only starred songs', () {
      expect(
        filterLibrarySongs(songs, favoritesOnly: true).map((s) => s.track.id),
        ['b'],
      );
    });

    test('orders by recency, title and artist', () {
      List<String> ids(LibraryHomeSort sort) =>
          sortLibrarySongs(songs, sort).map((s) => s.track.id).toList();
      expect(ids(LibraryHomeSort.recent), ['a', 'b', 'c']);
      expect(ids(LibraryHomeSort.recentlyAdded), ['a', 'b', 'c']);
      expect(ids(LibraryHomeSort.alphabetical), ['b', 'c', 'a']);
      expect(ids(LibraryHomeSort.creator), ['b', 'c', 'a']);
    });
  });

  group('home entries', () {
    final songs = mergeLibrarySongs(
      saved: [a, b, c],
      favorites: [_favorite(b, 2)],
    );
    final playlists = [
      _playlist('p1', 'Viaje', created: 1, updated: 5),
      _playlist('p2', 'Ánimo', created: 4, updated: 4),
      _playlist('p3', 'Zen', created: 2, updated: 2),
    ];
    final artists = [
      CollectionArtistEntry(
        key: 'catalog:x',
        artistId: 'x',
        providerId: 'catalog',
        name: 'Luna',
        addedAt: DateTime(2026, 1, 3),
      ),
    ];

    List<LibraryHomeEntry> build(
      LibraryHomeFilter filter, {
      LibraryHomeSort sort = LibraryHomeSort.recent,
      String query = '',
      Set<String> pinned = const {},
      Map<String, int> played = const {},
    }) => buildLibraryHomeEntries(
      filter: filter,
      sort: sort,
      query: query,
      songs: songs,
      playlists: playlists,
      favoriteArtists: artists,
      pinnedPlaylists: pinned,
      playedPlaylists: played,
      downloadedCount: 7,
    );

    test('everything leads with the fixed shortcuts and their counts', () {
      final entries = build(LibraryHomeFilter.all);
      expect(entries.take(3).map((e) => e.kind), [
        LibraryHomeEntryKind.pinnedFavorites,
        LibraryHomeEntryKind.pinnedSongs,
        LibraryHomeEntryKind.pinnedDownloaded,
      ]);
      expect(entries.take(3).map((e) => e.count), [1, 3, 7]);
      expect(entries.take(3).every((e) => e.pinned && e.isShortcut), isTrue);
      // Songs are a filter, not rows mixed into the overview.
      expect(
        entries.where((e) => e.kind == LibraryHomeEntryKind.song),
        isEmpty,
      );
    });

    test('the song list never contains a favorites folder', () {
      for (final filter in [
        LibraryHomeFilter.songs,
        LibraryHomeFilter.favorites,
      ]) {
        final entries = build(filter);
        expect(
          entries.every((e) => e.kind == LibraryHomeEntryKind.song),
          isTrue,
          reason: '$filter lists songs only',
        );
      }
      expect(build(LibraryHomeFilter.songs), hasLength(3));
      expect(build(LibraryHomeFilter.favorites).single.song!.track.id, 'b');
    });

    test('each filter shows only its kind', () {
      expect(build(LibraryHomeFilter.playlists).map((e) => e.kind).toSet(), {
        LibraryHomeEntryKind.playlist,
      });
      expect(build(LibraryHomeFilter.artists).single.title, 'Luna');
      expect(
        build(LibraryHomeFilter.downloaded).single.kind,
        LibraryHomeEntryKind.pinnedDownloaded,
      );
      expect(build(LibraryHomeFilter.albums), isEmpty);
      expect(libraryFilterListsAlbums(LibraryHomeFilter.albums), isTrue);
      expect(libraryFilterListsAlbums(LibraryHomeFilter.all), isFalse);
      expect(libraryFilterListsAlbums(LibraryHomeFilter.downloaded), isTrue);
      expect(libraryFilterListsAlbums(LibraryHomeFilter.songs), isFalse);
    });

    test(
      'playlists order by recency, creation and name; pinned stay first',
      () {
        List<String> names(
          LibraryHomeSort sort, {
          Set<String> pinned = const {},
          Map<String, int> played = const {},
        }) => build(
          LibraryHomeFilter.playlists,
          sort: sort,
          pinned: pinned,
          played: played,
        ).map((e) => e.title).toList();

        expect(names(LibraryHomeSort.recent), ['Viaje', 'Ánimo', 'Zen']);
        expect(names(LibraryHomeSort.recentlyAdded), ['Ánimo', 'Zen', 'Viaje']);
        expect(names(LibraryHomeSort.alphabetical), ['Ánimo', 'Viaje', 'Zen']);
        expect(names(LibraryHomeSort.alphabetical, pinned: {'p3'}), [
          'Zen',
          'Ánimo',
          'Viaje',
        ]);
        expect(
          names(
            LibraryHomeSort.recent,
            played: {'p3': DateTime(2026, 2).millisecondsSinceEpoch},
          ),
          ['Zen', 'Viaje', 'Ánimo'],
        );
      },
    );

    test('searching everything hides shortcuts and finds songs', () {
      final entries = build(LibraryHomeFilter.all, query: 'an');
      expect(entries.any((e) => e.isShortcut), isFalse);
      expect(entries.map((e) => e.title), ['Ánimo', 'Mango']);
    });

    test('everything holds only the fixed shortcuts and the playlists', () {
      final many = [
        for (final name in ['Zeta', 'Armenta', 'El Randal'])
          CollectionArtistEntry(
            key: 'catalog:$name',
            artistId: name,
            providerId: 'catalog',
            name: name,
            addedAt: DateTime(2026, 1, 3),
          ),
      ];
      final all = buildLibraryHomeEntries(
        filter: LibraryHomeFilter.all,
        sort: LibraryHomeSort.recent,
        songs: songs,
        playlists: playlists.take(2).toList(),
        favoriteArtists: many,
      );
      expect(all.map((e) => e.kind), [
        LibraryHomeEntryKind.pinnedFavorites,
        LibraryHomeEntryKind.pinnedSongs,
        LibraryHomeEntryKind.pinnedDownloaded,
        LibraryHomeEntryKind.playlist,
        LibraryHomeEntryKind.playlist,
      ]);
      expect(
        buildLibraryHomeEntries(
          filter: LibraryHomeFilter.artists,
          sort: LibraryHomeSort.recent,
          songs: songs,
          favoriteArtists: many,
        ).map((e) => e.title),
        ['Armenta', 'El Randal', 'Zeta'],
      );
    });

    test('the album sort separates the songs under one header per album', () {
      Track inAlbum(String id, String album, int number) => Track(
        id: id,
        name: 'Song $id',
        artistName: 'Artist',
        albumName: album,
        duration: 1,
        trackNumber: number,
      );
      final albumSongs = mergeLibrarySongs(
        saved: [
          inAlbum('1', 'Beta', 2),
          inAlbum('2', 'Alfa', 1),
          inAlbum('3', 'Beta', 1),
        ],
        favorites: const [],
      );
      final entries = buildLibraryHomeEntries(
        filter: LibraryHomeFilter.songs,
        sort: LibraryHomeSort.album,
        songs: albumSongs,
      );
      expect(entries.map((e) => e.kind), [
        LibraryHomeEntryKind.albumHeader,
        LibraryHomeEntryKind.song,
        LibraryHomeEntryKind.albumHeader,
        LibraryHomeEntryKind.song,
        LibraryHomeEntryKind.song,
      ]);
      expect(
        [
          for (final e in entries)
            if (e.kind == LibraryHomeEntryKind.song) e.song!.track.id,
        ],
        ['2', '3', '1'],
      );
      expect(entries[0].title, 'Alfa');
      expect(entries[0].count, 1);
      expect(entries[2].title, 'Beta');
      expect(entries[2].count, 2);
      expect(
        buildLibraryHomeEntries(
          filter: LibraryHomeFilter.songs,
          sort: LibraryHomeSort.recent,
          songs: albumSongs,
        ).any((e) => e.kind == LibraryHomeEntryKind.albumHeader),
        isFalse,
      );
    });

    test('database order follows the chosen sort', () {
      expect(libraryBrowseSortFor(LibraryHomeSort.recent), 'latest');
      expect(libraryBrowseSortFor(LibraryHomeSort.recentlyAdded), 'latest');
      expect(libraryBrowseSortFor(LibraryHomeSort.alphabetical), 'a-z');
      expect(libraryBrowseSortFor(LibraryHomeSort.creator), 'a-z');
      expect(libraryBrowseSortFor(LibraryHomeSort.album), 'a-z');
    });
  });
}
