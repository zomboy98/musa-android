import 'dart:io' show File;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/track_actions.dart';

/// Row height shared by every list row of the song menu.
const double trackActionRowHeight = 52;

/// Diameter of the round quick-action buttons.
const double trackActionQuickSize = 52;

/// Cover, title and artist of the song a menu acts on: one line each.
///
/// The cover has a fixed size and no fade, so it never changes the layout or
/// flashes when it arrives.
class TrackActionHeader extends StatelessWidget {
  const TrackActionHeader({
    super.key,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.coverSize = 48,
    this.padding = const EdgeInsets.fromLTRB(20, 4, 20, 12),
  });

  final String title;
  final String artist;
  final String? coverUrl;
  final double coverSize;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final url = coverUrl;
    final placeholder = Container(
      width: coverSize,
      height: coverSize,
      color: scheme.surfaceContainerHighest,
      child: AppIcon(
        Icons.music_note,
        size: coverSize * 0.45,
        color: scheme.onSurfaceVariant,
      ),
    );
    return Padding(
      padding: padding,
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: url == null || url.isEmpty
                ? placeholder
                : url.startsWith('file:')
                ? Image.file(
                    File.fromUri(Uri.parse(url)),
                    width: coverSize,
                    height: coverSize,
                    fit: BoxFit.cover,
                    cacheWidth: (coverSize * 3).round(),
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => placeholder,
                  )
                : CachedNetworkImage(
                    imageUrl: url,
                    width: coverSize,
                    height: coverSize,
                    fit: BoxFit.cover,
                    memCacheWidth: (coverSize * 3).round(),
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    placeholderFadeInDuration: Duration.zero,
                    cacheManager: CoverCacheManager.instance,
                    placeholder: (_, _) => placeholder,
                    errorWidget: (_, _, _) => placeholder,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The song menu as a Material bottom sheet: header, round quick actions and
/// a plain list. The chosen action closes the sheet with its id, once.
class TrackActionsSheet extends StatefulWidget {
  const TrackActionsSheet({
    super.key,
    required this.menu,
    required this.title,
    required this.artist,
    this.coverUrl,
  });

  final TrackActionMenu menu;
  final String title;
  final String artist;
  final String? coverUrl;

  @override
  State<TrackActionsSheet> createState() => _TrackActionsSheetState();
}

class _TrackActionsSheetState extends State<TrackActionsSheet> {
  bool _picked = false;

  void _pick(TrackAction action) {
    if (_picked || !action.enabled) return;
    _picked = true;
    Navigator.of(context).pop(action.id);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final menu = widget.menu;
    final divider = Divider(
      height: 1,
      thickness: 1,
      indent: 20,
      endIndent: 20,
      color: scheme.outlineVariant.withValues(alpha: 0.5),
    );
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.82,
        ),
        child: RepaintBoundary(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const AppSheetHandle(),
                TrackActionHeader(
                  title: widget.title,
                  artist: widget.artist,
                  coverUrl: widget.coverUrl,
                ),
                if (menu.quick.isNotEmpty) ...[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    child: Row(
                      children: [
                        for (final action in menu.quick)
                          Expanded(
                            child: TrackQuickActionButton(
                              action: action,
                              onPressed: () => _pick(action),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (menu.groups.isNotEmpty) divider,
                ],
                for (var i = 0; i < menu.groups.length; i++) ...[
                  if (i > 0) divider,
                  for (final action in menu.groups[i])
                    TrackActionRow(
                      action: action,
                      onPressed: () => _pick(action),
                    ),
                ],
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A round shortcut with its label underneath.
class TrackQuickActionButton extends StatelessWidget {
  const TrackQuickActionButton({
    super.key,
    required this.action,
    required this.onPressed,
  });

  final TrackAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = action.enabled;
    final background = action.selected
        ? scheme.primaryContainer
        : scheme.surfaceContainerHighest;
    final foreground = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : action.selected
        ? scheme.onPrimaryContainer
        : scheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: action.selected,
      label: action.label,
      excludeSemantics: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: enabled ? onPressed : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: trackActionQuickSize,
                  height: trackActionQuickSize,
                  decoration: BoxDecoration(
                    color: background,
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: AppIcon(action.icon, size: 24, color: foreground),
                ),
                const SizedBox(height: 6),
                Text(
                  action.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One list row: icon and text on a 52 dp line.
class TrackActionRow extends StatelessWidget {
  const TrackActionRow({
    super.key,
    required this.action,
    required this.onPressed,
  });

  final TrackAction action;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = action.enabled;
    final color = !enabled
        ? scheme.onSurface.withValues(alpha: 0.38)
        : action.destructive
        ? scheme.error
        : scheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      selected: action.selected,
      excludeSemantics: true,
      label: action.label,
      child: InkWell(
        onTap: enabled ? onPressed : null,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: trackActionRowHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: AppIcon(
                    action.icon,
                    size: 24,
                    color: action.selected && enabled ? scheme.primary : color,
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        action.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: color,
                        ),
                      ),
                      if (action.subtitle != null)
                        Text(
                          action.subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The song menu as a Mornye popover: the same header, round quick actions
/// and rows, closing once with the chosen action's id.
class MornyeTrackActionsMenu extends StatefulWidget {
  const MornyeTrackActionsMenu({
    super.key,
    required this.menu,
    required this.title,
    required this.artist,
    this.coverUrl,
    this.inheritSurface = false,
  });

  final TrackActionMenu menu;
  final String title;
  final String artist;
  final String? coverUrl;
  final bool inheritSurface;

  @override
  State<MornyeTrackActionsMenu> createState() => _MornyeTrackActionsMenuState();
}

class _MornyeTrackActionsMenuState extends State<MornyeTrackActionsMenu> {
  bool _picked = false;

  void _pick(TrackAction action) {
    if (_picked || !action.enabled) return;
    _picked = true;
    Navigator.of(context).pop(action.id);
  }

  @override
  Widget build(BuildContext context) {
    final converted = widget.menu.toMornye(_pick);
    return MornyeContextMenu(
      inheritSurface: widget.inheritSurface,
      dense: true,
      header: TrackActionHeader(
        title: widget.title,
        artist: widget.artist,
        coverUrl: widget.coverUrl,
        padding: const EdgeInsets.symmetric(horizontal: 16),
      ),
      quickActions: converted.quick,
      groups: converted.groups,
    );
  }
}
