import 'package:mornye/utils/lyrics_draft.dart';

/// A line the user corrected over the text a provider served. Only the
/// corrected line is kept, never the whole lyrics.
class LyricsLinePatch {
  const LyricsLinePatch({
    required this.timeMs,
    required this.originalHash,
    required this.text,
  });

  /// When the line is sung. Lines without a time are numbered `-1 - index`.
  final int timeMs;

  /// [lyricsLineHash] of the provider's text, so a changed line is not
  /// overwritten by a correction made for another wording.
  final String originalHash;
  final String text;

  Map<String, Object> toJson() => {'t': timeMs, 'h': originalHash, 'x': text};

  static LyricsLinePatch? fromJson(Object? json) {
    if (json is! Map) return null;
    final time = json['t'];
    final hash = json['h'];
    final text = json['x'];
    if (time is! int || hash is! String || text is! String) return null;
    return LyricsLinePatch(timeMs: time, originalHash: hash, text: text);
  }

  @override
  bool operator ==(Object other) =>
      other is LyricsLinePatch &&
      other.timeMs == timeMs &&
      other.originalHash == originalHash &&
      other.text == text;

  @override
  int get hashCode => Object.hash(timeMs, originalHash, text);
}

/// A stable 64-bit FNV-1a hash of [text] ignoring spacing differences, as hex.
String lyricsLineHash(String text) {
  final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  var hash = 0xcbf29ce484222325;
  for (final unit in normalized.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// The key a track's corrections are stored under: its ISRC, else its
/// catalog identity, else artist, title and rounded duration.
String lyricsCorrectionKey({
  String? isrc,
  String? catalogSource,
  String? catalogId,
  required String artist,
  required String title,
  required int durationMs,
}) {
  final code = (isrc ?? '').trim().toUpperCase().replaceAll(
    RegExp(r'[-\s]'),
    '',
  );
  if (code.isNotEmpty) return 'isrc:$code';
  final source = (catalogSource ?? '').trim().toLowerCase();
  final id = (catalogId ?? '').trim();
  if (source.isNotEmpty && id.isNotEmpty) return 'catalog:$source:$id';
  final seconds = (durationMs / 1000).round();
  return 'track:${artist.trim().toLowerCase()}|${title.trim().toLowerCase()}|$seconds';
}

int _slot(LyricsDraftLine line, int index) =>
    line.time?.inMilliseconds ?? -1 - index;

/// The lyrics with the corrections that still match applied, and how many
/// did not because the provider's line is no longer the one corrected.
class LyricsCorrectionResult {
  const LyricsCorrectionResult({
    required this.raw,
    required this.applied,
    required this.obsolete,
  });

  final String raw;
  final int applied;
  final int obsolete;
}

LyricsCorrectionResult applyLyricsPatches(
  String raw,
  List<LyricsLinePatch> patches,
) {
  if (patches.isEmpty || raw.trim().isEmpty || !LyricsDraft.canEdit(raw)) {
    return LyricsCorrectionResult(raw: raw, applied: 0, obsolete: 0);
  }
  final draft = LyricsDraft.parse(raw);
  final lines = [...draft.lines];
  var applied = 0;
  for (final patch in patches) {
    var index = -1;
    for (final (position, line) in lines.indexed) {
      if (_slot(line, position) == patch.timeMs &&
          lyricsLineHash(line.text) == patch.originalHash) {
        index = position;
        break;
      }
    }
    if (index < 0) continue;
    lines[index] = lines[index].copyWith(text: patch.text);
    applied++;
  }
  if (applied == 0) {
    return LyricsCorrectionResult(
      raw: raw,
      applied: 0,
      obsolete: patches.length,
    );
  }
  return LyricsCorrectionResult(
    raw: LyricsDraft(
      header: draft.header,
      footer: draft.footer,
      lines: lines,
    ).toLrc(),
    applied: applied,
    obsolete: patches.length - applied,
  );
}

/// The corrections that turn [servedRaw] into [editedRaw]: lines at the same
/// time whose text changed. Added, removed and retimed lines are not
/// corrections and are left out.
List<LyricsLinePatch> diffLyricsPatches(String servedRaw, String editedRaw) {
  if (!LyricsDraft.canEdit(servedRaw) || !LyricsDraft.canEdit(editedRaw)) {
    return const [];
  }
  final served = LyricsDraft.parse(servedRaw).lines;
  final edited = LyricsDraft.parse(editedRaw).lines;
  final editedBySlot = <int, LyricsDraftLine>{
    for (final (index, line) in edited.indexed) _slot(line, index): line,
  };
  final patches = <LyricsLinePatch>[];
  for (final (index, line) in served.indexed) {
    final slot = _slot(line, index);
    final replacement = editedBySlot[slot];
    if (replacement == null) continue;
    final text = replacement.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (text.isEmpty || lyricsLineHash(text) == lyricsLineHash(line.text)) {
      continue;
    }
    patches.add(
      LyricsLinePatch(
        timeMs: slot,
        originalHash: lyricsLineHash(line.text),
        text: text,
      ),
    );
  }
  return patches;
}

/// The provider's text for the line sung at [timeMs] in [servedRaw].
String? servedLyricsLine(String servedRaw, int timeMs) {
  if (!LyricsDraft.canEdit(servedRaw)) return null;
  for (final (index, line) in LyricsDraft.parse(servedRaw).lines.indexed) {
    if (_slot(line, index) == timeMs) return line.text;
  }
  return null;
}

/// The slot of the line sung at [timeMs] in [servedRaw], allowing the few
/// milliseconds the player's rounding may move it.
int? nearestLyricsSlot(String servedRaw, int timeMs) {
  if (!LyricsDraft.canEdit(servedRaw)) return null;
  int? nearest;
  var distance = 16;
  for (final (index, line) in LyricsDraft.parse(servedRaw).lines.indexed) {
    final slot = _slot(line, index);
    if (slot < 0) continue;
    final delta = (slot - timeMs).abs();
    if (delta < distance) {
      nearest = slot;
      distance = delta;
    }
  }
  return nearest;
}
