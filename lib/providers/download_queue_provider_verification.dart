// ignore_for_file: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
part of 'download_queue_provider.dart';

/// How many times a download waits for another verification panel to end and
/// then retries its own challenge. Each wait needs a real release signal and is
/// bounded by [extensionVerificationGrantTimeout] and cancellation.
const _maxBusyVerificationPanelWaits = 2;

extension _DownloadQueueVerificationGate on DownloadQueueNotifier {
  Future<void> _handleVerificationNotificationTap(
    VerificationNotification target,
  ) async {
    await _queueRestored.future;
    if (!ref.mounted) return;
    final item = _findItemById(target.itemId);
    if (item != null &&
        (item.status == DownloadStatus.completed ||
            item.status == DownloadStatus.skipped ||
            _isLocallyCancelled(item.id, item: item))) {
      return;
    }
    // Foregrounding wakes an existing queue waiter. Do not replace it or
    // reopen a browser that the queue already owns.
    if ((item != null &&
            _verificationWaitCoordinator.hasActiveWaiter(item.id)) ||
        _verificationWaitCoordinator.hasActiveFlow(target.extensionId)) {
      return;
    }
    // Older builds did not retain verification failures. The notification
    // still identifies the extension if its queue item is already missing.
    final verification = await _openVerificationAndWait(
      item?.id ?? 'notification:${target.tapId}',
      target.extensionId,
    );
    if (!ref.mounted || !verification.successful || state.isPaused) return;
    final current = _findItemById(target.itemId);
    if (current != null &&
        current.status == DownloadStatus.failed &&
        current.errorType == DownloadErrorType.verificationRequired &&
        !_isLocallyCancelled(current.id, item: current)) {
      await retryItem(current.id, selectForPlayback: false);
    }
  }

