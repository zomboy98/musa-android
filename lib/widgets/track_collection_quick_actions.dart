import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_bottom_sheet.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/context_menu.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_icon_button.dart';
import 'package:mornye/widgets/track_actions.dart';
import 'package:mornye/widgets/track_actions_sheet.dart';

/// The "+" action shared by rows, menus and the player: adds [track] to the
/// library, or removes it when [saved].
Future<void> toggleSavedLibraryTrack(
  BuildContext context,
  WidgetRef ref,
  Track track,
  bool saved,
) => _toggleSavedTrack(context, ref, track, saved);

Future<void> _toggleSavedTrack(
  BuildContext context,
  WidgetRef ref,
  Track track,
  bool saved,
) => toggleSavedLibraryTrackIn(
  context,
  ProviderScope.containerOf(context, listen: false),
  track,
  saved,
);

/// Same action on a [container] that outlives the widget that asked for it
/// (the add-to-music sheet closes before the slow library work ends).
Future<void> toggleSavedLibraryTrackIn(
  BuildContext context,
  ProviderContainer container,
  Track track,
  bool saved,
) async {
  try {
    final notifier = container.read(savedLibraryTracksProvider.notifier);
    if (saved) {
      // A favorite cannot live outside the library, so its star goes too.
      // Songs without a star never touch the collections database here.
      final collections = container.read(libraryCollectionsProvider.notifier);
      final starred = container.read(libraryCollectionsProvider).isLoved(track);
      await notifier.remove(track);
      if (starred) {
        await collections.dropLovedTracks([trackCollectionKey(track)]);
      }
      return;
    }
    final result = await notifier.addWithRetention(track);
    if (result.added &&
        container.read(settingsProvider).autoDownloadSavedTracks) {
      final settings = container.read(settingsProvider);
      final service = resolveConfiguredDownloadService(
        settings.defaultService,
        container.read(extensionProvider),
        autoFallback: settings.autoFallback,
      );
      if (service.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(context.l10n.savedTrackAutoDownloadError)),
          );
        }
      } else {
        try {
          await container
              .read(downloadQueueProvider.notifier)
              .addCurrentSavedTrackToQueue(
                track,
                service,
                notifier.currentSaveIntention(track),
              );
        } catch (_) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(context.l10n.savedTrackAutoDownloadError)),
            );
          }
        }
      }
    }
    final autoDownload = container
        .read(settingsProvider)
        .autoDownloadSavedTracks;
    if (result.retentionError != null &&
        !(autoDownload &&
            result.retentionError is SavedAudioPreparationException) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.savedTrackRetentionError)),
      );
    }
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.savedCatalogTracksError)),
      );
    }
  }
}

class TrackCollectionQuickActions extends ConsumerWidget {
  final Track track;
  final bool hasLocalPlaybackCandidate;

  /// A 32dp pointer target for desktop table rows.
  final bool dense;

  const TrackCollectionQuickActions({
    super.key,
    required this.track,
    this.hasLocalPlaybackCandidate = false,
    this.dense = false,
  });

  /// Track options: a bottom sheet (Material) or popover (Mornye) on phones
  /// and tablets, a context menu at [position] or under [context] on
  /// desktop. All three show the same actions in the same order, resolved
  /// before the menu opens.
  static void showTrackOptionsSheet(
    BuildContext context,
    WidgetRef ref,
    Track track, {
    bool hasLocalPlaybackCandidate = false,
    Offset? position,
  }) {
    final menu = readTrackActionMenu(
      context,
      ref,
      track,
      hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
    );
    final root = Navigator.of(context, rootNavigator: true).context;
    if (isDesktopPlatform) {
      final origin =
          position ??
          contextMenuOriginOf(context) ??
          MediaQuery.sizeOf(context).center(Offset.zero);
      showContextMenu(
        context,
        position: origin,
        groups: menu.toContextGroups(
          (action) => runTrackAction(root, ref, track, action.id),
        ),
      );
      return;
    }
    if (context.isMornye) {
      final anchor = mornyeMenuAnchor(context);
      showMornyeContextMenu<TrackActionId>(
        context: context,
        anchor: anchor,
        builder: (_) => MornyeTrackActionsMenu(
          menu: menu,
          title: track.name,
          artist: track.artistName,
          coverUrl: track.coverUrl,
        ),
      ).then((id) {
        if (id != null && root.mounted) {
          runTrackAction(root, ref, track, id, shareOrigin: anchor);
        }
      });
      return;
    }
    showAppModalBottomSheet<TrackActionId>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      builder: (_) => TrackActionsSheet(
        menu: menu,
        title: track.name,
        artist: track.artistName,
        coverUrl: track.coverUrl,
      ),
    ).then((id) {
      if (id != null && root.mounted) runTrackAction(root, ref, track, id);
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppIconButton(
      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
      icon: AppIcon(
        context.isMornye ? CupertinoIcons.ellipsis : Icons.more_vert,
        color: colorScheme.onSurfaceVariant,
        size: 20,
      ),
      onPressed: () => showTrackOptionsSheet(
        context,
        ref,
        track,
        hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
        position: contextMenuPositionBelow(context),
      ),
      padding: EdgeInsets.zero,
      constraints: dense
          ? const BoxConstraints(minWidth: 32, minHeight: 32)
          : const BoxConstraints(minWidth: 48, minHeight: 48),
      style: dense
          ? IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            )
          : null,
    );
  }
}

/// The track options as desktop context menu groups, in the order every song
/// menu uses.
List<List<ContextMenuAction>> trackOptionMenuGroups(
  BuildContext context,
  WidgetRef ref,
  Track track, {
  bool hasLocalPlaybackCandidate = false,
}) {
  final root = Navigator.of(context, rootNavigator: true).context;
  return readTrackActionMenu(
    context,
    ref,
    track,
    hasLocalPlaybackCandidate: hasLocalPlaybackCandidate,
  ).toContextGroups((action) => runTrackAction(root, ref, track, action.id));
}
