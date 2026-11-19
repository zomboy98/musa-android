import 'package:mornye/models/track.dart';
import 'package:mornye/services/search_region.dart';
import 'package:mornye/services/search_result_classifier.dart';
import 'package:mornye/services/song_search_ranking.dart';

/// Extension that supplies the regional rankings.
const String regionalSignalExtensionId = 'apple-music';

/// Songs asked per storefront.
const int regionalSignalRows = 25;

/// How long a search waits for the regional rankings before ranking without
/// them.
const Duration regionalSignalTimeout = Duration(seconds: 4);

/// One song of a storefront's search ranking.
typedef RegionalRankRow = ({String? isrc, String title, String artist});

/// The ranking of one country and how much it counts.
class RegionalRanking {
  final double weight;
  final List<RegionalRankRow> rows;

  const RegionalRanking(this.weight, this.rows);
}

String _titleArtistKey(String title, String artist) =>
    '${cleanSongTitle(title)}|${normalizeSearchText(artist)}';

Iterable<String> _artistKeys(String title, String artistName) sync* {
  for (final part in artistName.split(
    RegExp(r'\s*(?:,|&|;|/|\bfeat\b\.?)\s*'),
  )) {
    if (normalizeSearchText(part).isNotEmpty) {
      yield _titleArtistKey(title, part);
    }
  }
}

/// Popularity points of songs, taken from the order of the search results of
/// the chosen region and its neighbors. A song gets
/// `weight * (rows - position) / rows` per ranking it appears in; it is paired
/// by ISRC, or by title and artist when the ISRC is missing.
class RegionalSongSignal {
  final Map<String, double> _byIsrc = {};
  final Map<String, double> _byTitleArtist = {};

  RegionalSongSignal(List<RegionalRanking> rankings) {
    for (final ranking in rankings) {
      final count = ranking.rows.length;
      for (var position = 0; position < count; position++) {
        final row = ranking.rows[position];
        final points = ranking.weight * (count - position) / count;
        final isrc = row.isrc?.trim().toUpperCase();
        if (isrc != null && isrc.isNotEmpty) {
          _byIsrc[isrc] = (_byIsrc[isrc] ?? 0) + points;
        }
        for (final key in _artistKeys(row.title, row.artist)) {
          _byTitleArtist[key] = (_byTitleArtist[key] ?? 0) + points;
        }
      }
    }
  }

  bool get isEmpty => _byIsrc.isEmpty && _byTitleArtist.isEmpty;

  double scoreOf(Track track) {
    final isrc = track.isrc?.trim().toUpperCase();
    if (isrc != null && isrc.isNotEmpty) {
      final byIsrc = _byIsrc[isrc];
      if (byIsrc != null) return byIsrc;
    }
    var best = 0.0;
    for (final key in _artistKeys(track.name, track.artistName)) {
      final points = _byTitleArtist[key];
      if (points != null && points > best) best = points;
    }
    return best;
  }
}

/// Keeps the ranking of one (query, country) for [ttl].
class RegionalRankingCache {
  final Duration ttl;
  final int maxEntries;
  final DateTime Function() _now;
  final Map<String, ({DateTime at, List<RegionalRankRow> rows})> _entries = {};

  RegionalRankingCache({
    this.ttl = const Duration(minutes: 10),
    this.maxEntries = 40,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  String _key(String query, String country) =>
      '${country.toLowerCase()}|${normalizeSearchText(query)}';

  List<RegionalRankRow>? get(String query, String country) {
    final key = _key(query, country);
    final entry = _entries[key];
    if (entry == null) return null;
    if (_now().difference(entry.at) >= ttl) {
      _entries.remove(key);
      return null;
    }
    return entry.rows;
  }

  void put(String query, String country, List<RegionalRankRow> rows) {
    final key = _key(query, country);
    _entries.remove(key);
    _entries[key] = (at: _now(), rows: rows);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }
}

/// The rankings of [region] and its neighbors for [query]; a country whose
/// [fetch] fails or is empty is left out, never raising.
Future<RegionalSongSignal> buildRegionalSignal({
  required String query,
  required String region,
  required Future<List<RegionalRankRow>> Function(String country) fetch,
  required RegionalRankingCache cache,
}) async {
  final rankings = await Future.wait([
    for (final entry in searchRegionWeights(region))
      () async {
        try {
          var rows = cache.get(query, entry.code);
          if (rows == null) {
            rows = await fetch(entry.code);
            if (rows.isNotEmpty) cache.put(query, entry.code, rows);
          }
          return RegionalRanking(entry.weight, rows);
        } catch (_) {
          return RegionalRanking(entry.weight, const []);
        }
      }(),
  ]);
  return RegionalSongSignal(rankings);
}
