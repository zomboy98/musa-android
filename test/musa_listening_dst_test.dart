import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/listening_statistics.dart';

void main() {
  // Refuse to infer the zone from the machine's current offset alone.
  final newYork = Platform.environment['TZ'] == 'America/New_York' &&
      DateTime(2026, 3, 8).timeZoneOffset == const Duration(hours: -5) &&
      DateTime(2026, 3, 9).timeZoneOffset == const Duration(hours: -4) &&
      DateTime(2026, 11, 1).timeZoneOffset == const Duration(hours: -4) &&
      DateTime(2026, 11, 2).timeZoneOffset == const Duration(hours: -5);
  test('recorder splits New York DST intervals at local midnight', () async {
    final vectors = <(DateTime, Duration, List<(String, int)>)>[
      (DateTime(2026, 3, 8), const Duration(hours: 23, seconds: 1), [('2026-03-08', 82800000), ('2026-03-09', 1000)]),
      (DateTime(2026, 11, 1), const Duration(hours: 25, seconds: 1), [('2026-11-01', 90000000), ('2026-11-02', 1000)]),
      (DateTime(2026, 3, 7, 23, 59, 50), const Duration(hours: 23, seconds: 20), [('2026-03-07', 10000), ('2026-03-08', 82800000), ('2026-03-09', 10000)]),
      (DateTime.utc(2026, 11, 1, 5, 59, 50).toLocal(), const Duration(seconds: 20), [('2026-11-01', 20000)]),
    ];
    for (final (start, duration, expected) in vectors) {
      var elapsed = Duration.zero;
      final writes = <ListeningDelta>[];
      final recorder = ListeningRecorder(
        write: (batch) async => writes.addAll(batch),
        elapsed: () => elapsed,
        now: () => start.add(elapsed),
      );
      recorder.update(const ListeningTrack(key: 'A', title: '', artist: '', album: ''), playing: true);
      elapsed = duration;
      await recorder.flush();
      expect(writes.map((d) => (d.day, d.milliseconds)).toList(), expected);
    }
  }, skip: newYork ? false : 'Run in an isolated process with TZ=America/New_York and matching IANA rules');
}
