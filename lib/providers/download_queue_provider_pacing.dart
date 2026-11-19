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

  Duration _startDelayFor(DownloadItem item) {
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
