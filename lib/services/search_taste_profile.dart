import 'package:mornye/models/track.dart';
import 'package:mornye/services/search_result_classifier.dart';
import 'package:mornye/services/song_search_ranking.dart';

/// Points of a song whose artist the user follows.
const double searchTasteFollowedPoints = 2.0;

/// Most points of a song by an artist the user plays; the artist played the
/// most gets all of them, the others in proportion to their listening time.
const double searchTastePlayedMaxPoints = 1.5;

/// Points of a song whose genre is one the user picked in their music
/// preferences.
const double searchTasteGenrePoints = 0.5;

/// Days of listening history that count.
const int searchTasteDays = 90;

/// How long a profile is reused, and how long a search waits to build one.
const Duration searchTasteCacheTtl = Duration(minutes: 2);
const Duration searchTasteTimeout = Duration(milliseconds: 1500);

/// Artists of the listening history that count, the most played first.
const int searchTastePlayedArtists = 50;

/// What this device knows about the user, taken only from what they follow,
/// pick and play. Nothing is preloaded: with no history the profile is empty
/// and scores every song zero. The score only breaks ties inside a level of
/// text match; it never hides or lowers a result.
class SearchTasteProfile {
  final Set<String> _followed;
  final Map<String, double> _played;
  final Set<String> _genres;

  SearchTasteProfile._(this._followed, this._played, this._genres);

  static final SearchTasteProfile empty = SearchTasteProfile._(
    const {},
    const {},
    const {},
  );

  /// [playedMilliseconds] maps an artist name to the time the user listened.
  factory SearchTasteProfile({
    Iterable<String> followedArtists = const [],
    Map<String, int> playedMilliseconds = const {},
    Iterable<String> genres = const [],
  }) {
    final followed = {
      for (final name in followedArtists)
        if (normalizeSearchText(name).isNotEmpty) normalizeSearchText(name),
    };
    final ranked = [
      for (final entry in playedMilliseconds.entries)
        if (entry.value > 0 && normalizeSearchText(entry.key).isNotEmpty)
          (name: normalizeSearchText(entry.key), time: entry.value),
    ]..sort((a, b) => b.time.compareTo(a.time));
    final played = <String, double>{};
    if (ranked.isNotEmpty) {
      final top = ranked.first.time;
      for (final item in ranked.take(searchTastePlayedArtists)) {
        played.putIfAbsent(item.name, () => item.time / top);
      }
    }
    final genreSet = {
      for (final genre in genres)
        if (normalizeSearchText(genre).isNotEmpty) normalizeSearchText(genre),
    };
    return SearchTasteProfile._(followed, played, genreSet);
  }

  bool get isEmpty => _followed.isEmpty && _played.isEmpty && _genres.isEmpty;

  double scoreOf(Track track) {
    if (isEmpty) return 0;
    var points = 0.0;
    var follows = false;
    var share = 0.0;
    for (final artist in songArtistParts(track.artistName)) {
      if (_followed.contains(artist)) follows = true;
      final played = _played[artist];
      if (played != null && played > share) share = played;
    }
    if (follows) points += searchTasteFollowedPoints;
    points += searchTastePlayedMaxPoints * share;
    final genre = normalizeSearchText(track.genre ?? '');
    if (genre.isNotEmpty && _genres.contains(genre)) {
      points += searchTasteGenrePoints;
    }
    return points;
  }
}

/// Points of a song the user already has downloaded or in their library:
/// above any regional or listening score, so it leads its group.
const double searchLocalSongPoints = 100.0;

/// Points of a song whose artist has songs the user already has locally.
const double searchLocalArtistPoints = 20.0;

/// Which of the songs of one search the user already has on the device.
class LocalSongSignal {
  final Set<String> _songs;
  final Set<String> _artists;

  LocalSongSignal._(this._songs, this._artists);

  static final LocalSongSignal empty = LocalSongSignal._(const {}, const {});

  static String songKey(Track track) {
    final isrc = track.isrc?.trim().toUpperCase();
    if (isrc != null && isrc.isNotEmpty) return 'isrc:$isrc';
    return 'id:${track.source ?? ''}:${track.id}';
  }

  factory LocalSongSignal(Iterable<Track> localSongs) {
    final songs = <String>{};
    final artists = <String>{};
    for (final track in localSongs) {
      songs.add(songKey(track));
      artists.addAll(songArtistParts(track.artistName));
    }
    return LocalSongSignal._(songs, artists);
  }

  bool get isEmpty => _songs.isEmpty;

  double scoreOf(Track track) {
    if (isEmpty) return 0;
    if (_songs.contains(songKey(track))) return searchLocalSongPoints;
    return songArtistParts(track.artistName).any(_artists.contains)
        ? searchLocalArtistPoints
        : 0;
  }
}
