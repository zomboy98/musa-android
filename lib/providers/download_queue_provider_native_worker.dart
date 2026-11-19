// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

class _NativeResultPersistenceFailure implements Exception {
  _NativeResultPersistenceFailure(this.cause);
  final Object cause;
}

class _NativeReconciliationAbandoned implements Exception {}

class _NativeServiceStatusUnknown implements Exception {
  _NativeServiceStatusUnknown(this.cause);
  final Object cause;
}

class _NativeWorkerRequestContext {
  final DownloadItem item;
  final String requestJson;
  final String outputDir;
  final String quality;
  final String storageMode;
  final String outputExt;
  final String? downloadTreeUri;
  final String? safRelativeDir;
  final String? safFileName;
  final bool qualityVariantCollisionOnly;

  const _NativeWorkerRequestContext({
    required this.item,
    required this.requestJson,
    required this.outputDir,
    required this.quality,
    required this.storageMode,
    required this.outputExt,
    this.downloadTreeUri,
    this.safRelativeDir,
    this.safFileName,
    this.qualityVariantCollisionOnly = false,
  });

  _NativeWorkerRequestContext withResolvedFolder(Map<String, dynamic> result) {
    final directory = result['saf_relative_dir'];
    if (storageMode != 'saf' || directory is! String) return this;
    return _NativeWorkerRequestContext(
      item: item,
      requestJson: requestJson,
      outputDir: directory,
      quality: quality,
      storageMode: storageMode,
      outputExt: outputExt,
      downloadTreeUri: downloadTreeUri,
      safRelativeDir: directory,
      safFileName: safFileName,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );
  }
}

extension _DownloadQueueNativeWorker on DownloadQueueNotifier {
  Future<bool> _recoverNativeWorkerStorageFailure({
    required _NativeWorkerRequestContext context,
    required String errorType,
    required String errorMessage,
    required Object? diagnosticStage,
    required bool recordDiagnostic,
    required Map<String, _NativeWorkerRequestContext> contexts,
    required Set<String> reconciledIds,
  }) async {
    if (!isStorageWriteFailure(
      errorType: errorType,
      errorMessage: errorMessage,
    )) {
      return false;
    }

    if (storageWriteRecoveryFor(useSaf: context.storageMode == 'saf') ==
        StorageWriteRecovery.requestSafAccess) {
      _log.w(
        'Native worker lost SAF access; cancelling the run without changing the selected destination',
      );
      try {
        await PlatformBridge.cancelNativeDownloadWorker();
      } catch (_) {
        _log.w('Failed to cancel native worker after SAF access loss');
      }
      if (!ref.mounted) return true;
      for (final pendingId in contexts.keys) {
        if (reconciledIds.contains(pendingId)) continue;
        final pending = _findItemById(pendingId);
        if (pending == null ||
            pending.status == DownloadStatus.completed ||
            pending.status == DownloadStatus.skipped) {
          continue;
        }
        reconciledIds.add(pendingId);
        _recordFailedDownload(
          pendingId,
          error: safPermissionLostErrorMessage,
          errorType: DownloadErrorType.permission,
          diagnosticStage: diagnosticStage,
          recordDiagnostic: recordDiagnostic && pendingId == context.item.id,
        );
      }
      return true;
    }

    final fallbackRoot = await _activateAppFolderStorageFallback(
      failedOutputDir: context.outputDir,
    );
    if (!ref.mounted || fallbackRoot == null) return true;
    if (_pathIsInside(context.outputDir, fallbackRoot)) {
      // This request already used the verified fallback. Do not create an
      // infinite retry loop if the failure has another device-specific cause.
      return false;
    }

    _log.w(
      'Native worker could not write its destination; retrying pending items in the app folder',
    );
    try {
      await PlatformBridge.cancelNativeDownloadWorker();
    } catch (_) {
      _log.w('Failed to cancel native worker for storage fallback');
    }
    if (!ref.mounted) return true;

    for (final pendingId in contexts.keys) {
      if (reconciledIds.contains(pendingId)) continue;
      final pending = _findItemById(pendingId);
      if (pending == null ||
          pending.status == DownloadStatus.completed ||
          pending.status == DownloadStatus.skipped) {
        continue;
      }
      reconciledIds.add(pendingId);
      updateItemStatus(pendingId, DownloadStatus.queued, progress: 0.0);
    }
    return true;
  }

  Future<void> _persistNativeFinalizedHistoryFallback(
    _NativeWorkerRequestContext context,
    Map<String, dynamic> result,
    String filePath,
  ) async {
    if (!ref.mounted) return;
    final audio = await resolveDownloadCompletionAudio(
      result: result,
      filePath: filePath,
      fileName: result['file_name']?.toString(),
      quality: context.quality,
      readMetadata: PlatformBridge.readFileMetadata,
      debug: _log.d,
    );
    if (!ref.mounted) return;
    final useSaf = context.storageMode == 'saf';
    final resultFileName = result['file_name']?.toString().trim();
    final lyricsAvailability = await _resolveFinalLyricsAvailability(
      filePath: filePath,
    );

    if (!ref.mounted) return;
    await ref
        .read(downloadHistoryProvider.notifier)
        .addToHistory(
          _historyItemFromResult(
            item: context.item,
            trackToDownload: context.item.track,
            result: result,
            filePath: filePath,
            quality: audio.quality,
            useSaf: useSaf,
            downloadTreeUri: context.downloadTreeUri,
            safRelativeDir: context.safRelativeDir,
            safFileName: resultFileName?.isNotEmpty == true
                ? resultFileName
                : context.safFileName,
            bitDepth: audio.bitDepth,
            sampleRate: audio.sampleRate,
            bitrate: audio.bitrate,
            format: audio.format,
            genre: normalizeOptionalString(result['genre']?.toString()),
            label: normalizeOptionalString(result['label']?.toString()),
            copyright: normalizeOptionalString(result['copyright']?.toString()),
            hasLyrics: lyricsAvailability.hasLyrics,
            lyricsMetadataScanVersion: lyricsAvailability.scanVersion,
            hasReplayGain: lyricsAvailability.hasReplayGain,
            replayGainMetadataScanVersion:
                lyricsAvailability.replayGainScanVersion,
          ),
          preserveTrackVariant: context.item.preserveQualityVariant,
          origin: _resolvedOrigin(context.item),
        );
  }

  bool _canUseAndroidNativeWorker(AppSettings settings) {
    // Network publication runs in the shared queue after native tag processing.
    // Do not let the worker publish a local history row or completion early.
    if (state.items.any((item) => item.networkDownloadFolder.isNotEmpty)) {
      return false;
    }
    if (!_isAndroidNativeWorker || !settings.nativeDownloadWorkerEnabled) {
      return false;
    }
    if (_queueNeedsPacedProcessing()) return false;
    if (!settings.useExtensionProviders) {
      return false;
    }
    if (_isSafMode(settings)) {
      if (settings.downloadTreeUri.isEmpty) {
        return false;
      }
    }
    final extensionState = ref.read(extensionProvider);
    final hasEnabledDownloadProvider = extensionState.extensions.any(
      (extension) => extension.enabled && extension.hasDownloadProvider,
    );
    if (!hasEnabledDownloadProvider) {
      return false;
    }
    return true;
  }

  String _newNativeWorkerRunId() =>
      'native-${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

  String _snapshotRunId(Map<String, dynamic> snapshot) {
    final direct = snapshot['run_id']?.toString() ?? '';
    if (direct.isNotEmpty) return direct;

    final settingsJson = snapshot['settings_json'];
    if (settingsJson is String && settingsJson.isNotEmpty) {
      try {
        final decoded = jsonDecode(settingsJson);
        if (decoded is Map) {
          return decoded['run_id']?.toString() ?? '';
        }
      } catch (_) {}
    } else if (settingsJson is Map) {
      return settingsJson['run_id']?.toString() ?? '';
    }
    return '';
  }

  bool _isNativeWorkerSnapshotContractCompatible(
    Map<String, dynamic> snapshot,
  ) {
    final version = snapshot['contract_version'];
    return version == DownloadRequestPayload.nativeWorkerContractVersion;
  }

  /// Serial of the last fully-processed state snapshot, echoed back to the
  /// native side so steady-state polls skip the per-item payload. Falls back
  /// to the previous value for snapshots without the field.
  int _snapshotStateSerial(Map<String, dynamic> snapshot, int previous) {
    final serial = snapshot['state_serial'];
    if (serial is num && serial > 0) {
      return serial.toInt();
    }
    return previous;
  }

