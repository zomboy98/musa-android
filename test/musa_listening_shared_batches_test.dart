import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  test('recorder matches shared day and flush vectors', () async {
    final lines = File('rust_backend/crates/musa-listening/tests/batch_vectors.txt')
        .readAsLinesSync().where((l) => l.isNotEmpty && !l.startsWith('#'));
    for (final line in lines) {
      final p = line.split('|');
      final start = DateTime(2026, 10, 1).add(Duration(milliseconds: int.parse(p[1])));
      var elapsed = Duration.zero;
      final batches = <String>[];
      final recorder = ListeningRecorder(
        write: (batch) async {
          final entries = batch.map((d) => '${d.day}:${d.track.key}:${d.milliseconds}:${d.plays}').toList()..sort();
          batches.add(entries.join(';'));
        },
        elapsed: () => elapsed,
        now: () => start.add(elapsed),
      );
      for (final event in p[2].split(',')) {
        final f = event.split(':');
        switch (f[0]) {
          case 't': elapsed += Duration(milliseconds: int.parse(f[1]));
          case 'u': recorder.update(ListeningTrack(key: f[1], title: '', artist: '', album: ''), playing: f[2] == '1');
          case 'c': recorder.checkpoint();
          case 'f': await recorder.flush();
          default: throw StateError('Unknown event: $event');
        }
      }
      expect(batches.join('/'), p[3], reason: p[0]);
    }
  });
}
