import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_shadow.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'support/link_sync_support.dart';

class Observer extends ListeningShadow {
  Observer() : super(run: (_) async => {});
  final events = <Map<String, dynamic>>[];
  bool cancelled = false;
  @override
  void submit(
    Map<String, dynamic> event, {
    List<Map<String, dynamic>>? expected,
  }) {
    events.add({'event': event, 'expected': expected});
  }

  @override
  void invalidate() {
    cancelled = true;
  }
}

class ThrowingObserver extends Observer {
  @override
  void submit(
    Map<String, dynamic> event, {
    List<Map<String, dynamic>>? expected,
  }) => throw StateError('observer');
}

class ThrowingLimitObserver extends Observer {
  @override
  int get maxSegments => throw StateError('limit');
}

void main() {
  test(
    'flag defaults to disabled',
    () => expect(listeningShadowEnabled, isFalse),
  );
  test('instance reset follows accounting and precedes update', () async {
    final shadow = Observer();
    var clock = Duration.zero;
    final writes = <ListeningDelta>[];
    final recorder = ListeningRecorder(
      write: (d) async => writes.addAll(d),
      elapsed: () => clock,
      now: () => DateTime(2026, 1, 1).add(clock),
      shadow: shadow,
    );
    const track = ListeningTrack(
      key: 'private',
      title: 'private',
      artist: '',
      album: '',
    );
    recorder.update(track, playing: true, playbackInstance: 1);
    clock += const Duration(seconds: 31);
    recorder.update(track, playing: true, playbackInstance: 2);
    expect(shadow.events.map((e) => (e['event'] as Map)['type']), [
      'reset',
      'update',
      'advance',
      'reset',
      'update',
    ]);
    expect(shadow.events.toString(), isNot(contains('private')));
    await recorder.flush();
    expect(writes.single.plays, 1);
    await recorder.clear(() async {});
    expect(shadow.cancelled, isTrue);
  });

  test(
    'pause, resume, enable and ended retain correct ordering and threshold',
    () async {
      final observer = Observer();
      var clock = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (d) async => writes.addAll(d),
        elapsed: () => clock,
        now: () => DateTime(2026, 1, 1).add(clock),
        shadow: observer,
      );
      const track = ListeningTrack(key: 'a', title: '', artist: '', album: '');
      recorder.update(track, playing: true, playbackInstance: 1);
      clock += const Duration(seconds: 10);
      recorder.update(track, playing: false, playbackInstance: 1);
      clock += const Duration(seconds: 10);
      recorder.update(track, playing: true, playbackInstance: 1);
      recorder.setEnabled(false);
      clock += const Duration(seconds: 10);
      recorder.setEnabled(true);
      clock += const Duration(seconds: 20);
      recorder.update(track, playing: false, ended: true, playbackInstance: 1);
      await recorder.flush();
      expect(writes.single.milliseconds, 30000);
      expect(writes.single.plays, 1);
      expect(observer.events.map((e) => (e['event'] as Map)['type']), [
        'reset',
        'update',
        'advance',
        'update',
        'update',
        'enabled',
        'enabled',
        'advance',
        'reset',
        'update',
      ]);
      expect(recorder.idle, isTrue);
    },
  );

  test(
    'clear invalidates immediately even when store fails and never reactivates',
    () async {
      final observer = Observer();
      final pending = Completer<void>();
      final recorder = ListeningRecorder(
        write: (_) async {},
        elapsed: () => Duration.zero,
        now: DateTime.now,
        shadow: observer,
      );
      final clearing = recorder.clear(() => pending.future);
      expect(observer.cancelled, isTrue);
      pending.completeError(StateError('clear'));
      await expectLater(clearing, throwsStateError);
      recorder.update(
        const ListeningTrack(key: 'a', title: '', artist: '', album: ''),
        playing: true,
      );
      expect(observer.events, isEmpty);
    },
  );

  test('observer errors do not change write, flush or idle', () async {
    Future<List<int>> run(ListeningShadow? observer) async {
      var clock = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (d) async => writes.addAll(d),
        elapsed: () => clock,
        now: () => DateTime(2026, 1, 1).add(clock),
        shadow: observer,
      );
      recorder.update(
        const ListeningTrack(key: 'a', title: '', artist: '', album: ''),
        playing: true,
      );
      clock += const Duration(seconds: 31);
      recorder.update(null, playing: false);
      await recorder.flush();
      return [
        writes.single.milliseconds,
        writes.single.plays,
        recorder.idle ? 1 : 0,
      ];
    }

    expect(await run(ThrowingObserver()), await run(null));
    expect(await run(ThrowingLimitObserver()), await run(null));
  });

  test('null track and midnight produce matching segments', () async {
    final observer = Observer();
    var clock = Duration.zero;
    final writes = <ListeningDelta>[];
    final recorder = ListeningRecorder(
      write: (d) async => writes.addAll(d),
      elapsed: () => clock,
      now: () => DateTime(2026, 1, 1, 23, 59, 50).add(clock),
      shadow: observer,
    );
    recorder.update(null, playing: false);
    recorder.update(
      const ListeningTrack(key: 'secret', title: '', artist: '', album: ''),
      playing: true,
    );
    clock += const Duration(seconds: 31);
    recorder.update(null, playing: false);
    await recorder.flush();
    final advance = observer.events.singleWhere(
      (e) => (e['event'] as Map)['type'] == 'advance',
    );
    expect((advance['event'] as Map)['segments'], [
      {'day': '2026-01-01', 'milliseconds': 10000},
      {'day': '2026-01-02', 'milliseconds': 21000},
    ]);
    expect(
      (advance['expected'] as List<Map<String, dynamic>>).map(
        (e) => e['plays'],
      ),
      [0, 1],
    );
    expect(writes.map((e) => e.milliseconds), [10000, 21000]);
  });

  test('successful late response cannot revive shadow after clear', () async {
    final response = Completer<Map<String, dynamic>>();
    final shadow = ListeningShadow(run: (_) => response.future);
    final recorder = ListeningRecorder(
      write: (_) async {},
      elapsed: () => Duration.zero,
      now: DateTime.now,
      shadow: shadow,
    );
    recorder.update(
      const ListeningTrack(key: 'secret', title: '', artist: '', album: ''),
      playing: true,
    );
    await recorder.clear(() async {});
    response.complete({
      'version': 2,
      'state': {
        'version': 1,
        'track': null,
        'playing': false,
        'enabled': true,
        'session_ms': 0,
        'counted': false,
      },
      'batches': <Object>[],
    });
    await Future<void>.delayed(Duration.zero);
    expect(shadow.active, isFalse);
    await recorder.flush();
  });

  test('in-flight asynchronous failure remains isolated after clear', () async {
    final response = Completer<Map<String, dynamic>>();
    final shadow = ListeningShadow(run: (_) => response.future);
    final recorder = ListeningRecorder(
      write: (_) async {},
      elapsed: () => Duration.zero,
      now: DateTime.now,
      shadow: shadow,
    );
    recorder.update(
      const ListeningTrack(key: 'a', title: '', artist: '', album: ''),
      playing: true,
    );
    await recorder.clear(() async {});
    expect(shadow.active, isFalse);
    response.completeError(StateError('late'));
    await shadow.drain();
    await recorder.flush();
  });

  test(
    'real database, pending writes, clear and idle match without shadow',
    () async {
      Future<List<Object?>> scenario(bool enabled, bool clearFails) async {
        final db = await openLinkListeningDatabase(
          await linkSyncTempDirectory(),
          'shadow',
        );
        addTearDown(db.close);
        final gate = Completer<void>();
        var clock = Duration.zero;
        final shadow = enabled ? Observer() : null;
        final recorder = ListeningRecorder(
          write: (batch) async {
            await gate.future;
            await writeListeningDeltas(db, batch);
          },
          elapsed: () => clock,
          now: () => DateTime(2026, 1, 1).add(clock),
          shadow: shadow,
        );
        const track = ListeningTrack(
          key: 'song',
          title: 'Song',
          artist: 'A',
          album: 'B',
        );
        recorder.update(track, playing: true, playbackInstance: 1);
        clock += const Duration(seconds: 31);
        recorder.update(track, playing: false, playbackInstance: 1);
        final writing = recorder.flush();
        final idleBefore = recorder.idle;
        final clearing = recorder.clear(() async {
          if (clearFails) throw StateError('clear');
          await db.delete('listening');
        });
        expect(shadow?.cancelled ?? true, isTrue);
        gate.complete();
        await writing;
        if (clearFails) {
          await expectLater(clearing, throwsStateError);
        } else {
          await clearing;
        }
        await recorder.flush();
        final rows = await db.query('listening');
        return [idleBefore, recorder.idle, rows];
      }

      for (final fails in [false, true]) {
        expect(await scenario(true, fails), await scenario(false, fails));
      }
    },
  );
}
