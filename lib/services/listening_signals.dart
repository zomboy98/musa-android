import 'dart:math';

import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/artist_utils.dart';
import 'package:mornye/utils/logger.dart';

final _log = AppLogger('ListeningSignals');

const listeningSignalsWindow = Duration(days: 90);
const _completionHalfLife = Duration(days: 45);
const _skipHalfLife = Duration(days: 21);

String _normalized(String value) {
  final text = value.trim().toLowerCase();
  return text.length > 160 ? text.substring(0, 160) : text;
}

String listeningSongKey(String artist, String title) =>
    '${_normalized(artist)}|${_normalized(title)}';

String listeningSongKeyOf(PlayableMedia media) =>
    listeningSongKey(media.artist, media.title);

final _artistKeys = <String, List<String>>{};

List<String> listeningArtistKeys(String artist) {
  final cached = _artistKeys[artist];
  if (cached != null) return cached;
  if (_artistKeys.length > 20000) _artistKeys.clear();
  return _artistKeys[artist] = _splitArtistKeys(artist);
}

List<String> _splitArtistKeys(String artist) {
  final names = splitArtistNames(artist);
  final keys = {
    for (final name in names)
      if (_normalized(name).isNotEmpty) _normalized(name),
  };
  if (keys.isEmpty && _normalized(artist).isNotEmpty) {
    keys.add(_normalized(artist));
  }
  return keys.toList(growable: false);
}

abstract class ListeningSignals {
  const ListeningSignals();

  DateTime get now;

  int playCount(PlayableMedia track);

  DateTime? lastPlayed(PlayableMedia track);

  double recentCompletions(PlayableMedia track);

  double recentSkips(PlayableMedia track);

  bool isFavorite(PlayableMedia track);

  double artistCompletions(String artistKey);

  double artistSkips(String artistKey);

  int artistFavorites(String artistKey);
}

class SongListening {
  const SongListening({
    this.plays = 0,
    this.lastPlayed,
    this.completions = 0,
    this.skips = 0,
    this.favorite = false,
  });

  final int plays;
  final DateTime? lastPlayed;
  final double completions;
  final double skips;
  final bool favorite;

  SongListening copyWith({
    int? plays,
    DateTime? lastPlayed,
    double? completions,
    double? skips,
    bool? favorite,
  }) => SongListening(
    plays: plays ?? this.plays,
    lastPlayed: lastPlayed ?? this.lastPlayed,
    completions: completions ?? this.completions,
    skips: skips ?? this.skips,
    favorite: favorite ?? this.favorite,
  );
}

class ArtistListening {
  const ArtistListening({
    this.completions = 0,
    this.skips = 0,
    this.favorites = 0,
  });

  final double completions;
  final double skips;
  final int favorites;
}

class SnapshotListeningSignals extends ListeningSignals {
  const SnapshotListeningSignals({
    required this.now,
    this.songs = const {},
    this.artists = const {},
  });

  @override
  final DateTime now;
  final Map<String, SongListening> songs;
  final Map<String, ArtistListening> artists;

  SongListening _song(PlayableMedia track) =>
      songs[listeningSongKeyOf(track)] ?? const SongListening();

  @override
  int playCount(PlayableMedia track) => _song(track).plays;

  @override
  DateTime? lastPlayed(PlayableMedia track) => _song(track).lastPlayed;

  @override
  double recentCompletions(PlayableMedia track) => _song(track).completions;

  @override
  double recentSkips(PlayableMedia track) => _song(track).skips;

  @override
  bool isFavorite(PlayableMedia track) => _song(track).favorite;

  @override
  double artistCompletions(String artistKey) =>
      artists[artistKey]?.completions ?? 0;

  @override
  double artistSkips(String artistKey) => artists[artistKey]?.skips ?? 0;

  @override
  int artistFavorites(String artistKey) => artists[artistKey]?.favorites ?? 0;
}

double _decay(Duration age, Duration halfLife) {
  if (age.isNegative) return 1;
  return pow(0.5, age.inMinutes / halfLife.inMinutes).toDouble();
}

DateTime _endOfDay(String day) {
  final parts = day.split('-');
  if (parts.length != 3) return DateTime.fromMillisecondsSinceEpoch(0);
  final year = int.tryParse(parts[0]) ?? 1970;
  final month = int.tryParse(parts[1]) ?? 1;
  final date = int.tryParse(parts[2]) ?? 1;
  return DateTime(year, month, date, 23, 59);
}

