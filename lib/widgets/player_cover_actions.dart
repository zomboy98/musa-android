import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/player_track_navigation.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/artists_sheet.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/collectible_cover_viewer.dart';
import 'package:mornye/widgets/player_artist_sheet.dart';

Future<void> showPlayerArtistsSheet(
  BuildContext context,
  WidgetRef ref,
  MediaItem item, {
  Future<void> Function()? fallback,
}) async {
  final extensionId = playingCatalogExtensionId(item);
  if (extensionId == null) {
    if (fallback != null) {
      await fallback();
    } else {
      await openPlayingArtist(context, ref, item);
    }
    return;
  }
  final track = await ref.read(playerCollectionTrackProvider(item).future);
  if (!context.mounted) return;
  final names = (item.artist ?? '').trim().isEmpty
      ? track.artistName
      : item.artist!;
  final albumType = item.extras?['albumType']?.toString() ?? track.albumType;
  final release = playerReleaseName(item, albumType);
  await showArtistsSheet(
    context,
    ref,
    artistas: artistsSheetArtistsFrom(
      names,
      track.artistId,
      extensionId: extensionId,
    ),
    album: release.trim().isEmpty
        ? null
        : ArtistsSheetAlbum(
            name: release,
            id: track.albumId,
            artistName: track.albumArtist ?? names,
            coverUrl: item.artUri?.toString() ?? track.coverUrl,
            extensionId: extensionId,
            type: albumType,
          ),
  );
}

Rect? Function() _globalRectReader(BuildContext context) => () {
  if (!context.mounted) return null;
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.attached || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
};

void showPlayerCollectibleCover(
  BuildContext context,
  MediaItem item, {
  double coverRadius = 20,
}) {
  final provider = coverImageProvider(item.artUri?.toString());
  if (provider == null) return;
  showCollectibleCover(
    context,
    imageProvider: provider,
    title: item.album,
    originRect: _globalRectReader(context),
    originRadius: coverRadius,
  );
}

class PlayerCoverTap extends StatelessWidget {
  const PlayerCoverTap({
    super.key,
    required this.item,
    required this.child,
    this.coverRadius = 20,
  });

  final MediaItem item;
  final Widget child;
  final double coverRadius;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: item.album ?? item.title,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () =>
          showPlayerCollectibleCover(context, item, coverRadius: coverRadius),
      child: child,
    ),
  );
}
