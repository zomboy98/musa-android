import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The listener's own timing shift per track, in the app's private
/// preferences. Keys are the same as the line corrections' track keys.
class LyricsSyncStore {
  const LyricsSyncStore();

  static const _preference = 'lyrics_track_offsets_v1';

  Future<Map<String, int>> _readAll() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_preference);
      if (raw == null || raw.isEmpty) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final entry in decoded.entries)
          if (entry.value is num)
            entry.key.toString(): (entry.value as num).round(),
      };
    } catch (_) {
      return {};
    }
  }

  Future<int?> read(String key) async => (await _readAll())[key];

  /// Stores [offsetMs] for [key]; null forgets the track.
  Future<void> write(String key, int? offsetMs) async {
    final all = await _readAll();
    if (offsetMs == null) {
      all.remove(key);
    } else {
      all[key] = offsetMs;
    }
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(_preference, jsonEncode(all))) {
      throw StateError('Could not store the lyrics timing');
    }
  }

  static const _estimatedPreference = 'lyrics_estimated_sync_v1';

  /// Whether plain lyrics get approximate timing when no provider has any.
  /// On unless the listener turned it off.
  Future<bool> readEstimatedEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_estimatedPreference) ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> writeEstimatedEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_estimatedPreference, enabled);
  }
}
