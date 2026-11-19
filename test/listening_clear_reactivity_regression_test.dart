import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/listening_rewind_provider.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  test(
    'concurrent clears run separately and propagate their own failures',
    () async {
      final firstGate = Completer<void>();
      var elapsed = Duration.zero;
      var calls = 0;
      final recorder = ListeningRecorder(
        elapsed: () => elapsed,
        now: () => DateTime(2026, 12, 1).add(elapsed),
        write: (_) async {},
      );
      recorder.update(
        const ListeningTrack(key: 'a', title: 'a', artist: 'b', album: 'c'),
        playing: true,
      );
      final first = recorder.clear(() async {
        calls++;
        await firstGate.future;
      });
      final second = recorder.clear(() async {
        calls++;
        throw StateError('second clear');
      });
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      firstGate.complete();
      await first;
      await expectLater(second, throwsStateError);
      expect(calls, 2);
      elapsed = const Duration(seconds: 1);
      await recorder.flush();
    },
  );

  test(
    'flush waits for failed clear and persists restored and new time',
    () async {
      var elapsed = Duration.zero;
      final gate = Completer<void>();
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        elapsed: () => elapsed,
        now: () => DateTime(2026, 12, 1).add(elapsed),
        write: (batch) async => writes.addAll(batch),
      );
      recorder.update(
        const ListeningTrack(key: 'a', title: 'a', artist: 'b', album: 'c'),
        playing: true,
      );
      elapsed = const Duration(seconds: 31);
      final clear = recorder.clear(() => gate.future);
      elapsed = const Duration(seconds: 35);
      final flush = recorder.flush();
      await Future<void>.delayed(Duration.zero);
      expect(writes, isEmpty);
      gate.completeError(StateError('clear failed'));
      await expectLater(clear, throwsStateError);
      await flush;
      expect(writes.fold<int>(0, (sum, d) => sum + d.milliseconds), 35000);
      expect(writes.fold<int>(0, (sum, d) => sum + d.plays), 1);
      await recorder.flush();
      expect(writes.length, 1);
    },
  );

  test(
    'flush after successful clear saves only playback since request',
    () async {
      var elapsed = Duration.zero;
      final gate = Completer<void>();
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        elapsed: () => elapsed,
        now: () => DateTime(2026, 12, 1).add(elapsed),
        write: (batch) async => writes.addAll(batch),
      );
      recorder.update(
        const ListeningTrack(key: 'a', title: 'a', artist: 'b', album: 'c'),
        playing: true,
      );
      elapsed = const Duration(seconds: 10);
      final clear = recorder.clear(() => gate.future);
      elapsed = const Duration(seconds: 15);
      final flush = recorder.flush();
      gate.complete();
      await clear;
      await flush;
      expect(writes.single.milliseconds, 5000);
    },
  );

  test('second clear still executes after the first fails', () async {
    final gate = Completer<void>();
    var calls = 0;
    final recorder = ListeningRecorder(
      elapsed: () => Duration.zero,
      now: () => DateTime(2026),
      write: (_) async {},
    );
    final first = recorder.clear(() => gate.future);
    final second = recorder.clear(() async {
      calls++;
    });
    gate.completeError(StateError('first clear'));
    await expectLater(first, throwsStateError);
    await second;
    expect(calls, 1);
  });

  test(
    'failed clear restores failed in-flight write and active interval once',
    () async {
      var time = Duration.zero;
      final writeGate = Completer<void>();
      final clearGate = Completer<void>();
      final written = <ListeningDelta>[];
      var writes = 0;
      final recorder = ListeningRecorder(
        elapsed: () => time,
        now: () => DateTime(2026, 12, 1).add(time),
        write: (batch) async {
          if (writes++ == 0) {
            await writeGate.future;
            throw StateError('write failed');
          }
          written.addAll(batch);
        },
      );
      recorder.update(
        const ListeningTrack(key: 'a', title: 'a', artist: 'b', album: 'c'),
        playing: true,
      );
      time = const Duration(seconds: 31);
      final firstWrite = recorder.flush();
      final clearing = recorder.clear(() => clearGate.future);
      time = const Duration(seconds: 33);
      recorder.checkpoint();
      writeGate.complete();
      await firstWrite;
      await Future<void>.delayed(Duration.zero);
      time = const Duration(seconds: 35);
      clearGate.completeError(StateError('clear failed'));
      await expectLater(clearing, throwsStateError);
      time = const Duration(seconds: 40);
      await recorder.flush();
      expect(written.fold<int>(0, (sum, d) => sum + d.milliseconds), 40000);
      expect(written.fold<int>(0, (sum, d) => sum + d.plays), 1);
      await recorder.flush();
      expect(writes, 2);
    },
  );

  test(
    'spotlight refreshes after commits without another flush and cancels on disposal',
    () async {
      final changes = StreamController<int>.broadcast(sync: true);
      addTearDown(changes.close);
      var hasListening = false;
      var flushes = 0;
      var loads = 0;
      final container = ProviderContainer(
        overrides: [
          listeningRewindNowProvider.overrideWithValue(
            () => DateTime(2026, 12, 15),
          ),
          listeningStatisticsChangesProvider.overrideWith(
            (ref) => changes.stream,
          ),
          listeningStatisticsInitialFlushProvider.overrideWith((ref) async {
            flushes++;
          }),
          listeningRewindHasListeningProvider.overrideWithValue((range) async {
            loads++;
            return hasListening;
          }),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(listeningRewindSpotlightProvider, (_, _) {});
      expect(
        await container.read(listeningRewindSpotlightProvider.future),
        isNull,
      );
      hasListening = true;
      changes.add(1);
      await Future<void>.delayed(Duration.zero);
      expect(
        await container.read(listeningRewindSpotlightProvider.future),
        isNotNull,
      );
      expect(flushes, 1);
      expect(loads, 2);
      sub.close();
      await Future<void>.delayed(Duration.zero);
      changes.add(2);
      await Future<void>.delayed(Duration.zero);
      expect(loads, 2);
    },
  );
}
