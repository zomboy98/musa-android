import 'package:mornye/constants/storage_defaults.dart';
import 'dart:async';
import 'package:mornye/services/music_player_service.dart'
    show
        notifyPermanentDownloadReady,
        notifyPermanentDownloadSelected,
        notifyPlaybackSourceRelocated;
import 'package:mornye/providers/local_library_provider.dart';
import 'dart:math';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart';
import 'package:mornye/models/quality_replace_result.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../utils/saf_attempt_cleanup.dart';
import 'package:mornye/services/network_download_staging.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/download_verification_retry_guard.dart';
import 'package:mornye/providers/download_queue_state.dart';
import 'package:mornye/providers/download_origin_inference.dart';
import 'package:mornye/providers/keep_downloaded_provider.dart';
import 'package:mornye/models/library_collections.dart' show trackCollectionKey;
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/download_queue_policy.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/providers/download_progress.dart';
import 'package:mornye/services/download_file_finalizer.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/services/download_container_finalizer.dart';
import 'package:mornye/services/download_completion_audio.dart';
import 'package:mornye/services/download_metadata_resolver.dart';
import 'package:mornye/services/download_metadata_embedding.dart';
import 'package:mornye/services/download_saf_file_replacer.dart';
import 'package:mornye/services/download_connectivity_policy.dart';
import 'package:mornye/services/connectivity_monitor.dart';
import 'package:mornye/services/download_keep_awake.dart';
import 'package:mornye/services/download_queue_pacing.dart';
import 'package:mornye/services/download_scheduler.dart';
import 'package:mornye/services/download_retry_backoff.dart';
import 'package:mornye/services/source_deletion_events.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/folder_path_template.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_reorganizer.dart';
import 'package:mornye/services/app_private_storage.dart';
import 'package:mornye/services/private_downloads_migration.dart';
import 'package:mornye/providers/storage_access_provider.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/download_motion_artwork_source.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_decryption.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/hires_check_service.dart';
import 'package:mornye/services/replaygain_service.dart';
import 'package:mornye/services/album_replaygain_readiness.dart';
import 'package:mornye/services/notification_service.dart';
import 'package:mornye/services/verification_notification.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/saf_display_path.dart';
import 'package:mornye/utils/string_utils.dart';
import 'package:mornye/utils/audio_format_utils.dart';
import 'package:mornye/utils/int_utils.dart';
import 'package:mornye/utils/isrc_utils.dart';
import 'package:mornye/utils/path_match_keys.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/controllers/local_playback.dart'
    show historyMatchesTrack;
import 'package:mornye/utils/download_error_type.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/lyrics_metadata_helper.dart';
import 'package:mornye/utils/progress_stream_poller.dart';

import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/services/analytics/anonymous_metrics.dart';
import 'package:mornye/services/native_download_history.dart';
import 'package:mornye/services/native_download_worker_monitor.dart';

export 'package:mornye/providers/download_history_provider.dart';
export 'package:mornye/providers/download_queue_policy.dart';
export 'package:mornye/providers/download_queue_state.dart';
export 'package:mornye/services/download_metadata_resolver.dart'
    show copyTrackWithResolvedMetadata;
export 'package:mornye/services/download_queue_persistence.dart'
    show encodeDownloadQueueItemForPersistence, downloadQueuePersistenceStatus;

export 'package:mornye/services/history_database.dart'
    show HistoryLookupRequest, HistoryBatchLookupRequest;
export 'package:mornye/services/library_reorganizer.dart'
    show
        LibraryReorganizationMove,
        LibraryReorganizationPlan,
        LibraryReorganizationResult;

part 'download_queue_provider_paths.dart';
part 'download_queue_provider_progress.dart';
part 'download_queue_provider_verification.dart';
part 'download_queue_provider_connectivity.dart';
part 'download_queue_provider_native_worker.dart';
part 'download_queue_provider_finalization.dart';
part 'download_queue_provider_replaygain.dart';
part 'download_queue_provider_embedding.dart';
part 'download_queue_provider_single_item.dart';
part 'download_queue_provider_hires_check.dart';
part 'download_queue_provider_reorganize.dart';
part 'download_queue_provider_pacing.dart';

final _log = AppLogger('DownloadQueue');

final _invalidFolderChars = RegExp(r'[<>:"/\\|?*]');
final _trimDotsAndSpacesRegex = RegExp(r'^[. ]+|[. ]+$');
final _trimUnderscoresAndSpacesRegex = RegExp(r'^[_ ]+|[_ ]+$');
final _multiWhitespaceRegex = RegExp(r'\s+');
final _multiUnderscoreRegex = RegExp(r'_+');

double _log10(num x) => log(x) / ln10;
final _yearRegex = RegExp(r'^(\d{4})');
const _defaultOutputFolderName = defaultDownloadFolderName;
const _defaultAndroidDownloadSubpath = defaultAndroidDownloadSubpath;
const _maxSafFilenameUtf8Bytes = 180;
const _maxSafDirSegmentUtf8Bytes = 120;
final _batchUniqueFilenameTokenPattern = RegExp(
  r'\{(?:title|track(?:_raw)?|track:\d+|playlist_position(?:_raw)?|playlist_position:\d+|playlist position|playlistPosition|position(?::\d+)?)\}',
  caseSensitive: false,
);
final _leadingTrackNumberPattern = RegExp(
  r'^\{track(?::\d+|_raw)?\}\s*[-._]*\s*',
  caseSensitive: false,
);
final _qualityFilenameTokenPattern = RegExp(
  r'\{quality_variant\}',
  caseSensitive: false,
);
final _explicitQualityFilenameTokenPattern = RegExp(
  r'\{(?:quality|quality_variant)\}',
  caseSensitive: false,
);

extension on DownloadItem {
  DownloadItem resetToQueued() => copyWith(
    status: DownloadStatus.queued,
    progress: 0,
    speedMBps: 0,
    bytesReceived: 0,
    bytesTotal: 0,
  );
}

/// The tier the backend really fetched. A relayed download may come from
/// another provider or quality class than the one requested, and history must
/// name what was obtained.
String? _fetchedQualityId(DownloadResult result) {
  final value = result['resolved_quality'];
  return value is String && value.trim().isNotEmpty ? value.trim() : null;
}

bool _sameAutomaticTrack(Track a, Track b) {
  final left = normalizeIsrc(a.isrc);
  final right = normalizeIsrc(b.isrc);
  if (left.isNotEmpty && right.isNotEmpty) return left == right;
  final aSource = a.source?.trim().toLowerCase() ?? '';
  final bSource = b.source?.trim().toLowerCase() ?? '';
  return a.id.trim().isNotEmpty &&
      a.id == b.id &&
      aSource.isNotEmpty &&
      aSource == bSource;
}

class _AutomaticSaveCheck {
  final Track track;
  final completedPaths = <String>[];
  int examinedPaths = 0;
  bool cancelled = false;

  bool get hasUnexaminedPath => examinedPaths < completedPaths.length;
  _AutomaticSaveCheck(this.track);
}

class DownloadQueueNotifier extends Notifier<DownloadQueueState> {
  DownloadQueueNotifier({
    @visibleForTesting this.queuePersistenceForTesting,
    @visibleForTesting this.notifyReadyForTesting,
    @visibleForTesting this.isAndroidForTesting,
    @visibleForTesting this.nativeSnapshotForTesting,
    @visibleForTesting this.nativeRequestJsonForTesting,
  });

  @visibleForTesting
  final bool? isAndroidForTesting;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? nativeSnapshotForTesting;
  @visibleForTesting
  final Future<String?> Function(DownloadItem)? nativeRequestJsonForTesting;
  bool get _isAndroidNativeWorker => isAndroidForTesting ?? Platform.isAndroid;

  @visibleForTesting
  final Future<void> Function(Track, String)? notifyReadyForTesting;
  Future<void> _notifyReady(Track track, String path) =>
      (notifyReadyForTesting ?? notifyPermanentDownloadReady)(track, path);

  @visibleForTesting
  final DownloadQueuePersistence Function(
    List<DownloadItem> Function() currentItems,
    void Function(Object) onError,
  )?
  queuePersistenceForTesting;
  final _permanentSelections = <({Track track, String? id})>[];
  final _pendingSelectionEvents = <Map<String, dynamic>>[];
  final _selectionSnapshots = <String, List<DownloadItem>>{};
  final _preHydrationEvents = <String>{};
  int? _restoreClearBoundary;
  bool _failedDiscardEnqueued = false;

  bool _isDiscardEvent(Map<String, dynamic> event) =>
      event['_native_discard'] == true;

  void _reserveNativeDiscard(
    int index, {
    required bool all,
    Set<String> ids = const {},
  }) {
    if (!_isAndroidNativeWorker ||
        !(_hasActiveAndroidNativeWorker ||
            _nativeOwnershipUncertain ||
            _queueStartupPending))
      return;
    _queuePersistence.reserveNativeDiscard();
    final random = Random.secure();
    final eventId = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _pendingSelectionEvents.insert(index, {
      '_native_discard': true,
      'event_id': eventId,
      'all': all,
      'ids': ids.toList(),
    });
    _selectionSnapshots[eventId] = List<DownloadItem>.of(state.items);
    if (!_queueStorageReady) _preHydrationEvents.add(eventId);
    scheduleMicrotask(_drainSelectionEvents);
  }

  Future<void> _writeNativeDiscard(Map<String, dynamic> event) async {
    final runId = _activeNativeWorkerRunId ?? await _loadNativeWorkerRunId();
    if (runId == null || runId.isEmpty) {
      _queuePersistence.releaseNativeDiscard();
      return;
    }
    _failedDiscardEnqueued = true;
    await _queuePersistence.persistNativeDiscard(
      runId,
      allRequests: event['all'] == true,
      requestIds: (event['ids'] as List).cast<String>().toSet(),
      snapshot: _selectionSnapshots[event['event_id']]!,
    );
  }

  int? _restoreClearEventIndex;
  bool _selectionWriteRunning = false;
  bool _selectionWriteFailed = false;
  bool _nativeOwnershipUncertain = false;
  bool _nativeCancellationRetryRunning = false;
  int _nativeResumeGeneration = 0;
  int _clearGeneration = 0;
  int _selectionDeferrals = 0;
  final _deferredReady = <String, DownloadItem>{};
  bool get _selectionBarrier =>
      _selectionWriteRunning ||
      _selectionWriteFailed ||
      _pendingSelectionEvents.isNotEmpty;

  String _selectPermanentDownload(Track track, String id) =>
      _recordSelectionEvent(track, id);

  String _recordSelectionEvent(Track track, String? id) {
    final event = _newSelectionEvent(track, id);
    _pendingSelectionEvents.add(event);
    final eventId = event['event_id'] as String;
    _selectionSnapshots[eventId] = List<DownloadItem>.of(state.items);
    if (!_queueStorageReady) _preHydrationEvents.add(eventId);
    scheduleMicrotask(_drainSelectionEvents);
    return eventId;
  }

  void _freezeSelectionEventsSince(int index) {
    final snapshot = List<DownloadItem>.of(state.items);
    for (final event in _pendingSelectionEvents.skip(index)) {
      if (_isDiscardEvent(event)) continue;
      _selectionSnapshots[event['event_id'] as String] = snapshot;
    }
  }

  void _dropSelectionEvent(String id) {
    final index = _pendingSelectionEvents.indexWhere(
      (event) => event['event_id'] == id,
    );
    if (index < 0) return;
    _pendingSelectionEvents.removeAt(index);
    _selectionSnapshots.remove(id);
    _preHydrationEvents.remove(id);
    if (_restoreClearBoundary != null && index < _restoreClearBoundary!)
      _restoreClearBoundary = _restoreClearBoundary! - 1;
    if (_restoreClearEventIndex != null && index < _restoreClearEventIndex!)
      _restoreClearEventIndex = _restoreClearEventIndex! - 1;
  }

  Map<String, dynamic> _newSelectionEvent(Track track, String? id) {
    final random = Random.secure();
    return <String, dynamic>{
      'event_id': List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join(),
      'request_id': id,
      'track_json': jsonEncode(track.toJson()),
    };
  }

  void _applySelectionEvent(Map<String, dynamic> event, {bool notify = false}) {
    final track = Track.fromJson(
      jsonDecode(event['track_json'] as String) as Map<String, dynamic>,
    );
    final id = event['request_id'] as String?;
    _permanentSelections.add((track: track, id: id));
    if (id != null) {
      if (notify) notifyPermanentDownloadSelected(track);
    }
  }

  Future<void> _drainSelectionEvents() async {
    if (_selectionDeferrals > 0 ||
        _selectionWriteRunning ||
        _selectionWriteFailed ||
        _pendingSelectionEvents.isEmpty)
      return;
    _selectionWriteRunning = true;
    var batch = <Map<String, dynamic>>[];
    try {
      if (!_queueStorageReady) _startQueueRestore();
      await _queueHydrated.future;
      if (!ref.mounted) return;
      if (!_queueStorageReady) throw StateError('Queue restoration failed');
      while (_pendingSelectionEvents.isNotEmpty) {
        final first = _pendingSelectionEvents.first;
        final id = first['event_id'] as String;
        final snapshot = _selectionSnapshots[id];
        batch = [first];
        if (!_isDiscardEvent(first) && snapshot != null) {
          for (final event in _pendingSelectionEvents.skip(1)) {
            if (_isDiscardEvent(event) ||
                !identical(_selectionSnapshots[event['event_id']], snapshot))
              break;
            batch.add(event);
          }
        }
        if (_isDiscardEvent(first)) {
          _failedDiscardEnqueued = false;
          await _writeNativeDiscard(first);
        } else {
          await _queuePersistence.persistSelectionEvents(
            batch,
            snapshot: snapshot,
          );
        }
        if (!ref.mounted) return;
        _pendingSelectionEvents.removeRange(0, batch.length);
        for (final event in batch) {
          _selectionSnapshots.remove(event['event_id']);
        }
        for (final event in batch) {
          if (!_isDiscardEvent(event))
            _applySelectionEvent(event, notify: true);
        }
        batch = [];
      }
    } catch (_) {
      _selectionWriteFailed = true;
      _failedSelectionBatch = batch;
      _log.e('Failed to persist download selection');
      if (ref.mounted)
        state = state.copyWith(selectionPersistenceBlocked: true);
    } finally {
      _selectionWriteRunning = false;
      _releaseSelectionBarrier();
    }
  }

  void _releaseSelectionBarrier() {
    if (!ref.mounted || _selectionBarrier) return;
    _saveQueueToStorage();
    for (final item in _deferredReady.values) {
      final current = _findItemById(item.id);
      if ((current == null ||
              (current.status == DownloadStatus.completed &&
                  current.filePath == item.filePath)) &&
          _isSelectedPermanentDownload(item) &&
          item.filePath != null) {
        unawaited(_notifyReady(item.track, item.filePath!));
      }
    }
    _deferredReady.clear();
    if (!state.isPaused) Future.microtask(_processQueue);
  }

  Future<void> retrySelectionPersistence() async {
    if (!_selectionWriteFailed || _selectionWriteRunning) return;
    _selectionWriteRunning = true;
    try {
      if (!_queueStorageReady) {
        _startQueueRestore();
        await _queueHydrated.future;
        if (!_queueStorageReady) throw StateError('Queue restoration failed');
      }
      if (_failedSelectionBatch.length == 1 &&
          _isDiscardEvent(_failedSelectionBatch.single) &&
          !_failedDiscardEnqueued) {
        await _writeNativeDiscard(_failedSelectionBatch.single);
      } else {
        await _queuePersistence.persistSelectionEvents([]);
      }
      // The persistence writer retained the failed batch. It committed before
      // any later gesture, which remains queued here.
      // The batch size is tracked separately below when a failure occurs.
      for (final event in _failedSelectionBatch) {
        if (!_isDiscardEvent(event)) _applySelectionEvent(event, notify: true);
        _selectionSnapshots.remove(event['event_id']);
      }
      _pendingSelectionEvents.removeRange(0, _failedSelectionBatch.length);
      _failedSelectionBatch = [];
      _selectionWriteFailed = false;
      if (ref.mounted)
        state = state.copyWith(selectionPersistenceBlocked: false);
    } catch (_) {
      _log.e('Failed to retry download selection');
      if (ref.mounted)
        state = state.copyWith(selectionPersistenceBlocked: true);
    } finally {
      _selectionWriteRunning = false;
    }
    if (!_selectionWriteFailed) await _drainSelectionEvents();
    _releaseSelectionBarrier();
  }

  List<Map<String, dynamic>> _failedSelectionBatch = [];

