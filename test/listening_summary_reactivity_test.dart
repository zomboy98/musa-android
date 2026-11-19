import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  test(
    'each committed void event has a distinct observable revision',
    () async {
      final events = StreamController<void>.broadcast(sync: true);
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [
          listeningStatisticsEventStreamProvider.overrideWithValue(
            events.stream,
          ),
        ],
      );
      addTearDown(container.dispose);
      final observed = <int>[];
      var errors = 0;
      final subscription = container.listen(
        listeningStatisticsChangesProvider,
        (_, next) {
          if (next.hasValue) observed.add(next.requireValue);
          if (next.hasError) errors++;
        },
      );
      addTearDown(subscription.close);
      events.add(null);
      events.add(null);
      events.add(null);
      expect(observed, [1, 2, 3]);
      events.addError(StateError('temporary stream error'));
      events.add(null);
      expect(errors, 1);
      expect(observed.last, 4);
    },
  );
  test(
    'mix history reloads on commits without another recorder flush',
    () async {
      var eventRevision = 0;
      final changes = StreamController<int>.broadcast(sync: true);
      addTearDown(changes.close);
      var flushes = 0;
      var loads = 0;
      var revision = '1';
      final container = ProviderContainer(
        overrides: [
          listeningStatisticsChangesProvider.overrideWith(
            (ref) => changes.stream,
          ),
          listeningStatisticsInitialFlushProvider.overrideWith((ref) async {
            flushes++;
            await Future<void>.delayed(Duration.zero);
            changes.add(++eventRevision);
          }),
          libraryMixListeningRevisionLoadProvider.overrideWithValue((
            now,
            includeLocal,
            indexRevision,
          ) async {
            loads++;
            return revision;
          }),
        ],
      );
      addTearDown(container.dispose);
      final provider = libraryMixListeningRevisionProvider((
        day: '2026-11-06',
        includeLocal: true,
        indexRevision: 'library-1',
      ));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      expect(await container.read(provider.future), '1');
      final initialLoads = loads;
      revision = '2';
      changes.add(++eventRevision);
      await Future<void>.delayed(Duration.zero);
      expect(await container.read(provider.future), '2');
      await Future<void>.delayed(Duration.zero);
      expect(flushes, 1);
      expect(loads, initialLoads + 1);
    },
  );
  test('pending flush survives invalidation and disposal', () async {
    var eventRevision = 0;
    final changes = StreamController<int>.broadcast(sync: true);
    addTearDown(changes.close);
    final flush = Completer<void>();
    var loads = 0;
    final container = ProviderContainer(
      overrides: [
        listeningStatisticsChangesProvider.overrideWith(
          (ref) => changes.stream,
        ),
        listeningStatisticsInitialFlushProvider.overrideWith(
          (ref) => flush.future,
        ),
        listeningStatisticsLoadProvider.overrideWithValue((start, end) async {
          loads++;
          return const ListeningSummary(milliseconds: 42);
        }),
      ],
    );
    addTearDown(container.dispose);
    final summary = listeningSummaryProvider((days: 0, year: 2026));
    final subscription = container.listen(summary, (_, _) {});
    final first = container.read(summary.future);
    changes.add(++eventRevision);
    await Future<void>.delayed(Duration.zero);
    final second = container.read(summary.future);
    subscription.close();
    await Future<void>.delayed(Duration.zero);
    flush.complete();

    expect((await first).milliseconds, 42);
    expect((await second).milliseconds, 42);
    expect(loads, 2);
  });

  test(
    'active annual and recent summaries reload on committed changes',
    () async {
      var eventRevision = 0;
      final changes = StreamController<int>.broadcast(sync: true);
      addTearDown(changes.close);
      var flushes = 0;
      var milliseconds = 1000;
      var loads = 0;
      final container = ProviderContainer(
        overrides: [
          listeningStatisticsChangesProvider.overrideWith(
            (ref) => changes.stream,
          ),
          listeningStatisticsInitialFlushProvider.overrideWith((ref) async {
            flushes++;
          }),
          listeningStatisticsLoadProvider.overrideWithValue((start, end) async {
            loads++;
            return ListeningSummary(milliseconds: milliseconds);
          }),
        ],
      );
      addTearDown(container.dispose);
      final annual = listeningSummaryProvider((
        days: 0,
        year: DateTime.now().year,
      ));
      final recent = listeningSummaryProvider((days: 7, year: 0));
      final annualSubscription = container.listen(annual, (_, _) {});
      final recentSubscription = container.listen(recent, (_, _) {});
      addTearDown(annualSubscription.close);
      addTearDown(recentSubscription.close);

      expect((await container.read(annual.future)).milliseconds, 1000);
      expect((await container.read(recent.future)).milliseconds, 1000);
      milliseconds = 3000;
      changes.add(++eventRevision);
      await Future<void>.delayed(Duration.zero);
      expect((await container.read(annual.future)).milliseconds, 3000);
      expect((await container.read(recent.future)).milliseconds, 3000);
      expect(flushes, 1);
      expect(loads, 4);
    },
  );
}
