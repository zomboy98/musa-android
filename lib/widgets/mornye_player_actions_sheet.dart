import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/track_actions.dart';
import 'package:mornye/widgets/track_actions_sheet.dart';

/// Navigation for the title/artist, separate from playback and file actions.
class MornyePlayerNavigationMenu extends StatelessWidget {
  const MornyePlayerNavigationMenu({
    super.key,
    required this.mediaItem,
    this.sourceColor,
  });

  final MediaItem mediaItem;
  final Color? sourceColor;

  @override
  Widget build(BuildContext context) {
    return _MornyePlayerMenuSurface(
      sourceColor: sourceColor,
      child: MornyeContextMenu(
        inheritSurface: true,
        dense: true,
        groups: [
          [
            if ((mediaItem.artist ?? '').trim().isNotEmpty)
              MornyeMenuAction(
                icon: CupertinoIcons.mic,
                label: context.l10n.mornyeGoToArtist,
                subtitle: mediaItem.artist,
                onPressed: () => Navigator.of(context).pop('artist'),
              ),
            if ((mediaItem.album ?? '').trim().isNotEmpty)
              MornyeMenuAction(
                icon: CupertinoIcons.square_stack,
                label: context.l10n.homeGoToAlbum,
                subtitle: mediaItem.album,
                onPressed: () => Navigator.of(context).pop('album'),
              ),
          ],
        ],
      ),
    );
  }
}

/// The song menu over the player, in the player's dark appearance. The menu
/// and the cover color arrive already resolved, so nothing changes once it
/// is on screen. It closes with the chosen [TrackActionId.value].
class MornyePlayerActionsSheet extends StatelessWidget {
  const MornyePlayerActionsSheet({
    super.key,
    required this.mediaItem,
    required this.menu,
    this.sourceColor,
  });

  final MediaItem mediaItem;
  final TrackActionMenu menu;
  final Color? sourceColor;

  @override
  Widget build(BuildContext context) {
    return _MornyePlayerMenuSurface(
      sourceColor: sourceColor,
      child: MornyeTrackActionsMenu(
        inheritSurface: true,
        menu: menu,
        title: mediaItem.title,
        artist: mediaItem.artist ?? '',
        coverUrl: mediaItem.artUri?.toString(),
      ),
    );
  }
}

/// Dark surface tinted with the cover's color, which is known before the menu
/// opens.
class _MornyePlayerMenuSurface extends StatelessWidget {
  const _MornyePlayerMenuSurface({
    required this.sourceColor,
    required this.child,
  });

  final Color? sourceColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dominant = HSLColor.fromColor(sourceColor ?? Colors.grey);
    final surface = dominant
        .withSaturation(dominant.saturation.clamp(0.0, 0.34))
        .withLightness(0.28)
        .toColor();
    return Theme(
      data: MornyeTheme.fromContext(
        context,
        brightness: Brightness.dark,
        chromeSurface: surface,
      ),
      child: child,
    );
  }
}
