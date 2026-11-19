import 'package:flutter/widgets.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_home.dart';

/// Wording of the library home and its "+" action, taken from the app
/// localizations so it follows the language of the device or of the app.
class LibraryHomeStrings {
  const LibraryHomeStrings._(this._l);

  factory LibraryHomeStrings.of(BuildContext context) =>
      LibraryHomeStrings._(context.l10n);

  final AppLocalizations _l;

  String get title => _l.libraryHomeTitle;
  String get addToLibrary => _l.libraryHomeAddToLibrary;
  String get removeFromLibrary => _l.libraryHomeRemoveFromLibrary;
  String get inLibrary => _l.libraryHomeInLibrary;
  String get favorite => _l.libraryHomeFavorite;
  String get unfavorite => _l.libraryHomeUnfavorite;
  String get create => _l.libraryHomeCreate;
  String get clearFilter => _l.libraryHomeClearFilter;
  String get sortBy => _l.libraryHomeSortBy;
  String get changeView => _l.libraryHomeChangeView;
  String get favorites => _l.libraryHomeFavorites;
  String get allSongs => _l.libraryHomeSongs;
  String get downloaded => _l.libraryHomeDownloaded;
  String get pinned => _l.libraryHomePinned;
  String get pin => _l.libraryHomePin;
  String get unpin => _l.libraryHomeUnpin;
  String get pinError => _l.libraryHomePinError;
  String get open => _l.libraryHomeOpen;
  String get options => _l.libraryHomeOptions;
  String get onDevice => _l.libraryHomeOnDevice;
  String get emptyTitle => _l.libraryHomeEmptyTitle;
  String get emptyHint => _l.libraryHomeEmptyHint;
  String get localEmptyHint => _l.libraryLocalEmptyHint;
  String get localEmptyAction => _l.libraryLocalEmptyAction;
  String get emptyFavorites => _l.libraryHomeEmptyFavorites;
  String get emptyPlaylists => _l.libraryHomeEmptyPlaylists;
  String get emptyFiltered => _l.libraryHomeEmptyFiltered;
  String noResults(String query) => _l.libraryHomeNoResults(query);

  String filter(LibraryHomeFilter filter) => switch (filter) {
    LibraryHomeFilter.all => _l.libraryHomeFilterAll,
    LibraryHomeFilter.songs => _l.libraryHomeSongs,
    LibraryHomeFilter.albums => _l.libraryHomeFilterAlbums,
    LibraryHomeFilter.artists => _l.libraryHomeFilterArtists,
    LibraryHomeFilter.playlists => _l.libraryHomeFilterPlaylists,
    LibraryHomeFilter.downloaded => _l.libraryHomeDownloaded,
    LibraryHomeFilter.favorites => _l.libraryHomeFavorites,
  };

  String sort(LibraryHomeSort sort) => switch (sort) {
    LibraryHomeSort.recent => _l.libraryHomeSortRecent,
    LibraryHomeSort.recentlyAdded => _l.libraryHomeSortRecentlyAdded,
    LibraryHomeSort.alphabetical => _l.libraryHomeSortAlphabetical,
    LibraryHomeSort.creator => _l.libraryHomeSortCreator,
    LibraryHomeSort.album => _l.libraryHomeSortAlbum,
  };

  String view(LibraryHomeView view) => switch (view) {
    LibraryHomeView.compact => _l.libraryHomeViewCompact,
    LibraryHomeView.list => _l.libraryHomeViewList,
    LibraryHomeView.grid => _l.libraryHomeViewGrid,
  };

  String songs(int count) => _l.libraryHomeSongCount(count);
  String get playlistKind => _l.libraryHomePlaylistKind;
  String get albumKind => _l.libraryHomeAlbumKind;
  String get artistKind => _l.libraryHomeArtistKind;
}
