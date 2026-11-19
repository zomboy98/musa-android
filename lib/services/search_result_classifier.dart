import 'package:mornye/models/track.dart';

/// Pure classification, de-duplication and relevance ordering of the
/// collection results (artists, albums, playlists) of a search.
///
/// Providers sometimes declare a derived list ("Some Artist Mix",
/// "Another Artist Hits", "Artist - Topic") as an `artist`. The rules here are
/// conservative: the declared `item_type` is respected unless there is clear
/// evidence of a mistake.

/// Final kind of a search result.
enum SearchResultKind { artist, album, playlist, song }

/// One classified result. [track] carries the normalized `itemType`, so the
/// existing `isArtistItem`/`isPlaylistItem`/`isAlbumItem` getters are correct
/// downstream. [originalIndex] is the index in the provider's list.
class ClassifiedSearchItem {
  final Track track;
  final SearchResultKind kind;
  final int originalIndex;

  /// True when the provider declared an artist and the app demoted it.
  final bool demotedFromArtist;

  const ClassifiedSearchItem({
    required this.track,
    required this.kind,
    required this.originalIndex,
    this.demotedFromArtist = false,
  });
}

class ClassifiedSearchResults {
  final List<ClassifiedSearchItem> artists;
  final List<ClassifiedSearchItem> albums;
  final List<ClassifiedSearchItem> playlists;

  /// Songs keep the provider order; they are never merged or dropped.
  final List<ClassifiedSearchItem> songs;

  const ClassifiedSearchResults({
    required this.artists,
    required this.albums,
    required this.playlists,
    required this.songs,
  });
}

/// Lower-cases, strips accents and punctuation and collapses spaces.
String normalizeSearchText(String value) {
  final buffer = StringBuffer();
  for (final rune in value.toLowerCase().runes) {
    final char = String.fromCharCode(rune);
    final mapped = _accentMap[char] ?? char;
    for (final unit in mapped.runes) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLatin = unit >= 0x61 && unit <= 0x7a;
      // Keep every non-ASCII letter (CJK, Cyrillic...) as a word character.
      final isOtherLetter = unit > 0x7f && !_isSymbolOrSpace(unit);
      buffer.writeCharCode(isDigit || isLatin || isOtherLetter ? unit : 0x20);
    }
  }
  return buffer.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _isSymbolOrSpace(int unit) =>
    (unit >= 0x2000 && unit <= 0x2bff) ||
    (unit >= 0x3000 && unit <= 0x303f) ||
    (unit >= 0xff00 && unit <= 0xff0f) ||
    unit == 0xa0;

const Map<String, String> _accentMap = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'å': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ø': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
  'ß': 'ss',
};

/// Words that name a collection rather than a person (accent-free).
const Set<String> _genericWords = {
  'mix',
  'mixes',
  'hits',
  'hit',
  'radio',
  'playlist',
  'playlists',
  'lista',
  'listas',
  'essentials',
  'essential',
  'esenciales',
  'best',
  'top',
  'exitos',
  'canciones',
  'cancion',
  'musica',
  'music',
  'songs',
  'greatest',
  'coleccion',
  'collection',
  'topic',
  'official',
  'oficial',
  'vevo',
  'mejor',
  'mejores',
  'completo',
  'discografia',
  'discography',
  'clasicos',
  'classics',
  'favoritas',
  'favorites',
  'exitazos',
  'rolitas',
  'albums',
  'albumes',
  'karaoke',
  'instrumental',
  'remixes',
};

/// Connectors allowed around a generic word ("Best Of", "Lo mejor de").
const Set<String> _connectorWords = {
  'de',
  'del',
  'la',
  'las',
  'el',
  'lo',
  'los',
  'the',
  'of',
  'y',
  'and',
  'en',
  'a',
  'this',
  'is',
  'este',
  'es',
  'by',
  'para',
  'for',
  'with',
};

/// Leading phrases that mark a list on their own ("This Is X").
const List<List<String>> _leadingListPhrases = [
  ['this', 'is'],
  ['best', 'of'],
  ['the', 'best', 'of'],
  ['lo', 'mejor', 'de'],
  ['greatest', 'hits'],
  ['mix', 'de'],
  ['radio', 'de'],
  ['essentials'],
];

