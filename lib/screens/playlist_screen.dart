import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:mornye/controllers/track_history_snapshot.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/collection_header_actions.dart';
import 'package:mornye/controllers/selection_mode_mixin.dart';
import 'package:mornye/widgets/collection_scaffold.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/utils/image_cache_utils.dart';
import 'package:mornye/utils/cover_art_utils.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/utils/provider_resource_ids.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/animation_utils.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/shuffle_mode_window.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:mornye/widgets/cover_collage_backdrop.dart';
import 'package:mornye/widgets/playlist_cover_collage.dart';
import 'package:mornye/widgets/playlist_batch_download_status.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:mornye/controllers/collapsing_header_scroll_mixin.dart';
import 'package:mornye/widgets/error_card.dart';
import 'package:mornye/widgets/collection_suggestions_section.dart';
import 'package:mornye/widgets/downloadable_cover.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_artist_header.dart';

String? resolveOriginalCollectionProvider(
  String providerId,
  ExtensionState state,
) {
  return state.extensions
      .where(
        (extension) =>
            extension.enabled &&
            extension.id.toLowerCase() == providerId.toLowerCase() &&
            (extension.hasMetadataProvider ||
                extension.id.toLowerCase() == 'deezer'),
      )
      .firstOrNull
      ?.id;
}

/// Stable identity for each occurrence while distinct tracks move around it.
/// Identical occurrences have no persistent entry ID, so their ordinal is the
/// only available distinction.
List<ValueKey<(String, String, int)>> playlistOccurrenceKeys(
  List<Track> tracks,
) {
  final counts = <(String, String), int>{};
  return [
    for (final track in tracks)
      () {
        final identity = (track.source ?? '', track.id);
        final ordinal = counts.update(
          identity,
          (value) => value + 1,
          ifAbsent: () => 0,
        );
        return ValueKey((identity.$1, identity.$2, ordinal));
      }(),
  ];
}

/// Changes when a snapshot adds or removes an occurrence, but not on reorder.
String playlistMultiplicitySignature(List<Track> tracks) {
  final multiplicities = <String, int>{};
  for (final track in tracks) {
    final identity = jsonEncode([track.source ?? '', track.id]);
    multiplicities.update(identity, (count) => count + 1, ifAbsent: () => 1);
  }
  final identities = multiplicities.keys.toList()..sort();
  return sha256
      .convert(
        utf8.encode(
          jsonEncode([
            for (final identity in identities)
              [identity, multiplicities[identity]],
          ]),
        ),
      )
      .toString();
}

class PlaylistScreen extends ConsumerStatefulWidget {
  final String playlistName;
  final String? coverUrl;
  final String? headerVideoUrl;
  final List<Track> tracks;
  final String? playlistId;
  final String? metadataProviderId;
  final String collectionType;
  final String? recommendedService;
  final Future<Map<String, dynamic>> Function(String, String, String)?
  metadataLoader;

  const PlaylistScreen({
    super.key,
    required this.playlistName,
    this.coverUrl,
    this.headerVideoUrl,
    required this.tracks,
    this.playlistId,
    this.metadataProviderId,
    this.collectionType = 'playlist',
    this.recommendedService,
    this.metadataLoader,
  });

  @override
  ConsumerState<PlaylistScreen> createState() => _PlaylistScreenState();
}

