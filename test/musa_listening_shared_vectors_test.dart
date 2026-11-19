import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  test('recorder matches shared MUSA listening vectors', () async {
    final lines = File('rust_backend/crates/musa-listening/tests/vectors.txt')
        .readAsLinesSync().where((line) => line.isNotEmpty && !line.startsWith('#'));
    for (final line in lines) {
      final fields = line.split('|');
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => DateTime(2026, 10, 2),
      );
      ListeningTrack? track(String key) => key == '-' ? null : ListeningTrack(
        key: key, title: key, artist: '', album: '',
      );
      for (final event in fields[1].split(',')) {
        final p = event.split(':');
        switch (p[0]) {
          case 'u': recorder.update(track(p[1]), playing: p[2] == '1');
          case 'x': recorder.update(track(p[1]), playing: false, ended: true);
          case 'e': recorder.setEnabled(p[1] == '1');
          case 't': elapsed += Duration(milliseconds: int.parse(p[1]));
          default: throw StateError('Unknown vector event: $event');
        }
      }
      await recorder.flush();
      final actual = {for (final d in writes) d.track.key: [d.milliseconds, d.plays]};
      final expected = <String, List<int>>{};
      if (fields[2] != '-') {
        for (final item in fields[2].split(',')) {
          final p = item.split(':');
          expected[p[0]] = [int.parse(p[1]), int.parse(p[2])];
        }
      }
      expect(actual, expected, reason: fields[0]);
    }
  });
}
