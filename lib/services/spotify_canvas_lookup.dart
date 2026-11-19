import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/bundled_extensions_gate.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

typedef SpotifyCanvasSearch =
    Future<List<Map<String, dynamic>>> Function(String query);
typedef SpotifyCanvasUrlHandler =
    Future<Map<String, dynamic>?> Function(String url);

enum CanvasState {
  found('found'),
  absentConfirmed('absent_confirmed'),
  emptyAmbiguous('empty_ambiguous'),
  error('error'),
  rateLimited('rate_limited');

  const CanvasState(this.wire);
  final String wire;

  static CanvasState? parse(Object? value) {
    final text = value?.toString().trim().toLowerCase();
    for (final state in values) {
      if (state.wire == text) return state;
    }
    return null;
  }
}

class CanvasResult {
  const CanvasResult(this.state, {this.url, this.reason = '', this.retryAfter});
  final CanvasState state;
  final String? url;
  final String reason;
  final Duration? retryAfter;

  /// Reads the add-on answer. The relay keeps only `header_video`, so the
  /// state travels there: a direct URL when found, a JSON status otherwise.
  static CanvasResult parse(Map<String, dynamic> response) {
    final raw = response['header_video']?.toString().trim() ?? '';
    if (raw.isNotEmpty && !raw.startsWith('{')) {
      final url = normalizeRemoteHttpUrl(raw);
      if (url != null) return CanvasResult(CanvasState.found, url: url);
      return const CanvasResult(
        CanvasState.emptyAmbiguous,
        reason: 'invalid_url',
      );
    }
    Map<String, dynamic>? status;
    if (raw.startsWith('{')) {
      try {
        final decoded = jsonDecode(raw);
        if (decoded is Map) status = decoded.cast<String, dynamic>();
      } catch (_) {}
      if (status == null) {
        return const CanvasResult(
          CanvasState.emptyAmbiguous,
          reason: 'bad_status',
        );
      }
    } else if (response['canvas_state'] != null) {
      status = response;
    }
    if (status == null) {
      return const CanvasResult(
        CanvasState.emptyAmbiguous,
        reason: 'legacy_empty',
      );
    }
    final state = CanvasState.parse(status['canvas_state']);
    final reason = status['reason']?.toString().trim() ?? '';
    switch (state) {
      case CanvasState.absentConfirmed:
      case CanvasState.emptyAmbiguous:
      case CanvasState.error:
        return CanvasResult(state!, reason: reason);
      case CanvasState.rateLimited:
        final seconds = status['retry_after'];
        return CanvasResult(
          CanvasState.rateLimited,
          reason: reason,
          retryAfter: seconds is num && seconds > 0
              ? Duration(seconds: seconds.round())
              : null,
        );
      case CanvasState.found:
      case null:
        return const CanvasResult(
          CanvasState.emptyAmbiguous,
          reason: 'bad_status',
        );
    }
  }
}

class _Resolved {
  const _Resolved(this.id, this.via);
  final String id;
  final String via;
}

class _Miss {
  const _Miss(this.at, this.pluginVersion);
  final int at;
  final String pluginVersion;
}

class _TransientFailure implements Exception {
  const _TransientFailure(this.reason);
  final String reason;
}

final _canvasLog = AppLogger('SpotifyCanvas');

void _defaultCanvasLog(String message) {
  debugPrint('canvas: $message');
  _canvasLog.i(message);
}

