import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/theme/app_tokens.dart';
import 'package:mornye/utils/adaptive_layout.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/track_card.dart';

/// Editing has its own drag gestures, leaving normal track selection intact.
class CollectionReorderSliver extends StatefulWidget {
  const CollectionReorderSliver({
    super.key,
    required this.entries,
    required this.onReorder,
    required this.onDraggingChanged,
    this.onReorderGroup,
    this.initialSelectedKeys = const {},
    this.onSelectionChanged,
    this.enabled = true,
  });

  final List<CollectionTrackEntry> entries;
  final void Function(int oldIndex, int newIndex) onReorder;
  final ValueChanged<bool> onDraggingChanged;
  final bool enabled;
  final Set<String> initialSelectedKeys;
  final ValueChanged<Set<String>>? onSelectionChanged;
  final ValueChanged<List<CollectionTrackEntry>>? onReorderGroup;

  @override
  State<CollectionReorderSliver> createState() =>
      _CollectionReorderSliverState();
}

class _CollectionReorderSliverState extends State<CollectionReorderSliver> {
  int? _dragStartIndex;
  final _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _selected.addAll(
      widget.initialSelectedKeys.intersection(
        widget.entries.map((entry) => entry.key).toSet(),
      ),
    );
  }

  @override
  void didUpdateWidget(covariant CollectionReorderSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    _selected.retainAll(widget.entries.map((entry) => entry.key).toSet());
  }

  void _moveGroup(bool down) {
    if (!_canMoveGroup(down)) return;
    final next = [...widget.entries];
    // Swap each selected occurrence with its adjacent unselected occurrence.
    // Iterate backwards when moving down so each row moves exactly one place.
    final indices = down
        ? List.generate(next.length - 1, (i) => next.length - 2 - i)
        : List.generate(next.length - 1, (i) => i + 1);
    for (final i in indices) {
      final adjacent = down ? i + 1 : i - 1;
      if (_selected.contains(next[i].key) &&
          !_selected.contains(next[adjacent].key)) {
        final entry = next[i];
        next[i] = next[adjacent];
        next[adjacent] = entry;
      }
    }
    widget.onReorderGroup?.call(next);
  }

  void _finishDragging() {
    if (!mounted) return;
    setState(() => _dragStartIndex = null);
    widget.onDraggingChanged(false);
  }

  bool _movesGroup(int index) =>
      widget.onReorderGroup != null &&
      _selected.contains(widget.entries[index].key);

  bool _canMove(int index, bool down) {
    if (!widget.enabled || _dragStartIndex != null) return false;
    if (!_movesGroup(index)) {
      return down ? index < widget.entries.length - 1 : index > 0;
    }
    return _canMoveGroup(down);
  }

  bool _canMoveGroup(bool down) {
    if (widget.onReorderGroup == null ||
        !widget.enabled ||
        _dragStartIndex != null ||
        _selected.isEmpty) {
      return false;
    }
    for (var i = 0; i < widget.entries.length; i++) {
      final adjacent = down ? i + 1 : i - 1;
      if (adjacent >= 0 &&
          adjacent < widget.entries.length &&
          _selected.contains(widget.entries[i].key) &&
          !_selected.contains(widget.entries[adjacent].key)) {
        return true;
      }
    }
    return false;
  }

  void _move(int index, bool down) {
    if (!_canMove(index, down)) return;
    if (_movesGroup(index)) {
      _moveGroup(down);
    } else {
      widget.onReorder(index, down ? index + 1 : index - 1);
    }
  }

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: EdgeInsets.symmetric(horizontal: wideListInset(context)),
    sliver: SliverMainAxisGroup(
      slivers: [
        if (widget.onReorderGroup != null)
          PinnedHeaderSliver(
            child: Material(
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.l10n.selectionSelected(_selected.length),
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('collection-order-group-up'),
                    tooltip: context.l10n.queueMoveUp,
                    onPressed: _canMoveGroup(false)
                        ? () => _moveGroup(false)
                        : null,
                    icon: const Icon(Icons.arrow_upward),
                  ),
                  IconButton(
                    key: const ValueKey('collection-order-group-down'),
                    tooltip: context.l10n.queueMoveDown,
                    onPressed: _canMoveGroup(true)
                        ? () => _moveGroup(true)
                        : null,
                    icon: const Icon(Icons.arrow_downward),
                  ),
                ],
              ),
            ),
          ),
        SliverReorderableList(
          itemCount: widget.entries.length,
          proxyDecorator: (child, index, animation) => Material(
            elevation: 6,
            child: Stack(
              children: [
                child,
                if (_selected.contains(widget.entries[index].key) &&
                    _selected.length > 1)
                  Positioned(
                    right: 48,
                    top: 0,
                    child: Badge(label: Text('${_selected.length}')),
                  ),
              ],
            ),
          ),
          onReorderItem: (oldIndex, newIndex) {
            if (_selected.contains(widget.entries[oldIndex].key) &&
                widget.onReorderGroup != null) {
              final boundary = newIndex > oldIndex ? newIndex + 1 : newIndex;
              final moving = widget.entries
                  .where((e) => _selected.contains(e.key))
                  .toList();
              final remaining = widget.entries
                  .where((e) => !_selected.contains(e.key))
                  .toList();
              final insertion = widget.entries
                  .take(boundary)
                  .where((e) => !_selected.contains(e.key))
                  .length;
              remaining.insertAll(insertion, moving);
              widget.onReorderGroup!(remaining);
            } else {
              widget.onReorder(oldIndex, newIndex);
            }
            _finishDragging();
          },
          onReorderStart: (index) {
            setState(() => _dragStartIndex = index);
            HapticFeedback.selectionClick();
            widget.onDraggingChanged(true);
          },
          onReorderEnd: (index) {
            final start = _dragStartIndex;
            if (start == null) return;
            final destination = index > start ? index - 1 : index;
            // Changed drops commit after the proxy finishes returning to its row.
            if (destination == start) _finishDragging();
          },
          itemBuilder: (context, index) {
            final entry = widget.entries[index];
            final track = entry.track;
            final size = context.tokens.coverCompact;
            return ReorderableDelayedDragStartListener(
              key: ValueKey(entry.key),
              enabled: widget.enabled,
              index: index,
              child: Listener(
                onPointerCancel: (_) {
                  if (_dragStartIndex == index) _finishDragging();
                },
                child: Semantics(
                  customSemanticsActions: {
                    if (_canMove(index, false))
                      CustomSemanticsAction(
                        label: context.l10n.queueMoveUp,
                      ): () =>
                          _move(index, false),
                    if (_canMove(index, true))
                      CustomSemanticsAction(
                        label: context.l10n.queueMoveDown,
                      ): () =>
                          _move(index, true),
                  },
                  child: TrackCard(
                    style: TrackCardStyle.flat,
                    leadingArtwork: true,
                    isSelected: _selected.contains(entry.key),
                    leading: widget.onReorderGroup != null
                        ? Checkbox(
                            semanticLabel: '${track.name}, ${track.artistName}',
                            key: ValueKey(
                              'collection-order-select-${entry.key}',
                            ),
                            value: _selected.contains(entry.key),
                            onChanged: widget.enabled && _dragStartIndex == null
                                ? (value) => setState(() {
                                    if (value == true) {
                                      _selected.add(entry.key);
                                    } else {
                                      _selected.remove(entry.key);
                                    }
                                    widget.onSelectionChanged?.call(
                                      Set.of(_selected),
                                    );
                                  })
                                : null,
                          )
                        : ClipRRect(
                            borderRadius: context.tokens.borderRadiusThumb,
                            child: track.coverUrl?.isNotEmpty == true
                                ? LocalOrNetworkCoverImage(
                                    url: track.coverUrl!,
                                    width: size,
                                    height: size,
                                    networkCacheWidth: (size * 2).toInt(),
                                    placeholder: (_) =>
                                        TrackCoverPlaceholder(size: size),
                                  )
                                : TrackCoverPlaceholder(size: size),
                          ),
                    title: track.name,
                    subtitle: Text(
                      track.artistName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: ReorderableDragStartListener(
                      enabled: widget.enabled,
                      index: index,
                      child: SizedBox.square(
                        key: ValueKey('collection-order-handle-${entry.key}'),
                        dimension: context.tokens.minTouchTarget,
                        child: AppIcon.adaptive(
                          Icons.drag_handle,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ],
    ),
  );
}
