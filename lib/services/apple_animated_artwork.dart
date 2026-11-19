import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show PlatformException;
import 'package:mornye/models/track.dart';
import 'package:mornye/services/bundled_extensions_gate.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/string_utils.dart';

typedef AnimatedArtworkHandler = Future<Map<String, dynamic>?> Function(String);

enum AnimatedArtworkVariant { square, tall }

class AnimatedArtworkSource {
  const AnimatedArtworkSource({
    required this.url,
    required this.variant,
    this.previewUrl,
  });

  final String url;
  final AnimatedArtworkVariant variant;
  final String? previewUrl;
}

class AnimatedArtworkVariants {
  const AnimatedArtworkVariants({this.square, this.tall});

  final AnimatedArtworkSource? square;
  final AnimatedArtworkSource? tall;

  bool get isEmpty => square == null && tall == null;
}

enum AnimatedArtworkOutcome { found, absent, unmatched, failed }

class AnimatedArtworkResult {
  const AnimatedArtworkResult(
    this.outcome, [
    this.source,
    this.variants = const AnimatedArtworkVariants(),
  ]);

  final AnimatedArtworkOutcome outcome;
  final AnimatedArtworkSource? source;
  final AnimatedArtworkVariants variants;
}

const _squareKeys = [
  'motionDetailSquare',
  'motionSquareVideo1x1',
  'motionArtworkSquare1x1',
  'motionArtistSquare1x1',
];

const _tallKeys = [
  'motionDetailTall',
  'motionTallVideo3x4',
  'motionArtworkTall3x4',
];

AnimatedArtworkSource? _variantSource(
  Map<Object?, Object?> editorialVideo,
  List<String> keys,
  AnimatedArtworkVariant variant,
) {
  for (final key in keys) {
    final entry = editorialVideo[key];
    if (entry is! Map) continue;
    final url = normalizeRemoteHttpUrl(entry['video']?.toString());
    if (url == null) continue;
    final frame = entry['previewFrame'];
    return AnimatedArtworkSource(
      url: url,
      variant: variant,
      previewUrl: frame is Map
          ? normalizeRemoteHttpUrl(frame['url']?.toString())
          : null,
    );
  }
  return null;
}

/// Both loops Apple offers for an album: the square one and the tall 3:4 one.
AnimatedArtworkVariants selectAnimatedArtworkVariants(Object? editorialVideo) {
  if (editorialVideo is! Map) return const AnimatedArtworkVariants();
  return AnimatedArtworkVariants(
    square: _variantSource(
      editorialVideo,
      _squareKeys,
      AnimatedArtworkVariant.square,
    ),
    tall: _variantSource(
      editorialVideo,
      _tallKeys,
      AnimatedArtworkVariant.tall,
    ),
  );
}

/// Picks the best loop for a square box: a square one when it exists,
/// otherwise a tall 3:4 one, which the player crops to its box.
AnimatedArtworkSource? selectAnimatedArtworkVariant(Object? editorialVideo) {
  final variants = selectAnimatedArtworkVariants(editorialVideo);
  return variants.square ?? variants.tall;
}

Object? _editorialVideoOf(Map<String, dynamic> response) {
  final direct = response['editorial_video'];
  if (direct is Map) return direct;
  final packed = response['header_video'];
  if (packed is String && packed.trimLeft().startsWith('{')) {
    try {
      return jsonDecode(packed);
    } catch (_) {}
  }
  return null;
}

/// Tells "this album has no animated artwork" (and "no album matched") apart
/// from a lookup that did not complete, which must never be kept as absence.
AnimatedArtworkResult classifyAnimatedArtworkResponse(
  Map<String, dynamic>? response,
) {
  if (response == null ||
      response['success'] == false ||
      response['error'] != null ||
      response['type'] != 'animated_artwork') {
    return const AnimatedArtworkResult(AnimatedArtworkOutcome.failed);
  }
  final variants = selectAnimatedArtworkVariants(_editorialVideoOf(response));
  final source = variants.square ?? variants.tall;
  if (source != null) {
    return AnimatedArtworkResult(
      AnimatedArtworkOutcome.found,
      source,
      variants,
    );
  }
  final matched = (response['id']?.toString().trim() ?? '').isNotEmpty;
  return AnimatedArtworkResult(
    matched ? AnimatedArtworkOutcome.absent : AnimatedArtworkOutcome.unmatched,
  );
}

