import 'package:flutter/cupertino.dart' show CupertinoIcons;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/shuffle_strategy.dart';
import 'package:mornye/widgets/expressive_button_group.dart';
import 'package:mornye/widgets/shuffle_mode_window.dart';

/// Love all, download all and add to playlist buttons of a track collection
/// header, laid out for desktop, Mornye or Material. All three are disabled
/// while [tracks] is empty.
class CollectionHeaderActions extends StatelessWidget {
  const CollectionHeaderActions({
    super.key,
    required this.tracks,
    required this.onLoveAll,
    required this.downloadIcon,
    required this.onDownloadAll,
    required this.addToPlaylistIcon,
    required this.onAddToPlaylist,
    this.tonalDownload = false,
    this.onShuffle,
  });

  final List<Track> tracks;
  final VoidCallback onLoveAll;

  /// The Material download glyph; Mornye uses its filled arrow.
  final IconData downloadIcon;
  final VoidCallback onDownloadAll;
  final bool tonalDownload;
  final IconData addToPlaylistIcon;
  final VoidCallback onAddToPlaylist;
  final VoidCallback? onShuffle;

  @override
  Widget build(BuildContext context) {
    final enabled = tracks.isNotEmpty;
    final mornye = context.isMornye;
    final love = Consumer(
      builder: (context, ref, _) {
        ref.watch(libraryCollectionsProvider.select((state) => state.loved));
        final collectionsState = ref.read(libraryCollectionsProvider);
        final allLoved =
            enabled && tracks.every((t) => collectionsState.isLoved(t));
        return HeaderCircleButton(
          icon: allLoved ? Icons.favorite : Icons.favorite_border,
          tonal: true,
          iconColor: allLoved ? Theme.of(context).colorScheme.error : null,
          tooltip: allLoved
              ? context.l10n.trackOptionRemoveFromLoved
              : context.l10n.tooltipLoveAll,
          onPressed: enabled ? onLoveAll : null,
        );
      },
    );
    final download = HeaderFilledButton(
      icon: mornye ? CupertinoIcons.arrow_down_circle_fill : downloadIcon,
      tonal: tonalDownload,
      label: mornye
          ? context.l10n.dialogDownload
          : context.l10n.downloadAllCount(tracks.length),
      onPressed: enabled ? onDownloadAll : null,
    );
    final addToPlaylist = HeaderCircleButton(
      icon: addToPlaylistIcon,
      tonal: true,
      tooltip: context.l10n.tooltipAddToPlaylist,
      onPressed: enabled ? onAddToPlaylist : null,
    );
    final shuffle = onShuffle == null
        ? null
        : Consumer(
            builder: (context, ref, _) {
              final strategy = ref.watch(
                shuffleStrategyProvider.select(
                  (state) => state.value ?? ShuffleStrategy.off,
                ),
              );
              return HeaderCircleButton(
                key: const ValueKey('collection-shuffle'),
                icon: Icons.shuffle,
                glyph: strategy.enabled
                    ? ShuffleStrategyIcon(strategy: strategy, size: 22)
                    : null,
                tonal: true,
                tooltip: strategy.enabled
                    ? shuffleStrategyLabel(context, strategy)
                    : context.l10n.actionShuffle,
                onPressed: enabled ? onShuffle : null,
              );
            },
          );
    if (isDesktopPlatform) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        spacing: 10,
        children: [love, download, addToPlaylist, ?shuffle],
      );
    }
    if (mornye) {
      return Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          love,
          const SizedBox(width: 16),
          Flexible(child: SizedBox(width: 172, child: download)),
          const SizedBox(width: 16),
          addToPlaylist,
          if (shuffle != null) ...[const SizedBox(width: 16), shuffle],
        ],
      );
    }
    return ExpressiveButtonGroup(
      flexible: const {1},
      children: [love, download, addToPlaylist, ?shuffle],
    );
  }
}
