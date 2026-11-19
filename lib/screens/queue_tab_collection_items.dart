part of 'queue_tab.dart';

class _ManualPlaylistDropRegistration extends StatefulWidget {
  const _ManualPlaylistDropRegistration({
    required this.registry,
    required this.canAccept,
    required this.onDrop,
    required this.child,
  });

  final Set<_ManualPlaylistDropRegistrationState> registry;
  final bool canAccept;
  final ValueChanged<LibraryPlaylistDragBatch> onDrop;
  final Widget child;

  @override
  State<_ManualPlaylistDropRegistration> createState() =>
      _ManualPlaylistDropRegistrationState();
}

class _ManualPlaylistDropRegistrationState
    extends State<_ManualPlaylistDropRegistration> {
  @override
  void initState() {
    super.initState();
    widget.registry.add(this);
  }

  @override
  void didUpdateWidget(_ManualPlaylistDropRegistration oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry.remove(this);
      widget.registry.add(this);
    }
  }

  @override
  void dispose() {
    widget.registry.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _ManualPlaylistRegistrationScope(owner: this, child: widget.child);
}

class _ManualPlaylistRegistrationScope extends InheritedWidget {
  const _ManualPlaylistRegistrationScope({
    required this.owner,
    required super.child,
  });
  final _ManualPlaylistDropRegistrationState owner;

  @override
  bool updateShouldNotify(_ManualPlaylistRegistrationScope oldWidget) =>
      owner != oldWidget.owner;
}