Duration animatedArtworkCacheTtl(AnimatedArtworkOutcome outcome) =>
    switch (outcome) {
      AnimatedArtworkOutcome.found => const Duration(hours: 12),
      AnimatedArtworkOutcome.absent => const Duration(hours: 24),
      AnimatedArtworkOutcome.unmatched => const Duration(hours: 2),
      AnimatedArtworkOutcome.failed => const Duration(minutes: 3),
    };

final _isrcShape = RegExp(r'^[A-Z0-9]{12}$');

String? normalizedArtworkIsrc(String? value) {
  final folded = (value ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
  final upper = folded.toUpperCase();
  return _isrcShape.hasMatch(upper) ? upper : null;
}

String cleanArtworkTitle(String value) => value
    .replaceAll(
      RegExp(
        r'\s*[\(\[]\s*(?:explicit|clean)\s*[\)\]]\s*$',
        caseSensitive: false,
      ),
      '',
    )
    .trim();

/// The parameters sent to the art provider. The audio provider's ids never
/// appear here: art is identified by ISRC and, as a fallback, by title,
/// artist, album and duration. Only Apple's own numeric ids are passed on.
Map<String, String> animatedArtworkRequestParams(
  Track track, {
  String? storefront,
}) {
  final id = track.id.trim();
  final source = (track.source ?? '').trim().toLowerCase().replaceAll('_', '-');
  final appleId = RegExp(r'^(?:apple-music:)?(\d+)$').firstMatch(id)?.group(1);
  final albumId = (track.albumId ?? '').trim();
  final fromApple = source == 'apple-music' || id.startsWith('apple-music:');
  final isrc = normalizedArtworkIsrc(track.isrc);
  return <String, String>{
    if (storefront != null && storefront.isNotEmpty) 'storefront': storefront,
    if (fromApple && RegExp(r'^\d+$').hasMatch(albumId)) 'album_id': albumId,
    if (fromApple && appleId != null) 'track_id': appleId,
    'isrc': ?isrc,
    'title': cleanArtworkTitle(track.name),
    'artist': track.artistName.trim(),
    if (track.albumName.trim().isNotEmpty) 'album': track.albumName.trim(),
    if (track.duration > 0) 'duration_ms': '${track.duration * 1000}',
  };
}

String animatedArtworkLookupUrl(Track track, {String? storefront}) {
  return Uri(
    scheme: 'apple-music',
    path: 'animated-artwork',
    queryParameters: animatedArtworkRequestParams(
      track,
      storefront: storefront,
    ),
  ).toString();
}

/// A readable account of a lookup, without tokens: what was asked and which
/// album Apple resolved, with the keys of its editorial video.
String describeAnimatedArtworkLookup(
  Map<String, String> request,
  Map<String, dynamic>? response,
) {
  final asked =
      'request album=${request['album_id'] ?? '-'} '
      'track=${request['track_id'] ?? '-'} '
      'isrc=${request['isrc'] ?? '-'} '
      'storefront=${request['storefront'] ?? '-'}';
  if (response == null) return '$asked -> no response';
  final video = _editorialVideoOf(response);
  final keys = video is Map ? video.keys.join(',') : '';
  final name = _truncate('${response['name'] ?? ''}', 60);
  return '$asked -> resolved album=${response['id'] ?? ''} name=$name '
      'editorialVideo=${keys.isNotEmpty} keys=$keys '
      'storefront=${response['storefront'] ?? ''} '
      'attempts=${response['attempts'] ?? ''}';
}

String _truncate(String text, [int max = 200]) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length > max ? flat.substring(0, max) : flat;
}

/// A readable account of a failed lookup that does not depend on the
/// obfuscated runtime type name.
String describeLookupError(Object error) {
  if (error is PlatformException) {
    return 'type=PlatformException code=${error.code} '
        'message=${_truncate('${error.message}')}';
  }
  if (error is TimeoutException) return 'type=Timeout';
  return 'type=${error.runtimeType} message=${_truncate(error.toString())}';
}

