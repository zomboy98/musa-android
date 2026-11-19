import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_queue_store.dart';
import 'package:mornye/services/library_schema.dart';

import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'manual order persists across pages and preserves hidden entries',
    () async {
      final db = await SqliteProcessDatabase.open();
      addTearDown(db.close);
      await LibrarySchema.create(db, LibrarySchema.version);
      await db.execute("ATTACH DATABASE ':memory:' AS history_db");
      final definition = RegExp(r'CREATE TABLE history\s*\([\s\S]*?\n\s*\)')
          .firstMatch(
            File('lib/services/history_schema.dart').readAsStringSync(),
          )!
          .group(0)!;
      await db.execute(
        definition.replaceFirst(
          'CREATE TABLE history',
          'CREATE TABLE history_db.history',
        ),
      );
      await db.execute(
        'CREATE TABLE history_db.history_path_keys (item_id TEXT, path_key TEXT)',
      );
      final batch = db.batch();
      for (var i = 0; i < 350; i++) {
        batch.insert('library', {
          'id': '$i',
          'track_name': 'Track $i',
          'artist_name': 'Artist',
          'album_name': 'Album',
          'file_path': '/$i.flac',
          'scanned_at': '2026-01-01',
          'sort_added': i ~/ 4,
          'track_name_norm': 'track $i',
          'artist_name_norm': 'artist',
          'album_name_norm': 'album',
          'sort_genre': '',
          'sort_release': '',
        });
      }
      await batch.commit(noResult: true);
      await db.insert('history_db.history', {
        'id': 'h',
        'track_name': 'Track 348',
        'artist_name': 'Artist',
        'album_name': 'Album',
        'file_path': '/download.flac',
        'service': 'test',
        'downloaded_at': '2026-01-01',
        'sort_added': 87,
        'sort_track': 'track 348',
        'sort_artist': 'artist',
        'sort_album': 'album',
        'sort_genre': '',
        'sort_release': '',
      });
      await db.insert('library_manual_order', {
        'unified_id': 'local_orphan',
        'position': 0,
      });
      final library = LibraryDatabase.withDatabase(db, historyAttached: true);
      final store = LibraryQueueStore(db, historyFts: false, localFts: false);
      final initial = await store.trackPage(
        const QueueLibraryDbQuery(sortMode: 'manual', limit: 400),
      );
      final expected = initial.rows
          .map((row) => (row['item'] as Map)['id'] as String)
          .toList();
      final selected = expected.where((id) => id == '1' || id == '2').toList();
      expected.removeWhere((id) => id == '1' || id == '2');
      expected.insertAll(expected.indexOf('349'), selected);
      await library.moveManualLibraryTracks([
        'local_1',
        'local_2',
      ], beforeId: 'local_349');
      final ids = <String>[];
      QueueLibraryDbCursor? cursor;
      do {
        final page = await store.trackPage(
          QueueLibraryDbQuery(
            sortMode: 'manual',
            limit: 80,
            cursor: cursor,
            offset: ids.length,
          ),
        );
        ids.addAll(
          page.rows.map((row) => (row['item'] as Map)['id'] as String),
        );
        cursor = page.rows.length == 80 ? page.nextCursor : null;
      } while (cursor != null);
      expect(ids.length, 351);
      expect(ids.toSet().length, 351);
      expect(ids, expected);
      final saved = (await db.query(
        'library',
        where: 'id = ?',
        whereArgs: ['1'],
      )).single;
      await db.delete('library', where: 'id = ?', whereArgs: ['1']);
      final orderBeforeRejectedMoves = await db.query(
        'library_manual_order',
        orderBy: 'position',
      );
      await expectLater(
        library.moveManualLibraryTracks(['local_3'], beforeId: 'local_1'),
        throwsStateError,
      );
      await expectLater(
        library.moveManualLibraryTracks([
          'local_1',
          'local_3',
        ], beforeId: 'local_349'),
        throwsStateError,
      );
      expect(
        await db.query('library_manual_order', orderBy: 'position'),
        orderBeforeRejectedMoves,
      );
      await library.moveManualLibraryTracks(['local_3'], beforeId: 'local_349');
      await db.insert('library', saved);
      expected.remove('3');
      expected.insert(expected.indexOf('349'), '3');
      final restored = await store.trackPage(
        const QueueLibraryDbQuery(sortMode: 'manual', limit: 351),
      );
      expect(restored.rows.map((row) => (row['item'] as Map)['id']), expected);
      expect(
        await db.query(
          'library_manual_order',
          where: 'unified_id = ?',
          whereArgs: ['local_orphan'],
        ),
        hasLength(1),
      );
      await expectLater(
        library.moveManualLibraryTracks(['local_1'], beforeId: 'local_missing'),
        throwsStateError,
      );
      expect(
        (await db.query(
          'library_manual_order',
          where: 'unified_id = ?',
          whereArgs: ['local_1'],
        )).single['position'],
        expected.indexOf('1') + 1,
      );
    },
  );
}
