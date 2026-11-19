import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/prefetch_planner.dart';

List<String> _ids(String letters) => letters.split('');

void main() {
  group('planPrefetch', () {
    test('the window is the first songs in play order', () {
      final plan = planPrefetch(upcoming: _ids('bcdef'), count: 3);
      expect(plan.window, ['b', 'c', 'd']);
      expect(plan.toStart, ['b']);
      expect(plan.toCancel, isEmpty);
    });

    test('the window refills when the current song advances', () {
      final first = planPrefetch(
        upcoming: _ids('bcde'),
        count: 3,
        ready: {'b', 'c', 'd'},
      );
      expect(first.toStart, isEmpty);
      expect(first.ready, 3);
      final next = planPrefetch(
        upcoming: _ids('cdef'),
        count: 3,
        ready: {'b', 'c', 'd'},
      );
      expect(next.window, ['c', 'd', 'e']);
      expect(next.ready, 2);
      expect(next.toStart, ['e']);
    });

    test('is idempotent: ready and running songs are not started again', () {
      final plan = planPrefetch(
        upcoming: _ids('bcd'),
        count: 3,
        ready: {'b'},
        inFlight: {'c'},
        maxConcurrent: 2,
      );
      expect(plan.toStart, ['d']);
      final again = planPrefetch(
        upcoming: _ids('bcd'),
        count: 3,
        ready: {'b'},
        inFlight: {'c', 'd'},
        maxConcurrent: 2,
      );
      expect(again.toStart, isEmpty);
      expect(again.toCancel, isEmpty);
    });

    test('a failed song does not block the ones behind it', () {
      final plan = planPrefetch(
        upcoming: _ids('bcde'),
        count: 2,
        blocked: {'b'},
      );
      expect(plan.window, ['c', 'd']);
      expect(plan.toStart, ['c']);
    });

    test('a failed song is tried again once it is no longer blocked', () {
      final plan = planPrefetch(upcoming: _ids('bcd'), count: 2);
      expect(plan.toStart, ['b']);
    });

    test('the end of the queue leaves a short window', () {
      final plan = planPrefetch(upcoming: _ids('b'), count: 3);
      expect(plan.window, ['b']);
      final none = planPrefetch(upcoming: const [], count: 3);
      expect(none.window, isEmpty);
      expect(none.toStart, isEmpty);
    });

    test('a jump far away cancels the old preparations', () {
      final plan = planPrefetch(
        upcoming: _ids('xyz'),
        count: 3,
        inFlight: {'c'},
      );
      expect(plan.toCancel, ['c']);
      expect(plan.toStart, ['x']);
    });

    test('a song inserted to play next takes the first place', () {
      final plan = planPrefetch(
        upcoming: _ids('nbcd'),
        count: 2,
        ready: {'b', 'c'},
        inFlight: {'c'},
      );
      expect(plan.window, ['n', 'b']);
      expect(plan.toStart, ['n']);
      expect(plan.toCancel, ['c']);
    });

    test('never exceeds the concurrency limit', () {
      final one = planPrefetch(upcoming: _ids('bcde'), count: 4);
      expect(one.toStart, ['b']);
      final two = planPrefetch(
        upcoming: _ids('bcde'),
        count: 4,
        maxConcurrent: 2,
      );
      expect(two.toStart, ['b', 'c']);
      final busy = planPrefetch(
        upcoming: _ids('bcde'),
        count: 4,
        inFlight: {'b'},
        maxConcurrent: 2,
      );
      expect(busy.toStart, ['c']);
      final full = planPrefetch(
        upcoming: _ids('bcde'),
        count: 4,
        inFlight: {'b'},
      );
      expect(full.toStart, isEmpty);
    });

    test('nothing starts while starting is not allowed', () {
      final plan = planPrefetch(
        upcoming: _ids('bcd'),
        count: 3,
        inFlight: {'z'},
        allowStart: false,
      );
      expect(plan.toStart, isEmpty);
      expect(plan.toCancel, ['z']);
    });

    test('a window of zero prepares nothing', () {
      final plan = planPrefetch(upcoming: _ids('bcd'), count: 0);
      expect(plan.window, isEmpty);
      expect(plan.toStart, isEmpty);
    });
  });

  group('prefetchUpcomingIndexes', () {
    List<int> ahead(
      int index,
      int length, {
      int lookahead = 3,
      bool repeatAll = false,
      bool repeatOne = false,
      bool shuffle = false,
    }) => prefetchUpcomingIndexes(
      index: index,
      length: length,
      lookahead: lookahead,
      repeatAll: repeatAll,
      repeatOne: repeatOne,
      shuffle: shuffle,
    );

    test('follows the queue order and stops at the lookahead', () {
      expect(ahead(2, 100), [3, 4, 5]);
    });

    test('a long queue only looks a few songs ahead', () {
      expect(ahead(0, 5000, lookahead: 8), hasLength(8));
    });

    test('the end of the queue prepares nothing without repeat', () {
      expect(ahead(4, 5), isEmpty);
      expect(ahead(3, 5), [4]);
    });

    test('repeat all wraps to the start of the queue', () {
      expect(ahead(4, 5, repeatAll: true), [0, 1, 2]);
      expect(ahead(3, 5, repeatAll: true), [4, 0, 1]);
    });

    test('repeat all never reaches back to the current song', () {
      expect(ahead(1, 3, repeatAll: true, lookahead: 8), [2, 0]);
    });

    test('shuffle keeps the order already fixed and does not wrap', () {
      expect(ahead(2, 5, shuffle: true), [3, 4]);
      expect(ahead(4, 5, repeatAll: true, shuffle: true), isEmpty);
    });

    test('a single song has nothing ahead', () {
      expect(ahead(0, 1), isEmpty);
      expect(ahead(0, 1, repeatAll: true), isEmpty);
    });

    test('repeat one has nothing ahead', () {
      expect(ahead(1, 5, repeatOne: true), isEmpty);
    });
  });

  group('prefetchRetryDelay', () {
    test('grows with each failure up to the ceiling', () {
      expect(prefetchRetryDelay(0), Duration.zero);
      expect(prefetchRetryDelay(1), const Duration(seconds: 15));
      expect(prefetchRetryDelay(2), const Duration(seconds: 30));
      expect(prefetchRetryDelay(3), const Duration(seconds: 60));
      expect(prefetchRetryDelay(4), const Duration(minutes: 2));
      expect(prefetchRetryDelay(40), const Duration(minutes: 2));
    });
  });
}
