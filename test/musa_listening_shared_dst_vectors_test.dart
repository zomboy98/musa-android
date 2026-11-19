import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  final newYork = Platform.environment['TZ'] == 'America/New_York' &&
      DateTime(2026, 3, 8).timeZoneOffset == const Duration(hours: -5) &&
      DateTime(2026, 3, 9).timeZoneOffset == const Duration(hours: -4) &&
      DateTime(2026, 11, 1).timeZoneOffset == const Duration(hours: -4) &&
      DateTime(2026, 11, 2).timeZoneOffset == const Duration(hours: -5);

  test('real recorder matches shared DST vectors', () async {
    final lines = File('rust_backend/crates/musa-listening/tests/dst_vectors.txt')
        .readAsLinesSync();
    for (final line in lines.where((line) => line.isNotEmpty && !line.startsWith('#'))) {
      final fields = line.split('|');
      final start = DateTime.fromMillisecondsSinceEpoch(int.parse(fields[1]));
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => start.add(elapsed),
      );
      recorder.update(const ListeningTrack(key: 'A', title: '', artist: '', album: ''), playing: true);
      elapsed = Duration(milliseconds: int.parse(fields[2]));
      await recorder.flush();
      expect(writes.map((d) => '${d.day}:${d.milliseconds}:${d.plays}').join(';'), fields[3], reason: fields[0]);
    }
  }, skip: newYork ? false : 'Requires isolated process with TZ=America/New_York and matching IANA rules');
}
