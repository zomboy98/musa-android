part of 'queue_tab.dart';

extension _QueueTabItemWidgets on _QueueTabState {
  DownloadedFormat _libraryItemFormat(UnifiedLibraryItem item) {
    final history = item.historyItem;
    if (history != null) return DownloadedFormat.fromHistory(history);
    final local = item.localItem;
    if (local == null) return DownloadedFormat.neutral;
    return DownloadedFormat.fromFile(
      filePath: local.filePath,
      format: local.format,
      quality: item.quality,
      bitDepth: local.bitDepth,
      sampleRate: local.sampleRate,
      bitrate: local.bitrate,
    );
  }

  Widget _buildSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<UnifiedLibraryItem> unifiedItems,
    double bottomPadding,
  ) {
    final selectedCount = _selectedIds.length;
    final allSelected = _allQuerySelected;
    final selectedItems = _selectedItemsFromAll(unifiedItems);
    final completeSelection = selectedItems.length == selectedCount;
    final localOnlySelection =
        completeSelection && _isLocalOnlySelection(unifiedItems);

    final canMoveManually =
        _sortMode == 'manual' &&
        (widget.librarySection ??
                ref.read(settingsProvider).historyFilterMode) ==
            'all';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canMoveManually)
          FilledButton.icon(
            onPressed: () => _moveManualSelection(unifiedItems),
            icon: const Icon(Icons.drive_file_move_outline),
            label: Text(context.l10n.queueMoveSelection),
          ),
        LibraryTrackSelectionBar(
          playbackActions: completeSelection
              ? LibrarySelectionPlaybackActions(
                  items: selectedItems,
                  onClose: _exitSelectionMode,
                )
              : TextButton.icon(
                  onPressed: () async {
                    final resolved = await _resolveSelectionItems(unifiedItems);
                    if (resolved == null || !mounted || !context.mounted)
                      return;
                    _syncSelectionOverlay(
                      items: unifiedItems,
                      bottomPadding: MediaQuery.paddingOf(context).bottom,
                    );
                  },
                  icon: const Icon(Icons.download),
                  label: Text(
                    context.l10n.queueLoadSelectedActions(selectedCount),
                  ),
                ),
          selectedCount: selectedCount,
          allSelected: allSelected,
          onClose: _exitSelectionMode,
          onToggleSelectAll: () {
            if (allSelected) {
              _exitSelectionMode();
            } else {
              _selectAll(unifiedItems);
            }
          },
          bottomPadding: bottomPadding,
          flacEligibleCount: localOnlySelection
              ? _selectedFlacEligibleLocalItems(unifiedItems).length
              : 0,
          onQueueFlac: () => _queueSelectedLocalAsFlac(unifiedItems),
          onReEnrich: () => _reEnrichSelectedFromQueue(unifiedItems),
          onConvert: () => _showBatchConvertSheet(context, unifiedItems),
          onReplayGain: ({required remove}) =>
              _runBatchReplayGain(unifiedItems, remove: remove),
          onDelete: () => _deleteSelected(unifiedItems),
        ),
      ],
    );
  }

  Future<void> _moveManualSelection(
    List<UnifiedLibraryItem> items, {
    String? destinationId,
    LibraryPlaylistDragBatch? batch,
  }) async {
    final l10n = context.l10n;
    final List<String> selected;
    if (batch != null) {
      final ids = await resolveManualLibraryDragIds(batch);
      if (!mounted) return;
      if (ids == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l10n.queueMoveLoadSelectionFailed)),
        );
        return;
      }
      selected = ids;
    } else {
      selected = _selectedIds.toList(growable: false);
    }
    final selectionToken = _librarySelectionToken;
    final anchors = items
        .where((item) => !_selectedIds.contains(item.id))
        .toList();
    // This sentinel cannot be a unified library ID (which has a source prefix).
    const end = '';
    _hideSelectionOverlay();
    final destination =
        destinationId ??
        await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(l10n.queueMoveBefore),
            content: SizedBox(
              width: 480,
              // Lazy rows: the anchors are every other song in the library.
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: anchors.length + 1,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return ListTile(
                      leading: const Icon(Icons.vertical_align_bottom),
                      title: Text(l10n.queueMoveToEndOfLibrary),
                      onTap: () => Navigator.pop(dialogContext, end),
                    );
                  }
                  final item = anchors[index - 1];
                  return ListTile(
                    title: Text(
                      item.trackName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      item.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    onTap: () => Navigator.pop(dialogContext, item.id),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: Text(context.l10n.dialogCancel),
              ),
            ],
          ),
        );
    if (!mounted) return;
    if (destination == null) {
      _syncSelectionOverlay(
        items: items,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
      return;
    }
    // An absent destination must never be interpreted as the end sentinel.
    // A drag's row can disappear while its batch is being resolved.
    if (destination != end &&
        (selected.contains(destination) ||
            !items.any((item) => item.id == destination))) {
      _syncSelectionOverlay(
        items: items,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
      return;
    }
    final anchor = destination == end
        ? null
        : items.where((item) => item.id == destination).firstOrNull;
    final description = anchor == null
        ? l10n.queueMoveDescriptionEnd
        : l10n.queueMoveDescriptionBefore(anchor.trackName);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.queueMoveConfirmTitle),
        content: Text(
          l10n.queueMoveConfirmMessage(selected.length, description),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(context.l10n.dialogCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l10n.queueMoveAction),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmed != true) {
      _syncSelectionOverlay(
        items: items,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
      return;
    }
    try {
      final shouldClear = await writeManualLibraryMove(
        selected: selected,
        write: (ids) => LibraryDatabase.instance.moveManualLibraryTracks(
          ids,
          beforeId: destination == end ? null : destination,
        ),
        ownsSelection: () => batch != null
            ? batch.ownsSelection(_librarySelectionToken, _selectedIds)
            : identical(selectionToken, _librarySelectionToken) &&
                  selected.length == _selectedIds.length &&
                  selected.every(_selectedIds.contains),
      );
      if (!mounted) return;
      if (shouldClear) {
        _exitSelectionMode();
      }
      _setState(_resetLibraryPaging);
      ref.invalidate(_queueLibraryPageProvider);
    } catch (_) {
      if (!mounted) return;
      _setState(_resetLibraryPaging);
      ref.invalidate(_queueLibraryPageProvider);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l10n.queueMoveSelectionFailed)));
      _syncSelectionOverlay(
        items: items,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
    }
  }

  Widget _buildFilterButton(BuildContext context) {
    return GestureDetector(
      onLongPress: _activeFilterCount > 0 ? _resetFilters : null,
      child: ExpressiveButton(
        text: true,
        onPressed: () => _showFilterSheet(context),
        icon: Badge(
          isLabelVisible: _activeFilterCount > 0,
          label: Text('$_activeFilterCount'),
          child: const AppIcon(Icons.filter_list, size: 18),
        ),
        style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
        child: Text(context.l10n.libraryFilterTitle),
      ),
    );
  }

  /// When [size] is provided, renders at fixed dimensions (list mode).
  /// When [size] is null, fills the parent container (grid mode).
  Widget _buildUnifiedCoverImage(
    UnifiedLibraryItem item,
    ColorScheme colorScheme, [
    double? size,
  ]) {
    final isDownloaded = item.source == LibraryItemSource.downloaded;

    // Scanned SAF tracks also recover artwork after a transient provider error.
    if (isDownloaded || item.filePath.startsWith('content://')) {
      return OfflineAvailabilityCover(
        item: item,
        child: ValueListenableBuilder<int>(
          valueListenable: _embeddedCoverVersion,
          builder: (context, _, child) => _buildUnifiedCoverImageInner(
            item,
            colorScheme,
            isDownloaded,
            size,
          ),
        ),
      );
    }

    return OfflineAvailabilityCover(
      item: item,
      child: _buildUnifiedCoverImageInner(
        item,
        colorScheme,
        isDownloaded,
        size,
      ),
    );
  }

  Widget _buildUnifiedCoverImageInner(
    UnifiedLibraryItem item,
    ColorScheme colorScheme,
    bool isDownloaded, [
    double? size,
  ]) {
    final cacheSize = size != null ? (size * 2).toInt() : 200;
    final iconSize = size != null ? size * 0.4 : 32.0;

    Widget buildPlaceholder({
      bool isLocal = false,
      bool recoverDocument = true,
    }) {
      if (recoverDocument && item.filePath.startsWith('content://')) {
        final recovered = _resolveDownloadedEmbeddedCoverPath(item.filePath);
        if (recovered != null) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox.square(
              dimension: size,
              child: CoverImageFrame(
                image: ResizeImage.resizeIfNeeded(
                  cacheSize,
                  null,
                  FileImage(File(recovered)),
                ),
                errorBuilder: (_, _, _) =>
                    buildPlaceholder(isLocal: isLocal, recoverDocument: false),
              ),
            ),
          );
        }
      }
      final bgColor = (isDownloaded && !isLocal)
          ? colorScheme.surfaceContainerHighest
          : colorScheme.secondaryContainer;
      final fgColor = (isDownloaded && !isLocal)
          ? colorScheme.onSurfaceVariant
          : colorScheme.onSecondaryContainer;
      return Container(
        width: size,
        height: size,
        decoration: size != null
            ? BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(8),
              )
            : null,
        color: size != null ? null : bgColor,
        child: Center(
          child: AppIcon(Icons.music_note, color: fgColor, size: iconSize),
        ),
      );
    }

    Widget fadeInFileImage(Widget child, int? frame, bool wasSync) {
      if (wasSync) return child;
      final Widget backdrop;
      if (isDownloaded && item.coverUrl != null) {
        backdrop = CachedCoverImage(
          imageUrl: item.coverUrl!,
          width: size,
          height: size,
          memCacheWidth: cacheSize,
          placeholder: (context, url) =>
              buildPlaceholder(recoverDocument: false),
          errorWidget: (context, url, error) => buildPlaceholder(),
        );
      } else {
        backdrop = buildPlaceholder(
          isLocal: !isDownloaded,
          recoverDocument: false,
        );
      }
      final animated = Stack(
        fit: StackFit.expand,
        children: [
          backdrop,
          AnimatedOpacity(
            opacity: frame == null ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutCubic,
            child: child,
          ),
        ],
      );
      if (size == null) return animated;
      return SizedBox(width: size, height: size, child: animated);
    }

    if (isDownloaded) {
      final embeddedCoverPath = _resolveDownloadedEmbeddedCoverPath(
        item.filePath,
      );
      if (embeddedCoverPath != null) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(
            dimension: size,
            child: CoverImageFrame(
              image: ResizeImage.resizeIfNeeded(
                cacheSize,
                null,
                FileImage(File(embeddedCoverPath)),
              ),
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                  fadeInFileImage(child, frame, wasSynchronouslyLoaded),
              errorBuilder: (context, error, stackTrace) => buildPlaceholder(),
            ),
          ),
        );
      }
    }

    if (item.coverUrl != null) {
      return CachedCoverImage(
        imageUrl: item.coverUrl!,
        width: size,
        height: size,
        complete: true,
        memCacheWidth: cacheSize,
        borderRadius: BorderRadius.circular(8),
        placeholder: (context, url) => buildPlaceholder(),
        errorWidget: (context, url, error) => buildPlaceholder(),
        fadeInDuration: const Duration(milliseconds: 180),
        fadeOutDuration: const Duration(milliseconds: 90),
      );
    }

    if (item.localCoverPath != null && item.localCoverPath!.isNotEmpty) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox.square(
          dimension: size,
          child: CoverImageFrame(
            image: ResizeImage.resizeIfNeeded(
              cacheSize,
              null,
              FileImage(File(item.localCoverPath!)),
            ),
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                fadeInFileImage(child, frame, wasSynchronouslyLoaded),
            errorBuilder: (context, error, stackTrace) =>
                buildPlaceholder(isLocal: true),
          ),
        ),
      );
    }

    if (size != null) {
      return buildPlaceholder();
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: buildPlaceholder(),
    );
  }

  /// A tap on a library song outside selection mode: opens its metadata, or
  /// the bare file when the song has no history or library record.
  VoidCallback _libraryItemOpenAction(
    UnifiedLibraryItem item, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
  }) {
    if (item.source == LibraryItemSource.downloaded) {
      return () => _navigateToHistoryMetadataScreen(
        item.historyItem!,
        navigationItems: downloadedNavigationItems,
        navigationIndex: downloadedNavigationIndex,
      );
    }
    if (item.localItem != null) {
      return () => _navigateToLocalMetadataScreen(
        item.localItem!,
        navigationItems: localNavigationItems,
        navigationIndex: localNavigationIndex,
      );
    }
    return () => _openFile(
      item.filePath,
      title: item.trackName,
      artist: item.artistName,
      album: item.albumName,
      coverUrl: item.coverUrl ?? item.localCoverPath ?? '',
    );
  }

  /// A desktop click on a library song opens its details, as a tap does on
  /// a phone; modifier clicks select.
  void _desktopLibraryItemClick(
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> libraryItems,
    VoidCallback open,
  ) {
    handleDesktopRowClick(
      item.id,
      select: (kind) => _applyDesktopClick(item.id, kind, [
        for (final song in libraryItems) song.id,
      ]),
      activate: open,
    );
  }

  /// The desktop Songs table, after the [leadCount] active downloads. Songs
  /// load in pages already sorted, so the header sorts through the Library
  /// sort modes.
  Widget _buildLibrarySongTable(
    BuildContext context, {
    required String filterMode,
    required List<UnifiedLibraryItem> items,
    required int leadCount,
    required Widget Function(int index) leadBuilder,
    required VoidCallback Function(UnifiedLibraryItem item) openAction,
  }) {
    final table = _librarySongTableRows(
      filterMode,
      items,
      Theme.of(context).colorScheme,
    );
    final byId = table.byId;
    final sort = switch (_sortMode) {
      'a-z' => (column: TrackTableColumn.title, ascending: true),
      'z-a' => (column: TrackTableColumn.title, ascending: false),
      'artist-asc' => (column: TrackTableColumn.artist, ascending: true),
      'artist-desc' => (column: TrackTableColumn.artist, ascending: false),
      'album-asc' => (column: TrackTableColumn.album, ascending: true),
      'album-desc' => (column: TrackTableColumn.album, ascending: false),
      _ => null,
    };
    final inset = EdgeInsets.symmetric(horizontal: wideListInset(context));
    return SliverMainAxisGroup(
      slivers: [
        if (leadCount > 0)
          SliverPadding(
            padding: inset,
            sliver: SliverList.builder(
              itemCount: leadCount,
              itemBuilder: (context, index) => leadBuilder(index),
            ),
          ),
        SliverPadding(
          padding: inset,
          sliver: SliverTrackTable(
            rows: table.rows,
            rowWrapper: _sortMode == 'manual' && filterMode == 'all'
                ? (context, id, child) => _buildPlaylistCompatibleDragSource(
                    byId[id]!,
                    items,
                    ManualLibraryDragRow(
                      id: id,
                      selected: _isSelectionMode && _selectedIds.contains(id),
                      canAccept: _canAcceptManualDrop(id),
                      dragLabel: '${_selectedIds.length}',
                      registry: _manualDragRows,
                      target: _manualDropTarget,
                      onDropBefore: (batch) => _moveManualSelection(
                        items,
                        destinationId: id,
                        batch: batch,
                      ),
                      child: child,
                    ),
                    Theme.of(context).colorScheme,
                  )
                : null,
            uniformRowHeight: true,
            columns: const [
              TrackTableColumn.title,
              TrackTableColumn.artist,
              TrackTableColumn.album,
              TrackTableColumn.quality,
              TrackTableColumn.duration,
            ],
            selectedIds: _selectedIds,
            onSelect: _applyDesktopClick,
            // A click opens the song's details, as a tap does on a phone.
            onActivate: (id) {
              final item = byId[id];
              if (item != null) openAction(item)();
            },
            onContextMenu: (id, position) {
              final item = byId[id];
              if (item == null) return;
              _showLibraryItemMenu(
                context,
                item,
                items,
                position,
                onOpenDetails: openAction(item),
              );
            },
            sort: sort,
            sortableColumns: const {
              TrackTableColumn.title,
              TrackTableColumn.artist,
              TrackTableColumn.album,
            },
            onSort: (next) {
              final mode = switch (next) {
                null => 'latest',
                (column: TrackTableColumn.title, ascending: true) => 'a-z',
                (column: TrackTableColumn.title, ascending: false) => 'z-a',
                (column: TrackTableColumn.artist, ascending: true) =>
                  'artist-asc',
                (column: TrackTableColumn.artist, ascending: false) =>
                  'artist-desc',
                (column: TrackTableColumn.album, ascending: true) =>
                  'album-asc',
                (column: TrackTableColumn.album, ascending: false) =>
                  'album-desc',
                _ => _sortMode,
              };
              _setSortMode(mode);
            },
          ),
        ),
      ],
    );
  }

  /// The Songs table rows for [items], kept while the songs, the quality
  /// label mode and [colorScheme] stay the same. A new list, such as one
  /// with another page loaded, reuses the rows of the songs it keeps.
  _LibrarySongTableRows _librarySongTableRows(
    String filterMode,
    List<UnifiedLibraryItem> items,
    ColorScheme colorScheme,
  ) {
    final qualityMode = _libraryQualityLabelMode;
    final cached = _songTableByMode[filterMode];
    final reusable =
        cached != null &&
        cached.qualityMode == qualityMode &&
        cached.colorScheme == colorScheme;
    if (reusable && identical(cached.items, items)) return cached;
    final previous = reusable ? cached.rowByItem : null;
    final rows = <TrackTableRow>[];
    final rowByItem = Map<UnifiedLibraryItem, TrackTableRow>.identity();
    final byId = <String, UnifiedLibraryItem>{};
    for (final item in items) {
      final row =
          previous?[item] ??
          TrackTableRow(
            id: item.id,
            title: item.trackName,
            artist: item.artistName,
            album: item.albumName,
            quality: item.qualityForMode(qualityMode),
            duration: switch (item.historyItem?.duration ??
                item.localItem?.duration) {
              final seconds? when seconds > 0 => Duration(seconds: seconds),
              _ => null,
            },
            leading: _buildUnifiedCoverImage(item, colorScheme, 32),
            playback: mediaItemPlaybackUiProvider(_libraryPlaybackKey(item)),
          );
      rows.add(row);
      rowByItem[item] = row;
      byId[item.id] = item;
    }
    return _songTableByMode[filterMode] = _LibrarySongTableRows(
      items: items,
      qualityMode: qualityMode,
      colorScheme: colorScheme,
      rows: rows,
      rowByItem: rowByItem,
      byId: byId,
    );
  }

  Widget _libraryDetailsMenu(
    BuildContext context,
    VoidCallback openDetails, {
    bool overArtwork = false,
  }) {
    final colors = Theme.of(context).colorScheme;
    return PopupMenuButton<VoidCallback>(
      icon: overArtwork
          ? Container(
              width: 36,
              height: 36,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: colors.surfaceContainerHighest,
                shape: BoxShape.circle,
              ),
              child: AppIcon(Icons.more_vert, color: colors.onSurfaceVariant),
            )
          : const AppIcon(Icons.more_vert),
      onSelected: (action) => action(),
      itemBuilder: (_) => [
        PopupMenuItem(
          value: openDetails,
          child: Text(context.l10n.nowPlayingDetails),
        ),
      ],
    );
  }

  Widget _buildUnifiedLibraryItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    bool playlistDragEnabled = false,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final date = item.addedAt;
    final dateStr = DateFormat.MMMd(
      Localizations.localeOf(context).toLanguageTag(),
    ).add_Hm().format(date);

    final isDownloaded = item.source == LibraryItemSource.downloaded;
    final quality = item.qualityForMode(_libraryQualityLabelMode);
    final sourceLabel = isDownloaded
        ? context.l10n.librarySourceDownloaded
        : context.l10n.librarySourceLocal;
    // The label text tells the sources apart; rows keep one neutral role.
    final sourceColor = colorScheme.surfaceContainerHighest;
    final sourceTextColor = colorScheme.onSurfaceVariant;

    final open = _libraryItemOpenAction(
      item,
      downloadedNavigationItems: downloadedNavigationItems,
      downloadedNavigationIndex: downloadedNavigationIndex,
      localNavigationItems: localNavigationItems,
      localNavigationIndex: localNavigationIndex,
    );

    final playbackKey = _libraryPlaybackKey(item);
    final leading = Hero(
      tag: 'cover_lib_${item.id}',
      child: _buildUnifiedCoverImage(
        item,
        colorScheme,
        context.tokens.coverList,
      ),
    );
    // The text reads the row's supporting colour, which follows the fill of
    // the current track; the badges keep their own surfaces.
    final subtitle = Builder(
      builder: (context) {
        final textColor = DefaultTextStyle.of(context).style.color;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The history service is where the audio was downloaded from;
            // artist lookups use the user's search provider instead.
            IgnorePointer(
              ignoring: true,
              child: ClickableArtistName(
                artistName: item.artistName,
                coverUrl: item.coverUrl,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: textColor),
              ),
            ),
            const SizedBox(height: 2),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Container(
                  padding: context.tokens.badgePadding,
                  decoration: BoxDecoration(
                    color: sourceColor,
                    borderRadius: context.tokens.borderRadiusBadge,
                  ),
                  child: Text(
                    sourceLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: sourceTextColor,
                      fontSize: context.tokens.badgeFontSize,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                Text(
                  dateStr,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: textColor),
                ),
                if (quality != null && quality.isNotEmpty)
                  _buildLibraryQualityBadge(
                    context,
                    colorScheme,
                    quality,
                    listStyle: true,
                  ),
                if (offlineAvailabilityLabel(context, item) case final status?)
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ],
        );
      },
    );
    final trailing = ValueListenableBuilder<bool>(
      valueListenable: fileExistsListenable,
      builder: (context, fileExists, child) {
        if (fileExists) return const SizedBox.shrink();
        return Tooltip(
          message: context.l10n.queueDownloadedFileMissing,
          child: AppIcon(
            Icons.error_outline,
            color: colorScheme.error,
            size: 20,
          ),
        );
      },
    );
    Widget card({bool current = false, bool playing = false}) => TrackCard(
      isSelectionMode: _isSelectionMode,
      isSelected: isSelected,
      isCurrent: current,
      isPlaying: playing,
      leadingArtwork: true,
      onTap: isDesktopPlatform
          ? () => _desktopLibraryItemClick(
              item,
              libraryItems,
              () => _playLibraryItemFromRow(item, libraryItems),
            )
          : _isSelectionMode
          ? () => _toggleSelection(item.id)
          : () => _playLibraryItemFromRow(item, libraryItems),
      onContextMenu: (position) => _showLibraryItemMenu(
        context,
        item,
        libraryItems,
        position,
        onOpenDetails: open,
      ),
      onLongPress: playlistDragEnabled
          ? null
          : _isSelectionMode
          ? () => _selectRangeTo(item.id, libraryItems)
          : () => _enterSelectionMode(item.id),
      leading: leading,
      title: item.trackName,
      subtitle: subtitle,
      trailing: isDesktopPlatform
          ? trailing
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [trailing, _libraryDetailsMenu(context, open)],
            ),
    );

    // Each row follows its own file in both themes; only affected identities
    // rebuild when playback changes. Multi-selection keeps its own semantics.
    return Consumer(
      builder: (context, ref, _) {
        final playback = ref.watch(mediaItemPlaybackUiProvider(playbackKey));
        return Semantics(
          label: context.l10n.a11yTrackByArtist(
            item.trackName,
            item.artistName,
          ),
          selected: _isSelectionMode ? isSelected : playback.isCurrent,
          child: card(current: playback.isCurrent, playing: playback.isPlaying),
        );
      },
    );
  }

  Widget _buildUnifiedGridItem(
    BuildContext context,
    UnifiedLibraryItem item,
    ColorScheme colorScheme, {
    required List<DownloadHistoryItem> downloadedNavigationItems,
    required int? downloadedNavigationIndex,
    required List<LocalLibraryItem> localNavigationItems,
    required int? localNavigationIndex,
    required List<UnifiedLibraryItem> libraryItems,
    bool playlistDragEnabled = false,
  }) {
    final fileExistsListenable = _fileExistsListenable(item.filePath);
    final isSelected = _selectedIds.contains(item.id);
    final quality = item.qualityForMode(_libraryQualityLabelMode);

    final open = _libraryItemOpenAction(
      item,
      downloadedNavigationItems: downloadedNavigationItems,
      downloadedNavigationIndex: downloadedNavigationIndex,
      localNavigationItems: localNavigationItems,
      localNavigationIndex: localNavigationIndex,
    );

    return TrackGridCard(
      isSelected: _isSelectionMode && isSelected,
      semanticLabel: context.l10n.a11yTrackByArtist(
        item.trackName,
        item.artistName,
      ),
      onTap: isDesktopPlatform
          ? () => _desktopLibraryItemClick(
              item,
              libraryItems,
              () => _playLibraryItemFromRow(item, libraryItems),
            )
          : _isSelectionMode
          ? () => _toggleSelection(item.id)
          : () => _playLibraryItemFromRow(item, libraryItems),
      onContextMenu: (position) => _showLibraryItemMenu(
        context,
        item,
        libraryItems,
        position,
        onOpenDetails: open,
      ),
      onLongPress: playlistDragEnabled
          ? null
          : _isSelectionMode
          ? () => _selectRangeTo(item.id, libraryItems)
          : () => _enterSelectionMode(item.id),
      cover: Hero(
        tag: 'cover_lib_${item.id}',
        child: _buildUnifiedCoverImage(item, colorScheme),
      ),
      overlays: [
        if (!_isSelectionMode)
          PositionedDirectional(
            end: 4,
            top: 4,
            child: DownloadedFormatMark(
              format: _libraryItemFormat(item),
              onArtwork: true,
            ),
          ),
        if (quality != null && quality.isNotEmpty)
          PositionedDirectional(
            start: 4,
            end: _isSelectionMode ? 4 : 28,
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
            child: _libraryDetailsMenu(context, open, overArtwork: true),
          ),
        if (!_isSelectionMode)
          PositionedDirectional(
            start: isDesktopPlatform ? null : 4,
            end: isDesktopPlatform ? 4 : null,
            bottom: 4,
            child: ValueListenableBuilder<bool>(
              valueListenable: fileExistsListenable,
              builder: (context, fileExists, child) => fileExists
                  ? const SizedBox.shrink()
                  : Tooltip(
                      message: context.l10n.queueDownloadedFileMissing,
                      child: AppIcon(
                        Icons.error_outline,
                        color: colorScheme.error,
                        size: 20,
                      ),
                    ),
            ),
          ),
        if (_isSelectionMode)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.3)
                    : Colors.transparent,
                borderRadius: context.tokens.borderRadiusThumb,
              ),
            ),
          ),
        if (_isSelectionMode)
          PositionedDirectional(
            end: 4,
            top: 4,
            child: AnimatedSelectionCheckbox(
              selected: isSelected,
              colorScheme: colorScheme,
              size: 24,
              unselectedColor: colorScheme.surface,
            ),
          ),
      ],
      title: item.trackName,
      // Not the history service: see the list row above.
      subtitle: IgnorePointer(
        ignoring: true,
        child: ClickableArtistName(
          artistName: item.artistName,
          coverUrl: item.coverUrl,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: colorScheme.onSurfaceVariant),
        ),
      ),
    );
  }
}

