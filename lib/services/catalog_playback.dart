import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:flutter/foundation.dart'
    show ValueNotifier, debugPrint, visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/provider_retry_policy.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_id_resolver.dart';
import 'package:mornye/services/playback_track_enrichment.dart';
import 'package:mornye/services/provider_request_spec.dart';
import 'package:mornye/utils/catalog_search_query.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/playable_audio_format.dart';
import 'package:mornye/utils/streaming_quality_notice.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Safe boundary for failures from providers, storage and temporary preparation.
class CatalogPlaybackException implements Exception {
  const CatalogPlaybackException(this.category);
  final String category;

  @override
  String toString() => 'CatalogPlaybackException: $category';
}

/// Keeps only [a-z_0-9] (lower-cased) and at most 60 characters, so nothing
/// that looks like a path, URL or token can be logged verbatim.
String sanitizeDiagnosticToken(Object? value) {
  final text = (value ?? '').toString().toLowerCase();
  final cleaned = text.replaceAll(RegExp(r'[^a-z0-9_]'), '_');
  return cleaned.length > 60 ? cleaned.substring(0, 60) : cleaned;
}

/// Provider and quality ids are logged only when they already look like a
/// plain identifier; anything else (paths, URLs, free text) becomes `unknown`.
String _safeIdentifier(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{1,40}$').hasMatch(value)
    ? sanitizeDiagnosticToken(value)
    : 'unknown';

/// What was being requested when preparation failed (identifiers only).
class _AcquireDiagnostics {
  String service = '';
  String quality = '';
  String firstQuality = '';
  String chosenService = '';
  bool relayed = false;
  String firstFailureReason = '';
  bool progressive = false;
  void Function(String service, String quality)? onResolved;

  bool get firstFailureUnavailable =>
      firstFailureReason.isEmpty ||
      firstFailureReason == 'provider quality unavailable' ||
      firstFailureReason == 'provider track not found';
}

/// The first preparation of the song that is about to play: what it was asked
/// for and when it began, so the player can show the format being prepared.
class CatalogPreparation {
  const CatalogPreparation({
    required this.key,
    required this.service,
    required this.quality,
    required this.started,
  });

  final String key;
  final String service;
  final String quality;
  final DateTime started;
}

/// Classified, sanitized cause of a preparation failure: exception type,
/// allow-listed reason / platform code / provider attempts, and the request
/// that was made. Free-text messages are never included.
@visibleForTesting
String describeCatalogFailure(
  Object error, {
  String service = '',
  String quality = '',
  bool progressive = false,
}) {
  final fields = <String>[
    'exception=${sanitizeDiagnosticToken(error.runtimeType)}',
  ];
  Object? details;
  if (error is TemporaryTrackException) {
    fields.add('reason=${BugLog.temporaryReason(error.reason)}');
  } else if (error is PlatformException) {
    fields.add('code=${sanitizeDiagnosticToken(error.code)}');
    details = error.details;
  }
  if (details is Map) {
    fields.add(
      'error_type=${BugLog.temporaryErrorType(details['error_type'])}',
    );
    final attempts = BugLog.sanitizeProviderAttempts(
      details['provider_attempts'],
    );
    if (attempts.isNotEmpty) fields.add('attempts=${attempts.join(';')}');
  }
  fields
    ..add('service=${_safeIdentifier(service)}')
    ..add('quality=${_safeIdentifier(quality)}')
    ..add('mode=${progressive ? 'progressive' : 'full_download'}');
  return fields.join(' ');
}

/// Internal marker: the cache missed and no configured audio provider exists.
class _CatalogProviderUnavailable implements Exception {
  const _CatalogProviderUnavailable();
}

const catalogProviderUnavailableCategory = temporaryProviderUnavailableReason;

class CatalogVerificationBlock {
  CatalogVerificationBlock({required this.trackKey, required this.extensionId})
    : created = DateTime.now();

  final String trackKey;
  final String extensionId;
  final DateTime created;
}

const catalogProviderInterventionCategory = 'provider intervention required';

Future<bool> runCatalogVerification({
  required String extensionId,
  required Completer<void> consumerCancellation,
  required Future<void> taskCancellation,
  required Future<bool> Function(String, Future<void>)? verify,
}) async {
  if (verify == null || consumerCancellation.isCompleted) return false;
  final cancellation = Future.any<void>([
    taskCancellation,
    consumerCancellation.future,
  ]);
  return Future.any<bool>([
    verify(extensionId, cancellation),
    cancellation.then((_) => false),
  ]);
}

/// Coordinates publication so concurrent consumers never dispose the same
/// staging directory before the store has finished copying it.
class _PendingPreparation {
  _PendingPreparation(this.future);
  final Future<CatalogAudioLease> future;
  Completer<bool>? retentionDecision;
  int waiters = 0;
}

class _ResolvingPreparation {
  _ResolvingPreparation(this.retain);
  final Future<void> Function() retain;
  final Completer<bool> promotion = Completer<bool>();
}

class CatalogPlayback {
  CatalogPlayback({
    CatalogAudioStore? storage,
    TemporaryTrackPreparer Function(Track)? preparerFactory,
    TemporaryTrackPreparer Function(Track, String, bool)?
    resolvedPreparerFactory,
    TemporaryTrackPreparer Function(
      Track,
      Future<bool> Function(String, Future<void>),
    )?
    preparerFactoryWithVerification,
    Future<bool> Function(Track)? savedLookup,
    Future<void> Function(PreparedTemporaryTrack)? disposePrepared,
  }) : _store = storage == null ? null : Future.value(storage),
       _preparerFactory = preparerFactory,
       _resolvedPreparerFactory = resolvedPreparerFactory,
       _preparerFactoryWithVerification = preparerFactoryWithVerification,
       _savedLookup = savedLookup,
       _disposePrepared = disposePrepared ?? _defaultDisposePrepared;
  static Future<void> _defaultDisposePrepared(
    PreparedTemporaryTrack prepared,
  ) => prepared.dispose();
  final TemporaryTrackPreparer Function(Track)? _preparerFactory;
  final TemporaryTrackPreparer Function(Track, String, bool)?
  _resolvedPreparerFactory;
  final TemporaryTrackPreparer Function(
    Track,
    Future<bool> Function(String, Future<void>),
  )?
  _preparerFactoryWithVerification;
  final Future<bool> Function(Track)? _savedLookup;
  final Future<void> Function(PreparedTemporaryTrack) _disposePrepared;
  late final CatalogCleanupScheduler _scheduler = CatalogCleanupScheduler(
    cleanupExpired,
  );
  Future<CatalogAudioStore>? _store;
  final Map<String, _PendingPreparation> _pending = {};
  final Map<String, _PendingPreparation> _detachedPending = {};
  final Map<String, Set<_ResolvingPreparation>> _resolving = {};
  final Map<String, Future<bool>> _retainedResolutions = {};
  final Map<String, TemporaryTrackPreparer> _preparers = {};
  final Map<TemporaryTrackPreparer, Future<bool>> _preparerDecisions = {};
  final Map<String, int> _generations = {};
  final Map<(String, int), Future<bool>> _cancellationDecisions = {};
  final Map<(String, int), int> _activePreparationCounts = {};
  final Map<String, Completer<void>> _consumerCancellations = {};
  final Map<String, CatalogAudioLease> _selectedVariants = {};
  final Map<String, String> _variantTracks = {};
  final Map<String, String> _qualityOverrides = {};
  final Map<String, String> _serviceOverrides = {};
  final Map<String, ({String service, String quality})> _playingRequests = {};
  final ValueNotifier<CatalogPreparation?> preparation = ValueNotifier(null);
  Future<void>? _stagingRecovery;
  Future<void> _retentionTail = Future.value();

  Future<T> withRetentionLock<T>(Future<T> Function() action) {
    final operation = _retentionTail.then((_) => action());
    _retentionTail = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return operation;
  }

  /// Video tags leave with their song when cleanup retires its temporary
  /// copy. [videoTagKeepAlive] vouches for songs kept elsewhere (downloads).
  TrackVideoTags videoTags = trackVideoTags;
  Future<bool> Function(String key)? videoTagKeepAlive;

  /// Quality asked for this one song only; saved settings are never touched.
  String? qualityOverrideFor(Track track) => _qualityOverrides[key(track)];

  String? serviceOverrideFor(Track track) => _serviceOverrides[key(track)];

  void setQualityOverride(Track track, String? qualityId, {String? service}) {
    final id = key(track);
    final value = qualityId?.trim() ?? '';
    final provider = service?.trim() ?? '';
    _qualityOverrides.remove(id);
    _serviceOverrides.remove(id);
    if (value.isEmpty) return;
    _qualityOverrides[id] = value;
    if (provider.isNotEmpty) _serviceOverrides[id] = provider;
    while (_qualityOverrides.length > 200) {
      final oldest = _qualityOverrides.keys.first;
      _qualityOverrides.remove(oldest);
      _serviceOverrides.remove(oldest);
    }
  }

  /// Provider and quality the last prepared source of [track] was asked for.
  ({String service, String quality})? playingRequest(Track track) =>
      _playingRequests[key(track)];

  ({String service, String quality})? _servedRequest(
    CatalogAudioLease lease,
    _AcquireDiagnostics diag,
  ) {
    if (lease.isTemporary) {
      return (service: diag.service, quality: diag.quality);
    }
    String? plain(Object? value) =>
        value is String && RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(value)
        ? value
        : null;
    final quality = plain(lease.qualityMetadata['resolved_quality']);
    if (quality == null) return null;
    return (
      service: plain(lease.qualityMetadata['provider']) ?? diag.service,
      quality: quality,
    );
  }

  void restorePlayingRequest(
    Track track,
    ({String service, String quality})? previous,
  ) {
    final id = key(track);
    _playingRequests.remove(id);
    if (previous != null) _playingRequests[id] = previous;
  }

  final ValueNotifier<StreamingQualityNotice?> qualityNotice = ValueNotifier(
    null,
  );

  @visibleForTesting
  Future<PrimaryAudioProperties> Function(String path) audioFileFacts =
      FFmpegProbe.audioProperties;

  Future<void> _publishVerifiedNotice(
    CatalogAudioLease lease, {
    required String requestedQuality,
    required bool relayed,
    required bool requestedUnavailable,
    required String chosenService,
    required StreamingQualityNotice fallback,
  }) async {
    var notice = fallback;
    try {
      final facts = await audioFileFacts(
        lease.path,
      ).timeout(const Duration(seconds: 3));
      notice =
          streamingQualityNotice(
            requestedQuality: requestedQuality,
            metadata: lease.qualityMetadata,
            relayed: relayed,
            requestedUnavailable: requestedUnavailable,
            chosenService: chosenService,
            bitDepth: facts.bitDepth,
            sampleRate: facts.sampleRate,
          ) ??
          fallback;
    } on Object {
      notice = fallback;
    }
    qualityNotice.value = notice;
  }

  final ValueNotifier<CatalogVerificationBlock?> verificationBlock =
      ValueNotifier(null);

  String defaultService = '';
  bool providerConfirmed = false;
  String quality = 'LOSSLESS';
  int playbackBitrateKbps = 128;
  bool useExtensions = true;
  bool useFallback = true;
  Future<String> Function(String requested, bool useFallback)?
  resolveDownloadService;
  Future<bool> Function(String, Future<void>)? verifyExtension;

  /// Decides provider and quality for this one playback (saved settings are
  /// never modified). Unset in tests, which then use the fields as they are.
  Future<StreamingRequest> Function(
    String quality,
    String service,
    bool useFallback,
  )?
  resolveStreaming;

  /// Other provider/quality requests to try, in order, when the first one
  /// fails. Unset in tests, which then see a single attempt.
  Future<List<StreamingRequest>> Function(
    StreamingRequest first,
    String quality,
    bool useFallback,
  )?
  streamingAlternatives;

  CatalogIdResolver? idResolver;
  ProviderRetryPolicy? retryPolicy;

  Future<Track> Function(Track track)? trackEnricher;
  Duration enrichmentBudget = const Duration(seconds: 5);
  final Map<String, Track> _enriched = {};
  final Set<String> _simplifiedQuery = {};

  bool _worthSimplifiedRetry(Track track, Object error) =>
      error is TemporaryTrackException &&
      (error.reason == providerFailureReasonFor('not_found') ||
          error.reason == providerFailureReasonFor('provider_unavailable') ||
          error.reason == providerFailureReasonFor('')) &&
      catalogQueryCanBeSimplified(_requestTrack(track));

  Future<CatalogAudioLease> _withSimplifiedRetry(
    Track track,
    Object firstError,
    Duration Function() remaining,
    Future<CatalogAudioLease> Function(Duration budget) run,
  ) async {
    if (!_worthSimplifiedRetry(track, firstError)) throw firstError;
    final left = remaining();
    if (left <= Duration.zero) throw firstError;
    final id = key(track);
    _simplifiedQuery.add(id);
    try {
      _emitDiagnostic('relay retry simplified_query=true');
      return await run(left);
    } finally {
      _simplifiedQuery.remove(id);
    }
  }

  Track _requestTrack(Track track) => _enriched[key(track)] ?? track;

  Future<void> _enrichForRequest(Track track) async {
    final id = key(track);
    final enricher = trackEnricher;
    if (enricher == null ||
        _enriched.containsKey(id) ||
        !playbackTrackNeedsEnrichment(track)) {
      return;
    }
    Track result = track;
    try {
      result = await enricher(track).timeout(enrichmentBudget);
    } catch (_) {
      result = track;
    }
    _enriched.remove(id);
    _enriched[id] = result;
    while (_enriched.length > 200) {
      _enriched.remove(_enriched.keys.first);
    }
  }

  Future<CatalogNativeId?> nativeIdFor(Track track, String serviceId) async {
    final resolver = idResolver;
    if (resolver == null) return null;
    try {
      return await resolver.resolve(
        _requestTrack(track),
        serviceId,
        timeout: idResolutionBudget,
      );
    } catch (_) {
      return null;
    }
  }

  bool providerResting(Track track, String serviceId) {
    if (ProviderCooldown.instance.isCoolingDown(serviceId, trace: true)) {
      return true;
    }
    final block = verificationBlock.value;
    return block != null &&
        block.trackKey == key(track) &&
        block.extensionId.trim().toLowerCase() ==
            serviceId.trim().toLowerCase();
  }

  Duration idResolutionBudget = const Duration(seconds: 6);

  /// Total time one song may spend trying providers, and the part of it given
  /// to the first attempt (a progressive start has no cap of its own).
  Duration relayBudget = const Duration(seconds: 120);
  Duration firstAttemptBudget = const Duration(seconds: 75);
  final Map<String, int> _foregroundWaiters = {};
  final Set<String> _relayedKeys = {};

  /// Whether the last preparation of [track] needed another provider or
  /// format than the one first asked for.
  bool wasRelayed(Track track) => _relayedKeys.contains(key(track));

  /// Sends one sanitized line to the channel the relay already reports on.
  void diagnostic(String line) => _emitDiagnostic(line);
  final Map<String, int> _verifying = {};

  Future<bool> _isSaved(Track track) async {
    if (_savedLookup case final lookup?) return lookup(track);
    final raw = (await SharedPreferences.getInstance()).getString(
      'saved_library_tracks_v1',
    );
    if (raw == null) return false;
    final rows = jsonDecode(raw) as List<dynamic>;
    return rows
        .map((row) => Track.fromJson(Map<String, dynamic>.from(row as Map)))
        .any((item) => trackCollectionKey(item) == trackCollectionKey(track));
  }

  String key(Track track) => trackCollectionKey(track);

  String _variantKey(
    String id,
    int bitrate,
    String sourceQuality,
    String service,
    bool fallback,
  ) => jsonEncode([
    'catalog-audio-v5',
    id,
    bitrate,
    sourceQuality,
    service,
    fallback,
  ]);

  Future<CatalogAudioLease?> _verifiedVariant(
    CatalogAudioStore storage,
    String variant,
    String service,
  ) async {
    return storage.acquire(variant, requiredProvider: service);
  }

  List<String> _legacyVariants(String id) => [
    id,
    ...[
      96,
      128,
      192,
      256,
    ].map((bitrate) => jsonEncode(['catalog-aac-v1', id, bitrate])),
  ];

  void selectLease(Track track, CatalogAudioLease lease) {
    _selectedVariants[key(track)] = lease;
    _noteListened(key(track));
  }

  static const retainedPlayedTracks = 3;
  static const retainedPrefetchedTracks = 3;

  /// Songs kept ready ahead of the current one; their copies are never
  /// evicted for the sake of older ones.
  int prefetchRetention = retainedPrefetchedTracks;
  static const retainedBackgroundPreparations = 3;
  static const temporaryBudgetBytes = 400 * 1024 * 1024;
  final List<String> _listened = [];
  final List<String> _prefetched = [];
  final Set<String> _retainedBackground = {};
  final Set<String> _prefetching = {};

  void _retentionLog(String line) {
    debugPrint(line);
    _failureLog.i(line);
  }

  void _noteListened(String id) {
    _listened.remove(id);
    _listened.add(id);
    while (_listened.length > retainedPlayedTracks + 1) {
      _listened.removeAt(0);
    }
  }

  Set<String> get _protectedTracks => {
    ..._listened,
    ..._prefetched,
    ..._variantTracks.values,
  };

  Future<int> enforceTemporaryBudget({int? maxBytes}) async {
    try {
      final evicted = await (await store).enforceTemporaryBudget(
        maxBytes: maxBytes ?? temporaryBudgetBytes,
        protectedTracks: _protectedTracks,
        trace: _retentionLog,
      );
      return evicted;
    } catch (_) {
      return 0;
    }
  }

  Future<CatalogAudioStore> get store => _store ??= () async {
    final root = await getApplicationSupportDirectory();
    final result = CatalogAudioStore(
      cacheDirectory: Directory(
        p.join(root.path, 'catalog_audio', 'temporary'),
      ),
      libraryDirectory: Directory(
        p.join(root.path, 'catalog_audio', 'library'),
      ),
    );
    await result.initialize();
    return result;
  }();

  /// Receives one sanitized line describing why a preparation failed.
  void Function(String line)? failureDiagnostic;
  static final _failureLog = AppLogger('CatalogPlayback');

  Future<CatalogAudioLease> acquire(
    Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
    bool initial = false,
    bool relay = true,
    bool engineFallback = true,
    bool background = false,
    StreamingRequest? forced,
    CatalogNativeId? nativeId,
  }) async {
    final id0 = key(track);
    if (background) {
      _prefetching.add(id0);
    } else {
      _promoteToForeground(id0);
    }
    if (relay) _foregroundWaiters[id0] = (_foregroundWaiters[id0] ?? 0) + 1;
    try {
      return await _acquireTracked(
        track,
        experimentalTransfer: experimentalTransfer,
        cancelExperimentalTransfer: cancelExperimentalTransfer,
        initial: initial,
        relay: relay,
        engineFallback: engineFallback,
        forced: forced,
        nativeId: nativeId,
      );
    } finally {
      if (relay) {
        final left = (_foregroundWaiters[id0] ?? 1) - 1;
        if (left <= 0) {
          _foregroundWaiters.remove(id0);
        } else {
          _foregroundWaiters[id0] = left;
        }
      }
    }
  }

  Future<CatalogAudioLease> _acquireTracked(
    Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
    required bool initial,
    required bool relay,
    required bool engineFallback,
    StreamingRequest? forced,
    CatalogNativeId? nativeId,
  }) async {
    final diag = _AcquireDiagnostics()
      ..progressive = experimentalTransfer != null;
    CatalogPreparation? published;
    if (initial) {
      final id = key(track);
      final started = DateTime.now();
      published = CatalogPreparation(
        key: id,
        service: _serviceOverrides[id] ?? defaultService,
        quality: _qualityOverrides[id] ?? quality,
        started: started,
      );
      preparation.value = published;
      diag.onResolved = (service, resolvedQuality) {
        if (!identical(preparation.value, published)) return;
        final next = CatalogPreparation(
          key: id,
          service: service,
          quality: resolvedQuality,
          started: started,
        );
        published = next;
        preparation.value = next;
      };
    }
    try {
      await _enrichForRequest(track);
      final lease = await _acquireRelaying(
        track,
        experimentalTransfer: experimentalTransfer,
        cancelExperimentalTransfer: cancelExperimentalTransfer,
        diag: diag,
        relayAllowed: relay,
        engineFallbackAllowed: engineFallback,
        forced: forced,
        nativeId: nativeId,
      );
      if (diag.quality.isNotEmpty) {
        SpecialQualityAvailability.instance.recordPlayback(
          track: track,
          requestedService: diag.chosenService.isEmpty
              ? diag.service
              : diag.chosenService,
          requestedQuality: diag.firstQuality.isEmpty
              ? diag.quality
              : diag.firstQuality,
          metadata: lease.qualityMetadata,
          failureWasUnavailability:
              !diag.relayed || diag.firstFailureUnavailable,
        );
        final id = key(track);
        _relayedKeys.remove(id);
        if (diag.relayed) {
          _relayedKeys.add(id);
          while (_relayedKeys.length > 200) {
            _relayedKeys.remove(_relayedKeys.first);
          }
        }
        if (initial || _qualityOverrides.containsKey(id)) {
          final requestedQuality = diag.firstQuality.isEmpty
              ? diag.quality
              : diag.firstQuality;
          final notice = streamingQualityNotice(
            requestedQuality: requestedQuality,
            metadata: lease.qualityMetadata,
            relayed: diag.relayed,
            requestedUnavailable: diag.firstFailureUnavailable,
            chosenService: diag.chosenService,
          );
          if (notice != null && notice.needsFileFacts) {
            unawaited(
              _publishVerifiedNotice(
                lease,
                requestedQuality: requestedQuality,
                relayed: diag.relayed,
                requestedUnavailable: diag.firstFailureUnavailable,
                chosenService: diag.chosenService,
                fallback: notice,
              ),
            );
          } else if (notice != null) {
            qualityNotice.value = notice;
          }
        }
        _playingRequests.remove(id);
        final served = _servedRequest(lease, diag);
        if (served != null) _playingRequests[id] = served;
        while (_playingRequests.length > 200) {
          _playingRequests.remove(_playingRequests.keys.first);
        }
      }
      if (verificationBlock.value?.trackKey == key(track)) {
        verificationBlock.value = null;
      }
      return lease;
    } catch (error) {
      if (error is TemporaryVerificationRequired) {
        verificationBlock.value = CatalogVerificationBlock(
          trackKey: key(track),
          extensionId: error.extensionId,
        );
      }
      // Never propagate provider output, paths or credentials to playback logs.
      final category = error is _CatalogProviderUnavailable
          ? catalogProviderUnavailableCategory
          : error is TemporaryTrackException &&
                isKnownFailureReason(error.reason)
          ? error.reason
          : failureReasonGeneric;
      try {
        final line =
            'preparation failed category=${sanitizeDiagnosticToken(category)} '
            '${describeCatalogFailure(error, service: diag.service, quality: diag.quality, progressive: diag.progressive)}';
        (failureDiagnostic ?? _failureLog.w)(line);
      } catch (_) {
        // Diagnostics must never change the playback result.
      }
      throw CatalogPlaybackException(category);
    } finally {
      if (initial && identical(preparation.value, published)) {
        preparation.value = null;
      }
    }
  }

  void _emitDiagnostic(String line) {
    try {
      (failureDiagnostic ?? _failureLog.w)(line);
    } catch (_) {
      // Diagnostics must never change the playback result.
    }
  }

  String _failureReasonOf(Object error) =>
      error is TemporaryTrackException && isKnownFailureReason(error.reason)
      ? error.reason
      : failureReasonGeneric;

  void _logRelayFailure(
    int attempt,
    int total,
    Object error,
    String service,
    String quality,
    _AcquireDiagnostics diag,
  ) {
    _emitDiagnostic(
      'relay attempt failed attempt=$attempt/$total '
      'category=${sanitizeDiagnosticToken(_failureReasonOf(error))} '
      '${describeCatalogFailure(error, service: service, quality: quality, progressive: diag.progressive && attempt == 1)}',
    );
  }

  bool _relayable(Object error) =>
      error is TemporaryTrackException &&
      error.reason != failureReasonCancelled &&
      error.reason != 'verification timed out';

  Future<CatalogAudioLease> _attempt(
    Track track,
    Duration? budget,
    Future<CatalogAudioLease> Function() run,
  ) async {
    final future = run();
    if (budget == null) return future;
    final id = key(track);
    var wait = budget;
    while (true) {
      try {
        return await future.timeout(wait);
      } on TimeoutException {
        if ((_verifying[id] ?? 0) > 0) {
          wait = const Duration(seconds: 1);
          continue;
        }
        unawaited(
          future.then<void>((late) => late.release(), onError: (Object _) {}),
        );
        if ((_foregroundWaiters[id] ?? 0) <= 1) await cancel(track);
        throw const TemporaryTrackException('provider timed out');
      }
    }
  }

  Future<CatalogAudioLease> _acquireRelaying(
    Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
    required _AcquireDiagnostics diag,
    bool relayAllowed = true,
    bool engineFallbackAllowed = true,
    StreamingRequest? forced,
    CatalogNativeId? nativeId,
  }) async {
    final alternatives = streamingAlternatives;
    final relay = relayAllowed && alternatives != null && useFallback;
    final started = DateTime.now();
    Object lastError;
    TemporaryVerificationRequired? blocked;
    ({String service, String quality, Object error})? failedFirst;
    Future<CatalogAudioLease> firstAttempt(Duration? budget) => _attempt(
      track,
      budget,
      () => _acquire(
        track,
        experimentalTransfer: experimentalTransfer,
        cancelExperimentalTransfer: cancelExperimentalTransfer,
        diag: diag,
        forced: forced,
        nativeId: nativeId,
        userRequested: forced != null,
        engineFallback: engineFallbackAllowed && !relay,
      ),
    );
    try {
      return await firstAttempt(
        relay && experimentalTransfer == null ? firstAttemptBudget : null,
      );
    } catch (error) {
      if (!relay || !_relayable(error)) rethrow;
      lastError = error;
      diag.firstFailureReason = _failureReasonOf(error);
      failedFirst = (
        service: diag.service,
        quality: diag.quality,
        error: error,
      );
      if (error is TemporaryVerificationRequired) blocked = error;
      if (experimentalTransfer == null &&
          nativeId == null &&
          forced == null &&
          error is! TemporaryVerificationRequired) {
        try {
          return await _withSimplifiedRetry(track, error, () {
            final left = relayBudget - DateTime.now().difference(started);
            return left < firstAttemptBudget ? left : firstAttemptBudget;
          }, firstAttempt);
        } catch (retryError) {
          if (!_relayable(retryError)) rethrow;
          lastError = retryError;
        }
      }
    }
    final id = key(track);
    var generation = _generations[id] ?? 0;
    var candidates = const <StreamingRequest>[];
    try {
      candidates = await alternatives(
        StreamingRequest(diag.service, diag.quality),
        quality,
        useFallback,
      );
    } catch (_) {
      candidates = const [];
    }
    var attempts = 1;
    final total = candidates.length + 1;
    _logRelayFailure(
      1,
      total,
      failedFirst.error,
      failedFirst.service,
      failedFirst.quality,
      diag,
    );
    var skipped = 0;
    for (final candidate in candidates) {
      if (blocked != null && candidate.serviceId == blocked.extensionId) {
        continue;
      }
      if (ProviderCooldown.instance.isCoolingDown(
        candidate.serviceId,
        trace: true,
      )) {
        skipped++;
        continue;
      }
      final remaining = relayBudget - DateTime.now().difference(started);
      if (remaining <= Duration.zero) break;
      if ((_generations[id] ?? 0) != generation) {
        throw StateError('Preparación cancelada');
      }
      attempts++;
      CatalogNativeId? native;
      final resolver = idResolver;
      if (resolver != null) {
        try {
          native = await resolver.resolve(
            _requestTrack(track),
            candidate.serviceId,
            timeout: remaining < idResolutionBudget
                ? remaining
                : idResolutionBudget,
          );
        } catch (_) {
          native = null;
        }
        if ((_generations[id] ?? 0) != generation) {
          throw StateError('Preparación cancelada');
        }
      }
      final left = relayBudget - DateTime.now().difference(started);
      if (left <= Duration.zero) break;
      Future<CatalogAudioLease> candidateAttempt(Duration budget) => _attempt(
        track,
        budget,
        () => _acquire(track, diag: diag, forced: candidate, nativeId: native),
      );
      try {
        CatalogAudioLease won;
        try {
          won = await candidateAttempt(left);
        } catch (firstError) {
          if (!_relayable(firstError) ||
              native != null ||
              firstError is TemporaryVerificationRequired) {
            rethrow;
          }
          won = await _withSimplifiedRetry(
            track,
            firstError,
            () => relayBudget - DateTime.now().difference(started),
            candidateAttempt,
          );
        }
        diag.relayed = true;
        _emitDiagnostic(
          'relay succeeded attempt=$attempts/$total '
          'service=${_safeIdentifier(diag.service)} '
          'quality=${_safeIdentifier(diag.quality)}',
        );
        return won;
      } catch (error) {
        if (!_relayable(error)) rethrow;
        if (native != null &&
            error is TemporaryTrackException &&
            error.reason == providerFailureReasonFor('not_found')) {
          unawaited(
            resolver?.invalidate(track, candidate.serviceId) ?? Future.value(),
          );
        }
        _logRelayFailure(
          attempts,
          total,
          error,
          diag.service,
          diag.quality,
          diag,
        );
        lastError = error;
        if (error is TemporaryVerificationRequired) blocked ??= error;
        generation = _generations[id] ?? 0;
      }
    }
    if (blocked != null) throw blocked;
    if (attempts > 1 || skipped > 0) {
      throw const TemporaryTrackException(failureReasonProvidersExhausted);
    }
    throw lastError;
  }

  /// Prepares [track] ahead of playback. The temporary copy stays in the store
  /// under the usual retention rules, so the later [acquire] of the same song
  /// finds it already published and returns at once.
  Future<void> prefetch(Track track) async {
    final id = key(track);
    _prefetched.remove(id);
    _prefetched.add(id);
    final keep = prefetchRetention > retainedPrefetchedTracks
        ? prefetchRetention
        : retainedPrefetchedTracks;
    while (_prefetched.length > keep) {
      _prefetched.removeAt(0);
    }
    try {
      final lease = await acquire(
        track,
        relay: false,
        engineFallback: false,
        background: true,
      );
      await lease.release();
    } finally {
      _prefetching.remove(id);
    }
  }

  void _promoteToForeground(String id) {
    if (!_prefetching.remove(id)) return;
    for (final entry in _variantTracks.entries) {
      if (entry.value == id) _preparers[entry.key]?.promote(entry.key);
    }
  }

  /// Whether [track] already has a permanent copy, so nothing needs preparing.
  Future<bool> hasLocalCopy(Track track) async {
    try {
      if (await _isSaved(track)) return true;
      return (await (await store).lookup(key(track)))?.persistent == true;
    } catch (_) {
      return true;
    }
  }

  Future<CatalogAudioLease> _acquire(
    Track track, {
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
    _AcquireDiagnostics? diag,
    StreamingRequest? forced,
    CatalogNativeId? nativeId,
    bool engineFallback = true,
    bool userRequested = false,
  }) async {
    final id = key(track);
    final bitrate = playbackBitrateKbps;
    var sourceQuality = _qualityOverrides[id] ?? quality;
    var requestedService = _serviceOverrides[id] ?? defaultService;
    if (diag != null && diag.chosenService.isEmpty) {
      diag.chosenService = requestedService;
    }
    final extensions = useExtensions;
    final fallback = useFallback;
    if (forced != null) {
      sourceQuality = forced.qualityId;
      requestedService = forced.serviceId;
    } else if (resolveStreaming case final streaming?) {
      try {
        final request = await streaming(
          sourceQuality,
          requestedService,
          fallback,
        );
        sourceQuality = request.qualityId;
        requestedService = request.serviceId;
      } catch (_) {
        // Keep the saved choice if providers cannot be inspected.
      }
    }
    diag
      ?..service = requestedService
      ..quality = sourceQuality;
    if (diag != null && diag.firstQuality.isEmpty) {
      diag.firstQuality = sourceQuality;
    }
    diag?.onResolved?.call(requestedService, sourceQuality);
    final resolver = resolveDownloadService;
    final generation = _generations[id] ?? 0;
    final consumerCancellation = _consumerCancellations.putIfAbsent(
      id,
      Completer<void>.new,
    );
    final storage = await store;
    if ((_generations[id] ?? 0) != generation) {
      throw StateError('Preparación cancelada');
    }
    var saved = false;
    var lease = await withRetentionLock(() async {
      saved = await _isSaved(track);
      if (saved) {
        await promote(track, requireSaved: true);
      }
      final stable = await storage.lookup(id);
      if (stable?.persistent == true) {
        return storage.acquire(id);
      }
      return null;
    });
    if ((_generations[id] ?? 0) != generation) {
      await lease?.release();
      throw StateError('Preparación cancelada');
    }
    if (lease != null) return lease;
    final usePlatform =
        _preparerFactory == null && _preparerFactoryWithVerification == null;
    final String service;
    _ResolvingPreparation? resolvingState;
    if (usePlatform) {
      if (resolver == null)
        throw StateError('El proveedor de descarga no está inicializado');
      final resolvingFuture = resolver(requestedService, fallback);
      late final _ResolvingPreparation resolving;
      resolving = _ResolvingPreparation(() async {
        try {
          final retainedService = await resolvingFuture;
          if (retainedService.trim().isEmpty)
            throw const _CatalogProviderUnavailable();
          try {
            if (!await _isSaved(track)) {
              if (!resolving.promotion.isCompleted) {
                resolving.promotion.complete(false);
              }
              return;
            }
          } catch (_) {
            // Preserve a committed save when its references cannot be read.
          }
          final variant = _variantKey(
            id,
            bitrate,
            sourceQuality,
            retainedService,
            fallback,
          );
          final work = _retainedResolutions.putIfAbsent(variant, () async {
            final existing = _pending[variant] ?? _detachedPending[variant];
            if (existing != null) {
              existing.waiters++;
              CatalogAudioLease? guard;
              try {
                guard = await existing.future;
                return (await storage.lookup(id))?.persistent == true;
              } finally {
                existing.waiters--;
                if (existing.waiters == 0 && guard != null) {
                  if (identical(_pending[variant], existing))
                    _pending.remove(variant);
                  if (identical(_detachedPending[variant], existing))
                    _detachedPending.remove(variant);
                  if (!_pending.containsKey(variant) &&
                      !_detachedPending.containsKey(variant))
                    _variantTracks.remove(variant);
                  await guard.release();
                }
              }
            }
            final guard = await _prepare(
              track,
              id,
              variant,
              storage,
              generation,
              bitrate,
              sourceQuality,
              retainedService,
              extensions,
              fallback,
              forcedCandidate: forced != null || !engineFallback,
              nativeId: forced != null ? nativeId : null,
              manual:
                  (forced == null || userRequested) &&
                  !_prefetching.contains(id),
            );
            await guard.release();
            return (await storage.lookup(id))?.persistent == true;
          });
          try {
            final result = await work;
            if (!resolving.promotion.isCompleted)
              resolving.promotion.complete(result);
          } finally {
            if (identical(_retainedResolutions[variant], work))
              _retainedResolutions.remove(variant);
          }
        } catch (_) {
          if (!resolving.promotion.isCompleted)
            resolving.promotion.complete(false);
        }
      });
      (_resolving[id] ??= {}).add(resolving);
      resolvingState = resolving;
      try {
        service = await Future.any<String>([
          resolvingFuture,
          consumerCancellation.future.then<String>(
            (_) => throw StateError('Preparación cancelada'),
          ),
        ]);
      } catch (_) {
        if ((_generations[id] ?? 0) == generation) {
          _resolving[id]?.remove(resolving);
          if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
          if (!resolving.promotion.isCompleted)
            resolving.promotion.complete(false);
        }
        rethrow;
      }
      if ((_generations[id] ?? 0) != generation)
        throw StateError('Preparación cancelada');
      if (service.trim().isEmpty) {
        _resolving[id]?.remove(resolving);
        if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
        if (!resolving.promotion.isCompleted)
          resolving.promotion.complete(false);
        // An exact-provider cache hit is safe even when that provider is now
        // unavailable; never guess a previously selected fallback provider.
        if (requestedService.trim().isNotEmpty) {
          final cached = await _verifiedVariant(
            storage,
            _variantKey(id, bitrate, sourceQuality, requestedService, fallback),
            requestedService,
          );
          if ((_generations[id] ?? 0) != generation) {
            await cached?.release();
            throw StateError('Preparación cancelada');
          }
          if (cached != null) return cached;
        }
        throw const _CatalogProviderUnavailable();
      }
    } else {
      service = requestedService;
    }
    diag?.service = service;
    final variant = _variantKey(id, bitrate, sourceQuality, service, fallback);
    lease = await _verifiedVariant(storage, variant, service);
    if ((_generations[id] ?? 0) != generation) {
      await lease?.release();
      throw StateError('Preparación cancelada');
    }
    if (lease != null) {
      _retentionLog('retention: hit source=cache initial=${diag != null}');
      if (resolvingState != null) {
        _resolving[id]?.remove(resolvingState);
        if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
        if (!resolvingState.promotion.isCompleted)
          resolvingState.promotion.complete(false);
      }
      return lease;
    }
    final retained = _retainedResolutions[variant];
    if (retained != null) {
      try {
        await Future.any<void>([
          retained.then<void>((_) {}),
          consumerCancellation.future.then<void>(
            (_) => throw StateError('Preparación cancelada'),
          ),
        ]);
      } catch (_) {
        if ((_generations[id] ?? 0) == generation && resolvingState != null) {
          _resolving[id]?.remove(resolvingState);
          if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
          if (!resolvingState.promotion.isCompleted)
            resolvingState.promotion.complete(false);
        }
        rethrow;
      }
      if ((_generations[id] ?? 0) != generation)
        throw StateError('Preparación cancelada');
      lease = (await storage.lookup(id))?.persistent == true
          ? await storage.acquire(id)
          : await _verifiedVariant(storage, variant, service);
      if ((_generations[id] ?? 0) != generation) {
        await lease?.release();
        throw StateError('Preparación cancelada');
      }
      if (lease != null) {
        if (resolvingState != null) {
          _resolving[id]?.remove(resolvingState);
          if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
          if (!resolvingState.promotion.isCompleted)
            resolvingState.promotion.complete(
              (await storage.lookup(id))?.persistent == true,
            );
        }
        return lease;
      }
    }
    final detached = saved || _retainedBackground.contains(id)
        ? _detachedPending[variant]
        : null;
    if (detached == null && _pending[variant] == null) {
      _retentionLog('retention: miss preparing');
    }
    final retainDetached =
        detached != null &&
        await (detached.retentionDecision?.future ?? Future.value(false));
    if ((_generations[id] ?? 0) != generation) {
      throw StateError('Preparación cancelada');
    }
    if (retainDetached &&
        !_pending.containsKey(variant) &&
        identical(_detachedPending[variant], detached)) {
      _pending[variant] = detached;
      _detachedPending.remove(variant);
    }
    final pending =
        _pending[variant] ??
        (retainDetached ? detached : null) ??
        _pending.putIfAbsent(variant, () {
          _variantTracks[variant] = id;
          final generationKey = (id, generation);
          _activePreparationCounts[generationKey] =
              (_activePreparationCounts[generationKey] ?? 0) + 1;
          final future = _prepare(
            track,
            id,
            variant,
            storage,
            generation,
            bitrate,
            sourceQuality,
            service,
            extensions,
            fallback,
            forcedCandidate: forced != null || !engineFallback,
            nativeId: forced != null ? nativeId : null,
            manual:
                (forced == null || userRequested) && !_prefetching.contains(id),
            experimentalTransfer: experimentalTransfer,
            cancelExperimentalTransfer: cancelExperimentalTransfer,
          );
          void finished() {
            final remaining =
                (_activePreparationCounts[generationKey] ?? 1) - 1;
            if (remaining == 0) {
              _activePreparationCounts.remove(generationKey);
              _cancellationDecisions.remove(generationKey);
            } else {
              _activePreparationCounts[generationKey] = remaining;
            }
          }

          unawaited(
            future.then<void>(
              (_) => finished(),
              onError: (Object _, StackTrace stack) => finished(),
            ),
          );
          return _PendingPreparation(future);
        });
    final resolving = resolvingState;
    if (resolving != null) {
      _resolving[id]?.remove(resolving);
      if (_resolving[id]?.isEmpty == true) _resolving.remove(id);
      unawaited(
        pending.future.then<void>(
          (_) async {
            try {
              final saved = (await storage.lookup(id))?.persistent == true;
              if (!resolving.promotion.isCompleted)
                resolving.promotion.complete(saved);
            } catch (_) {
              if (!resolving.promotion.isCompleted)
                resolving.promotion.complete(false);
            }
          },
          onError: (Object _, StackTrace __) {
            if (!resolving.promotion.isCompleted)
              resolving.promotion.complete(false);
          },
        ),
      );
    }
    pending.waiters++;
    CatalogAudioLease? guard;
    try {
      guard = await Future.any<CatalogAudioLease>([
        pending.future,
        consumerCancellation.future.then<CatalogAudioLease>(
          (_) => throw StateError('Preparación cancelada'),
        ),
      ]);
      if ((_generations[id] ?? 0) != generation) {
        throw StateError('Preparación cancelada');
      }
      lease = await storage.acquire(variant);
      lease ??= await storage.acquire(id);
      if ((_generations[id] ?? 0) != generation) {
        await lease?.release();
        throw StateError('Preparación cancelada');
      }
      if (lease == null)
        throw StateError('El audio temporal no está disponible');
      return lease;
    } finally {
      pending.waiters--;
      if (pending.waiters == 0) {
        Future<void> releaseGuard(CatalogAudioLease published) async {
          if (pending.waiters != 0) return;
          if (identical(_pending[variant], pending)) _pending.remove(variant);
          if (identical(_detachedPending[variant], pending))
            _detachedPending.remove(variant);
          if (!_pending.containsKey(variant)) _variantTracks.remove(variant);
          await published.release();
        }

        if (guard != null) {
          await releaseGuard(guard);
        } else {
          unawaited(
            pending.future.then(
              releaseGuard,
              onError: (Object _, StackTrace __) {
                if (pending.waiters == 0 &&
                    identical(_pending[variant], pending)) {
                  _pending.remove(variant);
                  _variantTracks.remove(variant);
                }
                if (identical(_detachedPending[variant], pending))
                  _detachedPending.remove(variant);
                if (!_pending.containsKey(variant) &&
                    !_detachedPending.containsKey(variant)) {
                  _variantTracks.remove(variant);
                }
              },
            ),
          );
        }
      }
    }
  }

  Future<bool> _preparationCancelled(
    Track track,
    String id,
    int generation, [
    TemporaryTrackPreparer? preparer,
  ]) async {
    if (preparer != null) {
      while (true) {
        final currentDecision = _preparerDecisions[preparer];
        if (currentDecision != null && !await currentDecision) return true;
        if (identical(currentDecision, _preparerDecisions[preparer])) break;
      }
    }
    if ((_generations[id] ?? 0) == generation) return false;
    final decision = _cancellationDecisions[(id, generation)];
    if (decision != null) return !await decision;
    try {
      return !await _isSaved(track);
    } catch (_) {
      return false;
    }
  }

  Future<CatalogAudioLease> _prepare(
    Track track,
    String id,
    String variant,
    CatalogAudioStore storage,
    int generation,
    int bitrate,
    String sourceQuality,
    String service,
    bool extensions,
    bool fallback, {
    bool forcedCandidate = false,
    bool manual = true,
    CatalogNativeId? nativeId,
    Future<Map<String, dynamic>> Function(DownloadRequestPayload)?
    experimentalTransfer,
    Future<void> Function(String)? cancelExperimentalTransfer,
  }) async {
    if (service.trim().isNotEmpty &&
        ProviderCooldown.instance.isCoolingDown(service, trace: true)) {
      throw TemporaryTrackException(providerFailureReasonFor('rate_limited'));
    }
    final policy = retryPolicy;
    if (policy != null && service.trim().isNotEmpty) {
      final qualityKey = sourceQuality.trim().isEmpty
          ? 'default'
          : sourceQuality;
      if (policy.blockedFor(service, id, manual: manual, quality: qualityKey) >
          Duration.zero) {
        throw TemporaryTrackException(providerFailureReasonFor('rate_limited'));
      }
      policy.recordAttempt(service, id);
      await policy.spaceRequest(service);
    }
    final usePlatform =
        _preparerFactory == null && _preparerFactoryWithVerification == null;
    final root = usePlatform && _resolvedPreparerFactory == null
        ? await getApplicationSupportDirectory()
        : null;
    if (await _preparationCancelled(track, id, generation)) {
      throw StateError('Preparación cancelada');
    }
    if (await _preparationCancelled(track, id, generation)) {
      throw StateError('Preparación cancelada');
    }
    late final TemporaryTrackPreparer preparer;
    Future<bool> verifyForActiveConsumer(
      String extensionId,
      Future<void> taskCancellation,
    ) {
      final active = _pending[variant];
      final consumer = _consumerCancellations[id];
      if (active == null ||
          active.waiters == 0 ||
          consumer == null ||
          !identical(_preparers[variant], preparer)) {
        return Future.value(false);
      }
      _verifying[id] = (_verifying[id] ?? 0) + 1;
      return runCatalogVerification(
        extensionId: extensionId,
        consumerCancellation: consumer,
        taskCancellation: taskCancellation,
        verify: verifyExtension,
      ).whenComplete(() {
        final left = (_verifying[id] ?? 1) - 1;
        if (left <= 0) {
          _verifying.remove(id);
        } else {
          _verifying[id] = left;
        }
      });
    }

    preparer =
        _preparerFactoryWithVerification?.call(
          track,
          verifyForActiveConsumer,
        ) ??
        _preparerFactory?.call(track) ??
        _resolvedPreparerFactory?.call(
          track,
          service,
          fallback && !forcedCandidate,
        ) ??
        TemporaryTrackPreparer.platform(
          verify: verifyForActiveConsumer,
          bitrateKbps: bitrate,
          transfer: experimentalTransfer,
          cancelTransfer: cancelExperimentalTransfer,
          stagingRoot: Directory(
            p.join(root!.path, 'catalog_audio', 'staging'),
          ),
          payload: (dir, transferId) => buildCatalogDownloadPayload(
            track: _requestTrack(track),
            directory: dir,
            transferId: transferId,
            service: service,
            quality: sourceQuality,
            useExtensions: extensions,
            useFallback: fallback && !forcedCandidate,
            nativeId: nativeId,
            simplifiedQuery: _simplifiedQuery.contains(id),
          ),
        );
    _preparers[variant] = preparer;
    _variantTracks[variant] = id;
    try {
      await (_stagingRecovery ??= preparer.recoverAbandoned());
      if (await _preparationCancelled(track, id, generation, preparer)) {
        throw StateError('Preparación cancelada');
      }
      final PreparedTemporaryTrack prepared;
      try {
        prepared = await preparer.prepare(
          variant,
          priority: _prefetching.contains(id)
              ? ProviderRequestPriority.prefetch
              : ProviderRequestPriority.foreground,
        );
      } catch (error) {
        if (policy != null &&
            service.trim().isNotEmpty &&
            !(error is TemporaryTrackException &&
                error.reason == failureReasonCancelled)) {
          policy.recordFailure(
            service,
            id,
            quality:
                error is TemporaryTrackException &&
                    formatFailureReasons.contains(error.reason)
                ? (sourceQuality.trim().isEmpty ? 'default' : sourceQuality)
                : null,
          );
        }
        rethrow;
      }
      if (service.trim().isNotEmpty) policy?.recordSuccess(service, id);
      CatalogAudioLease? publishedGuard;
      try {
        final metadata = prepared.qualityMetadata;
        final extension = playableAudioExtension(
          metadata['output_codec']?.toString(),
          metadata['output_container']?.toString(),
        );
        if (metadata['output_decode_validated'] != true ||
            extension == null ||
            p.extension(prepared.file.path) != extension) {
          throw const TemporaryTrackException('invalid provider output');
        }
        if (await _preparationCancelled(track, id, generation, preparer)) {
          throw StateError('Preparación cancelada');
        }
        publishedGuard = await withRetentionLock(() async {
          if (await _preparationCancelled(track, id, generation, preparer)) {
            throw StateError('Preparación cancelada');
          }
          await storage.putTemporary(
            variant,
            prepared.file,
            extension: extension,
            qualityMetadata: prepared.qualityMetadata,
          );
          if (await _preparationCancelled(track, id, generation, preparer)) {
            throw StateError('Preparación cancelada');
          }
          // Temporary playback quality is not proof of the configured download.
          final guard = await storage.acquire(variant);
          if (guard == null)
            throw StateError('El audio temporal no está disponible');
          if (await _preparationCancelled(track, id, generation, preparer)) {
            await guard.release();
            throw StateError('Preparación cancelada');
          }
          return guard;
        });
        unawaited(enforceTemporaryBudget());
        return publishedGuard!;
      } finally {
        try {
          await _disposePrepared(prepared);
        } catch (_) {
          // The caller never receives the guard if staging cleanup fails.
          await publishedGuard?.release();
          rethrow;
        }
      }
    } finally {
      if (identical(_preparers[variant], preparer)) _preparers.remove(variant);
      _preparerDecisions.remove(preparer);
    }
  }

  Future<void> cancel(Track track, {bool retain = false}) async {
    final id = key(track);
    final generation = _generations[id] ?? 0;
    final retentionDecision = Completer<bool>();
    final resolving = _resolving.remove(id) ?? {};
    if ((_activePreparationCounts[(id, generation)] ?? 0) > 0 ||
        resolving.isNotEmpty) {
      _cancellationDecisions[(id, generation)] = retentionDecision.future;
    }
    _generations[id] = generation + 1;
    final cancellation = _consumerCancellations.remove(id);
    if (cancellation != null && !cancellation.isCompleted)
      cancellation.complete();
    final variants = _variantTracks.entries
        .where((e) => e.value == id)
        .map((e) => e.key)
        .toList();
    final preparers = {
      for (final variant in variants) variant: _preparers[variant],
    };
    for (final preparer in preparers.values) {
      if (preparer != null)
        _preparerDecisions[preparer] = retentionDecision.future;
    }
    final pending = {
      for (final variant in variants)
        variant: _pending[variant] ?? _detachedPending[variant],
    };
    for (final variant in variants) {
      final previous = pending[variant];
      if (previous != null &&
          (identical(_pending[variant], previous) ||
              identical(_detachedPending[variant], previous))) {
        previous.retentionDecision = retentionDecision;
        _detachedPending[variant] = previous;
        if (identical(_pending[variant], previous)) _pending.remove(variant);
      }
    }
    // A committed save owns its in-flight preparation independently of playback.
    bool saved;
    try {
      saved = await _isSaved(track);
    } catch (_) {
      saved = true; // Preserve work when references cannot be read safely.
    }
    final active = [
      for (final item in pending.values)
        if (item != null) item,
    ];
    final keepInBackground =
        !saved &&
        retain &&
        active.isNotEmpty &&
        (_retainedBackground.contains(id) ||
            _retainedBackground.length < retainedBackgroundPreparations);
    if (keepInBackground) {
      _retainedBackground.add(id);
      _retentionLog('retention: keep background preparation');
      unawaited(
        Future.wait([
          for (final item in active)
            item.future.then<void>((_) {}, onError: (Object _) {}),
        ]).whenComplete(() => _retainedBackground.remove(id)),
      );
    }
    retentionDecision.complete(saved || keepInBackground);
    final retainedResolutions = <Future<void>>[];
    for (final item in resolving) {
      if (saved) {
        retainedResolutions.add(item.retain());
      } else {
        if (!item.promotion.isCompleted) item.promotion.complete(false);
      }
    }
    unawaited(
      Future.wait(retainedResolutions).then((_) {
        if ((_activePreparationCounts[(id, generation)] ?? 0) == 0) {
          _cancellationDecisions.remove((id, generation));
        }
      }),
    );
    if (saved || keepInBackground) return;
    for (final variant in variants) {
      final preparer = preparers[variant];
      if (identical(_preparers[variant], preparer)) _preparers.remove(variant);
      if (identical(_pending[variant], pending[variant]))
        _pending.remove(variant);
      await preparer?.cancel(variant);
    }
  }

  /// Existing permanent audio remains usable. Temporary variants cannot yet be
  /// shown equivalent to the configured download, so do not publish them as
  /// permanent. A normal saved-track download can proceed independently.
  Future<bool> promote(
    Track track, {
    List<String>? knownVariants,
    bool Function()? saveIntention,
    bool requireSaved = false,
  }) async {
    final entry = await (await store).lookup(key(track));
    return entry?.persistent == true;
  }

  /// An in-flight playback preparation cannot prove download equivalence.
  Future<bool>? pendingSavedPromotion(Track track) => null;

  Future<List<Track>> _savedTracks() async {
    final raw = (await SharedPreferences.getInstance()).getString(
      'saved_library_tracks_v1',
    );
    if (raw == null) return const [];
    return (jsonDecode(raw) as List<dynamic>)
        .map((row) => Track.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
  }

  Future<int> _cleanup({required bool all}) => withRetentionLock(() async {
    final saved = await _savedTracks();
    final storage = await store;
    final protectedIds = saved.map(key).toSet();
    final variants = await storage.variantsForTracks(protectedIds);
    for (final track in saved) {
      try {
        await promote(
          track,
          knownVariants: variants[key(track)] ?? [],
          requireSaved: true,
        );
      } on FileSystemException {
        // A full disk must not block cleanup of unrelated temporary audio.
        // The saved temporary copy remains protected for a later retry.
      }
    }
    for (final track in saved) {
      final id = key(track);
      if ((await storage.lookup(id))?.persistent != true) {
        protectedIds.addAll(_legacyVariants(id));
        protectedIds.addAll(variants[id] ?? []);
      }
    }
    final removed = await (all
        ? storage.clearTemporary(protectedIds: protectedIds)
        : storage.cleanupExpired(protectedIds: protectedIds));
    if (!all) await enforceTemporaryBudget();
    try {
      await videoTags.prune((tagKey) async {
        if (protectedIds.contains(tagKey)) return true;
        if (await storage.lookup(tagKey) != null) return true;
        return await videoTagKeepAlive?.call(tagKey) ?? false;
      });
    } catch (_) {
      // Stale tags are harmless; the next cleanup retries.
    }
    return removed;
  });

  Future<int> cleanupExpired() => _cleanup(all: false);
  Future<int> clearTemporary() => _cleanup(all: true);

  void startAutomaticCleanup() => _scheduler.start();
  void stopAutomaticCleanup() => _scheduler.stop();
}

