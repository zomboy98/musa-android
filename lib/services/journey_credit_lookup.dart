import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:mornye/constants/app_info.dart';

/// Serializes MusicBrainz calls across this Dart isolate. MusicBrainz requests
/// should begin at least one second apart. Non-MusicBrainz requests must not
/// use this queue, and callers must supply their own timeout.
Future<T> scheduleMusicBrainzRequest<T>(
  Future<T> Function() operation, {
  Duration minInterval = const Duration(seconds: 1),
}) {
  return _musicBrainzSchedule(operation, minInterval);
}

Future<void> _musicBrainzQueue = Future<void>.value();
final Stopwatch _musicBrainzClock = Stopwatch()..start();
Duration? _musicBrainzLastStart;

Future<T> _musicBrainzSchedule<T>(
  Future<T> Function() operation,
  Duration minInterval,
) {
  final completer = Completer<T>();
  _musicBrainzQueue = _musicBrainzQueue.then((_) async {
    final previous = _musicBrainzLastStart;
    if (previous != null) {
      final remaining = minInterval - (_musicBrainzClock.elapsed - previous);
      if (remaining > Duration.zero) await Future<void>.delayed(remaining);
    }
    _musicBrainzLastStart = _musicBrainzClock.elapsed;
    try {
      completer.complete(await operation());
    } catch (error, stack) {
      completer.completeError(error, stack);
    }
  });
  return completer.future;
}

/// Only credits supported by a uniquely matched MusicBrainz recording and,
/// for labels, a uniquely matched release. MBIDs are not image URLs.
class JourneyCreditResult {
  const JourneyCreditResult({
    this.labels = const [],
    this.producers = const [],
    this.artistIds = const {},
    this.labelIds = const {},
    this.producerIds = const {},
  });

  final List<String> labels;
  final List<String> producers;
  final Map<String, String> artistIds;
  final Map<String, String> labelIds;
  final Map<String, String> producerIds;
}

class _CachedCredit {
  const _CachedCredit(this.value, this.expires);
  final JourneyCreditResult value;
  final DateTime expires;
}

/// Looks up missing factual credits; never modifies local tags or overwrites
/// provider metadata. The caller decides whether and when to use the result.
///
/// An ISRC can identify multiple recordings, and a recording can appear on
/// many editions. For multiple recordings only unanimously matching artist
/// IDs are retained; recording and release credits are not guessed.
/// This class does not manufacture or search for logos or signatures.
class JourneyCreditLookup {
  JourneyCreditLookup({
    http.Client? client,
    this.minInterval = const Duration(seconds: 1),
    this.timeout = const Duration(seconds: 8),
    this.cacheDuration = const Duration(hours: 6),
  }) : _client = client ?? http.Client();

  static final JourneyCreditLookup shared = JourneyCreditLookup();
  static const _maxCacheEntries = 128;
  static final _isrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$');
  static final _mbidPattern = RegExp(
    r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
    caseSensitive: false,
  );
  // Production builds should set a contact chosen by the project owner:
  // MusicBrainz asks for a meaningful User-Agent with contact information.
  // Avoid inventing or disclosing a private URL in development builds.
  static const _contact = String.fromEnvironment('MUSA_MUSICBRAINZ_CONTACT');
  static final _headers = {
    'Accept': 'application/json',
    'User-Agent': _contact.trim().isEmpty
        ? 'MUSA/${AppInfo.version}'
        : 'MUSA/${AppInfo.version} (${_contact.trim()})',
  };

  final http.Client _client;
  final Duration minInterval;
  final Duration timeout;
  final Duration cacheDuration;
  final _inFlight = <String, Future<JourneyCreditResult>>{};
  final _cache = <String, _CachedCredit>{};

