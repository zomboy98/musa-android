import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:mornye/models/track.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Private file identities used only to avoid repeating automatic downloads.
/// This is independent of download history and never adds a library item.
class DownloadFileInventory {
  static const _key = 'download_file_inventory_v1';
  static Future<void> _writes = Future.value();
  static final _changes = StreamController<void>.broadcast();
  static Stream<void> get changes => _changes.stream;
  @visibleForTesting
  static void resetWritesForTest() => _writes = Future.value();
  static Future<void> record(Track track, String path) {
    if (path.isEmpty || path.startsWith('network://')) return Future.value();
    final operation = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decode(prefs.getString(_key));
      entries.removeWhere((entry) => entry['path'] == path);
      entries.add({
        'path': path,
        'identity': _identity(track.id, track.source),
        'isrcHash': _isrc(track.isrc),
        'isrcHashVersion': '2',
      });
      if (!await prefs.setString(_key, jsonEncode(entries))) {
        throw StateError('Could not persist download file inventory');
      }
      _changes.add(null);
    });
    _writes = operation;
    return operation;
  }

  static Future<bool> containsAccessible(
    Track track,
    Future<bool> Function(String) accessible,
  ) async {
    final isrc = _isrc(track.isrc);
    final identity = _identity(track.id, track.source);
    late final legacy = _legacyIsrcHashes(track.isrc);
    for (final entry in (await _readEntries()).reversed) {
      final storedIsrc = entry['isrcHash']!;
      final matches = isrc.isNotEmpty && storedIsrc.isNotEmpty
          ? (entry['isrcHashVersion'] == '2'
                ? storedIsrc == isrc
                : legacy.contains(storedIsrc))
          : identity.isNotEmpty && identity == entry['identity'];
      if (matches && await accessible(entry['path']!)) return true;
    }
    return false;
  }

  /// Looks up matching paths with a single inventory read for the whole batch.
  static Future<List<List<String>>> candidatePathsBatch(
    List<Track> tracks,
  ) async {
    final canonical = <String, List<String>>{};
    final legacy = <String, List<String>>{};
    final byIdentity = <String, List<Map<String, String>>>{};
    for (final entry in (await _readEntries()).reversed) {
      final isrc = entry['isrcHash']!;
      final identity = entry['identity']!;
      if (isrc.isNotEmpty) {
        final byIsrc = entry['isrcHashVersion'] == '2' ? canonical : legacy;
        (byIsrc[isrc] ??= []).add(entry['path']!);
      }
      if (identity.isNotEmpty) (byIdentity[identity] ??= []).add(entry);
    }
    return [
      for (final track in tracks)
        [
          ...?canonical[_isrc(track.isrc)],
          if (legacy.isNotEmpty)
            for (final hash in _legacyIsrcHashes(track.isrc)) ...?legacy[hash],
          for (final entry
              in byIdentity[_identity(track.id, track.source)] ??
                  const <Map<String, String>>[])
            if (normalizeIsrc(track.isrc).isEmpty || entry['isrcHash']!.isEmpty)
              entry['path']!,
        ],
    ];
  }

  static Future<List<Map<String, String>>> _readEntries() async {
    await _writes.catchError((_) {});
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null && (raw.contains('"id":') || raw.contains('"isrc":'))) {
      await _mutate((_) {});
    }
    final current = prefs.getString(_key);
    if (current == null) return const [];
    if (_cachedRaw != null && _cachedRaw == current) return _cachedEntries!;
    final entries = List<Map<String, String>>.unmodifiable(_decode(current));
    _cachedRaw = current;
    _cachedEntries = entries;
    return entries;
  }

  static String? _cachedRaw;
  static List<Map<String, String>>? _cachedEntries;

  /// Only remove entries after the application has confirmed file deletion.
  /// A failed open alone may mean a disconnected disk or revoked SAF access.
  static Future<void> removeDeletedPath(String path) => _mutate((entries) {
    entries.removeWhere((entry) => entry['path'] == path);
  });

  /// Clear recognition records without deleting any downloaded files.
  static Future<void> clear() => _mutate((entries) => entries.clear());

  static Future<void> _mutate(void Function(List<Map<String, String>>) mutate) {
    final operation = _writes.catchError((_) {}).then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final entries = _decode(prefs.getString(_key));
      mutate(entries);
      if (!await prefs.setString(_key, jsonEncode(entries))) {
        throw StateError('Could not persist download file inventory');
      }
      _changes.add(null);
    });
    _writes = operation;
    return operation;
  }

  static String _hash(String value) =>
      sha256.convert(utf8.encode(value)).toString();
  static String _hashIsrc(String value) =>
      value.isEmpty ? '' : _hash('isrc:$value');

  static String _isrc(String? value) => _hashIsrc(normalizeIsrc(value));

  // Older digests cannot be normalized in place. Check their exact spelling
  // and conventional forms of the country/registrant/year/designation groups.
  // Arbitrary historic spellings cannot be recovered from the digest alone.
  static Set<String> _legacyIsrcHashes(String? value) {
    final raw = value?.trim().toUpperCase() ?? '';
    final canonical = normalizeIsrc(raw);
    if (canonical.isEmpty) return const {};
    final formatted = formatIsrcForDisplay(canonical);
    final groups = formatted.split('-');
    const separators = ['', '-', ' '];
    return {
      _hashIsrc(raw),
      _hashIsrc(canonical),
      if (groups.length == 4)
        for (final a in separators)
          for (final b in separators)
            for (final c in separators)
              _hashIsrc(
                '${groups[0]}$a${groups[1]}$b${groups[2]}$c${groups[3]}',
              ),
    };
  }

  static String _identity(String id, String? source) {
    final normalizedSource = source?.trim().toLowerCase() ?? '';
    return id.trim().isEmpty || normalizedSource.isEmpty
        ? ''
        : _hash(jsonEncode(['source-id', normalizedSource, id]));
  }

  static List<Map<String, String>> _decode(String? raw) {
    if (raw == null) return [];
    final decoded = jsonDecode(raw);
    if (decoded is! List) throw const FormatException('Invalid inventory');
    return decoded.whereType<Map<dynamic, dynamic>>().map((entry) {
      final values = entry.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
      return {
        'path': values['path'] ?? '',
        'identity':
            values['identity'] ??
            _identity(values['id'] ?? '', values['source']),
        'isrcHash': values['isrcHash'] ?? _isrc(values['isrc']),
        'isrcHashVersion':
            values['isrcHashVersion'] ??
            (values.containsKey('isrcHash') ? '1' : '2'),
      };
    }).toList();
  }
}
