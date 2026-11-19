import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/widgets/storage_access_widgets.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_counts_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/library_playlist_order_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/artist_screen.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/listening_rewind_screen.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/library_settings_page.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/nav_bar_inset.dart';
import 'package:mornye/widgets/addons_reminder_card.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/app_refresh_indicator.dart';
import 'package:mornye/widgets/app_search_field.dart';
import 'package:mornye/widgets/app_sliver_header.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:mornye/widgets/library_browse_artwork.dart';
import 'package:mornye/widgets/library_home_strings.dart';
import 'package:mornye/widgets/library_home_widgets.dart';
import 'package:mornye/widgets/library_search_results.dart';
import 'package:mornye/widgets/open_audio_button.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/providers/keep_downloaded_provider.dart';
import 'package:mornye/widgets/downloaded_format_mark.dart';
import 'package:mornye/widgets/keep_downloaded_switch.dart';
import 'package:mornye/widgets/playlist_cover_collage.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';

/// "Your library": one searchable, filterable list of everything the listener
/// keeps. Favorites and downloads are fixed shortcuts and filters over it,
/// never folders nested inside the song list.
class LibraryHomeScreen extends ConsumerStatefulWidget {
  const LibraryHomeScreen({
    super.key,
    required this.onOpenSection,
    required this.onOpenAlbum,
    required this.onPlayAlbum,
    required this.onOpenArtistAlbums,
    this.initialFilter = LibraryHomeFilter.all,
  });

  /// Opens a section page: `all` lists the files already on the device.
  final ValueChanged<String> onOpenSection;
  final ValueChanged<LibraryBrowseEntry> onOpenAlbum;
  final ValueChanged<LibraryBrowseEntry> onPlayAlbum;
  final ValueChanged<String> onOpenArtistAlbums;
  final LibraryHomeFilter initialFilter;

  @override
  ConsumerState<LibraryHomeScreen> createState() => _LibraryHomeScreenState();
}

class _LibraryHomeScreenState extends ConsumerState<LibraryHomeScreen> {
  static const _pageSize = 40;

