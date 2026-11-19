import 'package:mornye/utils/lyrics_parser.dart';

/// Lead applied to synced lyrics on a Bluetooth output, whose audio reaches
/// the ear later than the position the player reports.
const int kBluetoothLyricsCompensationMs = 170;

/// How much earlier than the reported position a line and its words light up,
/// so the highlight lands as the word is heard rather than after it.
const int kLyricsLookAheadMs = 200;

/// Widest shift the per-track timing control accepts.
const int kMaxTrackLyricsOffsetMs = 15000;

/// An automatic correction below this is noise; above the maximum it is a
/// different recording rather than a timing shift.
const int kMinAutoLyricsOffsetMs = 400;
const int kMaxAutoLyricsOffsetMs = 8000;

const Duration _preferredTolerance = Duration(seconds: 3);
const Duration _acceptedTolerance = Duration(seconds: 10);

/// How far the timing of synced lyrics can be trusted for a given track.
enum LyricsSyncConfidence {
  /// The track length is not known, so nothing can be compared.
  unknown,
  high,
  low,
  suspect,
}

int _rank(LyricsSyncConfidence value) => switch (value) {
  LyricsSyncConfidence.high => 0,
  LyricsSyncConfidence.unknown => 1,
  LyricsSyncConfidence.low => 2,
  LyricsSyncConfidence.suspect => 3,
};

/// Whether [a] is a better timing guarantee than [b].
bool lyricsConfidenceBeats(LyricsSyncConfidence a, LyricsSyncConfidence b) =>
    _rank(a) < _rank(b);

/// The first and last line start times, for diagnostics and comparison.
class LyricsSpan {
  const LyricsSpan(this.first, this.last);

  final Duration first;
  final Duration last;
}

LyricsSpan? lyricsSpan(List<LyricLine> lines) {
  Duration? first;
  Duration? last;
  for (final line in lines) {
    if (line.text.trim().isEmpty) continue;
    if (first == null || line.time < first) first = line.time;
    if (last == null || line.time > last) last = line.time;
  }
  return first == null ? null : LyricsSpan(first, last!);
}

/// The `[length: mm:ss]` an LRC file declares, when it has one.
Duration? lrcDeclaredLength(String raw) {
  final match = RegExp(
    r'^\s*\[length:\s*(?:(\d+):)?(\d+):(\d+)(?:[.,](\d+))?\s*\]',
    caseSensitive: false,
    multiLine: true,
  ).firstMatch(raw);
  if (match == null) return null;
  final hours = int.tryParse(match.group(1) ?? '0') ?? 0;
  final minutes = int.parse(match.group(2)!);
  final seconds = int.parse(match.group(3)!);
  final fraction = match.group(4);
  final millis = fraction == null
      ? 0
      : int.parse(fraction.padRight(3, '0').substring(0, 3));
  return Duration(
    hours: hours,
    minutes: minutes,
    seconds: seconds,
    milliseconds: millis,
  );
}

/// Compares the timing of synced [lines] with the length of the track being
/// played. A declared length (LRC `[length:]`) is compared directly; without
/// it the last sung line must fall inside the track, and a track that goes on
/// silent for far longer than a normal outro does not match either.
LyricsSyncConfidence lyricsDurationConfidence({
  required List<LyricLine> lines,
  required Duration? trackDuration,
  Duration? declaredLength,
}) {
  if (trackDuration == null || trackDuration <= Duration.zero) {
    return LyricsSyncConfidence.unknown;
  }
  LyricsSyncConfidence byDifference(Duration difference) {
    final gap = difference.abs();
    if (gap <= _preferredTolerance) return LyricsSyncConfidence.high;
    if (gap <= _acceptedTolerance) return LyricsSyncConfidence.low;
    return LyricsSyncConfidence.suspect;
  }

  if (declaredLength != null && declaredLength > Duration.zero) {
    return byDifference(declaredLength - trackDuration);
  }
  final span = lyricsSpan(lines);
  if (span == null) return LyricsSyncConfidence.unknown;
  final overrun = span.last - trackDuration;
  if (overrun > _acceptedTolerance) return LyricsSyncConfidence.suspect;
  if (overrun > _preferredTolerance) return LyricsSyncConfidence.low;
  final tail = trackDuration - span.last;
  final allowedTailMs = (trackDuration.inMilliseconds * 0.25).round();
  final allowedTail = Duration(
    milliseconds: allowedTailMs < 60000 ? 60000 : allowedTailMs,
  );
  if (tail > allowedTail) return LyricsSyncConfidence.suspect;
  return LyricsSyncConfidence.high;
}