/// A selected song starts a group drag; dropping on another song moves the
/// group immediately before that song after confirmation.
Future<List<String>?> resolveManualLibraryDragIds(
  LibraryPlaylistDragBatch batch,
) async {
  final result = await batch.result;
  if (result.failed || result.items.isEmpty) return null;
  return List.unmodifiable(result.items.map((item) => item.id));
}

Future<bool> writeManualLibraryMove({
  required List<String> selected,
  required Future<void> Function(List<String>) write,
  required bool Function() ownsSelection,
}) async {
  await write(List.unmodifiable(selected));
  return ownsSelection();
}

class ManualLibraryDragRow extends StatefulWidget {
  const ManualLibraryDragRow({
    super.key,
    required this.id,
    required this.selected,
    required this.canAccept,
    required this.dragLabel,
    required this.onDropBefore,
    required this.child,
    this.registry,
    this.target,
  });

  final String id;
  final bool selected;
  final bool canAccept;
  final String dragLabel;
  final ValueChanged<LibraryPlaylistDragBatch> onDropBefore;
  final Widget child;
  final Set<_ManualLibraryDragRowState>? registry;
  final ValueListenable<_ManualLibraryDragRowState?>? target;

  @override
  State<ManualLibraryDragRow> createState() => _ManualLibraryDragRowState();
}

