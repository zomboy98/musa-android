import 'dart:convert';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/m3u_playlist_service.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';

List<Track> _parsePlaylistInBackground(Map<String, dynamic> request) {
  final content = utf8.decode(request['bytes'] as Uint8List);
  final seed = request['id_seed'] as int;
  return request['format'] == 'csv'
      ? CsvImportService._parseCsv(content, idSeed: seed)
      : M3uPlaylistService.parseM3u(content, idSeed: seed);
}

List<Track> _hydratePlaylistInBackground(List<dynamic> rows) => [
  for (final row in rows) Track.fromJson(Map<String, dynamic>.from(row as Map)),
];

class CsvImportService {
  static final _log = AppLogger('CsvImportService');

  static Future<List<Track>> pickAndParseCsv({
    void Function(int current, int total)? onProgress,
  }) async {
    try {
      final picked = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['csv', 'm3u', 'm3u8'],
      );

      if (picked != null) {
        final bytes = await picked.readAsBytes();
        final extension = p.extension(picked.name).toLowerCase();
        final tracks = await parsePlaylistInBackground(
          bytes,
          format: (extension == '.m3u' || extension == '.m3u8') ? 'm3u' : 'csv',
        );

        if (tracks.isNotEmpty) {
          return await enrichTracksMetadata(tracks, onProgress: onProgress);
        }
        return tracks;
      }
    } catch (e) {
      _log.e('Error picking/parsing playlist file: $e');
    }
    return [];
  }

  /// Native parsing consumes bytes directly. Old native binaries and test
  /// hosts retain the same parser in an isolate, never the Flutter frame.
  static Future<List<Track>> parsePlaylistInBackground(
    Uint8List bytes, {
    required String format,
    int? idSeed,
  }) async {
    final seed = idSeed ?? DateTime.now().millisecondsSinceEpoch;
    List<dynamic> rows;
    try {
      final result = await PlatformBridge.runNativeDataJob({
        'operation': 'parse_playlist',
        'format': format,
        'id_seed': seed,
      }, bytes: bytes);
      rows = result['tracks'] as List;
    } on MissingPluginException {
      return compute(_parsePlaylistInBackground, {
        'bytes': bytes,
        'format': format,
        'id_seed': seed,
      });
    }
    return compute(_hydratePlaylistInBackground, rows);
  }

  @visibleForTesting
  static Future<List<Track>> enrichTracksMetadata(
    List<Track> tracks, {
    void Function(int current, int total)? onProgress,
    Future<List<Map<String, dynamic>>> Function(String query, int limit)?
    lookup,
    int concurrency = 3,
  }) async {
    if (tracks.isEmpty) return const [];
    final providerLookup =
        lookup ??
        (String query, int limit) =>
            PlatformBridge.searchTracksWithMetadataProviders(
              query,
              limit: limit,
              includeExtensions: true,
            );
    final results = List<Track?>.filled(tracks.length, null);
    var nextIndex = 0;
    var completed = 0;
    final workerCount = math.min(math.max(1, concurrency), tracks.length);

    _log.i(
      'Enriching ${tracks.length} imported tracks with configured metadata providers ($workerCount workers)',
    );

    Future<void> worker() async {
      while (true) {
        final index = nextIndex++;
        if (index >= tracks.length) return;
        final track = tracks[index];
        results[index] = await _enrichTrack(track, providerLookup);
        completed++;
        onProgress?.call(completed, tracks.length);
      }
    }

    await Future.wait(List.generate(workerCount, (_) => worker()));
    final enriched = results.cast<Track>();
    _log.i('Enrichment complete: ${enriched.length} tracks');
    return enriched;
  }

  static Future<Track> _enrichTrack(
    Track track,
    Future<List<Map<String, dynamic>>> Function(String query, int limit) lookup,
  ) async {
    if (track.coverUrl != null && track.duration > 0) return track;

    Map<String, dynamic>? selected;
    final isrc = track.isrc?.trim().toUpperCase() ?? '';
    if (isrc.isNotEmpty) {
      try {
        final candidates = await lookup(isrc, 5);
        selected = _bestCandidate(track, candidates, requireExactIsrc: true);
      } catch (e) {
        _log.w('ISRC provider lookup failed for ${track.name}: $e');
      }
    }

    if (selected == null) {
      try {
        final candidates = await lookup('${track.artistName} ${track.name}', 5);
        selected = _bestCandidate(track, candidates);
      } catch (e) {
        _log.w('Metadata provider lookup failed for ${track.name}: $e');
      }
    }
    if (selected == null) return track;

    final candidate = Track.fromBackendMap(selected);
    _log.d(
      'Enriched ${track.name} via ${selected['provider_id'] ?? selected['source'] ?? 'metadata provider'}',
    );
    return track.copyWith(
      name: track.name,
      artistName: track.artistName,
      albumName: candidate.albumName.isEmpty
          ? track.albumName
          : candidate.albumName,
      albumArtist: candidate.albumArtist,
      artistId: candidate.artistId,
      albumId: candidate.albumId,
      coverUrl: candidate.coverUrl,
      isrc: candidate.isrc,
      duration: candidate.duration > 0 ? candidate.duration : track.duration,
      trackNumber: candidate.trackNumber,
      discNumber: candidate.discNumber,
      totalDiscs: candidate.totalDiscs,
      totalTracks: candidate.totalTracks,
      releaseDate: candidate.releaseDate,
      genre: candidate.genre,
      label: candidate.label,
      copyright: candidate.copyright,
      composer: candidate.composer,
      explicit: candidate.explicit,
      upc: candidate.upc,
    );
  }

  static Map<String, dynamic>? _bestCandidate(
    Track track,
    List<Map<String, dynamic>> candidates, {
    bool requireExactIsrc = false,
  }) {
    if (candidates.isEmpty) return null;
    final targetIsrc = track.isrc?.trim().toUpperCase() ?? '';
    final targetName = _normalizeMatchText(track.name);
    final targetArtist = _normalizeMatchText(track.artistName);
    Map<String, dynamic>? best;
    var bestScore = -1;
    var ambiguous = false;
    for (final candidate in candidates) {
      final candidateIsrc =
          candidate['isrc']?.toString().trim().toUpperCase() ?? '';
      if (targetIsrc.isNotEmpty &&
          candidateIsrc.isNotEmpty &&
          targetIsrc != candidateIsrc) {
        continue;
      }
      if (requireExactIsrc &&
          (targetIsrc.isEmpty || candidateIsrc != targetIsrc)) {
        continue;
      }
      var score = candidateIsrc.isNotEmpty && candidateIsrc == targetIsrc
          ? 100
          : 0;
      final name = _normalizeMatchText(candidate['name']?.toString() ?? '');
      final artist = _normalizeMatchText(
        (candidate['artists'] ?? candidate['artist'])?.toString() ?? '',
      );
      final exactIsrc = targetIsrc.isNotEmpty && candidateIsrc == targetIsrc;
      // A matching artist alone is not evidence that this is the same song.
      // Avoid substring matches for titles: they conflate versions and songs.
      final compatibleText =
          targetName.isNotEmpty &&
          name == targetName &&
          targetArtist.isNotEmpty &&
          artist == targetArtist;
      if (!exactIsrc && !compatibleText) continue;
      if (targetName.isNotEmpty && name == targetName) {
        score += 30;
      } else if (targetName.isNotEmpty &&
          name.isNotEmpty &&
          (name.contains(targetName) || targetName.contains(name))) {
        score += 15;
      }
      if (targetArtist.isNotEmpty && artist == targetArtist) {
        score += 20;
      } else if (targetArtist.isNotEmpty &&
          artist.isNotEmpty &&
          (artist.contains(targetArtist) || targetArtist.contains(artist))) {
        score += 10;
      }
      if (score > bestScore) {
        best = candidate;
        bestScore = score;
        ambiguous = false;
      } else if (score == bestScore && !exactIsrc) {
        ambiguous = true;
      }
    }
    return ambiguous ? null : best;
  }

  static String _normalizeMatchText(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ')
      .trim();

  static List<Track> _parseCsv(String content, {int? idSeed}) {
    final List<Track> tracks = [];
    final records = _csvRecords(content);
    final lines = records.map((record) => record.$2).toList();
    if (lines.isEmpty) return tracks;

    int startIdx = 0;
    while (startIdx < lines.length && lines[startIdx].trim().isEmpty) {
      startIdx++;
    }
    if (startIdx >= lines.length) return tracks;

    final headers = _parseLine(lines[startIdx]);
    final colMap = <String, int>{};
    for (int i = 0; i < headers.length; i++) {
      String h = _cleanValue(headers[i]).toLowerCase();
      colMap[h] = i;
    }

    _log.d('CSV Headers: ${colMap.keys.toList()}');
    const idKeys = [
      'track uri',
      'spotify - id',
      'spotify id',
      'spotify_id',
      'id',
      'uri',
    ];
    String? normalizedId(List<String> values) {
      var id = _getValue(values, colMap, idKeys);
      if (id != null && id.startsWith('spotify:track:')) {
        id = id.replaceAll('spotify:track:', '');
      }
      return id == null || id.trim().isEmpty ? null : id;
    }

    final reservedIds = <String>{};
    for (final line in lines.skip(startIdx + 1)) {
      if (line.trim().isEmpty) continue;
      final id = normalizedId(_parseLine(line.trim()));
      if (id != null) reservedIds.add(id);
    }
    final seed = idSeed ?? DateTime.now().millisecondsSinceEpoch;

    for (int i = startIdx + 1; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      final values = _parseLine(line);

      String? getVal(List<String> keys) {
        return _getValue(values, colMap, keys);
      }

      String? trackName = getVal(['track name', 'track', 'name', 'title']);
      String? artistName = getVal([
        'artist name(s)',
        'artist name',
        'artist',
        'artists',
      ]);
      String? albumName = getVal(['album name', 'album']);
      String? isrc = getVal(['isrc']);
      String? spotifyId = normalizedId(values);

      if ((trackName != null && trackName.isNotEmpty && artistName != null) ||
          (spotifyId != null && spotifyId.isNotEmpty)) {
        var trackId = spotifyId;
        if (trackId == null) {
          var candidate = 'csv_${seed}_${records[i].$1}';
          while (reservedIds.contains(candidate)) {
            candidate = '${candidate}_';
          }
          reservedIds.add(candidate);
          trackId = candidate;
        }
        tracks.add(
          Track(
            id: trackId,
            name: trackName ?? 'Unknown Track',
            artistName: artistName ?? 'Unknown Artist',
            albumName: albumName ?? 'Unknown Album',
            isrc: isrc,
            duration: 0,
            coverUrl: null,
          ),
        );
      }
    }

    _log.i('Parsed ${tracks.length} tracks from CSV');
    return tracks;
  }

  // Ignore an incomplete final quoted record, preserving complete records.
  static List<(int, String)> _csvRecords(String content) {
    final result = <(int, String)>[];
    var buffer = StringBuffer();
    var quoted = false;
    var line = 0;
    var start = 0;
    for (var i = 0; i < content.length; i++) {
      final char = content[i];
      if (char == '"') {
        buffer.write(char);
        if (quoted && i + 1 < content.length && content[i + 1] == '"') {
          buffer.write(content[++i]);
        } else {
          quoted = !quoted;
        }
      } else if (char == '\r' || char == '\n') {
        final newline =
            char == '\r' && i + 1 < content.length && content[i + 1] == '\n'
            ? '$char${content[++i]}'
            : char;
        if (quoted) {
          buffer.write(newline);
        } else {
          result.add((start, buffer.toString()));
          buffer = StringBuffer();
          start = line + 1;
        }
        line++;
      } else {
        buffer.write(char);
      }
    }
    if (!quoted) result.add((start, buffer.toString()));
    return result;
  }

  static String? _getValue(
    List<String> values,
    Map<String, int> colMap,
    List<String> possibleKeys,
  ) {
    for (final key in possibleKeys) {
      if (colMap.containsKey(key)) {
        final index = colMap[key]!;
        if (index < values.length) {
          return _cleanValue(values[index]);
        }
      }
    }
    return null;
  }

  static String _cleanValue(String val) {
    return val.trim();
  }

  static List<String> _parseLine(String line) {
    final List<String> result = [];
    bool inQuote = false;
    var buffer = StringBuffer();

    for (int i = 0; i < line.length; i++) {
      final char = line[i];
      if (char == '"') {
        if (inQuote && i + 1 < line.length && line[i + 1] == '"') {
          buffer.write('"');
          i++;
        } else {
          inQuote = !inQuote;
        }
        continue;
      }
      if (char == ',' && !inQuote) {
        result.add(buffer.toString());
        buffer = StringBuffer();
        continue;
      }
      buffer.write(char);
    }
    result.add(buffer.toString());
    return result;
  }
}
