import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/services/listening_statistics.dart';

final listeningStatisticsEventStreamProvider = Provider<Stream<void>>(
  (ref) => ListeningStatisticsStore.instance.changes,
);

final listeningStatisticsChangesProvider = StreamProvider.autoDispose<int>((
  ref,
) {
  var revision = 0;
  // Repeated void/null events compare equal in Riverpod. Give every commit
  // its own revision so the second and later writes also refresh readers.
  return ref
      .watch(listeningStatisticsEventStreamProvider)
      .map((_) => ++revision);
});

// Flush once per active group of summaries. Flushing on every change would
// itself write more elapsed playback and create a refresh loop.
final listeningStatisticsInitialFlushProvider =
    FutureProvider.autoDispose<void>((ref) => listeningRecorder.flush());

final listeningStatisticsLoadProvider =
    Provider<Future<ListeningSummary> Function(DateTime, DateTime)>(
      (ref) => ListeningStatisticsStore.instance.load,
    );

final listeningSummaryProvider = FutureProvider.autoDispose
    .family<ListeningSummary, ({int days, int year})>((ref, period) async {
      ref.watch(listeningStatisticsChangesProvider);
      final load = ref.watch(listeningStatisticsLoadProvider);
      await ref.watch(listeningStatisticsInitialFlushProvider.future);
      final now = DateTime.now();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final start = period.days == 0
          ? DateTime(period.year)
          : DateTime(now.year, now.month, now.day - period.days + 1);
      final end = period.days == 0 ? DateTime(period.year + 1) : tomorrow;
      return load(start, end);
    });
