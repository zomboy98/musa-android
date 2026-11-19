import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'late response from an invalidated generation cannot replace cache',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final pending = Completer<List<ExploreSection>?>();
      var calls = 0;
      List<ExploreSection> feed(String id) => [
        ExploreSection(
          uri: 'feed',
          title: 'Playlists',
          items: [
            ExploreItem(
              id: id,
              uri: id,
              type: 'playlist',
              name: id,
              artists: '',
              coverUrl: 'https://example.com/a.png',
            ),
          ],
        ),
      ];
      final container = ProviderContainer(
        overrides: [
          homeTopPicksClockProvider.overrideWithValue(
            () => DateTime(2026, 11, 8),
          ),
          homeTopPicksExtensionProvider.overrideWithValue('example'),
          homeTopPicksFeedReaderProvider.overrideWithValue((id) {
            calls++;
            return calls == 1 ? pending.future : Future.value(feed('new'));
          }),
        ],
      );
      final subscription = container.listen(homeTopPicksProvider, (_, _) {});
      await tester.pump();
      await tester.pump();
      expect(calls, 1);
      container.read(homeTopPicksRefreshProvider.notifier).state++;
      expect(
        (await container.read(homeTopPicksProvider.future)).single.id,
        'new',
      );
      pending.complete(feed('old'));
      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('home_top_picks_v2'), contains('new'));
      expect(prefs.getString('home_top_picks_v2'), isNot(contains('old')));
      subscription.close();
      container.dispose();
    },
  );
  testWidgets('refresh survives invalidation while resolving region', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final delayed = Completer<String?>();
    final regionFuture = StateProvider<Future<String?>>(
      (ref) => Future.value('US'),
    );
    var reads = 0;
    final container = ProviderContainer(
      overrides: [
        homeTopPicksClockProvider.overrideWithValue(
          () => DateTime(2026, 11, 8),
        ),
        homeTopPicksExtensionProvider.overrideWithValue('example'),
        homeTopPicksRegionProvider.overrideWith(
          (ref) => ref.watch(regionFuture),
        ),
        homeTopPicksFeedReaderProvider.overrideWithValue((id) async {
          reads++;
          return [];
        }),
      ],
    );
    final subscription = container.listen(homeTopPicksProvider, (_, _) {});
    await container.read(homeTopPicksProvider.future);
    expect(reads, 1);
    container.read(regionFuture.notifier).state = delayed.future;
    container.read(homeTopPicksRefreshProvider.notifier).state++;
    await tester.pump();
    container.read(regionFuture.notifier).state = Future.value('US');
    final result = container.read(homeTopPicksProvider.future);
    delayed.complete('US');
    await result;
    expect(reads, 2, reason: 'the new generation must still force a fetch');
    subscription.close();
    container.dispose();
  });
  testWidgets(
    'region change invalidates daily cache without destroying it on failure',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final region = StateProvider<String>((ref) => 'US');
      var reads = 0;
      var fail = false;
      var containerRegion = 'US';
      final container = ProviderContainer(
        retry: (count, error) => null,
        overrides: [
          homeTopPicksClockProvider.overrideWithValue(
            () => DateTime(2026, 11, 8),
          ),
          homeTopPicksExtensionProvider.overrideWithValue('example'),
          homeTopPicksRegionProvider.overrideWith(
            (ref) async => ref.watch(region),
          ),
          exploreProvider.overrideWith(_EmptyExplore.new),
          homeTopPicksFeedReaderProvider.overrideWithValue((id) async {
            reads++;
            if (fail) return null;
            final current = containerRegion;
            return [
              ExploreSection(
                uri: 'feed',
                title: 'Playlists',
                items: [
                  ExploreItem(
                    id: current,
                    uri: current,
                    type: 'playlist',
                    name: current,
                    artists: '',
                    coverUrl: 'https://example.com/a.png',
                  ),
                ],
              ),
            ];
          }),
        ],
      );
      final subscription = container.listen(homeTopPicksProvider, (_, _) {});
      containerRegion = 'US';
      expect(
        (await container.read(homeTopPicksProvider.future)).single.id,
        'US',
      );
      final prefs = await SharedPreferences.getInstance();
      final original = prefs.getString('home_top_picks_v2');
      fail = true;
      containerRegion = 'GB';
      container.read(region.notifier).state = 'GB';
      await expectLater(
        container.read(homeTopPicksProvider.future),
        throwsException,
      );
      expect(prefs.getString('home_top_picks_v2'), original);
      fail = false;
      container.invalidate(homeTopPicksProvider);
      expect(
        (await container.read(homeTopPicksProvider.future)).single.id,
        'GB',
      );
      containerRegion = 'US';
      container.read(region.notifier).state = 'US';
      expect(
        (await container.read(homeTopPicksProvider.future)).single.id,
        'US',
      );
      expect(reads, 4);
      subscription.close();
      container.dispose();
    },
  );
  testWidgets('explicit refresh fetches again and retains cache on failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var reads = 0;
    var fail = false;
    final container = ProviderContainer(
      overrides: [
        homeTopPicksClockProvider.overrideWithValue(
          () => DateTime(2026, 11, 8),
        ),
        homeTopPicksExtensionProvider.overrideWithValue('example'),
        homeTopPicksFeedReaderProvider.overrideWithValue((id) async {
          reads++;
          if (fail) return null;
          return [
            ExploreSection(
              uri: 'feed',
              title: 'Playlists',
              items: [
                ExploreItem(
                  id: 'p$reads',
                  uri: 'p$reads',
                  type: 'playlist',
                  name: 'Playlist $reads',
                  artists: '',
                  coverUrl: 'https://example.com/a.png',
                ),
              ],
            ),
          ];
        }),
      ],
    );
    final subscription = container.listen(homeTopPicksProvider, (_, _) {});
    expect((await container.read(homeTopPicksProvider.future)).single.id, 'p1');
    final prefs = await SharedPreferences.getInstance();
    final firstCache = prefs.getString('home_top_picks_v2');
    container.read(homeTopPicksRefreshProvider.notifier).state++;
    expect((await container.read(homeTopPicksProvider.future)).single.id, 'p2');
    expect(reads, 2);
    final secondCache = prefs.getString('home_top_picks_v2');
    expect(secondCache, isNot(firstCache));
    fail = true;
    container.read(homeTopPicksRefreshProvider.notifier).state++;
    expect((await container.read(homeTopPicksProvider.future)).single.id, 'p2');
    expect(reads, 3);
    expect(prefs.getString('home_top_picks_v2'), secondCache);
    subscription.close();
    container.dispose();
  });
  testWidgets(
    'day updates at local midnight and on resume after clock changes',
    (tester) async {
      var now = DateTime(2026, 11, 8, 23, 59, 50);
      final container = ProviderContainer(
        overrides: [homeTopPicksClockProvider.overrideWithValue(() => now)],
      );
      final changes = <String>[];
      final subscription = container.listen(
        homeTopPicksDayProvider,
        (_, next) => changes.add(next),
        fireImmediately: true,
      );
      expect(changes, ['2026-11-08']);
      now = DateTime(2026, 11, 9);
      await tester.pump(const Duration(seconds: 10));
      expect(changes, ['2026-11-08', '2026-11-09']);

      now = DateTime(2026, 11, 10, 8);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(changes.last, '2026-11-10');
      subscription.close();
      container.dispose();
      await tester.pump(const Duration(minutes: 2));
      expect(changes, ['2026-11-08', '2026-11-09', '2026-11-10']);
    },
  );

  testWidgets(
    'background cancels timer and resume schedules new local midnight',
    (tester) async {
      var now = DateTime(2026, 11, 8, 22);
      var clockReads = 0;
      final container = ProviderContainer(
        overrides: [
          homeTopPicksClockProvider.overrideWithValue(() {
            clockReads++;
            return now;
          }),
        ],
      );
      final changes = <String>[];
      final subscription = container.listen(
        homeTopPicksDayProvider,
        (_, next) => changes.add(next),
        fireImmediately: true,
      );
      final initialReads = clockReads;
      await tester.pump(const Duration(minutes: 30));
      expect(clockReads, initialReads, reason: 'no periodic clock polling');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = DateTime(2026, 11, 10, 23, 59, 55);
      await tester.pump(const Duration(hours: 3));
      expect(clockReads, initialReads, reason: 'no wakeup while backgrounded');
      expect(changes, ['2026-11-08']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(changes.last, '2026-11-10');
      now = DateTime(2026, 11, 11);
      await tester.pump(const Duration(seconds: 5));
      expect(changes.last, '2026-11-11');
      subscription.close();
      container.dispose();
    },
  );
}

class _EmptyExplore extends ExploreNotifier {
  @override
  ExploreState build() => const ExploreState();
}
