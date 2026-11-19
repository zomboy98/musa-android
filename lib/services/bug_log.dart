import 'dart:async';
import 'dart:convert';

// Flutter exposes characters for grapheme-safe text truncation.
// ignore: depend_on_referenced_packages
import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:mornye/utils/download_error_type.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TemporaryPreparationFailure implements Exception {
  const TemporaryPreparationFailure([this.reason = 'unknown']);
  final String reason;
}

/// Automatic records exclude exception messages and locations.
enum TemporaryPipelineStage {
  verification,
  provider,
  matching,
  quality,
  download,
  finalization,
  fileAccess,
  playback,
}

enum TemporaryPipelineOutcome {
  required,
  accepted,
  completed,
  ready,
  failed,
  cancelled,
}

class BugLog extends ChangeNotifier {
  BugLog({Future<SharedPreferences> Function()? preferences})
    : _preferences = preferences ?? SharedPreferences.getInstance;

  static final instance = BugLog();
  static const key = 'local_bug_log_v1';
  static const maxEntries = 100;
  static const maxNoteLength = 500;
  final Future<SharedPreferences> Function() _preferences;
  Future<void> _pending = Future.value();
  final List<Map<String, String>> _batch = [];
  final Map<int, int> _dropped = {};
  bool _persistenceFailed = false;
  bool get persistenceFailed => _persistenceFailed;
  bool _cacheUntrusted = false;
  Future<SharedPreferences> _trustedPreferences() async {
    final prefs = await _preferences();
    if (_cacheUntrusted) {
      await prefs.reload();
      _cacheUntrusted = false;
    }
    return prefs;
  }

  Future<void> _invalidateCache(SharedPreferences prefs) async {
    _cacheUntrusted = true;
    try {
      await prefs.reload();
      _cacheUntrusted = false;
    } catch (_) {
      // A later operation must reload successfully before using this cache.
    }
  }

  int _generation = 0;
  int? _scheduledGeneration;
  static final Object _notificationZone = Object();
  static final Object _suppressionZone = Object();

  static void suppressCapture(void Function() action) =>
      runZoned(action, zoneValues: {_suppressionZone: true});

  static String categoryForTag(String tag) {
    final value = tag.toLowerCase();
    if (value.contains('search')) return 'search';
    if (value.contains('download')) return 'download';
    if (value.contains('player') || value.contains('playback')) return 'player';
    return 'application';
  }

  /// Restricted diagnostic vocabulary; no provider-supplied text is stored.
  static String temporaryErrorType(Object? value) =>
      downloadDiagnosticErrorType(value);

  static String temporaryReason(Object? value) =>
      const {
        'provider download failed': 'provider_download_failed',
        'provider track not found': 'provider_track_not_found',
        'provider unavailable': 'provider_unavailable',
        'provider intervention required': 'provider_intervention_required',
        'encrypted output unsupported': 'encrypted_output_unsupported',
        'invalid provider output': 'invalid_provider_output',
        'AAC conversion failed': 'aac_conversion_failed',
        'invalid AAC output': 'invalid_aac_output',
        'Opus conversion failed': 'opus_conversion_failed',
        'invalid Opus output': 'invalid_opus_output',
        'invalid temporary request': 'invalid_temporary_request',
        'invalid temporary copy': 'invalid_temporary_copy',
        'audio stream not identified': 'audio_stream_not_identified',
        'unsupported audio format': 'unsupported_audio_format',
        'flac remux failed': 'flac_remux_failed',
        'invalid audio output': 'invalid_audio_output',
        'verification timed out': 'verification_timed_out',
        'provider session expired': 'provider_session_expired',
        'provider reauth required': 'provider_reauth_required',
        'provider quality unavailable': 'provider_quality_unavailable',
        'provider rate limited': 'provider_rate_limited',
        'provider subscription required': 'provider_subscription_required',
        'provider network blocked': 'provider_network_blocked',
        'provider network failed': 'provider_network_failed',
        'provider timed out': 'provider_timed_out',
        'provider stream expired': 'provider_stream_expired',
        'provider storage failed': 'provider_storage_failed',
        'preparation timed out': 'preparation_timed_out',
        'progressive position unavailable': 'progressive_position_unavailable',
        'finalization failed': 'finalization_failed',
        'invalid finalization output': 'invalid_finalization_output',
        'AC-4 repair failed': 'ac4_repair_failed',
        'private finalization unavailable': 'private_finalization_unavailable',
        'preparation failed': 'preparation_failed',
        'cancelled': 'cancelled',
      }[value] ??
      'unknown';