/// `album_type` values that state the item is a list.
const Set<String> _listAlbumTypes = {
  'playlist',
  'collection',
  'mix',
  'radio',
  'chart',
  'channel',
};

String _declaredType(String? raw) {
  final value = (raw ?? '').trim().toLowerCase();
  return switch (value) {
    'artist' || 'artists' => 'artist',
    'album' || 'albums' || 'single' || 'ep' => 'album',
    'playlist' || 'playlists' || 'mix' || 'collection' => 'playlist',
    _ => value,
  };
}

SearchResultKind _kindOfDeclared(String declared) => switch (declared) {
  'artist' => SearchResultKind.artist,
  'album' => SearchResultKind.album,
  'playlist' => SearchResultKind.playlist,
  _ => SearchResultKind.song,
};

String _itemTypeOf(SearchResultKind kind) => switch (kind) {
  SearchResultKind.artist => 'artist',
  SearchResultKind.album => 'album',
  SearchResultKind.playlist => 'playlist',
  SearchResultKind.song => 'track',
};

List<String> _tokens(String normalized) =>
    normalized.isEmpty ? const [] : normalized.split(' ');

bool _isFiller(String token) =>
    _genericWords.contains(token) ||
    _connectorWords.contains(token) ||
    RegExp(r'^\d+$').hasMatch(token);

/// Result of splitting a name into a core and generic edge words.
class _EdgeSplit {
  final List<String> core;
  final bool trailing;
  final bool leading;
  const _EdgeSplit(this.core, {this.trailing = false, this.leading = false});
  bool get hasEdge => trailing || leading;
}

