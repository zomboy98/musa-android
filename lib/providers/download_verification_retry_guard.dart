import 'dart:async';

class DownloadVerificationRetryGuard {
  final Set<String> _grantedRetryKeys = {};
  final Set<String> _authenticatedRetryKeys = {};

  bool tryAuthenticatedRetry(String itemId, String service) =>
      _authenticatedRetryKeys.add(_key(itemId, service));

  bool hasRetriedAfterGrant(String itemId, String service) =>
      _grantedRetryKeys.contains(_key(itemId, service));

  void recordVerificationResult(
    String itemId,
    String service, {
    required bool granted,
  }) {
    if (granted) {
      _grantedRetryKeys.add(_key(itemId, service));
    }
  }

  void clearItem(String itemId) {
    bool matches(String key) => key == itemId || key.startsWith('$itemId::');
    _grantedRetryKeys.removeWhere(matches);
    _authenticatedRetryKeys.removeWhere(matches);
  }

  void retainItems(Set<String> itemIds) {
    bool missing(String key) => !itemIds.contains(key.split('::').first);
    _grantedRetryKeys.removeWhere(missing);
    _authenticatedRetryKeys.removeWhere(missing);
  }

  String _key(String itemId, String service) =>
      '$itemId::${service.trim().toLowerCase()}';
}

/// Shares one verification challenge between downloads for the same service
/// while still allowing each queue item to stop waiting independently.
///
/// When the last waiter leaves, [startFlow]'s cancellation signal completes so
/// browser timers and grant subscriptions can be released immediately.
class DownloadVerificationWaitCoordinator<T> {
  DownloadVerificationWaitCoordinator(this._cancelledResult);

  final T _cancelledResult;
  final Map<String, _ActiveDownloadVerificationFlow<T>> _flowsByService = {};
  final Map<String, Completer<void>> _cancellationsByItem = {};

  bool hasActiveFlow(String service) =>
      _flowsByService.containsKey(_serviceKey(service));

  bool hasActiveWaiter(String itemId) =>
      _cancellationsByItem.containsKey(itemId);

  Future<({R? value})?> waitForPreflight<R>({
    required String itemId,
    required Future<R?> Function() lookup,
    required Duration timeout,
  }) async {
    final cancellation = _beginItemWait(itemId);
    try {
      return await Future.any<({R? value})?>([
        Future<R?>.sync(lookup).then((value) => (value: value)),
        cancellation.future.then((_) => null),
      ]).timeout(timeout);
    } finally {
      _endItemWait(itemId, cancellation);
    }
  }

  Future<T> waitForGrant({
    required String itemId,
    required String service,
    required Future<T> Function(Future<void> cancellationSignal) startFlow,
  }) {
    final itemCancellation = _beginItemWait(itemId);

    final serviceKey = _serviceKey(service);
    var activeFlow = _flowsByService[serviceKey];
    if (activeFlow == null) {
      final flowCancellation = Completer<void>();
      final result = Future<T>.sync(() => startFlow(flowCancellation.future));
      activeFlow = _ActiveDownloadVerificationFlow(
        result: result,
        cancellation: flowCancellation,
      );
      _flowsByService[serviceKey] = activeFlow;
    }

    final waiter = Object();
    activeFlow.waiters.add(waiter);
    return _waitForGrant(
      itemId: itemId,
      serviceKey: serviceKey,
      activeFlow: activeFlow,
      waiter: waiter,
      itemCancellation: itemCancellation,
    );
  }

  Future<T> _waitForGrant({
    required String itemId,
    required String serviceKey,
    required _ActiveDownloadVerificationFlow<T> activeFlow,
    required Object waiter,
    required Completer<void> itemCancellation,
  }) async {
    try {
      return await Future.any<T>([
        activeFlow.result,
        itemCancellation.future.then((_) => _cancelledResult),
      ]);
    } finally {
      _endItemWait(itemId, itemCancellation);
      activeFlow.waiters.remove(waiter);
      if (activeFlow.waiters.isEmpty &&
          identical(_flowsByService[serviceKey], activeFlow)) {
        _flowsByService.remove(serviceKey);
        if (!activeFlow.cancellation.isCompleted) {
          activeFlow.cancellation.complete();
        }
      }
    }
  }

  Completer<void> _beginItemWait(String itemId) {
    cancelItem(itemId);
    final cancellation = Completer<void>();
    _cancellationsByItem[itemId] = cancellation;
    return cancellation;
  }

  void _endItemWait(String itemId, Completer<void> cancellation) {
    if (identical(_cancellationsByItem[itemId], cancellation)) {
      _cancellationsByItem.remove(itemId);
    }
  }

  void cancelItem(String itemId) {
    final cancellation = _cancellationsByItem[itemId];
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  void cancelAll() {
    for (final cancellation in _cancellationsByItem.values.toList()) {
      if (!cancellation.isCompleted) cancellation.complete();
    }
  }

  String _serviceKey(String service) => service.trim().toLowerCase();
}

class _ActiveDownloadVerificationFlow<T> {
  _ActiveDownloadVerificationFlow({
    required this.result,
    required this.cancellation,
  });

  final Future<T> result;
  final Completer<void> cancellation;
  final Set<Object> waiters = {};
}