  bool _isNativeWorkerSnapshotForRun(
    Map<String, dynamic> snapshot,
    String runId,
  ) =>
      runId.isNotEmpty &&
      _snapshotRunId(snapshot) == runId &&
      _isNativeWorkerSnapshotContractCompatible(snapshot);

  Future<void> _persistNativeWorkerRunId(String runId) async {
    _activeNativeWorkerRunId = runId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      DownloadQueueNotifier._nativeWorkerRunIdPrefsKey,
      runId,
    );
  }

  Future<String?> _loadNativeWorkerRunId() async {
    if (_activeNativeWorkerRunId != null) return _activeNativeWorkerRunId;
    final prefs = await SharedPreferences.getInstance();
    final runId = prefs.getString(
      DownloadQueueNotifier._nativeWorkerRunIdPrefsKey,
    );
    if (runId != null && runId.isNotEmpty) {
      _activeNativeWorkerRunId = runId;
      return runId;
    }
    return null;
  }

  Future<void> _clearNativeWorkerRunId(String runId) async {
    final discards = await _queuePersistence.loadNativeDiscards(runId);
    if (discards.allRequests || discards.requestIds.isNotEmpty) {
      throw StateError('Native discard still requires confirmation');
    }
    if (_activeNativeWorkerRunId == runId) {
      _activeNativeWorkerRunId = null;
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(DownloadQueueNotifier._nativeWorkerRunIdPrefsKey) ==
        runId) {
      await prefs.remove(DownloadQueueNotifier._nativeWorkerRunIdPrefsKey);
    }
  }

  void _holdNativeOwnershipForRecovery() {
    if (!ref.mounted) return;
    _nativeOwnershipUncertain = true;
    state = state.copyWith(isPaused: true, nativeRecoveryRequired: true);
    _persistUserPausedQueue(true);
  }

  // Only the durable ledger authorizes discarding a native result. A missing
  // item in a snapshot is not evidence that native storage accepted the ACK.
  Future<Map<String, dynamic>?> _reconcileDurableNativeDiscards(
    Map<String, dynamic> snapshot,
    String runId,
    int clearGeneration,
  ) async {
    while (_selectionBarrier &&
        ref.mounted &&
        clearGeneration == _clearGeneration) {
      if (_selectionWriteFailed) {
        _holdNativeOwnershipForRecovery();
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!ref.mounted || clearGeneration != _clearGeneration) return null;
    try {
      final discard = await _queuePersistence.loadNativeDiscards(runId);
      if (!discard.allRequests && discard.requestIds.isEmpty) return snapshot;
      if (!_isNativeWorkerSnapshotForRun(snapshot, runId)) return null;
      // Keep discarded results out of every reconciliation while the worker
      // is running. Its eventual stopped snapshot performs the durable ACK.
      if (snapshot['is_running'] == false) {
        final confirmed =
            await PlatformBridge.discardStoppedNativeDownloadWorkerItems(
              runId: runId,
              itemIds: discard.requestIds.toList(growable: false),
              allRequests: discard.allRequests,
            );
        if (!ref.mounted || clearGeneration != _clearGeneration) return null;
        if (!confirmed || _selectionBarrier) {
          _holdNativeOwnershipForRecovery();
          return null;
        }
        await _queuePersistence.flush(requireDurable: true);
        if (!ref.mounted || clearGeneration != _clearGeneration) return null;
        if (_selectionBarrier) {
          _holdNativeOwnershipForRecovery();
          return null;
        }
        await _queuePersistence.ackNativeDiscards(
          runId,
          requestIds: discard.requestIds,
          allRequests: discard.allRequests,
        );
      }
      bool retained(dynamic raw) {
        if (discard.allRequests) return false;
        final id = raw is Map ? raw['item_id']?.toString() : raw?.toString();
        return id == null || !discard.requestIds.contains(id);
      }

      return {
        ...snapshot,
        if (snapshot['items'] is List)
          'items': (snapshot['items'] as List).where(retained).toList(),
        if (snapshot['item_ids'] is List)
          'item_ids': (snapshot['item_ids'] as List).where(retained).toList(),
        if (snapshot['item_delta'] is Map && !retained(snapshot['item_delta']))
          'item_delta': null,
        if (snapshot['item_deltas'] is List)
          'item_deltas': (snapshot['item_deltas'] as List)
              .where(retained)
              .toList(),
      };
    } catch (_) {
      _log.w('Could not confirm durable native discard');
      if (ref.mounted && clearGeneration == _clearGeneration) {
        _holdNativeOwnershipForRecovery();
      }
      return null;
    }
  }

  Future<bool> _tryAdoptAndroidNativeWorkerSnapshot(
    List<DownloadItem> restoredItems,
  ) async {
    final clearGeneration = _clearGeneration;
    final settings = ref.read(settingsProvider);
    // Adoption deliberately skips _canUseAndroidNativeWorker: that gate reads
    // extension state that loads asynchronously after startup, and toggles the
    // user may have flipped mid-run. If a native batch is already running we
    // must reconcile with it regardless, or the Dart queue would download the
    // same items a second time alongside it.
    if (!_isAndroidNativeWorker) {
      return false;
    }

    Map<String, dynamic> snapshot;
    try {
      snapshot =
          await (nativeSnapshotForTesting?.call() ??
              PlatformBridge.getNativeDownloadWorkerSnapshot());
    } catch (_) {
      return false;
    }
    final runId = await _loadNativeWorkerRunId();
    if (!ref.mounted || clearGeneration != _clearGeneration) return false;
    if (runId == null ||
        runId.isEmpty ||
        !_isNativeWorkerSnapshotForRun(snapshot, runId)) {
      return false;
    }
    if (snapshot['is_running'] is! bool) {
      _holdNativeOwnershipForRecovery();
      return false;
    }

    final reconciledSnapshot = await _reconcileDurableNativeDiscards(
      snapshot,
      runId,
      clearGeneration,
    );
    if (reconciledSnapshot == null) return false;
    snapshot = reconciledSnapshot;
    final rawItems = snapshot['items'];
    final rawItemIds = snapshot['item_ids'];
    final snapshotIds = rawItems is List
        ? rawItems
              .whereType<Map<Object?, Object?>>()
              .map((item) => item['item_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
        : rawItemIds is List
        ? rawItemIds
              .map((id) => id?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toSet()
        : <String>{};
    if (snapshotIds.isEmpty) {
      if (snapshot['is_running'] == false) {
        if (_hasUnresolvedStoppedNativeItems(snapshot, const {})) {
          _holdNativeOwnershipForRecovery();
          return false;
        }
        await _clearNativeWorkerRunId(runId);
        return true;
      }
      return false;
    }
    if (!restoredItems.any(
      (item) => snapshotIds.contains(item.id) && _findItemById(item.id) != null,
    )) {
      return false;
    }

    final contexts = <String, _NativeWorkerRequestContext>{};
    final pendingContextIds = <String>{};
    for (final item in restoredItems) {
      if (!snapshotIds.contains(item.id) || _findItemById(item.id) == null)
        continue;
      final context = await _buildAndroidNativeWorkerRequest(item, settings);
      if (!ref.mounted || clearGeneration != _clearGeneration) return false;
      if (context != null) {
        contexts[item.id] = context;
      } else {
        // Extensions may still be loading this early in startup; remember the
        // item and retry building its context on later reconcile polls.
        pendingContextIds.add(item.id);
      }
    }

    final snapshotClaimsRunning = snapshot['is_running'] == true;
    bool serviceAlive;
    try {
      serviceAlive =
          !snapshotClaimsRunning || await _isNativeWorkerServiceAlive();
    } on _NativeServiceStatusUnknown {
      if (ref.mounted && clearGeneration == _clearGeneration) {
        _holdNativeOwnershipForRecovery();
      }
      return false;
    }
    if (!ref.mounted || clearGeneration != _clearGeneration) return false;
    if (snapshotClaimsRunning && !serviceAlive) {
      // The service died mid-batch (process kill/reboot): the snapshot is
      // frozen at is_running=true and nothing will ever update it. Reconcile
      // what the worker managed to finish, requeue the rest, and let the
      // caller fall back to the Dart queue.
      _log.w('Native worker service is dead; reclaiming queue');
      if (contexts.isNotEmpty) {
        if (!await _applyNativeSnapshotWithRetry(
          {...snapshot, 'is_running': false},
          contexts,
          <String>{},
          settings,
          clearGeneration,
        ))
          return false;
      } else if (_hasUnresolvedStoppedNativeItems(snapshot, const {})) {
        _holdNativeOwnershipForRecovery();
        return true;
      }
      _requeueInFlightNativeWorkerItems(snapshotIds);
      await _clearNativeWorkerRunId(runId);
      return false;
    }
    if (contexts.isEmpty && pendingContextIds.isEmpty) {
      return false;
    }
    // A stopped run can contain results that still need a request context.
    // Keep ownership until providers are ready to reconstruct every context.
    if (!snapshotClaimsRunning && pendingContextIds.isNotEmpty) return false;

    _log.i('Adopting Android native worker snapshot');
    final reconciledIds = <String>{};
    _totalQueuedAtStart = contexts.length + pendingContextIds.length;
    _completedInSession = 0;
    _failedInSession = 0;
    state = state.copyWith(
      isProcessing: snapshot['is_running'] == true,
      isPaused: snapshot['is_paused'] == true,
    );
    if (!await _applyNativeSnapshotWithRetry(
      snapshot,
      contexts,
      reconciledIds,
      settings,
      clearGeneration,
    ))
      return false;

    if (snapshot['is_running'] == true) {
      unawaited(
        _continueAndroidNativeWorkerAdoption(
          contexts,
          pendingContextIds,
          reconciledIds,
          settings,
          runId,
        ),
      );
    } else if (state.items.any(
      (item) => item.status == DownloadStatus.queued,
    )) {
      await _clearNativeWorkerRunId(runId);
      Future.microtask(() => _processQueue());
    } else {
      await _clearNativeWorkerRunId(runId);
    }

    return true;
  }

  Future<bool> _isNativeWorkerServiceAlive() async {
    try {
      return await PlatformBridge.isDownloadServiceRunning();
    } catch (error) {
      throw _NativeServiceStatusUnknown(error);
    }
  }

  Future<Map<String, dynamic>?> _cancelAndConfirmNativeWorker(
    String runId,
  ) async {
    await PlatformBridge.cancelNativeDownloadWorker();
    for (var attempt = 0; attempt < 20; attempt++) {
      final snapshot = await PlatformBridge.getNativeDownloadWorkerSnapshot();
      if (_isNativeWorkerSnapshotForRun(snapshot, runId) &&
          snapshot['is_running'] == false) {
        return snapshot;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return null;
  }

  Future<bool> _reconcileStoppedNativeSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> reconciledIds,
    AppSettings settings,
    int clearGeneration,
  ) async {
    final runId = _snapshotRunId(snapshot);
    final filtered = await _reconcileDurableNativeDiscards(
      snapshot,
      runId,
      clearGeneration,
    );
    if (filtered == null || filtered['is_running'] != false) return false;
    snapshot = filtered;
    final rawItems = snapshot['items'];
    if (rawItems is! List) return false;
    while (_selectionBarrier &&
        ref.mounted &&
        clearGeneration == _clearGeneration) {
      if (_selectionWriteFailed) {
        _holdNativeOwnershipForRecovery();
        return false;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (!ref.mounted || clearGeneration != _clearGeneration) return false;
    {
      for (final raw in rawItems) {
        if (raw is! Map) return false;
        final id = raw['item_id']?.toString() ?? '';
        if (id.isEmpty) return false;
        if (contexts.containsKey(id) || reconciledIds.contains(id)) continue;
        final item = _findItemById(id);
        if (item == null) return false;
        final context = await _buildAndroidNativeWorkerRequest(item, settings);
        if (!ref.mounted ||
            clearGeneration != _clearGeneration ||
            context == null)
          return false;
        contexts[id] = context;
      }
      if (!await _applyNativeSnapshotWithRetry(
        snapshot,
        contexts,
        reconciledIds,
        settings,
        clearGeneration,
      ))
        return false;
    }
    try {
      await _queuePersistence.flush(requireDurable: true);
    } catch (_) {
      return false;
    }
    return ref.mounted && clearGeneration == _clearGeneration;
  }

  /// Puts items the dead native worker left mid-flight back into the queue so
  /// the Dart queue can pick them up.
  void _requeueInFlightNativeWorkerItems(Set<String> itemIds) {
    for (final id in itemIds) {
      final current = _findItemById(id);
      if (current == null) continue;
      if (current.status == DownloadStatus.downloading ||
          current.status == DownloadStatus.finalizing) {
        updateItemStatus(id, DownloadStatus.queued, progress: 0.0);
      }
    }
  }

  Future<void> _rebuildPendingNativeWorkerContexts(
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> pendingContextIds,
    AppSettings settings,
  ) async {
    if (pendingContextIds.isEmpty) return;
    final resolved = <String>{};
    for (final id in pendingContextIds) {
      final item = _findItemById(id);
      if (item == null) {
        resolved.add(id);
        continue;
      }
      final context = await _buildAndroidNativeWorkerRequest(item, settings);
      if (context != null) {
        contexts[id] = context;
        resolved.add(id);
      }
    }
    pendingContextIds.removeAll(resolved);
  }

  Future<void> _continueAndroidNativeWorkerAdoption(
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> pendingContextIds,
    Set<String> reconciledIds,
    AppSettings settings,
    String runId,
  ) async {
    final clearGeneration = _clearGeneration;
    var deadServicePolls = 0;
    var lastStateSerial = 0;
    try {
      while (ref.mounted && clearGeneration == _clearGeneration) {
        final snapshot = await PlatformBridge.getNativeDownloadWorkerSnapshot(
          sinceStateSerial: lastStateSerial,
        );
        if (!ref.mounted || clearGeneration != _clearGeneration) return;
        final matchesRun = _isNativeWorkerSnapshotForRun(snapshot, runId);
        if (matchesRun && snapshot['is_running'] is! bool) {
          _holdNativeOwnershipForRecovery();
          return;
        }
        if (!matchesRun || snapshot['is_running'] == true) {
          final serviceAlive = await _isNativeWorkerServiceAlive();
          if (!ref.mounted || clearGeneration != _clearGeneration) return;
          if (serviceAlive) {
            deadServicePolls = 0;
          } else {
            deadServicePolls++;
            if (deadServicePolls >= 3) {
              _log.w(
                'Native worker died without a final snapshot; reclaiming queue',
              );
              if (matchesRun) {
                if (!await _applyNativeSnapshotWithRetry(
                  {...snapshot, 'is_running': false},
                  contexts,
                  reconciledIds,
                  settings,
                  clearGeneration,
                ))
                  return;
                if (!ref.mounted || clearGeneration != _clearGeneration) return;
              } else {
                _holdNativeOwnershipForRecovery();
                return;
              }
              _requeueInFlightNativeWorkerItems({
                ...contexts.keys,
                ...pendingContextIds,
              });
              if (!ref.mounted || clearGeneration != _clearGeneration) return;
              await _clearNativeWorkerRunId(runId);
              if (!ref.mounted || clearGeneration != _clearGeneration) return;
              if (state.items.any(
                (item) => item.status == DownloadStatus.queued,
              )) {
                Future.microtask(() => _processQueue());
              }
              return;
            }
          }
        }
        if (!matchesRun) {
          lastStateSerial = 0;
          await Future<void>.delayed(const Duration(seconds: 1));
          continue;
        }
        state = state.copyWith(isPaused: snapshot['is_paused'] == true);
        await _rebuildPendingNativeWorkerContexts(
          contexts,
          pendingContextIds,
          settings,
        );
        if (!ref.mounted || clearGeneration != _clearGeneration) return;
        if (!await _applyNativeSnapshotWithRetry(
          snapshot,
          contexts,
          reconciledIds,
          settings,
          clearGeneration,
        ))
          return;
        if (!ref.mounted || clearGeneration != _clearGeneration) return;
        lastStateSerial = _snapshotStateSerial(snapshot, lastStateSerial);
        if (snapshot['is_running'] != true) {
          await _clearNativeWorkerRunId(runId);
          if (!ref.mounted || clearGeneration != _clearGeneration) return;
          // Items may have been requeued during reconciliation (e.g. batch
          // mates of a verification challenge); hand them to the queue.
          if (!state.isPaused &&
              state.items.any((item) => item.status == DownloadStatus.queued)) {
            Future.microtask(() => _processQueue());
          }
          break;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    } on _NativeServiceStatusUnknown catch (_) {
      _log.w('Could not determine native worker service status');
      if (ref.mounted && clearGeneration == _clearGeneration) {
        _holdNativeOwnershipForRecovery();
      }
    } catch (_) {
      _log.w('Android native worker adoption stopped');
    } finally {
      if (ref.mounted && clearGeneration == _clearGeneration) {
        state = state.copyWith(isProcessing: false, currentDownload: null);
      }
    }
  }

  Future<bool> _tryProcessQueueWithAndroidNativeWorker(
    AppSettings settings,
  ) async {
    if (!_canUseAndroidNativeWorker(settings)) {
      return false;
    }

    final queuedItems = state.items
        .where((item) => item.status == DownloadStatus.queued)
        .toList(growable: false);
    if (queuedItems.isEmpty) {
      return false;
    }

    _log.i('Starting Android native download worker');

    final isSafMode = _isSafMode(settings);
    if (!isSafMode && state.outputDir.isEmpty) {
      await _initOutputDir();
      if (!ref.mounted) return true;
    }
    if (!isSafMode && state.outputDir.isEmpty) {
      final musicDir = await _ensureDefaultDocumentsOutputDir();
      if (!ref.mounted) return true;
      state = state.copyWith(outputDir: musicDir.path);
    }

    final contexts = <String, _NativeWorkerRequestContext>{};
    Map<String, dynamic> encodeRequest(
      DownloadItem item,
      _NativeWorkerRequestContext context,
    ) {
      return {
        'contract_version': DownloadRequestPayload.nativeWorkerContractVersion,
        'item_id': item.id,
        'track_name': item.track.name,
        'artist_name': item.track.artistName,
        'item_json': jsonEncode(item.toJson()),
        'request_json': context.requestJson,
      };
    }

    // Only the first request blocks startup. The rest are prepared with a
    // small metadata pipeline and appended to the already-running native
    // worker, reducing time-to-first-byte for large albums/playlists.
    final firstItem = queuedItems.first;
    final firstContext = await _buildAndroidNativeWorkerRequest(
      firstItem,
      settings,
    );
    if (!ref.mounted) return true;
    if (firstContext == null) {
      _log.w(
        'Native worker gate rejected a request; falling back to Dart queue',
      );
      return false;
    }
    contexts[firstItem.id] = firstContext;

    if (state.isPaused ||
        !canStartForegroundDownloadForLifecycle(
          WidgetsBinding.instance.lifecycleState,
        )) {
      _log.i(
        'Native worker preparation finished after the app entered the background; deferring start',
      );
      _stopConnectivityMonitoring();
      return true;
    }

    state = state.copyWith(isProcessing: true, isPaused: false);
    _totalQueuedAtStart = queuedItems.length;
    _completedInSession = 0;
    _failedInSession = 0;

    final runId = _newNativeWorkerRunId();
    final clearGeneration = _clearGeneration;
    await _persistNativeWorkerRunId(runId);
    final reconciledIds = <String>{};
    Future<void>? preparationFuture;
    var preparationStopRequested = false;
    try {
      while (_selectionBarrier && ref.mounted && !state.isPaused) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (!ref.mounted ||
          state.isPaused ||
          _findItemById(firstItem.id)?.status != DownloadStatus.queued) {
        await _clearNativeWorkerRunId(runId);
        if (ref.mounted) state = state.copyWith(isProcessing: false);
        return true;
      }
      await PlatformBridge.startNativeDownloadWorker(
        requests: [encodeRequest(firstItem, firstContext)],
        settings: {
          'worker': 'android_native',
          'version': 1,
          'contract_version':
              DownloadRequestPayload.nativeWorkerContractVersion,
          'run_id': runId,
          'created_at': DateTime.now().toIso8601String(),
          'save_download_history': settings.saveDownloadHistory,
          'download_network_mode': settings.downloadNetworkMode,
          'concurrent_downloads': settings.concurrentDownloads.clamp(1, 3),
          'finalizer_concurrency': 1,
          'preparation_streaming': true,
          'expected_total_items': queuedItems.length,
        },
      );

      Future<void> finishPreparation() async {
        try {
          await PlatformBridge.finishNativeDownloadWorkerPreparation(
            runId: runId,
          );
        } catch (_) {
          // A failed hand-off must not leave the foreground worker waiting
          // forever on an open preparation channel.
          try {
            await PlatformBridge.cancelNativeDownloadWorker();
          } catch (_) {
            _log.w(
              'Could not cancel native worker after preparation handoff failed',
            );
          }
          rethrow;
        }
      }

      if (!ref.mounted) {
        await finishPreparation();
        return true;
      }

      preparationFuture = () async {
        var nextIndex = 1;
        try {
          while (nextIndex < queuedItems.length && !preparationStopRequested) {
            while (contexts.length >=
                    DownloadQueueNotifier._nativePreparationWindowSize &&
                !preparationStopRequested) {
              await Future<void>.delayed(const Duration(milliseconds: 250));
            }
            if (preparationStopRequested) break;

            final capacity =
                DownloadQueueNotifier._nativePreparationWindowSize -
                contexts.length;
            final batchLength = min(
              DownloadQueueNotifier._nativePreparationBatchSize,
              min(capacity, queuedItems.length - nextIndex),
            );
            if (batchLength <= 0) continue;

            final batchItems = queuedItems.sublist(
              nextIndex,
              nextIndex + batchLength,
            );
            nextIndex += batchLength;
            final prepared = List<_NativeWorkerRequestContext?>.filled(
              batchItems.length,
              null,
            );
            var preparationIndex = 0;
            final preparationConcurrency = min(2, batchItems.length);
            await Future.wait(
              List.generate(preparationConcurrency, (_) async {
                while (true) {
                  final index = preparationIndex++;
                  if (index >= batchItems.length) return;
                  final item = batchItems[index];
                  try {
                    prepared[index] = await _buildAndroidNativeWorkerRequest(
                      item,
                      settings,
                    );
                  } catch (_) {
                    _log.w('Could not prepare native download request');
                  }
                }
              }),
            );

            final appendRequests = <Map<String, dynamic>>[];
            final appendedIds = <String>[];
            for (var index = 0; index < batchItems.length; index++) {
              final item = batchItems[index];
              final context = prepared[index];
              if (context == null) {
                _log.w(
                  'Native worker gate rejected a request; leaving it queued for the Dart worker',
                );
                continue;
              }
              contexts[item.id] = context;
              appendedIds.add(item.id);
              appendRequests.add(encodeRequest(item, context));
            }
            if (appendRequests.isEmpty) continue;

            try {
              // A foreground selection may arrive while requests are being
              // prepared. Do not hand them to the native worker until its
              // ordered selection write has committed.
              while (ref.mounted &&
                  (_selectionBarrier || state.isPaused) &&
                  !preparationStopRequested) {
                await Future<void>.delayed(const Duration(milliseconds: 250));
              }
              if (!ref.mounted || preparationStopRequested) break;
              for (var index = appendedIds.length - 1; index >= 0; index--) {
                final id = appendedIds[index];
                if (_findItemById(id)?.status != DownloadStatus.queued) {
                  contexts.remove(id);
                  appendedIds.removeAt(index);
                  appendRequests.removeAt(index);
                }
              }
              if (appendRequests.isEmpty) continue;
              await PlatformBridge.appendNativeDownloadWorkerRequests(
                runId: runId,
                requests: appendRequests,
              );
            } catch (_) {
              for (final id in appendedIds) {
                contexts.remove(id);
              }
              _log.w('Could not append prepared native download requests');
            }
          }
        } finally {
          await finishPreparation();
        }
      }();

      final exit =
          await NativeDownloadWorkerMonitor(
            readSnapshot: ({sinceStateSerial = 0}) async {
              if (!ref.mounted) throw _NativeReconciliationAbandoned();
              final snapshot =
                  await PlatformBridge.getNativeDownloadWorkerSnapshot(
                    sinceStateSerial: sinceStateSerial,
                  );
              if (!ref.mounted) throw _NativeReconciliationAbandoned();
              return snapshot;
            },
            matchesRun: (snapshot) =>
                _isNativeWorkerSnapshotForRun(snapshot, runId),
            isServiceAlive: _isNativeWorkerServiceAlive,
          ).run(
            onSnapshot: (snapshot) async {
              if (!ref.mounted) throw _NativeReconciliationAbandoned();
              if (snapshot['is_running'] is! bool) {
                _holdNativeOwnershipForRecovery();
                throw _NativeReconciliationAbandoned();
              }
              if (snapshot['is_running'] == false) {
                preparationStopRequested = true;
              }
              if (!await _applyNativeSnapshotWithRetry(
                snapshot,
                contexts,
                reconciledIds,
                settings,
                clearGeneration,
              ))
                throw _NativeReconciliationAbandoned();
            },
          );
      preparationStopRequested = true;
      if (!ref.mounted) return true;
      if (exit == NativeDownloadWorkerExit.serviceLost) {
        _log.w('Native worker lost its service; reclaiming queue');
        // A lost service may have left a snapshot for another run, or a
        // compact snapshot that omits results. Keep ownership until recovery
        // can establish the full stopped state.
        _holdNativeOwnershipForRecovery();
        return true;
      }
      await _clearNativeWorkerRunId(runId);
    } catch (e) {
      preparationStopRequested = true;
      if (!ref.mounted || e is _NativeReconciliationAbandoned) return true;
      if (e is _NativeServiceStatusUnknown) {
        if (ref.mounted && clearGeneration == _clearGeneration) {
          _holdNativeOwnershipForRecovery();
        }
        return true;
      }
      if (isForegroundServiceStartNotAllowed(e)) {
        _log.w(
          'Android rejected the native worker start while backgrounded; keeping the queue pending',
        );
        await _clearNativeWorkerRunId(runId);
        if (!ref.mounted) return true;
        state = state.copyWith(isProcessing: false, currentDownload: null);
        return true;
      }
      if (e is NativeDownloadWorkerStartupTimeout) {
        _log.w(
          'Android native worker did not publish a matching snapshot; cancelling native worker and falling back to Dart queue',
        );
        try {
          final snapshot = await _cancelAndConfirmNativeWorker(runId);
          if (snapshot == null ||
              !await _reconcileStoppedNativeSnapshot(
                snapshot,
                contexts,
                reconciledIds,
                settings,
                clearGeneration,
              )) {
            throw StateError('Native worker stop was not confirmed');
          }
        } catch (_) {
          if (!ref.mounted) return true;
          _log.w('Failed to cancel timed-out native worker');
          _nativeOwnershipUncertain = true;
          state = state.copyWith(isPaused: true, nativeRecoveryRequired: true);
          _persistUserPausedQueue(true);
          return true;
        }
        if (!ref.mounted) return true;
        await _clearNativeWorkerRunId(runId);
        if (!ref.mounted) return true;
        state = state.copyWith(isProcessing: false, currentDownload: null);
        await Future<void>.delayed(const Duration(milliseconds: 500));
        return false;
      }
      _log.w('Android native worker encountered an error');
      // The native worker keeps downloading on its own; without cancelling
      // it here the batch we just marked failed would continue in the
      // background, its completions never reconciled, and the Dart queue
      // could even restart alongside it.
      try {
        final snapshot = await _cancelAndConfirmNativeWorker(runId);
        if (snapshot == null ||
            !await _reconcileStoppedNativeSnapshot(
              snapshot,
              contexts,
              reconciledIds,
              settings,
              clearGeneration,
            )) {
          throw StateError('Native worker stop was not confirmed');
        }
      } catch (_) {
        if (!ref.mounted) return true;
        _log.w('Failed to cancel native worker after error');
        _nativeOwnershipUncertain = true;
        state = state.copyWith(isPaused: true, nativeRecoveryRequired: true);
        _persistUserPausedQueue(true);
        return true;
      }
      if (!ref.mounted) return true;
      await _clearNativeWorkerRunId(runId);
      if (!ref.mounted) return true;
      for (final item in queuedItems) {
        final current = _findItemById(item.id);
        if (current == null ||
            current.status == DownloadStatus.completed ||
            current.status == DownloadStatus.failed ||
            current.status == DownloadStatus.skipped) {
          continue;
        }
        _recordFailedDownload(
          item.id,
          error: 'Native download worker failed: $e',
          errorType: DownloadErrorType.workerFailed,
        );
      }
    } finally {
      preparationStopRequested = true;
      if (preparationFuture != null) {
        try {
          await preparationFuture;
        } catch (_) {
          _log.w('Native worker preparation pipeline stopped');
        }
      }
      if (ref.mounted && clearGeneration == _clearGeneration) {
        state = state.copyWith(isProcessing: false, currentDownload: null);
      }
      _stopConnectivityMonitoring();
      try {
        await PlatformBridge.cleanupConnections();
      } catch (_) {
        _log.w('Native worker cleanup failed');
      }
    }

    if (!ref.mounted) return true;
    final hasQueuedItems = state.items.any(
      (item) => item.status == DownloadStatus.queued,
    );
    if (hasQueuedItems && !state.isPaused) {
      _log.i(
        'Found queued items after Android native worker finished, restarting queue...',
      );
      Future.microtask(() => _processQueue());
    }

    return true;
  }

  Future<_NativeWorkerRequestContext?> _buildAndroidNativeWorkerRequest(
    DownloadItem item,
    AppSettings settings,
  ) async {
    final testBuilder = nativeRequestJsonForTesting;
    if (testBuilder != null) {
      final requestJson = await testBuilder(item);
      if (!ref.mounted || requestJson == null) return null;
      return _NativeWorkerRequestContext(
        item: item,
        requestJson: requestJson,
        outputDir: state.outputDir,
        quality: state.audioQuality,
        storageMode: 'app',
        outputExt: '',
      );
    }
    if (!_hasActiveDownloadProvider(item.service)) {
      return null;
    }

    final preferredQuality =
        item.service.toLowerCase() == settings.defaultService.toLowerCase()
        ? state.audioQuality
        : _rememberedDownloadQuality(settings, item.service) ??
              (_downloadProviderHasQualityOptions(item.service)
                  ? ''
                  : state.audioQuality);
    final useSourceDefault =
        item.qualityOverride == null || item.qualityOverride == 'DEFAULT';
    final requestedQuality = useSourceDefault
        ? preferredQuality
        : item.qualityOverride!;
    final quality = _resolveDeclaredDownloadQuality(
      item.service,
      requestedQuality,
      useSourceDefault: useSourceDefault,
      allowProviderFallback:
          _itemUsesFallback(item) && settings.useExtensionProviders,
      strict: settings.strictDownloadQuality,
    );
    if (quality == null) return null;

    // The fake Hi-Res check and its LOSSLESS re-download live in the Dart
    // run (_DownloadRun._replaceFakeHiResIfNeeded); the native finalizer has
    // no equivalent, so these items stay on the Dart queue.
    if (settings.redownloadFakeHiRes &&
        HiResCheckService.isHiResQuality(quality)) {
      return null;
    }

    final sourceTrack = await _metadataResolver.prepareSourceTrack(item.track);
    if (!ref.mounted) return null;
    item = item.copyWith(
      track: await _resolveDownloadAlbumCredit(sourceTrack, settings),
    );

    if (!ref.mounted) return null;
    final customFolderPath = await _resolveCustomFolderPath(
      item.track,
      item,
      settings,
      quality,
    );
    if (!ref.mounted) return null;
    final isSafMode = _isSafMode(settings);
    final rawOutputDir = isSafMode
        ? _buildRelativeOutputDir(
            item.track,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          )
        : await _buildOutputDir(
            item.track,
            settings,
            customFolderPath: customFolderPath,
            playlistName: item.playlistName,
          );
    if (!ref.mounted) return null;
    final outputDir = isSafMode
        ? _sanitizeSafRelativeDir(rawOutputDir)
        : rawOutputDir;
    if (!isSafMode) {
      await _ensureDirExists(outputDir, label: 'Output folder');
      if (!ref.mounted) return null;
    }

    final outputExt = _determineOutputExt(quality, item.service);
    String? safFileName;
    final safOutputExt = isSafMode ? outputExt : '';
    final baseFilenameFormat = _shouldTreatAsSingleRelease(item.track)
        ? state.singleFilenameFormat
        : state.filenameFormat;
    final effectiveFilenameFormat = _filenameFormatForItem(
      item,
      baseFilenameFormat,
    );
    final qualityVariantCollisionOnly =
        item.preserveQualityVariant &&
        !_explicitQualityFilenameTokenPattern.hasMatch(baseFilenameFormat);
    if (isSafMode) {
      safFileName = await _buildSafFileNameForItem(
        item,
        item.track,
        filenameFormat: effectiveFilenameFormat,
        quality: quality,
        outputExt: safOutputExt,
      );
    }

    if (!ref.mounted) return null;
    var trackForPayload = item.track;
    final extensionState = ref.read(extensionProvider);
    final skipMetadataEnrichment =
        DownloadMetadataResolver.shouldSkipMetadataEnrichment(
          extensionState,
          trackForPayload.source,
          item.service,
        );
    String? nativeDeezerTrackId;
    if (skipMetadataEnrichment) {
      nativeDeezerTrackId = DownloadMetadataResolver.knownDeezerTrackId(
        trackForPayload,
      );
    } else {
      nativeDeezerTrackId = await _metadataResolver
          .resolveDeezerIdFromKnownOrIsrc(
            trackForPayload,
            item.id,
            lookupContext: 'native worker ISRC',
          );
      if (!ref.mounted) return null;
      final providerResolved = await _metadataResolver
          .resolveDeezerIdViaProviderIfNeeded(
            trackForPayload,
            nativeDeezerTrackId,
            item.id,
            extensionState: extensionState,
          );
      trackForPayload = providerResolved.track;
      nativeDeezerTrackId = providerResolved.deezerTrackId;
    }

    if (!ref.mounted) return null;
    final extendedMetadata = skipMetadataEnrichment
        ? null
        : await _metadataResolver.loadExtendedMetadataForDeezerId(
            nativeDeezerTrackId,
          );

    if (!ref.mounted) return null;
    final payload = _buildDownloadRequestPayload(
      track: trackForPayload,
      item: item,
      settings: settings,
      extensionState: extensionState,
      quality: quality,
      qualityFromSavedPreference:
          useSourceDefault &&
          quality == requestedQuality &&
          _rememberedDownloadQuality(settings, item.service) ==
              requestedQuality,
      filenameFormat: effectiveFilenameFormat,
      outputDir: outputDir,
      outputExt: outputExt,
      useSaf: isSafMode,
      safFileName: safFileName,
      deezerTrackId: nativeDeezerTrackId,
      genre: extendedMetadata?.genre,
      label: extendedMetadata?.label,
      copyright: extendedMetadata?.copyright,
      stageSafForDeferredPublish: isSafMode,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    ).withStrategy(useExtensions: true, useFallback: _itemUsesFallback(item));

    return _NativeWorkerRequestContext(
      item: item.copyWith(track: trackForPayload),
      requestJson: jsonEncode(payload.toJson()),
      outputDir: outputDir,
      quality: quality,
      storageMode: isSafMode ? 'saf' : 'app',
      outputExt: outputExt,
      downloadTreeUri: isSafMode ? settings.downloadTreeUri : null,
      safRelativeDir: isSafMode ? outputDir : null,
      safFileName: safFileName,
      qualityVariantCollisionOnly: qualityVariantCollisionOnly,
    );
  }

  Future<bool> _applyNativeSnapshotWithRetry(
    Map<String, dynamic> snapshot,
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> reconciledIds,
    AppSettings settings,
    int clearGeneration,
  ) async {
    if (snapshot['is_running'] is! bool) {
      if (ref.mounted && clearGeneration == _clearGeneration) {
        _holdNativeOwnershipForRecovery();
      }
      return false;
    }
    final filtered = await _reconcileDurableNativeDiscards(
      snapshot,
      _snapshotRunId(snapshot),
      clearGeneration,
    );
    if (filtered == null) return false;
    snapshot = filtered;
    while (ref.mounted && clearGeneration == _clearGeneration) {
      try {
        final knownIds = {...contexts.keys, ...reconciledIds};
        await _applyAndroidNativeWorkerSnapshot(
          snapshot,
          contexts,
          reconciledIds,
          settings,
          clearGeneration,
        );
        if (ref.mounted &&
            clearGeneration == _clearGeneration &&
            snapshot['is_running'] == false &&
            _hasUnresolvedStoppedNativeItems(snapshot, knownIds)) {
          _holdNativeOwnershipForRecovery();
          return false;
        }
        return ref.mounted && clearGeneration == _clearGeneration;
      } on _NativeResultPersistenceFailure {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return false;
  }

  bool _hasUnresolvedStoppedNativeItems(
    Map<String, dynamic> snapshot,
    Set<String> knownIds,
  ) {
    bool unresolved(dynamic raw, {bool idOnly = false}) {
      final id = idOnly
          ? raw?.toString()
          : raw is Map
          ? raw['item_id']?.toString()
          : null;
      return id == null || id.isEmpty || !knownIds.contains(id);
    }

    for (final key in const ['items', 'item_deltas']) {
      final values = snapshot[key];
      if (values is List && values.any(unresolved)) return true;
    }
    final delta = snapshot['item_delta'];
    if (delta != null && unresolved(delta)) return true;
    final ids = snapshot['item_ids'];
    if (ids is List && ids.any((id) => unresolved(id, idOnly: true)))
      return true;
    return false;
  }

  Future<void> _applyAndroidNativeWorkerSnapshot(
    Map<String, dynamic> snapshot,
    Map<String, _NativeWorkerRequestContext> contexts,
    Set<String> reconciledIds,
    AppSettings settings,
    int clearGeneration,
  ) async {
    final rawItems = snapshot['items'];
    final rawDelta = snapshot['item_delta'];
    final rawDeltas = snapshot['item_deltas'];
    final itemSnapshots = <Map<String, dynamic>>[];
    if (rawItems is List) {
      for (final rawItem in rawItems) {
        if (rawItem is Map) {
          itemSnapshots.add(Map<String, dynamic>.from(rawItem));
        }
      }
    }
    if (rawDelta is Map) {
      itemSnapshots.add(Map<String, dynamic>.from(rawDelta));
    }
    if (rawDeltas is List) {
      for (final rawItem in rawDeltas) {
        if (rawItem is Map) {
          itemSnapshots.add(Map<String, dynamic>.from(rawItem));
        }
      }
    }
    final workerRunning = snapshot['is_running'] == true;

    for (final itemSnapshot in itemSnapshots) {
      final itemId = itemSnapshot['item_id']?.toString() ?? '';
      if (itemId.isEmpty || reconciledIds.contains(itemId)) {
        continue;
      }
      final context = contexts[itemId];
      if (context == null) continue;

      final status = nativeWorkerStatusAfterSnapshotStop(
        workerRunning: workerRunning,
        status: itemSnapshot['status']?.toString() ?? 'queued',
      );
      final progress = ((itemSnapshot['progress'] as num?)?.toDouble() ?? 0.0)
          .clamp(0.0, 1.0)
          .toDouble();
      final current = _findItemById(itemId);
      if (current == null) {
        reconciledIds.add(itemId);
        continue;
      }

      if (status == 'queued') {
        updateItemStatus(itemId, DownloadStatus.queued, progress: 0.0);
        continue;
      }

      if (status == 'preparing') {
        updateItemStatus(itemId, DownloadStatus.downloading, progress: 0.0);
        continue;
      }

      if (status == 'downloading') {
        updateItemStatus(
          itemId,
          DownloadStatus.downloading,
          progress: progress,
        );
        continue;
      }

      if (status == 'finalizing') {
        updateItemStatus(
          itemId,
          DownloadStatus.finalizing,
          progress: nativeWorkerFinalizingProgress(progress),
        );
        continue;
      }

      if (status == 'completed') {
        final result = itemSnapshot['result'];
        if (result is Map) {
          try {
            await _completeAndroidNativeWorkerItem(
              context,
              Map<String, dynamic>.from(result),
              settings,
            );
            if (!ref.mounted || clearGeneration != _clearGeneration) return;
            reconciledIds.add(itemId);
          } catch (e) {
            if (!ref.mounted || clearGeneration != _clearGeneration) return;
            // A native output can be complete while Library persistence or
            // Dart-side adoption fails. Do not leave the queue permanently at
            // 100%: surface the reconciliation failure and keep processing
            // the rest of the worker batch.
            if (_findItemById(itemId) != null) {
              _recordFailedDownload(
                itemId,
                error: 'Downloaded file could not be added to the Library: $e',
                errorType: DownloadErrorType.libraryAddFailed,
              );
            }
            reconciledIds.add(itemId);
          }
        }
        continue;
      }

      if (status == 'failed' || status == 'skipped') {
        final result = itemSnapshot['result'];
        final error = itemSnapshot['error']?.toString();
        if (status == 'skipped') {
          reconciledIds.add(itemId);
          updateItemStatus(itemId, DownloadStatus.skipped);
        } else {
          final resultMap = result is Map
              ? Map<String, dynamic>.from(result)
              : null;
          final errorMsg = (error == null || error.isEmpty)
              ? (resultMap?['error']?.toString() ?? 'Download failed')
              : error;
          final errorType = _classifyBackendDownloadFailure(
            resultMap?['error_type']?.toString(),
            errorMsg,
          );
          try {
            if (await _recoverNativeWorkerStorageFailure(
              context: context,
              errorType: resultMap?['error_type']?.toString() ?? '',
              errorMessage: errorMsg,
              diagnosticStage: resultMap?['failure_stage'],
              recordDiagnostic:
                  errorType != DownloadErrorType.verificationRequired &&
                  BugLog.temporaryErrorType(resultMap?['error_type']) !=
                      'cancelled',
              contexts: contexts,
              reconciledIds: reconciledIds,
            )) {
              continue;
            }
          } catch (_) {
            _log.w('Could not recover native-worker storage failure');
          }
          reconciledIds.add(itemId);
          if (errorType == DownloadErrorType.verificationRequired) {
            _log.i(
              'Android native worker requires verification; switching to interactive queue',
            );
            // Cancelling the native worker marks every remaining batch item
            // "skipped" on the native side. Those items did nothing wrong —
            // remember them now and requeue them below so the batch resumes
            // after the challenge instead of being abandoned.
            final pendingBatchIds = <String>[];
            for (final pendingId in contexts.keys) {
              if (pendingId == itemId || reconciledIds.contains(pendingId)) {
                continue;
              }
              final pending = _findItemById(pendingId);
              if (pending == null) continue;
              if (pending.status == DownloadStatus.queued ||
                  pending.status == DownloadStatus.downloading ||
                  pending.status == DownloadStatus.finalizing) {
                pendingBatchIds.add(pendingId);
              }
            }
            try {
              await PlatformBridge.cancelNativeDownloadWorker();
            } catch (_) {
              _log.w('Failed to cancel native worker before verification');
            }
            for (final pendingId in pendingBatchIds) {
              reconciledIds.add(pendingId);
              updateItemStatus(pendingId, DownloadStatus.queued, progress: 0.0);
            }
            if (_queueStartupPending) {
              // This snapshot predates the browser return. Let startup finish
              // exchanging its callback before retrying through the regular
              // queue; opening another challenge here would race that grant
              // and wait on our own queue-restoration barrier.
              updateItemStatus(itemId, DownloadStatus.queued, progress: 0.0);
              continue;
            }
            await _handleVerificationRequiredDownload(
              current,
              errorMsg,
              _nativeWorkerVerificationService(resultMap, context),
            );
            continue;
          }
          _recordFailedDownload(
            itemId,
            error: errorMsg,
            errorType: errorType,
            diagnosticStage: resultMap?['failure_stage'],
            diagnosticErrorType: resultMap?['error_type'],
            diagnosticCause: resultMap?['diagnostic_cause'],
            // Provider reported for the retained failure; not the full fallback history.
            diagnosticProvider: resultMap?['service'],
            diagnosticProviderAttempts: resultMap?['provider_attempts'],
          );
        }
      }
    }

    final releasableIds = contexts.keys
        .where(reconciledIds.contains)
        .toList(growable: false);
    if (!ref.mounted ||
        clearGeneration != _clearGeneration ||
        releasableIds.isEmpty) {
      return;
    }

    // Restored state is already published here; startup adoption must not
    // await the public lifecycle gate whose completion depends on adoption.
    try {
      await _queuePersistence.flush(requireDurable: true);
    } catch (error) {
      _log.w('Could not persist native results before acknowledgement');
      throw _NativeResultPersistenceFailure(error);
    }
    if (!ref.mounted || clearGeneration != _clearGeneration) return;
    if (!workerRunning) {
      for (final itemId in releasableIds) {
        contexts.remove(itemId);
        reconciledIds.remove(itemId);
      }
      return;
    }

    final runId = _snapshotRunId(snapshot);
    if (runId.isEmpty) return;
    try {
      await PlatformBridge.acknowledgeNativeDownloadWorkerItems(
        runId: runId,
        itemIds: releasableIds,
      );
      for (final itemId in releasableIds) {
        contexts.remove(itemId);
        reconciledIds.remove(itemId);
      }
    } catch (e) {
      // Keep contexts so the acknowledgement is retried on the next poll.
      // This also keeps the preparation window bounded while native results
      // are still retained by the service.
      _log.w('Could not release reconciled native queue items');
    }
  }

  Future<void> _completeAndroidNativeWorkerItem(
    _NativeWorkerRequestContext context,
    Map<String, dynamic> rawResult,
    AppSettings settings,
  ) async {
    if (!ref.mounted) return;
    final result = DownloadResult.fromMap(rawResult);
    context = context.withResolvedFolder(result);
    final item = context.item;
    var filePath = result.filePath;
    if (filePath == null || filePath.isEmpty) {
      _recordFailedDownload(
        item.id,
        error: 'Native worker completed without a file path',
        errorType: DownloadErrorType.emptyResult,
      );
      return;
    }

    if (result.nativeFinalized) {
      final nativeFinalizedFilePath = filePath;
      await _saveDownloadedMotionArtwork(ref, item, item.track, result);
      if (!ref.mounted) return;
      await persistBeforePublishingDownloadCompletion(
        persist: () async {
          await DownloadFileInventory.record(
            item.track,
            nativeFinalizedFilePath,
          );
          if (!ref.mounted || !settings.saveDownloadHistory) return;
          final history = ref.read(downloadHistoryProvider.notifier);
          await reconcileNativeDownloadHistory(
            result: result,
            adopt: (json) => history.adoptNativeHistoryItem(
              DownloadHistoryItem.fromJson(json),
              preserveTrackVariant: item.preserveQualityVariant,
              origin: _resolvedOrigin(item),
            ),
            reload: history.reloadFromStorage,
            persistFallback: () => _persistNativeFinalizedHistoryFallback(
              context,
              result,
              nativeFinalizedFilePath,
            ),
          );
        },
        publish: () {
          if (!ref.mounted) return;
          _completedInSession++;
          updateItemStatus(
            item.id,
            DownloadStatus.completed,
            progress: 1.0,
            filePath: nativeFinalizedFilePath,
          );
        },
      );
      if (ref.mounted) _removeCompletedItem(item.id);
      return;
    }

    final rawDecryptFileName =
        result.fileName ?? context.safFileName ?? 'track';
    final decryptOutcome = await _fileFinalizer.decrypt(
      result: result,
      filePath: filePath,
      useSaf: context.storageMode == 'saf',
      treeUri: context.downloadTreeUri,
      relativeDir: context.safRelativeDir ?? '',
      baseName: rawDecryptFileName.replaceFirst(RegExp(r'\.[^.]+$'), ''),
      extensionFallback: context.outputExt,
      repairContainer: false,
      onStart: (strategy) =>
          _log.i('Native worker is decrypting an encrypted stream'),
    );
    if (!ref.mounted) return;
    if (decryptOutcome.path == null) {
      _recordFailedDownload(
        item.id,
        error: 'Failed to decrypt encrypted stream',
        errorType: DownloadErrorType.decryptFailed,
      );
      return;
    }
    filePath = decryptOutcome.path!;
    if (decryptOutcome.fileName != null) {
      result.fileName = decryptOutcome.fileName;
    }

    var actualQuality = _fetchedQualityId(result) ?? context.quality;
    var actualBitDepth = result.actualBitDepth;
    var actualSampleRate = result.actualSampleRate;
    var actualFormat =
        normalizeAudioFormatValue(
          result['audio_codec']?.toString() ?? result['format']?.toString(),
        ) ??
        normalizeAudioFormatValue(audioFormatForPath(filePath));
    var actualBitrate = readPositiveBitrateKbps(
      result['bitrate'] ?? result['actual_bitrate'],
    );
    final resolvedQuality = resolveDisplayQuality(
      filePath: filePath,
      detectedFormat: actualFormat,
      bitDepth: actualBitDepth,
      sampleRate: actualSampleRate,
      bitrateKbps: actualBitrate,
      storedQuality: actualQuality,
    );
    if (resolvedQuality != null) {
      actualQuality = resolvedQuality;
    }

    final resolvedAlbumArtist = DownloadMetadataResolver.albumArtistForMetadata(
      item.track,
      settings,
    );
    final trackToDownload = buildTrackForMetadataEmbedding(
      item.track,
      result,
      resolvedAlbumArtist,
    );
    final convertedContainerPath =
        await _finalizeNativeWorkerContainerConversion(
          context: context,
          result: result,
          settings: settings,
          track: trackToDownload,
          filePath: filePath,
        );
    if (!ref.mounted) return;
    if (convertedContainerPath == null) {
      _recordFailedDownload(
        item.id,
        error: 'Failed to convert downloaded container',
        errorType: DownloadErrorType.conversionFailed,
      );
      return;
    }
    filePath = convertedContainerPath;

    final postProcessedPath = await _runPostProcessingHooks(
      filePath,
      trackToDownload,
      item.id,
    );
    if (!ref.mounted) return;
    if (postProcessedPath != null && postProcessedPath.isNotEmpty) {
      filePath = postProcessedPath;
    }
    if (settings.embedMetadata &&
        _isMp4Container(result['file_name']?.toString() ?? filePath)) {
      // Native lossy containers still need tags and lyrics.
      Future<void> embedNativeMetadata(String path) async {
        if (!ref.mounted) return;
        final lyrics = await _embedMetadataToFile(
          path,
          trackToDownload,
          format: 'm4a',
          genre: result['genre'] as String?,
          label: result['label'] as String?,
          copyright: result['copyright'] as String?,
          comment: result['comment'] as String?,
          lyricsLrc: result['lyrics_lrc'] as String?,
          downloadService: context.item.service,
          writeExternalLrc: context.storageMode != 'saf',
        );
        if (lyrics != null && lyrics.isNotEmpty) result['lyrics_lrc'] = lyrics;
      }

      if (context.storageMode == 'saf' && isContentUri(filePath)) {
        final treeUri = context.downloadTreeUri;
        if (treeUri != null && treeUri.isNotEmpty) {
          final fileName =
              result['file_name']?.toString() ?? context.safFileName;
          if (fileName != null && fileName.isNotEmpty) {
            final updatedUri = await _replaceSafFileVia(
              uri: filePath,
              treeUri: treeUri,
              relativeDir: context.safRelativeDir ?? '',
              op: (tempPath, _) async {
                await embedNativeMetadata(tempPath);
                return (tempPath, fileName);
              },
            );
            if (updatedUri != null) filePath = updatedUri;
          }
        }
      } else {
        await embedNativeMetadata(filePath);
      }
    }
    if (!ref.mounted) return;
    await _writeNativeWorkerReplayGain(
      settings: settings,
      track: trackToDownload,
      filePath: filePath,
    );

    if (!ref.mounted) return;
    if (item.preserveQualityVariant) {
      final variantOutcome = await _finalizeQualityVariantFilename(
        item: item,
        result: result,
        filePath: filePath,
        storageMode: context.storageMode,
        downloadTreeUri: context.downloadTreeUri,
        safRelativeDir: context.safRelativeDir,
        fileName: result['file_name'] as String? ?? context.safFileName,
        collisionOnly: context.qualityVariantCollisionOnly,
      );
      filePath = variantOutcome.filePath;
      actualBitDepth = readPositiveInt(result['actual_bit_depth']);
      actualSampleRate = readPositiveInt(result['actual_sample_rate']);
      actualFormat =
          normalizeAudioFormatValue(result['audio_codec']?.toString()) ??
          normalizeAudioFormatValue(audioFormatForPath(filePath));
      actualBitrate = readPositiveBitrateKbps(
        result['bitrate'] ?? result['actual_bitrate'],
      );
      final finalQuality = resolveDisplayQuality(
        filePath: filePath,
        fileName: variantOutcome.fileName,
        detectedFormat: actualFormat,
        bitDepth: actualBitDepth,
        sampleRate: actualSampleRate,
        bitrateKbps: actualBitrate,
        storedQuality: actualQuality,
      );
      if (finalQuality != null) actualQuality = finalQuality;
    }

    if (!ref.mounted) return;
    final externalLrcWritten = await _saveExternalLrc(
      result: result,
      settings: settings,
      extensionState: ref.read(extensionProvider),
      track: trackToDownload,
      service: context.item.service,
      filePath: filePath,
      storageMode: context.storageMode,
      downloadTreeUri: context.downloadTreeUri,
      safRelativeDir: context.safRelativeDir ?? '',
      resolveBaseName: () async {
        final resultFileName = result['file_name'] as String?;
        final fileName = (resultFileName != null && resultFileName.isNotEmpty)
            ? resultFileName
            : context.safFileName;
        return fileName != null && fileName.isNotEmpty
            ? fileName.replaceFirst(RegExp(r'\.[^.]+$'), '')
            : await PlatformBridge.sanitizeFilename(
                '${trackToDownload.artistName} - ${trackToDownload.name}',
              );
      },
      onFetchError: (e) => _log.w('Failed to fetch native-worker external LRC'),
    );

    final resultSafFileName = result['file_name'] as String?;
    final audio = await resolveDownloadCompletionAudio(
      result: result,
      filePath: filePath,
      fileName: resultSafFileName,
      quality: actualQuality,
      readMetadata: PlatformBridge.readFileMetadata,
      debug: _log.d,
    );

    if (!ref.mounted) return;
    final completedFilePath = filePath;
    await _saveDownloadedMotionArtwork(ref, item, trackToDownload, result);
    if (!ref.mounted) return;
    final lyricsAvailability = await _resolveFinalLyricsAvailability(
      filePath: completedFilePath,
      externalLrcWritten: externalLrcWritten,
    );
    if (!ref.mounted) return;
    await persistBeforePublishingDownloadCompletion(
      persist: () async {
        await DownloadFileInventory.record(item.track, completedFilePath);
        if (!ref.mounted || !settings.saveDownloadHistory) return;
        await ref
            .read(downloadHistoryProvider.notifier)
            .addToHistory(
              _historyItemFromResult(
                item: item,
                trackToDownload: trackToDownload,
                result: result,
                filePath: completedFilePath,
                quality: audio.quality,
                useSaf: context.storageMode == 'saf',
                downloadTreeUri: context.downloadTreeUri,
                safRelativeDir: context.safRelativeDir,
                safFileName:
                    (resultSafFileName != null && resultSafFileName.isNotEmpty)
                    ? resultSafFileName
                    : context.safFileName,
                bitDepth: audio.bitDepth,
                sampleRate: audio.sampleRate,
                bitrate: audio.bitrate,
                format: audio.format,
                genre: normalizeOptionalString(result['genre'] as String?),
                label: normalizeOptionalString(result['label'] as String?),
                copyright: normalizeOptionalString(
                  result['copyright'] as String?,
                ),
                hasLyrics: lyricsAvailability.hasLyrics,
                lyricsMetadataScanVersion: lyricsAvailability.scanVersion,
                hasReplayGain: lyricsAvailability.hasReplayGain,
                replayGainMetadataScanVersion:
                    lyricsAvailability.replayGainScanVersion,
              ),
              preserveTrackVariant: item.preserveQualityVariant,
              origin: _resolvedOrigin(item),
            );
      },
      publish: () {
        if (!ref.mounted) return;
        _completedInSession++;
        updateItemStatus(
          item.id,
          DownloadStatus.completed,
          progress: 1.0,
          filePath: completedFilePath,
        );
      },
    );
    if (!ref.mounted) return;
    // Quality-variant renaming may have changed the path since the scan.
    _updateAlbumRgFilePath(trackToDownload, completedFilePath);
    await _checkAndWriteAlbumReplayGain(trackToDownload);
    if (ref.mounted) _removeCompletedItem(item.id);
  }

  Future<void> _writeNativeWorkerReplayGain({
    required AppSettings settings,
    required Track track,
    required String filePath,
  }) async {
    if (!settings.embedReplayGain) {
      return;
    }
    final ext = audioFormatForPath(filePath)?.toLowerCase();
    if (ext != 'flac' &&
        ext != 'm4a' &&
        ext != 'mp3' &&
        ext != 'opus' &&
        !isContentUri(filePath)) {
      return;
    }

    try {
      final rgResult = await ReplayGainService.scanAndApplyToFile(filePath);
      if (rgResult == null) {
        return;
      }
      _storeTrackReplayGainForAlbum(track, filePath, rgResult);
      _log.d('Native-worker ReplayGain written');
    } catch (_) {
      _log.w('Failed to write native-worker ReplayGain');
    }
  }

  String _nativeWorkerVerificationService(
    Map<String, dynamic>? result,
    _NativeWorkerRequestContext context,
  ) {
    if (result != null) {
      for (final key in const [
        'service',
        'verification_service',
        'provider',
        'source',
      ]) {
        final value = result[key]?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }
    return context.item.service;
  }
}