  final _scroll = ScrollController();
  final _search = TextEditingController();
  Timer? _debounce;
  bool _showSearch = false;
  String _query = '';
  late LibraryHomeFilter _filter = widget.initialFilter;
  LibraryBrowseRequest? _activeBrowse;
  final _historySnapshot = TrackHistorySnapshot();
  Set<String> _downloadedSongKeys = const <String>{};

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_maybeLoadMore);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    final request = _activeBrowse;
    if (request == null || _scroll.position.extentAfter > 500) return;
    unawaited(ref.read(libraryBrowseProvider(request).notifier).loadMore());
  }

  void _searchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted || _query == value.trim()) return;
      setState(() => _query = value.trim());
    });
  }

  void _setFilter(LibraryHomeFilter filter) {
    if (filter == _filter) return;
    setState(() => _filter = filter);
    if (_scroll.hasClients && _scroll.offset > 0) _scroll.jumpTo(0);
  }

  LibraryBrowseRequest _browse({required bool artists, required String sort}) =>
      (
        artists: artists,
        artist: null,
        search: _query,
        sort: sort,
        limit: _pageSize,
        completeness: null,
      );

  Future<void> _playSongs(List<LibrarySong> songs, int index) async {
    try {
      final playback = ref.read(playbackProvider.notifier);
      if (index >= 0 &&
          index < songs.length &&
          await playback.openPlayerIfCurrent(track: songs[index].track)) {
        return;
      }
      await playback.playTrackList([
        for (final song in songs) song.track,
      ], startIndex: index);
    } catch (error) {
      if (mounted) showCannotOpenFileSnackBar(context, error);
    }
  }

  /// Songs whose favorite toggle is still saving: a double tap must not flip
  /// the star twice.
  final Set<String> _favoriteBusy = <String>{};

  Future<void> _toggleFavorite(LibrarySong song) async {
    if (!_favoriteBusy.add(song.key)) return;
    try {
      await ref.read(libraryMembershipProvider).toggleFavorite(song.track);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.snackbarError(context.friendlyError(error)),
          ),
        ),
      );
    } finally {
      _favoriteBusy.remove(song.key);
    }
  }

  Future<void> _togglePin(String playlistId) async {
    try {
      await ref
          .read(libraryPlaylistOrderProvider.notifier)
          .togglePin(playlistId);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(LibraryHomeStrings.of(context).pinError)),
      );
    }
  }

  void _openEntry(LibraryHomeEntry entry, List<LibrarySong> visibleSongs) {
    switch (entry.kind) {
      case LibraryHomeEntryKind.pinnedFavorites:
        pushPage<void>(
          context,
          (_) => const LibraryTracksFolderScreen(
            mode: LibraryTracksFolderMode.loved,
          ),
        );
      case LibraryHomeEntryKind.pinnedSongs:
        _setFilter(LibraryHomeFilter.songs);
      case LibraryHomeEntryKind.pinnedDownloaded:
        widget.onOpenSection('all');
      case LibraryHomeEntryKind.playlist:
        pushPage<void>(
          context,
          (_) => LibraryTracksFolderScreen(
            mode: LibraryTracksFolderMode.playlist,
            playlistId: entry.playlist!.id,
          ),
        );
      case LibraryHomeEntryKind.artist:
        final artist = entry.artist!;
        Navigator.of(context).push(
          slidePageRoute<void>(
            page: ArtistScreen(
              artistId: artist.artistId,
              artistName: artist.name,
              coverUrl: artist.imageUrl,
              extensionId: artist.providerId?.isNotEmpty == true
                  ? artist.providerId
                  : null,
            ),
          ),
        );
      case LibraryHomeEntryKind.albumHeader:
        break;
      case LibraryHomeEntryKind.song:
        final index = visibleSongs.indexWhere(
          (song) => song.key == entry.song!.key,
        );
        unawaited(_playSongs(visibleSongs, index < 0 ? 0 : index));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strings = LibraryHomeStrings.of(context);
    final inset = 16 + wideListInset(context);
    final preferences = ref.watch(libraryHomePreferencesProvider);
    final searching = _query.isNotEmpty;
    final localLibraryEnabled = ref.watch(
      settingsProvider.select((s) => s.localLibraryEnabled),
    );
    final downloadedCount =
        ref
            .watch(
              libraryCountsProvider(
                LibraryCountsRequest.all(
                  localLibraryEnabled: localLibraryEnabled,
                ),
              ),
            )
            .value
            ?.allTrackCount ??
        0;
    final localOnly = ref.watch(localOnlyModeProvider);
    final songsLoaded = ref.watch(librarySongsLoadedProvider);
    var entries = ref.watch(
      libraryHomeEntriesProvider((
        filter: _filter,
        sort: preferences.sort,
        query: _query,
        downloadedCount: downloadedCount,
      )),
    );
    if (localOnly) {
      entries = [
        for (final entry in entries)
          if (entry.kind != LibraryHomeEntryKind.pinnedDownloaded) entry,
      ];
      if (songsLoaded &&
          _filter == LibraryHomeFilter.all &&
          entries.every(
            (entry) => entry.isShortcut && (entry.count ?? 0) == 0,
          )) {
        entries = const <LibraryHomeEntry>[];
      }
    }

    // Albums and scanned artists are paged from the database. A search over
    // everything delegates device files to the shared search results instead.
    final searchAll = searching && _filter == LibraryHomeFilter.all;
    final browseSort = libraryBrowseSortFor(preferences.sort);
    final albumRequest = libraryFilterListsAlbums(_filter) && !searchAll
        ? _browse(artists: false, sort: browseSort)
        : null;
    final artistRequest = _filter == LibraryHomeFilter.artists
        ? _browse(artists: true, sort: browseSort)
        : null;
    final browseRequest = albumRequest ?? artistRequest;
    _activeBrowse = browseRequest;
    final browse = browseRequest == null
        ? null
        : ref.watch(libraryBrowseProvider(browseRequest));
    final browseRows = browse?.value?.entries ?? const <LibraryBrowseEntry>[];
    final browseLoading =
        browse != null &&
        (browse.isLoading || (browse.value?.isLoadingMore ?? false));
    final browseFailed =
        browse != null &&
        (browse.hasError || browse.value?.loadMoreError != null);

    final visibleSongs = [
      for (final entry in entries)
        if (entry.song case final song?) song,
    ];
    _historySnapshot.update([for (final song in visibleSongs) song.track]);
    final historyKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    ref.watch(localLibraryProvider.select((state) => state.loadedIndexVersion));
    final localLibrary = ref.read(localLibraryProvider);
    final lookupKeys = _historySnapshot.lookupKeys;
    _downloadedSongKeys = {
      for (var i = 0; i < visibleSongs.length; i++)
        if (historyKeys.contains(lookupKeys[i]) ||
            localLibrary.existsInLibrary(
              isrc: visibleSongs[i].track.isrc,
              trackName: visibleSongs[i].track.name,
              artistName: visibleSongs[i].track.artistName,
            ))
          visibleSongs[i].key,
    };
    final listsSongs =
        _filter == LibraryHomeFilter.songs ||
        _filter == LibraryHomeFilter.favorites;
    final loadingFirst =
        (listsSongs && !songsLoaded && entries.isEmpty) ||
        (browseLoading && browseRows.isEmpty && entries.isEmpty);
    final total = entries.length + browseRows.length;
    final view = preferences.view;
    final onlyShortcuts =
        entries.isNotEmpty &&
        browseRows.isEmpty &&
        entries.every((entry) => entry.isShortcut);

    Widget itemAt(BuildContext context, int index, {required bool grid}) {
      if (index < entries.length) {
        return _entry(
          context,
          entries[index],
          visibleSongs,
          view: view,
          grid: grid,
          inset: inset,
        );
      }
      return _browseEntry(
        context,
        browseRows[index - entries.length],
        artists: artistRequest != null,
        view: view,
        grid: grid,
        inset: inset,
      );
    }

    return PopScope(
      canPop: _filter == LibraryHomeFilter.all,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _setFilter(LibraryHomeFilter.all);
      },
      child: AppRefreshIndicator(
      onRefresh: () async {
        if (browseRequest == null) return;
        ref.invalidate(libraryBrowseProvider(browseRequest));
        try {
          await ref.read(libraryBrowseProvider(browseRequest).future);
        } catch (_) {
          // The retry row reports the failure.
        }
      },
      child: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          AppSliverHeader.tabRoot(
            title: strings.title,
            alignToContent: true,
            actions: [
              IconButton(
                tooltip: context.l10n.librarySearchHint,
                icon: const Icon(Icons.search),
                onPressed: () => setState(() => _showSearch = !_showSearch),
              ),
              if (!localOnly)
                IconButton(
                  key: const ValueKey('library_import'),
                  tooltip: strings.create,
                  icon: const Icon(Icons.add),
                  onPressed: () => showCreatePlaylistSheet(context, ref),
                ),
              if (localOnly && context.isMornye) const HomeProfileButton(),
            ],
          ),
          if (_showSearch)
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(inset, 4, inset, 8),
                child: AppSearchField(
                  controller: _search,
                  autofocus: true,
                  hintText: context.l10n.librarySearchHint,
                  clearTooltip: context.l10n.dialogClear,
                  samplesBackdrop: false,
                  onChanged: _searchChanged,
                  onClear: () {
                    _search.clear();
                    _searchChanged('');
                  },
                ),
              ),
            ),
          if (Platform.isAndroid)
            const SliverToBoxAdapter(child: PrivateStorageBanner()),
          SliverPersistentHeader(
            pinned: true,
            delegate: LibraryChipsHeaderDelegate(
              selected: _filter,
              onSelected: _setFilter,
              background: theme.scaffoldBackgroundColor,
              horizontalPadding: inset,
              includeDownloaded: !localOnly,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: inset - 8),
              child: LibrarySortBar(
                sort: preferences.sort,
                view: view,
                onSort: (sort) => ref
                    .read(libraryHomePreferencesProvider.notifier)
                    .setSort(sort),
                onView: (next) => ref
                    .read(libraryHomePreferencesProvider.notifier)
                    .setView(next),
                trailing: const OpenAudioButton(),
              ),
            ),
          ),
          if (_filter == LibraryHomeFilter.all && !searching)
            SliverToBoxAdapter(
              child: AddonsReminderCard(
                margin: EdgeInsets.fromLTRB(inset, 0, inset, 12),
                onEnterCode: () => pushPage<void>(
                  context,
                  (_) => const ExtensionsPage(),
                ),
              ),
            ),
          if (_filter == LibraryHomeFilter.songs && !searching && !localOnly)
            SliverToBoxAdapter(
              child: KeepDownloadedSwitch(
                scope: keepLibraryScope,
                padding: EdgeInsets.symmetric(horizontal: inset),
              ),
            ),
          if (_filter == LibraryHomeFilter.all &&
              !searching &&
              !localOnly &&
              ref.watch(
                settingsProvider.select((s) => s.listeningStatisticsEnabled),
              ))
            SliverToBoxAdapter(
              child: ListeningRewindBanner(
                margin: EdgeInsets.fromLTRB(inset, 0, inset, 12),
              ),
            ),
          if (total > 0)
            if (view == LibraryHomeView.grid)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 190,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 12,
                    mainAxisExtent:
                        190 + MediaQuery.textScalerOf(context).scale(14) * 3.2,
                  ),
                  itemCount: total,
                  itemBuilder: (context, index) =>
                      itemAt(context, index, grid: true),
                ),
              )
            else
              SliverList.builder(
                itemCount: total,
                itemBuilder: (context, index) =>
                    itemAt(context, index, grid: false),
              ),
          if (searchAll)
            LibrarySearchResults(
              query: _query,
              onOpenArtist: widget.onOpenArtistAlbums,
            ),
          if (browseFailed)
            SliverToBoxAdapter(
              child: Center(
                child: TextButton.icon(
                  onPressed: () =>
                      ref.invalidate(libraryBrowseProvider(browseRequest!)),
                  icon: const Icon(Icons.refresh),
                  label: Text(context.l10n.dialogRetry),
                ),
              ),
            )
          else if (loadingFirst)
            LibraryHomeSkeleton(horizontalPadding: inset)
          else if (browseLoading)
            LibraryHomeSkeleton(rows: 2, horizontalPadding: inset)
          else if (!searchAll && (total == 0 || onlyShortcuts))
            SliverToBoxAdapter(
              child: _emptyState(strings, total == 0, localOnly),
            ),
          const NavBarSliverSpacer(),
        ],
      ),
    ));
  }

  void _chooseMusicFolders() {
    ref.read(settingsProvider.notifier).setLocalLibraryEnabled(true);
    pushPage<void>(context, (_) => const LibrarySettingsPage());
  }

  Widget _emptyState(LibraryHomeStrings strings, bool nothing, bool localOnly) {
    if (_query.isNotEmpty) {
      return LibraryHomeEmptyState(
        icon: Icons.search_off,
        title: strings.noResults(_query),
      );
    }
    return switch (_filter) {
      LibraryHomeFilter.favorites => LibraryHomeEmptyState(
        icon: CupertinoIcons.star,
        title: strings.emptyFiltered,
        hint: strings.emptyFavorites,
      ),
      LibraryHomeFilter.playlists => LibraryHomeEmptyState(
        icon: Icons.queue_music,
        title: strings.emptyFiltered,
        hint: strings.emptyPlaylists,
      ),
      LibraryHomeFilter.albums ||
      LibraryHomeFilter.artists ||
      LibraryHomeFilter.downloaded => LibraryHomeEmptyState(
        icon: Icons.library_music_outlined,
        title: strings.emptyFiltered,
        hint: context.l10n.libraryEmptyCollection,
      ),
      _ when localOnly => LibraryHomeEmptyState(
        icon: Icons.library_music_outlined,
        title: strings.emptyTitle,
        hint: strings.localEmptyHint,
        actionLabel: strings.localEmptyAction,
        onAction: _chooseMusicFolders,
      ),
      _ => LibraryHomeEmptyState(
        icon: Icons.add_circle_outline,
        title: strings.emptyTitle,
        hint: strings.emptyHint,
      ),
    };
  }

  Widget _entry(
    BuildContext context,
    LibraryHomeEntry entry,
    List<LibrarySong> visibleSongs, {
    required LibraryHomeView view,
    required bool grid,
    required double inset,
  }) {
    final colors = Theme.of(context).colorScheme;
    final strings = LibraryHomeStrings.of(context);
    void open() => _openEntry(entry, visibleSongs);
    final count = entry.count ?? 0;
    final (
      String title,
      String subtitle,
      Widget artwork,
    ) = switch (entry.kind) {
      LibraryHomeEntryKind.pinnedFavorites => (
        strings.favorites,
        strings.songs(count),
        LibraryShortcutArtwork(
          icon: CupertinoIcons.star_fill,
          background: colors.primary,
          foreground: colors.onPrimary,
        ),
      ),
      LibraryHomeEntryKind.pinnedSongs => (
        strings.allSongs,
        strings.songs(count),
        LibraryShortcutArtwork(
          icon: Icons.library_music,
          background: colors.secondaryContainer,
          foreground: colors.onSecondaryContainer,
        ),
      ),
      LibraryHomeEntryKind.pinnedDownloaded => (
        strings.downloaded,
        '${strings.songs(count)} · ${strings.onDevice}',
        LibraryShortcutArtwork(
          icon: CupertinoIcons.arrow_down_circle_fill,
          background: colors.tertiaryContainer,
          foreground: colors.onTertiaryContainer,
        ),
      ),
      LibraryHomeEntryKind.playlist => (
        entry.title,
        '${strings.playlistKind} · ${strings.songs(count)}',
        _PlaylistArtwork(playlist: entry.playlist!),
      ),
      LibraryHomeEntryKind.artist => (
        entry.title,
        strings.artistKind,
        _coverOrIcon(context, entry.artist!.imageUrl, Icons.person),
      ),
      LibraryHomeEntryKind.albumHeader => (
        entry.title,
        '${strings.albumKind} � ${entry.creator} � ${strings.songs(count)}',
        _coverOrIcon(context, entry.song!.track.coverUrl, Icons.album_outlined),
      ),
      LibraryHomeEntryKind.song => (
        entry.title,
        entry.creator,
        _coverOrIcon(context, entry.song!.track.coverUrl, Icons.music_note),
      ),
    };
    final circular = entry.kind == LibraryHomeEntryKind.artist;
    final key = ValueKey('library-entry-${entry.id}');
    if (grid) {
      return LibraryEntryCell(
        key: key,
        artwork: artwork,
        title: title,
        subtitle: subtitle,
        circular: circular,
        onTap: open,
        onLongPress: entry.playlist == null
            ? null
            : () => _togglePin(entry.playlist!.id),
      );
    }
    final compact = view == LibraryHomeView.compact;
    Widget? trailing;
    if (entry.song case final song?) {
      final downloaded = _downloadedSongKeys.contains(song.key);
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!compact)
            IconButton(
              key: ValueKey('library-favorite-${song.key}'),
              tooltip: song.favorite ? strings.unfavorite : strings.favorite,
              icon: Icon(
                song.favorite ? CupertinoIcons.star_fill : CupertinoIcons.star,
                size: 20,
                color: song.favorite ? colors.primary : colors.onSurfaceVariant,
              ),
              onPressed: () => _toggleFavorite(song),
            ),
          if (!compact)
            SizedBox(
              width: downloadedFormatMarkWidth,
              child: downloaded
                  ? DownloadedFormatMark(
                      key: ValueKey('library-downloaded-${song.key}'),
                      track: song.track,
                    )
                  : null,
            ),
          TrackCollectionQuickActions(
            track: song.track,
            hasLocalPlaybackCandidate: downloaded,
          ),
        ],
      );
    } else if (entry.playlist case final playlist?) {
      trailing = PopupMenuButton<String>(
        key: ValueKey('library-menu-${entry.id}'),
        tooltip: strings.options,
        icon: const Icon(Icons.more_vert),
        onSelected: (action) =>
            action == 'pin' ? _togglePin(playlist.id) : open(),
        itemBuilder: (context) => [
          PopupMenuItem(value: 'open', child: Text(strings.open)),
          PopupMenuItem(
            value: 'pin',
            child: Text(entry.pinned ? strings.unpin : strings.pin),
          ),
        ],
      );
    } else if (entry.isShortcut) {
      trailing = Padding(
        padding: const EdgeInsetsDirectional.only(end: 12),
        child: Icon(Icons.chevron_right, color: colors.onSurfaceVariant),
      );
    }
    return LibraryEntryTile(
      key: key,
      artwork: artwork,
      title: title,
      subtitle: subtitle,
      compact: compact,
      circular: circular,
      pinned: entry.pinned,
      trailing: trailing,
      horizontalPadding: inset,
      onTap: open,
    );
  }

  Widget _browseEntry(
    BuildContext context,
    LibraryBrowseEntry entry, {
    required bool artists,
    required LibraryHomeView view,
    required bool grid,
    required double inset,
  }) {
    final strings = LibraryHomeStrings.of(context);
    void open() => artists
        ? widget.onOpenArtistAlbums(entry.artist)
        : widget.onOpenAlbum(entry);
    final title = artists ? entry.artist : entry.name;
    final subtitle = artists
        ? '${strings.artistKind} · ${strings.songs(entry.trackCount)}'
        : '${strings.albumKind} · ${entry.artist}';
    final artwork = LibraryBrowseArtwork(
      entry: entry,
      placeholderIcon: artists ? Icons.person : Icons.album_outlined,
      placeholderSize: grid ? 40 : 24,
    );
    final key = ValueKey(
      'library-${artists ? 'artist' : 'album'}-${entry.source}-${entry.key}',
    );
    if (grid) {
      return LibraryEntryCell(
        key: key,
        artwork: artwork,
        title: title,
        subtitle: subtitle,
        circular: artists,
        onTap: open,
        onLongPress: artists ? null : () => widget.onPlayAlbum(entry),
      );
    }
    return LibraryEntryTile(
      key: key,
      artwork: artwork,
      title: title,
      subtitle: subtitle,
      compact: view == LibraryHomeView.compact,
      circular: artists,
      horizontalPadding: inset,
      onTap: open,
      trailing: artists
          ? null
          : PopupMenuButton<String>(
              tooltip: strings.options,
              icon: const Icon(Icons.more_vert),
              onSelected: (action) =>
                  action == 'play' ? widget.onPlayAlbum(entry) : open(),
              itemBuilder: (context) => [
                PopupMenuItem(value: 'open', child: Text(strings.open)),
                PopupMenuItem(
                  value: 'play',
                  child: Text(context.l10n.tooltipPlay),
                ),
              ],
            ),
    );
  }
}

Widget _coverOrIcon(BuildContext context, String? url, IconData icon) {
  final colors = Theme.of(context).colorScheme;
  Widget fallback(BuildContext context) => ColoredBox(
    color: colors.surfaceContainerHighest,
    child: Center(child: Icon(icon, color: colors.onSurfaceVariant)),
  );
  if (url == null || url.trim().isEmpty) return fallback(context);
  return LocalOrNetworkCoverImage(url: url, placeholder: fallback);
}

class _PlaylistArtwork extends StatelessWidget {
  const _PlaylistArtwork({required this.playlist});

  final UserPlaylistCollection playlist;

  @override
  Widget build(BuildContext context) {
    final sources = ownPlaylistCollageSources(
      playlist.coverImagePath,
      playlist.tracks,
    );
    if (sources.isNotEmpty) return PlaylistCoverCollage(sources: sources);
    return _coverOrIcon(
      context,
      playlist.coverImagePath ?? playlist.previewCover,
      Icons.queue_music,
    );
  }
}
