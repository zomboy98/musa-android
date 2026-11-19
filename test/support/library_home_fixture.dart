import 'dart:convert';

import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixed_settings.dart';

Track libraryTrack(String id, {String? name, String artist = 'Artist'}) =>
    Track(
      id: id,
      name: name ?? 'Song $id',
      artistName: artist,
      albumName: 'Album',
      duration: 180,
      source: 'catalog',
    );

CollectionTrackEntry favoriteEntry(Track track) => CollectionTrackEntry(
  key: trackCollectionKey(track),
  track: track,
  addedAt: DateTime(2026),
);

/// Collections held in memory. Starring follows the real rule: the song is
/// kept in the library through [favoriteLibrarySyncProvider].
class MemoryCollections extends LibraryCollectionsNotifier {
  MemoryCollections(this.initial);

  final LibraryCollectionsState initial;

  @override
  LibraryCollectionsState build() => initial;

  @override
  Future<bool> toggleLoved(Track track) async {
    final key = trackCollectionKey(track);
    await ref.read(favoriteLibrarySyncProvider)([track]);
    if (state.containsLovedKey(key)) {
      state = state.copyWith(
        loved: state.loved.where((entry) => entry.key != key).toList(),
      );
      return false;
    }
    state = state.copyWith(loved: [favoriteEntry(track), ...state.loved]);
    return true;
  }

  @override
  Future<int> dropLovedTracks(Iterable<String> trackKeys) async {
    final keys = trackKeys.toSet();
    final next = state.loved.where((e) => !keys.contains(e.key)).toList();
    final removed = state.loved.length - next.length;
    if (removed > 0) state = state.copyWith(loved: next);
    return removed;
  }
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

/// Stores [saved] as the "+" references the app reads at startup.
void seedSavedTracks(List<Track> saved) {
  SharedPreferences.setMockInitialValues({
    if (saved.isNotEmpty)
      SavedLibraryTracksNotifier.storageKey: jsonEncode([
        for (final track in saved) track.toJson(),
      ]),
  });
}

/// Overrides that keep the library home off the database and the network.
List<Override> libraryHomeOverrides({
  List<CollectionTrackEntry> favorites = const [],
  List<UserPlaylistCollection> playlists = const [],
  List<CollectionArtistEntry> favoriteArtists = const [],
  List<LibraryBrowseEntry> albums = const [],
  int downloadedCount = 0,
  List<LibraryBrowseRequest>? browseRequests,
  List<LibrarySearchRequest>? searches,
  LibraryCollectionsNotifier Function(LibraryCollectionsState initial)?
  collections,
  DownloadHistoryNotifier Function()? history,
}) => [
  settingsProvider.overrideWith(
    () => FixedSettingsNotifier(
      const AppSettings(
        localLibraryEnabled: false,
        listeningStatisticsEnabled: false,
      ),
    ),
  ),
  downloadHistoryProvider.overrideWith(history ?? _History.new),
  libraryCollectionsProvider.overrideWith(
    () => (collections ?? MemoryCollections.new)(
      LibraryCollectionsState(
        loved: favorites,
        playlists: playlists,
        favoriteArtists: favoriteArtists,
        isLoaded: true,
      ),
    ),
  ),
  libraryCountsProvider.overrideWith(
    (ref, request) async => QueueLibraryCounts(
      allTrackCount: downloadedCount,
      albumCount: albums.length,
      singleTrackCount: 0,
    ),
  ),
  libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
    browseRequests?.add(page.browse);
    if (page.offset > 0) return const LibraryBrowsePage([]);
    final query = page.browse.search.toLowerCase();
    return LibraryBrowsePage([
      for (final album in albums)
        if (album.name.toLowerCase().contains(query)) album,
    ]);
  }),
  librarySearchProvider.overrideWith((ref, request) async {
    searches?.add(request);
    return [];
  }),
  promoteSavedCatalogAudioProvider.overrideWithValue((_) async => false),
  pendingSavedCatalogPromotionProvider.overrideWithValue((_) => null),
  savedCatalogRetentionLockProvider.overrideWithValue(
    <T>(Future<T> Function() action) => action(),
  ),
];

LibraryBrowseEntry libraryAlbum(String name, {String artist = 'Artist'}) =>
    LibraryBrowseEntry(
      source: 'downloaded',
      key: 'album-$name',
      name: name,
      artist: artist,
      samplePath: '',
      trackCount: 3,
    );
