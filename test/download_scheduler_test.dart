import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_scheduler.dart';

class _Queue {
  final queued = <String>['a', 'b', 'c', 'd'];
  final started = <String>[];
  final finished = <String>[];
  final work = <String, Completer<void>>{};
  int limit = 2;
  int selections = 0;
  bool paused = false;

  DownloadScheduler<String> get scheduler => DownloadScheduler(
    queuedItems: () {
      selections++;
      return List.of(queued);
    },
    idOf: (id) => id,
    isPaused: () => paused,
    concurrency: () => limit,
    start: (id) {
      queued.remove(id);
      started.add(id);
      return (work[id] = Completer<void>()).future;
    },
    onFinished: finished.add,
  );

  void complete(String id) => work[id]!.complete();
}

void main() {
  testWidgets('does not traverse a completed tail after the last free slot', (
    tester,
  ) async {
    var checked = 0;
    var paused = false;
    final work = <Completer<void>>[];
    final run = DownloadScheduler<int>(
      queuedItems: () => Iterable<int>.generate(10000).where((item) {
        checked++;
        return item < 3;
      }),
      idOf: (item) => '$item',
      isPaused: () => paused,
      concurrency: () => 3,
      start: (_) {
        final pending = Completer<void>();
        work.add(pending);
        return pending.future;
      },
    ).run();
    final checksAtAdmission = checked;
    paused = true;
    for (final pending in work) {
      pending.complete();
    }
    await tester.pump();
    await run;
    expect(work, hasLength(3));
    expect(checksAtAdmission, 3);
  });

  testWidgets('fills free slots without scanning when every slot is occupied', (
    tester,
  ) async {
    final queue = _Queue();
    final run = queue.scheduler.run();
    await tester.pump();
    expect(queue.started, ['a', 'b']);
    await tester.pump(const Duration(seconds: 30));
    expect(queue.selections, 1);
    queue.complete('b');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c', 'd']);
    queue.complete('c');
    queue.complete('d');
    await tester.pump();
    await run;
    expect(queue.finished, ['b', 'a', 'c', 'd']);
  });

  testWidgets('stops selecting as soon as starting work pauses the queue', (
    tester,
  ) async {
    var paused = false;
    var checked = 0;
    final started = <int>[];
    final work = Completer<void>();
    final run = DownloadScheduler<int>(
      queuedItems: () => Iterable<int>.generate(10000).where((item) {
        checked++;
        return item == 0 || item == 9999;
      }),
      idOf: (item) => '$item',
      isPaused: () => paused,
      concurrency: () => 3,
      start: (item) {
        started.add(item);
        paused = true;
        return work.future;
      },
    ).run();
    expect(checked, 1);
    expect(started, [0]);
    work.complete();
    await tester.pump();
    await run;
  });

  test(
    'a pause during lazy selection prevents starting the yielded item',
    () async {
      var paused = false;
      var started = false;
      await DownloadScheduler<int>(
        queuedItems: () => [0].where((item) {
          paused = true;
          return true;
        }),
        idOf: (item) => '$item',
        isPaused: () => paused,
        concurrency: () => 3,
        start: (_) async => started = true,
      ).run();
      expect(started, isFalse);
    },
  );

  testWidgets('selection errors still drain active work before returning', (
    tester,
  ) async {
    final work = {'a': Completer<void>(), 'b': Completer<void>()};
    final finished = <String>[];
    var rejectSelection = false;
    var done = false;
    final failure = StateError('Queue selection unavailable');
    final run = DownloadScheduler<String>(
      queuedItems: () sync* {
        if (rejectSelection) throw failure;
        yield* work.keys;
      },
      idOf: (id) => id,
      isPaused: () => false,
      concurrency: () => 2,
      start: (id) => work[id]!.future,
      onFinished: finished.add,
    ).run().whenComplete(() => done = true);
    final assertion = expectLater(run, throwsA(same(failure)));
    rejectSelection = true;
    work['a']!.complete();
    await tester.pump();
    expect(done, isFalse);
    expect(finished, ['a']);
    work['b']!.complete();
    await tester.pump();
    await assertion;
    expect(finished, ['a', 'b']);
  });

  testWidgets(
    'pause drains active downloads and leaves queued work for resume',
    (tester) async {
      final queue = _Queue();
      var done = false;
      final run = queue.scheduler.run().then((_) => done = true);
      await tester.pump();
      queue.paused = true;
      await tester.pump(const Duration(milliseconds: 250));
      queue.complete('a');
      await tester.pump();
      expect(done, false);
      expect(queue.started, ['a', 'b']);
      queue.complete('b');
      await tester.pump();
      await run;
      expect(queue.queued, ['c', 'd']);
      queue.paused = false;
      final resumed = queue.scheduler.run();
      await tester.pump();
      queue.complete('c');
      queue.complete('d');
      await tester.pump();
      await resumed;
    },
  );

  testWidgets('retry waits for its active attempt before starting again', (
    tester,
  ) async {
    final queue = _Queue();
    final run = queue.scheduler.run();
    await tester.pump();
    queue.queued.insert(0, 'a');
    queue.complete('b');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c']);
    expect(queue.queued, ['a', 'd']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'b', 'c', 'a']);
    queue.complete('c');
    await tester.pump();
    queue.complete('a');
    queue.complete('d');
    await tester.pump();
    await run;
  });

  testWidgets('uses live ordering and changes concurrency within the bounds', (
    tester,
  ) async {
    final queue = _Queue()..limit = 1;
    final run = queue.scheduler.run();
    await tester.pump();
    queue.queued
      ..clear()
      ..addAll(['d', 'e', 'c']);
    queue.limit = 99;
    await tester.pump(const Duration(milliseconds: 250));
    expect(queue.started, ['a', 'd', 'e']);
    queue.limit = 0;
    queue.complete('d');
    queue.complete('e');
    await tester.pump();
    expect(queue.started, ['a', 'd', 'e']);
    queue.complete('a');
    await tester.pump();
    expect(queue.started, ['a', 'd', 'e', 'c']);
    queue.complete('c');
    await tester.pump();
    await run;
  });

  testWidgets(
    'observes failure and drains other active work before returning',
    (tester) async {
      final queue = _Queue();
      var done = false;
      final error = StateError('Download failed');
      final run = queue.scheduler.run().whenComplete(() => done = true);
      final assertion = expectLater(run, throwsA(same(error)));
      await tester.pump();
      queue.work['a']!.completeError(error);
      await tester.pump();
      expect(done, false);
      expect(queue.started, ['a', 'b']);
      queue.complete('b');
      await tester.pump();
      await assertion;
      expect(queue.finished, ['a', 'b']);
      expect(queue.queued, ['c', 'd']);
    },
  );

  testWidgets(
    'synchronous task failures release their slot without a timer leak',
    (tester) async {
      final run = DownloadScheduler<String>(
        queuedItems: () => ['a'],
        idOf: (id) => id,
        isPaused: () => false,
        concurrency: () => 1,
        start: (_) => throw StateError('Startup failed'),
      ).run();
      final assertion = expectLater(run, throwsStateError);
      await tester.pump();
      await assertion;
    },
  );

  testWidgets('does not start work when the queue is already paused', (
    tester,
  ) async {
    final queue = _Queue()..paused = true;
    await queue.scheduler.run();
    expect(queue.started, isEmpty);
    expect(queue.selections, 0);
  });

  testWidgets('respects the per-provider cap and skips to the next provider', (
    tester,
  ) async {
    final queue = _Queue()
      ..queued.clear()
      ..queued.addAll(['x1', 'x2', 'y1', 'x3'])
      ..limit = 3;
    final run = DownloadScheduler<String>(
      queuedItems: () => List.of(queue.queued),
      idOf: (id) => id,
      isPaused: () => false,
      concurrency: () => queue.limit,
      groupOf: (id) => id.substring(0, 1),
      groupLimit: (group) => group == 'x' ? 1 : 3,
      start: (id) {
        queue.queued.remove(id);
        queue.started.add(id);
        return (queue.work[id] = Completer<void>()).future;
      },
    ).run();
    await tester.pump();
    expect(queue.started, ['x1', 'y1']);
    queue.work['x1']!.complete();
    await tester.pump(const Duration(milliseconds: 300));
    expect(queue.started, ['x1', 'y1', 'x2']);
    queue.work['y1']!.complete();
    queue.work['x2']!.complete();
    await tester.pump(const Duration(milliseconds: 300));
    queue.work['x3']!.complete();
    await tester.pump(const Duration(milliseconds: 300));
    await run;
    expect(queue.started, ['x1', 'y1', 'x2', 'x3']);
  });

  testWidgets('a cap of one runs the queue strictly in order', (tester) async {
    final queue = _Queue()..limit = 3;
    final run = DownloadScheduler<String>(
      queuedItems: () => List.of(queue.queued),
      idOf: (id) => id,
      isPaused: () => false,
      concurrency: () => queue.limit,
      groupOf: (_) => 'p',
      groupLimit: (_) => 1,
      start: (id) {
        queue.queued.remove(id);
        queue.started.add(id);
        return (queue.work[id] = Completer<void>()).future;
      },
    ).run();
    await tester.pump();
    expect(queue.started, ['a']);
    for (final id in ['a', 'b', 'c', 'd']) {
      queue.work[id]!.complete();
      await tester.pump(const Duration(milliseconds: 300));
    }
    await run;
    expect(queue.started, ['a', 'b', 'c', 'd']);
  });

  testWidgets('start delay holds the next item without ending the run', (
    tester,
  ) async {
    final queue = _Queue()..limit = 1;
    var gap = Duration.zero;
    var paused = false;
    final run = DownloadScheduler<String>(
      queuedItems: () => List.of(queue.queued),
      idOf: (id) => id,
      isPaused: () => paused,
      concurrency: () => queue.limit,
      startDelay: (_) => gap,
      start: (id) {
        queue.queued.remove(id);
        queue.started.add(id);
        gap = const Duration(seconds: 1);
        return Future<void>.value();
      },
    ).run();
    await tester.pump();
    expect(queue.started, ['a']);
    await tester.pump(const Duration(milliseconds: 600));
    expect(queue.started, ['a']);
    gap = Duration.zero;
    await tester.pump(const Duration(milliseconds: 300));
    expect(queue.started, ['a', 'b']);
    gap = const Duration(seconds: 1);
    await tester.pump(const Duration(milliseconds: 300));
    paused = true;
    await tester.pump(const Duration(milliseconds: 300));
    await run;
    expect(queue.started, ['a', 'b']);
  });
}
