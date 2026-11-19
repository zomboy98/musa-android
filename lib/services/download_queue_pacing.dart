import 'package:mornye/models/download_item.dart';

class DownloadQueuePacing {
  DownloadQueuePacing({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  static const deezerGap = Duration(seconds: 2);
  static const providerGap = Duration(seconds: 4);
  static const failureThreshold = 3;
  static const failurePause = Duration(minutes: 5);
  static const _countedFailures = {
    DownloadErrorType.rateLimit,
    DownloadErrorType.timeout,
    DownloadErrorType.providerError,
    DownloadErrorType.transientNetwork,
  };

  final DateTime Function() _clock;
  DateTime? _lastFinished;
  String? _streakService;
  int _streak = 0;

  static String _normalize(String service) => service.trim().toLowerCase();

  static Duration gapFor(String service) =>
      _normalize(service) == 'deezer' ? deezerGap : providerGap;

  static bool countsAsProviderFailure(DownloadErrorType? type) =>
      type != null && _countedFailures.contains(type);

  void markFinished() => _lastFinished = _clock();

  Duration remainingGap(String service) {
    final last = _lastFinished;
    if (last == null) return Duration.zero;
    final left = gapFor(service) - _clock().difference(last);
    return left > Duration.zero ? left : Duration.zero;
  }

  void recordSuccess() {
    _streakService = null;
    _streak = 0;
  }

  bool recordFailure(String service, DownloadErrorType? type) {
    if (!countsAsProviderFailure(type)) {
      recordSuccess();
      return false;
    }
    final id = _normalize(service);
    if (_streakService != id) {
      _streakService = id;
      _streak = 0;
    }
    _streak++;
    if (_streak < failureThreshold) return false;
    recordSuccess();
    return true;
  }

  void reset() {
    _lastFinished = null;
    recordSuccess();
  }
}