  Future<JourneyCreditResult> lookup({
    required String isrc,
    String? album,
    required List<String> artists,
  }) {
    final code = isrc.trim().replaceAll('-', '').toUpperCase();
    final requestedArtists = artists
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
    if (!_isrcPattern.hasMatch(code) || requestedArtists.isEmpty) {
      return Future.value(const JourneyCreditResult());
    }
    final key = jsonEncode([
      code,
      _normal(album),
      requestedArtists.map(_normal).toList(),
    ]);
    final cached = _cache[key];
    if (cached != null && cached.expires.isAfter(DateTime.now())) {
      return Future.value(cached.value);
    }
    _cache.remove(key);
    return _inFlight.putIfAbsent(key, () {
      late final Future<JourneyCreditResult> pending;
      pending = _lookup(code, album, requestedArtists)
          .then((answer) {
            if (answer != null) {
              _cache[key] = _CachedCredit(
                answer,
                DateTime.now().add(cacheDuration),
              );
              while (_cache.length > _maxCacheEntries) {
                _cache.remove(_cache.keys.first);
              }
              return answer;
            }
            return const JourneyCreditResult();
          })
          .catchError((_) => const JourneyCreditResult())
          .whenComplete(() {
            if (identical(_inFlight[key], pending)) _inFlight.remove(key);
          });
      return pending;
    });
  }

