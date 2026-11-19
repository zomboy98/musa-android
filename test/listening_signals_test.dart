import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/autoplay_taste.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/listening_signals.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

final _now = DateTime(2026, 11, 15, 12);

PlayableMedia _media(String artist, String title) => PlayableMedia(
  id: '$artist-$title',
  source: '/$artist/$title.flac',
  title: title,
  artist: artist,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  late Directory directory;

  setUp(() async {
    sqfliteFfiInit();
    directory = await Directory.systemTemp.createTemp('listening-signals-');
    addTearDown(() => directory.delete(recursive: true));
  });

  test('reads plays, loved songs and skips from the local stores', () async {
    final statsDb = await ListeningStatisticsStore.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/stats.db',
    );
    final collectionsDb = await LibraryCollectionsDatabase.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/collections.db',
    );
    final tasteDb = await AutoplayTaste.openWithFactory(
      databaseFactoryFfi,
      '${directory.path}/taste.db',
    );
    addTearDown(statsDb.close);
    addTearDown(collectionsDb.close);
    addTearDown(tasteDb.close);

    Future<void> listened(String day, String artist, String title, int plays) =>
        statsDb.insert('listening', {
          'day': day,
          'track_key': '/$artist/$title.flac',
          'title': title,
          'artist': artist,
          'album': '',
          'milliseconds': plays * 200000,
          'plays': plays,
        });
    await listened('2026-11-14', 'Ana', 'Uno', 3);
    await listened('2026-10-01', 'Ana', 'Uno', 2);
    await listened('2026-11-10', 'Ana', 'Dos', 1);
    await listened('2025-01-05', 'Beto', 'Viejo', 4);

    final loved = Track(
      id: 'tr-1',
      name: 'Tres',
      artistName: 'Cora',
      albumName: 'Disco',
      duration: 200,
    );
    await LibraryCollectionsDatabase.withDatabase(
      collectionsDb,
    ).upsertLovedEntry(
      trackKey: trackCollectionKey(loved),
      trackJson: jsonEncode(loved.toJson()),
      addedAt: _now.toIso8601String(),
    );

    await tasteDb.insert('plays', {
      'at': _now.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
      'kind': 'skipped',
      'reward': 0.0,
      'song': 'ana|dos',
      'artist': 'ana',
    });

    final signals = await loadDeviceListeningSignals(
      statistics: ListeningStatisticsStore.forTesting(statsDb),
      collections: LibraryCollectionsDatabase.withDatabase(collectionsDb),
      taste: AutoplayTaste(open: () async => tasteDb),
      now: _now,
    );

    final uno = _media('Ana', 'Uno');
    final dos = _media('Ana', 'Dos');
    final viejo = _media('Beto', 'Viejo');
    final tres = _media('Cora', 'Tres');
    expect(signals.playCount(uno), 5);
    expect(signals.lastPlayed(uno)!.day, 14);
    expect(signals.recentCompletions(uno), greaterThan(2));
    expect(signals.recentCompletions(viejo), 0);
    expect(signals.playCount(viejo), 4);
    expect(signals.lastPlayed(viejo)!.year, 2025);
    expect(signals.recentSkips(dos), greaterThan(0.8));
    expect(signals.artistSkips('ana'), greaterThan(0.8));
    expect(signals.artistCompletions('ana'), greaterThan(4));
    expect(signals.isFavorite(tres), isTrue);
    expect(signals.artistFavorites('cora'), 1);
    expect(signals.isFavorite(uno), isFalse);
    expect(signals.playCount(_media('Nadie', 'Nunca')), 0);
  });

  test('without local stores it still returns usable empty signals', () async {
    final signals = await loadDeviceListeningSignals(
      statistics: ListeningStatisticsStore.forTesting(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
      ),
      collections: LibraryCollectionsDatabase.withDatabase(
        await databaseFactoryFfi.openDatabase(inMemoryDatabasePath),
      ),
      now: _now,
    );
    expect(signals.playCount(_media('A', 'B')), 0);
    expect(signals.lastPlayed(_media('A', 'B')), isNull);
    expect(signals.isFavorite(_media('A', 'B')), isFalse);
  });
}