  ({Track track, String? id})? _latestCommittedSelection(Track track) =>
      _permanentSelections.reversed
          .where((entry) => _sameAutomaticTrack(entry.track, track))
          .firstOrNull;

  ({Track track, String? id})? _latestSelection(Track track) {
    for (final event in _pendingSelectionEvents.reversed) {
      if (_isDiscardEvent(event)) continue;
      final eventTrack = Track.fromJson(
        jsonDecode(event['track_json'] as String) as Map<String, dynamic>,
      );
      if (_sameAutomaticTrack(eventTrack, track)) {
        return (track: eventTrack, id: event['request_id'] as String?);
      }
    }
    return _latestCommittedSelection(track);
  }

  bool _isSelectedPermanentDownload(DownloadItem item) {
    final selected = _permanentSelections.reversed
        .where((entry) => _sameAutomaticTrack(entry.track, item.track))
        .firstOrNull;
    if (selected != null) return selected.id == item.id;
    // Restored rows have no known selection order. Do not guess between them.
    return state.items
            .where((other) => _sameAutomaticTrack(other.track, item.track))
            .length ==
        1;
  }

  @visibleForTesting
  bool isSelectedPermanentDownloadForTesting(DownloadItem item) =>
      _isSelectedPermanentDownload(item);

  void _prunePermanentSelections(Set<String> removedIds) {
    final pending = List<Map<String, dynamic>>.of(_pendingSelectionEvents);
    final candidates = <({Track track, String? id})>[
      ..._permanentSelections,
      for (final event in pending)
        if (!_isDiscardEvent(event))
          (
            track: Track.fromJson(
              jsonDecode(event['track_json'] as String) as Map<String, dynamic>,
            ),
            id: event['request_id'] as String?,
          ),
    ];
    for (final entry in candidates.reversed) {
      final id = entry.id;
      if (id != null &&
          removedIds.contains(id) &&
          _latestSelection(entry.track)?.id == id) {
        _recordSelectionEvent(entry.track, null);
      }
    }
  }

  final _automaticSaveChecks = <_AutomaticSaveCheck>[];

  void _logQueuePersistenceFailure(Object _) =>
      _log.e('Failed to persist queue');

  late final _queuePersistence =
      queuePersistenceForTesting?.call(
        () => state.items,
        _logQueuePersistenceFailure,
      ) ??
      DownloadQueuePersistence(
        currentItems: () => state.items,
        onError: _logQueuePersistenceFailure,
      );
  final QueueProcessingGate _queueProcessingGate = QueueProcessingGate();
  final DownloadProgressTracker _progressTracker = DownloadProgressTracker();
  final DownloadConnectivityPolicy _connectivityPolicy =
      DownloadConnectivityPolicy();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  int _downloadCount = 0;
  static const _progressPollingInterval = Duration(milliseconds: 1200);
  static const _progressStreamBootstrapTimeout = Duration(seconds: 3);
  static const _queueSchedulingInterval = Duration(milliseconds: 250);
  static const cooldownWaitText = 'Proveedor en enfriamiento, se reanuda solo';
  static const providerTurnLimit = Duration(minutes: 15);
  final DownloadQueuePacing _pacing = DownloadQueuePacing();
  Timer? _autoResumeTimer;
  bool _autoPaused = false;
  static const _nativePreparationBatchSize = 32;
  static const _nativePreparationWindowSize = 128;
  static const _nativeWorkerRunIdPrefsKey =
      'download_queue_native_worker_run_id';
  final NotificationService _notificationService = NotificationService();
  final _metadataResolver = DownloadMetadataResolver();
  late final _metadataEmbedding = DownloadMetadataEmbedding(
    onReplayGain: _storeTrackReplayGainForAlbum,
  );
  late final ProgressStreamPoller<Map<String, dynamic>> _progressPoller =
      ProgressStreamPoller<Map<String, dynamic>>(
        streamProvider: PlatformBridge.downloadProgressStream,
        pollProvider: PlatformBridge.getAllDownloadProgress,
        onProgress: (allProgress) async =>
            _processAllDownloadProgress(allProgress),
        pollingInterval: _progressPollingInterval,
        bootstrapTimeout: _progressStreamBootstrapTimeout,
        onStreamProcessingError: (e) =>
            _log.w('Progress stream processing failed: $e'),
        onStreamFailed: (error) => _log.w(
          'Download progress stream failed, fallback to polling: $error',
        ),
        onStreamTimeout: () =>
            _log.w('Download progress stream timeout, fallback to polling'),
        onPollError: (e) => _log.w('Progress polling failed: $e'),
        shouldPollTick: () => _progressTracker.shouldPoll(state),
      );
  int _totalQueuedAtStart = 0;
  int _completedInSession = 0;
  int _failedInSession = 0;
  int _queueItemSequence = 0;
  bool _isLoaded = false;
  Completer<void> _queueRestored = Completer<void>();
  Completer<void> _queueHydrated = Completer<void>();
  bool _queueStartupPending = false;
  bool _queueStorageReady = true;
  bool? _startupPausedOverride;
  bool _foregroundResumeScheduled = false;
  bool _iosBackgroundExecutionExpired = false;
  StreamSubscription<List<String>>? _iosBackgroundExpirationSubscription;
  final Set<String> _ensuredDirs = {};
  final Map<String, Future<void>> _qualityVariantFileLocks = {};
  Future<String?>? _appFolderStorageFallback;
  final Set<String> _rejectedAppFolderRoots = {};

  Future<T> _withQualityVariantFileLock<T>(
    String path,
    Future<T> Function() action,
  ) async {
    final key = path.toLowerCase();
    final previous = _qualityVariantFileLocks[key];
    final completer = Completer<void>();
    final current = completer.future;
    _qualityVariantFileLocks[key] = current;
    if (previous != null) await previous;
    try {
      return await action();
    } finally {
      completer.complete();
      if (identical(_qualityVariantFileLocks[key], current)) {
        _qualityVariantFileLocks.remove(key);
      }
    }
  }

  bool _networkPausedByWifiOnly = false;
  final Set<String> _locallyCancelledItemIds = {};
  final Map<String, Completer<DownloadItem?>> _replaceWaiters = {};
  final Map<String, String> _failureSummaries = {};
  final Set<String> _pausePendingItemIds = {};
  final Map<String, Future<void>> _nativeCancelRequests = {};
  final Map<String, Future<void>> _activeDownloadAttempts = {};
  final Set<String> _retryingItemIds = {};
  final DownloadVerificationRetryGuard _verificationRetryGuard =
      DownloadVerificationRetryGuard();
  final _verificationWaitCoordinator = DownloadVerificationWaitCoordinator(
    ExtensionVerificationResult.failed,
  );
  final DownloadRetryBackoff _rateLimitBackoff = DownloadRetryBackoff();
  final Map<String, Completer<void>> _providerTurnWaits = {};

  void _cancelProviderTurnWait(String id) {
    final wait = _providerTurnWaits.remove(id);
    if (wait != null && !wait.isCompleted) wait.complete();
  }

  void _cancelAllProviderTurnWaits() {
    for (final id in _providerTurnWaits.keys.toList()) {
      _cancelProviderTurnWait(id);
    }
  }
  final Set<String> _rateLimitRetriedItemIds = {};
  String? _activeNativeWorkerRunId;
  bool get _hasActiveAndroidNativeWorker =>
      _isAndroidNativeWorker && _activeNativeWorkerRunId?.isNotEmpty == true;

  // Album ReplayGain accumulator: keyed by album identifier.
  // Stores per-track loudness data until all album tracks are done,
  // then computes and writes album gain/peak to every track in the album.
  final Map<String, _AlbumRgAccumulator> _albumRgData = {};

  @override
  DownloadQueueState build() {
    ref.onDispose(
      SourceDeletionEvents.instance.subscribe((source) async {
        _removeDeletedFile(source);
        await DownloadFileInventory.removeDeletedPath(source);
      }),
    );
    if (Platform.isIOS) {
      _iosBackgroundExpirationSubscription ??=
          PlatformBridge.iosBackgroundDownloadExpirationEvents().listen(
            _handleIosBackgroundDownloadExpiration,
          );
      ref.onDispose(() {
        _iosBackgroundExpirationSubscription?.cancel();
        _iosBackgroundExpirationSubscription = null;
      });
    }
    ref.listen<AppSettings>(settingsProvider, (previous, next) {
      updateSettings(next);
      if (previous?.downloadNetworkMode != next.downloadNetworkMode) {
        _handleDownloadNetworkModeChanged(next.downloadNetworkMode);
      }
    });
    ref.listen<StorageAccessState>(storageAccessProvider, (previous, next) {
      if (previous == null ||
          (previous.answered == next.answered &&
              previous.granted == next.granted)) {
        return;
      }
      if (ref.mounted &&
          state.items.any((item) => item.status == DownloadStatus.queued)) {
        Future.microtask(_processQueue);
      }
    });

    ref.onDispose(() {
      for (final waiter in _replaceWaiters.values.toList()) {
        if (!waiter.isCompleted) waiter.complete(null);
      }
      _replaceWaiters.clear();
      if (!_queueRestored.isCompleted) _queueRestored.complete();
      if (!_queueHydrated.isCompleted) _queueHydrated.complete();
      _verificationWaitCoordinator.cancelAll();
      _rateLimitBackoff.cancelAll();
      _cancelAllProviderTurnWaits();
      _progressPoller.stop();
      _autoResumeTimer?.cancel();
      _connectivitySub?.cancel();
      _connectivitySub = null;
      _queuePersistence.dispose();
    });

    _queueStorageReady = false;
    _startQueueRestore(initializeOutputDir: true);
    return const DownloadQueueState();
  }

  void _startQueueRestore({bool initializeOutputDir = false}) {
    if (_queueStartupPending || _queueStorageReady || !ref.mounted) return;
    _queueStartupPending = true;
    final restored = _queueRestored = Completer<void>();
    final hydrated = _queueHydrated = Completer<void>();
    Future.microtask(() async {
      try {
        if (!ref.mounted) return;
        updateSettings(ref.read(settingsProvider));
        if (initializeOutputDir) {
          try {
            await _initOutputDir();
          } catch (error, stack) {
            _log.e(
              'Failed to initialize download folder: $error',
              error,
              stack,
            );
          }
        }
        await _loadQueueFromStorage();
        await _purgeQueueOnce();
      } catch (error, stack) {
        _log.e('Failed to initialize download queue: $error', error, stack);
      } finally {
        if (ref.mounted && _queueStorageReady) {
          // Native adoption can publish an older paused snapshot after a user
          // has changed this choice while its platform calls were awaiting.
          final paused = _startupPausedOverride;
          if (paused != null && state.isPaused != paused) {
            if (paused && state.isProcessing) {
              pauseQueue(persistAcrossRestarts: false);
            } else if (!paused) {
              resumeQueue();
            } else {
              state = state.copyWith(isPaused: true);
            }
          }
          _startupPausedOverride = null;
        }
        _queueStartupPending = false;
        if (ref.mounted && _queueStorageReady) {
          _saveQueueToStorage();
          if (!state.isProcessing && !state.isPaused && state.queuedCount > 0) {
            Future.microtask(_processQueue);
          }
        }
        if (!restored.isCompleted) restored.complete();
        if (!hydrated.isCompleted) hydrated.complete();
      }
    });
  }

  /// Flush any debounced queue persistence to disk immediately. Called when
  /// the app is backgrounded: the OS may kill the process without a graceful
  /// teardown, and a pending debounce timer would silently drop the most
  /// recent queue mutations.
  Future<void> flushQueuePersistence({bool requireDurable = false}) async {
    // Startup publishes restored items before completing this gate. Capturing
    // the initial empty state while hydration is in flight would delete the
    // restored rows when the persistence writer reaches that empty snapshot.
    if (!_queueStorageReady) _startQueueRestore();
    await _queueRestored.future;
    if (!ref.mounted) return;
    if (!_queueStorageReady) {
      throw StateError('Download queue restoration failed; retry the flush');
    }
    while (_selectionBarrier && ref.mounted) {
      if (_selectionWriteFailed)
        throw StateError('Download selection requires an explicit retry');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!ref.mounted) return;
    await _queuePersistence.flush(requireDurable: requireDurable);
  }

  void _persistUserPausedQueue(bool paused) {
    if (_queueStartupPending) _startupPausedOverride = paused;
    _queuePersistence.setUserPaused(paused);
  }

  /// Restarts a queue that was deliberately left pending because Android did
  /// not allow a foreground service to be launched while the app was hidden.
  void resumePendingDownloadsOnForeground() {
    if (Platform.isIOS && _iosBackgroundExecutionExpired) {
      _iosBackgroundExecutionExpired = false;
      if (state.isPaused) {
        state = state.copyWith(isPaused: false);
      }
    }
    if (_foregroundResumeScheduled ||
        state.isProcessing ||
        state.isPaused ||
        !state.items.any((item) => item.status == DownloadStatus.queued)) {
      return;
    }
    _foregroundResumeScheduled = true;
    Future.microtask(() async {
      _foregroundResumeScheduled = false;
      if (!ref.mounted) return;
      if (!state.isProcessing &&
          !state.isPaused &&
          state.items.any((item) => item.status == DownloadStatus.queued)) {
        await _processQueue();
      }
    });
  }

  Future<void> handleVerificationNotificationTap(
    VerificationNotification target,
  ) => _handleVerificationNotificationTap(target);

  void _handleIosBackgroundDownloadExpiration(List<String> nativeItemIds) {
    if (!Platform.isIOS) return;
    final cancelledItemIds = nativeItemIds.toSet();
    final requeueItemIds = cancelledItemIds.where((id) {
      final item = state.lookup.byItemId[id];
      return item != null && item.status != DownloadStatus.completed;
    }).toSet();
    if (!state.isProcessing && requeueItemIds.isEmpty) return;

    final alreadyForeground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _log.w(
      'iOS background execution time expired; safely deferring active downloads until foreground',
    );
    _iosBackgroundExecutionExpired = true;
    if (state.isProcessing && !state.isPaused) {
      pauseQueue(
        persistAcrossRestarts: false,
        nativeCancelledItemIds: cancelledItemIds,
      );
    }

    if (requeueItemIds.isNotEmpty) {
      final updatedItems = state.items
          .map((item) {
            if (!requeueItemIds.contains(item.id)) {
              return item;
            }
            return item.resetToQueued();
          })
          .toList(growable: false);
      if (state.isProcessing) {
        _pausePendingItemIds.addAll(requeueItemIds);
      }
      state = state.copyWith(
        items: updatedItems,
        isPaused: true,
        currentDownload: null,
      );
    } else if (!state.isProcessing) {
      state = state.copyWith(isPaused: true, currentDownload: null);
    }
    unawaited(
      flushQueuePersistence().catchError((Object error) {
        _log.e('Failed to flush expired iOS queue: $error');
      }),
    );
    // The native expiration callback cancels the download synchronously before this
    // asynchronous event reaches Dart. If foregrounding won that race, still
    // requeue the cancelled item, then immediately let the running queue loop
    // continue instead of misclassifying it as a skipped download.
    if (alreadyForeground) {
      resumePendingDownloadsOnForeground();
    }
  }

  static const _queuePurgeFlag = 'download_queue_purged_20261116';

