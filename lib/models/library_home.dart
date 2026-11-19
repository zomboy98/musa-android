import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';

/// What the library home lists. `all` mixes every kind.
enum LibraryHomeFilter {
  all,
  songs,
  albums,
  artists,
  playlists,
  downloaded,
  favorites,
}

enum LibraryHomeSort { recent, recentlyAdded, alphabetical, creator, album }

enum LibraryHomeView { compact, list, grid }

enum LibraryHomeEntryKind {
  /// Fixed shortcuts that lead the list; they are views, not folders.
  pinnedFavorites,
  pinnedSongs,
  pinnedDownloaded,
  playlist,
  artist,
  song,

  /// Heading of one album inside the song list sorted by album.
  albumHeader,
}

/// A song the listener keeps: added with "+", starred, or both.
class LibrarySong {
  const LibrarySong({
    required this.key,
    required this.track,
    required this.favorite,
    required this.saved,
    required this.order,
    this.addedAt,
  });

  final String key;
  final Track track;

  /// Starred. Every favorite is a library song.
  final bool favorite;

  /// Explicitly added with "+". False only for favorites starred before the
  /// two concepts were linked; they still belong to the library.
  final bool saved;

  /// Position by recency: 0 is the newest.
  final int order;
  final DateTime? addedAt;
}

/// The library is everything added with "+" plus every favorite. Favorites are
/// a subset by construction, so no stored data has to be rewritten.
List<LibrarySong> mergeLibrarySongs({
  required List<Track> saved,
  required List<CollectionTrackEntry> favorites,
}) {
  final favoriteByKey = <String, CollectionTrackEntry>{
    for (final entry in favorites) entry.key: entry,
  };
  final songs = <LibrarySong>[];
  final seen = <String>{};
  for (final track in saved) {
    final key = trackCollectionKey(track);
    if (!seen.add(key)) continue;
    final favorite = favoriteByKey[key];
    songs.add(
      LibrarySong(
        key: key,
        track: track,
        favorite: favorite != null,
        saved: true,
        order: songs.length,
        addedAt: favorite?.addedAt,
      ),
    );
  }
  for (final entry in favorites) {
    if (!seen.add(entry.key)) continue;
    songs.add(
      LibrarySong(
        key: entry.key,
        track: entry.track,
        favorite: true,
        saved: false,
        order: songs.length,
        addedAt: entry.addedAt,
      ),
    );
  }
  return List.unmodifiable(songs);
}

/// Favorites that are not yet stored as "+" references. Storing them is
/// idempotent: a second pass over the result finds nothing left to add.
List<Track> favoritesMissingFromSaved({
  required List<Track> saved,
  required Iterable<Track> favorites,
}) {
  final keys = saved.map(trackCollectionKey).toSet();
  final missing = <Track>[];
  for (final track in favorites) {
    if (keys.add(trackCollectionKey(track))) missing.add(track);
  }
  return missing;
}

const _foldFrom = 'áàäâãåéèëêíìïîóòöôõúùüûñç';
const _foldTo = 'aaaaaaeeeeiiiiooooouuuunc';

/// Lowercase text without accents, so "cancion" finds "Canción".
String foldLibraryText(String value) {
  final lower = value.toLowerCase().trim();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    final index = _foldFrom.indexOf(char);
    buffer.write(index < 0 ? char : _foldTo[index]);
  }
  return buffer.toString();
}

/// Name order for artists: no case, no accents, and "ñ" right after "n".
String artistSortKey(String name) =>
    foldLibraryText(name.toLowerCase().replaceAll('ñ', 'n~'));

List<CollectionArtistEntry> sortArtistsByName(
  Iterable<CollectionArtistEntry> artists,
) {
  final keyed = [
    for (final artist in artists) (artistSortKey(artist.name), artist),
  ];
  keyed.sort((a, b) {
    final order = a.$1.compareTo(b.$1);
    return order != 0 ? order : a.$2.key.compareTo(b.$2.key);
  });
  return [for (final item in keyed) item.$2];
}

bool _matches(String query, Iterable<String?> fields) {
  if (query.isEmpty) return true;
  for (final field in fields) {
    if (field != null && foldLibraryText(field).contains(query)) return true;
  }
  return false;
}

List<LibrarySong> filterLibrarySongs(
  List<LibrarySong> songs, {
  String query = '',
  bool favoritesOnly = false,
}) {
  final folded = foldLibraryText(query);
  if (folded.isEmpty && !favoritesOnly) return songs;
  return songs
      .where(
        (song) =>
            (!favoritesOnly || song.favorite) &&
            _matches(folded, [
              song.track.name,
              song.track.artistName,
              song.track.albumName,
            ]),
      )
      .toList(growable: false);
}