String animatedArtworkKey(Track track) {
  String fold(String value) => value.toLowerCase().replaceAll(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
    '',
  );
  final album = fold(track.albumName);
  final artist = fold(
    (track.albumArtist ?? '').trim().isNotEmpty
        ? track.albumArtist!
        : track.artistName,
  );
  if (album.isNotEmpty) return '$artist|$album';
  return '$artist|${fold(track.name)}';
}

final _lookupLog = AppLogger('AppleAnimatedArtwork');

void _defaultLog(String message) {
  debugPrint('animated artwork: $message');
  _lookupLog.i(message);
}

class _Entry {
  _Entry(this.result, this.expiresAt, this.pluginVersion);

  final AnimatedArtworkResult result;
  final int expiresAt;
  final String pluginVersion;
}

class _Absence {
  const _Absence(this.at, this.pluginVersion);

  final int at;
  final String pluginVersion;
}

class AppleAnimatedArtworkLookup {
  AppleAnimatedArtworkLookup({
    AnimatedArtworkHandler? handleUrl,
    Future<Directory> Function()? directory,
    DateTime Function()? now,
    void Function(String message)? log,
    this.timeout = const Duration(seconds: 15),
    this.retryDelays = const [Duration(milliseconds: 600)],
    this.ready,
    this.readyTimeout = const Duration(seconds: 15),
    String Function()? pluginVersion,
    this.installed,
  }) : _pluginVersion = pluginVersion ?? (() => ''),
       _handleUrl = handleUrl ?? PlatformBridge.handleURLWithExtension,
       _directory = directory ?? MotionArtworkStore.defaultDirectory,
       _now = now ?? DateTime.now,
       _log = log ?? _defaultLog;

  static const _maxEntries = 256;
  static const _saveRetry = Duration(minutes: 5);

  final AnimatedArtworkHandler _handleUrl;
  final Future<Directory> Function() _directory;
  final DateTime Function() _now;
  final void Function(String message) _log;
  final Duration timeout;
  final List<Duration> retryDelays;
  final Future<void> Function()? ready;
  final Duration readyTimeout;

  /// When set and false, the add-on is not installed and nothing is looked up.
  final bool Function()? installed;
  final String Function() _pluginVersion;
  final _memory = <String, _Entry>{};
  final _pending = <String, Future<AnimatedArtworkResult>>{};
  final _saveFailures = <String, int>{};
  Map<String, _Absence>? _absent;

