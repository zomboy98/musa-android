// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

extension _DownloadQueuePacing on DownloadQueueNotifier {
  bool _itemUsesFallback(DownloadItem item) =>
      state.autoFallback && !item.fromBatch;

  bool _queueNeedsPacedProcessing() {
    for (final item in state.items) {
      if (item.fromBatch &&
          (item.status == DownloadStatus.queued ||
              item.status == DownloadStatus.downloading ||
              item.status == DownloadStatus.finalizing)) {
        return true;
      }
      if (item.status != DownloadStatus.queued) continue;
      final service = _normalizeQueuedService(item.service);
      if (service.isNotEmpty &&
          ProviderCooldown.instance.isCoolingDown(service)) {
        return true;
      }
    }
    return false;
  }

  int _queueConcurrency() => 1;

  bool get _foregroundLive =>
      _foregroundChains > 0 ||
      state.items.any(
    (item) =>
        _foregroundItemIds.contains(item.id) &&
        (item.status == DownloadStatus.queued ||
            item.status == DownloadStatus.downloading ||
            item.status == DownloadStatus.finalizing),
  );

  /// Items the scheduler may start. While a quality replacement for the song
  /// that is playing is queued or running, it is the only one.
  Iterable<DownloadItem> _schedulableItems() {
    final eligible = state.queuedItems.where(
      (item) => !_selectionBarrier && !_pausePendingItemIds.contains(item.id),
    );
    if ((_foregroundItemIds.isEmpty && _foregroundChains == 0) || !_foregroundLive) {
      return eligible;
    }
    return eligible.where((item) => _foregroundItemIds.contains(item.id));
  }

  /// Puts the replacement [id] ahead of every other download: those running
  /// go back to the queue and none starts until it ends.
  void _yieldQueueTo(String id) {
    _foregroundItemIds.add(id);
    var paused = 0;
    final nativeWorker = _hasActiveAndroidNativeWorker;
    for (final other in state.items.toList(growable: false)) {
      if (other.id == id || _foregroundItemIds.contains(other.id)) continue;
      switch (other.status) {
        case DownloadStatus.queued:
          paused++;
        case DownloadStatus.downloading:
        case DownloadStatus.finalizing:
          paused++;
          if (nativeWorker) break;
          _pausePendingItemIds.add(other.id);
          _requestNativeCancel(other.id);
          _requeueItemForPause(other.id);
        default:
          break;
      }
    }
    debugPrint('quality-switch: priority pause=$paused resume=0');
  }

  /// The replacement [id] ended, however it ended: the rest of the queue
  /// goes on by itself.
  void _releaseForeground(String id) {
    if (!_foregroundItemIds.remove(id)) return;
    if (!ref.mounted || _foregroundChains > 0) return;
    final resumed = state.items
        .where(
          (item) =>
              item.status == DownloadStatus.queued &&
              !_foregroundItemIds.contains(item.id),
        )
        .length;
    debugPrint('quality-switch: priority pause=0 resume=$resumed');
    if (!state.isPaused && resumed > 0 && !state.isProcessing) {
      Future.microtask(_processQueue);
    }
  }

  Duration _startDelayFor(DownloadItem item) {
    if (_foregroundItemIds.contains(item.id)) return Duration.zero;
    final service = _normalizeQueuedService(item.service);
    if (service.isNotEmpty && !_itemUsesFallback(item)) {
      final cooling = ProviderCooldown.instance.remaining(service);
      if (cooling > Duration.zero) {
        _autoPauseQueue(cooling, service: service);
        return cooling;
      }
    }
    return _pacing.remainingGap(service);
  }

  void _afterQueueItemFinished(String id) {
    _pacing.markFinished();
    if (_foregroundItemIds.contains(id)) {
      _releaseForeground(id);
      return;
    }
    if (!ref.mounted) return;
    final item = _findItemById(id);
    if (item == null) return;
    final service = _normalizeQueuedService(item.service);
    switch (item.status) {
      case DownloadStatus.completed:
        _pacing.recordSuccess();
      case DownloadStatus.failed:
        final streakReached = _pacing.recordFailure(service, item.errorType);
        final cooling = service.isEmpty
            ? Duration.zero
            : ProviderCooldown.instance.remaining(service);
        if (cooling > Duration.zero) {
          _autoPauseQueue(cooling, service: service);
        } else if (streakReached) {
          _autoPauseQueue(DownloadQueuePacing.failurePause);
        }
      default:
        break;
    }
  }

  void _markWaitingForCooldown(String service) {
    final replacements = <int, DownloadItem>{};
    final items = state.items;
    for (var i = 0; i < items.length; i++) {
      final current = items[i];
      if (current.status != DownloadStatus.queued ||
          current.preparationStage == DownloadQueueNotifier.cooldownWaitText ||
          _normalizeQueuedService(current.service) != service) {
        continue;
      }
      replacements[i] = current.copyWith(
        preparationStage: DownloadQueueNotifier.cooldownWaitText,
      );
    }
    if (replacements.isEmpty) return;
    state = state.withItemReplacements(replacements);
    _saveQueueToStorage();
  }

  void _autoPauseQueue(Duration duration, {String? service}) {
    if (!ref.mounted) return;
    if (service != null && service.isNotEmpty) _markWaitingForCooldown(service);
    if (state.isPaused) return;
    _autoResumeTimer?.cancel();
    pauseQueue(persistAcrossRestarts: false);
    if (!state.isPaused) return;
    _autoPaused = true;
    _log.w('Queue paused automatically; resuming in ${duration.inSeconds}s');
    _autoResumeTimer = Timer(duration, _resumeAfterAutoPause);
  }

  void _resumeAfterAutoPause() {
    _autoResumeTimer = null;
    if (!ref.mounted || !_autoPaused) return;
    _autoPaused = false;
    resumeQueue();
  }

  void _clearAutoPause() {
    _autoResumeTimer?.cancel();
    _autoResumeTimer = null;
    _autoPaused = false;
  }
}