  Future<void> _purgeQueueOnce() async {
    if (!ref.mounted || !_queueStorageReady) return;
    if (Platform.environment.containsKey('FLUTTER_TEST')) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_queuePurgeFlag) ?? false) return;
    await prefs.setBool(_queuePurgeFlag, true);
    if (!ref.mounted || state.items.isEmpty) return;
    clearAll();
  }

  Future<void> _loadQueueFromStorage() async {
    if (_isLoaded || !ref.mounted) return;

    try {
      final restorePaused = await _queuePersistence.loadUserPaused();
      if (!ref.mounted) return;
      final restoredItems = await _queuePersistence.restore();
      if (!ref.mounted) return;
      final selectionEvents = await _queuePersistence.restoreSelectionEvents();
      if (!ref.mounted) return;
      for (final event in selectionEvents) {
        _applySelectionEvent(event);
      }
      final clearIndex = _restoreClearEventIndex;
      if (clearIndex != null) {
        final tombstones = _permanentSelections
            .where(
              (selection) =>
                  selection.id != null &&
                  _latestCommittedSelection(selection.track)?.id ==
                      selection.id,
            )
            .map((selection) => _newSelectionEvent(selection.track, null))
            .toList();
        _pendingSelectionEvents.insertAll(
          min(clearIndex, _pendingSelectionEvents.length),
          tombstones,
        );
        final clearSnapshot = <DownloadItem>[];
        for (final event in tombstones) {
          _selectionSnapshots[event['event_id'] as String] = clearSnapshot;
        }
        _restoreClearEventIndex = null;
        if (tombstones.isNotEmpty) scheduleMicrotask(_drainSelectionEvents);
      }
      final pendingItems = restoredItems.map((item) {
        final service = _normalizeQueuedService(item.service);
        return service == item.service ? item : item.copyWith(service: service);
      }).toList();

      final droppedDuplicateIds = <String>{};
      final normalizedRestoredItems = _withoutFailedDuplicates(
        _normalizeRestoredQueueIds(pendingItems),
        droppedDuplicateIds,
      );
      final normalizedPendingItems = clearIndex == null
          ? normalizedRestoredItems
          : <DownloadItem>[];
      final mergedSnapshots = <List<DownloadItem>, List<DownloadItem>>{};
      for (var index = 0; index < _pendingSelectionEvents.length; index++) {
        final eventId = _pendingSelectionEvents[index]['event_id'] as String;
        if (_preHydrationEvents.contains(eventId) &&
            (clearIndex == null || index < (_restoreClearBoundary ?? 0))) {
          final snapshot = _selectionSnapshots[eventId];
          if (snapshot != null)
            _selectionSnapshots[eventId] = mergedSnapshots.putIfAbsent(
              snapshot,
              () => [...normalizedRestoredItems, ...snapshot],
            );
        }
      }
      _preHydrationEvents.clear();
      _restoreClearBoundary = null;
      state = state.copyWith(
        // Additions remain visible immediately while the database and codec
        // worker are awaiting. Append them without deduplicating track IDs:
        // distinct requests/quality variants are deliberately separate items.
        items: [...normalizedPendingItems, ...state.items],
        isPaused:
            _startupPausedOverride ??
            (normalizedPendingItems.isNotEmpty && restorePaused),
      );
      _isLoaded = true;
      _queueStorageReady = true;
      if (droppedDuplicateIds.isNotEmpty) {
        _log.i(
          'Merged ${droppedDuplicateIds.length} repeated failed downloads',
        );
        _prunePermanentSelections(droppedDuplicateIds);
      }
      if (_hasNetworkFailedItems) _startConnectivityMonitoring();
      if (!_queueHydrated.isCompleted) _queueHydrated.complete();
      _saveQueueToStorage();
      if (normalizedPendingItems.isEmpty) {
        if (await _tryAdoptAndroidNativeWorkerSnapshot(normalizedPendingItems))
          return;
        if (await _guardPersistedNativeOwnership()) return;
        if (restorePaused && _startupPausedOverride == null) {
          _queuePersistence.setUserPaused(false);
        }
        _log.d('No pending items to restore');
        if (!_selectionBarrier) await _queuePersistence.flush();
        return;
      }
      _log.i(
        'Restored ${normalizedPendingItems.length} pending items from storage',
      );
      if (await _tryAdoptAndroidNativeWorkerSnapshot(normalizedPendingItems)) {
        return;
      }
      if (!ref.mounted) return;
      if (await _guardPersistedNativeOwnership()) return;
      if (state.isPaused) {
        _log.i('Restored queue in user-paused state');
      }
    } catch (e) {
      _log.e('Failed to load queue from storage: $e');
    }
  }

  Future<bool> _guardPersistedNativeOwnership() async {
    if (!_isAndroidNativeWorker) return false;
    final runId = await _loadNativeWorkerRunId();
    if (!ref.mounted || runId == null || runId.isEmpty) return false;
    _nativeOwnershipUncertain = true;
    state = state.copyWith(isPaused: true, nativeRecoveryRequired: true);
    _persistUserPausedQueue(true);
    return true;
  }

  void _saveQueueToStorage() {
    // A partial startup snapshot must never enter the writer's debounce or
    // dispose path: it would otherwise delete the restored IDs later on.
    if (!_queueStorageReady) {
      _startQueueRestore();
      return;
    }
    if (_queueStartupPending || _selectionBarrier) return;
    _queuePersistence.schedule();
  }

  bool _isSafMode(AppSettings settings) {
    return Platform.isAndroid &&
        settings.storageMode == 'saf' &&
        settings.downloadTreeUri.isNotEmpty;
  }

  String _normalizeQueuedService(String service) {
    final normalized = service.trim();
    if (normalized.isEmpty) {
      return normalized;
    }

    final resolved = resolveConfiguredDownloadService(
      normalized,
      ref.read(extensionProvider),
      autoFallback: false,
    );
    return resolved.isEmpty ? normalized : resolved;
  }

  bool _hasActiveDownloadProvider(String service) {
    final normalized = service.trim();
    if (normalized.isEmpty) {
      return false;
    }

    final extensionState = ref.read(extensionProvider);
    return extensionState.extensions.any(
      (ext) =>
          ext.enabled &&
          ext.hasDownloadProvider &&
          ext.status != 'error' &&
          ext.id.trim().toLowerCase() == normalized.toLowerCase(),
    );
  }

  String? _resolveDeclaredDownloadQuality(
    String service,
    String quality, {
    bool useSourceDefault = false,
    bool allowProviderFallback = false,
    bool strict = true,
  }) {
    final provider = ref
        .read(extensionProvider)
        .extensions
        .where(
          (ext) =>
              ext.enabled &&
              ext.hasDownloadProvider &&
              ext.id.toLowerCase() == service.trim().toLowerCase(),
        )
        .firstOrNull;
    if (provider == null) return null;
    final options = provider.qualityOptions;
    // Legacy providers without a declared list retain their existing contract.
    if (options.isEmpty) return manifestQualityId(quality);
    final option =
        findDownloadQualityOption(options, quality) ??
        (useSourceDefault
            ? findEquivalentDownloadQualityOption(options, quality)
            : null);
    if (option != null) return manifestQualityId(option.id);
    final remembered = manifestQualityId(quality);
    if (!strict) {
      // Relay mode never stops here: the backend maps an undeclared tier by
      // quality class, and no choice at all means the provider's best tier.
      if (remembered.isNotEmpty) return remembered;
      final best =
          defaultDownloadQualityOption(provider.id, options) ??
          options
              .where((o) => o.kind.trim().toLowerCase() == 'lossless')
              .firstOrNull ??
          options.first;
      return manifestQualityId(best.id);
    }
    if (useSourceDefault && allowProviderFallback && remembered.isNotEmpty) {
      return remembered;
    }
    final sourceDefault = useSourceDefault && remembered.isEmpty
        ? defaultDownloadQualityOption(provider.id, options)
        : null;
    if (sourceDefault != null) return manifestQualityId(sourceDefault.id);
    return null;
  }

  bool _downloadProviderHasQualityOptions(String service) => ref
      .read(extensionProvider)
      .extensions
      .any(
        (ext) =>
            ext.enabled &&
            ext.hasDownloadProvider &&
            ext.id.toLowerCase() == service.trim().toLowerCase() &&
            ext.qualityOptions.isNotEmpty,
      );

  String? _rememberedDownloadQuality(AppSettings settings, String service) {
    final target = service.trim().toLowerCase();
    for (final entry in settings.downloadQualityByProvider.entries) {
      if (entry.key.trim().toLowerCase() == target) return entry.value;
    }
    return null;
  }

  /// Builds the backend [DownloadRequestPayload] shared by the native-worker
  /// request builder and the inline single-item download path. Fields whose
  /// source value legitimately differs between the two callers (SAF staging,
  /// download strategy) are left as parameters.
  DownloadRequestPayload _buildDownloadRequestPayload({
    required Track track,
    required DownloadItem item,
    required AppSettings settings,
    required ExtensionState extensionState,
    required String quality,
    required bool qualityFromSavedPreference,
    required String filenameFormat,
    required String outputDir,
    required String outputExt,
    required bool useSaf,
    String? safFileName,
    String? deezerTrackId,
    String? genre,
    String? label,
    String? copyright,
    bool stageSafForDeferredPublish = false,
    bool qualityVariantCollisionOnly = false,
  }) {
    final resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
      track,
      settings,
    );
    final postProcessingEnabled =
        settings.useExtensionProviders &&
        extensionState.extensions.any((e) => e.enabled && e.hasPostProcessing);
    final selectedDownloadExtension = extensionState.extensions
        .where(
          (extension) =>
              extension.enabled &&
              extension.hasDownloadProvider &&
              extension.id.toLowerCase() == item.service.toLowerCase(),
        )
        .firstOrNull;
    final normalizedTrackNumber =
        (track.trackNumber != null && track.trackNumber! > 0)
        ? track.trackNumber!
        : 0;
    final normalizedDiscNumber =
        (track.discNumber != null && track.discNumber! > 0)
        ? track.discNumber!
        : 0;

    String payloadSpotifyId = track.source?.trim().toLowerCase() == 'local'
        ? ''
        : track.id;
    String payloadQobuzId = '';
    String payloadTidalId = '';
    if (track.id.startsWith('qobuz:')) {
      payloadQobuzId = track.id.substring(6);
      if (_downloadProviderReplacesLegacyProvider(item.service, 'qobuz')) {
        payloadSpotifyId = '';
      }
    }
    if (track.id.startsWith('tidal:')) {
      payloadTidalId = track.id.substring(6);
      if (_downloadProviderReplacesLegacyProvider(item.service, 'tidal')) {
        payloadSpotifyId = '';
      }
    }

    final qualitySource = qualityFromSavedPreference
        ? settings.downloadQualitySourceFor(item.service, quality)
        : null;
    return DownloadRequestPayload(
      isrc: track.isrc ?? '',
      service: item.service,
      downloadProvider: item.service,
      providerTrackId: _knownProviderTrackId(track, item.service),
      spotifyId: payloadSpotifyId,
      trackName: track.name,
      artistName: track.artistName,
      albumName: track.albumName,
      albumArtist: resolvedAlbumArtist ?? '',
      coverUrl: settings.embedMetadata ? (track.coverUrl ?? '') : '',
      coverMaxDimension: settings.embeddedCoverMaxDimension,
      outputDir: outputDir,
      albumFolderTemplate: _unresolvedAlbumFolderTemplate(
        track,
        item,
        settings,
      ),
      filenameFormat: filenameFormat,
      quality: quality,
      qualitySourceProvider: qualitySource?.provider,
      qualitySourceId: qualitySource?.id,
      qualitySourceKind: qualitySource?.kind,
      qualitySourceLabel: qualitySource?.label,
      allowSavedQualityIdFallback:
          settings.autoFallback && qualityFromSavedPreference,
      qualityRelay:
          !item.fromBatch &&
          downloadQualityRelayAllowed(
            strict: settings.strictDownloadQuality,
            qualityOverride: item.qualityOverride,
          ),
      embedMetadata: settings.embedMetadata,
      artistTagMode: settings.artistTagMode,
      metadataSeparators: settings.metadataSeparators,
      embedLyrics:
          settings.embedMetadata &&
          settings.embedLyrics &&
          !DownloadMetadataResolver.shouldSkipLyrics(
            extensionState,
            track.source,
            item.service,
          ),
      embedReplayGain: settings.embedReplayGain,
      postProcessingEnabled: postProcessingEnabled,
      trackNumber: normalizedTrackNumber,
      playlistPosition: _validPlaylistPosition(item),
      discNumber: normalizedDiscNumber,
      totalTracks: track.totalTracks ?? 0,
      totalDiscs: track.totalDiscs ?? 0,
      releaseDate: track.releaseDate ?? '',
      itemId: item.id,
      durationMs: track.duration * 1000,
      source: track.source ?? '',
      genre: genre ?? track.genre ?? '',
      label: label ?? track.label ?? '',
      copyright: copyright ?? track.copyright ?? '',
      composer: track.composer ?? '',
      comment: track.comment ?? '',
      explicit: track.explicit == true,
      albumType: track.albumType ?? '',
      upc: track.upc ?? '',
      qobuzId: payloadQobuzId,
      tidalId: payloadTidalId,
      deezerId: deezerTrackId ?? '',
      lyricsMode: settings.lyricsMode,
      storageMode: useSaf ? 'saf' : 'app',
      safTreeUri: useSaf ? settings.downloadTreeUri : '',
      safRelativeDir: useSaf ? outputDir : '',
      safFileName: useSaf ? (safFileName ?? '') : '',
      safOutputExt: useSaf ? outputExt : '',
      outputExt: outputExt,
      stageSafOutput: stageSafForDeferredPublish,
      deferSafPublish: stageSafForDeferredPublish,
      requiresContainerConversion: _shouldRequestContainerConversion(
        item.service,
        outputExt,
      ),
      allowQualityVariant: item.preserveQualityVariant,
      qualityVariant: item.preserveQualityVariant
          ? qualityVariantStagingLabel(item.id)
          : '',
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
      songLinkRegion: settings.songLinkRegion,
      networkConcurrencyLimit:
          selectedDownloadExtension
              ?.downloadTransferPolicy
              .maxConcurrentDownloads ??
          3,
    );
  }

  String _newQueueItemId(Track track, {Set<String>? takenIds}) {
    final trimmedIsrc = track.isrc?.trim();
    final trimmedTrackId = track.id.trim();
    final base = (trimmedIsrc != null && trimmedIsrc.isNotEmpty)
        ? trimmedIsrc
        : (trimmedTrackId.isNotEmpty ? trimmedTrackId : 'track');

    while (true) {
      _queueItemSequence++;
      final candidate =
          '$base-${DateTime.now().microsecondsSinceEpoch}-$_queueItemSequence';
      if (takenIds == null || !takenIds.contains(candidate)) {
        return candidate;
      }
    }
  }

  List<DownloadItem> _normalizeRestoredQueueIds(List<DownloadItem> items) {
    if (items.isEmpty) return items;

    final seen = <String>{};
    var regeneratedCount = 0;
    final normalized = <DownloadItem>[];

    for (final item in items) {
      final trimmedId = item.id.trim();
      final shouldRegenerate = trimmedId.isEmpty || seen.contains(trimmedId);
      if (shouldRegenerate) {
        final newId = _newQueueItemId(item.track, takenIds: seen);
        seen.add(newId);
        normalized.add(item.copyWith(id: newId));
        regeneratedCount++;
      } else {
        seen.add(trimmedId);
        normalized.add(item);
      }
    }

    if (regeneratedCount > 0) {
      _log.w(
        'Regenerated $regeneratedCount duplicate/empty queue item IDs during restore',
      );
    }

    return normalized;
  }

  void updateSettings(AppSettings settings) {
    state = _withSettings(settings);
  }

  DownloadQueueState _withSettings(
    AppSettings settings, {
    List<DownloadItem>? items,
  }) {
    return state.copyWith(
      items: items,
      outputDir: settings.downloadDirectory.isNotEmpty
          ? settings.downloadDirectory
          : state.outputDir,
      filenameFormat: settings.filenameFormat,
      singleFilenameFormat: settings.singleFilenameFormat,
      audioQuality: settings.audioQuality,
      autoFallback: settings.autoFallback,
    );
  }

  /// Automatic saves wait for hydration and never duplicate active downloads.
  /// Recheck the queue immediately before insertion so concurrent callers
  /// cannot both enqueue the same song.
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) => _addSavedTrackToQueue(
    track,
    service,
    playlistName: playlistName,
    playlistPosition: playlistPosition,
    qualityOverride: qualityOverride,
    origin: origin,
  );

  Future<String?> addCurrentSavedTrackToQueue(
    Track track,
    String service,
    bool Function() isCurrent,
  ) => _addSavedTrackToQueue(track, service, isCurrent: isCurrent);

  Future<String?> _addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
    bool Function()? isCurrent,
  }) async {
    if (!_queueStorageReady) _startQueueRestore();
    await _queueRestored.future;
    if (!ref.mounted) return null;
    if (!_queueStorageReady) {
      throw StateError('Download queue restoration failed; retry the download');
    }
    if (_hasActiveAutomaticDownload(track)) return null;
    final check = _AutomaticSaveCheck(track);
    _automaticSaveChecks.add(check);
    try {
      if (await _hasAccessibleSavedDownload(track)) return null;
      while (check.hasUnexaminedPath) {
        if (await savedDownloadFileAccessible(
          check.completedPaths[check.examinedPaths++],
        )) {
          return null;
        }
      }
      if (!ref.mounted ||
          _hasActiveAutomaticDownload(track) ||
          (isCurrent != null && !isCurrent())) {
        return null;
      }
      return addToQueue(
        track,
        service,
        playlistName: playlistName,
        playlistPosition: playlistPosition,
        qualityOverride: qualityOverride,
        origin: origin,
      );
    } finally {
      _automaticSaveChecks.remove(check);
    }
  }

  bool _hasActiveAutomaticDownload(Track track) => state.items.any(
    (item) =>
        _matchesActiveDownload(item, track, '', allowQualityVariants: false),
  );

  Future<bool> _hasAccessibleSavedDownload(
    Track track, {
    bool includeLocalLibrary = true,
  }) async {
    for (final item in state.items) {
      if (item.status == DownloadStatus.completed &&
          _sameAutomaticTrack(item.track, track) &&
          item.filePath != null &&
          await savedDownloadFileAccessible(item.filePath!)) {
        return true;
      }
    }
    try {
      if (await DownloadFileInventory.containsAccessible(
        track,
        savedDownloadFileAccessible,
      )) {
        return true;
      }
    } catch (error) {
      _log.w('Could not verify download file inventory: $error');
    }
    if (!ref.mounted) return false;
    try {
      final history = ref.read(downloadHistoryProvider.notifier);
      final candidates = await history.findTrackCandidatesAsync(
        HistoryLookupRequest(
          spotifyId: track.id,
          isrc: track.isrc,
          trackName: track.name,
          artistName: track.artistName,
        ),
      );
      for (final match in candidates) {
        if (historyMatchesTrack(track, match) &&
            await savedDownloadFileAccessible(match.filePath)) {
          return true;
        }
      }
    } catch (error) {
      // An unavailable history or storage provider must not suppress a save.
      _log.w('Could not verify existing saved download: $error');
    }
    if (!ref.mounted ||
        !includeLocalLibrary ||
        !ref.read(settingsProvider).localLibraryEnabled) {
      return false;
    }
    try {
      final library = ref.read(localLibraryProvider.notifier);
      final isrc = track.isrc?.trim();
      if (isrc != null &&
          isrc.isNotEmpty &&
          await _isAccessibleLocalCopy(
            track,
            await library.getByIsrcAsync(isrc),
          )) {
        return true;
      }
      return await _isAccessibleLocalCopy(
        track,
        await library.findByTrackAndArtistAsync(track.name, track.artistName),
      );
    } catch (error) {
      _log.w('Could not verify existing local saved track: $error');
      return false;
    }
  }

  Future<bool> _isAccessibleLocalCopy(
    Track track,
    LocalLibraryItem? match,
  ) async {
    if (match == null) return false;
    final localIsrc = normalizeIsrc(match.isrc);
    final wantedIsrc = normalizeIsrc(track.isrc);
    final sameTrack = wantedIsrc.isNotEmpty && localIsrc.isNotEmpty
        ? wantedIsrc == localIsrc
        : track.name.trim().isNotEmpty &&
              track.artistName.trim().isNotEmpty &&
              match.trackName.trim().toLowerCase() ==
                  track.name.trim().toLowerCase() &&
              match.artistName.trim().toLowerCase() ==
                  track.artistName.trim().toLowerCase();
    return sameTrack && await savedDownloadFileAccessible(match.filePath);
  }

  /// Holds the batch against queue clears and observes only completions for
  /// submitted identities. Publish synchronously after the final probe.
  Future<void> checkDownloadBatch(
    List<Track> tracks, {
    required bool Function() isMounted,
    required Future<List<SavedDownloadPathStatus>> Function(
      bool Function() isCurrent,
    )
    check,
    required void Function(List<SavedDownloadPathStatus?>) publish,
  }) async {
    final clearGeneration = _clearGeneration;
    final downloadDirectory = ref.read(settingsProvider).downloadDirectory;
    bool isCurrent() =>
        ref.mounted && isMounted() && clearGeneration == _clearGeneration;
    final pending = tracks.map(_AutomaticSaveCheck.new).toList();
    _automaticSaveChecks.addAll(pending);
    try {
      final statuses = <SavedDownloadPathStatus?>[...await check(isCurrent)];
      if (!isCurrent()) return;
      // Probing one path can overlap another completion. Remove the current
      // worklist before each await and drain only newly reported completions.
      final completed = <String, Future<SavedDownloadPathStatus>>{};
      while (isCurrent()) {
        var hadNewPaths = false;
        for (var index = 0; index < pending.length; index++) {
          final item = pending[index];
          if (item.cancelled ||
              statuses[index] == SavedDownloadPathStatus.accessible) {
            continue;
          }
          while (item.hasUnexaminedPath && isCurrent() && !item.cancelled) {
            hadNewPaths = true;
            final path = item.completedPaths[item.examinedPaths++];
            final status = await completed.putIfAbsent(
              path,
              () => savedDownloadPathStatus(
                path,
                downloadDirectory: downloadDirectory,
              ),
            );
            if (status == SavedDownloadPathStatus.accessible) {
              statuses[index] = status;
              break;
            }
            if (status == SavedDownloadPathStatus.unavailable) {
              statuses[index] = status;
            }
          }
        }
        if (!hadNewPaths) break;
      }
      if (!isCurrent()) return;
      for (var index = 0; index < pending.length; index++) {
        if (pending[index].cancelled) statuses[index] = null;
      }
      publish(statuses);
    } catch (error) {
      if (isCurrent()) rethrow;
    } finally {
      final finished = pending.toSet();
      _automaticSaveChecks.removeWhere(finished.contains);
    }
  }

  /// The same request as an existing entry that already ended (failed,
  /// cancelled or completed and still listed). Enqueueing it again reuses
  /// that entry instead of adding a twin; see [_reuseEndedDownload].
  DownloadItem? _findEndedDownload(
    Iterable<DownloadItem> items,
    Track track,
    String normalizedService, {
    String? qualityOverride,
    required bool allowQualityVariants,
  }) {
    DownloadItem? found;
    for (final item in items) {
      if (item.status != DownloadStatus.failed &&
          item.status != DownloadStatus.skipped &&
          item.status != DownloadStatus.completed) {
        continue;
      }
      if (_matchesDownloadRequest(
        item,
        track,
        normalizedService,
        qualityOverride: qualityOverride,
        allowQualityVariants: allowQualityVariants,
      )) {
        // A completed entry wins; otherwise the most recent failure.
        if (found?.status != DownloadStatus.completed) found = item;
      }
    }
    return found;
  }

  /// Retries a failed/cancelled entry in place with the newest request (the
  /// provider or explicit quality may have changed) and dismisses its older
  /// failed twins. A completed entry is returned untouched: downloading it
  /// again takes an explicit re-download. Returns the reused id.
  String _reuseEndedDownload(
    DownloadItem ended,
    Track track,
    String normalizedService, {
    String? qualityOverride,
    required bool allowQualityVariants,
  }) {
    if (ended.status == DownloadStatus.completed) {
      _selectPermanentDownload(track, ended.id);
      return ended.id;
    }
    final twins = [
      for (final item in state.items)
        if (item.id != ended.id &&
            item.status == DownloadStatus.failed &&
            _matchesDownloadRequest(
              item,
              track,
              normalizedService,
              qualityOverride: qualityOverride,
              allowQualityVariants: allowQualityVariants,
            ))
          item.id,
    ];
    twins.forEach(dismissItem);
    final service = _normalizeQueuedService(normalizedService);
    if (ended.service != service ||
        (qualityOverride != null && ended.qualityOverride != qualityOverride)) {
      state = state.copyWith(
        items: [
          for (final item in state.items)
            if (item.id == ended.id)
              item.copyWith(service: service, qualityOverride: qualityOverride)
            else
              item,
        ],
      );
      _saveQueueToStorage();
    }
    unawaited(retryItem(ended.id));
    return ended.id;
  }

  /// Drops failed entries that repeat another entry of the same request.
  /// Nothing queued, active, completed or cancelled by the user is ever
  /// dropped (a cancelled row stays retryable), and no file is touched: only
  /// the redundant failed queue rows go away.
  List<DownloadItem> _withoutFailedDuplicates(
    List<DownloadItem> items,
    Set<String> droppedIds,
  ) {
    bool ended(DownloadItem item) => item.status == DownloadStatus.failed;
    bool same(DownloadItem a, DownloadItem b) =>
        _sameAutomaticTrack(a.track, b.track) &&
        a.networkDownloadFolder == b.networkDownloadFolder &&
        (!(a.preserveQualityVariant || b.preserveQualityVariant) ||
            (sameManifestQualityId(
                  a.qualityOverride ?? '',
                  b.qualityOverride ?? '',
                ) &&
                a.service.toLowerCase() == b.service.toLowerCase()));
    final kept = <DownloadItem>[];
    // Newest first, so the most recent failure is the one that stays.
    for (final item in items.reversed) {
      if (item.status == DownloadStatus.skipped) continue;
      final twin = kept.where((other) => same(other, item)).firstOrNull;
      if (twin == null) {
        kept.add(item);
      } else if (ended(item)) {
        droppedIds.add(item.id);
      } else if (ended(twin)) {
        droppedIds.add(twin.id);
        kept[kept.indexOf(twin)] = item;
      } else {
        kept.add(item);
      }
    }
    if (droppedIds.isEmpty) return items;
    return [
      for (final item in items)
        if (!droppedIds.contains(item.id)) item,
    ];
  }

  bool _matchesActiveDownload(
    DownloadItem item,
    Track track,
    String normalizedService, {
    String? qualityOverride,
    required bool allowQualityVariants,
  }) {
    if (item.status != DownloadStatus.queued &&
        item.status != DownloadStatus.downloading &&
        item.status != DownloadStatus.finalizing) {
      return false;
    }
    return _matchesDownloadRequest(
      item,
      track,
      normalizedService,
      qualityOverride: qualityOverride,
      allowQualityVariants: allowQualityVariants,
    );
  }

  bool _matchesDownloadRequest(
    DownloadItem item,
    Track track,
    String normalizedService, {
    String? qualityOverride,
    required bool allowQualityVariants,
  }) {
    if (!_sameAutomaticTrack(item.track, track)) return false;
    if (!allowQualityVariants) return true;
    return sameManifestQualityId(
          item.qualityOverride ?? '',
          qualityOverride ?? '',
        ) &&
        _normalizeQueuedService(item.service).toLowerCase() ==
            normalizedService.toLowerCase();
  }

  /// The origin to report for [item], inferring the playlist of songs queued
  /// before origins were stored.
  DownloadOrigin? _resolvedOrigin(DownloadItem item) {
    final stated = item.origin;
    if (stated != null && stated.collectionId != null) return stated;
    return inferDownloadOrigin(
      stated: stated,
      track: item.track,
      playlistName: item.playlistName,
      collections: ref.read(libraryCollectionsProvider),
      keptPlaylistIds: [
        for (final scope in ref.read(keepDownloadedProvider))
          if (keepScopePlaylistId(scope) case final id?) id,
      ],
    );
  }

  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) {
    final settings = ref.read(settingsProvider);
    final normalizedService = settings.allowQualityVariants
        ? _normalizeQueuedService(service)
        : null;
    for (final item in state.items) {
      if (_matchesActiveDownload(
        item,
        track,
        normalizedService ?? service,
        qualityOverride: qualityOverride,
        allowQualityVariants: settings.allowQualityVariants,
      )) {
        _selectPermanentDownload(track, item.id);
        return item.id;
      }
    }
    final ended = _findEndedDownload(
      state.items,
      track,
      normalizedService ?? service,
      qualityOverride: qualityOverride,
      allowQualityVariants: settings.allowQualityVariants,
    );
    if (ended != null) {
      updateSettings(settings);
      return _reuseEndedDownload(
        ended,
        track,
        normalizedService ?? service,
        qualityOverride: qualityOverride,
        allowQualityVariants: settings.allowQualityVariants,
      );
    }
    updateSettings(settings);

    final takenIds = state.items.map((item) => item.id).toSet();
    final id = _newQueueItemId(track, takenIds: takenIds);
    final item = DownloadItem(
      id: id,
      track: queuedDownloadTrack(track),
      service: normalizedService ?? _normalizeQueuedService(service),
      createdAt: DateTime.now(),
      qualityOverride: qualityOverride,
      playlistName: playlistName,
      playlistPosition: playlistPosition,
      preserveQualityVariant: settings.allowQualityVariants,
      networkDownloadFolder: settings.networkDownloadFolder,
      origin:
          origin ??
          defaultDownloadOrigin(
            playlistName: playlistName,
            multipleTracks: false,
          ),
    );

    state = state.copyWith(items: [...state.items, item]);
    _selectPermanentDownload(track, id);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }

    return id;
  }

  /// Downloads [track] again at [qualityId] through the ordinary queue and,
  /// only once the new file is finished and verified, replaces the previous
  /// one: [onReady] may move playback onto it first, then the previous file
  /// and its history row go away and the new file takes the previous file's
  /// name, leaving a single file. When the new file is not acceptable it is
  /// deleted and the previous file is kept.
  Future<QualityReplaceResult> replaceTrackQuality(
    Track track,
    String service,
    String qualityId, {
    required String previousPath,
    required String previousHistoryId,
    Future<bool> Function(String newPath)? onReady,
    Duration timeout = const Duration(minutes: 30),
    Future<int?> Function(String path)? measureDuration,
  }) async {
    final settings = ref.read(settingsProvider);
    final takenIds = state.items.map((item) => item.id).toSet();
    final id = _newQueueItemId(track, takenIds: takenIds);
    final item = DownloadItem(
      id: id,
      track: queuedDownloadTrack(track),
      service: _normalizeQueuedService(service),
      createdAt: DateTime.now(),
      qualityOverride: qualityId,
      preserveQualityVariant: true,
      networkDownloadFolder: settings.networkDownloadFolder,
    );
    final waiter = Completer<DownloadItem?>();
    _replaceWaiters[id] = waiter;
    debugPrint(
      'replace: start kind=${_replacePathKind(previousPath)} '
      'service=${item.service} quality=$qualityId '
      'queue=${state.items.length} processing=${state.isProcessing}',
    );
    updateSettings(settings);
    state = state.copyWith(items: [...state.items, item]);
    _saveQueueToStorage();
    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
    var timedOut = false;
    final done = await waiter.future.timeout(
      timeout,
      onTimeout: () {
        timedOut = true;
        return null;
      },
    );
    _replaceWaiters.remove(id);
    final summary = _failureSummaries.remove(id);
    if (!ref.mounted) {
      return const QualityReplaceResult.failed(QualityReplaceFailure.cancelled);
    }
    if (done == null) {
      debugPrint('replace: ended timeout=$timedOut');
      return QualityReplaceResult.failed(
        timedOut
            ? QualityReplaceFailure.timedOut
            : QualityReplaceFailure.cancelled,
      );
    }
    if (done.status == DownloadStatus.failed) {
      debugPrint(
        'replace: ended failed type=${done.errorType?.name ?? 'none'} '
        '${summary ?? 'no-summary'}',
      );
      return QualityReplaceResult.failed(
        QualityReplaceFailure.downloadFailed,
        detail: shortFailureCause(done.error),
        errorType: done.errorType,
        summary: summary,
      );
    }
    if (done.status != DownloadStatus.completed) {
      debugPrint('replace: ended status=${done.status.name}');
      return const QualityReplaceResult.failed(QualityReplaceFailure.cancelled);
    }
    final newPath = done.filePath;
    if (newPath == null || newPath.trim().isEmpty) {
      debugPrint('replace: ended no-path');
      return const QualityReplaceResult.failed(QualityReplaceFailure.noFile);
    }
    if (physicalFilePathsMatch(newPath, previousPath)) {
      debugPrint('replace: ended same-file');
      return const QualityReplaceResult.failed(QualityReplaceFailure.sameFile);
    }
    debugPrint('replace: ready kind=${_replacePathKind(newPath)}');

    final rejected = await _rejectionFor(
      track,
      previousPath,
      newPath,
      measureDuration ?? _measureDurationSeconds,
    );
    if (rejected != null) {
      debugPrint('replace: rejected reason=${rejected.name}');
      await _discardReplacement(newPath);
      return QualityReplaceResult.failed(rejected);
    }

    var switched = true;
    if (onReady != null) {
      try {
        switched = await onReady(newPath);
      } catch (_) {
        switched = false;
      }
      debugPrint('replace: switch=${switched ? 'ok' : 'false'}');
    }

    final removedPrevious = await deleteFile(previousPath);
    debugPrint('replace: deleted-old=$removedPrevious');
    if (removedPrevious) {
      if (previousHistoryId.isNotEmpty) {
        await ref
            .read(downloadHistoryProvider.notifier)
            .removeFromHistory(previousHistoryId);
      }
      try {
        await removeDeletedLibraryFileEntries(ref.container, [previousPath]);
      } catch (_) {}
    }

    var finalPath = newPath;
    if (removedPrevious) {
      finalPath = await _takePreviousName(previousPath, newPath) ?? newPath;
    }
    if (finalPath != newPath) {
      debugPrint('replace: renamed=true');
      await _safeRelocate(newPath, finalPath);
    } else if (!switched && onReady != null) {
      await _safeRelocate(previousPath, finalPath);
    }
    return QualityReplaceResult.success(
      finalPath,
      switched: switched,
      removedPrevious: removedPrevious,
    );
  }

  /// Cancels the downloads started by [replaceTrackQuality] for [track]. The
  /// pending replacement ends as cancelled and the previous file is kept.
  void cancelTrackQualityReplacement(Track track) {
    final key = trackCollectionKey(track);
    for (final id in _replaceWaiters.keys.toList()) {
      final item = _findItemById(id);
      if (item == null) {
        _replaceWaiters.remove(id)?.complete(null);
      } else if (trackCollectionKey(item.track) == key) {
        cancelItem(id);
      }
    }
  }

  String _replacePathKind(String path) => path.startsWith('content://')
      ? 'saf'
      : path.startsWith('network://')
      ? 'network'
      : 'path';

  Future<int?> _measureDurationSeconds(String path) async {
    try {
      final metadata = await PlatformBridge.readFileMetadata(path);
      final value = metadata['duration'];
      return value is num && value > 0 ? value.round() : null;
    } catch (_) {
      return null;
    }
  }

  Future<QualityReplaceFailure?> _rejectionFor(
    Track track,
    String previousPath,
    String newPath,
    Future<int?> Function(String path) measure,
  ) async {
    final stat = await fileStat(newPath);
    if (stat == null) return QualityReplaceFailure.noFile;
    final size = stat.size;
    if (size != null && size <= 0) return QualityReplaceFailure.emptyFile;
    final actual = await measure(newPath);
    if (actual == null || actual <= 0) return null;
    final expected =
        await measure(previousPath) ?? (track.duration > 0 ? track.duration : 0);
    if (expected <= 0) return null;
    final tolerance = max(3.0, expected * 0.015);
    return (actual - expected).abs() > tolerance
        ? QualityReplaceFailure.durationMismatch
        : null;
  }

  Future<void> _discardReplacement(String newPath) async {
    try {
      final history = ref.read(downloadHistoryProvider.notifier);
      final row = await history.getByFilePathAsync(newPath);
      await deleteFile(newPath);
      if (row != null) await history.removeFromHistory(row.id);
    } catch (_) {
      await deleteFile(newPath);
    }
    try {
      await removeDeletedLibraryFileEntries(ref.container, [newPath]);
    } catch (_) {}
  }

  Future<String?> _takePreviousName(String previousPath, String newPath) async {
    if (isContentUri(previousPath) ||
        isContentUri(newPath) ||
        previousPath.startsWith('network://') ||
        newPath.startsWith('network://')) {
      return null;
    }
    if (!p.equals(p.dirname(previousPath), p.dirname(newPath))) return null;
    final target = p.join(
      p.dirname(newPath),
      '${p.basenameWithoutExtension(previousPath)}${p.extension(newPath)}',
    );
    if (p.equals(target, newPath)) return null;
    try {
      if (await File(target).exists() && !await deleteFile(target)) return null;
      await File(newPath).rename(target);
    } catch (_) {
      return null;
    }
    try {
      final history = ref.read(downloadHistoryProvider.notifier);
      final row = await history.getByFilePathAsync(newPath);
      if (row != null) {
        await history.addToHistory(
          row.copyWith(filePath: target),
          preserveTrackVariant: true,
        );
      }
      await removeDeletedLibraryFileEntries(ref.container, [newPath]);
    } catch (_) {}
    return target;
  }

  Future<void> _safeRelocate(String from, String to) async {
    try {
      await notifyPlaybackSourceRelocated(from, to);
    } catch (_) {}
  }

  /// Enqueues a selection without album-batch normalization or naming rules.
  /// Equivalent to separate [addToQueue] calls, with one queue publication.
  void addIndividualTracksToQueue(List<Track> tracks, String service) {
    _enqueueIndividualTracks(tracks, service);
  }

  int _enqueueIndividualTracks(
    List<Track> tracks,
    String service, {
    bool? allowQualityVariants,
  }) {
    if (tracks.isEmpty) return 0;
    final selectionStart = _pendingSelectionEvents.length;
    final settings = ref.read(settingsProvider);
    final preserveVariants =
        allowQualityVariants ?? settings.allowQualityVariants;
    final normalizedService = _normalizeQueuedService(service);
    final takenIds = state.items.map((item) => item.id).toSet();
    final newItems = <DownloadItem>[];
    for (final track in tracks) {
      final existing = [...state.items, ...newItems]
          .where(
            (item) => _matchesActiveDownload(
              item,
              track,
              normalizedService,
              allowQualityVariants: preserveVariants,
            ),
          )
          .firstOrNull;
      if (existing != null) {
        _selectPermanentDownload(track, existing.id);
        continue;
      }
      final ended = _findEndedDownload(
        state.items,
        track,
        normalizedService,
        allowQualityVariants: preserveVariants,
      );
      if (ended != null) {
        _reuseEndedDownload(
          ended,
          track,
          normalizedService,
          allowQualityVariants: preserveVariants,
        );
        continue;
      }
      final id = _newQueueItemId(track, takenIds: takenIds);
      takenIds.add(id);
      _selectPermanentDownload(track, id);
      newItems.add(
        DownloadItem(
          id: id,
          track: queuedDownloadTrack(track),
          service: normalizedService,
          createdAt: DateTime.now(),
          preserveQualityVariant: preserveVariants,
          networkDownloadFolder: settings.networkDownloadFolder,
          origin: DownloadOrigin.track,
        ),
      );
    }
    state = _withSettings(settings, items: [...state.items, ...newItems]);
    _freezeSelectionEventsSince(selectionStart);
    _saveQueueToStorage();
    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
    return newItems.length;
  }

  List<String> addMultipleToQueue(
    List<Track> tracks,
    String service, {
    String? qualityOverride,
    bool? allowQualityVariants,
    String? playlistName,
    List<int?>? playlistPositions,
    DownloadOrigin? origin,
  }) {
    return addBatchesToQueue(
      [
        DownloadQueueBatch(
          tracks: tracks,
          playlistName: playlistName,
          playlistPositions: playlistPositions,
          origin: origin,
        ),
      ],
      service,
      qualityOverride: qualityOverride,
      allowQualityVariants: allowQualityVariants,
    );
  }

  /// Publishes several independent album/playlist batches together. Keep each
  /// group's artist normalization, batch flag and playlist positions separate.
  /// Returns only newly admitted queue item IDs, not preexisting downloads.
  List<String> addBatchesToQueue(
    List<DownloadQueueBatch> batches,
    String service, {
    String? qualityOverride,
    bool? allowQualityVariants,
  }) {
    if (batches.isEmpty) return const [];
    final selectionStart = _pendingSelectionEvents.length;
    final settings = ref.read(settingsProvider);
    final preserveVariants =
        allowQualityVariants ?? settings.allowQualityVariants;
    String? normalizedService;
    final takenIds = state.items.map((item) => item.id).toSet();
    final newItems = <DownloadItem>[];
    for (final batch in batches) {
      final playlistName = batch.playlistName;
      final playlistPositions = batch.playlistPositions;
      final shouldAssignPlaylistPositions =
          playlistName != null && playlistName.trim().isNotEmpty;
      final normalizedTracks = normalizeBatchAlbumArtists(batch.tracks);
      final fromBatch = normalizedTracks.length > 1;
      final origin =
          batch.origin ??
          defaultDownloadOrigin(
            playlistName: playlistName,
            multipleTracks: fromBatch,
          );
      for (var index = 0; index < normalizedTracks.length; index++) {
        final track = normalizedTracks[index];
        final targetService = preserveVariants
            ? normalizedService ??= _normalizeQueuedService(service)
            : service;
        final existing = [...state.items, ...newItems]
            .where(
              (item) => _matchesActiveDownload(
                item,
                track,
                targetService,
                qualityOverride: qualityOverride,
                allowQualityVariants: preserveVariants,
              ),
            )
            .firstOrNull;
        if (existing != null) {
          _selectPermanentDownload(track, existing.id);
          continue;
        }
        final ended = _findEndedDownload(
          state.items,
          track,
          targetService,
          qualityOverride: qualityOverride,
          allowQualityVariants: preserveVariants,
        );
        if (ended != null) {
          _reuseEndedDownload(
            ended,
            track,
            targetService,
            qualityOverride: qualityOverride,
            allowQualityVariants: preserveVariants,
          );
          continue;
        }
        final explicitPosition =
            playlistPositions != null &&
                index < playlistPositions.length &&
                (playlistPositions[index] ?? 0) > 0
            ? playlistPositions[index]
            : null;
        final id = _newQueueItemId(track, takenIds: takenIds);
        takenIds.add(id);
        _selectPermanentDownload(track, id);
        newItems.add(
          DownloadItem(
            id: id,
            track: queuedDownloadTrack(track),
            service: normalizedService ??= _normalizeQueuedService(service),
            createdAt: DateTime.now(),
            qualityOverride: qualityOverride,
            playlistName: playlistName,
            playlistPosition:
                explicitPosition ??
                (shouldAssignPlaylistPositions ? index + 1 : null),
            fromBatch: fromBatch,
            preserveQualityVariant: preserveVariants,
            networkDownloadFolder: settings.networkDownloadFolder,
            origin: origin,
          ),
        );
      }
    }

    state = _withSettings(settings, items: [...state.items, ...newItems]);
    _freezeSelectionEventsSince(selectionStart);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
    return List.unmodifiable(newItems.map((item) => item.id));
  }

  void updateItemStatus(
    String id,
    DownloadStatus status, {
    double? progress,
    double? speedMBps,
    String? filePath,
    String? error,
    DownloadErrorType? errorType,
    String? preparationStage,
    int? bytesReceived,
    int? bytesTotal,
  }) {
    final items = state.items;
    final index = state.lookup.indexByItemId[id] ?? -1;
    if (index == -1) return;

    final current = items[index];
    final next = current.copyWith(
      status: status,
      progress: progress ?? current.progress,
      speedMBps: speedMBps ?? current.speedMBps,
      filePath: filePath,
      error: error,
      errorType: errorType,
      preparationStage: preparationStage,
      bytesReceived: bytesReceived,
      bytesTotal: bytesTotal,
    );

    if (current.status == next.status &&
        current.progress == next.progress &&
        current.speedMBps == next.speedMBps &&
        current.filePath == next.filePath &&
        current.error == next.error &&
        current.errorType == next.errorType &&
        current.preparationStage == next.preparationStage &&
        current.bytesReceived == next.bytesReceived &&
        current.bytesTotal == next.bytesTotal) {
      return;
    }

    if (status == DownloadStatus.completed &&
        current.status != DownloadStatus.completed &&
        next.filePath != null &&
        next.filePath!.isNotEmpty) {
      AnonymousMetrics.recordDownloadCompleted();
      if (_selectionBarrier) {
        _deferredReady[next.id] = next;
      } else if (_isSelectedPermanentDownload(next)) {
        unawaited(_notifyReady(next.track, next.filePath!));
      }
      for (final check in _automaticSaveChecks) {
        if (_sameAutomaticTrack(check.track, next.track)) {
          check.completedPaths.add(next.filePath!);
        }
      }
    }
    state = state.withItemReplacements({index: next});
    if (status == DownloadStatus.completed ||
        status == DownloadStatus.failed ||
        status == DownloadStatus.skipped) {
      _replaceWaiters.remove(id)?.complete(next);
    }

    if (Platform.isAndroid && status == DownloadStatus.finalizing) {
      PlatformBridge.clearItemProgress(id).catchError((_) {});
      final queueCount = state.lookup.queuedCount;
      _maybeUpdateAndroidDownloadService(
        trackName: next.track.name,
        artistName: _notificationService.embeddingMetadataLabel,
        progress: 100,
        total: 100,
        queueCount: queueCount,
        status: 'finalizing',
      );
    }

    if (status == DownloadStatus.completed ||
        status == DownloadStatus.failed ||
        status == DownloadStatus.skipped) {
      _saveQueueToStorage();
    }
  }

  void _recordFailedDownload(
    String id, {
    required String error,
    required DownloadErrorType errorType,
    Object? diagnosticStage,
    Object? diagnosticErrorType,
    Object? diagnosticCause,
    Object? diagnosticProvider,
    Object? diagnosticProviderAttempts,
    bool recordDiagnostic = true,
    bool countInSession = true,
  }) {
    final priorItem = _findItemById(id);
    final priorStatus = priorItem?.status;
    final cancelled = _isLocallyCancelled(id, item: priorItem);
    if (_replaceWaiters.containsKey(id)) {
      _failureSummaries[id] = BugLog.downloadFailureSummary(
        stage: diagnosticStage,
        errorType: diagnosticErrorType,
        cause: diagnosticCause,
        provider: diagnosticProvider,
        providerAttempts: diagnosticProviderAttempts,
      );
    }
    updateItemStatus(
      id,
      DownloadStatus.failed,
      error:
          typedDownloadFailureMessage(diagnosticErrorType, errorType) ?? error,
      errorType: errorType,
    );
    if (countInSession) _failedInSession++;
    if (recordDiagnostic &&
        !cancelled &&
        priorStatus != null &&
        priorStatus != DownloadStatus.failed &&
        priorStatus != DownloadStatus.skipped &&
        priorStatus != DownloadStatus.completed &&
        errorType != DownloadErrorType.verificationRequired) {
      _recordDownloadFailureDiagnostic(
        errorType: errorType,
        stage: diagnosticStage,
        diagnosticErrorType: diagnosticErrorType,
        cause: diagnosticCause,
        provider: diagnosticProvider,
        providerAttempts: diagnosticProviderAttempts,
      );
    }
  }

  void _recordDownloadFailureDiagnostic({
    required DownloadErrorType? errorType,
    Object? stage,
    Object? diagnosticErrorType,
    Object? cause,
    Object? provider,
    Object? providerAttempts,
  }) {
    unawaited(
      BugLog.instance.recordTerminalDownloadFailure(
        stage: stage,
        errorType: switch (errorType) {
          DownloadErrorType.verificationRequired => 'verification_required',
          DownloadErrorType.rateLimit => 'rate_limit',
          _ =>
            diagnosticErrorType ??
                switch (errorType) {
                  DownloadErrorType.notFound => 'not_found',
                  DownloadErrorType.network => 'network',
                  DownloadErrorType.permission => 'permission',
                  _ => 'unknown',
                },
        },
        cause: cause,
        provider: provider,
        providerAttempts: providerAttempts,
      ),
    );
  }

  /// Fails requests that have not started when shared queue setup cannot
  /// continue. Active and terminal items keep their current state.
  void failQueuedDownloads({
    required String error,
    DownloadErrorType? errorType,
  }) {
    final items = state.items;
    final changes = <int, DownloadItem>{};
    for (var index = 0; index < items.length; index++) {
      final item = items[index];
      if (item.status != DownloadStatus.queued) continue;
      changes[index] = item.copyWith(
        status: DownloadStatus.failed,
        filePath: null,
        error: error,
        errorType: errorType,
      );
    }
    if (changes.isEmpty) return;

    state = state.withItemReplacements(changes);
    _saveQueueToStorage();
    for (final item in changes.values) {
      if (_isLocallyCancelled(item.id, item: item)) continue;
      _recordDownloadFailureDiagnostic(
        errorType: errorType,
        stage: 'preparing_output',
      );
    }
  }

  @visibleForTesting
  String relativeOutputDirFor(
    Track track,
    AppSettings settings, {
    String? customFolderPath,
    String? playlistName,
  }) => _buildRelativeOutputDir(
    track,
    settings,
    customFolderPath: customFolderPath,
    playlistName: playlistName,
  );

  DownloadItem? _findItemById(String id) {
    return state.lookup.byItemId[id];
  }

  bool _isLocallyCancelled(String id, {DownloadItem? item}) {
    if (_locallyCancelledItemIds.contains(id)) return true;
    final resolved = item ?? _findItemById(id);
    return resolved?.status == DownloadStatus.skipped;
  }

  bool _isPausePending(String id) => _pausePendingItemIds.contains(id);

  void _requeueItemForPause(String id) {
    final updatedItems = state.items
        .map((item) {
          if (item.id != id) return item;
          if (item.status == DownloadStatus.completed ||
              item.status == DownloadStatus.failed ||
              item.status == DownloadStatus.skipped) {
            return item;
          }
          return item.resetToQueued();
        })
        .toList(growable: false);

    final currentDownload = state.currentDownload?.id == id
        ? null
        : state.currentDownload;
    state = state.copyWith(
      items: updatedItems,
      currentDownload: currentDownload,
    );
  }

  void _requestNativeCancel(String id) {
    _verificationWaitCoordinator.cancelItem(id);
    _rateLimitBackoff.cancelItem(id);
    _cancelProviderTurnWait(id);
    final previous = _nativeCancelRequests[id] ?? Future<void>.value();
    final request = previous
        .then((_) => PlatformBridge.cancelDownload(id))
        .catchError((Object error) => _log.w('Could not cancel download'));
    _nativeCancelRequests[id] = request;
    unawaited(
      request.whenComplete(() {
        if (identical(_nativeCancelRequests[id], request)) {
          _nativeCancelRequests.remove(id);
        }
      }),
    );
    PlatformBridge.clearItemProgress(id).catchError((_) {});
  }

  Future<void> _finishPausedDownload(String id) async {
    try {
      final cancellation = _nativeCancelRequests[id];
      if (cancellation != null) await cancellation;
      // Pausing before the backend acquires a lease, or after it releases
      // one, leaves an idle cancel flag. Reset it only after this attempt and
      // its cancellation have finished, before the scheduler can restart it.
      if (ref.mounted &&
          _findItemById(id) != null &&
          !_isLocallyCancelled(id)) {
        await PlatformBridge.resetDownloadCancel(id);
      }
    } catch (_) {
      _log.w('Could not reset paused download');
    } finally {
      _pausePendingItemIds.remove(id);
    }
  }

  void _cancelPendingSaveChecks(Track track) {
    for (final check in _automaticSaveChecks) {
      if (_sameAutomaticTrack(check.track, track)) check.cancelled = true;
    }
  }

  void cancelItem(String id) {
    _deferredReady.remove(id);
    final item = _findItemById(id);
    final selectionStart = _pendingSelectionEvents.length;
    if (item != null) {
      _cancelPendingSaveChecks(item.track);
      final selectedId = _latestSelection(item.track)?.id;
      if (selectedId == id) _recordSelectionEvent(item.track, null);
    }
    _pausePendingItemIds.remove(id);
    _locallyCancelledItemIds.add(id);
    updateItemStatus(id, DownloadStatus.skipped);
    _freezeSelectionEventsSince(selectionStart);
    _reserveNativeDiscard(selectionStart, all: false, ids: {id});
    _requestNativeCancel(id);
  }

  void dismissItem(String id) {
    _deferredReady.remove(id);
    final item = _findItemById(id);
    if (item == null) return;
    final selectionStart = _pendingSelectionEvents.length;

    final isActive =
        item.status == DownloadStatus.queued ||
        item.status == DownloadStatus.downloading ||
        item.status == DownloadStatus.finalizing;
    final wasFailed =
        item.status == DownloadStatus.failed ||
        item.status == DownloadStatus.skipped;

    if (isActive) {
      _cancelPendingSaveChecks(item.track);
      _pausePendingItemIds.remove(id);
      _locallyCancelledItemIds.add(id);
      _requestNativeCancel(id);
    } else {
      _locallyCancelledItemIds.remove(id);
    }

    if (item.status != DownloadStatus.completed) {
      _purgeAlbumRgEntry(item.track);
    }

    final items = state.items.where((entry) => entry.id != id).toList();
    final currentDownload = state.currentDownload?.id == id
        ? null
        : state.currentDownload;
    state = state.copyWith(items: items, currentDownload: currentDownload);
    _reserveNativeDiscard(selectionStart, all: false, ids: {id});
    _prunePermanentSelections({id});
    _saveQueueToStorage();

    // Dismissing a failed/skipped item may unblock album RG.
    if (wasFailed) {
      _retriggerAlbumRgChecks();
    }
    if (item.status != DownloadStatus.downloading &&
        item.status != DownloadStatus.finalizing &&
        item.networkDownloadFolder.isNotEmpty) {
      unawaited(
        NetworkDownloadStaging.instance.discard(id).catchError((Object e) {
          _log.w('Could not remove network staging: $e');
        }),
      );
    }
  }

  void clearAll() {
    final selectionStart = _pendingSelectionEvents.length;
    if (!_queueStorageReady) _restoreClearBoundary ??= selectionStart;
    final nativeRunNeedsStop =
        _hasActiveAndroidNativeWorker || _nativeOwnershipUncertain;
    if (nativeRunNeedsStop) {
      _nativeOwnershipUncertain = true;
    }
    _clearGeneration++;
    _deferredReady.clear();
    for (final item in state.items) {
      _recordSelectionEvent(item.track, null);
    }
    if (!_queueStorageReady)
      _restoreClearEventIndex = _pendingSelectionEvents.length;
    for (final item in state.items) {
      if (item.networkDownloadFolder.isNotEmpty &&
          item.status != DownloadStatus.downloading &&
          item.status != DownloadStatus.finalizing) {
        unawaited(
          NetworkDownloadStaging.instance.discard(item.id).catchError((
            Object e,
          ) {
            _log.w('Could not clear network staging: $e');
          }),
        );
      }
    }
    final wasProcessing = state.isProcessing;
    final activeIds = state.items
        .where(
          (item) =>
              item.status == DownloadStatus.queued ||
              item.status == DownloadStatus.downloading ||
              item.status == DownloadStatus.finalizing,
        )
        .map((item) => item.id)
        .toList(growable: false);

    if (activeIds.isNotEmpty) {
      _pausePendingItemIds.addAll(activeIds);
      _locallyCancelledItemIds.addAll(activeIds);
      for (final id in activeIds) {
        _verificationWaitCoordinator.cancelItem(id);
        _rateLimitBackoff.cancelItem(id);
        _cancelProviderTurnWait(id);
      }
      unawaited(PlatformBridge.cancelDownloads(activeIds));
    }

    state = state.copyWith(
      items: [],
      isPaused: nativeRunNeedsStop,
      currentDownload: null,
      nativeRecoveryRequired: nativeRunNeedsStop ? true : null,
    );
    _freezeSelectionEventsSince(selectionStart);
    _reserveNativeDiscard(selectionStart, all: true);
    if (_restoreClearEventIndex != null &&
        _pendingSelectionEvents.length > selectionStart &&
        _isDiscardEvent(_pendingSelectionEvents[selectionStart])) {
      _restoreClearEventIndex = _restoreClearEventIndex! + 1;
    }
    _persistUserPausedQueue(false);
    if (nativeRunNeedsStop) {
      unawaited(_retryUncertainNativeWorkerCancellation());
    } else if (_isAndroidNativeWorker && _queueStartupPending) {
      PlatformBridge.cancelNativeDownloadWorker().catchError((_) {});
    }
    _notificationService.cancelDownloadNotification();
    _saveQueueToStorage();
    _albumRgData.clear();
    if (!wasProcessing) {
      _locallyCancelledItemIds.clear();
    }
    _pausePendingItemIds.clear();
  }

  void pauseQueue({
    bool persistAcrossRestarts = true,
    Set<String> nativeCancelledItemIds = const {},
  }) {
    _nativeResumeGeneration++;
    if (_queueStartupPending) {
      _startupPausedOverride = true;
      if (!state.isProcessing) {
        state = state.copyWith(isPaused: true, currentDownload: null);
        if (persistAcrossRestarts) _persistUserPausedQueue(true);
        return;
      }
    }
    if (state.isProcessing && !state.isPaused) {
      final nativeWorkerActive = _hasActiveAndroidNativeWorker;
      if (nativeWorkerActive) {
        PlatformBridge.pauseNativeDownloadWorker().catchError((_) {});
      }
      final activeIds = state.items
          .where(
            (item) =>
                item.status == DownloadStatus.downloading ||
                item.status == DownloadStatus.finalizing,
          )
          .map((item) => item.id)
          .toSet();

      if (activeIds.isNotEmpty) {
        _pausePendingItemIds.addAll(activeIds);
        for (final id in activeIds) {
          if (nativeWorkerActive || nativeCancelledItemIds.contains(id)) {
            // The native worker or iOS expiry already cancelled this attempt.
            // A second cancel can arrive after it unwinds and leave a flag
            // that aborts the resumed download before it starts.
            _verificationWaitCoordinator.cancelItem(id);
            _rateLimitBackoff.cancelItem(id);
            _cancelProviderTurnWait(id);
          } else {
            _requestNativeCancel(id);
          }
          _requeueItemForPause(id);
        }
      }

      state = state.copyWith(isPaused: true, currentDownload: null);
      if (persistAcrossRestarts) {
        _persistUserPausedQueue(true);
      }
      _notificationService.cancelDownloadNotification();
      _log.i('Queue paused');
    }
  }

  void resumeQueue() {
    if (_nativeOwnershipUncertain) {
      unawaited(_retryUncertainNativeWorkerCancellation());
      return;
    }
    if (_queueStartupPending || !_queueStorageReady) {
      _startupPausedOverride = false;
      _persistUserPausedQueue(false);
      _startQueueRestore();
    }
    if (state.isPaused) {
      _clearAutoPause();
      if (_hasActiveAndroidNativeWorker) {
        final generation = ++_nativeResumeGeneration;
        scheduleMicrotask(() => _resumeNativeWorkerAfterSelection(generation));
      }
      state = state.copyWith(isPaused: false);
      _persistUserPausedQueue(false);
      _log.i('Queue resumed');
      if (state.queuedCount > 0 && !state.isProcessing) {
        Future.microtask(() => _processQueue());
      }
    }
  }

  Future<void> _resumeNativeWorkerAfterSelection(int generation) async {
    while ((_selectionBarrier || !_queueStorageReady || _queueStartupPending) &&
        ref.mounted &&
        generation == _nativeResumeGeneration) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!ref.mounted ||
        state.isPaused ||
        generation != _nativeResumeGeneration ||
        !_hasActiveAndroidNativeWorker)
      return;
    await PlatformBridge.resumeNativeDownloadWorker().catchError((_) {});
  }

  Future<void> _retryUncertainNativeWorkerCancellation() async {
    if (_nativeCancellationRetryRunning) return;
    _nativeCancellationRetryRunning = true;
    try {
      final runId = _activeNativeWorkerRunId;
      if (runId == null) return;
      final snapshot = await _cancelAndConfirmNativeWorker(runId);
      if (snapshot == null) return;
      if (!ref.mounted) return;
      if (!await _reconcileStoppedNativeSnapshot(
        snapshot,
        {},
        {},
        ref.read(settingsProvider),
        _clearGeneration,
      )) {
        _log.w('Native worker stopped; final snapshot is not yet reconcilable');
        return;
      }
      if (!ref.mounted) return;
      await _clearNativeWorkerRunId(runId);
      if (!ref.mounted) return;
      _nativeOwnershipUncertain = false;
      state = state.copyWith(
        isProcessing: false,
        isPaused: true,
        nativeRecoveryRequired: false,
      );
      resumeQueue();
    } catch (error) {
      _log.w('Could not stop native worker; queue remains paused: $error');
    } finally {
      _nativeCancellationRetryRunning = false;
    }
  }

  void togglePause() {
    if (state.isPaused) {
      resumeQueue();
    } else {
      pauseQueue();
    }
  }

  Future<void> retryItem(String id, {bool selectForPlayback = true}) async {
    final item = state.items.where((i) => i.id == id).firstOrNull;
    if (item == null) {
      _log.w('Retry requested for an unavailable item');
      return;
    }

    if (item.status != DownloadStatus.failed &&
        item.status != DownloadStatus.skipped) {
      _log.w('retryItem: Item status is ${item.status}, not retrying');
      return;
    }

    if (!_retryingItemIds.add(id)) return;
    String? selectionEventId;
    final retrySnapshot = List<DownloadItem>.of(state.items);
    if (selectForPlayback) {
      _selectionDeferrals++;
      selectionEventId = _selectPermanentDownload(item.track, id);
    }
    try {
      await _retryItem(item);
    } finally {
      _retryingItemIds.remove(id);
      if (selectionEventId != null) {
        _finishRetrySelection(id, selectionEventId, retrySnapshot);
      }
    }
  }

  Future<void> retryItemWithQuality(String id, String quality) async {
    final item = _findItemById(id);
    if (item == null || item.status != DownloadStatus.failed) return;
    final resolvedQuality = _resolveDeclaredDownloadQuality(
      item.service,
      quality,
    );
    if (resolvedQuality == null) return;
    _selectionDeferrals++;
    final selectionEventId = _selectPermanentDownload(item.track, id);
    state = state.copyWith(
      items: [
        for (final current in state.items)
          if (current.id == id)
            current.copyWith(qualityOverride: resolvedQuality)
          else
            current,
      ],
    );
    _saveQueueToStorage();
    final retrySnapshot = List<DownloadItem>.of(state.items);
    try {
      await retryItem(id, selectForPlayback: false);
    } finally {
      _finishRetrySelection(id, selectionEventId, retrySnapshot);
    }
  }

  void _finishRetrySelection(
    String id,
    String selectionEventId,
    List<DownloadItem> retrySnapshot,
  ) {
    _selectionDeferrals--;
    if (!ref.mounted) return;
    final current = _findItemById(id);
    if (current != null && current.status == DownloadStatus.queued) {
      _selectionSnapshots[selectionEventId] = [
        for (final old in retrySnapshot)
          if (old.id == id) current else old,
      ];
    } else {
      _dropSelectionEvent(selectionEventId);
    }
    scheduleMicrotask(_drainSelectionEvents);
  }

  Future<void> _retryItem(DownloadItem item) async {
    final id = item.id;
    _log.i('Retrying download');
    await _waitForCancelledDownloadAttempts([id]);
    if (!ref.mounted) return;
    final pending = _findItemById(id);
    if (pending == null ||
        (pending.status != DownloadStatus.failed &&
            pending.status != DownloadStatus.skipped)) {
      return;
    }
    // A cancel issued while the item never started leaves a pre-registered
    // flag in the backend that the next attempt would consume and abort
    // instantly; the user asked for a retry, so drop it first.
    try {
      await PlatformBridge.resetDownloadCancel(id);
    } catch (_) {
      _log.w('Failed to reset download cancellation flag');
      if (!ref.mounted) return;
      final current = _findItemById(id);
      if (current != null &&
          (current.status == DownloadStatus.failed ||
              current.status == DownloadStatus.skipped)) {
        state = state.copyWith(manualRetryFailure: Object());
      }
      return;
    }
    if (!ref.mounted) return;
    final current = state.items.where((i) => i.id == id).firstOrNull;
    if (current == null ||
        (current.status != DownloadStatus.failed &&
            current.status != DownloadStatus.skipped)) {
      return;
    }
    _locallyCancelledItemIds.remove(id);
    _verificationRetryGuard.clearItem(id);
    _rateLimitRetriedItemIds.remove(id);

    // Purge stale ReplayGain entry for this track so a re-scan doesn't
    // produce duplicate entries that bias album gain.
    _purgeAlbumRgEntry(item.track);

    final items = state.items.map((i) {
      if (i.id == id) {
        return i.resetToQueued().copyWith(
          error: null,
          errorType: null,
          filePath: null,
        );
      }
      return i;
    }).toList();
    state = state.copyWith(items: items);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      _log.d('Starting queue processing for retry');
      Future.microtask(() => _processQueue());
    } else {
      _log.d('Queue already processing, item will be picked up');
    }
  }

  Future<void> retryAllFailed({bool networkOnly = false}) async {
    final failedIds = state.items
        .where(
          (item) =>
              (item.status == DownloadStatus.failed ||
                  item.status == DownloadStatus.skipped) &&
              !_retryingItemIds.contains(item.id) &&
              (!networkOnly || item.errorType?.isNetworkFailure == true),
        )
        .map((item) => item.id)
        .toSet();
    if (failedIds.isEmpty) {
      _log.d('retryAllFailed: no failed downloads to retry');
      return;
    }

    _retryingItemIds.addAll(failedIds);
    try {
      await _retryFailedItems(failedIds);
    } finally {
      _retryingItemIds.removeAll(failedIds);
    }
  }

  Future<void> _retryFailedItems(Set<String> failedIds) async {
    _log.i('Retrying ${failedIds.length} failed download(s)');
    await _waitForCancelledDownloadAttempts(failedIds);
    if (!ref.mounted) return;
    final pendingIds = failedIds.where((id) {
      final item = _findItemById(id);
      return item != null &&
          (item.status == DownloadStatus.failed ||
              item.status == DownloadStatus.skipped);
    }).toSet();
    if (pendingIds.isEmpty) return;
    final retryableIds = await PlatformBridge.resetDownloadCancels(pendingIds);
    if (!ref.mounted || retryableIds.isEmpty) return;
    _locallyCancelledItemIds.removeAll(retryableIds);
    _pausePendingItemIds.removeAll(retryableIds);

    for (final item in state.items) {
      if (!retryableIds.contains(item.id)) continue;
      _purgeAlbumRgEntry(item.track);
    }

    final items = state.items
        .map((item) {
          if (!retryableIds.contains(item.id)) return item;
          if (item.status != DownloadStatus.failed &&
              item.status != DownloadStatus.skipped) {
            return item;
          }
          _verificationRetryGuard.clearItem(item.id);
          _rateLimitRetriedItemIds.remove(item.id);
          return item.resetToQueued().copyWith(
            error: null,
            errorType: null,
            filePath: null,
          );
        })
        .toList(growable: false);

    state = state.copyWith(items: items, isPaused: false);
    _persistUserPausedQueue(false);
    _saveQueueToStorage();

    if (!state.isProcessing) {
      Future.microtask(() => _processQueue());
    }
  }

  Future<void> _waitForCancelledDownloadAttempts(Iterable<String> ids) async {
    // A cancelled row becomes retryable before its writer and native cancel
    // finish. Both must settle before resetting the flag or publishing a new
    // attempt, otherwise the old result can overwrite the retried row.
    while (true) {
      final pending = <Future<void>>{
        for (final id in ids) ...[
          ?_nativeCancelRequests[id],
          ?_activeDownloadAttempts[id],
        ],
      };
      if (pending.isEmpty) return;
      await Future.wait(pending);
      if (!ref.mounted) return;
    }
  }

  /// Reinserts a queued item ahead of all other queued items so the next
  /// free download slot picks it up. During an active native worker run the
  /// current batch keeps its order; the new order applies from the next run.
  void downloadNext(String id) {
    final items = state.items;
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = items[index];
    if (item.status != DownloadStatus.queued) return;
    final firstQueuedIndex = items.indexWhere(
      (candidate) => candidate.status == DownloadStatus.queued,
    );
    if (firstQueuedIndex == index) return;
    final reordered = List<DownloadItem>.from(items)
      ..removeAt(index)
      ..insert(firstQueuedIndex, item);
    state = state.copyWith(items: reordered);
    _saveQueueToStorage();
  }

  /// Moves a queued item [offset] positions up (negative) or down (positive)
  /// among the queued items, leaving non-queued rows in place. Same native
  /// worker caveat as [downloadNext]: an in-flight batch keeps its order.
  void moveQueuedItem(String id, int offset) {
    if (offset == 0) return;
    final items = state.items;
    final index = items.indexWhere((item) => item.id == id);
    if (index == -1) return;
    final item = items[index];
    if (item.status != DownloadStatus.queued) return;
    final queuedIndices = <int>[
      for (var i = 0; i < items.length; i++)
        if (items[i].status == DownloadStatus.queued) i,
    ];
    final position = queuedIndices.indexOf(index);
    final targetPosition = position + offset;
    if (targetPosition < 0 || targetPosition >= queuedIndices.length) return;
    final reordered = List<DownloadItem>.from(items)..removeAt(index);
    // Inserting at the target's pre-removal index lands the item directly
    // before it when moving up and directly after it when moving down.
    reordered.insert(queuedIndices[targetPosition], item);
    state = state.copyWith(items: reordered);
    _saveQueueToStorage();
  }

  void removeItem(String id) {
    _deferredReady.remove(id);
    _removeQueueItem(id, completedCleanup: false);
  }

  int removeFailedItems() {
    final ids = [
      for (final item in state.items)
        if (item.status == DownloadStatus.failed) item.id,
    ];
    for (final id in ids) {
      removeItem(id);
    }
    return ids.length;
  }

  void _removeCompletedItem(String id) =>
      _removeQueueItem(id, completedCleanup: true);

  @visibleForTesting
  void removeCompletedItemForTesting(String id) => _removeCompletedItem(id);

  @visibleForTesting
  List<DownloadItem> withoutFailedDuplicatesForTesting(
    List<DownloadItem> items,
  ) => _withoutFailedDuplicates(items, <String>{});

  @visibleForTesting
  String? resolveDeclaredDownloadQualityForTesting(
    String service,
    String quality, {
    bool useSourceDefault = false,
    bool strict = true,
  }) => _resolveDeclaredDownloadQuality(
    service,
    quality,
    useSourceDefault: useSourceDefault,
    strict: strict,
  );

  void _removeQueueItem(String id, {required bool completedCleanup}) {
    final selectionStart = _pendingSelectionEvents.length;
    final removedItem = state.items.where((item) => item.id == id).firstOrNull;
    if (!completedCleanup && removedItem != null) {
      _cancelPendingSaveChecks(removedItem.track);
    }
    _locallyCancelledItemIds.remove(id);
    _replaceWaiters.remove(id)?.complete(null);
    state = state.withoutItem(id);
    if (!completedCleanup)
      _reserveNativeDiscard(selectionStart, all: false, ids: {id});
    if (!completedCleanup) _prunePermanentSelections({id});
    _saveQueueToStorage();

    // Clean stale album RG entries when a track is removed from the queue.
    // Only purge for items that were NOT completed — completed items' RG data
    // must survive removal because album gain is computed after the last track
    // finishes, by which time earlier completed tracks have been removed.
    if (removedItem != null && removedItem.status != DownloadStatus.completed) {
      _purgeAlbumRgEntry(removedItem.track);
      // Removing a failed/skipped item may unblock album RG for the album.
      _retriggerAlbumRgChecks();
    }
  }

  void _removeDeletedFile(String filePath) {
    final deletedKeys = buildPhysicalPathMatchKeys(filePath);
    if (deletedKeys.isEmpty) return;
    final removedIds = <String>{
      for (final item in state.items)
        if (item.status == DownloadStatus.completed &&
            buildPhysicalPathMatchKeys(item.filePath).any(deletedKeys.contains))
          item.id,
    };
    if (removedIds.isEmpty) return;
    // Match the deleted file, not the song: another provider or format may
    // be downloading the same track and must keep its independent request.
    state = state.copyWith(
      items: state.items
          .where((item) => !removedIds.contains(item.id))
          .toList(growable: false),
      currentDownload: removedIds.contains(state.currentDownload?.id)
          ? null
          : state.currentDownload,
    );
    _prunePermanentSelections(removedIds);
    _saveQueueToStorage();
  }

  Future<String?> exportFailedDownloads() async {
    final failedItems = state.items
        .where((item) => item.status == DownloadStatus.failed)
        .toList();

    if (failedItems.isEmpty) {
      _log.d('No failed downloads to export');
      return null;
    }

    try {
      String baseDir = state.outputDir;
      if (baseDir.isEmpty) {
        final dir = await getApplicationDocumentsDirectory();
        baseDir = dir.path;
      }

      final failedDownloadsDir = '$baseDir/failed_downloads';
      final failedDir = Directory(failedDownloadsDir);
      if (!await failedDir.exists()) {
        await failedDir.create(recursive: true);
      }

      final now = DateTime.now();
      final dateStr =
          '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
      final fileName = 'failed_downloads_$dateStr.txt';
      final filePath = '$failedDownloadsDir/$fileName';

      final file = File(filePath);
      final bool fileExists = await file.exists();

      final buffer = StringBuffer();

      if (!fileExists) {
        buffer.writeln('# MUSA Failed Downloads');
        buffer.writeln('# Date: $dateStr');
        buffer.writeln('#');
        buffer.writeln('# Format: [Time] Track - Artist | URL | Error');
        buffer.writeln('');
      }

      final timeStr =
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}';

      for (final item in failedItems) {
        final track = item.track;
        final spotifyUrl = track.id.startsWith('deezer:')
            ? 'https://www.deezer.com/track/${track.id.substring(7)}'
            : 'https://open.spotify.com/track/${track.id}';
        final error = item.error ?? 'Unknown error';
        buffer.writeln(
          '[$timeStr] ${track.name} - ${track.artistName} | $spotifyUrl | $error',
        );
      }

      if (fileExists) {
        await file.writeAsString(buffer.toString(), mode: FileMode.append);
        _log.i('Appended failed downloads to the export file');
      } else {
        await file.writeAsString(buffer.toString());
        _log.i('Created failed downloads export file');
      }

      return filePath;
    } catch (_) {
      _log.e('Failed to export failed downloads');
      return null;
    }
  }

  DownloadErrorType _classifyBackendDownloadFailure(
    String? reportedType,
    String message,
  ) {
    final type = downloadErrorTypeFromBackend(reportedType);
    if (type == null) return _downloadErrorTypeFromMessage(message);
    if (type == DownloadErrorType.providerError) {
      final inferred = _downloadErrorTypeFromMessage(message);
      return inferred == DownloadErrorType.unknown ? type : inferred;
    }
    if (type != DownloadErrorType.verificationRequired &&
        _downloadHttpRateLimit.hasMatch(message)) {
      return DownloadErrorType.rateLimit;
    }
    return type;
  }

  // Recognize status at a known prefix without searching URLs or payloads.
  // Keep this grammar in sync with NativeWorkerPolicy.
  static final _downloadHttpRateLimit = RegExp(
    r'^[ \t]*(?:(?:all providers failed\. last error:|download failed:)[ \t]+)*'
    r'(?:(?:(?:could not fetch track data|direct soundcloud lookup failed|search failed):[ \t]+)?'
    r'soundcloud api returned http[ \t]+'
    r'|failed to resolve deezer download:[ \t]+http[ \t]+'
    r'|(?:soundcloud (?:hls|stream) request failed|could not fetch track data: soundcloud api failed after retry):[ \t]+http[ \t]+'
    r'|failed to download (?:file(?: via (?:cobalt|yt1d))?|(?:deezer|qobuz) stream):[ \t]+http[ \t]+error:[ \t]+'
    r'|(?:segment [0-9]+[ \t]+)?'
    r'(?:http(?:/[0-9]+(?:\.[0-9]+)?)?(?:[ \t]+(?:error|status(?:[ \t]+code)?))?|status(?:[ \t]+code)?)'
    r'(?:[ \t]*[:=][ \t]*|[ \t]+))429(?=$|[ \t\r\n:;,!)\]]|\.(?:$|[ \t\r\n]))',
    caseSensitive: false,
  );

  DownloadErrorType _downloadErrorTypeFromMessage(String errorMsg) {
    final lowerMsg = errorMsg.toLowerCase();
    if (isExtensionVerificationRequired(errorMsg)) {
      return DownloadErrorType.verificationRequired;
    }
    if (_downloadHttpRateLimit.hasMatch(errorMsg)) {
      return DownloadErrorType.rateLimit;
    }
    if (lowerMsg.contains('not found') ||
        lowerMsg.contains('not available') ||
        lowerMsg.contains('no results')) {
      return DownloadErrorType.notFound;
    }
    if (lowerMsg.contains('permission') ||
        lowerMsg.contains('operation not permitted') ||
        lowerMsg.contains('access denied')) {
      return DownloadErrorType.permission;
    }
    if (lowerMsg.contains('network') ||
        lowerMsg.contains('connection') ||
        lowerMsg.contains('timeout') ||
        lowerMsg.contains('dial')) {
      return DownloadErrorType.network;
    }
    return DownloadErrorType.unknown;
  }

  Future<void> _processQueue() async {
    // Wait before acquiring the single-flight processing lock. Restoration
    // may adopt an existing native run and must be free to finish that work.
    if (_queueStartupPending || !_queueStorageReady) {
      _startQueueRestore();
      await _queueRestored.future;
      if (!ref.mounted || !_queueStorageReady || state.isPaused) return;
    }
    if (!ref.mounted ||
        state.isPaused ||
        _selectionBarrier ||
        _nativeOwnershipUncertain)
      return;
    if (!_queueProcessingGate.tryEnter()) return;

    try {
      if (state.isProcessing) return;
      await _processQueueSingleFlight();
    } catch (_) {
      _log.e('Download queue processing failed');
      _stopProgressPolling();
      _metadataEmbedding.clearCoverCache();
      _stopConnectivityMonitoring();
      if (ref.mounted) {
        state = state.copyWith(isProcessing: false, currentDownload: null);
      }
      // Setup and finalization can fail outside the per-item pipeline. The
      // queue owner still releases the execution window before another run.
      try {
        if (Platform.isAndroid) {
          await PlatformBridge.stopDownloadService();
        } else if (Platform.isIOS) {
          await PlatformBridge.endBackgroundDownloadTask();
        }
        await downloadKeepAwake.end();
      } catch (cleanupError, cleanupStack) {
        _log.e(
          'Failed to release download execution window: $cleanupError',
          cleanupError,
          cleanupStack,
        );
      }
    } finally {
      if (_queueProcessingGate.leave() && ref.mounted) {
        Future.microtask(_processQueue);
      }
    }
  }

  Future<void> _processQueueSingleFlight() async {
    if (Platform.isAndroid &&
        state.items.any((item) => item.status == DownloadStatus.queued) &&
        !canStartForegroundDownloadForLifecycle(
          WidgetsBinding.instance.lifecycleState,
        )) {
      _log.i(
        'Download queue is waiting for the app to return to the foreground',
      );
      return;
    }

    var settings = ref.read(settingsProvider);
    updateSettings(settings);
    var isSafMode = _isSafMode(settings);
    final networkOnlyQueue = state.items
        .where((item) => item.status == DownloadStatus.queued)
        .every((item) => item.networkDownloadFolder.isNotEmpty);
    if (!networkOnlyQueue && settings.useExtensionProviders) {
      // Cold browser callbacks and restored downloads share initialization.
      // An empty list while loading must not be treated as removed providers.
      await ref.read(extensionProvider.notifier).ensureInitialized();
      if (!ref.mounted || state.isPaused) return;
      settings = ref.read(settingsProvider);
      updateSettings(settings);
      isSafMode = _isSafMode(settings);
    }
    IosSecurityScopedAccess? iosDownloadBookmarkAccess;

    // Validate SAF before handing the batch to either queue implementation.
    // Never silently redirect a user-selected SAF destination into private app
    // storage: keep the selection intact so the UI can request access again.
    if (!networkOnlyQueue &&
        Platform.isAndroid &&
        settings.storageMode == 'saf') {
      var safAccessible = settings.downloadTreeUri.isNotEmpty;
      if (safAccessible) {
        try {
          safAccessible = await PlatformBridge.validateSafTreeAccess(
            settings.downloadTreeUri,
          );
        } catch (e) {
          safAccessible = false;
          _log.w('SAF access validation failed');
        }
      }
      if (!ref.mounted) return;
      if (!safAccessible) {
        _log.w(
          'SAF grant is missing or no longer writable; download location must be reselected',
        );
        failQueuedDownloads(
          error: safPermissionLostErrorMessage,
          errorType: DownloadErrorType.permission,
        );
        return;
      }
    }
    if (await _holdQueueForStorageAccess(
      settings,
      safMode: isSafMode,
      networkOnly: networkOnlyQueue,
    )) {
      _log.i('Download queue is waiting for the access to all files answer');
      return;
    }
    if (!ref.mounted) return;
    if (Platform.isAndroid &&
        !networkOnlyQueue &&
        !isSafMode &&
        settings.downloadDirectory.isEmpty) {
      await _initOutputDir(force: true);
      if (!ref.mounted) return;
    }
    if (Platform.isAndroid &&
        !networkOnlyQueue &&
        !isSafMode &&
        state.outputDir.isNotEmpty &&
        !await _isDirectoryWritable(Directory(state.outputDir))) {
      if (!ref.mounted) return;
      final failedOutputDir = state.outputDir;
      _log.w(
        'Configured app-folder path is not writable; resolving a safe fallback',
      );
      try {
        await _activateAppFolderStorageFallback(
          failedOutputDir: failedOutputDir,
        );
        if (!ref.mounted) return;
        settings = ref.read(settingsProvider);
      } catch (_) {
        if (!ref.mounted) return;
        _log.e('No writable app-folder fallback is available');
      }
    }
    if (!ref.mounted) return;
    if (settings.downloadNetworkMode == 'wifi_only') {
      final connectivityResult = await Connectivity().checkConnectivity();
      if (!ref.mounted) return;
      final hasWifi = connectivityResult.contains(ConnectivityResult.wifi);
      if (!hasWifi) {
        _log.w('WiFi-only mode enabled but no WiFi connection. Queue paused.');
        _networkPausedByWifiOnly = true;
        _startConnectivityMonitoring();
        state = state.copyWith(isProcessing: false, isPaused: true);
        return;
      }
    }
    // Monitor in every mode so idle connections are recycled on a network
    // switch, even though only wifi_only pauses the queue.
    _networkPausedByWifiOnly = false;
    _startConnectivityMonitoring();

    final handledByNativeWorker = await _tryProcessQueueWithAndroidNativeWorker(
      settings,
    );
    if (!ref.mounted || handledByNativeWorker) {
      return;
    }

    // Native request construction can perform asynchronous metadata lookups.
    // The app may have moved to the background while those were running.
    if (Platform.isAndroid &&
        !canStartForegroundDownloadForLifecycle(
          WidgetsBinding.instance.lifecycleState,
        )) {
      _log.i(
        'Download queue moved to the background during preparation; deferring start',
      );
      _stopConnectivityMonitoring();
      return;
    }

    state = state.copyWith(isProcessing: true);
    _log.i('Starting queue processing...');

    _totalQueuedAtStart = state.items
        .where((i) => i.status == DownloadStatus.queued)
        .length;
    _completedInSession = 0;
    _failedInSession = 0;

    // A disposed provider skips remaining setup but still releases the
    // execution window already acquired for this run.
    setup:
    {
      if (Platform.isAndroid && _totalQueuedAtStart > 0) {
        final firstItem = state.items.firstWhere(
          (item) => item.status == DownloadStatus.queued,
          orElse: () => state.items.first,
        );
        try {
          await _notificationService.cancelDownloadNotification();
          if (!ref.mounted) break setup;
          await PlatformBridge.startDownloadService(
            trackName: firstItem.track.name,
            artistName: firstItem.track.artistName,
            queueCount: _totalQueuedAtStart,
          );
          _log.d('Foreground service started');
        } catch (e) {
          if (!ref.mounted) break setup;
          if (isForegroundServiceStartNotAllowed(e)) {
            _log.w(
              'Android deferred the download service start until the app returns to the foreground',
            );
            state = state.copyWith(isProcessing: false, currentDownload: null);
            _stopConnectivityMonitoring();
            return;
          }
          _log.e('Failed to start foreground service: $e');
        }
      }

      if (!ref.mounted) break setup;
      if (Platform.isIOS && _totalQueuedAtStart > 0) {
        await PlatformBridge.beginBackgroundDownloadTask();
      }

      // Desktop: keep the computer from idle sleeping until the queue stops.
      if (!ref.mounted) break setup;
      if (_totalQueuedAtStart > 0) await downloadKeepAwake.begin();
      if (!ref.mounted) break setup;

      if (!isSafMode && state.outputDir.isEmpty) {
        _log.d('Output dir empty, initializing...');
        await _initOutputDir();
        if (!ref.mounted) break setup;
      }

      // iOS: Validate that outputDir is writable (not iCloud Drive which native code
      // can't access), unless a bookmark makes this app-Documents path-shape
      // check irrelevant (see shouldValidateIosOutputDir).
      if (!networkOnlyQueue &&
          shouldValidateIosOutputDir(
            isIOS: Platform.isIOS,
            isSafMode: isSafMode,
            outputDir: state.outputDir,
            downloadDirectoryBookmark: settings.downloadDirectoryBookmark,
          )) {
        final isICloudPath =
            state.outputDir.contains('Mobile Documents') ||
            state.outputDir.contains('CloudDocs') ||
            state.outputDir.contains('com~apple~CloudDocs');
        if (isICloudPath) {
          _log.w(
            'iOS: iCloud Drive path detected, falling back to app Documents folder',
          );
          _log.w('Native backend cannot access this iCloud Drive path');
          final musicDir = await _ensureDefaultDocumentsOutputDir();
          if (!ref.mounted) break setup;
          state = state.copyWith(outputDir: musicDir.path);
          ref
              .read(settingsProvider.notifier)
              .setDownloadDirectory(musicDir.path);
        } else if (!isValidIosWritablePath(state.outputDir)) {
          _log.w(
            'iOS: Invalid output path detected (container root?), falling back to app Documents folder',
          );
          final correctedPath = await validateOrFixIosPath(state.outputDir);
          if (!ref.mounted) break setup;
          _log.i('Selected corrected iOS output folder');
          state = state.copyWith(outputDir: correctedPath);
          ref
              .read(settingsProvider.notifier)
              .setDownloadDirectory(correctedPath);
        }
      }

      if (!isSafMode && state.outputDir.isEmpty) {
        _log.d('Using fallback directory...');
        final musicDir = await _ensureDefaultDocumentsOutputDir();
        if (!ref.mounted) break setup;
        state = state.copyWith(outputDir: musicDir.path);
      }

      _log.d('Download storage mode: ${isSafMode ? 'SAF' : 'filesystem'}');

      try {
        if (!isSafMode &&
            !networkOnlyQueue &&
            Platform.isIOS &&
            settings.downloadDirectoryBookmark.isNotEmpty) {
          iosDownloadBookmarkAccess =
              await PlatformBridge.startAccessingIosBookmark(
                settings.downloadDirectoryBookmark,
              );
          if (!ref.mounted) break setup;
          final resolvedPath = iosDownloadBookmarkAccess?.path;
          if (resolvedPath != null && resolvedPath.isNotEmpty) {
            if (resolvedPath != state.outputDir) {
              _log.i('Resolved iOS download bookmark');
              state = state.copyWith(outputDir: resolvedPath);
            }
          } else {
            _log.w(
              'The saved download folder may have been moved, deleted, or its access grant lost',
            );
            failQueuedDownloads(error: downloadFolderAccessLostErrorMessage);
            state = state.copyWith(isProcessing: false);
            await PlatformBridge.endBackgroundDownloadTask();
            return;
          }
        }

        await _runQueueLoop();
      } finally {
        if (iosDownloadBookmarkAccess != null) {
          await PlatformBridge.stopAccessingIosBookmark(
            iosDownloadBookmarkAccess,
          );
          iosDownloadBookmarkAccess = null;
        }
      }
    }
    final stoppedWhilePaused = ref.mounted && state.isPaused;
    final keepConnectivityMonitoring =
        stoppedWhilePaused && _networkPausedByWifiOnly;

    _stopProgressPolling();
    _metadataEmbedding.clearCoverCache();
    if (!keepConnectivityMonitoring) {
      _stopConnectivityMonitoring();
    }

    if (Platform.isAndroid) {
      try {
        await PlatformBridge.stopDownloadService();
        _log.d('Foreground service stopped');
      } catch (e) {
        _log.e('Failed to stop foreground service: $e');
      }
    }

    if (Platform.isIOS) {
      await PlatformBridge.endBackgroundDownloadTask();
    }

    await downloadKeepAwake.end();

    if (stoppedWhilePaused && _downloadCount > 0) {
      try {
        await PlatformBridge.cleanupConnections();
      } catch (e) {
        _log.e('Final cleanup failed: $e');
      }
    }
    _downloadCount = 0;

    if (!stoppedWhilePaused) {
      // Releasing idle runtimes already recycles the Rust HTTP pool. A
      // separate cleanup immediately beforehand only builds it twice.
      await PlatformBridge.releaseNativeMemory();
    }

    _log.i(
      'Queue stats - completed: $_completedInSession, failed: $_failedInSession, totalAtStart: $_totalQueuedAtStart',
    );
    if (!ref.mounted) return;
    final hasSessionResults = _completedInSession > 0 || _failedInSession > 0;
    if (!stoppedWhilePaused && _totalQueuedAtStart > 0 && hasSessionResults) {
      final settings = ref.read(settingsProvider);
      if (settings.autoExportFailedDownloads && _failedInSession > 0) {
        final exportPath = await exportFailedDownloads();
        if (exportPath != null) {
          _log.i('Auto-exported failed downloads');
        }
      }
    }

    if (stoppedWhilePaused) {
      _log.i('Queue processing paused');
    } else {
      _log.i('Queue processing finished');
    }
    // All per-item futures have completed at this point. Remove any iOS
    // expiration guards that arrived after an individual worker's finally
    // block, otherwise the safely requeued item would be filtered forever on
    // the next queue run.
    if (!ref.mounted) return;
    _pausePendingItemIds.removeWhere(
      (id) => state.lookup.byItemId[id]?.status == DownloadStatus.queued,
    );
    state = state.copyWith(isProcessing: false, currentDownload: null);

    final hasQueuedItems = state.items.any(
      (item) => item.status == DownloadStatus.queued,
    );
    if (hasQueuedItems && !state.isPaused) {
      _log.i(
        'Found queued items after processing finished, restarting queue...',
      );
      Future.microtask(() => _processQueue());
    }
  }

  int? _providerConcurrencyLimit(String service) {
    if (service.isEmpty || !ref.mounted) return null;
    final extension = ref
        .read(extensionProvider)
        .extensions
        .where((ext) => ext.id.trim().toLowerCase() == service)
        .firstOrNull;
    return extension?.downloadTransferPolicy.maxConcurrentDownloads;
  }

  Future<void> _runQueueLoop() async {
    _startMultiProgressPolling();
    try {
      await DownloadScheduler<DownloadItem>(
        queuedItems: () => state.queuedItems.where(
          (item) =>
              !_selectionBarrier && !_pausePendingItemIds.contains(item.id),
        ),
        idOf: (item) => item.id,
        isPaused: () => !ref.mounted || state.isPaused,
        concurrency: _queueConcurrency,
        groupOf: (item) => item.service.trim().toLowerCase(),
        groupLimit: _providerConcurrencyLimit,
        startDelay: _startDelayFor,
        checkInterval: _queueSchedulingInterval,
        start: (item) async {
          updateItemStatus(
            item.id,
            DownloadStatus.downloading,
            preparationStage: item.preparationStage == cooldownWaitText
                ? ''
                : null,
          );
          _log.d('Started download');
          try {
            await _downloadSingleItem(item);
          } finally {
            _afterQueueItemFinished(item.id);
          }
        },
        onFinished: (id) =>
            PlatformBridge.clearItemProgress(id).catchError((_) {}),
      ).run();
      if (!ref.mounted) return;
      _log.d(
        state.isPaused
            ? 'Queue is paused and no active download remains'
            : 'No more items to process',
      );
    } finally {
      _stopProgressPolling();
      if (ref.mounted) {
        final remainingIds = state.items.map((item) => item.id).toSet();
        _locallyCancelledItemIds.removeWhere(
          (id) => !remainingIds.contains(id),
        );
        _pausePendingItemIds.removeWhere((id) => !remainingIds.contains(id));
        _verificationRetryGuard.retainItems(remainingIds);
        _rateLimitRetriedItemIds.removeWhere(
          (id) => !remainingIds.contains(id),
        );
      }
    }
  }
}