/// Splits [tokens] into the core name plus a generic tail and/or head. The
/// core must keep at least one token that is neither generic nor a connector.
_EdgeSplit _splitEdges(List<String> tokens) {
  var start = 0;
  var end = tokens.length;
  var sawGenericTail = false;
  var sawGenericHead = false;

  // Tail: filler tokens, at least one real generic word among them.
  var tailStart = end;
  while (tailStart > 0 && _isFiller(tokens[tailStart - 1])) {
    tailStart--;
  }
  if (tailStart < end &&
      tokens.sublist(tailStart, end).any(_genericWords.contains) &&
      tailStart > 0) {
    // Trim connectors that belong to the core ("de" right before the tail is
    // part of the tail; none of them can end the core).
    end = tailStart;
    sawGenericTail = true;
  }

  // Head: a known leading phrase or a run of filler with a generic word.
  var headEnd = start;
  while (headEnd < end && _isFiller(tokens[headEnd])) {
    headEnd++;
  }
  if (headEnd > start && headEnd < end) {
    final head = tokens.sublist(start, headEnd);
    final isKnownPhrase = _leadingListPhrases.any(
      (phrase) =>
          head.length >= phrase.length &&
          _listEquals(head.sublist(0, phrase.length), phrase),
    );
    // A single leading word ("Radio Futura", "Top Gear") is too weak; only
    // longer/known phrases count.
    final hasGeneric = head.any(_genericWords.contains);
    if (isKnownPhrase || (hasGeneric && head.length >= 2)) {
      start = headEnd;
      sawGenericHead = true;
    }
  }

  final core = tokens.sublist(start, end);
  final hasRealCore = core.any((t) => !_isFiller(t));
  if (!hasRealCore) return _EdgeSplit(tokens);
  return _EdgeSplit(core, trailing: sawGenericTail, leading: sawGenericHead);
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

int _editDistanceAtMost1(String a, String b) {
  if (a == b) return 0;
  if ((a.length - b.length).abs() > 1) return 2;
  var i = 0;
  while (i < a.length && i < b.length && a[i] == b[i]) {
    i++;
  }
  if (a.length == b.length) {
    return a.substring(i + 1) == b.substring(i + 1) ? 1 : 2;
  }
  final shorter = a.length < b.length ? a : b;
  final longer = a.length < b.length ? b : a;
  return shorter.substring(i) == longer.substring(i + 1) ? 1 : 2;
}

/// Same name, or the same name with a single one-letter spelling difference
/// in one token ("Double" / "Doble").
bool _sameNameOrSpellingVariant(List<String> a, List<String> b) {
  if (a.isEmpty || a.length != b.length) return false;
  var differing = 0;
  for (var i = 0; i < a.length; i++) {
    if (a[i] == b[i]) continue;
    if (a[i].length < 4 || b[i].length < 4) return false;
    if (_editDistanceAtMost1(a[i], b[i]) > 1) return false;
    differing++;
    if (differing > 1) return false;
  }
  return true;
}

bool _hasText(String? value) => value != null && value.trim().isNotEmpty;

/// The provider recognizes the item as an artist (it gives an artist id).
bool _hasArtistSignal(Track t) => _hasText(t.artistId);

bool _statesList(Track t) =>
    _listAlbumTypes.contains((t.albumType ?? '').trim().toLowerCase());

class _Entry {
  final Track track;
  final int index;
  final String name;
  final List<String> tokens;
  SearchResultKind kind;
  bool demoted = false;
  _Entry(this.track, this.index, this.name, this.tokens, this.kind);
}

/// Classifies [tracks] and returns the four sections, de-duplicated and
/// ordered by relevance to [query] (the provider order breaks ties).
ClassifiedSearchResults classifySearchResults(
  List<Track> tracks, {
  String query = '',
}) {
  final queryTokens = _tokens(normalizeSearchText(query));

  final entries = <_Entry>[];
  for (var i = 0; i < tracks.length; i++) {
    final track = tracks[i];
    final name = normalizeSearchText(track.name);
    entries.add(
      _Entry(
        track,
        i,
        name,
        _tokens(name),
        _kindOfDeclared(_declaredType(track.itemType)),
      ),
    );
  }

  // Anchors: declared artists whose own name is not a list-like name.
  final anchors = <_Entry>[
    for (final e in entries)
      if (e.kind == SearchResultKind.artist &&
          e.tokens.isNotEmpty &&
          !_splitEdges(e.tokens).hasEdge)
        e,
  ];

  for (final e in entries) {
    if (e.kind != SearchResultKind.artist || e.tokens.isEmpty) continue;
    if (_shouldDemote(e, anchors, queryTokens)) {
      e.kind = SearchResultKind.playlist;
      e.demoted = true;
    }
  }

  final sections = <SearchResultKind, List<_Entry>>{
    for (final kind in SearchResultKind.values) kind: <_Entry>[],
  };
  for (final e in entries) {
    sections[e.kind]!.add(e);
  }

  final artists = _finalizeCollection(
    sections[SearchResultKind.artist]!,
    queryTokens,
  );
  final albums = _finalizeCollection(
    sections[SearchResultKind.album]!,
    queryTokens,
  );
  final playlists = _finalizeCollection(
    sections[SearchResultKind.playlist]!,
    queryTokens,
  );

  return ClassifiedSearchResults(
    artists: artists,
    albums: albums,
    playlists: playlists,
    songs: [
      for (final e in sections[SearchResultKind.song]!)
        ClassifiedSearchItem(
          track: e.track,
          kind: SearchResultKind.song,
          originalIndex: e.index,
        ),
    ],
  );
}

bool _shouldDemote(_Entry e, List<_Entry> anchors, List<String> queryTokens) {
  // (c) The source states it is a list.
  if (_statesList(e.track)) return true;

  final split = _splitEdges(e.tokens);
  if (!split.hasEdge) return false;

  // (a) Core equals (or spells like) the name of ANOTHER artist in the
  // results.
  for (final other in anchors) {
    if (identical(other, e)) continue;
    if (_sameNameOrSpellingVariant(split.core, other.tokens)) return true;
  }

  // (b) No artist signal from the source; generic words the user typed
  // themselves do not count.
  if (_hasArtistSignal(e.track)) return false;
  final edgeTokens = e.tokens.where((t) => !split.core.contains(t));
  final genericEdge = edgeTokens.where(_genericWords.contains);
  if (genericEdge.isEmpty) return false;
  final typedByUser = genericEdge.any(
    (g) => queryTokens.any((q) => q.length >= 2 && g.startsWith(q)),
  );
  return !typedByUser;
}

/// 3: every query token is a prefix of a name token, in order.
/// 2: partial (several tokens, or all out of order).
/// 1: a single token matches (prefix).
/// 0: only a substring match. -1: no token matches (kept, but last).
int _relevance(List<String> nameTokens, List<String> queryTokens) {
  if (queryTokens.isEmpty) return 3;
  var cursor = 0;
  var inOrder = true;
  for (final q in queryTokens) {
    var found = -1;
    for (var j = cursor; j < nameTokens.length; j++) {
      if (nameTokens[j].startsWith(q)) {
        found = j;
        break;
      }
    }
    if (found < 0) {
      inOrder = false;
      break;
    }
    cursor = found + 1;
  }
  if (inOrder) return 3;

  final matched = queryTokens
      .where((q) => nameTokens.any((n) => n.startsWith(q)))
      .length;
  if (matched == queryTokens.length || matched >= 2) return 2;
  if (matched == 1) return 1;
  final anySubstring = queryTokens.any(
    (q) => q.length >= 3 && nameTokens.any((n) => n.contains(q)),
  );
  return anySubstring ? 0 : -1;
}

List<ClassifiedSearchItem> _finalizeCollection(
  List<_Entry> entries,
  List<String> queryTokens,
) {
  final merged = _dedupe(entries);

  final scored = <(_Entry, int)>[];
  for (final e in merged) {
    // Nothing is dropped: a provider may match on aliases or fields the
    // name does not show, so a non-matching item simply goes last.
    scored.add((e, _relevance(e.tokens, queryTokens)));
  }
  // Stable by construction: ties fall back to the provider position.
  scored.sort((a, b) {
    final byScore = b.$2.compareTo(a.$2);
    return byScore != 0 ? byScore : a.$1.index.compareTo(b.$1.index);
  });

  return [
    for (final (e, _) in scored)
      ClassifiedSearchItem(
        track: _withFinalType(e),
        kind: e.kind,
        originalIndex: e.index,
        demotedFromArtist: e.demoted,
      ),
  ];
}

Track _withFinalType(_Entry e) {
  final type = _itemTypeOf(e.kind);
  return e.track.itemType == type ? e.track : e.track.copyWith(itemType: type);
}

String _ownerKey(_Entry e) {
  // Albums/playlists with one name but another owner are different things.
  if (e.kind == SearchResultKind.artist) return '';
  return normalizeSearchText(e.track.artistName);
}

bool _sameProvider(Track a, Track b) =>
    (a.source ?? '').trim() == (b.source ?? '').trim();

bool _idsCompatible(Track a, Track b) {
  final ia = a.id.trim();
  final ib = b.id.trim();
  return ia.isEmpty || ib.isEmpty || ia == ib;
}

List<_Entry> _dedupe(List<_Entry> entries) {
  final kept = <_Entry>[];
  final replacements = <_Entry, Track>{};

  for (final e in entries) {
    _Entry? target;
    for (final k in kept) {
      if (k.kind != e.kind || !_sameProvider(k.track, e.track)) continue;
      final exactName = k.name == e.name && _ownerKey(k) == _ownerKey(e);
      final exact = exactName && _idsCompatible(k.track, e.track);
      // Same artist spelled slightly differently; both need artist signals.
      final variant =
          e.kind == SearchResultKind.artist &&
          !exactName &&
          _hasArtistSignal(k.track) &&
          _hasArtistSignal(e.track) &&
          _sameNameOrSpellingVariant(k.tokens, e.tokens);
      if (exact || variant) {
        target = k;
        break;
      }
    }
    if (target == null) {
      kept.add(e);
      continue;
    }
    replacements[target] = _mergeTracks(
      replacements[target] ?? target.track,
      e.track,
    );
  }

  return [
    for (final k in kept)
      if (replacements.containsKey(k))
        (_Entry(replacements[k]!, k.index, k.name, k.tokens, k.kind)
          ..demoted = k.demoted)
      else
        k,
  ];
}

/// Keeps [a] (the more relevant) and fills what it lacks from [b]: best
/// image and the most reliable id.
Track _mergeTracks(Track a, Track b) {
  final aCover = _hasText(a.coverUrl);
  final bCover = _hasText(b.coverUrl);
  final aId = a.id.trim().isNotEmpty;
  final bId = b.id.trim().isNotEmpty;
  return a.copyWith(
    coverUrl: !aCover && bCover ? b.coverUrl : null,
    id: !aId && bId ? b.id : null,
    artistId: !_hasText(a.artistId) && _hasText(b.artistId) ? b.artistId : null,
    totalTracks: a.totalTracks == null && b.totalTracks != null
        ? b.totalTracks
        : null,
  );
}
