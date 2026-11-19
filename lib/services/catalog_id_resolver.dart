import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode, debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/provider_request_spec.dart';
import 'package:mornye/utils/catalog_search_query.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum CatalogIdVia { cache, isrc, title }

class CatalogNativeId {
  const CatalogNativeId(this.providerId, this.id, this.via);

  final String providerId;
  final String id;
  final CatalogIdVia via;
}

typedef CatalogIdSearch =
    Future<List<Map<String, dynamic>>> Function(
      String providerId,
      String query,
      Map<String, dynamic> options,
    );
typedef CatalogDeezerIsrcLookup =
    Future<Map<String, dynamic>> Function(String isrc);

const catalogIdResolverBuildEnabled = bool.fromEnvironment(
  'MUSA_CATALOG_ID_RESOLVER',
  defaultValue: true,
);
const catalogIdResolverPreferenceKey = 'catalog_id_resolver_enabled';

enum _Kind { hit, miss, empty, error, skipped }

class _Outcome {
  const _Outcome(
    this.kind, {
    this.id = '',
    this.via = CatalogIdVia.cache,
    this.queries = 0,
    this.rows = 0,
    this.reason = 'none',
  });

  final _Kind kind;
  final String id;
  final CatalogIdVia via;
  final int queries;
  final int rows;
  final String reason;
}

class _Entry {
  const _Entry({this.id, required this.at, this.empty = false});

  final String? id;
  final int at;
  final bool empty;
}

class CatalogIdResolver {
  CatalogIdResolver({
    CatalogIdSearch? search,
    CatalogDeezerIsrcLookup? deezerByIsrc,
    Future<Directory> Function()? directory,
    Future<bool> Function()? enabled,
    DateTime Function()? now,
    void Function(String line)? diagnostic,
    this.positiveTtl = const Duration(days: 30),
    this.negativeTtl = const Duration(hours: 24),
    this.emptyTtl = const Duration(minutes: 15),
    this.errorBackoff = const Duration(seconds: 60),
    this.lookupWindow = const Duration(minutes: 2),
    this.maxLookupsPerTrack = 4,
    this.maxEntries = 2000,
  }) : _search = search ?? _defaultSearch,
       _deezerByIsrc = deezerByIsrc ?? PlatformBridge.searchDeezerByISRC,
       _directory = directory ?? _defaultDirectory,
       _enabled = enabled ?? _defaultEnabled,
       _now = now ?? DateTime.now,
       _diagnostic = diagnostic ?? _logDiagnostic;

  final CatalogIdSearch _search;
  final CatalogDeezerIsrcLookup _deezerByIsrc;
  final Future<Directory> Function() _directory;
  final Future<bool> Function() _enabled;
  final DateTime Function() _now;
  final void Function(String line) _diagnostic;
  final Duration positiveTtl;
  final Duration negativeTtl;
  final Duration emptyTtl;
  final Duration errorBackoff;
  final Duration lookupWindow;
  final int maxLookupsPerTrack;
  final int maxEntries;

  static final _isrcPattern = RegExp(r'^[A-Z]{2}[A-Z0-9]{3}\d{7}$');
  static final _providerPattern = RegExp(r'^[a-z0-9_-]{1,40}$');
  static final _artistSplit = RegExp(
    r'\s*(?:,|;|&|\+|\bfeat\.?|\bft\.?|\bfeaturing\b)\s*|\s+x\s+',
    caseSensitive: false,
  );
  static final _annotationGroup = RegExp(r'\(([^()]*)\)|\[([^\[\]]*)\]');
  static final _annotationStart = RegExp(
    r'^(?:from\s|feat\b|ft\b|featuring\s|with\s|prod\b|produced\b)',
    caseSensitive: false,
  );
  static const _versionWords = [
    'mix',
    'remix',
    'live',
    'acoustic',
    'demo',
    'instrumental',
    'karaoke',
    'edit',
    'extended',
    'slowed',
    'sped',
    'remaster',
    'remastered',
    'version',
  ];
  static final _versionPattern = RegExp('\\b(?:${_versionWords.join('|')})\\b');