enum SavedDownloadPathStatus { accessible, missing, unavailable }

/// Distinguishes a missing file from a storage location that cannot be checked.
Future<SavedDownloadPathStatus> savedDownloadPathStatus(
  String path, {
  String downloadDirectory = '',
}) async {
  const missing = SavedDownloadPathStatus.missing;
  const unavailable = SavedDownloadPathStatus.unavailable;
  const accessible = SavedDownloadPathStatus.accessible;
  if (path.isEmpty || path.startsWith('network://') || isCueVirtualPath(path)) {
    return unavailable;
  }
  try {
    if (isContentUri(path)) {
      return await _safDownloadPathStatus(path);
    }
    final file = File(path);
    try {
      final handle = await file.open();
      try {
        return await handle.length() > 0 ? accessible : missing;
      } finally {
        await handle.close();
      }
    } on PathNotFoundException {
      if (await FileSystemEntity.type(path, followLinks: false) ==
          FileSystemEntityType.link) {
        return unavailable;
      }
      // A deleted album can remove every parent directory. Check the
      // containing volume rather than requiring the immediate parent.
      return await _downloadVolumeAvailable(path, downloadDirectory)
          ? missing
          : unavailable;
    }
  } catch (_) {
    return unavailable;
  }
}

Future<SavedDownloadPathStatus> _safDownloadPathStatus(String path) async {
  const accessible = SavedDownloadPathStatus.accessible;
  const missing = SavedDownloadPathStatus.missing;
  const unavailable = SavedDownloadPathStatus.unavailable;
  if (isDesktopPlatform) return unavailable;

  // A completed empty query proves absence. Provider and security errors
  // propagate from the native stat and leave availability inconclusive.
  final stat = await PlatformBridge.safStat(path);
  if (stat['exists'] == false) return missing;
  if (stat['exists'] != true) return unavailable;
  final size = stat['size'];
  if (size is int && size > 0) {
    return await PlatformBridge.safCanOpenRead(path) ? accessible : unavailable;
  }

  // Null or zero can mean a provider cannot report size. Opening a
  // descriptor alone cannot establish readable bytes or confirm absence.
  return unavailable;
}