class SpotifyCanvasLookup {
  SpotifyCanvasLookup({
    SpotifyCanvasSearch? search,
    SpotifyCanvasUrlHandler? handleUrl,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
    void Function(String message)? log,
    this.timeout = const Duration(seconds: 12),
    this.missDuration = const Duration(hours: 24),
    this.transientMissDuration = const Duration(minutes: 3),
    this.ambiguousDuration = const Duration(minutes: 30),
    this.rateLimitMin = const Duration(minutes: 5),
    this.rateLimitMax = const Duration(hours: 1),
    this.retryDelays = const [
      Duration(milliseconds: 600),
      Duration(milliseconds: 1500),
    ],
    this.ready,
    this.readyTimeout = const Duration(seconds: 15),
    String Function()? pluginVersion,
    this.installed,
  }) : _pluginVersion = pluginVersion ?? (() => ''),
       _search = search ?? _defaultSearch,
       _handleUrl = handleUrl ?? PlatformBridge.handleURLWithExtension,
       _directory = directory ?? MotionArtworkStore.defaultDirectory,
       _now = now ?? DateTime.now,
       _log = log ?? _defaultCanvasLog;

  static const extensionId = 'spotify-web';
  static final _spotifyId = RegExp(r'^[A-Za-z0-9]{22}$');
  static const _maxMisses = 512;

  final SpotifyCanvasSearch _search;
  final SpotifyCanvasUrlHandler _handleUrl;
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final void Function(String message) _log;
  final Duration timeout;
  final Duration missDuration;
  final Duration transientMissDuration;
  final Duration ambiguousDuration;
  final Duration rateLimitMin;
  final Duration rateLimitMax;
  final List<Duration> retryDelays;
  final Future<void> Function()? ready;
  final Duration readyTimeout;

  /// When set and false, the add-on is not installed and nothing is looked up.
  final bool Function()? installed;
  final String Function() _pluginVersion;
  final _found = <String, String>{};
  final _pending = <String, Future<String?>>{};
  final _transientMisses = <String, int>{};
  Map<String, _Miss>? _misses;
  Map<String, _Miss>? _ambiguous;
  int _rateLimitedUntil = 0;

  static Future<List<Map<String, dynamic>>> _defaultSearch(String query) =>
      PlatformBridge.customSearchWithExtension(
        extensionId,
        query,
        options: const {'limit': 8, 'filter': 'tracks'},
      );