class _PlaylistScreenState extends ConsumerState<PlaylistScreen>
    with
        SelectionModeMixin<PlaylistScreen>,
        CollapsingHeaderScrollMixin<PlaylistScreen>,
        PlaylistDownloadFeedback<PlaylistScreen> {
  final _historySnapshot = TrackHistorySnapshot();
  final _anonymousListContext = List.generate(
    4,
    (_) => Random.secure().nextInt(1 << 32),
  ).join('-');

  /// Double click and Enter actions of the desktop table rows, by row id.
  final Map<String, VoidCallback> _desktopActivations = {};
  List<Track>? _fetchedTracks;
  bool _isLoading = false;
  String? _error;
  String? _resolvedPlaylistName;
  String? _resolvedCoverUrl;
  String? _resolvedHeaderVideoUrl;

  List<Track> get _tracks => _fetchedTracks ?? widget.tracks;
  String get _playlistName => _resolvedPlaylistName ?? widget.playlistName;
  String? get _coverUrl => _resolvedCoverUrl ?? widget.coverUrl;
  String? get _headerVideoUrl =>
      _resolvedHeaderVideoUrl ?? widget.headerVideoUrl;

  /// Playlists can legitimately contain the same track twice, so selection is
  /// keyed by position as well as id (matching the album screen).
  String _trackSelectionId(Track track, int index) => '${track.id}#$index';

  List<Track> get _selectedTracks => [
    for (var index = 0; index < _tracks.length; index++)
      if (selectedIds.contains(_trackSelectionId(_tracks[index], index)))
        _tracks[index],
  ];

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<String> ids,
    double bottomPadding,
  ) {
    final selectedCount = selectedIds.length;
    return buildSelectionBar(
      ids: ids,
      bottomPadding: bottomPadding,
      children: [
        SizedBox(
          width: double.infinity,
          child: SelectionActionButton(
            icon: Icons.download_rounded,
            label: '${context.l10n.dialogDownload} ($selectedCount)',
            onPressed: selectedCount == 0 ? null : _downloadSelected,
            colorScheme: colorScheme,
          ),
        ),
      ],
    );
  }

  Future<void> _downloadSelected() async {
    final selected = _selectedTracks;
    if (selected.isEmpty) return;
    final submittedIds = Set<String>.of(selectedIds);
    await queueTracksSkippingDownloaded(
      context,
      ref,
      selected,
      artistNameForPicker: _playlistName,
      recommendedService: widget.recommendedService,
      forceQualityPicker: true,
      origin: DownloadOrigin.playlist,
      onAdmitted: trackPlaylistDownloadBatch(),
      onQueued: () {
        if (selectedIds.length == submittedIds.length &&
            submittedIds.every(selectedIds.contains)) {
          exitSelectionMode();
        }
      },
    );
  }

  String? _metadataProviderId(String playlistId) {
    final providerId = resolvePreferredMetadataProviderId(
      widget.metadataProviderId,
      playlistId,
    );
    if (providerId == null) return null;
    if (widget.metadataLoader != null) {
      return resolveOriginalCollectionProvider(
        providerId,
        ref.read(extensionProvider),
      );
    }
    final effective = resolveEffectiveMetadataProvider(
      providerId,
      ref.read(extensionProvider),
    );
    return effective.isEmpty ? null : effective;
  }

  String _metadataResourceId(String providerId, String playlistId) {
    return stripPrefixedResourceId(playlistId);
  }

  String? _recommendedDownloadService() {
    final explicit = widget.recommendedService;
    if (explicit != null && explicit.isNotEmpty) {
      return explicit;
    }

    final playlistId = widget.playlistId;
    if (playlistId != null) {
      final providerId = _metadataProviderId(playlistId);
      if (providerId != null && providerId.isNotEmpty) {
        return resolveEffectiveDownloadService(
          providerId,
          ref.read(extensionProvider),
        );
      }
    }

    final source = _tracks.firstOrNull?.source;
    if (source != null && source.isNotEmpty) {
      return source;
    }

    final trackId = _tracks.firstOrNull?.id ?? '';
    final trackProviderId = legacyProviderIdFromResourceId(trackId);
    if (trackProviderId != null) {
      return resolveEffectiveDownloadService(
        trackProviderId,
        ref.read(extensionProvider),
      );
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _fetchTracksIfNeeded();
  }

  @override
  void didUpdateWidget(covariant PlaylistScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.playlistId != widget.playlistId ||
        oldWidget.metadataProviderId != widget.metadataProviderId ||
        oldWidget.collectionType != widget.collectionType ||
        (widget.playlistId == null &&
            (oldWidget.playlistName != widget.playlistName ||
                oldWidget.tracks.length != widget.tracks.length ||
                oldWidget.tracks.indexed.any((entry) {
                  final (index, oldTrack) = entry;
                  final track = widget.tracks[index];
                  return oldTrack.id != track.id ||
                      oldTrack.source != track.source;
                })))) {
      clearPlaylistDownloadFeedback();
    }
  }

  Future<void> _fetchTracksIfNeeded() async {
    if (widget.tracks.isNotEmpty || widget.playlistId == null) return;

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      String playlistId = widget.playlistId!;
      late final Map<String, dynamic> result;
      final providerId = _metadataProviderId(playlistId);
      if (providerId == null && widget.metadataLoader != null) {
        throw StateError('The original catalog provider is unavailable.');
      }
      if (providerId != null) {
        result =
            await (widget.metadataLoader ?? PlatformBridge.getProviderMetadata)(
              providerId,
              widget.collectionType,
              _metadataResourceId(providerId, playlistId),
            );
      } else {
        result = await PlatformBridge.getProviderMetadata(
          'deezer',
          widget.collectionType,
          playlistId,
        );
      }
      if (!mounted) return;

      final playlistInfo =
          (result['playlist_info'] ?? result['album_info'])
              as Map<String, dynamic>?;
      final owner = playlistInfo?['owner'] as Map<String, dynamic>?;
      final resolvedPlaylistName =
          (playlistInfo?['name'] ?? owner?['name'])?.toString() ??
          _playlistName;

      final trackList =
          (result['track_list'] ?? result['tracks']) as List<dynamic>? ?? [];
      final tracks = trackList
          .map(
            (t) => Track.fromBackendMap(
              t as Map<String, dynamic>,
              playlistName: resolvedPlaylistName,
              source: providerId,
            ),
          )
          .toList();

      final headerVideo = playlistInfo?['header_video']?.toString();

      setState(() {
        _fetchedTracks = tracks;
        _resolvedPlaylistName = resolvedPlaylistName;
        _resolvedCoverUrl = (playlistInfo?['images'] ?? owner?['images'])
            ?.toString();
        _resolvedHeaderVideoUrl =
            (headerVideo != null && headerVideo.isNotEmpty)
            ? headerVideo
            : _resolvedHeaderVideoUrl;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = context.friendlyError(e);
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (context.isMornye) {
      return MornyeArtistSurface(
        imageSource: _coverUrl,
        neutralActions: true,
        child: Builder(builder: _buildPage),
      );
    }
    return _buildPage(context);
  }

  Widget _buildPage(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final bottomPadding = isSelectionMode
        ? MediaQuery.paddingOf(context).bottom
        : 0.0;

    final ids = [
      for (var index = 0; index < _tracks.length; index++)
        _trackSelectionId(_tracks[index], index),
    ];
    pruneSelection(ids.toSet());

    return DesktopListScope(
      onSelectAll: ids.isEmpty ? null : () => selectAll(ids),
      onClearSelection: isSelectionMode ? exitSelectionMode : null,
      onActivate: () => _desktopActivations[selectionAnchorId]?.call(),
      child: CollectionScaffold(
        scrollController: scrollController,
        isSelectionMode: isSelectionMode,
        onExitSelectionMode: exitSelectionMode,
        selectionBar: _buildSelectionBottomBar(
          context,
          colorScheme,
          ids,
          bottomPadding,
        ),
        appBar: _buildAppBar(context, colorScheme),
        slivers: [
          ?playlistDownloadFeedback,
          _buildTrackList(context, colorScheme),
          _buildPlaylistFooter(context, colorScheme),
          if (!_isLoading && _tracks.isNotEmpty && !isSelectionMode)
            CollectionSuggestionsSliver(
              collectionKey:
                  'playlist:${widget.metadataProviderId}:'
                  '${widget.playlistId ?? widget.playlistName}',
              tracks: _tracks,
            ),
        ],
      ),
    );
  }

  Widget _buildAppBar(BuildContext context, ColorScheme colorScheme) {
    final expandedHeight = calculateExpandedHeight(context);
    final cacheWidth = coverCacheWidthForViewport(context);
    final motionUrl = _headerVideoUrl;
    final hasMotion =
        motionUrl != null &&
        motionUrl.trim().isNotEmpty &&
        Uri.tryParse(motionUrl)?.hasAuthority == true;
    Widget playlistPlaceholder({double? size}) {
      return Container(
        color: colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.playlist_play,
          size: size ?? 80,
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    final collageSources = playlistCollageSources(
      _tracks.map((track) => track.coverUrl),
      limit: 9,
    );
    final Widget coverImage = collageSources.isNotEmpty
        ? CoverCollageBackdrop(sources: collageSources)
        : _coverUrl != null
        ? CachedCoverImage(
            imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
            fit: BoxFit.cover,
            memCacheWidth: cacheWidth,
            placeholder: (_, _) => Container(color: colorScheme.surface),
            errorWidget: (_, _, _) => Container(color: colorScheme.surface),
          )
        : playlistPlaceholder();

    return AlbumDetailHeader(
      title: _playlistName,
      immersive: context.isMornye,
      squareArtwork: !hasMotion,
      expandedHeight: expandedHeight,
      showTitleInAppBar: false,
      showTitleListenable: showTitleNotifier,
      background: hasMotion
          ? MotionHeaderBanner(videoUrl: motionUrl, fallback: coverImage)
          : coverImage,
      paletteSource: _coverUrl,
      blurAndScrimBackground:
          !hasMotion && _coverUrl != null && collageSources.isEmpty,
      coverBuilder: hasMotion || collageSources.isNotEmpty
          ? null
          : (context, coverSize) => _coverUrl != null
                ? DownloadableCover(
                    coverUrl: highResCoverUrl(_coverUrl) ?? _coverUrl,
                    baseName: _playlistName,
                    child: CachedCoverImage(
                      imageUrl: highResCoverUrl(_coverUrl) ?? _coverUrl!,
                      complete: true,
                      fit: BoxFit.cover,
                      memCacheWidth: cacheWidth,
                      placeholder: (_, _) => playlistPlaceholder(),
                      errorWidget: (_, _, _) => playlistPlaceholder(size: 48),
                    ),
                  )
                : playlistPlaceholder(size: 48),
      meta: HeaderMetaRow(
        items: [
          HeaderMetaItem(
            context.l10n.tracksCount(_tracks.length),
            icon: Icons.playlist_play,
          ),
        ],
      ),
      appBarActions: ref.watch(linkPhoneClientProvider) == null
          ? null
          : [
              LinkDownloadOnDesktopButton(
                tracks: _tracks,
                service: _recommendedDownloadService(),
                playlistName: _playlistName,
              ),
            ],
      actions: CollectionHeaderActions(
        tracks: _tracks,
        onLoveAll: () => loveAllTracks(this.context, ref, _tracks),
        downloadIcon: Icons.download_rounded,
        tonalDownload: true,
        onDownloadAll: () => confirmDownloadAllDialog(
          context,
          _tracks.length,
          () => _downloadAll(context),
        ),
        addToPlaylistIcon: Icons.playlist_add,
        onAddToPlaylist: () => showAddTracksToPlaylistSheet(
          context,
          ref,
          _tracks,
          playlistNamePrefill: widget.playlistName,
          preserveOccurrences: true,
        ),
        onShuffle: () => _shuffleAll(context),
      ),
    );
  }

  Widget _buildPlaylistFooter(BuildContext context, ColorScheme colorScheme) =>
      buildTrackListFooter(
        context,
        colorScheme,
        _tracks,
        excludeEpochReleaseDate: true,
      );

  Widget _buildTrackList(BuildContext context, ColorScheme colorScheme) {
    if (_isLoading) {
      // The skeleton rows carry the list's own inset.
      return const SliverToBoxAdapter(child: TrackListSkeleton(itemCount: 8));
    }

    if (_error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ErrorCard(
            error: _error!,
            colorScheme: colorScheme,
            onRetry: _fetchTracksIfNeeded,
          ),
        ),
      );
    }

    if (_tracks.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: Text(
              context.l10n.errorNoTracksFound,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      );
    }

    _historySnapshot.update(_tracks);
    final historyKeys = _historySnapshot.lookupKeys;
    final existingHistoryKeys = ref.watch(
      downloadHistoryVisibleBatchExistsProvider(_historySnapshot.request),
    );
    final tracks = _tracks;
    final occurrenceKeys = playlistOccurrenceKeys(tracks);
    // A provider gives no IDs for repeated entries. If multiplicities change,
    // the same ordinal may now name a different occurrence, so invalidate the
    // old context instead of highlighting the wrong row.
    final listContext = jsonEncode([
      'catalogPlaylist',
      widget.collectionType,
      widget.metadataProviderId,
      widget.playlistId ?? _anonymousListContext,
      playlistMultiplicitySignature(tracks),
    ]);
    final occurrences = [
      for (final key in occurrenceKeys)
        jsonEncode([key.value.$1, key.value.$2, key.value.$3]),
    ];
    final occurrenceIndexes = {
      for (var i = 0; i < occurrenceKeys.length; i++) occurrenceKeys[i]: i,
    };
    void activate(int index) => TrackListTile.activate(
      context,
      ref,
      tracks[index],
      isInHistory: existingHistoryKeys.contains(historyKeys[index]),
      onDownload: ({bool forceQualityPicker = false}) => _downloadTrack(
        context,
        tracks[index],
        playlistPosition: index + 1,
        forceQualityPicker: forceQualityPicker,
      ),
      queue: tracks,
      startIndex: index,
      listContext: listContext,
      listOccurrences: occurrences,
    );
    if (isDesktopPlatform) {
      final ids = [
        for (var i = 0; i < _tracks.length; i++)
          _trackSelectionId(_tracks[i], i),
      ];
      final inHistory = [
        for (final key in historyKeys) existingHistoryKeys.contains(key),
      ];
      _desktopActivations
        ..clear()
        ..addAll({
          for (var i = 0; i < ids.length; i++) ids[i]: () => activate(i),
        });
      return TrackListTable(
        listContext: listContext,
        listOccurrences: occurrences,
        verifiedDownloadedIndicator: true,
        tracks: tracks,
        ids: ids,
        isInHistory: inHistory,
        selectedIds: selectedIds,
        onSelect: applyDesktopClick,
        onActivate: activate,
        showArtwork: true,
        showAlbum: true,
      );
    }
    return SliverPadding(
      padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
      sliver: SliverList(
        delegate: SliverChildBuilderDelegate(
          (context, index) {
            final track = _tracks[index];
            final selectionId = _trackSelectionId(track, index);
            final isInHistory = existingHistoryKeys.contains(
              historyKeys[index],
            );
            return KeyedSubtree(
              key: occurrenceKeys[index],
              child: StaggeredListItem(
                index: index,
                child: TrackListTile(
                  track: track,
                  playlistActions: true,
                  listContext: listContext,
                  listOccurrence: occurrences[index],
                  onActivate: () => activate(index),
                  isInHistory: isInHistory,
                  isSelectionMode: isSelectionMode,
                  isSelected: selectedIds.contains(selectionId),
                  onToggleSelection: () => toggleSelection(selectionId),
                  onEnterSelectionMode: () => enterSelectionMode(selectionId),
                  onDownload: ({bool forceQualityPicker = false}) =>
                      _downloadTrack(
                        context,
                        track,
                        playlistPosition: index + 1,
                        forceQualityPicker: forceQualityPicker,
                      ),
                  leadingArtwork: true,
                  leading: track.coverUrl != null
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox(
                            width: 48,
                            height: 48,
                            child: PlayerArtwork(
                              complete: true,
                              artUri: track.coverUrl,
                              colorScheme: colorScheme,
                              iconSize: 24,
                            ),
                          ),
                        )
                      : Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Icon(
                            Icons.music_note,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                ),
              ),
            );
          },
          childCount: _tracks.length,
          findChildIndexCallback: (key) => occurrenceIndexes[key],
        ),
      ),
    );
  }

  void _downloadTrack(
    BuildContext context,
    Track track, {
    int? playlistPosition,
    bool forceQualityPicker = false,
  }) {
    downloadSingleTrack(
      context,
      ref,
      track,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      playlistPosition: playlistPosition,
      forceQualityPicker: forceQualityPicker,
    );
  }

  Future<void> _shuffleAll(BuildContext context) {
    final occurrenceKeys = playlistOccurrenceKeys(_tracks);
    return shuffleTrackCollection(
      context,
      ref,
      tracks: _tracks,
      smartAvailable: true,
      listContext: jsonEncode([
        'catalogPlaylist',
        widget.collectionType,
        widget.metadataProviderId,
        widget.playlistId ?? _anonymousListContext,
        playlistMultiplicitySignature(_tracks),
      ]),
      listOccurrences: [
        for (final key in occurrenceKeys)
          jsonEncode([key.value.$1, key.value.$2, key.value.$3]),
      ],
    );
  }

  Future<void> _downloadAll(BuildContext context) async {
    await queueTracksSkippingDownloaded(
      context,
      ref,
      _tracks,
      artistNameForPicker: _playlistName,
      recommendedService: _recommendedDownloadService(),
      playlistName: _playlistName,
      resolveDefaultService: false,
      onAdmitted: trackPlaylistDownloadBatch(),
    );
  }
}
