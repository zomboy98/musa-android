import 'package:mornye/models/track.dart';
import 'package:mornye/services/search_result_classifier.dart';

/// Results requested from the provider for each song query.
const int songSearchQueryLimit = 30;

/// Songs kept after merging the queries of one search.
const int songSearchMergedLimit = 50;

/// Songs the provider returned for a text typed by the user are ranked only by
/// how well the title (and, when the text names one, the artist) matches what
/// was typed; the provider order (popularity) decides inside each group.
enum SongMatchTier {
  /// Song of the artist the text names (see [matchedArtistNames]).
  artist,

  /// Exact title that also matches the artist named in the text.
  titleAndArtist,

  /// Exact title.
  exactTitle,

  /// Title that starts with the text.
  titlePrefix,

  /// Every word of the text is in the title.
  titleWords,

  /// Only the artist, album or the provider's own ranking relates to the text.
  other,

  /// Cover, tribute, karaoke or type beat: matches the text but imitates
  /// another work, so it goes below everything else.
  imitation,
}

/// A text of the form "title de|by|-|x artist".
class CompoundSongQuery {
  final String title;
  final String artist;

  /// True when the separator does not tell which side is the title
  /// ("A - B", "A x B"), so both orders are tried when ranking.
  final bool ambiguousOrder;

  const CompoundSongQuery({
    required this.title,
    required this.artist,
    required this.ambiguousOrder,
  });
}

final RegExp _compoundSeparator = RegExp(
  r'^(.+)\s+(de|by|-|–|—|x)\s+(.+)$',
  caseSensitive: false,
);

/// Splits "title de artist", "title - artist", "title by artist" and
/// "title x artist" at the last separator. Returns null when the
/// text has none.
CompoundSongQuery? parseCompoundSongQuery(String query) {
  final match = _compoundSeparator.firstMatch(query.trim());
  if (match == null) return null;
  final left = match.group(1)!.trim();
  final right = match.group(3)!.trim();
  if (normalizeSearchText(left).isEmpty || normalizeSearchText(right).isEmpty) {
    return null;
  }
  final separator = match.group(2)!.toLowerCase();
  return CompoundSongQuery(
    title: left,
    artist: right,
    ambiguousOrder: separator != 'de' && separator != 'by',
  );
}

/// Query syntaxes a provider understands for a title-targeted search. A
/// provider that is not listed gets only the plain query.
class TargetedSongSyntax {
  const TargetedSongSyntax._();

  static bool supports(String extensionId) =>
      extensionId.trim().toLowerCase() == 'deezer';