  Future<String?> lookup(Track track, {bool enabled = true}) {
    final id = track.id.trim();
    if (!enabled || id.isEmpty) return Future.value();
    final key = '$id|${(track.isrc ?? '').trim().toUpperCase()}';
    final known = _found[key];
    if (known != null) return Future.value(known);
    return _pending.putIfAbsent(key, () async {
      try {
        await awaitBundledExtensions(ready, timeout: readyTimeout, log: _log);
        if (installed != null && !installed!()) return null;
        final again = _found[key];
        if (again != null) return again;
        return await _resolve(track, key).timeout(timeout);
      } on TimeoutException {
        _log('lookup timeout after ${timeout.inSeconds}s');
        await _recordMiss(key, long: false);
        return null;
      } catch (error) {
        _log('lookup error ${error.runtimeType}');
        await _recordMiss(key, long: false);
        return null;
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<String?> _resolve(Track track, String key) async {
    final id = track.id.trim();
    _log(
      'lookup start track=${id.length > 12 ? id.substring(0, 12) : id} '
      'isrc=${(track.isrc ?? '').trim().isEmpty ? 'no' : 'yes'}',
    );
    if (await _isMiss(key)) {
      _log('skipped, recent miss cached');
      return null;
    }
    final result = await _fetch(track);
    switch (result.state) {
      case CanvasState.found:
        _found[key] = result.url!;
        _log('found');
        return result.url;
      case CanvasState.absentConfirmed:
        await _recordMiss(key, long: true);
        return null;
      case CanvasState.emptyAmbiguous:
        await _recordAmbiguous(key);
        return null;
      case CanvasState.error:
        await _recordMiss(key, long: false);
        return null;
      case CanvasState.rateLimited:
        _recordRateLimit(result.retryAfter);
        return null;
    }
  }

  void _logState(CanvasResult result, String spotifyId, String via) => _log(
    'state=${result.state.wire} '
    'reason=${result.reason.isEmpty ? '-' : result.reason} '
    'spotifyId=$spotifyId via=$via',
  );

  Future<CanvasResult> _fetch(Track track) async {
    try {
      final resolved = await _spotifyIdFor(track);
      if (resolved == null) {
        return const CanvasResult(
          CanvasState.absentConfirmed,
          reason: 'no_match',
        );
      }
      final response = await _withRetry(
        'handler',
        () => _handleUrl('spotify:canvas:${resolved.id}'),
      );
      final CanvasResult result;
      if (response == null) {
        result = const CanvasResult(CanvasState.error, reason: 'no_response');
      } else if (response['success'] == false || response['error'] != null) {
        result = const CanvasResult(CanvasState.error, reason: 'plugin');
      } else {
        result = CanvasResult.parse(response);
      }
      _logState(result, resolved.id, resolved.via);
      return result;
    } on _TransientFailure catch (failure) {
      _log('handler result error ${failure.reason}');
      return CanvasResult(CanvasState.error, reason: failure.reason);
    }
  }

  Future<T> _withRetry<T>(String stage, Future<T> Function() call) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await call();
      } catch (error) {
        if (attempt >= retryDelays.length) {
          throw _TransientFailure('$stage ${error.runtimeType}');
        }
        _log('$stage failed ${error.runtimeType}, retry ${attempt + 1}');
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _searchWithRetry(String query) =>
      _withRetry('search', () => _search(query));

  Future<_Resolved?> _spotifyIdFor(Track track) async {
    final id = track.id.trim();
    final source = (track.source ?? '').trim().toLowerCase();
    if ((source == extensionId || source == 'spotify') &&
        _spotifyId.hasMatch(id)) {
      _log('spotifyId=$id via=source');
      return _Resolved(id, 'source');
    }
    final isrc = (track.isrc ?? '').trim().toUpperCase();
    var anyResults = false;
    if (isrc.isNotEmpty) {
      final results = await _searchWithRetry('isrc:$isrc');
      anyResults = results.isNotEmpty;
      final byIsrc = _pickByIsrc(results, isrc);
      if (byIsrc != null) {
        _log('spotifyId=$byIsrc via=isrc');
        return _Resolved(byIsrc, 'isrc');
      }
    }
    final title = track.name.trim();
    final artist = track.artistName.trim();
    if (title.isEmpty || artist.isEmpty || track.duration <= 0) {
      _log('spotifyId=none via=none, not enough metadata for name search');
      if (isrc.isNotEmpty && !anyResults) {
        throw const _TransientFailure('search empty');
      }
      return null;
    }
    final results = await _searchWithRetry('$title $artist');
    anyResults = anyResults || results.isNotEmpty;
    final byName = _pickByName(results, track);
    if (byName != null) {
      _log('spotifyId=$byName via=name');
      return _Resolved(byName, 'name');
    }
    _log('spotifyId=none via=name results=${results.length}');
    if (!anyResults) throw const _TransientFailure('search empty');
    return null;
  }

  String? _pickByIsrc(List<Map<String, dynamic>> results, String isrc) {
    for (final item in results) {
      final id = _idOf(item);
      if (id == null) continue;
      final other = (item['isrc']?.toString() ?? '').trim().toUpperCase();
      if (other == isrc) return id;
    }
    return null;
  }

  String? _pickByName(List<Map<String, dynamic>> results, Track track) {
    final title = _fold(track.name);
    final artists = _artists(track.artistName);
    if (title.isEmpty || artists.isEmpty) return null;
    for (final item in results) {
      final id = _idOf(item);
      if (id == null || _fold(item['name']?.toString() ?? '') != title) {
        continue;
      }
      final millis = item['duration_ms'];
      if (millis is! num ||
          (millis / 1000 - track.duration).abs() > 3 ||
          !_artists(item['artists']?.toString() ?? '').any(artists.contains)) {
        continue;
      }
      return id;
    }
    return null;
  }

  String? _idOf(Map<String, dynamic> item) {
    for (final key in const ['spotify_id', 'id']) {
      final value = item[key]?.toString().trim() ?? '';
      if (_spotifyId.hasMatch(value)) return value;
    }
    return null;
  }

  static String _fold(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );

  static Set<String> _artists(String value) => {
    for (final part in value.split(
      RegExp(r'\s*(?:,|;|&|\bfeat\.?|\bft\.?)\s*', caseSensitive: false),
    ))
      if (_fold(part).isNotEmpty) _fold(part),
  };

  Future<File> _missFile() async =>
      File('${(await _directory()).path}/spotify_canvas_misses_v3.json');

  Future<File> _ambiguousFile() async =>
      File('${(await _directory()).path}/spotify_canvas_ambiguous_v1.json');

  Future<bool> _isMiss(String key) async {
    final now = _now().millisecondsSinceEpoch;
    if (now < _rateLimitedUntil) return true;
    final soft = _transientMisses[key];
    if (soft != null) {
      if (now - soft < transientMissDuration.inMilliseconds) return true;
      _transientMisses.remove(key);
    }
    final misses = await _loadMisses();
    final saved = misses[key];
    if (saved != null) {
      if (saved.pluginVersion == _pluginVersion() &&
          now - saved.at < missDuration.inMilliseconds) {
        return true;
      }
      misses.remove(key);
    }
    final ambiguous = await _loadAmbiguous();
    final unsure = ambiguous[key];
    if (unsure == null) return false;
    if (unsure.pluginVersion == _pluginVersion() &&
        now - unsure.at < ambiguousDuration.inMilliseconds) {
      return true;
    }
    ambiguous.remove(key);
    return false;
  }

  Future<Map<String, _Miss>> _loadMisses() async =>
      _misses ??= await _readStore(_missFile);

  Future<Map<String, _Miss>> _loadAmbiguous() async =>
      _ambiguous ??= await _readStore(_ambiguousFile);

  Future<Map<String, _Miss>> _readStore(Future<File> Function() open) async {
    final entries = <String, _Miss>{};
    try {
      final file = await open();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map) {
          for (final entry in data.entries) {
            final value = entry.value;
            if (value is Map && value['at'] is int) {
              entries[entry.key.toString()] = _Miss(
                value['at'] as int,
                value['v']?.toString() ?? '',
              );
            }
          }
        }
      }
    } catch (_) {}
    return entries;
  }

  Future<void> _writeStore(
    Future<File> Function() open,
    Map<String, _Miss> entries,
  ) async {
    if (entries.length > _maxMisses) {
      final oldest = entries.entries.reduce(
        (a, b) => a.value.at <= b.value.at ? a : b,
      );
      entries.remove(oldest.key);
    }
    try {
      final file = await open();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          for (final e in entries.entries)
            e.key: {'at': e.value.at, 'v': e.value.pluginVersion},
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _recordMiss(String key, {required bool long}) async {
    _log('miss recorded ${long ? 'long' : 'short'}');
    if (!long) {
      if (_transientMisses.length > _maxMisses) _transientMisses.clear();
      _transientMisses[key] = _now().millisecondsSinceEpoch;
      return;
    }
    final misses = await _loadMisses();
    misses[key] = _Miss(_now().millisecondsSinceEpoch, _pluginVersion());
    await _writeStore(_missFile, misses);
  }

  Future<void> _recordAmbiguous(String key) async {
    _log('miss recorded ambiguous');
    final ambiguous = await _loadAmbiguous();
    ambiguous[key] = _Miss(_now().millisecondsSinceEpoch, _pluginVersion());
    await _writeStore(_ambiguousFile, ambiguous);
  }

  void _recordRateLimit(Duration? retryAfter) {
    var wait = retryAfter ?? rateLimitMin;
    if (wait < rateLimitMin) wait = rateLimitMin;
    if (wait > rateLimitMax) wait = rateLimitMax;
    _rateLimitedUntil = _now().millisecondsSinceEpoch + wait.inMilliseconds;
    _log('miss recorded rate limit ${wait.inSeconds}s');
  }
}
