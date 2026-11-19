import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show DatabaseException;
import 'playlist_link_import_test.dart' show first, second;
import 'support/link_sync_support.dart';

class DelayedCollections extends LibraryCollectionsDatabase {
  DelayedCollections(super.database) : super.withDatabase();
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> createImportedPlaylist({
    required String id,
    required String name,
    required String timestamp,
    required List<Map<String, String>> tracks,
  }) async {
    started.complete();
    await release.future;
    await super.createImportedPlaylist(
      id: id,
      name: name,
      timestamp: timestamp,
      tracks: tracks,
    );
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('SQLite rollback and retry preserve order and duplicates', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'file-import');
    final notifier = LibraryCollectionsNotifier(
      database: LibraryCollectionsDatabase.withDatabase(db),
    );
    final container = ProviderContainer(
      overrides: [libraryCollectionsProvider.overrideWith(() => notifier)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container.read(libraryCollectionsProvider);
    await db.execute(
      "CREATE TRIGGER fail_import BEFORE INSERT ON playlist_tracks WHEN (SELECT COUNT(*) FROM playlist_tracks) = 1 BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(
      saveImportedPlaylist(notifier, 'File', [first, second, first]),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.query('playlists'), isEmpty);
    expect(await db.query('playlist_tracks'), isEmpty);
    await db.execute('DROP TRIGGER fail_import');
    await saveImportedPlaylist(notifier, 'File', [first, second, first]);
    final rows = await db.rawQuery(
      'SELECT track_json FROM playlist_tracks ORDER BY added_at,rowid',
    );
    expect(rows.map((row) => jsonDecode(row['track_json']! as String)), [
      first.toJson(),
      second.toJson(),
      first.toJson(),
    ]);
  });
  test('provider disposal during save commits the complete import', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'file-dispose');
    final database = DelayedCollections(db);
    final notifier = LibraryCollectionsNotifier(database: database);
    final container = ProviderContainer(
      overrides: [libraryCollectionsProvider.overrideWith(() => notifier)],
    );
    addTearDown(() async {
      await db.close();
    });
    container.read(libraryCollectionsProvider);
    final saving = saveImportedPlaylist(notifier, 'File', [
      first,
      second,
      first,
    ]);
    await database.started.future;
    container.dispose();
    database.release.complete();
    expect((await saving).addedCount, 3);
    expect(await db.query('playlists'), hasLength(1));
    expect(await db.query('playlist_tracks'), hasLength(3));
  });

  test('concurrent playlist creation is retained while import saves', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'file-concurrent');
    final database = DelayedCollections(db);
    final notifier = LibraryCollectionsNotifier(database: database);
    final container = ProviderContainer(
      overrides: [libraryCollectionsProvider.overrideWith(() => notifier)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container.read(libraryCollectionsProvider);
    final saving = saveImportedPlaylist(notifier, 'Imported', [first, first]);
    await database.started.future;
    final creating = notifier.createPlaylist('Concurrent');
    database.release.complete();
    await saving;
    await creating;
    expect(
      container.read(libraryCollectionsProvider).playlists.map((p) => p.name),
      containsAll(['Imported', 'Concurrent']),
    );
    expect(await db.query('playlists'), hasLength(2));
    expect(await db.query('playlist_tracks'), hasLength(2));
  });

  test('failure in a later batch rolls back earlier batches', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'file-large');
    final notifier = LibraryCollectionsNotifier(
      database: LibraryCollectionsDatabase.withDatabase(db),
    );
    final container = ProviderContainer(
      overrides: [libraryCollectionsProvider.overrideWith(() => notifier)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    container.read(libraryCollectionsProvider);
    await db.execute(
      "CREATE TRIGGER fail_later BEFORE INSERT ON playlist_tracks WHEN (SELECT COUNT(*) FROM playlist_tracks) = 128 BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );
    await expectLater(
      saveImportedPlaylist(notifier, 'Large', List.filled(130, first)),
      throwsA(isA<DatabaseException>()),
    );
    expect(await db.query('playlists'), isEmpty);
    expect(await db.query('playlist_tracks'), isEmpty);
  });
}
