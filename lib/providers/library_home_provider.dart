import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/models/library_home.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

export 'package:mornye/models/library_home.dart';

/// The order and layout the listener last chose for the library home.
class LibraryHomePreferences {
  const LibraryHomePreferences({
    this.sort = LibraryHomeSort.recent,
    this.view = LibraryHomeView.list,
  });

  final LibraryHomeSort sort;
  final LibraryHomeView view;

  LibraryHomePreferences copyWith({
    LibraryHomeSort? sort,
    LibraryHomeView? view,
  }) =>
      LibraryHomePreferences(sort: sort ?? this.sort, view: view ?? this.view);
}

T _byName<T extends Enum>(List<T> values, String? name, T fallback) {
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}

class LibraryHomePreferencesNotifier extends Notifier<LibraryHomePreferences> {
  static const sortKey = 'library_home_sort_v1';
  static const viewKey = 'library_home_view_v1';

  @override
  LibraryHomePreferences build() {
    _restore();
    return const LibraryHomePreferences();
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = LibraryHomePreferences(
        sort: _byName(
          LibraryHomeSort.values,
          prefs.getString(sortKey),
          state.sort,
        ),
        view: _byName(
          LibraryHomeView.values,
          prefs.getString(viewKey),
          state.view,
        ),
      );
    } catch (_) {
      // The defaults stay in place when preferences cannot be read.
    }
  }

  Future<void> setSort(LibraryHomeSort sort) async {
    if (sort == state.sort) return;
    state = state.copyWith(sort: sort);
    await _store(sortKey, sort.name);
  }

  Future<void> setView(LibraryHomeView view) async {
    if (view == state.view) return;
    state = state.copyWith(view: view);
    await _store(viewKey, view.name);
  }

  Future<void> _store(String key, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(key, value);
    } catch (_) {
      // The choice still applies to this session.
    }
  }
}

final libraryHomePreferencesProvider =
    NotifierProvider<LibraryHomePreferencesNotifier, LibraryHomePreferences>(
      LibraryHomePreferencesNotifier.new,
    );

/// Every song of the library: added with "+" or starred. Recomputed only when
/// one of the two stored lists changes.
final librarySongsProvider = Provider<List<LibrarySong>>((ref) {
  final saved = ref.watch(savedLibraryTracksProvider).value ?? const <Track>[];
  final favorites = ref.watch(
    libraryCollectionsProvider.select((state) => state.loved),
  );
  return mergeLibrarySongs(saved: saved, favorites: favorites);
});

/// False until both stored lists have been read once.
final librarySongsLoadedProvider = Provider<bool>((ref) {
  final saved = ref.watch(savedLibraryTracksProvider);
  final collections = ref.watch(
    libraryCollectionsProvider.select((state) => state.isLoaded),
  );
  return collections && !saved.isLoading;
});

final libraryFavoriteCountProvider = Provider<int>(
  (ref) =>
      ref.watch(libraryCollectionsProvider.select((state) => state.lovedCount)),
);

/// Keys of every library song, for "is this in my library" checks.
final librarySongKeysProvider = Provider<Set<String>>(
  (ref) => {for (final song in ref.watch(librarySongsProvider)) song.key},
);

typedef LibraryHomeQuery = ({
  LibraryHomeFilter filter,
  LibraryHomeSort sort,
  String query,
  int downloadedCount,
});

/// The in-memory rows for one filter, order and search. Sorting and filtering
/// happen here, once per change, never while a frame is being built.
final libraryHomeEntriesProvider = Provider.autoDispose
    .family<List<LibraryHomeEntry>, LibraryHomeQuery>((ref, request) {
      final songs = ref.watch(librarySongsProvider);
      final playlists = ref.watch(
        libraryCollectionsProvider.select((state) => state.playlists),
      );
      final artists = ref.watch(
        libraryCollectionsProvider.select((state) => state.favoriteArtists),
      );
      final order =
          ref.watch(libraryPlaylistOrderProvider).value ??
          const LibraryPlaylistOrder();
      return buildLibraryHomeEntries(
        filter: request.filter,
        sort: request.sort,
        query: request.query,
        songs: songs,
        playlists: playlists,
        favoriteArtists: artists,
        pinnedPlaylists: order.pinned,
        playedPlaylists: order.played,
        downloadedCount: request.downloadedCount,
      );
    });

enum LibraryMembershipChange {
  added,
  removed,
  favorited,
  unfavorited,
  unchanged,
}

/// The two actions of the player and menus: "+" (library) and star (favorite).
class LibraryMembershipController {
  LibraryMembershipController(this._ref);

  final Ref _ref;

  bool isInLibrary(Track track) =>
      _ref.read(librarySongKeysProvider).contains(trackCollectionKey(track));

  bool isFavorite(Track track) =>
      _ref.read(libraryCollectionsProvider).isLoved(track);

  /// "+": adds the song, or removes it together with its star, because a
  /// favorite cannot live outside the library.
  Future<LibraryMembershipChange> toggleLibrary(Track track) async {
    final saved = _ref.read(savedLibraryTracksProvider.notifier);
    final collections = _ref.read(libraryCollectionsProvider.notifier);
    if (isInLibrary(track)) {
      final starred = isFavorite(track);
      await saved.remove(track);
      if (starred) {
        await collections.dropLovedTracks([trackCollectionKey(track)]);
      }
      return LibraryMembershipChange.removed;
    }
    final result = await saved.addWithRetention(track);
    return result.added || isInLibrary(track)
        ? LibraryMembershipChange.added
        : LibraryMembershipChange.unchanged;
  }

  /// Star: marking it adds the song to the library; clearing it keeps it.
  Future<LibraryMembershipChange> toggleFavorite(Track track) async {
    final favorite = await _ref
        .read(libraryCollectionsProvider.notifier)
        .toggleLoved(track);
    return favorite
        ? LibraryMembershipChange.favorited
        : LibraryMembershipChange.unfavorited;
  }
}

final libraryMembershipProvider = Provider<LibraryMembershipController>(
  LibraryMembershipController.new,
);
