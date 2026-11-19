import 'package:mornye/services/playable_media.dart';

enum ShuffleStrategy {
  off,
  random,
  smart;

  bool get enabled => this != off;
}

bool smartShuffleEligible(List<PlayableMedia> queue) {
  final albums = <String>{};
  final artists = <String>{};
  for (final media in queue) {
    if (media.autoplay) continue;
    albums.add(media.albumId ?? media.album.trim().toLowerCase());
    artists.add(media.artist.trim().toLowerCase());
    if (albums.length > 1 && artists.length > 1) return true;
  }
  return false;
}