  /// Completes when the app is in the foreground. Verification challenges
  /// can only be handled there: launching a browser from the background is
  /// blocked by the OS and the challenge would expire unseen.
  Future<bool> _waitForForeground(Future<void> cancellationSignal) async {
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
      return true;
    }
    final completer = Completer<void>();
    final listener = AppLifecycleListener(
      onResume: () {
        if (!completer.isCompleted) completer.complete();
      },
    );
    try {
      return await Future.any<bool>([
        completer.future.then((_) => true),
        cancellationSignal.then((_) => false),
      ]);
    } finally {
      listener.dispose();
    }
  }

  Future<ExtensionVerificationResult> _openVerificationAndWait(
    String itemId,
    String extensionId,
  ) {
    if (_verificationWaitCoordinator.hasActiveFlow(extensionId)) {
      _log.i('Joining active verification flow');
    }

    return _verificationWaitCoordinator.waitForGrant(
      itemId: itemId,
      service: extensionId,
      startFlow: (cancellationSignal) =>
          _runVerificationFlow(extensionId, cancellationSignal),
    );
  }

  Future<ExtensionVerificationResult> _runVerificationFlow(
    String extensionId,
    Future<void> cancellationSignal,
  ) async {
    // Completes when every queue item waiting on this flow was cancelled,
    // paused or removed: no further challenge may be opened after that.
    var cancelled = false;
    unawaited(cancellationSignal.then((_) => cancelled = true));
    var busyPanelWaits = 0;
    while (true) {
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        _log.i(
          'Verification is waiting for the app to return to the foreground',
        );
        final reachedForeground = await _waitForForeground(cancellationSignal);
        if (!reachedForeground || cancelled) {
          _log.i(
            'Verification wait was cancelled before the app returned to the foreground',
          );
          return ExtensionVerificationResult.failed;
        }
      }

      // Finish the durable write before handing control to another app; a
      // background lifecycle callback may not finish before Android kills us.
      try {
        await flushQueuePersistence(requireDurable: true);
      } catch (_) {
        _log.w('Could not save downloads before verification');
        return ExtensionVerificationResult.failed;
      }
      if (!ref.mounted || cancelled) return ExtensionVerificationResult.failed;
      // The app may have been backgrounded while the flush was pending. Go back
      // to the top of the loop, which waits (cancellably) for the foreground
      // instead of launching the panel from the background.
      if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        continue;
      }
      final result = await resolveExtensionVerification(
        extensionId,
        browserMode: ref
            .read(settingsProvider)
            .extensionVerificationBrowserMode,
        cancellationSignal: cancellationSignal,
      );
      // Only `busy` caused by another panel this app is showing (e.g. a search
      // verification) is retried, and only once that panel really ended. A
      // panel the user closed, an error or a grant is never retried here.
      if (!result.panelBusy ||
          busyPanelWaits >= _maxBusyVerificationPanelWaits) {
        return result;
      }
      busyPanelWaits++;
      _log.i('Another verification panel is open; waiting for it to end');
      final released = await awaitVerificationPanelRelease(
        result,
        cancellationSignal: cancellationSignal,
      );
      if (!released || cancelled || !ref.mounted) return result;
      _log.i('Verification panel ended; opening the download challenge');
    }
  }

  bool _retryAuthenticatedDownload(String itemId, String service) {
    if (!_verificationRetryGuard.tryAuthenticatedRetry(itemId, service)) {
      return false;
    }
    updateItemStatus(
      itemId,
      DownloadStatus.queued,
      progress: 0,
      speedMBps: 0,
      error: '',
      errorType: DownloadErrorType.unknown,
    );
    _saveQueueToStorage();
    return true;
  }

  void _recordVerificationLookupError(String itemId, Object error) {
    final errorType = _downloadErrorTypeFromMessage(error.toString());
    _recordFailedDownload(
      itemId,
      error: 'Could not check provider authentication',
      errorType: switch (errorType) {
        DownloadErrorType.unknown || DownloadErrorType.verificationRequired =>
          DownloadErrorType.providerError,
        _ => errorType,
      },
    );
  }

  Future<bool> _handleVerificationRequiredDownload(
    DownloadItem item,
    String errorMsg,
    String? verificationService,
  ) async {
    final targetService = (verificationService ?? '').trim().isNotEmpty
        ? verificationService!.trim()
        : item.service;
    var canVerify = !_verificationRetryGuard.hasRetriedAfterGrant(
      item.id,
      targetService,
    );
    if (canVerify &&
        !_verificationWaitCoordinator.hasActiveFlow(targetService)) {
      ({Map<String, dynamic>? value})? preflight;
      Object? preflightError;
      try {
        preflight = await _verificationWaitCoordinator.waitForPreflight(
          itemId: item.id,
          lookup: () => PlatformBridge.getExtensionPendingAuth(targetService),
          timeout: extensionVerificationGrantTimeout,
        );
      } catch (error) {
        preflightError = error;
      }
      if (!ref.mounted) return true;
      final current = _findItemById(item.id);
      if (current == null || _isLocallyCancelled(item.id, item: current)) {
        return true;
      }
      if (_isPausePending(item.id)) {
        _requeueItemForPause(item.id);
        _pausePendingItemIds.remove(item.id);
        return true;
      }
      if (preflight == null && preflightError == null) return true;
      canVerify =
          _verificationWaitCoordinator.hasActiveFlow(targetService) ||
          preflight?.value?['auth_url']?.toString().trim().isNotEmpty == true;
      if (!canVerify &&
          preflight?.value?['authenticated'] == true &&
          _retryAuthenticatedDownload(item.id, targetService)) {
        return true;
      }
      if (!canVerify && preflightError != null) {
        _recordVerificationLookupError(item.id, preflightError);
        return true;
      }
    }
    if (!canVerify) {
      _recordFailedDownload(
        item.id,
        error: errorMsg,
        errorType: DownloadErrorType.verificationRequired,
      );
      return true;
    }
    _log.i('Download requires verification; waiting for grant');
    updateItemStatus(
      item.id,
      DownloadStatus.downloading,
      error: 'Waiting for verification',
      errorType: DownloadErrorType.verificationRequired,
    );

    // Descargar ya es el consentimiento del usuario: la verificación corre
    // invisible en MainActivity, sin notificación ni aviso de "verificar".
    if (!extensionVerificationIsSilent) {
      try {
        await _notificationService.showVerificationRequired(
          extensionId: targetService,
          itemId: item.id,
        );
      } catch (_) {
        _log.w('Failed to show the verification-required notification');
      }
    }

    late final ExtensionVerificationResult verification;
    try {
      if (!ref.mounted) return true;
      final current = _findItemById(item.id);
      if (current == null || _isLocallyCancelled(item.id, item: current)) {
        return true;
      }
      if (_isPausePending(item.id)) {
        _requeueItemForPause(item.id);
        _pausePendingItemIds.remove(item.id);
        return true;
      }
      verification = await _openVerificationAndWait(item.id, targetService);
    } finally {
      try {
        await _notificationService.cancelVerificationRequired();
      } catch (_) {
        _log.w('Failed to clear the verification-required notification');
      }
    }
    if (!ref.mounted) return true;
    final current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      _log.i('Verification wait stopped after item was removed or cancelled');
      return true;
    }
    if (_isPausePending(item.id)) {
      _requeueItemForPause(item.id);
      _pausePendingItemIds.remove(item.id);
      _log.i('Verification wait stopped because the queue was paused');
      return true;
    }

    if (verification.status == ExtensionVerificationStatus.authenticated &&
        _retryAuthenticatedDownload(item.id, targetService)) {
      return true;
    }
    if (verification.lookupError case final error?) {
      _recordVerificationLookupError(item.id, error);
      return true;
    }

    // Only a completed grant consumes the automatic retry. If bootstrap or
    // browser launch failed before a challenge opened, a later attempt must
    // still be allowed after the network changes.
    final granted = verification.status == ExtensionVerificationStatus.granted;
    _verificationRetryGuard.recordVerificationResult(
      item.id,
      targetService,
      granted: granted,
    );
    if (granted) {
      _log.i('Verification complete; retrying download');
      updateItemStatus(
        item.id,
        DownloadStatus.queued,
        progress: 0,
        speedMBps: 0,
        error: 'Retrying after verification',
        errorType: DownloadErrorType.verificationRequired,
      );
      _saveQueueToStorage();
      return true;
    }

    _recordFailedDownload(
      item.id,
      error: errorMsg,
      errorType: DownloadErrorType.verificationRequired,
    );
    return true;
  }

  int? _retryAfterSeconds(String errorMsg) {
    final lower = errorMsg.toLowerCase();
    final retryAfterMatch = RegExp(
      r'retry[- ]?after(?: seconds)?[:= ]+(\d+)',
      caseSensitive: false,
    ).firstMatch(lower);
    return retryAfterMatch == null
        ? null
        : int.tryParse(retryAfterMatch.group(1) ?? '');
  }

  bool _failForProviderCooldown(DownloadItem item) {
    final service = _normalizeQueuedService(item.service);
    if (service.isEmpty || _itemUsesFallback(item)) {
      return false;
    }
    final left = ProviderCooldown.instance.remaining(service, trace: true);
    if (left <= Duration.zero) return false;
    _recordFailedDownload(
      item.id,
      error: 'Provider cooling down, retry in ${left.inMinutes + 1} min',
      errorType: DownloadErrorType.rateLimit,
    );
    return true;
  }

  Duration _rateLimitBackoffDelay(String errorMsg) {
    final parsedSeconds = _retryAfterSeconds(errorMsg);
    final seconds = (parsedSeconds ?? 30).clamp(5, 300).toInt();
    return Duration(seconds: seconds);
  }

  Future<bool> _handleRateLimitedDownload(
    DownloadItem item,
    String errorMsg,
    String service,
  ) async {
    final requested = _retryAfterSeconds(errorMsg) ?? 0;
    if (requested > 300) {
      ProviderCooldown.instance.note(service, requested);
      return false;
    }
    if (_rateLimitRetriedItemIds.contains(item.id)) {
      return false;
    }
    _rateLimitRetriedItemIds.add(item.id);

    final delay = _rateLimitBackoffDelay(errorMsg);
    _log.i('Rate limited; download will retry after backoff');
    updateItemStatus(
      item.id,
      DownloadStatus.downloading,
      error: 'Rate limited, retrying after ${delay.inSeconds}s',
      errorType: DownloadErrorType.rateLimit,
    );

    // A synchronous state listener may already have cancelled or paused when
    // the backoff status was published. Do not register a new wait afterward.
    if (!ref.mounted) return true;
    var current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      return true;
    }
    if (!_isPausePending(item.id)) {
      await _rateLimitBackoff.wait(item.id, delay);
    }
    if (!ref.mounted) return true;
    current = _findItemById(item.id);
    if (current == null || _isLocallyCancelled(item.id, item: current)) {
      return true;
    }
    if (_isPausePending(item.id)) {
      _requeueItemForPause(item.id);
      await _finishPausedDownload(item.id);
      return true;
    }
    updateItemStatus(
      item.id,
      DownloadStatus.queued,
      progress: 0,
      speedMBps: 0,
      error: 'Retrying after rate limit',
      errorType: DownloadErrorType.rateLimit,
    );
    _saveQueueToStorage();
    return true;
  }
}