Future<bool> _downloadVolumeAvailable(
  String path,
  String downloadDirectory,
) async {
  if (!p.isAbsolute(path)) return false;
  if (Platform.isWindows) return Directory(p.rootPrefix(path)).exists();
  final segments = p.split(p.normalize(path));
  if (segments.length < 2) return false;
  if (Platform.isAndroid && segments[1] == 'sdcard') {
    return Directory('/sdcard').exists();
  }
  if (Platform.isAndroid &&
      segments.length >= 4 &&
      segments[1] == 'storage' &&
      segments[2] == 'emulated') {
    return Directory(p.joinAll(segments.take(4))).exists();
  }

  final mountParents = switch (segments[1]) {
    'Volumes' when Platform.isMacOS => const [3],
    'mnt' || 'media' when Platform.isLinux => const [2, 3, 4],
    'run'
        when Platform.isLinux &&
            segments.length > 2 &&
            segments[2] == 'media' =>
      const [3, 4, 5],
    'storage' || 'mnt' when Platform.isAndroid => const [3, 4, 5],
    _ => const <int>[],
  };
  if (mountParents.isEmpty) {
    if (p.isAbsolute(downloadDirectory) &&
        p.isWithin(downloadDirectory, path)) {
      return verifiedDownloadDirectoryContainsPath(downloadDirectory, path);
    }
    if (await File(path).parent.exists()) return true;
    // With a missing parent on an unclassified POSIX path, an existing /
    // does not tell us whether a custom mount is still available. App-owned
    // storage and the system temporary directory provide known roots.
    final temp = Directory.systemTemp;
    if (p.isWithin(temp.path, path) && await temp.exists()) return true;
    final documents = await getApplicationDocumentsDirectory();
    return p.isWithin(documents.path, path) && await documents.exists();
  }
  final possibleMounts = {
    for (final count in mountParents)
      if (count < segments.length) p.joinAll(segments.take(count)),
  };
  if (Platform.isMacOS) {
    final result = await Process.run('/sbin/mount', const <String>[]);
    return result.exitCode == 0 &&
        (result.stdout as String)
            .split('\n')
            .any(
              (line) =>
                  possibleMounts.any((mount) => line.contains(' on $mount (')),
            );
  }

  // A mountpoint directory can survive removal of a disk. Match actual
  // mount-table entries for conventional external storage paths.
  String encodeMountPath(String path) => path
      .replaceAll(r'\', r'\134')
      .replaceAll(' ', r'\040')
      .replaceAll('\t', r'\011')
      .replaceAll('\n', r'\012');
  final encoded = possibleMounts.map(encodeMountPath).toSet();
  final mounts = await File('/proc/self/mountinfo').readAsLines();
  return mounts.any((line) {
    final fields = line.split(' ');
    return fields.length > 4 && encoded.contains(fields[4]);
  });
}

/// Verifies a configured local root and rejects linked ancestors that could
/// redirect a historical download into an inaccessible volume.
@visibleForTesting
Future<bool> verifiedDownloadDirectoryContainsPath(
  String downloadDirectory,
  String path,
) async {
  if (!p.isAbsolute(downloadDirectory) || !p.isAbsolute(path)) return false;
  final root = p.normalize(downloadDirectory);
  if (!p.isWithin(root, path)) return false;
  try {
    if (!p.equals(await Directory(root).resolveSymbolicLinks(), root)) {
      return false;
    }
    var parent = p.dirname(p.normalize(path));
    while (!p.equals(parent, root)) {
      final type = await FileSystemEntity.type(parent, followLinks: false);
      if (type == FileSystemEntityType.directory) {
        return p.isWithin(root, await Directory(parent).resolveSymbolicLinks());
      }
      if (type != FileSystemEntityType.notFound) return false;
      parent = p.dirname(parent);
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

/// Only suppress an automatic download when the existing file can be opened.
/// Network identities require a separate connection and are inconclusive here.
Future<bool> savedDownloadFileAccessible(String path) async {
  if (path.isEmpty || path.startsWith('network://') || isCueVirtualPath(path)) {
    return false;
  }
  try {
    if (isContentUri(path)) {
      return await _safDownloadPathStatus(path) ==
          SavedDownloadPathStatus.accessible;
    }
    final file = File(path);
    if (!await file.exists() || await file.length() == 0) return false;
    final handle = await file.open();
    await handle.close();
    return true;
  } catch (_) {
    return false;
  }
}

final downloadQueueProvider =
    NotifierProvider<DownloadQueueNotifier, DownloadQueueState>(
      DownloadQueueNotifier.new,
    );

final downloadQueueLookupProvider = Provider<DownloadQueueLookup>((ref) {
  return ref.watch(downloadQueueProvider.select((s) => s.lookup));
});