  static String _clean(String value) =>
      value.replaceAll('"', ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

  /// `track:"title"` for Deezer.
  static String? titleQuery(String extensionId, String title) {
    if (!supports(extensionId)) return null;
    final cleaned = _clean(title);
    return cleaned.isEmpty ? null : 'track:"$cleaned"';
  }

  /// `track:"title" artist` for Deezer: its `artist:` filter returns
  /// nothing for most artists, so the artist goes as free text.
  static String? titleAndArtistQuery(
    String extensionId,
    String title,
    String artist,
  ) {
    if (!supports(extensionId)) return null;
    final cleanTitle = _clean(title);
    final cleanArtist = _clean(artist);
    if (cleanTitle.isEmpty || cleanArtist.isEmpty) return null;
    return 'track:"$cleanTitle" $cleanArtist';
  }
}

/// Whether the text is a plain title/artist search: not a link, an ISRC or a
/// provider operator.
bool isPlainSongQuery(String query) {
  final text = query.trim();
  if (text.length < 2) return false;
  final lower = text.toLowerCase();
  if (lower.startsWith('http') || lower.startsWith('spotify:')) return false;
  if (RegExp(
    r'^[a-z]{2}[a-z0-9]{3}\d{7}$',
    caseSensitive: false,
  ).hasMatch(text.replaceAll('-', ''))) {
    return false;
  }
  if (RegExp(r'\b(track|artist|album):', caseSensitive: false).hasMatch(text)) {
    return false;
  }
  return true;
}

/// The extra queries to run next to the plain one: the title-targeted query
/// and, for a compound text, the title-and-artist one. Empty when the
/// provider has no such syntax. At most two, so a search never has more than
/// three requests at once.
List<String> targetedSongQueries(String extensionId, String query) {
  if (!TargetedSongSyntax.supports(extensionId) || !isPlainSongQuery(query)) {
    return const [];
  }
  final queries = <String>[];
  final byTitle = TargetedSongSyntax.titleQuery(extensionId, query);
  if (byTitle != null) queries.add(byTitle);
  final compound = parseCompoundSongQuery(query);
  if (compound != null) {
    final byBoth = TargetedSongSyntax.titleAndArtistQuery(
      extensionId,
      compound.title,
      compound.artist,
    );
    if (byBoth != null) queries.add(byBoth);
  }
  return queries;
}

final RegExp _noiseBracket = RegExp(
  r'\s*[\(\[]\s*(?:feat\b|ft\b|featuring\b|with\b|explicit\b|clean\b|'
  r'remaster|\d{4}\s+remaster|bonus\s+track)[^\)\]]*[\)\]]',
  caseSensitive: false,
);

final RegExp _noiseSuffix = RegExp(
  r'\s+-\s+(?:(?:\d{4}\s+)?remaster(?:ed)?(?:\s+\d{4})?(?:\s+version)?|'
  r'(?:feat|ft|featuring)\b.*|explicit)\s*$',
  caseSensitive: false,
);

/// Title without "(feat. ...)", "(Explicit)", "- Remastered" and the like,
/// normalized for comparison.
String cleanSongTitle(String title) {
  var value = title;
  value = value.replaceAll(_noiseBracket, '');
  value = value.replaceAll(_noiseSuffix, '');
  return normalizeSearchText(value);
}

bool _hasWords(String haystack, String needle) =>
    needle.isNotEmpty && ' $haystack '.contains(' $needle ');

List<String> songArtistParts(String artistName) => [
  for (final part in artistName.split(RegExp(r'\s*(?:,|&|;|/|\bfeat\b\.?)\s*')))
    if (normalizeSearchText(part).isNotEmpty) normalizeSearchText(part),
];

final RegExp _imitationMarker = RegExp(
  r'\b(?:cover|covers|tribute|tributo|homenaje|karaoke|type beat|remake|'
  r'made famous|originally performed|in the style of)\b',
  caseSensitive: false,
);

bool hasImitationMarker(String value) => _imitationMarker.hasMatch(value);

/// What the ranking needs from the typed text, computed once per search.
class SongQueryProfile {
  final String query;
  final String normalized;
  final String cleaned;
  final List<String> words;
  final List<({String title, String artist})> splits;

  SongQueryProfile._(this.query, this.normalized, this.cleaned, this.words, this.splits);

  factory SongQueryProfile(String query) {
    final normalized = normalizeSearchText(query);
    final compound = parseCompoundSongQuery(query);
    final splits = <({String title, String artist})>[];
    if (compound != null) {
      final title = cleanSongTitle(compound.title);
      final artist = normalizeSearchText(compound.artist);
      splits.add((title: title, artist: artist));
      if (compound.ambiguousOrder) {
        splits.add((
          title: cleanSongTitle(compound.artist),
          artist: normalizeSearchText(compound.title),
        ));
      }
    }
    return SongQueryProfile._(
      query,
      normalized,
      cleanSongTitle(query),
      normalized.isEmpty ? const [] : normalized.split(' '),
      splits,
    );
  }

