import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';

Track trackFromHistoryItem(DownloadHistoryItem item) => Track(
  id: item.spotifyId?.trim().isNotEmpty == true ? item.spotifyId! : item.id,
  name: item.trackName,
  artistName: item.artistName,
  albumName: item.albumName,
  albumArtist: item.albumArtist,
  coverUrl: item.coverUrl,
  isrc: item.isrc,
  duration: item.duration ?? 0,
  trackNumber: item.trackNumber,
  discNumber: item.discNumber,
  totalDiscs: item.totalDiscs,
  releaseDate: item.releaseDate,
  totalTracks: item.totalTracks,
  composer: item.composer,
  genre: item.genre,
  label: item.label,
  copyright: item.copyright,
  explicit: item.explicit,
);
