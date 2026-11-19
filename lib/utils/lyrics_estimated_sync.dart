import 'package:mornye/utils/lyrics_parser.dart';

/// A bracketed section name such as a verse or chorus label, never sung.
final _sectionLabel = RegExp(r'^\s*[\[(][^\])]{1,40}[\])]\s*$');

final _vowelGroup = RegExp(
  r'[aeiouyáéíóúàèìòùâêîôûäëïöüãõåæœ]+',
  caseSensitive: false,
  unicode: true,
);

/// How long a line takes to sing, in syllable-like units. Latin text counts
/// vowel groups; scripts without them fall back to the character count.
int lyricsLineWeight(String text) {
  final letters = text.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
  if (letters.isEmpty) return 1;
  final groups = _vowelGroup.allMatches(text).length;
  final weight = groups >= letters.length / 5 ? groups : letters.length ~/ 2;
  return weight < 1 ? 1 : weight;
}

/// Spreads the lines of [plainText] over [duration] with a realistic shape:
/// an intro before the first line, a closing after the last, a longer pause
/// at every blank line between stanzas, and each line lasting in proportion
/// to its syllables. Returns no lines when there is nothing to place.
List<LyricLine> estimateSyncedLines({
  required String plainText,
  required Duration duration,
}) {
  if (duration <= Duration.zero) return const [];
  final rows = <({String text, bool breakBefore})>[];
  var pendingBreak = false;
  for (final raw in plainText.split(RegExp(r'\r?\n'))) {
    final text = raw.trim();
    if (text.isEmpty) {
      pendingBreak = rows.isNotEmpty;
      continue;
    }
    if (_sectionLabel.hasMatch(text)) {
      pendingBreak = rows.isNotEmpty;
      continue;
    }
    rows.add((text: text, breakBefore: pendingBreak));
    pendingBreak = false;
  }
  if (rows.isEmpty) return const [];

  final totalMs = duration.inMilliseconds.toDouble();
  final introMs = (totalMs * 0.06).clamp(8000.0, 15000.0);
  final outroMs = (totalMs * 0.04).clamp(5000.0, 10000.0);
  var singable = totalMs - introMs - outroMs;
  var intro = introMs;
  if (singable < totalMs * 0.5) {
    singable = totalMs * 0.5;
    intro = (totalMs - singable) * 0.6;
  }
  final stanzaBreaks = rows.where((row) => row.breakBefore).length;
  final pauseMs = stanzaBreaks == 0
      ? 0.0
      : (singable * 0.03).clamp(0.0, 3000.0).toDouble();
  final singing = singable - pauseMs * stanzaBreaks;
  final weights = [for (final row in rows) lyricsLineWeight(row.text)];
  final totalWeight = weights.fold<int>(0, (sum, weight) => sum + weight);

  final lines = <LyricLine>[];
  var cursor = intro;
  for (var i = 0; i < rows.length; i++) {
    if (rows[i].breakBefore) cursor += pauseMs;
    final share = singing * weights[i] / totalWeight;
    lines.add(
      LyricLine(
        time: Duration(milliseconds: cursor.round()),
        end: Duration(milliseconds: (cursor + share).round()),
        text: rows[i].text,
      ),
    );
    cursor += share;
  }
  return lines;
}

/// Lyrics with estimated timing for [plain], or null when it cannot be done.
ParsedLyrics? estimatedLyricsFor(ParsedLyrics plain, Duration? duration) {
  if (plain.synced || duration == null) return null;
  final text = plain.plainText.trim().isNotEmpty
      ? plain.plainText
      : plain.lines.map((line) => line.text).join('\n');
  final lines = estimateSyncedLines(plainText: text, duration: duration);
  if (lines.length < 2) return null;
  return ParsedLyrics(
    synced: true,
    wordSynced: false,
    lines: lines,
    plainText: plain.plainText,
    writers: plain.writers,
    provider: plain.provider,
    estimated: true,
  );
}

/// Whether [candidate] may take the place of the lyrics on screen: synced
/// text replaces plain text, and plain text never replaces synced text.
bool lyricsUpgradeAllowed({
  required ParsedLyrics current,
  required ParsedLyrics candidate,
}) {
  final currentIsSynced = current.synced && !current.estimated;
  if (candidate.estimated) return !currentIsSynced;
  if (currentIsSynced) return candidate.synced;
  return true;
}