  SongMatchTier tierOf(Track track, {Set<String> artistNames = const {}}) {
    final title = cleanSongTitle(track.name);
    if (title.isEmpty || normalized.isEmpty) return SongMatchTier.other;
    final artists = songArtistParts(track.artistName);
    if (artistNames.isNotEmpty && artists.any(artistNames.contains)) {
      return SongMatchTier.artist;
    }
    if (!hasImitationMarker(query) &&
        (hasImitationMarker(track.name) ||
            hasImitationMarker(track.albumName))) {
      return SongMatchTier.imitation;
    }

    for (final split in splits) {
      if (title == split.title &&
          artists.any(
            (artist) =>
                _hasWords(artist, split.artist) ||
                _hasWords(split.artist, artist),
          )) {
        return SongMatchTier.titleAndArtist;
      }
    }
    if (title.length >= 2 &&
        _hasWords(normalized, title) &&
        artists.any(
          (artist) =>
              _hasWords(normalized, artist) && !_hasWords(artist, title),
        )) {
      return SongMatchTier.titleAndArtist;
    }
    if (title == cleaned || title == normalized) {
      return SongMatchTier.exactTitle;
    }
    final fullTitle = normalizeSearchText(track.name);
    if (title.startsWith('$normalized ') ||
        fullTitle.startsWith('$normalized ')) {
      return SongMatchTier.titlePrefix;
    }
    final titleWords = fullTitle.split(' ').toSet();
    if (words.every(titleWords.contains)) return SongMatchTier.titleWords;
    return SongMatchTier.other;
  }
}

/// Artists, among the ones of [songs], that the text names: the text is the
/// artist's name, or (only for an artist the provider returned as an artist
/// result, [declaredArtists]) the beginning of it in whole words. Besides the
/// provider declaring it, the artist needs some weight: [score] above zero
/// for one of its songs (region popularity or the user's affinity). An
/// artist that is neither declared nor weighted never outranks a title.
Set<String> matchedArtistNames(
  Iterable<Track> songs,
  String query, {
  Iterable<String> declaredArtists = const [],
  double Function(Track track)? score,
}) {
  final text = normalizeSearchText(query);
  if (text.isEmpty) return const {};
  final declared = {
    for (final name in declaredArtists)
      if (normalizeSearchText(name).isNotEmpty) normalizeSearchText(name),
  };
  final matched = <String>{};
  final weighted = <String>{};
  for (final track in songs) {
    final points = score?.call(track) ?? 0;
    for (final artist in songArtistParts(track.artistName)) {
      final exact = artist == text;
      final prefix =
          declared.contains(artist) &&
          text.length >= 3 &&
          artist.startsWith('$text ');
      if (!exact && !prefix) continue;
      matched.add(artist);
      if (points > 0) weighted.add(artist);
    }
  }
  return {
    for (final artist in matched)
      if (declared.contains(artist) || weighted.contains(artist)) artist,
  };
}

/// The artist result the text names: its name equals the text or starts with
/// it in whole words. Null when none does.
Track? artistResultNamed(Iterable<Track> artists, String query) {
  final text = normalizeSearchText(query);
  if (text.isEmpty) return null;
  Track? prefix;
  for (final artist in artists) {
    final name = normalizeSearchText(artist.name);
    if (name == text) return artist;
    if (prefix == null && text.length >= 3 && name.startsWith('$text ')) {
      prefix = artist;
    }
  }
  return prefix;
}

String _dedupeKey(Track track) {
  final isrc = track.isrc?.trim();
  if (isrc != null && isrc.isNotEmpty) return 'isrc:${isrc.toUpperCase()}';
  return 'id:${track.source ?? ''}:${track.id}';
}

/// Merges the song lists of one search without duplicates (same ISRC, or same
/// id when there is none) and orders them by [SongMatchTier]. Inside a tier
/// the order is the one of [lists] (first list first, each in provider
/// order); when [regionalScore] is given, the songs it scores above zero go
/// first inside their tier, highest score first, and the rest keep the
/// provider order. The score never moves a song across tiers, except that it
/// can make a named artist count (see [matchedArtistNames]), whose songs lead.
List<Track> mergeRankedSongs(
  List<List<Track>> lists,
  String query, {
  int maxResults = songSearchMergedLimit,
  double Function(Track track)? regionalScore,
  Iterable<String> declaredArtists = const [],
}) {
  final profile = SongQueryProfile(query);
  final seen = <String>{};
  final unique = <Track>[];
  for (final list in lists) {
    for (final track in list) {
      if (seen.add(_dedupeKey(track))) unique.add(track);
    }
  }
  final artistNames = matchedArtistNames(
    unique,
    query,
    declaredArtists: declaredArtists,
    score: regionalScore,
  );
  final buckets = [for (final _ in SongMatchTier.values) <Track>[]];
  for (final track in unique) {
    buckets[profile.tierOf(track, artistNames: artistNames).index].add(track);
  }
  final merged = <Track>[];
  for (final bucket in buckets) {
    final ordered = regionalScore == null
        ? bucket
        : _regionalOrder(bucket, regionalScore);
    for (final track in ordered) {
      if (merged.length >= maxResults) return merged;
      merged.add(track);
    }
  }
  return merged;
}

List<Track> _regionalOrder(
  List<Track> bucket,
  double Function(Track track) score,
) {
  final scored = <({Track track, double points, int index})>[];
  final rest = <Track>[];
  for (var i = 0; i < bucket.length; i++) {
    final points = score(bucket[i]);
    if (points > 0) {
      scored.add((track: bucket[i], points: points, index: i));
    } else {
      rest.add(bucket[i]);
    }
  }
  if (scored.isEmpty) return bucket;
  scored.sort((a, b) {
    final byPoints = b.points.compareTo(a.points);
    return byPoints != 0 ? byPoints : a.index.compareTo(b.index);
  });
  return [for (final item in scored) item.track, ...rest];
}