List<LibrarySong> sortLibrarySongs(
  List<LibrarySong> songs,
  LibraryHomeSort sort,
) {
  int byTitle(LibrarySong a, LibrarySong b) {
    final title = foldLibraryText(
      a.track.name,
    ).compareTo(foldLibraryText(b.track.name));
    return title != 0 ? title : a.order.compareTo(b.order);
  }

  switch (sort) {
    case LibraryHomeSort.recent:
    case LibraryHomeSort.recentlyAdded:
      return songs;
    case LibraryHomeSort.alphabetical:
      return [...songs]..sort(byTitle);
    case LibraryHomeSort.album:
      return [...songs]..sort((a, b) {
        final album = foldLibraryText(
          a.track.albumName,
        ).compareTo(foldLibraryText(b.track.albumName));
        if (album != 0) return album;
        final artist = foldLibraryText(
          a.track.albumArtist ?? a.track.artistName,
        ).compareTo(foldLibraryText(b.track.albumArtist ?? b.track.artistName));
        if (artist != 0) return artist;
        final disc = (a.track.discNumber ?? 0).compareTo(
          b.track.discNumber ?? 0,
        );
        if (disc != 0) return disc;
        final number = (a.track.trackNumber ?? 0).compareTo(
          b.track.trackNumber ?? 0,
        );
        return number != 0 ? number : byTitle(a, b);
      });
    case LibraryHomeSort.creator:
      return [...songs]..sort((a, b) {
        final artist = foldLibraryText(
          a.track.artistName,
        ).compareTo(foldLibraryText(b.track.artistName));
        return artist != 0 ? artist : byTitle(a, b);
      });
  }
}

/// One row or cell of the library home, independent of how it is drawn.
class LibraryHomeEntry {
  const LibraryHomeEntry({
    required this.kind,
    required this.id,
    required this.title,
    this.creator = '',
    this.count,
    this.pinned = false,
    this.recency = 0,
    this.added = 0,
    this.song,
    this.playlist,
    this.artist,
  });

  final LibraryHomeEntryKind kind;
  final String id;

  /// Empty for the fixed shortcuts, which the screen names in its language.
  final String title;
  final String creator;
  final int? count;

  /// A fixed shortcut or a playlist the listener pinned.
  final bool pinned;
  final int recency;
  final int added;
  final LibrarySong? song;
  final UserPlaylistCollection? playlist;
  final CollectionArtistEntry? artist;

  bool get isShortcut =>
      kind == LibraryHomeEntryKind.pinnedFavorites ||
      kind == LibraryHomeEntryKind.pinnedSongs ||
      kind == LibraryHomeEntryKind.pinnedDownloaded;
}

