import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/services/collection_restore_codec.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/services/link/sync/link_collection_sync_schema.dart';

import 'support/link_sync_support.dart';

const _events = ['insert', 'delete', 'rekey', 'update'];

Future<Database> _legacyDatabase(String path) async {
  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: 3,
      onCreate: (db, _) async {
        for (final table in ['wishlist_tracks', 'loved_tracks']) {
          await db.execute(
            'CREATE TABLE $table(track_key TEXT PRIMARY KEY, '
            'track_json TEXT NOT NULL, added_at TEXT NOT NULL)',
          );
        }
        await db.execute(
          'CREATE TABLE playlists(id TEXT PRIMARY KEY, name TEXT NOT NULL, '
          'cover_image_path TEXT, created_at TEXT NOT NULL, '
          'updated_at TEXT NOT NULL)',
        );
        await db.execute(
          'CREATE TABLE playlist_tracks(playlist_id TEXT NOT NULL, '
          'track_key TEXT NOT NULL, track_json TEXT NOT NULL, '
          'added_at TEXT NOT NULL, PRIMARY KEY (playlist_id, track_key))',
        );
        await db.execute(
          'CREATE TABLE favorite_artists(artist_key TEXT PRIMARY KEY, '
          'artist_json TEXT NOT NULL, added_at TEXT NOT NULL)',
        );
        await createLinkCollectionSyncSchema(db);
        for (final event in _events) {
          final operation = event == 'insert'
              ? 'INSERT'
              : event == 'delete'
              ? 'DELETE'
              : 'UPDATE';
          final row = event == 'delete' ? 'OLD' : 'NEW';
          await db.execute(
            'CREATE TRIGGER link_sync_wishlist_tracks_$event AFTER $operation '
            'ON wishlist_tracks BEGIN '
            'INSERT OR REPLACE INTO link_sync_changes '
            '(kind, scope, key, seq, updated_ms, deleted, origin) '
            "VALUES ('wishlist', '', $row.track_key, 1, 1, "
            "${event == 'delete' ? 1 : 0}, 'x'); END",
          );
        }
      },
    ),
  );
  addTearDown(db.close);
  return db;
}

Future<void> _seed(Database db) async {
  await db.insert('loved_tracks', {
    'track_key': 'example:both',
    'track_json': '{"id":"both","from":"loved"}',
    'added_at': '2026-01-01T00:00:00.000',
  });
  await db.insert('loved_tracks', {
    'track_key': 'example:loved-only',
    'track_json': '{"id":"loved-only"}',
    'added_at': '2026-01-02T00:00:00.000',
  });
  await db.insert('wishlist_tracks', {
    'track_key': 'example:both',
    'track_json': '{"id":"both","from":"wishlist"}',
    'added_at': '2026-02-01T00:00:00.000',
  });
  await db.insert('wishlist_tracks', {
    'track_key': 'example:wishlist-only',
    'track_json': '{"id":"wishlist-only","name":"音楽 🎵"}',
    'added_at': '2026-02-02T00:00:00.000',
  });
}

Future<Map<String, Map<String, Object?>>> _loved(Database db) async => {
  for (final row in await db.query('loved_tracks'))
    row['track_key']! as String: row,
};

void main() {
  late Directory directory;
  setUp(() async {
    directory = await linkSyncTempDirectory();
  });

  test(
    'folding the wishlist unions it into loved without duplicates',
    () async {
      final db = await _legacyDatabase('${directory.path}/legacy.db');
      await _seed(db);
      final triggersBefore = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'trigger' "
        "AND name LIKE 'link_sync_wishlist_tracks_%'",
      );
      expect(triggersBefore, hasLength(4));
      expect(
        await db.query('link_sync_changes', where: "kind = 'wishlist'"),
        isNotEmpty,
      );

      await LibraryCollectionsDatabase.foldLegacyWishlistIntoLoved(db);

      final loved = await _loved(db);
      expect(loved.keys.toSet(), {
        'example:both',
        'example:loved-only',
        'example:wishlist-only',
      });
      expect(loved, hasLength(3));
      expect(
        loved['example:both']!['track_json'],
        '{"id":"both","from":"loved"}',
      );
      expect(loved['example:both']!['added_at'], '2026-01-01T00:00:00.000');
      expect(
        loved['example:wishlist-only']!['track_json'],
        '{"id":"wishlist-only","name":"音楽 🎵"}',
      );
      expect(
        loved['example:wishlist-only']!['added_at'],
        '2026-02-02T00:00:00.000',
      );
      expect(await db.query('wishlist_tracks'), isEmpty);
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE type = 'trigger' "
          "AND name LIKE 'link_sync_wishlist_tracks_%'",
        ),
        isEmpty,
      );
      expect(
        await db.query('link_sync_changes', where: "kind = 'wishlist'"),
        isEmpty,
      );
      expect(
        await db.rawQuery(
          "SELECT name FROM sqlite_master WHERE name = 'wishlist_tracks'",
        ),
        hasLength(1),
      );
    },
  );

  test('folding the wishlist twice is idempotent', () async {
    final db = await _legacyDatabase('${directory.path}/twice.db');
    await _seed(db);
    await LibraryCollectionsDatabase.foldLegacyWishlistIntoLoved(db);
    final first = await _loved(db);
    final firstChanges = await db.query('link_sync_changes', orderBy: 'seq');
    await LibraryCollectionsDatabase.foldLegacyWishlistIntoLoved(db);
    expect(await _loved(db), first);
    expect(await db.query('link_sync_changes', orderBy: 'seq'), firstChanges);
    expect(await db.query('wishlist_tracks'), isEmpty);
  });

  test('opening a v3 database folds the wishlist during upgrade', () async {
    final path = '${directory.path}/upgrade.db';
    final legacy = await _legacyDatabase(path);
    await _seed(legacy);
    await legacy.close();

    final db = await LibraryCollectionsDatabase.openWithFactory(
      databaseFactoryFfi,
      path,
    );
    addTearDown(db.close);
    expect((await db.rawQuery('PRAGMA user_version')).first.values.first, 4);
    expect((await _loved(db)).keys.toSet(), {
      'example:both',
      'example:loved-only',
      'example:wishlist-only',
    });
    expect(await db.query('wishlist_tracks'), isEmpty);
  });

  test('restoring a backup with a wishlist yields only loved commands', () {
    Map<String, dynamic> entry(String key, String addedAt) => {
      'key': key,
      'track': {'id': key},
      'addedAt': addedAt,
    };
    final commands = collectionRestoreCommands({
      'wishlist': [
        entry('example:both', '2026-02-01'),
        entry('example:wishlist-only', '2026-02-02'),
        entry('example:wishlist-only', '2026-02-03'),
      ],
      'loved': [
        entry('example:loved-only', '2026-01-02'),
        entry('example:both', '2026-01-01'),
      ],
    }, '2026-10-07T05:00:00.000').toList();

    expect(commands.every((command) => command['kind'] == 'loved'), isTrue);
    final keys = [
      for (final command in commands)
        (command['values'] as Map<String, dynamic>)['track_key'],
    ];
    expect(keys, [
      'example:loved-only',
      'example:both',
      'example:wishlist-only',
    ]);
    expect(keys.toSet(), hasLength(keys.length));
    final both = commands
        .map((command) => command['values'] as Map<String, dynamic>)
        .firstWhere((values) => values['track_key'] == 'example:both');
    expect(both['added_at'], '2026-01-01');
  });
}
