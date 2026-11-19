import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';

import 'support/sqlite_process_database.dart';

void main() {
  test(
    'clearing retained history invalidates disabled-recording mix cache',
    () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await db.execute(
        'CREATE TABLE listening (day TEXT, track_key TEXT, title TEXT, artist TEXT, plays INTEGER)',
      );
      await db.insert('listening', {
        'day': '2026-11-06',
        'track_key': '/music',
        'title': 'Song',
        'artist': 'Artist',
        'plays': 4,
      });
      final changes = StreamController<int>.broadcast(sync: true);
      addTearDown(changes.close);
      final container = ProviderContainer(
        overrides: [
          listeningStatisticsChangesProvider.overrideWith(
            (ref) => changes.stream,
          ),
          listeningStatisticsInitialFlushProvider.overrideWith((ref) async {}),
          libraryMixListeningRevisionLoadProvider.overrideWithValue(
            (now, _, _) async => libraryMixHistoryRevision(
              await libraryMixHistoryRows(db, now),
              sources: {'/music'},
              songs: {},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final provider = libraryMixListeningRevisionProvider((
        day: '2026-11-06',
        includeLocal: false,
        indexRevision: '1',
      ));
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      final before = libraryMixTasteRevision(
        [],
        await container.read(provider.future),
        false,
      );
      await db.delete('listening');
      changes.add(1);
      await Future<void>.delayed(Duration.zero);
      final after = libraryMixTasteRevision(
        [],
        await container.read(provider.future),
        false,
      );
      expect(after, isNot(before));
      expect(
        libraryMixesStale(
          cachedDay: '2026-11-06',
          cachedIncludeLocal: false,
          cachedCount: 10,
          cachedEmpty: false,
          cachedTasteRevision: before,
          tasteRevision: after,
          day: '2026-11-06',
          includeLocal: false,
          count: 10,
        ),
        isTrue,
      );
    },
  );
}