/// Entries held in memory for [filter]. Albums and scanned artists are paged
/// from the database and appended by the screen.
List<LibraryHomeEntry> buildLibraryHomeEntries({
  required LibraryHomeFilter filter,
  required LibraryHomeSort sort,
  String query = '',
  required List<LibrarySong> songs,
  List<UserPlaylistCollection> playlists = const [],
  List<CollectionArtistEntry> favoriteArtists = const [],
  Set<String> pinnedPlaylists = const {},
  Map<String, int> playedPlaylists = const {},
  int downloadedCount = 0,
}) {
  final folded = foldLibraryText(query);
  final searching = folded.isNotEmpty;
  final entries = <LibraryHomeEntry>[];

  // Shortcuts are views over the library, never rows inside the song list.
  if (!searching) {
    if (filter == LibraryHomeFilter.all) {
      entries.add(
        LibraryHomeEntry(
          kind: LibraryHomeEntryKind.pinnedFavorites,
          id: 'pinned:favorites',
          title: '',
          count: songs.where((song) => song.favorite).length,
          pinned: true,
        ),
      );
      entries.add(
        LibraryHomeEntry(
          kind: LibraryHomeEntryKind.pinnedSongs,
          id: 'pinned:songs',
          title: '',
          count: songs.length,
          pinned: true,
        ),
      );
    }
    if (filter == LibraryHomeFilter.all ||
        filter == LibraryHomeFilter.downloaded) {
      entries.add(
        LibraryHomeEntry(
          kind: LibraryHomeEntryKind.pinnedDownloaded,
          id: 'pinned:downloaded',
          title: '',
          count: downloadedCount,
          pinned: true,
        ),
      );
    }
  }

  final mixed = <LibraryHomeEntry>[];
  if (filter == LibraryHomeFilter.all ||
      filter == LibraryHomeFilter.playlists) {
    for (final playlist in playlists) {
      if (!_matches(folded, [playlist.name])) continue;
      final played = playedPlaylists[playlist.id] ?? 0;
      final updated = playlist.updatedAt.millisecondsSinceEpoch;
      mixed.add(
        LibraryHomeEntry(
          kind: LibraryHomeEntryKind.playlist,
          id: 'playlist:${playlist.id}',
          title: playlist.name,
          count: playlist.trackCount,
          pinned: pinnedPlaylists.contains(playlist.id),
          recency: played > updated ? played : updated,
          added: playlist.createdAt.millisecondsSinceEpoch,
          playlist: playlist,
        ),
      );
    }
  }
  if ((filter == LibraryHomeFilter.all && searching) ||
      filter == LibraryHomeFilter.artists) {
    for (final artist in favoriteArtists) {
      if (!_matches(folded, [artist.name])) continue;
      final added = artist.addedAt.millisecondsSinceEpoch;
      mixed.add(
        LibraryHomeEntry(
          kind: LibraryHomeEntryKind.artist,
          id: 'artist:${artist.key}',
          title: artist.name,
          creator: artist.name,
          recency: added,
          added: added,
          artist: artist,
        ),
      );
    }
  }
  mixed.sort((a, b) {
    if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
    if (filter == LibraryHomeFilter.artists) {
      final byName = artistSortKey(a.title).compareTo(artistSortKey(b.title));
      return byName != 0 ? byName : a.id.compareTo(b.id);
    }
    final order = switch (sort) {
      LibraryHomeSort.recent => b.recency.compareTo(a.recency),
      LibraryHomeSort.recentlyAdded => b.added.compareTo(a.added),
      LibraryHomeSort.alphabetical || LibraryHomeSort.album => 0,
      LibraryHomeSort.creator => foldLibraryText(
        a.creator,
      ).compareTo(foldLibraryText(b.creator)),
    };
    if (order != 0) return order;
    final title = foldLibraryText(a.title).compareTo(foldLibraryText(b.title));
    return title != 0 ? title : a.id.compareTo(b.id);
  });
  entries.addAll(mixed);

  final listsSongs =
      filter == LibraryHomeFilter.songs ||
      filter == LibraryHomeFilter.favorites ||
      (filter == LibraryHomeFilter.all && searching);
  if (listsSongs) {
    final visible = sortLibrarySongs(
      filterLibrarySongs(
        songs,
        query: query,
        favoritesOnly: filter == LibraryHomeFilter.favorites,
      ),
      sort,
    );
    LibraryHomeEntry songEntry(LibrarySong song) => LibraryHomeEntry(
      kind: LibraryHomeEntryKind.song,
      id: 'song:${song.key}',
      title: song.track.name,
      creator: song.track.artistName,
      song: song,
    );
    if (sort == LibraryHomeSort.album) {
      var start = 0;
      while (start < visible.length) {
        final key = _albumGroupKey(visible[start]);
        var end = start;
        while (end < visible.length && _albumGroupKey(visible[end]) == key) {
          end++;
        }
        final first = visible[start];
        entries.add(
          LibraryHomeEntry(
            kind: LibraryHomeEntryKind.albumHeader,
            id: 'album:$key',
            title: first.track.albumName,
            creator: first.track.albumArtist ?? first.track.artistName,
            count: end - start,
            song: first,
          ),
        );
        for (var i = start; i < end; i++) {
          entries.add(songEntry(visible[i]));
        }
        start = end;
      }
    } else {
      for (final song in visible) {
        entries.add(songEntry(song));
      }
    }
  }
  return entries;
}

String _albumGroupKey(LibrarySong song) => foldLibraryText(
  '${song.track.albumName}|${song.track.albumArtist ?? song.track.artistName}',
);

/// Whether [filter] also lists albums paged from the database. The mixed
/// list holds only the fixed shortcuts and the playlists, never albums.
bool libraryFilterListsAlbums(LibraryHomeFilter filter) =>
    filter == LibraryHomeFilter.albums ||
    filter == LibraryHomeFilter.downloaded;

/// The database order closest to [sort] for albums and scanned artists.
String libraryBrowseSortFor(LibraryHomeSort sort) => switch (sort) {
  LibraryHomeSort.recent || LibraryHomeSort.recentlyAdded => 'latest',
  LibraryHomeSort.alphabetical ||
  LibraryHomeSort.creator ||
  LibraryHomeSort.album => 'a-z',
};
