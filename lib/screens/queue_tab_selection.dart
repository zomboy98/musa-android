part of 'queue_tab.dart';

extension _QueueTabSelectionActions on _QueueTabState {
  bool _canAcceptManualDrop(String id) =>
      _isSelectionMode &&
      !_selectedIds.contains(id) &&
      !(_activeLibraryDragBatch?.containsId(id) ?? false);

  Widget _buildPlaylistCompatibleDragSource(
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> items,
    Widget child,
    ColorScheme colors,
  ) {
    final batch = LibraryPlaylistDragBatch();
    return Builder(
      builder: (sourceContext) =>
          LibraryPlaylistDragSource<LibraryPlaylistDragBatch>(
            data: batch,
            enabled: !_isDraggingLibraryTrack,
            onSelect: () {
              if (_activeLibraryDragBatch != null &&
                  !identical(batch, _activeLibraryDragBatch)) {
                // A second recognizer may start before the first rebuild disables
                // other sources. Its feedback and any native target must have a
                // safe, empty batch, without changing the active selection.
                batch.freeze(const [], (_) async => const []);
                return;
              }
              _selectDraggedTrack(item, items);
              if (!_isDraggingLibraryTrack) return;
              batch.freeze(
                _selectedIds,
                (ids) => ref.read(libraryDirectoryItemsLoaderProvider)([
                  for (final id in ids)
                    LibraryDirectoryTrack(
                      source: id.startsWith('local_') ? 'local' : 'downloaded',
                      id: id.substring(id.startsWith('local_') ? 6 : 3),
                      fileName: '',
                    ),
                ]),
                selectionToken: _librarySelectionToken,
              );
            },
            onDragStarted: () {
              if (_activeLibraryDragBatch != null) {
                // Suppress the rejected recognizer's native playlist drop too.
                _manualDragBatches[batch] = true;
                return;
              }
              _startLibraryTrackDrag(batch);
              if (_sortMode == 'manual') {
                _manualDragBatches[batch] = true;
                _manualDragScrollable = Scrollable.maybeOf(sourceContext);
              }
            },
            onDragEnd: () => _endLibraryTrackDrag(batch),
            onDragSourceDisposed: () => _abandonLibraryDrag(batch),
            onAmbiguousRelease: () {
              if (!mounted ||
                  _manualDragBatches[batch] != true ||
                  !identical(batch, _activeLibraryDragBatch))
                return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(context.l10n.queueDragFingerUnknown)),
              );
            },
            onDragUpdate: (details) {
              if (identical(batch, _activeLibraryDragBatch)) {
                _updateManualDrag(details.globalPosition);
              }
            },
            onPointerRelease: (position) {
              if (identical(batch, _activeLibraryDragBatch)) {
                _releaseManualDrag(position, batch);
              }
            },
            feedbackBuilder: (context) =>
                FutureBuilder<LibraryPlaylistDragResult>(
                  future: batch.result,
                  builder: (context, snapshot) =>
                      snapshot.hasData &&
                          !snapshot.data!.failed &&
                          snapshot.data!.items.isNotEmpty
                      ? _buildDragFeedback(
                          context,
                          snapshot.data!.items,
                          colors,
                        )
                      : Material(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: snapshot.hasData
                                ? const Icon(Icons.error_outline)
                                : const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                          ),
                        ),
                ),
            child: child,
          ),
    );
  }

  void _selectDraggedTrack(
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> visibleItems,
  ) {
    // Holding an already-selected track drags the existing batch without
    // extending the range back to the selection anchor.
    if (_isSelectionMode && _selectedIds.contains(item.id)) return;
    if (_isSelectionMode) {
      _selectRangeTo(item.id, visibleItems);
    } else {
      _enterSelectionMode(item.id);
    }
  }

  void _startLibraryTrackDrag(LibraryPlaylistDragBatch batch) {
    _activeLibraryDragBatch = batch;
    _librarySelectionToken = Object();
    _setState(() => _isDraggingLibraryTrack = true);
    _hideSelectionOverlay();
  }

  void _abandonLibraryDrag(LibraryPlaylistDragBatch batch) {
    if (!identical(batch, _activeLibraryDragBatch)) return;
    _manualDragTimer?.cancel();
    _manualDragTimer = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _endLibraryTrackDrag(batch);
    });
  }

  void _endLibraryTrackDrag(LibraryPlaylistDragBatch batch) {
    if (!identical(batch, _activeLibraryDragBatch)) return;
    _activeLibraryDragBatch = null;
    _manualDragTimer?.cancel();
    _manualDragTimer = null;
    _manualDragScrollable = null;
    _manualDragPosition = null;
    if (!mounted) return;
    _manualDropTarget.value = null;
    _manualPlaylistTarget.value = null;
    _setState(() => _isDraggingLibraryTrack = false);
  }

  Rect? _manualViewport() {
    final scrollable = _manualDragScrollable;
    if (scrollable == null || !scrollable.mounted) return null;
    final box = scrollable.context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _updateManualDrag(Offset position) {
    _manualDragPosition = position;
    if (_manualDragScrollable == null) return;
    _scheduleManualTargetUpdate();
    _manualDragTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final scrollable = _manualDragScrollable;
      final viewport = _manualViewport();
      final point = _manualDragPosition;
      if (scrollable == null ||
          viewport == null ||
          point == null ||
          point.dx < viewport.left ||
          point.dx > viewport.right)
        return;
      const edge = 72.0;
      double speed = 0;
      if (point.dy >= viewport.top && point.dy < viewport.top + edge) {
        speed = -((viewport.top + edge - point.dy) / edge).clamp(0.0, 1.0);
      } else if (point.dy <= viewport.bottom &&
          point.dy > viewport.bottom - edge) {
        speed = ((point.dy - viewport.bottom + edge) / edge).clamp(0.0, 1.0);
      }
      if (speed == 0 || !scrollable.position.hasContentDimensions) return;
      final scroll = scrollable.position;
      final next = (scroll.pixels + speed * 14).clamp(
        scroll.minScrollExtent,
        scroll.maxScrollExtent,
      );
      if (next != scroll.pixels) {
        scroll.jumpTo(next);
        _scheduleManualTargetUpdate();
      }
    });
  }

  void _scheduleManualTargetUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_isDraggingLibraryTrack) return;
      final position = _manualDragPosition;
      _manualDropTarget.value = position == null
          ? null
          : _manualRowAt(position);
      _manualPlaylistTarget.value = position == null
          ? null
          : _manualPlaylistAt(position);
    });
  }

  _ManualLibraryDragRowState? _manualRowAt(Offset position) {
    final viewport = _manualViewport();
    if (viewport == null || !viewport.contains(position)) return null;
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(
      hit,
      position,
      View.of(context).viewId,
    );
    for (final row in _manualDragRows.toList()) {
      if (!row.mounted || !row.widget.canAccept) continue;
      final box = row.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      if ((box.localToGlobal(Offset.zero) & box.size).contains(position) &&
          hit.path.any((entry) => identical(entry.target, box))) {
        return row;
      }
    }
    return null;
  }

  _ManualPlaylistDropRegistrationState? _manualPlaylistAt(Offset position) {
    final viewport = _manualViewport();
    if (viewport != null && viewport.contains(position)) {
      final hit = HitTestResult();
      WidgetsBinding.instance.hitTestInView(
        hit,
        position,
        View.of(context).viewId,
      );
      for (final target in _manualPlaylistTargets.toList()) {
        if (!target.mounted || !target.widget.canAccept) continue;
        final box = target.context.findRenderObject();
        if (box is RenderBox &&
            box.attached &&
            box.hasSize &&
            (box.localToGlobal(Offset.zero) & box.size).contains(position) &&
            hit.path.any((entry) => identical(entry.target, box))) {
          return target;
        }
      }
    }
    return null;
  }

  void _releaseManualDrag(Offset position, LibraryPlaylistDragBatch batch) {
    _manualDragPosition = position;
    final playlist = _manualPlaylistAt(position);
    if (playlist != null) {
      playlist.widget.onDrop(batch);
    } else {
      _manualRowAt(position)?.widget.onDropBefore(batch);
    }
  }

  void _enterSelectionMode(String itemId) {
    _librarySelectionToken = Object();
    HapticFeedback.mediumImpact();
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
      _isSelectionMode = true;
      _selectedIds.add(itemId);
      _selectionAnchorId = itemId;
    });
    _hidePlaylistSelectionOverlay();
  }

  void _exitSelectionMode() {
    _librarySelectionToken = Object();
    _setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _resolvedSelectionItems = const [];
      _selectionAnchorId = null;
    });
    _hideSelectionOverlay();
  }

  void _toggleSelection(String itemId) {
    _librarySelectionToken = Object();
    var shouldHideOverlay = false;
    _setState(() {
      _selectionAnchorId = toggleOrderedSelection(
        selected: _selectedIds,
        target: itemId,
      );
      if (_selectedIds.isEmpty) {
        _isSelectionMode = false;
        shouldHideOverlay = true;
      }
    });
    if (shouldHideOverlay) {
      _hideSelectionOverlay();
    }
  }

  _QueueLibraryPageRequest get _selectionQuery => _QueueLibraryPageRequest(
    filterMode:
        widget.librarySection ?? ref.read(settingsProvider).historyFilterMode,
    limit: _QueueTabState._libraryPageSize,
    offset: 0,
    searchQuery: _searchQuery,
    filterSource: _filterSource,
    filterQuality: _filterQuality,
    filterFormat: _filterFormat,
    filterMetadata: _filterMetadata,
    sortMode: _sortMode,
    localLibraryEnabled: ref.read(settingsProvider).localLibraryEnabled,
  );

  bool get _allQuerySelected =>
      _querySelection.covers(_selectionQuery, _selectedIds);

  Future<List<UnifiedLibraryItem>?> _resolveSelectionItems(
    List<UnifiedLibraryItem> visible,
  ) async {
    final selected = _selectedIds.toList(growable: false);
    final token = _librarySelectionToken;
    final query = _selectionQuery;
    bool isCurrent() =>
        mounted &&
        identical(token, _librarySelectionToken) &&
        query == _selectionQuery &&
        setEquals(selected.toSet(), _selectedIds);
    try {
      final resolved = await resolveLibrarySelectionItems(
        selectedIds: selected,
        // Always reload at action time: cached/displayed rows can retain an old
        // file path after relinking, removal, or a library rescan.
        load: () => ref.read(libraryDirectoryItemsLoaderProvider)([
          for (final id in selected)
            LibraryDirectoryTrack(
              source: id.startsWith('local_') ? 'local' : 'downloaded',
              id: id.substring(id.startsWith('local_') ? 6 : 3),
              fileName: '',
            ),
        ]),
        idOf: (item) => item.id,
        isCurrent: isCurrent,
      );
      if (resolved == null) return null;
      _setState(() => _resolvedSelectionItems = resolved);
      return resolved;
    } catch (_) {
      if (mounted && isCurrent()) {
        showAppSnackBar(
          context,
          content: Text(context.l10n.queueLoadSelectedFailed),
        );
      }
      return null;
    }
  }

  Future<void> _selectAll(List<UnifiedLibraryItem> items) async {
    final query = _selectionQuery;
    final token = Object();
    _librarySelectionToken = token;
    bool isCurrent() =>
        mounted &&
        identical(token, _librarySelectionToken) &&
        query == _selectionQuery;
    try {
      final ids = await _querySelection.resolve(
        scope: query,
        load: () => ref.read(libraryQueryIdsLoaderProvider)(query.toDbQuery()),
        isCurrent: isCurrent,
      );
      if (ids == null || !mounted) return;
      _setState(() {
        _isPlaylistSelectionMode = false;
        _selectedPlaylistIds.clear();
        _selectedIds
          ..clear()
          ..addAll(ids);
        _resolvedSelectionItems = const [];
        _isSelectionMode = ids.isNotEmpty;
        _selectionAnchorId = items.lastOrNull?.id;
      });
      _hidePlaylistSelectionOverlay();
      _syncSelectionOverlay(
        items: items,
        bottomPadding: MediaQuery.paddingOf(context).bottom,
      );
    } catch (_) {
      if (!mounted || !isCurrent()) return;
      showAppSnackBar(
        context,
        content: Text(context.l10n.queueSelectAllFailed),
      );
    }
  }

  /// A desktop click of [kind] on a library song; [orderedIds] lists the
  /// songs in the order shown.
  void _applyDesktopClick(
    String itemId,
    DesktopClick kind,
    List<String> orderedIds,
  ) {
    _librarySelectionToken = Object();
    var shouldHideOverlay = false;
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
      _selectionAnchorId = applyDesktopClickTo(
        _selectedIds,
        target: itemId,
        kind: kind,
        orderedIds: orderedIds,
        anchor: _selectionAnchorId,
      );
      _isSelectionMode = _selectedIds.isNotEmpty;
      shouldHideOverlay = !_isSelectionMode;
    });
    _hidePlaylistSelectionOverlay();
    if (shouldHideOverlay) _hideSelectionOverlay();
  }

  /// Opens the desktop menu of a library song. A song outside the selection
  /// becomes the selection for this menu only, so the menu acts on the song
  /// clicked: the selection toolbar does not open under the menu, and the
  /// selection ends if the menu closes without a choice.
  Future<void> _showLibraryItemMenu(
    BuildContext context,
    UnifiedLibraryItem item,
    List<UnifiedLibraryItem> libraryItems,
    Offset position, {
    VoidCallback? onOpenDetails,
  }) async {
    final forMenu = !_selectedIds.contains(item.id);
    if (forMenu) {
      _contextMenuSelection = true;
      _applyDesktopClick(item.id, DesktopClick.replace, const []);
      _hideSelectionOverlay();
    }
    final selectedItems = await _resolveSelectionItems(libraryItems);
    if (selectedItems == null || !mounted || !context.mounted) {
      if (mounted) _setState(() => _contextMenuSelection = false);
      return;
    }
    final chosen = await showContextMenu(
      context,
      position: position,
      groups: libraryTrackMenuGroups(
        context,
        ref,
        items: selectedItems,
        onPlay: () => _playLibraryItem(item, libraryItems),
        onOpenDetails: onOpenDetails,
        onDone: _exitSelectionMode,
        onReEnrich: () => _reEnrichSelectedFromQueue(libraryItems),
        onConvert: () => _showBatchConvertSheet(this.context, libraryItems),
        onDelete: () => _deleteSelected(libraryItems),
      ),
    );
    if (!forMenu || !mounted) return;
    // A bulk action (re-enrich, convert, delete) kept the selection and
    // shows the toolbar again.
    _setState(() => _contextMenuSelection = false);
    if (!chosen) _exitSelectionMode();
  }

  void _selectRangeTo(String itemId, List<UnifiedLibraryItem> visibleItems) {
    _librarySelectionToken = Object();
    HapticFeedback.selectionClick();
    _setState(() {
      _isSelectionMode = true;
      _selectionAnchorId = addOrderedSelectionRange(
        selected: _selectedIds,
        visibleItems: visibleItems
            .map((item) => item.id)
            .toList(growable: false),
        target: itemId,
        anchor: _selectionAnchorId,
      );
    });
  }

  void _hideSelectionOverlay() {
    _selectionOverlay.hide();
  }

  void _syncSelectionOverlay({
    required List<UnifiedLibraryItem> items,
    required double bottomPadding,
  }) {
    if (!mounted) return;
    if (_suppressSelectionOverlay ||
        _contextMenuSelection ||
        _isDraggingLibraryTrack ||
        !_isSelectionMode ||
        _isPlaylistSelectionMode) {
      _hideSelectionOverlay();
      return;
    }

    _selectionOverlayItems = items;
    _selectionOverlayBottomPadding = bottomPadding;
    _selectionOverlay.show(
      context,
      (_) => _buildSelectionBottomBar(
        context,
        Theme.of(context).colorScheme,
        _selectionOverlayItems,
        _selectionOverlayBottomPadding,
      ),
    );
  }

  void _hidePlaylistSelectionOverlay() {
    _playlistSelectionOverlay.hide();
  }

  void _syncPlaylistSelectionOverlay({
    required List<UserPlaylistCollection> playlists,
    required double bottomPadding,
  }) {
    if (!mounted) return;
    if (_suppressSelectionOverlay ||
        !_isPlaylistSelectionMode ||
        _isSelectionMode) {
      _hidePlaylistSelectionOverlay();
      return;
    }

    _playlistSelectionOverlayItems = playlists;
    _playlistSelectionOverlayBottomPadding = bottomPadding;
    _playlistSelectionOverlay.show(
      context,
      (_) => _buildPlaylistSelectionBottomBar(
        context,
        Theme.of(context).colorScheme,
        _playlistSelectionOverlayItems,
        _playlistSelectionOverlayBottomPadding,
      ),
    );
  }

  void _enterPlaylistSelectionMode(String playlistId) {
    _librarySelectionToken = Object();
    HapticFeedback.mediumImpact();
    _setState(() {
      _isSelectionMode = false;
      _selectedIds.clear();
      _selectionAnchorId = null;
      _isPlaylistSelectionMode = true;
      _selectedPlaylistIds.add(playlistId);
    });
    _hideSelectionOverlay();
  }

  void _exitPlaylistSelectionMode() {
    _setState(() {
      _isPlaylistSelectionMode = false;
      _selectedPlaylistIds.clear();
    });
    _hidePlaylistSelectionOverlay();
  }

  void _togglePlaylistSelection(String playlistId) {
    var shouldHideOverlay = false;
    _setState(() {
      if (_selectedPlaylistIds.contains(playlistId)) {
        _selectedPlaylistIds.remove(playlistId);
        if (_selectedPlaylistIds.isEmpty) {
          _isPlaylistSelectionMode = false;
          shouldHideOverlay = true;
        }
      } else {
        _selectedPlaylistIds.add(playlistId);
      }
    });
    if (shouldHideOverlay) {
      _hidePlaylistSelectionOverlay();
    }
  }

  void _selectAllPlaylists(List<UserPlaylistCollection> playlists) {
    _setState(() {
      _selectedPlaylistIds.addAll(playlists.map((e) => e.id));
    });
  }

  Future<void> _downloadAllSelectedPlaylists(BuildContext context) async {
    final collectionsState = ref.read(libraryCollectionsProvider);
    var selectedPlaylists = collectionsState.playlists
        .where((p) => _selectedPlaylistIds.contains(p.id))
        .toList();

    final totalTracks = selectedPlaylists.fold<int>(
      0,
      (sum, p) => sum + p.trackCount,
    );

    if (totalTracks == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.snackbarSelectedPlaylistsEmpty)),
      );
      return;
    }

    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.dialogDownloadAllTitle,
      message: context.l10n.dialogDownloadPlaylistsMessage(
        totalTracks,
        selectedPlaylists.length,
      ),
      confirmLabel: context.l10n.dialogDownload,
    );

    if (!confirmed || !context.mounted) return;

    await ref
        .read(libraryCollectionsProvider.notifier)
        .ensurePlaylistsLoaded(
          selectedPlaylists.map((playlist) => playlist.id),
        );
    if (!context.mounted) return;
    selectedPlaylists = ref
        .read(libraryCollectionsProvider)
        .playlists
        .where((playlist) => _selectedPlaylistIds.contains(playlist.id))
        .toList(growable: false);

    final settings = ref.read(settingsProvider);
    final extensionState = ref.read(extensionProvider);
    final queueNotifier = ref.read(downloadQueueProvider.notifier);

    bool enqueueAll() {
      final svc = resolveConfiguredDownloadService(
        settings.defaultService,
        extensionState,
        autoFallback: settings.autoFallback,
      );
      if (svc.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                noDownloadProviderMessage(
                  context.l10n,
                  noDownloadProviderCause(extensionState),
                ),
              ),
            ),
          );
        }
        return false;
      }
      queueNotifier.addBatchesToQueue([
        for (final playlist in selectedPlaylists)
          DownloadQueueBatch(
            tracks: playlist.tracks.map((entry) => entry.track).toList(),
            playlistName: playlist.name,
          ),
      ], svc);
      return true;
    }

    if (enqueueAll()) {
      _exitPlaylistSelectionMode();
    }
  }

  Future<void> _deleteSelectedPlaylists(BuildContext context) async {
    final count = _selectedPlaylistIds.length;
    final confirmed = await showAppConfirmDialog(
      context,
      title: context.l10n.collectionDeletePlaylist,
      message: context.l10n.collectionDeletePlaylistsMessage(count),
      confirmLabel: context.l10n.dialogDelete,
      destructive: true,
      cancelIsDefault: true,
      confirmStyle: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );

    if (!confirmed || !context.mounted) return;

    final notifier = ref.read(libraryCollectionsProvider.notifier);
    await notifier.deletePlaylists(_selectedPlaylistIds);

    if (!context.mounted) return;
    _exitPlaylistSelectionMode();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.l10n.collectionPlaylistsDeleted(count))),
    );
  }

  Widget _buildPlaylistSelectionBottomBar(
    BuildContext context,
    ColorScheme colorScheme,
    List<UserPlaylistCollection> playlists,
    double bottomPadding,
  ) {
    final selectedCount = _selectedPlaylistIds.length;
    final allSelected =
        selectedCount == playlists.length && playlists.isNotEmpty;

    return SelectionBottomBar(
      selectedCount: selectedCount,
      allSelected: allSelected,
      onClose: _exitPlaylistSelectionMode,
      onToggleSelectAll: () {
        if (allSelected) {
          _exitPlaylistSelectionMode();
        } else {
          _selectAllPlaylists(playlists);
        }
      },
      bottomPadding: bottomPadding,
      allSelectedLabel: context.l10n.selectionAllPlaylistsSelected,
      tapToSelectLabel: context.l10n.selectionTapPlaylistsToSelect,
      children: [
        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0
                ? () => _downloadAllSelectedPlaylists(context)
                : null,
            icon: const Icon(Icons.download_rounded),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.primary
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onPrimary
                  : colorScheme.onSurfaceVariant,
              padding: EdgeInsets.symmetric(
                vertical: isDesktopPlatform ? 8 : 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              selectedCount > 0
                  ? context.l10n.bulkDownloadPlaylistsButton(selectedCount)
                  : context.l10n.bulkDownloadSelectPlaylists,
            ),
          ),
        ),

        const SizedBox(height: 8),

        SizedBox(
          width: double.infinity,
          child: ExpressiveButton(
            onPressed: selectedCount > 0
                ? () => _deleteSelectedPlaylists(context)
                : null,
            icon: const Icon(Icons.delete_outline),
            style: FilledButton.styleFrom(
              backgroundColor: selectedCount > 0
                  ? colorScheme.error
                  : colorScheme.surfaceContainerHighest,
              foregroundColor: selectedCount > 0
                  ? colorScheme.onError
                  : colorScheme.onSurfaceVariant,
              padding: EdgeInsets.symmetric(
                vertical: isDesktopPlatform ? 8 : 16,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            child: Text(
              selectedCount > 0
                  ? context.l10n.selectionDeletePlaylistsCount(selectedCount)
                  : context.l10n.selectionSelectPlaylistsToDelete,
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _deleteSelected(List<UnifiedLibraryItem> allItems) async {
    final selected = await _resolveSelectionItems(allItems);
    if (selected == null || !mounted) return;
    await deleteLibraryTracks(
      context,
      ref,
      selected,
      isActive: () => mounted,
      onComplete: _exitSelectionMode,
    );
  }

  String _cleanFilePath(String? filePath) {
    return DownloadedEmbeddedCoverResolver.cleanFilePath(filePath);
  }

  Future<int?> _readFileModTimeMillis(String? filePath) async {
    return DownloadedEmbeddedCoverResolver.readFileModTimeMillis(filePath);
  }
}