extension _QueueTabCollectionItemWidgets on _QueueTabState {
  /// A completed download pinned above the Library until its row lands.
  Widget _buildBridgeItem(
    BuildContext context,
    DownloadItem item,
    ColorScheme colorScheme,
    DownloadHistoryItem? historyItem, {
    required bool grid,
    List<DownloadHistoryItem>? navigationItems,
    int? navigationIndex,
  }) {
    final track = item.track;
    final coverSize = grid ? null : _queueCoverSize();
    final radius = BorderRadius.circular(8);
    final unifiedItem = historyItem == null
        ? null
        : UnifiedLibraryItem.fromDownloadHistory(historyItem);
    final quality =
        unifiedItem?.qualityForMode(_libraryQualityLabelMode) ??
        buildCompletionBridgeFallbackQualityLabel(
          mode: _libraryQualityLabelMode,
          completedItemFilePath: item.filePath,
          storedQuality: track.audioQuality,
        );
    final cover = unifiedItem != null
        ? _buildUnifiedCoverImage(unifiedItem, colorScheme, coverSize)
        : track.coverUrl != null
        ? CachedCoverImage(
            imageUrl: track.coverUrl!,
            width: coverSize,
            height: coverSize,
            borderRadius: radius,
          )
        : grid
        ? const TrackCoverPlaceholder()
        : Container(
            width: coverSize,
            height: coverSize,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: radius,
            ),
            child: AppIcon(
              Icons.music_note,
              color: colorScheme.onSurfaceVariant,
            ),
          );
    final heroTag = historyItem != null
        ? 'cover_lib_dl_${historyItem.id}'
        : 'cover_${item.id}';
    final trackName = historyItem?.trackName ?? track.name;
    final artistName = historyItem?.artistName ?? track.artistName;
    final albumName = historyItem?.albumName ?? track.albumName;
    final coverUrl = historyItem?.coverUrl ?? track.coverUrl ?? '';
    void openDetails() => historyItem != null
        ? _navigateToHistoryMetadataScreen(
            historyItem,
            navigationItems: navigationItems,
            navigationIndex: navigationIndex,
          )
        : _navigateToMetadataScreen(item);
    final playable = _completionBridgePlayableProbe.listenable(
      historyFilePath: historyItem?.filePath,
      completedItemFilePath: item.filePath,
    );
    void onTap() {
      if (_isSelectionMode) {
        if (unifiedItem != null) _toggleSelection(unifiedItem.id);
        return;
      }
      final result = playable.value;
      if (result.status == CompletionBridgePlayableStatus.playable &&
          result.path != null) {
        _openFile(
          result.path!,
          title: trackName,
          artist: artistName,
          album: albumName,
          coverUrl: coverUrl,
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.status == CompletionBridgePlayableStatus.checking
                  ? context.l10n.queueCheckingDownloadedFile
                  : context.l10n.queueDownloadedFileMissing,
            ),
          ),
        );
      }
    }

    final playback = ValueListenableBuilder<CompletionBridgePlayableResult>(
      valueListenable: playable,
      builder: (context, result, child) {
        if (result.status == CompletionBridgePlayableStatus.playable) {
          return const SizedBox.shrink();
        }
        if (result.status == CompletionBridgePlayableStatus.checking) {
          final indicator = AppLoadingIndicator(
            size: grid ? 14 : 18,
            strokeWidth: 2,
            color: colorScheme.primary,
            semanticLabel: context.l10n.queueCheckingDownloadedFile,
          );
          return grid
              ? Container(
                  width: 28,
                  height: 28,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: indicator,
                )
              : SizedBox.square(
                  dimension: context.tokens.minTouchTarget,
                  child: Center(child: indicator),
                );
        }
        final icon = AppIcon(
          Icons.error_outline,
          color: colorScheme.error,
          size: grid ? 14 : 20,
        );
        return Tooltip(
          message: context.l10n.queueDownloadedFileMissing,
          child: grid
              ? Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: colorScheme.errorContainer,
                    shape: BoxShape.circle,
                  ),
                  child: icon,
                )
              : icon,
        );
      },
    );
    if (!grid) {
      return TrackCard(
        onTap: onTap,
        isSelectionMode: _isSelectionMode,
        isSelected:
            unifiedItem != null && _selectedIds.contains(unifiedItem.id),
        onLongPress: unifiedItem == null
            ? openDetails
            : () => _enterSelectionMode(unifiedItem.id),
        onContextMenu: (position) =>
            _showOpenMenu(context, position, openDetails),
        leading: Hero(tag: heroTag, child: cover),
        title: trackName,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            IgnorePointer(
              ignoring: true,
              child: ClickableArtistName(
                artistName: artistName,
                coverUrl: coverUrl,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            if (quality != null && quality.isNotEmpty) ...[
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: _buildLibraryQualityBadge(
                  context,
                  colorScheme,
                  quality,
                  listStyle: true,
                ),
              ),
            ],
          ],
        ),
        trailing: isDesktopPlatform
            ? playback
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [playback, _libraryDetailsMenu(context, openDetails)],
              ),
      );
    }
    return TrackGridCard(
      semanticLabel: context.l10n.a11yTrackByArtist(trackName, artistName),
      onTap: onTap,
      onLongPress: unifiedItem == null
          ? openDetails
          : () => _enterSelectionMode(unifiedItem.id),
      onContextMenu: (position) =>
          _showOpenMenu(context, position, openDetails),
      isSelected: unifiedItem != null && _selectedIds.contains(unifiedItem.id),
      cover: Hero(tag: heroTag, child: cover),
      overlays: [
        PositionedDirectional(
          end: 4,
          top: 4,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: context.tokens.borderRadiusBadge,
            ),
            child: AppIcon(
              Icons.download_done,
              size: 12,
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (quality != null && quality.isNotEmpty)
          PositionedDirectional(
            start: 4,
            end: 28,
            top: 4,
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: _buildLibraryQualityBadge(context, colorScheme, quality),
            ),
          ),
        if (!_isSelectionMode && !isDesktopPlatform)
          PositionedDirectional(
            end: 4,
            bottom: 4,
            child: _libraryDetailsMenu(context, openDetails, overArtwork: true),
          ),
        PositionedDirectional(
          start: isDesktopPlatform ? null : 4,
          end: isDesktopPlatform ? 4 : null,
          bottom: 4,
          child: playback,
        ),
      ],
      title: trackName,
      subtitle: IgnorePointer(
        ignoring: true,
        child: ClickableArtistName(artistName: artistName, coverUrl: coverUrl),
      ),
    );
  }

  Widget _buildLibraryQualityBadge(
    BuildContext context,
    ColorScheme colorScheme,
    String quality, {
    bool listStyle = false,
  }) {
    final tokens = context.tokens;
    final isHighlightedQuality = shouldHighlightAudioQualityBadge(quality);
    final displayQuality = listStyle
        ? quality
        : formatLibraryGridAudioQualityLabel(quality);
    final isDetailed = isDetailedLibraryAudioQualityLabel(displayQuality);
    final label = Text(
      displayQuality,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: isHighlightedQuality
            ? listStyle
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onPrimary
            : colorScheme.onSurfaceVariant,
        fontSize: isDetailed ? tokens.badgeFontSize - 1 : tokens.badgeFontSize,
        fontWeight: listStyle ? FontWeight.w500 : FontWeight.w600,
      ),
    );
    return Container(
      padding: tokens.badgePadding,
      decoration: BoxDecoration(
        color: isHighlightedQuality
            ? listStyle
                  ? colorScheme.primaryContainer
                  : colorScheme.primary
            : colorScheme.surfaceContainerHighest,
        borderRadius: tokens.borderRadiusBadge,
      ),
      child: !listStyle && isDetailed
          ? FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: label,
            )
          : label,
    );
  }

  Widget _buildCollectionListItem({
    required BuildContext context,
    required ColorScheme colorScheme,
    IconData? icon,
    Color? iconBgColor,
    Widget? coverWidget,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    ValueChanged<Offset>? onContextMenu,
  }) {
    final cover =
        coverWidget ??
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: context.isMornye
                ? iconBgColor ?? colorScheme.surfaceContainerHighest
                : colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(
            icon ?? Icons.folder,
            color: context.isMornye
                ? Colors.white
                : colorScheme.onSecondaryContainer,
            size: 28,
          ),
        );

    final card = AppContentCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      mornyeSurface: false,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            SizedBox(width: 56, height: 56, child: cover),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            AppIcon(
              Icons.chevron_right,
              color: colorScheme.onSurfaceVariant,
              size: 20,
            ),
          ],
        ),
      ),
    );
    return DesktopContextMenuRegion(
      onContextMenu:
          onContextMenu ??
          (position) => _showOpenMenu(context, position, onTap),
      child: card,
    );
  }

  /// The desktop menu of a folder that offers nothing beyond opening it.
  void _showOpenMenu(
    BuildContext context,
    Offset position,
    VoidCallback onOpen,
  ) => showContextMenu(
    context,
    position: position,
    groups: [
      [
        ContextMenuAction(
          icon: Icons.open_in_new,
          label: context.l10n.desktopMenuOpen,
          onSelected: onOpen,
        ),
      ],
    ],
  );

  /// The desktop menu of a playlist: open, rename, and delete. Deleting a
  /// playlist outside the selection deletes only that playlist.
  void _showPlaylistMenu(
    BuildContext context,
    UserPlaylistCollection playlist,
    Offset position,
  ) {
    final l10n = context.l10n;
    final root = Navigator.of(context, rootNavigator: true).context;
    showContextMenu(
      context,
      position: position,
      groups: [
        [
          ContextMenuAction(
            icon: Icons.open_in_new,
            label: l10n.desktopMenuOpen,
            onSelected: () => _openPlaylistById(playlist.id),
          ),
          ContextMenuAction(
            icon: Icons.edit_outlined,
            label: l10n.collectionRenamePlaylist,
            onSelected: () async {
              final name = await promptPlaylistName(
                root,
                title: l10n.collectionRenamePlaylist,
                confirmLabel: l10n.dialogSave,
                initialName: playlist.name,
              );
              final trimmed = name?.trim() ?? '';
              if (trimmed.isEmpty || !mounted) return;
              await ref
                  .read(libraryCollectionsProvider.notifier)
                  .renamePlaylist(playlist.id, trimmed);
            },
          ),
        ],
        [
          ContextMenuAction(
            icon: Icons.delete_outline,
            label: l10n.collectionDeletePlaylist,
            destructive: true,
            onSelected: () {
              if (!_selectedPlaylistIds.contains(playlist.id)) {
                _exitPlaylistSelectionMode();
                _enterPlaylistSelectionMode(playlist.id);
              }
              _deleteSelectedPlaylists(this.context);
            },
          ),
        ],
      ],
    );
  }

  Widget _buildCollectionGridItem({
    required BuildContext context,
    required ColorScheme colorScheme,
    IconData? icon,
    Color? iconBgColor,
    Widget? coverWidget,
    required String title,
    required int count,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    ValueChanged<Offset>? onContextMenu,
  }) {
    final cover =
        coverWidget ??
        Container(
          decoration: BoxDecoration(
            color: context.isMornye
                ? iconBgColor ?? colorScheme.surfaceContainerHighest
                : colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(8),
          ),
          child: AppIcon(
            icon ?? Icons.folder,
            color: context.isMornye
                ? Colors.white
                : colorScheme.onSecondaryContainer,
            size: 40,
          ),
        );

    return DesktopContextMenuRegion(
      onContextMenu:
          onContextMenu ??
          (position) => _showOpenMenu(context, position, onTap),
      child: _buildCollectionGridCell(
        context: context,
        colorScheme: colorScheme,
        cover: cover,
        title: title,
        count: count,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }

  Widget _buildCollectionGridCell({
    required BuildContext context,
    required ColorScheme colorScheme,
    required Widget cover,
    required String title,
    required int count,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Semantics(
      button: true,
      label: context.l10n.a11yOpenItemCount(title, count),
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 1,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: cover,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
            ),
            Text(
              context.l10n.itemCount(count),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<_CollectionEntry> _getVisibleCollectionEntries(
    LibraryCollectionsState collectionState,
  ) {
    final entries = <_CollectionEntry>[];
    if (collectionState.lovedCount > 0) {
      entries.add(_CollectionEntry.loved);
    }
    if (collectionState.favoriteArtistCount > 0) {
      entries.add(_CollectionEntry.favoriteArtists);
    }
    for (var i = 0; i < collectionState.playlists.length; i++) {
      entries.add(_CollectionEntry.playlist(i));
    }
    return entries;
  }

  /// Icon, tile color, title, count and folder of a non-playlist entry.
  (IconData, Color, String, int, VoidCallback) _specialCollection(
    BuildContext context,
    _CollectionEntryType type,
    LibraryCollectionsState collectionState,
  ) => switch (type) {
    _CollectionEntryType.loved => (
      Icons.favorite,
      const Color(0xFF8C67AC),
      context.l10n.collectionLoved,
      collectionState.lovedCount,
      _openLovedFolder,
    ),
    _ => (
      Icons.person,
      const Color(0xFFE91E63),
      context.l10n.collectionFavoriteArtists,
      collectionState.favoriteArtistCount,
      _openFavoriteArtistsFolder,
    ),
  };

  /// A playlist entry that accepts dragged tracks and outlines itself while
  /// one hovers. [builder] gets the entry's tap and long-press actions.
  Widget _playlistDropTarget(
    BuildContext context,
    ColorScheme colorScheme,
    UserPlaylistCollection playlist,
    List<UnifiedLibraryItem> filteredUnifiedItems,
    Widget Function(
      BuildContext context,
      VoidCallback onTap,
      VoidCallback onLongPress,
    )
    builder,
  ) {
    return _ManualPlaylistDropRegistration(
      registry: _manualPlaylistTargets,
      canAccept: !_isPlaylistSelectionMode,
      onDrop: (batch) =>
          _onTrackDroppedOnPlaylist(context, batch, playlist.id, playlist.name),
      child: DragTarget<LibraryPlaylistDragBatch>(
        onWillAcceptWithDetails: (_) => !_isPlaylistSelectionMode,
        onAcceptWithDetails: (details) {
          if (_manualDragBatches[details.data] == true) {
            // The pointer-up router resolves the current visible playlist.
            return;
          }
          _onTrackDroppedOnPlaylist(
            context,
            details.data,
            playlist.id,
            playlist.name,
          );
        },
        builder: (context, candidateData, rejectedData) {
          final owner = context
              .dependOnInheritedWidgetOfExactType<
                _ManualPlaylistRegistrationScope
              >()!
              .owner;
          return ValueListenableBuilder<_ManualPlaylistDropRegistrationState?>(
            valueListenable: _manualPlaylistTarget,
            builder: (context, target, child) {
              final isHovering = _manualDragScrollable != null
                  ? identical(target, owner)
                  : candidateData.isNotEmpty;
              return AnimatedContainer(curve: Curves.easeOutCubic,
                duration: const Duration(milliseconds: 150),
                decoration: isHovering
                    ? BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: colorScheme.primary,
                          width: 2,
                        ),
                        color: colorScheme.primary.withValues(alpha: 0.1),
                      )
                    : null,
                child: builder(
                  context,
                  _isPlaylistSelectionMode
                      ? () => _togglePlaylistSelection(playlist.id)
                      : () => _openPlaylistById(playlist.id),
                  _isPlaylistSelectionMode
                      ? () => _togglePlaylistSelection(playlist.id)
                      : () => _enterPlaylistSelectionMode(playlist.id),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _buildAllTabGridCollectionItem({
    required BuildContext context,
    required ColorScheme colorScheme,
    required _CollectionEntry entry,
    required LibraryCollectionsState collectionState,
    List<UnifiedLibraryItem> filteredUnifiedItems = const [],
  }) {
    if (entry.type != _CollectionEntryType.playlist) {
      final (icon, color, title, count, onTap) = _specialCollection(
        context,
        entry.type,
        collectionState,
      );
      return _buildCollectionGridItem(
        context: context,
        colorScheme: colorScheme,
        icon: icon,
        iconBgColor: color,
        title: title,
        count: count,
        onTap: onTap,
      );
    }
    final playlist = collectionState.playlists[entry.playlistIndex];
    final isSelected = _selectedPlaylistIds.contains(playlist.id);
    return _playlistDropTarget(
      context,
      colorScheme,
      playlist,
      filteredUnifiedItems,
      (context, onTap, onLongPress) => Stack(
        children: [
          _buildCollectionGridItem(
            context: context,
            colorScheme: colorScheme,
            coverWidget: _buildPlaylistCover(context, playlist, colorScheme),
            title: playlist.name,
            count: playlist.trackCount,
            onTap: onTap,
            onLongPress: onLongPress,
            onContextMenu: (position) =>
                _showPlaylistMenu(context, playlist, position),
          ),
          if (_isPlaylistSelectionMode)
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: IgnorePointer(
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Container(
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primary.withValues(alpha: 0.3)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
          if (_isPlaylistSelectionMode)
            PositionedDirectional(
              top: 4,
              end: 4,
              child: IgnorePointer(
                child: AnimatedSelectionCheckbox(
                  selected: isSelected,
                  colorScheme: colorScheme,
                  size: 20,
                  unselectedColor: colorScheme.surface.withValues(alpha: 0.85),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAllTabListCollectionItem({
    required BuildContext context,
    required ColorScheme colorScheme,
    required _CollectionEntry entry,
    required LibraryCollectionsState collectionState,
    List<UnifiedLibraryItem> filteredUnifiedItems = const [],
  }) {
    if (entry.type != _CollectionEntryType.playlist) {
      final (icon, color, title, count, onTap) = _specialCollection(
        context,
        entry.type,
        collectionState,
      );
      final countText = entry.type == _CollectionEntryType.favoriteArtists
          ? context.l10n.collectionArtistCount(count)
          : context.l10n.queueTrackCount(count);
      return _buildCollectionListItem(
        context: context,
        colorScheme: colorScheme,
        icon: icon,
        iconBgColor: color,
        title: title,
        subtitle: '${context.l10n.collectionFoldersTitle} • $countText',
        onTap: onTap,
      );
    }
    final playlist = collectionState.playlists[entry.playlistIndex];
    final isSelected = _selectedPlaylistIds.contains(playlist.id);
    return _playlistDropTarget(
      context,
      colorScheme,
      playlist,
      filteredUnifiedItems,
      (context, onTap, onLongPress) => Row(
        children: [
          if (_isPlaylistSelectionMode)
            Semantics(
              button: true,
              checked: isSelected,
              label: playlist.name,
              child: GestureDetector(
                onTap: () => _togglePlaylistSelection(playlist.id),
                behavior: HitTestBehavior.opaque,
                child: ConstrainedBox(
                  constraints: BoxConstraints.tightFor(
                    width: context.tokens.minTouchTarget,
                    height: context.tokens.minTouchTarget,
                  ),
                  child: Center(
                    child: AnimatedSelectionCheckbox(
                      selected: isSelected,
                      colorScheme: colorScheme,
                      size: 24,
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: _buildCollectionListItem(
              context: context,
              colorScheme: colorScheme,
              coverWidget: _buildPlaylistCover(
                context,
                playlist,
                colorScheme,
                56,
              ),
              title: playlist.name,
              subtitle: context.l10n.queueTrackCount(playlist.trackCount),
              onTap: onTap,
              onLongPress: onLongPress,
              onContextMenu: (position) =>
                  _showPlaylistMenu(context, playlist, position),
            ),
          ),
        ],
      ),
    );
  }
}