Future<ListeningSignals> loadDeviceListeningSignals({
  ListeningStatisticsStore? statistics,
  LibraryCollectionsDatabase? collections,
  AutoplayTaste? taste,
  DateTime? now,
}) async {
  final clock = now ?? DateTime.now();
  final songs = <String, SongListening>{};
  final artistCompletions = <String, double>{};
  final artistSkips = <String, double>{};
  final artistFavorites = <String, int>{};

  void addSong(String key, SongListening Function(SongListening) change) {
    songs[key] = change(songs[key] ?? const SongListening());
  }

  void addArtistValue(Map<String, double> into, String artist, double value) {
    for (final key in listeningArtistKeys(artist)) {
      into[key] = (into[key] ?? 0) + value;
    }
  }

  try {
    final store = statistics ?? ListeningStatisticsStore.instance;
    final from = clock.subtract(listeningSignalsWindow);
    final rows = await store.read((db) async {
      final totals = await db.rawQuery(
        'SELECT title, artist, SUM(plays) AS plays, MAX(day) AS last_day '
        'FROM listening GROUP BY title, artist HAVING SUM(plays) > 0',
      );
      final recent = await db.rawQuery(
        'SELECT title, artist, day, plays FROM listening '
        'WHERE day >= ? AND plays > 0',
        [listeningDay(from)],
      );
      return (totals, recent);
    });
    for (final row in rows.$1) {
      final key = listeningSongKey(
        row['artist'] as String? ?? '',
        row['title'] as String? ?? '',
      );
      final plays = (row['plays'] as num?)?.toInt() ?? 0;
      final last = _endOfDay(row['last_day'] as String? ?? '');
      addSong(key, (song) {
        final previous = song.lastPlayed;
        return song.copyWith(
          plays: song.plays + plays,
          lastPlayed: previous == null || last.isAfter(previous)
              ? last
              : previous,
        );
      });
    }
    for (final row in rows.$2) {
      final artist = row['artist'] as String? ?? '';
      final key = listeningSongKey(artist, row['title'] as String? ?? '');
      final plays = (row['plays'] as num?)?.toInt() ?? 0;
      final weight =
          plays *
          _decay(
            clock.difference(_endOfDay(row['day'] as String)),
            _completionHalfLife,
          );
      addSong(
        key,
        (song) => song.copyWith(completions: song.completions + weight),
      );
      addArtistValue(artistCompletions, artist, weight);
    }
  } catch (error) {
    _log.w('Listening statistics unavailable for shuffle: $error');
  }

  try {
    final loved = await (collections ?? LibraryCollectionsDatabase.instance)
        .loadLovedTracks(limit: 5000);
    for (final track in loved) {
      addSong(
        listeningSongKey(track.artistName, track.name),
        (song) => song.copyWith(favorite: true),
      );
      for (final key in listeningArtistKeys(track.artistName)) {
        artistFavorites[key] = (artistFavorites[key] ?? 0) + 1;
      }
    }
  } catch (error) {
    _log.w('Loved songs unavailable for shuffle: $error');
  }

  if (taste != null) {
    try {
      final log = await taste.readLog();
      for (final play in log) {
        final age = clock.difference(play.at);
        if (play.kind == AutoplayFeedbackKind.skipped) {
          if (age > const Duration(days: 60)) continue;
          final weight = _decay(age, _skipHalfLife);
          addSong(
            play.song,
            (song) => song.copyWith(skips: song.skips + weight),
          );
          for (final key in listeningArtistKeys(play.artist)) {
            artistSkips[key] = (artistSkips[key] ?? 0) + weight;
          }
        } else if (play.kind == AutoplayFeedbackKind.listened ||
            play.kind == AutoplayFeedbackKind.replayed) {
          addSong(play.song, (song) {
            final last = song.lastPlayed;
            return last == null || play.at.isAfter(last)
                ? song.copyWith(lastPlayed: play.at)
                : song;
          });
        }
      }
    } catch (error) {
      _log.w('Listening sessions unavailable for shuffle: $error');
    }
  }

  final artists = <String, ArtistListening>{};
  for (final key in {
    ...artistCompletions.keys,
    ...artistSkips.keys,
    ...artistFavorites.keys,
  }) {
    artists[key] = ArtistListening(
      completions: artistCompletions[key] ?? 0,
      skips: artistSkips[key] ?? 0,
      favorites: artistFavorites[key] ?? 0,
    );
  }
  return SnapshotListeningSignals(now: clock, songs: songs, artists: artists);
}