final catalogPlayback = CatalogPlayback();

Future<String> resolveCatalogDownloadService(
  String requested,
  Future<ExtensionState> Function() initializedState, {
  bool autoFallback = true,
}) async {
  final state = await initializedState();
  final usable = state.extensions
      .where((extension) => extension.status != 'error')
      .toList(growable: false);
  final ordered = <Extension>[];
  for (final id in state.providerPriority) {
    final normalized = id.trim().toLowerCase();
    for (final extension in usable) {
      if (extension.id.trim().toLowerCase() == normalized &&
          !ordered.contains(extension)) {
        ordered.add(extension);
      }
    }
  }
  ordered.addAll(usable.where((extension) => !ordered.contains(extension)));
  return resolveConfiguredDownloadService(
    requested,
    state.copyWith(extensions: ordered),
    autoFallback: autoFallback,
  );
}

String _searchTitle(String name) {
  final cleaned = CatalogIdResolver.cleanTitle(normalizeSearchWhitespace(name));
  return cleaned.isEmpty ? normalizeSearchWhitespace(name) : cleaned;
}

bool catalogQueryCanBeSimplified(Track track) =>
    simplifiedSearchTitle(track.name) != _searchTitle(track.name) ||
    simplifiedSearchArtist(track.artistName) !=
        normalizeSearchWhitespace(track.artistName);