  static String _downloadStage(Object? value) => switch (value) {
    'preparing_output' || 'preparing output directory' => 'preparing_output',
    'backend_download' || 'downloading' => 'backend_download',
    'android_finalizing' || 'finalizing' => 'android_finalizing',
    _ => 'unknown',
  };

  static String _downloadCause(Object? value) => switch (value) {
    'encrypted_validation_guard' => 'encrypted_validation_guard',
    'strict_quality_mismatch' => 'strict_quality_mismatch',
    'strict_quality_unverified' => 'strict_quality_unverified',
    'quality_selection_unavailable' => 'quality_selection_unavailable',
    'encrypted_finalization_unavailable' =>
      'encrypted_finalization_unavailable',
    _ => 'unknown',
  };

  static const maxProviderAttempts = 64;
  static const _attemptStages = {
    'availability',
    'availability_operation_error',
    'availability_operation_timeout',
    'availability_response_unavailable',
    'preflight_error',
    'preflight_verification_required',
    'download',
  };

  /// Closed projection of an untrusted `provider_attempts` list. Each item is
  /// `provider:stage:error_type` (empty error type -> `none`); every field comes
  /// from an explicit list, anything else becomes `unknown`. Order is kept, at
  /// most [maxProviderAttempts] items are read, non-map items are skipped.
  /// Returns an empty list when the value is absent or not a list.
  static List<String> sanitizeProviderAttempts(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final entry in raw.take(maxProviderAttempts)) {
      if (entry is! Map) continue;
      final stage = entry['stage'];
      final type = entry['error_type'];
      final typeCode = type == null || (type is String && type.isEmpty)
          ? 'none'
          : temporaryErrorType(type);
      out.add(
        '${temporaryProvider(entry['provider'])}:'
        '${stage is String && _attemptStages.contains(stage) ? stage : 'unknown'}:'
        '$typeCode',
      );
    }
    return out;
  }

  static const _attemptReasonClasses = {
    'no_match',
    'lookup_failed',
    'cancelled',
    'identity_missing',
    'direct_unplayable',
    'empty',
    'other',
  };
  static const _attemptIdSources = {
    'availability',
    'request',
    'native_alias',
    'empty',
  };

  /// Like [sanitizeProviderAttempts] but each item may append closed-list
  /// details: `/reason_class=<token>`, `/id_source=<token>`, `/id_len=<0-255>`
  /// and `/retry_after_s=<0-86400>`. Invalid or absent values are omitted.
  /// Not used for the persisted frames format.
  static List<String> sanitizeProviderAttemptDetails(Object? raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final entry in raw.take(maxProviderAttempts)) {
      if (entry is! Map) continue;
      final stage = entry['stage'];
      final type = entry['error_type'];
      final typeCode = type == null || (type is String && type.isEmpty)
          ? 'none'
          : temporaryErrorType(type);
      final reasonClass = entry['reason_class'];
      final idSource = entry['id_source'];
      final idLen = entry['id_len'];
      final retryAfter = entry['retry_after_s'];
      out.add(
        '${temporaryProvider(entry['provider'])}:'
        '${stage is String && _attemptStages.contains(stage) ? stage : 'unknown'}:'
        '$typeCode'
        '${reasonClass is String && _attemptReasonClasses.contains(reasonClass) ? '/reason_class=$reasonClass' : ''}'
        '${idSource is String && _attemptIdSources.contains(idSource) ? '/id_source=$idSource' : ''}'
        '${idLen is int && idLen >= 0 && idLen <= 255 ? '/id_len=$idLen' : ''}'
        '${retryAfter is int && retryAfter >= 0 && retryAfter <= 86400 ? '/retry_after_s=$retryAfter' : ''}',
      );
    }
    return out;
  }

  /// Re-validates a persisted `attempts_` payload (also protects against
  /// tampered stored rows). Returns null when empty.
  static String? _attemptsFromStored(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    final out = <String>[];
    for (final item in payload.split(';').take(maxProviderAttempts)) {
      final parts = item.split(':');
      if (parts.length != 3) continue;
      out.add(
        '${temporaryProvider(parts[0])}:'
        '${_attemptStages.contains(parts[1]) ? parts[1] : 'unknown'}:'
        '${parts[2] == 'none' ? 'none' : temporaryErrorType(parts[2])}',
      );
    }
    return out.isEmpty ? null : out.join(';');
  }

  /// One line with the stage, error type, cause, provider and attempts of a
  /// download failure, reduced to the closed lists of the failure log.
  static String downloadFailureSummary({
    Object? stage,
    Object? errorType,
    Object? cause,
    Object? provider,
    Object? providerAttempts,
  }) => _downloadFrames(
    stage,
    errorType,
    cause,
    provider,
    sanitizeProviderAttempts(providerAttempts).join(';'),
  );

  /// [provider] is optional: when null the `provider_` field is omitted (legacy
  /// format). When present it is reduced to [temporaryProvider]'s allowlist, so
  /// URLs, credentials or arbitrary text become `provider_unknown`.
  /// [attempts] is an already sanitized list from [sanitizeProviderAttempts];
  /// when empty the `attempts_` field is omitted (legacy format).
  static String _downloadFrames(
    Object? stage,
    Object? errorType,
    Object? cause, [
    Object? provider,
    String? attempts,
  ]) {
    final stageCode = _downloadStage(stage);
    final typeCode = temporaryErrorType(errorType);
    final causeCode = stageCode == 'backend_download'
        ? _downloadCause(cause)
        : 'unknown';
    final base = 'stage_$stageCode, error_type_$typeCode, cause_$causeCode';
    final withProvider = provider == null
        ? base
        : '$base, provider_${temporaryProvider(provider)}';
    return attempts == null || attempts.isEmpty
        ? withProvider
        : '$withProvider, attempts_$attempts';
  }

  /// [provider] is the provider reported with the retained failure (e.g. the
  /// backend result `service`). It is NOT guaranteed to reflect every fallback
  /// attempted; pass null when unknown to omit the field.
  Future<void> recordTerminalDownloadFailure({
    required Object? stage,
    required Object? errorType,
    Object? cause,
    Object? provider,
    Object? providerAttempts,
  }) {
    if (const {
      'verification_required',
      'cancelled',
    }.contains(temporaryErrorType(errorType))) {
      return Future.value();
    }
    return _appendAutomatic(
      category: 'download',
      type: 'TerminalDownloadFailure',
      frames: _downloadFrames(
        stage,
        errorType,
        cause,
        provider,
        sanitizeProviderAttempts(providerAttempts).join(';'),
      ),
    );
  }

  static String temporaryProvider(Object? value) =>
      switch (value is String ? value.trim().toLowerCase() : null) {
        'amazon' || 'amazon-extension' => 'amazon',
        'deezer' || 'deezer-extension' => 'deezer',
        'tidal' || 'tidal-web' || 'tidal-extension' => 'tidal',
        'qobuz' || 'qobuz-web' => 'qobuz',
        'spotify' || 'spotify-web' => 'spotify',
        'youtube' || 'ytmusic-spotiflac' => 'youtube',
        'apple-music' ||
        'beatport' ||
        'bugs-music' ||
        'genie-music' ||
        'jiosaavn' ||
        'melon-music' ||
        'soundcloud' => (value as String).trim().toLowerCase(),
        _ => 'unknown',
      };

  static String _temporaryStage(TemporaryPipelineStage stage) =>
      stage == TemporaryPipelineStage.fileAccess ? 'file_access' : stage.name;

  void recordTemporaryPipelineOutcome(
    TemporaryPipelineStage stage,
    TemporaryPipelineOutcome outcome, {
    Object? provider,
  }) {
    unawaited(
      _appendAutomatic(
        category: 'player',
        type: 'TemporaryPipelineOutcome',
        frames:
            'stage_${_temporaryStage(stage)}, '
            'provider_${temporaryProvider(provider)}, outcome_${outcome.name}',
      ).catchError((Object _) {}),
    );
  }

  Future<void> recordTemporaryProviderFailure({
    required String requestedService,
    required String requestedProvider,
    required String resultService,
    required String finalized,
    required bool success,
    required bool metadataChecked,
    required bool structured,
    required bool legacy,
    required bool invalidStructured,
    required bool invalidLegacy,
    required bool rejected,
    String? errorType,
    String? reason,
  }) {
    const services = {
      'spotify',
      'tidal',
      'qobuz',
      'deezer',
      'youtube',
      'soundcloud',
    };
    String service(String value) =>
        services.contains(value) ? value : 'unknown';
    final finalState =
        {'true', 'false', 'absent', 'invalid'}.contains(finalized)
        ? finalized
        : 'invalid';
    final frames = [
      'stage_provider_result',
      'error_type_${temporaryErrorType(errorType)}',
      'reason_${temporaryReason(reason)}',
      'requested_${service(requestedService)}',
      'provider_${service(requestedProvider)}',
      'result_${service(resultService)}',
      'success_$success',
      'checked_$metadataChecked',
      'finalized_$finalState',
      'structured_$structured',
      'legacy_$legacy',
      'invalidStructured_$invalidStructured',
      'invalidLegacy_$invalidLegacy',
      'rejected_$rejected',
    ].join(', ');
    return _appendAutomatic(
      category: 'player',
      type: 'TemporaryTrackProviderFailure',
      frames: frames,
    );
  }

  Future<void> record(
    String category, {
    Object? error,
    StackTrace? stack,
    String? tag,
  }) {
    if (_captureSuppressed) return Future.value();
    const categories = {
      'search',
      'download',
      'player',
      'application',
      'flutter',
      'platform',
      'async',
    };
    // A runtime type is accepted only when it is a simple Dart identifier.
    final type = error?.runtimeType.toString() ?? 'Error';
    return _appendAutomatic(
      category: categories.contains(category) ? category : 'application',
      type: RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(type)
          ? type
          : 'Error',
      frames: error is TemporaryPreparationFailure
          ? 'stage_preparation, reason_${temporaryReason(error.reason)}'
          : safeFrames(stack),
      tag: tag == null ? null : safeTag(tag),
    );
  }

  static bool get _captureSuppressed =>
      Zone.current[_notificationZone] == true ||
      Zone.current[_suppressionZone] == true;

  Future<void> _appendAutomatic({
    required String category,
    required String type,
    required String frames,
    String? tag,
  }) {
    if (_captureSuppressed) return Future.value();
    if (_batch.length == maxEntries) {
      final removed = _batch.removeAt(0);
      final generation = int.parse(removed['_generation']!);
      _dropped[generation] = (_dropped[generation] ?? 0) + 1;
    }
    _batch.add({
      'time': DateTime.now().toUtc().toIso8601String(),
      'category': category,
      'type': type,
      'frames': frames,
      if (tag != null) 'tag': tag,
      '_generation': '$_generation',
    });
    if (_scheduledGeneration != _generation) {
      final generation = _generation;
      _scheduledGeneration = generation;
      _pending = _pending.then((_) => _flush(generation)).catchError((
        Object _,
      ) {
        _persistenceFailed = true;
        _notifySafely();
      });
    }
    return _pending;
  }

  static String safeTag(String tag) =>
      const {
        'DownloadQueue': 'download_queue',
        'SearchProvider': 'search_provider',
        'MusicPlayer': 'music_player',
        'NativeDownload': 'native_download',
        'Main': 'startup',
      }[tag] ??
      'other';

  Future<void> recordPreparationFailure({String reason = 'unknown'}) => record(
    'player',
    error: TemporaryPreparationFailure(reason),
    tag: 'MusicPlayer',
  );

  /// Saves only text deliberately submitted by the user, with best-effort redaction.
  Future<void> addNote(String text) {
    final note = sanitizeNote(text);
    if (note.isEmpty) return Future.error(ArgumentError('Empty note'));
    final result = _pending.then((_) async {
      final prefs = await _trustedPreferences();
      final entries = _read(prefs);
      entries.add({
        'time': DateTime.now().toUtc().toIso8601String(),
        'category': 'application',
        'type': 'UserNote',
        'frames': '',
        'note': note,
      });
      if (entries.length > maxEntries) {
        entries.removeRange(0, entries.length - maxEntries);
      }
      try {
        if (!await prefs.setString(key, jsonEncode(entries))) {
          throw StateError('Could not save note');
        }
      } catch (_) {
        await _invalidateCache(prefs);
        rethrow;
      }
      _notifySafely();
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  static String sanitizeNote(String text) {
    var note = text.replaceAll(
      RegExp(r'https?://[^\s]+', caseSensitive: false),
      '[URL]',
    );
    note = note.replaceAll(
      RegExp(r'\b(bearer)\s+[^\s]+', caseSensitive: false),
      'Bearer [redacted]',
    );
    note = note.replaceAll(
      RegExp(
        r'\b(token|password|api[_-]?key|secret)\s*[:=]\s*[^\s,;]+',
        caseSensitive: false,
      ),
      '[redacted]',
    );
    note = note.replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '').trim();
    return note.characters.take(maxNoteLength).toString();
  }

  Future<void> _flush(int generation) async {
    try {
      while (_batch.any(
            (row) => int.parse(row['_generation']!) <= generation,
          ) ||
          _dropped.keys.any((key) => key <= generation)) {
        final prefs = await _trustedPreferences();
        final entries = _read(prefs);
        final batch = _batch
            .where((row) => int.parse(row['_generation']!) <= generation)
            .toList();
        final capturedDropped = Map<int, int>.fromEntries(
          _dropped.entries.where((entry) => entry.key <= generation),
        );
        final dropped = capturedDropped.values.fold<int>(
          0,
          (sum, count) => sum + count,
        );
        final writing = Set<Map<String, String>>.identity()..addAll(batch);
        _batch.removeWhere(writing.contains);
        for (final entry in capturedDropped.entries) {
          _dropped.remove(entry.key);
        }
        final displacedBatch = dropped > 0 && batch.length == maxEntries
            ? 1
            : 0;
        entries.addAll(
          batch.map(
            (row) => Map<String, String>.of(row)..remove('_generation'),
          ),
        );
        if (dropped > 0) {
          entries.add({
            'time': DateTime.now().toUtc().toIso8601String(),
            'category': 'application',
            'type': 'DroppedEvents',
            'frames': '',
            'count': '${dropped + displacedBatch}',
          });
        }
        if (entries.length > maxEntries) {
          entries.removeRange(0, entries.length - maxEntries);
        }
        try {
          if (!await prefs.setString(key, jsonEncode(entries))) {
            throw StateError('Could not save bug log');
          }
        } catch (_) {
          // SharedPreferences updates its in-memory cache before the platform
          // confirms the write; reload it before a retry when possible.
          await _invalidateCache(prefs);
          _batch.insertAll(0, batch);
          for (final entry in capturedDropped.entries) {
            _dropped[entry.key] = (_dropped[entry.key] ?? 0) + entry.value;
          }
          while (_batch.length > maxEntries) {
            final removed = _batch.removeAt(0);
            final removedGeneration = int.parse(removed['_generation']!);
            _dropped[removedGeneration] =
                (_dropped[removedGeneration] ?? 0) + 1;
          }
          rethrow;
        }
        _persistenceFailed = false;
        _notifySafely();
      }
    } finally {
      if (_scheduledGeneration == generation) _scheduledGeneration = null;
    }
  }

  void _notifySafely() =>
      runZoned(notifyListeners, zoneValues: {_notificationZone: true});

  /// Only source symbols from this application; never persist frame locations.
  static String safeFrames(StackTrace? stack) {
    if (stack == null) return '';
    final frames = <String>[];
    for (final line in stack.toString().split('\n')) {
      if (!line.contains('package:mornye/')) continue;
      final match = RegExp(
        r'^#\d+\s+([A-Za-z_][A-Za-z0-9_.$<>]{0,100})\s+\(',
      ).firstMatch(line);
      if (match != null) frames.add(match.group(1)!);
      if (frames.length == 3) break;
    }
    return frames.join(', ');
  }

  Future<List<Map<String, String>>> entries() async {
    await _pending;
    return _read(await _trustedPreferences());
  }

  Future<void> clear() {
    // Preserve events recorded after this request, while removing any older
    // events left in memory by a failed flush once storage removal succeeds.
    final generation = _generation++;
    final result = _pending.then((_) async {
      final prefs = await _trustedPreferences();
      try {
        if (!await prefs.remove(key)) {
          throw StateError('Could not clear bug log');
        }
      } catch (_) {
        // The plugin changes its cache before the platform confirms removal.
        await _invalidateCache(prefs);
        rethrow;
      }
      _batch.removeWhere((row) => int.parse(row['_generation']!) <= generation);
      _dropped.removeWhere((key, _) => key <= generation);
      _persistenceFailed = false;
      _notifySafely();
    });
    _pending = result.catchError((Object _) {});
    return result;
  }

  List<Map<String, String>> _read(SharedPreferences prefs) {
    try {
      final decoded = jsonDecode(prefs.getString(key) ?? '[]');
      if (decoded is! List) throw const FormatException('Invalid bug log');
      // Reconstruct a strict schema when reading, too.
      return decoded.whereType<Map<Object?, Object?>>().take(maxEntries).map((
        row,
      ) {
        final time = DateTime.tryParse('${row['time']}');
        const categories = {
          'search',
          'download',
          'player',
          'application',
          'flutter',
          'platform',
          'async',
        };
        final category = '${row['category']}';
        final type = '${row['type']}';
        final frames = '${row['frames'] ?? ''}';
        final count = int.tryParse('${row['count']}');
        if (type == 'TemporaryPipelineOutcome') {
          final fields = RegExp(
            r'^stage_([a-z_]+), provider_([a-z_-]+), outcome_([a-z_]+)$',
          ).firstMatch(frames);
          final stage = fields?.group(1);
          final outcome = fields?.group(3);
          return {
            'time': time?.toUtc().toIso8601String() ?? '',
            'category': 'player',
            'type': type,
            'frames':
                TemporaryPipelineStage.values
                        .map(_temporaryStage)
                        .contains(stage) &&
                    TemporaryPipelineOutcome.values.any(
                      (value) => value.name == outcome,
                    )
                ? 'stage_$stage, provider_${temporaryProvider(fields?.group(2))}, outcome_$outcome'
                : '',
          };
        }
        if (type == 'TerminalDownloadFailure') {
          final fields = RegExp(
            r'^stage_([a-z_]+), error_type_([a-z_]+), cause_([a-z_]+)(?:, provider_([a-z_-]+))?(?:, attempts_([a-z_:;-]+))?$',
          ).firstMatch(frames);
          return {
            'time': time?.toUtc().toIso8601String() ?? '',
            'category': 'download',
            'type': type,
            'frames': _downloadFrames(
              fields?.group(1),
              fields?.group(2),
              fields?.group(3),
              fields?.group(4),
              _attemptsFromStored(fields?.group(5)),
            ),
          };
        }
        return <String, String>{
          'time': time?.toUtc().toIso8601String() ?? '',
          'category': categories.contains(category) ? category : 'application',
          'type': RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,63}$').hasMatch(type)
              ? type
              : 'Error',
          if (type == 'UserNote' && row['note'] is String)
            'note': sanitizeNote(row['note'] as String),
          if (const {
            'download_queue',
            'search_provider',
            'music_player',
            'native_download',
            'startup',
            'other',
          }.contains(row['tag']))
            'tag': row['tag'] as String,
          'frames': RegExp(r'^[A-Za-z0-9_.$<>, ]{0,310}$').hasMatch(frames)
              ? frames
              : '',
          if (row['type'] == 'DroppedEvents' && count != null && count > 0)
            'count': '$count',
        };
      }).toList();
    } catch (_) {
      throw const FormatException('Invalid bug log');
    }
  }
}
