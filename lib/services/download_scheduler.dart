import 'dart:async';

/// Runs live queue candidates with bounded concurrency. A single timed waiter
/// observes completions instead of attaching listeners to active work each tick.
class DownloadScheduler<T> {
  const DownloadScheduler({
    required this.queuedItems,
    required this.idOf,
    required this.isPaused,
    required this.concurrency,
    required this.start,
    this.onFinished,
    this.groupOf,
    this.groupLimit,
    this.startDelay,
    this.checkInterval = const Duration(milliseconds: 250),
  });

  final Iterable<T> Function() queuedItems;
  final String Function(T) idOf;
  final bool Function() isPaused;
  final int Function() concurrency;
  final Future<void> Function(T) start;
  final void Function(String)? onFinished;
  final String Function(T)? groupOf;
  final int? Function(String)? groupLimit;
  final Duration Function(T)? startDelay;
  final Duration checkInterval;

  Future<void> run() async {
    final active = <String>{};
    final groups = <String, String>{};
    final groupCounts = <String, int>{};
    (Object, StackTrace)? failure;
    Completer<void>? waiter;
    Timer? timer;
    void wake() {
      timer?.cancel();
      timer = null;
      final pending = waiter;
      waiter = null;
      pending?.complete();
    }

    Future<void> waitForChange() {
      final pending = waiter = Completer<void>();
      timer = Timer(checkInterval, wake);
      return pending.future;
    }

    void failed(Object error, StackTrace stack) => failure ??= (error, stack);
    void launch(T item, String id, String group) {
      active.add(id);
      groups[id] = group;
      groupCounts[group] = (groupCounts[group] ?? 0) + 1;
      unawaited(
        Future.sync(
          () => start(item),
        ).then<void>((_) {}, onError: failed).whenComplete(() {
          active.remove(id);
          final group = groups.remove(id);
          if (group != null) {
            final left = (groupCounts[group] ?? 1) - 1;
            if (left <= 0) {
              groupCounts.remove(group);
            } else {
              groupCounts[group] = left;
            }
          }
          try {
            onFinished?.call(id);
          } catch (error, stack) {
            failed(error, stack);
          }
          wake();
        }),
      );
    }

    try {
      while (true) {
        var delayed = false;
        if (failure == null && !isPaused()) {
          final limit = concurrency().clamp(1, 3);
          if (active.length < limit) {
            for (final item in queuedItems()) {
              if (isPaused() || active.length >= limit) break;
              final id = idOf(item);
              // Retry can requeue an item before its previous attempt unwinds.
              if (active.contains(id)) continue;
              final group = groupOf?.call(item) ?? '';
              final cap = groupLimit?.call(group)?.clamp(1, 3);
              if (cap != null && (groupCounts[group] ?? 0) >= cap) continue;
              final delay = startDelay?.call(item) ?? Duration.zero;
              if (isPaused()) break;
              if (delay > Duration.zero) {
                delayed = true;
                break;
              }
              launch(item, id, group);
              // Advancing the lazy filter again may scan a long completed tail.
              if (active.length >= limit || isPaused()) break;
            }
          }
        }
        if (active.isEmpty && !delayed) break;
        await waitForChange();
      }
    } catch (error, stack) {
      failed(error, stack);
      while (active.isNotEmpty) {
        await waitForChange();
      }
    } finally {
      wake();
    }
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}