String _normalized(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

/// The constant shift, in ms, that makes [candidate] line up with
/// [reference], from the median difference of lines with the same text.
/// Null unless enough lines agree and the shift is a plausible timing error.
int? estimateConstantOffsetMs({
  required List<LyricLine> reference,
  required List<LyricLine> candidate,
  int minMatches = 4,
}) {
  final byText = <String, List<int>>{};
  for (final line in reference) {
    final key = _normalized(line.text);
    if (key.isEmpty || line.isBackground) continue;
    byText.putIfAbsent(key, () => []).add(line.time.inMilliseconds);
  }
  final differences = <int>[];
  for (final line in candidate) {
    final key = _normalized(line.text);
    final times = byText[key];
    if (key.isEmpty || line.isBackground || times == null) continue;
    final time = line.time.inMilliseconds;
    var best = times.first;
    for (final other in times) {
      if ((other - time).abs() < (best - time).abs()) best = other;
    }
    differences.add(best - time);
  }
  if (differences.length < minMatches) return null;
  differences.sort();
  final middle = differences.length ~/ 2;
  final median = differences.length.isOdd
      ? differences[middle]
      : ((differences[middle - 1] + differences[middle]) / 2).round();
  final agreeing = differences.where((d) => (d - median).abs() <= 500).length;
  if (agreeing < differences.length * 0.7) return null;
  final magnitude = median.abs();
  if (magnitude <= kMinAutoLyricsOffsetMs ||
      magnitude > kMaxAutoLyricsOffsetMs) {
    return null;
  }
  return (median / 10).round() * 10;
}

/// The shift in effect for one track: the listener's setting plus either
/// their own correction for the track or, without one, the automatic estimate
/// and the output latency compensation, less the highlight look-ahead.
int effectiveLyricsOffsetMs({
  required int globalMs,
  int? trackMs,
  int autoMs = 0,
  bool bluetooth = false,
  int lookAheadMs = kLyricsLookAheadMs,
}) {
  final track =
      trackMs ?? autoMs + (bluetooth ? kBluetoothLyricsCompensationMs : 0);
  return globalMs + track - lookAheadMs;
}

/// The per-track shift that puts the line starting at [lineTime] at the
/// moment [tapPosition] the listener heard it begin.
int trackOffsetFromTap({
  required Duration tapPosition,
  required Duration lineTime,
  required int globalMs,
}) => (tapPosition - lineTime).inMilliseconds - globalMs;

int clampTrackLyricsOffsetMs(int value) =>
    value.clamp(-kMaxTrackLyricsOffsetMs, kMaxTrackLyricsOffsetMs);

/// The single diagnostic line for one lyrics display; carries no lyrics text.
String lyricsSyncLogLine({
  required String? provider,
  required Duration? trackDuration,
  required LyricsSpan? span,
  required LyricsSyncConfidence confidence,
  required int autoMs,
  required int? trackMs,
  String kind = 'synced',
  String upgrade = 'none',
}) =>
    'lyrics-sync: provider=${provider ?? '?'} '
    'dur=${trackDuration?.inMilliseconds ?? 0} '
    'first=${span?.first.inMilliseconds ?? -1} '
    'last=${span?.last.inMilliseconds ?? -1} '
    'conf=${confidence.name} auto=$autoMs track=${trackMs ?? 0}ms '
    'ahead=${kLyricsLookAheadMs}ms bt=${kBluetoothLyricsCompensationMs}ms '
    'kind=$kind upgrade=$upgrade';
