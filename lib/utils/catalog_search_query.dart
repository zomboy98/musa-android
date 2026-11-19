const _diacriticGroups = <String, String>{
  'a': 'àáâãäåāăą',
  'c': 'çćĉč',
  'd': 'ďđ',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğģ',
  'h': 'ĥ',
  'i': 'ìíîïĩīĭįı',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľł',
  'n': 'ñńņň',
  'o': 'òóôõöøōŏő',
  'r': 'ŕŗř',
  's': 'śŝşš',
  't': 'ţť',
  'u': 'ùúûüũūŭůűų',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
  'ss': 'ß',
  'ae': 'æ',
  'oe': 'œ',
  'th': 'þ',
};

final _diacriticMap = {
  for (final entry in _diacriticGroups.entries)
    for (final rune in entry.value.runes) String.fromCharCode(rune): entry.key,
};

final _bracketGroup = RegExp(r'\(([^()]*)\)|\[([^\[\]]*)\]');
final _creditStart = RegExp(
  r'^(?:from\s|feat\b|ft\b|featuring\s|with\s|prod\b|produced\b|con\s|part\.|participa)',
  caseSensitive: false,
);
final _versionWord = RegExp(
  r'\b(?:remaster(?:ed)?|live|deluxe|version|mono|stereo|bonus|edit|radio|single|album|mix|remix|acoustic|demo|instrumental|explicit|clean|\d{4})\b',
  caseSensitive: false,
);
final _dashSuffix = RegExp(r'\s+[-–—]\s+(.*)$');
final _inlineCredit = RegExp(
  r'\s+(?:feat\.?|ft\.?|featuring|prod\.?|part\.)\s+.*$',
  caseSensitive: false,
);
final _artistSeparator = RegExp(
  r'\s*(?:,|;|&|\+|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?|\bwith\b)\s*|\s+(?:x|y|e)\s+',
  caseSensitive: false,
);
final _quotes = RegExp('[\'’‘ʼ`´"“”„«»‹›]');

String foldDiacritics(String value) {
  final out = StringBuffer();
  for (final rune in value.runes) {
    final char = String.fromCharCode(rune);
    out.write(_diacriticMap[char] ?? _diacriticMap[char.toLowerCase()] ?? char);
  }
  return out.toString();
}

String _plain(String value) {
  var text = foldDiacritics(value).toLowerCase();
  text = text.replaceAll(r'$', 's').replaceAll(_quotes, '');
  text = text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ');
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Title as providers index it: credits, version suffixes, accents, quotes and
/// punctuation removed. Falls back to the plain original when nothing is left.
String simplifiedSearchTitle(String title) {
  var text = title.replaceAllMapped(_bracketGroup, (match) {
    final content = (match.group(1) ?? match.group(2) ?? '').trim();
    return _creditStart.hasMatch(content) || _versionWord.hasMatch(content)
        ? ''
        : match.group(0)!;
  });
  final dash = _dashSuffix.firstMatch(text);
  if (dash != null) {
    final tail = dash.group(1) ?? '';
    if (_versionWord.hasMatch(tail) || _creditStart.hasMatch(tail)) {
      text = text.substring(0, dash.start);
    }
  }
  text = text.replaceFirst(_inlineCredit, '');
  final simple = _plain(text);
  return simple.isEmpty ? _plain(title) : simple;
}

/// Main artist of a credit line such as `A, B & C feat. D`.
String simplifiedSearchArtist(String artist) {
  final parts = artist.split(_artistSeparator);
  for (final part in parts) {
    final simple = _plain(part);
    if (simple.isNotEmpty) return simple;
  }
  return _plain(artist);
}

String normalizeSearchWhitespace(String value) => value
    .replaceAll(RegExp('[‘’ʼ]'), "'")
    .replaceAll(RegExp('[“”„]'), '"')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