class _ManualLibraryDragRowState extends State<ManualLibraryDragRow> {
  @override
  void initState() {
    super.initState();
    widget.registry?.add(this);
  }

  @override
  void didUpdateWidget(ManualLibraryDragRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.registry != widget.registry) {
      oldWidget.registry?.remove(this);
      widget.registry?.add(this);
    }
  }

  @override
  void dispose() {
    widget.registry?.remove(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DragTarget<LibraryPlaylistDragBatch>(
      onWillAcceptWithDetails: (_) => widget.canAccept,
      onAcceptWithDetails: (details) {
        if (widget.registry == null) widget.onDropBefore(details.data);
      },
      builder: (context, candidates, rejected) {
        Widget decorate(bool active) => DecoratedBox(
          decoration: BoxDecoration(
            border: !active
                ? null
                : Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.primary,
                      width: 3,
                    ),
                  ),
          ),
          child: widget.child,
        );
        final target = widget.target;
        if (target == null) return decorate(candidates.isNotEmpty);
        return ValueListenableBuilder<_ManualLibraryDragRowState?>(
          valueListenable: target,
          builder: (context, value, child) => decorate(identical(value, this)),
        );
      },
    );
  }
}

/// The desktop Songs table rows of one song list, with the inputs they were
/// built from.
class _LibrarySongTableRows {
  const _LibrarySongTableRows({
    required this.items,
    required this.qualityMode,
    required this.colorScheme,
    required this.rows,
    required this.rowByItem,
    required this.byId,
  });

  final List<UnifiedLibraryItem> items;
  final String qualityMode;
  final ColorScheme colorScheme;
  final List<TrackTableRow> rows;
  final Map<UnifiedLibraryItem, TrackTableRow> rowByItem;
  final Map<String, UnifiedLibraryItem> byId;
}