DownloadRequestPayload buildCatalogDownloadPayload({
  required Track track,
  required Directory directory,
  required String transferId,
  required String service,
  required String quality,
  required bool useExtensions,
  required bool useFallback,
  CatalogNativeId? nativeId,
  bool simplifiedQuery = false,
}) {
  final source = (track.source ?? '').trim().toLowerCase();
  final rawId = track.id.trim();
  final separator = rawId.indexOf(':');
  final prefix = separator > 0
      ? rawId.substring(0, separator).toLowerCase()
      : '';
  final trackNativeId = separator > 0 ? rawId.substring(separator + 1) : rawId;
  String idFor(String provider) =>
      (source == provider || prefix == provider) ? trackNativeId : '';
  final serviceKey = service.trim().toLowerCase();
  final spec = nativeId == null ? null : providerRequestSpecFor(serviceKey);
  final resolved =
      spec == null ||
          useFallback ||
          idFor(serviceKey).isNotEmpty ||
          nativeId!.providerId != spec.providerId
      ? null
      : spec.nativeId(nativeId.id);
  final direct =
      resolved != null && spec!.delivery == NativeIdDelivery.directSource;
  final field = resolved != null && !direct ? spec!.field : null;
  return DownloadRequestPayload(
    trackName: simplifiedQuery
        ? simplifiedSearchTitle(track.name)
        : _searchTitle(track.name),
    artistName: simplifiedQuery
        ? simplifiedSearchArtist(track.artistName)
        : normalizeSearchWhitespace(track.artistName),
    albumName: track.albumName,
    outputDir: directory.path,
    filenameFormat: '{title}',
    itemId: transferId,
    service: service,
    downloadProvider: service,
    providerTrackId: direct ? resolved : idFor(serviceKey),
    spotifyId: direct ? '' : idFor('spotify'),
    tidalId: direct
        ? ''
        : field == NativeIdField.tidal
        ? resolved!
        : idFor('tidal').isNotEmpty
        ? idFor('tidal')
        : idFor('tidal-web'),
    qobuzId: direct
        ? ''
        : field == NativeIdField.qobuz
        ? resolved!
        : idFor('qobuz').isNotEmpty
        ? idFor('qobuz')
        : idFor('qobuz-web'),
    deezerId: direct
        ? ''
        : field == NativeIdField.deezer
        ? resolved!
        : (track.deezerId ?? idFor('deezer')),
    source: direct ? spec.providerId : (track.source ?? ''),
    isrc: normalizeIsrc(track.isrc),
    durationMs: track.duration * 1000,
    quality: resolved != null ? spec!.quality(quality) : quality,
    useExtensions: useExtensions,
    useFallback: useFallback,
    allowQualityFallback: true,
    embedLyrics: false,
    embedMetadata: false,
  );
}

/// Maintenance is best-effort and never delays playback or application startup.
class CatalogCleanupScheduler {
  CatalogCleanupScheduler(
    this.cleanup, {
    this.interval = const Duration(hours: 6),
  });
  final Future<int> Function() cleanup;
  final Duration interval;
  Timer? _timer;
  bool _running = false;

  void start() {
    _run();
    _timer ??= Timer.periodic(interval, (_) => _run());
  }

  void _run() {
    if (_running) return;
    _running = true;
    unawaited(() async {
      try {
        await cleanup();
      } catch (_) {
        // Failed reads must leave all files untouched; retry on the next tick.
      } finally {
        _running = false;
      }
    }());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
