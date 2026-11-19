import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/clickable_metadata.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('PlayerTrackNavigation');

/// Only the encoded catalog identifies the provider of catalog artist IDs.
String? playingCatalogExtensionId(MediaItem item) {
  final source = item.extras?['source'];
  if (source is! String || !source.startsWith('catalog:')) return null;
  final track = PlayableMedia(
    id: item.id,
    source: source,
    title: item.title,
    artist: item.artist ?? '',
  ).catalogTrack;
  final provider = track?.source?.trim();
  if (provider == null ||
      provider.isEmpty ||
      provider.toLowerCase() == 'local') {
    return null;
  }
  return provider;
}

/// Opens the artist of the song playing as [mediaItem].
Future<void> openPlayingArtist(
  BuildContext context,
  WidgetRef ref,
  MediaItem mediaItem,
) async {
  final track = ref.read(playerCollectionTrackProvider(mediaItem)).value;
  // A downloaded track's source is the service its audio came from, not a
  // metadata catalog; the lookup uses the user's search provider instead.
  await navigateToArtist(
    context,
    artistName: mediaItem.artist ?? '',
    artistId: track?.artistId,
    extensionId: playingCatalogExtensionId(mediaItem),
  );
}

/// Opens the album of the song playing as [mediaItem] from [source].
Future<void> openPlayingAlbum(
  BuildContext context,
  WidgetRef ref, {
  required MediaItem mediaItem,
  required String source,
}) async {
  final albumName = (mediaItem.album ?? '').trim();
  if (albumName.isEmpty) return;

  // Prefer the stored collection so this action remains useful offline and
  // opens the exact files the user is currently playing.
  try {
    final historyItem = source.isEmpty
        ? null
        : await ref
              .read(downloadHistoryProvider.notifier)
              .getByFilePathAsync(source);
    if (!context.mounted) return;
    if (historyItem != null) {
      final albumArtist = (historyItem.albumArtist ?? '').trim();
      pushViaPreferredNavigator(
        context,
        (_) => DownloadedAlbumScreen(
          albumName: historyItem.albumName,
          artistName: albumArtist.isNotEmpty
              ? albumArtist
              : historyItem.artistName,
          coverUrl: historyItem.coverUrl,
        ),
      );
      return;
    }
  } catch (e) {
    _log.w('Failed to resolve downloaded album: $e');
  }

  try {
    final album = await ref
        .read(musicPlayerControllerProvider)
        .localAlbumFor(mediaItem.id);
    if (!context.mounted) return;
    if (album != null) {
      final (:item, :tracks) = album;
      final albumArtist = (item.albumArtist ?? '').trim();
      pushViaPreferredNavigator(
        context,
        (_) => LocalAlbumScreen(
          albumName: item.albumName,
          artistName: albumArtist.isNotEmpty ? albumArtist : item.artistName,
          coverPath: item.coverPath,
          tracks: tracks,
        ),
      );
      return;
    }
  } catch (e) {
    _log.w('Failed to resolve local album: $e');
  }

  if (!context.mounted) return;
  await navigateToAlbum(
    context,
    albumName: albumName,
    artistName: mediaItem.artist,
    coverUrl: mediaItem.artUri?.toString(),
  );
}
