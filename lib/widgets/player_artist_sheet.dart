import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/widgets/player_artwork.dart';

String playerReleaseName(MediaItem item, String? albumType) {
  final album = (item.album ?? '').trim();
  if (albumType?.trim().toLowerCase() == 'single' || album.isEmpty) {
    return item.title;
  }
  return album;
}

/// Artist credits and the current release, without fabricating artist imagery.
class PlayerArtistSheet extends StatelessWidget {
  const PlayerArtistSheet({
    super.key,
    required this.mediaItem,
    this.artistIds,
    this.albumType,
    required this.onArtist,
    required this.onAlbum,
  });
  final MediaItem mediaItem;
  final String? artistIds;
  final String? albumType;
  final ValueChanged<ArtistTapTarget> onArtist;
  final VoidCallback onAlbum;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final artists = buildArtistTapTargets(mediaItem.artist ?? '', artistIds);
    final hasAlbum = (mediaItem.album ?? '').trim().isNotEmpty;
    return ListView(
      shrinkWrap: true,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      children: [
        for (final artist in artists)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            leading: CircleAvatar(
              backgroundColor: colors.surfaceContainerHighest,
              child: Icon(Icons.person_outline, color: colors.onSurfaceVariant),
            ),
            title: Text(
              artist.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => onArtist(artist),
          ),
        if (artists.isNotEmpty) const Divider(),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 8),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox.square(
              dimension: 48,
              child: PlayerArtwork(
                complete: true,
                artUri: mediaItem.artUri?.toString(),
                colorScheme: colors,
                iconSize: 24,
              ),
            ),
          ),
          title: Text(
            playerReleaseName(mediaItem, albumType),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: hasAlbum ? const Icon(Icons.chevron_right) : null,
          onTap: hasAlbum ? onAlbum : null,
        ),
      ],
    );
  }
}