  Future<Map<String, dynamic>?> _get(Uri uri) async {
    try {
      final response = await scheduleMusicBrainzRequest(
        () => _client.get(uri, headers: _headers).timeout(timeout),
        minInterval: minInterval,
      );
      if (response.statusCode != 200 ||
          response.bodyBytes.length > 2 * 1024 * 1024) {
        return null;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      return data is Map<String, dynamic> ? data : null;
    } catch (_) {
      return null;
    }
  }

  Future<JourneyCreditResult?> _lookup(
    String isrc,
    String? album,
    List<String> artists,
  ) async {
    final data = await _get(
      Uri.https('musicbrainz.org', '/ws/2/isrc/$isrc', {
        'fmt': 'json',
        'inc': 'artist-credits artist-rels releases',
      }),
    );
    if (data == null) return null;
    final recordings = _maps(data['recordings']);
    final matches = recordings
        .where((recording) => _matchesArtists(recording, artists))
        .toList();
    // With several recordings, only retain artists whose MBID is the same
    // unambiguous identity in every candidate. Recording/release credits
    // remain unknown until a specific recording is selected.
    if (matches.isEmpty) return const JourneyCreditResult();
    if (matches.length > 1) {
      final consensus = <String, String>{};
      for (final name in artists) {
        final ids = matches
            .map((recording) => _artistId(recording, name))
            .toSet();
        if (ids.length != 1 || ids.single == null) {
          return const JourneyCreditResult();
        }
        consensus[name] = ids.single!;
      }
      return JourneyCreditResult(artistIds: Map.unmodifiable(consensus));
    }
    final recording = matches.single;
    final artistIds = <String, String>{};
    for (final name in artists) {
      final id = _artistId(recording, name);
      if (id != null) artistIds[name] = id;
    }
    final producers = <String>[];
    final seenProducers = <String>{};
    final producerCandidates = <String, Set<String>>{};
    final producerIdsUnknown = <String>{};
    for (final relation in _maps(recording['relations'])) {
      if (relation['type'] != 'producer' ||
          relation['target-type'] != 'artist') {
        continue;
      }
      final artist = _map(relation['artist']);
      final name = _text(relation['target-credit']) ?? _text(artist?['name']);
      if (name == null) continue;
      final normalized = _normal(name);
      if (seenProducers.add(normalized)) producers.add(name);
      final id = _mbid(artist?['id']);
      if (id == null) {
        producerIdsUnknown.add(normalized);
      } else {
        producerCandidates.putIfAbsent(normalized, () => <String>{}).add(id);
      }
    }
    final producerIds = <String, String>{};
    for (final name in producers) {
      final normalized = _normal(name);
      final candidates = producerCandidates[normalized];
      if (!producerIdsUnknown.contains(normalized) &&
          candidates != null &&
          candidates.length == 1) {
        producerIds[name] = candidates.single;
      }
    }
    final labels = <String>[];
    final labelIds = <String, String>{};
    final albumName = _normal(album);
    if (albumName.isNotEmpty) {
      var availableReleases = _maps(recording['releases']);
      if (availableReleases.isEmpty) {
        final recordingId = _mbid(recording['id']);
        if (recordingId != null) {
          final browse = await _get(
            Uri.https('musicbrainz.org', '/ws/2/release', {
              'fmt': 'json',
              'recording': recordingId,
              'inc': 'labels',
              'limit': '100',
              'offset': '0',
            }),
          );
          if (browse == null) return null;
          final rows = _maps(browse['releases']);
          final count = browse['release-count'];
          final offset = browse['release-offset'];
          // Never claim a unique edition from an incomplete first page.
          if (count is int && offset == 0 && count == rows.length) {
            availableReleases = rows;
          }
        }
      }
      final releases = availableReleases
          .where(
            (release) =>
                _normal(_text(release['title'])) == albumName &&
                _mbid(release['id']) != null,
          )
          .toList();
      if (releases.length == 1) {
        final id = _mbid(releases.single['id'])!;
        final release = releases.single.containsKey('label-info')
            ? releases.single
            : await _get(
                Uri.https('musicbrainz.org', '/ws/2/release/$id', {
                  'fmt': 'json',
                  'inc': 'labels',
                }),
              );
        // Do not cache an incomplete lookup after transient network failures.
        if (release == null) return null;
        final seen = <String>{};
        final candidates = <String, Set<String>>{};
        for (final entry in _maps(release['label-info'])) {
          final label = _map(entry['label']);
          final name = _text(label?['name']);
          final mbid = _mbid(label?['id']);
          if (name == null) continue;
          final normal = _normal(name);
          if (seen.add(normal)) labels.add(name);
          if (mbid != null) {
            candidates.putIfAbsent(normal, () => <String>{}).add(mbid);
          }
        }
        for (final name in labels) {
          final ids = candidates[_normal(name)];
          if (ids != null && ids.length == 1) labelIds[name] = ids.single;
        }
      }
    }
    return JourneyCreditResult(
      labels: List.unmodifiable(labels),
      producers: List.unmodifiable(producers),
      artistIds: Map.unmodifiable(artistIds),
      labelIds: Map.unmodifiable(labelIds),
      producerIds: Map.unmodifiable(producerIds),
    );
  }
}

String _normal(String? value) =>
    (value ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
String? _text(Object? value) {
  if (value is! String) return null;
  final result = value.trim();
  return result.isEmpty ? null : result;
}

String? _mbid(Object? value) {
  final id = _text(value);
  return id != null && JourneyCreditLookup._mbidPattern.hasMatch(id)
      ? id.toLowerCase()
      : null;
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map<String, dynamic> ? value : null;
List<Map<String, dynamic>> _maps(Object? value) =>
    value is List ? value.whereType<Map<String, dynamic>>().toList() : const [];

String? _artistId(Map<String, dynamic> recording, String name) {
  final ids = <String>{};
  var missingId = false;
  final requested = _normal(name);
  for (final credit in _maps(recording['artist-credit'])) {
    final artist = _map(credit['artist']);
    if (_normal(_text(credit['name'])) != requested &&
        _normal(_text(artist?['name'])) != requested) {
      continue;
    }
    final id = _mbid(artist?['id']);
    if (id == null) {
      missingId = true;
    } else {
      ids.add(id);
    }
  }
  return !missingId && ids.length == 1 ? ids.single : null;
}

bool _matchesArtists(Map<String, dynamic> recording, List<String> artists) {
  final credits = _maps(recording['artist-credit']);
  final known = <String>{};
  for (final credit in credits) {
    final name = _text(credit['name']);
    final actual = _text(_map(credit['artist'])?['name']);
    if (name != null) known.add(_normal(name));
    if (actual != null) known.add(_normal(actual));
  }
  return artists.every((name) => known.contains(_normal(name)));
}
