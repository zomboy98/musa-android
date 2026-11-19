/// How many songs ahead of the current one are kept prepared by default.
const int defaultPrefetchWindow = 3;

/// The most songs ahead of the current one that may be kept prepared.
const int maxPrefetchWindow = 5;

/// First wait after a song fails to prepare; it doubles per failure.
const Duration prefetchRetryBase = Duration(seconds: 15);

/// The longest wait before a failed song is tried again.
const Duration prefetchRetryCeiling = Duration(minutes: 2);

/// Songs failing at once after which preparing waits for the first to retry,
/// so a provider that is down is not asked for every song in the queue.
const int prefetchFailureSkipLimit = 2;

/// Wait before the next try of a song that has failed [failures] times.
Duration prefetchRetryDelay(
  int failures, {
  Duration base = prefetchRetryBase,
  Duration ceiling = prefetchRetryCeiling,
}) {
  if (failures <= 0) return Duration.zero;
  final shift = failures - 1 > 10 ? 10 : failures - 1;
  final delay = base * (1 << shift);
  return delay > ceiling ? ceiling : delay;
}

/// A short form of a song key that is safe to log.
String shortPrefetchId(String key) =>
    key.length <= 10 ? key : key.substring(0, 10);

/// Queue positions after [index] in play order, at most [lookahead] of them.
/// Repeat all wraps to the start of the queue, except in shuffle mode, where
/// the next pass opens with a song picked when it begins; repeat one replays
/// the current song, so nothing is ahead.
List<int> prefetchUpcomingIndexes({
  required int index,
  required int length,
  required int lookahead,
  bool repeatAll = false,
  bool repeatOne = false,
  bool shuffle = false,
}) {
  if (repeatOne || index < 0 || index >= length) return const [];
  final wraps = repeatAll && !shuffle;
  final indexes = <int>[];
  for (var step = 1; step <= lookahead && step < length; step++) {
    var i = index + step;
    if (i >= length) {
      if (!wraps) break;
      i -= length;
    }
    indexes.add(i);
  }
  return indexes;
}

class PrefetchPlan {
  const PrefetchPlan({
    required this.window,
    required this.ready,
    required this.toStart,
    required this.toCancel,
  });

  /// The songs that should be prepared now, in play order.
  final List<String> window;

  /// How many songs of [window] are already prepared.
  final int ready;

  /// Songs to start preparing, in play order.
  final List<String> toStart;

  /// Songs being prepared that are no longer in [window].
  final List<String> toCancel;
}

/// Decides which of the songs coming up should be prepared. It looks at keys
/// only, so it holds no state: the caller keeps what is ready, running and
/// failed, and applies the answer.
///
/// [upcoming] is the play order after the current song, already wrapped for
/// repeat and fixed by shuffle, without songs that need no preparing. The
/// first [count] songs that are not [blocked] form the window, so a song that
/// fails or waits never takes a place from the ones behind it. Songs start in
/// order, never more than [maxConcurrent] at once, and only when [allowStart].
PrefetchPlan planPrefetch({
  required List<String> upcoming,
  required int count,
  Set<String> ready = const {},
  Set<String> inFlight = const {},
  Set<String> blocked = const {},
  int maxConcurrent = 1,
  bool allowStart = true,
}) {
  final window = <String>[];
  if (count > 0) {
    for (final id in upcoming) {
      if (blocked.contains(id) || window.contains(id)) continue;
      window.add(id);
      if (window.length >= count) break;
    }
  }
  final inWindow = window.toSet();
  final toCancel = [
    for (final id in inFlight)
      if (!inWindow.contains(id)) id,
  ];
  final readyCount = window.where(ready.contains).length;
  final toStart = <String>[];
  if (allowStart) {
    var free = maxConcurrent - inFlight.where(inWindow.contains).length;
    for (final id in window) {
      if (free <= 0) break;
      if (ready.contains(id) || inFlight.contains(id)) continue;
      toStart.add(id);
      free--;
    }
  }
  return PrefetchPlan(
    window: window,
    ready: readyCount,
    toStart: toStart,
    toCancel: toCancel,
  );
}
