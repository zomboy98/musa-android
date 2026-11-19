import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';

/// The origin of a queued song. A queue stored before origins were recorded
/// has none: a song that belongs to a playlist or to the favorites is then a
/// playlist download, naming the playlist when it can be told which one (by
/// its name, by a list kept downloaded, or when only one holds it). Without a
/// known list the stated origin, possibly none, is kept.
DownloadOrigin? inferDownloadOrigin({
  required DownloadOrigin? stated,
  required Track track,
  required String? playlistName,
  required LibraryCollectionsState collections,
  Iterable<String> keptPlaylistIds = const [],
}) {
  if (stated != null &&
      (stated.kind != DownloadOriginKind.playlist ||
          stated.collectionId != null)) {
    return stated;
  }
  if (!collections.isLoaded) return stated;
  final key = trackCollectionKey(track);
  final containing = [
    for (final playlist in collections.playlists)
      if (playlist.containsTrackKey(key)) playlist,
  ];
  if (stated == null &&
      containing.isEmpty &&
      !collections.containsLovedKey(key)) {
    return null;
  }
  String? id;
  final name = playlistName?.trim() ?? '';
  if (name.isNotEmpty) {
    id = containing.where((p) => p.name == name).firstOrNull?.id;
  }
  if (id == null) {
    for (final kept in keptPlaylistIds) {
      if (containing.any((p) => p.id == kept)) {
        id = kept;
        break;
      }
    }
  }
  if (id == null && containing.length == 1) id = containing.single.id;
  return DownloadOrigin.playlistOf(id);
}