  final _entries = <String, _Entry>{};
  final _pending = <String, Future<_Outcome>>{};
  final _lookups = <String, List<int>>{};
  final _backoff = <String, int>{};
  bool _loaded = false;
  Future<void> _writeChain = Future.value();

  static Future<List<Map<String, dynamic>>> _defaultSearch(
    String providerId,
    String query,
    Map<String, dynamic> options,
  ) => PlatformBridge.customSearchWithExtension(
    providerId,
    query,
    options: options,
  );

  static Future<Directory> _defaultDirectory() async =>
      Directory('${(await getApplicationSupportDirectory()).path}/catalog_ids');

  static Future<bool> _defaultEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(catalogIdResolverPreferenceKey) ?? true;
    } catch (_) {
      return true;
    }
  }

  static void _logDiagnostic(String line) {
    developer.log(line, name: 'catalog_id');
    if (kDebugMode) debugPrint('[catalog_id] $line');
  }

  static String fold(String value) => foldDiacritics(value)
      .toLowerCase()
      .replaceAll(r'$', 's')
      .replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');

  static List<String> _artistParts(String value) => [
    for (final part in value.split(_artistSplit))
      if (fold(part).isNotEmpty) part.trim(),
  ];

  static Set<String> artists(String value) {
    final result = <String>{};
    for (final part in value.split(_artistSplit)) {
      final folded = fold(part);
      if (folded.isNotEmpty) result.add(folded);
    }
    return result;
  }

  static String cleanTitle(String title) {
    final cleaned = title.replaceAllMapped(_annotationGroup, (match) {
      final content = (match.group(1) ?? match.group(2) ?? '').trim();
      if (!_annotationStart.hasMatch(content)) return match.group(0)!;
      if (_versionPattern.hasMatch(content.toLowerCase())) {
        return match.group(0)!;
      }
      return '';
    });
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  static Set<String> _versionMarks(String title) => {
    for (final match in _versionPattern.allMatches(title.toLowerCase()))
      match.group(0)!,
  };

  static String _providerLabel(String serviceId) {
    final value = serviceId.trim().toLowerCase();
    return _providerPattern.hasMatch(value) ? value : 'unknown';
  }

  static String _validIsrc(Track track) {
    final value = normalizeIsrc(track.isrc);
    return _isrcPattern.hasMatch(value) ? value : '';
  }

  static String _firstArtistFold(Track track) {
    final parts = _artistParts(track.artistName);
    return parts.isEmpty ? '' : fold(parts.first);
  }

  static String _trackKey(Track track) {
    final isrc = _validIsrc(track);
    if (isrc.isNotEmpty) return 'isrc:$isrc';
    return 't:${fold(cleanTitle(track.name))}|${_firstArtistFold(track)}|'
        '${track.duration}';
  }

  static String _idPrefix(Track track) {
    final id = track.id.trim().toLowerCase();
    final index = id.indexOf(':');
    return index <= 0 ? '' : id.substring(0, index);
  }

  Future<CatalogNativeId?> resolve(
    Track track,
    String serviceId, {
    Duration timeout = const Duration(seconds: 6),
  }) async {
    final watch = Stopwatch()..start();
    final provider = _providerLabel(serviceId);

    void emit(
      String result, {
      String via = 'none',
      String delivery = 'none',
      String reason = 'none',
      int queries = 0,
      int rows = 0,
      int idLength = 0,
    }) {
      try {
        _diagnostic(
          'provider=$provider result=$result via=$via delivery=$delivery '
          'reason=$reason queries=$queries rows=$rows id_len=$idLength '
          'ms=${watch.elapsedMilliseconds}',
        );
      } catch (_) {}
    }

    CatalogNativeId? skipped(String reason) {
      emit('skipped', reason: reason);
      return null;
    }

    bool enabled;
    try {
      enabled = await _enabled();
    } catch (_) {
      enabled = true;
    }
    if (!catalogIdResolverBuildEnabled || !enabled) return skipped('disabled');

    final spec = providerRequestSpecFor(serviceId);
    if (spec == null || spec.lookup == NativeIdLookup.none) {
      return skipped('no_lookup');
    }
    final providerId = spec.providerId;

    final source = (track.source ?? '').trim().toLowerCase();
    final prefix = _idPrefix(track);
    if (sourcesForbiddingReplacement.contains(source) ||
        sourcesForbiddingReplacement.contains(prefix)) {
      return skipped('source_policy');
    }
    final bare = providerId.endsWith('-web')
        ? providerId.substring(0, providerId.length - 4)
        : providerId;
    final nativeSource = {providerId, bare};
    if (nativeSource.contains(source) ||
        nativeSource.contains(prefix) ||
        (spec.field == NativeIdField.deezer &&
            (track.deezerId ?? '').trim().isNotEmpty)) {
      return skipped('native');
    }

    final deliveryLabel = spec.delivery == NativeIdDelivery.nativeField
        ? 'field'
        : 'direct';
    final trackKey = _trackKey(track);
    final key = '$providerId|$trackKey';

    await _load();
    final nowMs = _now().millisecondsSinceEpoch;
    final cached = _entries[key];
    if (cached != null) {
      final id = cached.id;
      if (id != null) {
        if (nowMs - cached.at < positiveTtl.inMilliseconds) {
          if (spec.nativeId(id) != null) {
            emit(
              'hit',
              via: 'cache',
              delivery: deliveryLabel,
              idLength: id.length,
            );
            return CatalogNativeId(providerId, id, CatalogIdVia.cache);
          }
          _entries.remove(key);
          await _persistIfNeeded(key);
        } else {
          _entries.remove(key);
        }
      } else {
        final ttl = cached.empty ? emptyTtl : negativeTtl;
        if (nowMs - cached.at < ttl.inMilliseconds) {
          emit('miss_cached');
          return null;
        }
        _entries.remove(key);
      }
    }

    final until = _backoff[providerId];
    if (until != null && nowMs < until) return skipped('backoff');

    var future = _pending[key];
    if (future == null) {
      final window = _lookups.putIfAbsent(trackKey, () => <int>[]);
      window.removeWhere((at) => nowMs - at >= lookupWindow.inMilliseconds);
      if (window.length >= maxLookupsPerTrack) return skipped('budget');
      window.add(nowMs);
      final created = _run(track, spec, key);
      future = created;
      _pending[key] = created;
      unawaited(
        created.then((_) {
          if (identical(_pending[key], created)) _pending.remove(key);
        }),
      );
    }

    final completer = Completer<_Outcome?>();
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(null);
    });
    unawaited(
      future.then((outcome) {
        if (!completer.isCompleted) completer.complete(outcome);
      }),
    );
    final outcome = await completer.future;
    timer.cancel();

    if (outcome == null) {
      _backoff[providerId] =
          _now().millisecondsSinceEpoch + errorBackoff.inMilliseconds;
      emit('timeout');
      return null;
    }
    switch (outcome.kind) {
      case _Kind.hit:
        emit(
          'hit',
          via: outcome.via.name,
          delivery: deliveryLabel,
          queries: outcome.queries,
          rows: outcome.rows,
          idLength: outcome.id.length,
        );
        return CatalogNativeId(providerId, outcome.id, outcome.via);
      case _Kind.miss:
        emit('miss', queries: outcome.queries, rows: outcome.rows);
      case _Kind.empty:
        emit('empty', queries: outcome.queries, rows: outcome.rows);
      case _Kind.error:
        emit(
          'error',
          reason: outcome.reason,
          queries: outcome.queries,
          rows: outcome.rows,
        );
      case _Kind.skipped:
        emit(
          'skipped',
          reason: outcome.reason,
          queries: outcome.queries,
          rows: outcome.rows,
        );
    }
    return null;
  }

  Future<void> invalidate(Track track, String serviceId) async {
    final watch = Stopwatch()..start();
    final provider = _providerLabel(serviceId);
    try {
      final spec = providerRequestSpecFor(serviceId);
      if (spec != null) {
        await _load();
        final key = '${spec.providerId}|${_trackKey(track)}';
        final entry = _entries[key];
        if (entry != null && entry.id != null) {
          _entries.remove(key);
          await _persistIfNeeded(key);
        }
      }
    } catch (_) {}
    try {
      _diagnostic(
        'provider=$provider result=invalidated via=none delivery=none '
        'reason=none queries=0 rows=0 id_len=0 '
        'ms=${watch.elapsedMilliseconds}',
      );
    } catch (_) {}
  }

  Future<_Outcome> _run(
    Track track,
    ProviderRequestSpec spec,
    String key,
  ) async {
    try {
      final outcome = spec.lookup == NativeIdLookup.deezerIsrc
          ? await _lookupDeezer(track, spec)
          : await _lookupSearch(track, spec);
      await _store(key, outcome);
      return outcome;
    } catch (error) {
      _backoff[spec.providerId] =
          _now().millisecondsSinceEpoch + errorBackoff.inMilliseconds;
      return _Outcome(_Kind.error, reason: _errorReason(error));
    }
  }

  static String _errorReason(Object error) {
    final raw = error is PlatformException
        ? 'code_${error.code}'
        : error.runtimeType.toString();
    final clean = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    return clean.length > 32 ? clean.substring(0, 32) : clean;
  }

  Future<_Outcome> _lookupDeezer(Track track, ProviderRequestSpec spec) async {
    final isrc = _validIsrc(track);
    if (isrc.isEmpty) return const _Outcome(_Kind.skipped, reason: 'no_isrc');
    final result = await _deezerByIsrc(isrc);
    if (result['success'] == true) {
      final id = spec.nativeId('${result['track_id']}');
      if (id != null) {
        return _Outcome(
          _Kind.hit,
          id: id,
          via: CatalogIdVia.isrc,
          queries: 1,
          rows: 1,
        );
      }
    }
    return const _Outcome(_Kind.miss, queries: 1);
  }

  Future<_Outcome> _lookupSearch(Track track, ProviderRequestSpec spec) async {
    final title = cleanTitle(track.name);
    if (title.isEmpty) {
      return const _Outcome(_Kind.skipped, reason: 'no_identity');
    }
    final parts = _artistParts(track.artistName);
    final artist = parts.isEmpty ? '' : parts.first;
    final options = <String, dynamic>{
      'filter': spec.searchFilter,
      'limit': spec.searchLimit,
    };
    final firstQuery = '$title $artist'.trim();
    var queries = 1;
    var rows = await _search(spec.providerId, firstQuery, options);
    var total = rows.length;
    if (rows.isEmpty && title != firstQuery) {
      queries = 2;
      rows = await _search(spec.providerId, title, options);
      total += rows.length;
    }
    if (rows.isEmpty) {
      final plainTitle = simplifiedSearchTitle(track.name);
      final plainArtist = simplifiedSearchArtist(track.artistName);
      final plainQuery = '$plainTitle $plainArtist'.trim();
      if (plainQuery.isNotEmpty &&
          plainQuery != firstQuery.toLowerCase() &&
          plainQuery != title.toLowerCase()) {
        queries++;
        rows = await _search(spec.providerId, plainQuery, options);
        total += rows.length;
      }
    }
    if (rows.isEmpty) {
      return _Outcome(_Kind.empty, queries: queries, rows: total);
    }
    final picked = _select(track, spec, rows, title);
    if (picked == null) {
      return _Outcome(_Kind.miss, queries: queries, rows: total);
    }
    return _Outcome(
      _Kind.hit,
      id: picked.$1,
      via: picked.$2,
      queries: queries,
      rows: total,
    );
  }

  (String, CatalogIdVia)? _select(
    Track track,
    ProviderRequestSpec spec,
    List<Map<String, dynamic>> rows,
    String title,
  ) {
    final isrc = _validIsrc(track);
    final trackArtists = artists(track.artistName);
    final firstArtist = _firstArtistFold(track);
    final trackMarks = _versionMarks(track.name);
    final foldedTitle = fold(title);

    final byIsrc = <(String, double)>[];
    final byTitle = <(String, double)>[];
    for (final row in rows) {
      final type = row['item_type']?.toString();
      if (type != null && type.isNotEmpty && type != 'track') continue;
      final id =
          spec.nativeId(row['id']?.toString() ?? '') ??
          spec.nativeId(row['spotify_id']?.toString() ?? '');
      if (id == null) continue;
      final millis = row['duration_ms'];
      final seconds = millis is num ? millis / 1000 : 0.0;
      final diff = (seconds - track.duration).abs();
      final rowIsrc = normalizeIsrc(row['isrc']?.toString());

      if (isrc.isNotEmpty && rowIsrc == isrc) {
        if (seconds == 0 || track.duration <= 0 || diff <= 10) {
          byIsrc.add((id, seconds == 0 || track.duration <= 0 ? 0 : diff));
        }
        continue;
      }
      if (isrc.isNotEmpty && rowIsrc.isNotEmpty) continue;
      if (isrc.isNotEmpty && rowIsrc.isEmpty || isrc.isEmpty) {
        final rowName = row['name']?.toString() ?? '';
        if (fold(cleanTitle(rowName)) != foldedTitle) continue;
        final rowMarks = _versionMarks(rowName);
        if (rowMarks.length != trackMarks.length ||
            !rowMarks.containsAll(trackMarks)) {
          continue;
        }
        final rowArtistsRaw = row['artists'];
        final rowArtists = artists(
          rowArtistsRaw is List
              ? rowArtistsRaw.join(', ')
              : rowArtistsRaw?.toString() ?? '',
        );
        final rowFirst = rowArtists.isEmpty ? '' : rowArtists.first;
        final shared =
            (firstArtist.isNotEmpty && rowArtists.contains(firstArtist)) ||
            (rowFirst.isNotEmpty && trackArtists.contains(rowFirst));
        if (!shared) continue;
        if (track.duration <= 0 || seconds <= 0 || diff > 3) continue;
        byTitle.add((id, diff));
      }
    }

    if (byIsrc.isNotEmpty) {
      byIsrc.sort((a, b) => a.$2.compareTo(b.$2));
      return (byIsrc.first.$1, CatalogIdVia.isrc);
    }
    if (byTitle.isEmpty) return null;
    byTitle.sort((a, b) => a.$2.compareTo(b.$2));
    final best = byTitle.first;
    for (final other in byTitle.skip(1)) {
      if (other.$1 != best.$1 && other.$2 == best.$2) return null;
    }
    return (best.$1, CatalogIdVia.title);
  }

  Future<void> _store(String key, _Outcome outcome) async {
    final at = _now().millisecondsSinceEpoch;
    switch (outcome.kind) {
      case _Kind.hit:
        _entries[key] = _Entry(id: outcome.id, at: at);
      case _Kind.miss:
        _entries[key] = _Entry(at: at);
      case _Kind.empty:
        _entries[key] = _Entry(at: at, empty: true);
      case _Kind.error:
      case _Kind.skipped:
        return;
    }
    while (_entries.length > maxEntries) {
      final oldest = _entries.entries.reduce(
        (a, b) => a.value.at <= b.value.at ? a : b,
      );
      _entries.remove(oldest.key);
    }
    if (outcome.kind != _Kind.empty) await _persistIfNeeded(key);
  }

  Future<void> _persistIfNeeded(String key) {
    if (!key.contains('|isrc:')) return Future.value();
    _writeChain = _writeChain.then((_) => _write()).catchError((Object _) {});
    return _writeChain;
  }

  Future<File> _file() async =>
      File('${(await _directory()).path}/catalog_ids.json');

  Future<void> _load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final file = await _file();
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is! Map || data['v'] != providerRequestSpecVersion) return;
      final stored = data['e'];
      if (stored is! Map) return;
      for (final entry in stored.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final at = value['at'];
        if (at is! int) continue;
        final id = value['id'];
        final key = entry.key.toString();
        if (id is String) {
          _entries.putIfAbsent(key, () => _Entry(id: id, at: at));
        } else if (value['n'] == 1) {
          _entries.putIfAbsent(key, () => _Entry(at: at));
        }
      }
    } catch (_) {
      _entries.removeWhere((key, _) => key.contains('|isrc:'));
    }
  }

  Future<void> _write() async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final persisted = <String, Map<String, Object>>{};
      for (final entry in _entries.entries) {
        if (!entry.key.contains('|isrc:') || entry.value.empty) continue;
        final id = entry.value.id;
        persisted[entry.key] = id != null
            ? {'id': id, 'at': entry.value.at}
            : {'n': 1, 'at': entry.value.at};
      }
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'v': providerRequestSpecVersion, 'e': persisted}),
        flush: true,
      );
      await temp.rename(file.path);
    } catch (_) {}
  }
}
