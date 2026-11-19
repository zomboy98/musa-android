import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/services/listening_rewind.dart';
import 'package:mornye/services/listening_statistics.dart';

final listeningRewindProvider = FutureProvider.autoDispose
    .family<ListeningRewind, ListeningRewindPeriod>((ref, period) async {
      await listeningRecorder.flush();
      final range = ListeningRewindRange.of(period, DateTime.now());
      return ListeningStatisticsStore.instance.read(
        (db) => readListeningRewind(
          db,
          range,
          yearly: period == ListeningRewindPeriod.year,
        ),
      );
    });

final listeningRewindNowProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

final listeningRewindHasListeningProvider =
    Provider<Future<bool> Function(ListeningRewindRange)>(
      (ref) => (range) async {
        final rows = await ListeningStatisticsStore.instance.read(
          (db) => db.rawQuery(
            'SELECT 1 FROM listening '
            'WHERE day >= ? AND day < ? AND milliseconds > 0 LIMIT 1',
            [listeningDay(range.start), listeningDay(range.end)],
          ),
        );
        return rows.isNotEmpty;
      },
    );

/// The Rewind the Library advertises today, or null. A window without any
/// listening is not advertised, so the banner never opens an empty story.
final listeningRewindSpotlightProvider =
    FutureProvider.autoDispose<ListeningRewindSpotlight?>((ref) async {
      final now = ref.watch(listeningRewindNowProvider)();
      final tomorrow = DateTime(now.year, now.month, now.day + 1);
      final refresh = Timer(tomorrow.difference(now), ref.invalidateSelf);
      ref.onDispose(refresh.cancel);
      final spotlight = ListeningRewindSpotlight.at(now);
      if (spotlight == null) return null;
      ref.watch(listeningStatisticsChangesProvider);
      final hasListening = ref.watch(listeningRewindHasListeningProvider);
      await ref.watch(listeningStatisticsInitialFlushProvider.future);
      final range = ListeningRewindRange.of(spotlight.period, now);
      return await hasListening(range) ? spotlight : null;
    });
