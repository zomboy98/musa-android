import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/link/link_actions.dart';
import 'package:mornye/widgets/playlist_picker_sheet.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/services/network_offline_saver.dart';
import 'package:mornye/widgets/network_offline_actions.dart';
import 'package:mornye/providers/network_upload_provider.dart';
import 'package:mornye/widgets/network_upload_actions.dart';

/// Collection actions stay separate from actions that modify audio files.
class LibrarySelectionPlaybackActions extends ConsumerWidget {
  const LibrarySelectionPlaybackActions({
    super.key,
    required this.items,
    required this.onClose,
    this.canUseTracks,
    this.isCurrentRequest,
  });

  final List<UnifiedLibraryItem> items;
  final VoidCallback onClose;
  final Provider<bool>? canUseTracks;
  final bool Function()? isCurrentRequest;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = Theme.of(context).colorScheme;
    final showPlayer = ref.watch(playerUiEnabledProvider);
    final actions = <Widget>[
      if (items.any((item) => networkOfflineOrigin(item) != null))
        SelectionActionButton(
          icon: Icons.download_for_offline_outlined,
          label: context.l10n.offlineSave,
          colorScheme: colors,
          onPressed: () {
            if (isCurrentRequest?.call() == false) return;
            final root = Navigator.of(context, rootNavigator: true).context;
            unawaited(saveNetworkOffline(root, ref, items));
            onClose();
          },
        ),
      if (networkUploadOffered(
        ref.watch(networkUploadConnectionsProvider).value,
        items,
      ))
        SelectionActionButton(
          icon: Icons.cloud_upload_outlined,
          label: context.l10n.networkUpload,
          colorScheme: colors,
          onPressed: () {
            if (isCurrentRequest?.call() == false) return;
            final root = Navigator.of(context, rootNavigator: true).context;
            unawaited(
              uploadToNetworkStorage(
                root,
                ref,
                items,
                isCurrentRequest: isCurrentRequest,
              ),
            );
            onClose();
          },
        ),
      SelectionActionButton(
        icon: Icons.playlist_add,
        label: context.l10n.collectionAddToPlaylist,
        colorScheme: colors,
        onPressed: items.isEmpty
            ? null
            : () {
                if (isCurrentRequest?.call() == false) return;
                final tracks = items.map((item) => item.toTrack()).toList();
                final navigatorContext = Navigator.of(
                  context,
                  rootNavigator: true,
                ).context;
                onClose();
                showAddTracksToPlaylistSheet(
                  navigatorContext,
                  ref,
                  tracks,
                  canUseTracks: canUseTracks,
                );
              },
      ),
      for (final next in showPlayer ? [true, false] : const <bool>[])
        SelectionActionButton(
          icon: next ? Icons.playlist_play : Icons.queue_music,
          label: next
              ? context.l10n.trackPlayNext
              : context.l10n.trackAddToQueue,
          colorScheme: colors,
          onPressed: items.isEmpty
              ? null
              : () async {
                  if (isCurrentRequest?.call() == false) return;
                  final controller = ref.read(musicPlayerControllerProvider);
                  await controller.enqueueLibraryItems(
                    items,
                    playNext: next,
                    isCurrentRequest: isCurrentRequest,
                  );
                  if (context.mounted && isCurrentRequest?.call() != false) {
                    onClose();
                  }
                },
        ),
      // Copying songs to or from the paired computer (Mornye Link).
      ...linkTransferSelectionActions(
        context,
        ref,
        items,
        onClose: onClose,
        isCurrentRequest: isCurrentRequest,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final action in actions)
              if (isDesktopPlatform)
                action
              else
                SizedBox(width: (constraints.maxWidth - 8) / 2, child: action),
          ],
        ),
      ),
    );
  }
}
