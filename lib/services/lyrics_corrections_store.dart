import 'dart:convert';

import 'package:mornye/utils/lyrics_corrections.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The user's line corrections over provider lyrics, in the app's private
/// preferences: never the audio file and never the full text.
class LyricsCorrectionsStore {
  const LyricsCorrectionsStore();

  static const _preference = 'lyrics_line_corrections_v1';

  Future<Map<String, List<LyricsLinePatch>>> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_preference);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is List)
            entry.key.toString(): [
              for (final item in entry.value as List)
                ?LyricsLinePatch.fromJson(item),
            ],
      };
    } catch (_) {
      return {};
    }
  }

  Future<List<LyricsLinePatch>> read(String key) async =>
      (await _readAll())[key] ?? const [];

  /// Replaces the corrections of [key]; an empty list forgets the track.
  Future<void> write(String key, List<LyricsLinePatch> patches) async {
    final all = await _readAll();
    if (patches.isEmpty) {
      all.remove(key);
    } else {
      all[key] = patches;
    }
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode({
      for (final entry in all.entries)
        entry.key: [for (final patch in entry.value) patch.toJson()],
    });
    if (!await prefs.setString(_preference, encoded)) {
      throw StateError('Could not store the lyrics corrections');
    }
  }
}