  Future<AnimatedArtworkResult> lookup(Track track, {String? storefront}) {
    final key = animatedArtworkKey(track);
    if (track.name.trim().isEmpty || track.artistName.trim().isEmpty) {
      return Future.value(
        const AnimatedArtworkResult(AnimatedArtworkOutcome.unmatched),
      );
    }
    final known = _memory[key];
    if (known != null &&
        known.expiresAt > _nowMs &&
        known.result.outcome == AnimatedArtworkOutcome.found) {
      return Future.value(known.result);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        await awaitBundledExtensions(ready, timeout: readyTimeout, log: _log);
        if (installed != null && !installed!()) {
          return const AnimatedArtworkResult(AnimatedArtworkOutcome.unmatched);
        }
        final current = _memory[key];
        if (current != null &&
            current.expiresAt > _nowMs &&
            current.pluginVersion == _pluginVersion()) {
          return current.result;
        }
        return await _resolve(track, key, storefront);
      } finally {
        _pending.remove(key);
      }
    });
  }

  String _failureKey(Track track, AnimatedArtworkVariant? variant) =>
      variant == AnimatedArtworkVariant.tall
      ? '${animatedArtworkKey(track)}|tall'
      : animatedArtworkKey(track);

  bool saveBlocked(Track track, {AnimatedArtworkVariant? variant}) {
    final failedAt = _saveFailures[_failureKey(track, variant)];
    return failedAt != null && _nowMs - failedAt < _saveRetry.inMilliseconds;
  }

  void recordSaveFailure(Track track, {AnimatedArtworkVariant? variant}) {
    if (_saveFailures.length > _maxEntries) _saveFailures.clear();
    _log('save failed phase=download variant=${variant?.name ?? 'any'}');
    _saveFailures[_failureKey(track, variant)] = _nowMs;
  }

  int get _nowMs => _now().millisecondsSinceEpoch;

  Future<AnimatedArtworkResult> _resolve(
    Track track,
    String key,
    String? storefront,
  ) async {
    final version = _pluginVersion();
    final persisted = await _persistedAbsence(key, version);
    if (persisted != null) {
      _log('skipped, ${persisted.name} cached');
      return AnimatedArtworkResult(persisted);
    }
    AnimatedArtworkResult result;
    try {
      final request = animatedArtworkRequestParams(
        track,
        storefront: storefront,
      );
      final response = await _withRetry(
        () => _handleUrl(
          animatedArtworkLookupUrl(track, storefront: storefront),
        ).timeout(timeout),
      );
      _log(describeAnimatedArtworkLookup(request, response));
      result = classifyAnimatedArtworkResponse(response);
      if (result.outcome == AnimatedArtworkOutcome.failed) {
        _log(
          'lookup failed phase=lookup response=${_describeResponse(response)}',
        );
      }
    } catch (error) {
      _log('lookup error phase=lookup ${describeLookupError(error)}');
      result = const AnimatedArtworkResult(AnimatedArtworkOutcome.failed);
    }
    _log('outcome ${result.outcome.name}');
    _remember(key, result, version);
    return result;
  }

  String _describeResponse(Map<String, dynamic>? response) {
    if (response == null) return 'null';
    final error = response['error'];
    final text =
        'success=${response['success']} type=${response['type']} '
        'error=$error';
    return _truncate(text);
  }

  Future<T> _withRetry<T>(Future<T> Function() call) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await call();
      } catch (_) {
        if (attempt >= retryDelays.length) rethrow;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
  }

  void _remember(String key, AnimatedArtworkResult result, String version) {
    if (_memory.length > _maxEntries) _memory.clear();
    final ttl = animatedArtworkCacheTtl(result.outcome);
    _memory[key] = _Entry(result, _nowMs + ttl.inMilliseconds, version);
    if (result.outcome == AnimatedArtworkOutcome.absent ||
        result.outcome == AnimatedArtworkOutcome.unmatched) {
      unawaited(_persistAbsence(key, result.outcome, version));
    }
  }

  Future<File> _file() async => File(
    '${(await _directory()).path}/apple_animated_artwork_absent_v3.json',
  );

  Future<Map<String, _Absence>> _loadAbsent() async {
    final loaded = _absent;
    if (loaded != null) return loaded;
    final entries = <String, _Absence>{};
    try {
      final file = await _file();
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString());
        if (data is Map) {
          for (final entry in data.entries) {
            final value = entry.value;
            if (value is Map && value['at'] is int) {
              entries[entry.key.toString()] = _Absence(
                value['at'] as int,
                value['v']?.toString() ?? '',
              );
            }
          }
        }
      }
    } catch (_) {}
    return _absent ??= entries;
  }

  static const _absentMark = 'a|';
  static const _unmatchedMark = 'u|';

  Future<AnimatedArtworkOutcome?> _persistedAbsence(
    String key,
    String version,
  ) async {
    final entries = await _loadAbsent();
    for (final (mark, outcome) in [
      (_absentMark, AnimatedArtworkOutcome.absent),
      (_unmatchedMark, AnimatedArtworkOutcome.unmatched),
    ]) {
      final saved = entries['$mark$key'];
      if (saved == null) continue;
      if (saved.pluginVersion == version &&
          _nowMs - saved.at < animatedArtworkCacheTtl(outcome).inMilliseconds) {
        return outcome;
      }
      entries.remove('$mark$key');
    }
    return null;
  }

  Future<void> _persistAbsence(
    String key,
    AnimatedArtworkOutcome outcome,
    String version,
  ) async {
    final entries = await _loadAbsent();
    final mark = outcome == AnimatedArtworkOutcome.absent
        ? _absentMark
        : _unmatchedMark;
    entries['$mark$key'] = _Absence(_nowMs, version);
    if (entries.length > _maxEntries) {
      final oldest = entries.entries.reduce(
        (a, b) => a.value.at <= b.value.at ? a : b,
      );
      entries.remove(oldest.key);
    }
    try {
      final file = await _file();
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
}
