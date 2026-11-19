import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart'
    show databaseFactoryFfi, sqfliteFfiInit;
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/library_row_mapper.dart';

Map<String, dynamic> _scanned(String id, String path, String title) =>
    LocalLibraryItem(
      id: id,
      sourceId: 'music',
      trackName: title,
      artistName: 'Band',
      albumName: 'LP',
      filePath: path,
      scannedAt: DateTime.utc(2026, 10, 1),
      fileModTime: 1234,
      trackNumber: 1,
    ).toJson();

Future<void> _add(Map<String, dynamic> json) async {
  final db = await LibraryDatabase.instance.database;
  await db.insert('library', LibraryRowMapper.encode(json));
}

void main() {
  final messenger =
      TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library-relink-');
    sqfliteFfiInit();
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previousFactory;
      await root.delete(recursive: true);
    });
    final db = await LibraryDatabase.instance.database;
    await db.insert('library_sources', {
      'id': 'music',
      'path': '/music',
      'display_name': 'music',
      'available': 1,
      'enabled': 1,
    });
  });

  test('a moved file keeps its row under the new path', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('old', '/music/incoming/a.mp3', 'A'));
    await _add(_scanned('other', '/music/b.mp3', 'B'));
    final db = await library.database;
    await db.insert('library_manual_order', {
      'unified_id': 'local_old',
      'position': 7,
    });

    final before = await library.getPage(limit: 10);
    expect(before.map((row) => row['filePath']), {
      '/music/incoming/a.mp3',
      '/music/b.mp3',
    });

    expect(
      await library.relinkMovedFile(
        '/music/incoming/a.mp3',
        '/music/Band/LP/01 - A.mp3',
      ),
      isTrue,
    );

    final rows = await library.getPage(limit: 10);
    final moved = rows.singleWhere((row) => row['trackName'] == 'A');
    expect(moved['filePath'], '/music/Band/LP/01 - A.mp3');
    expect(moved['id'], isNot('old'));
    expect(moved['fileModTime'], 1234);
    expect(await library.getById('old'), isNull);
    expect((await library.getById(moved['id'] as String))?['trackName'], 'A');
    expect(await library.getCount(), 2);

    expect((await db.query('library_manual_order')).single, {
      'unified_id': 'local_${moved['id']}',
      'position': 7,
    });
    final keys = await db.query(
      'library_path_keys',
      where: 'item_id = ?',
      whereArgs: ['old'],
    );
    expect(keys, isEmpty);
  });

  test('a stale row at the destination is replaced, not duplicated', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('moving', '/music/x.mp3', 'X'));
    await _add(_scanned('stale', '/music/Band/x.mp3', 'Old copy'));

    expect(
      await library.relinkMovedFile('/music/x.mp3', '/music/Band/x.mp3'),
      isTrue,
    );

    final rows = await library.getPage(limit: 10);
    expect(rows, hasLength(1));
    expect(rows.single['trackName'], 'X');
    expect(rows.single['filePath'], '/music/Band/x.mp3');
  });

  test('an unknown path is reported, not invented', () async {
    expect(
      await LibraryDatabase.instance.relinkMovedFile('/nope.mp3', '/a.mp3'),
      isFalse,
    );
  });

  test(
    'conversion transfers ordering only when replacing the original',
    () async {
      final library = LibraryDatabase.instance;
      final db = await library.database;
      final original = LocalLibraryItem.fromJson(
        _scanned('original', '/music/a.flac', 'A'),
      );
      await _add(original.toJson());
      await db.insert('library_manual_order', {
        'unified_id': 'local_original',
        'position': 5,
      });
      await library.replaceWithConvertedItem(
        item: original,
        newFilePath: '/music/a.mp3',
        targetFormat: 'mp3',
        bitrate: '320',
      );
      final converted = (await library.getPage(limit: 10)).single;
      expect(await db.query('library_manual_order'), [
        {'unified_id': 'local_${converted['id']}', 'position': 5},
      ]);
    },
  );

  test('failed position transfer rolls back the move', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('old', '/music/a.flac', 'A'));
    final db = await library.database;
    await db.insert('library_manual_order', {
      'unified_id': 'local_old',
      'position': 5,
    });
    await db.execute('''
      CREATE TRIGGER reject_position_update BEFORE UPDATE ON library_manual_order
      BEGIN SELECT RAISE(ABORT, 'test rollback'); END
    ''');
    await expectLater(
      library.relinkMovedFile('/music/a.flac', '/music/b.flac'),
      throwsA(anything),
    );
    expect((await library.getById('old'))?['filePath'], '/music/a.flac');
    expect((await db.query('library_manual_order')).single['position'], 5);
  });

  test('keeping the original conversion leaves its manual order', () async {
    final library = LibraryDatabase.instance;
    final original = LocalLibraryItem.fromJson(
      _scanned('original', '/music/a.flac', 'A'),
    );
    await _add(original.toJson());
    final db = await library.database;
    await db.insert('library_manual_order', {
      'unified_id': 'local_original',
      'position': 5,
    });
    await library.replaceWithConvertedItem(
      item: original,
      newFilePath: '/music/a.mp3',
      targetFormat: 'mp3',
      bitrate: '320',
      keepOriginal: true,
    );
    expect(await library.getCount(), 2);
    expect(await db.query('library_manual_order'), [
      {'unified_id': 'local_original', 'position': 5},
    ]);
  });

  test('failed conversion rolls back the transferred position', () async {
    final library = LibraryDatabase.instance;
    final original = LocalLibraryItem.fromJson(
      _scanned('original', '/music/a.flac', 'A'),
    );
    await _add(original.toJson());
    final db = await library.database;
    await db.insert('library_manual_order', {
      'unified_id': 'local_original',
      'position': 5,
    });
    await db.execute(
      "CREATE TRIGGER reject_conversion BEFORE INSERT ON library WHEN NEW.file_path = '/music/a.mp3' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
    );
    await expectLater(
      library.replaceWithConvertedItem(
        item: original,
        newFilePath: '/music/a.mp3',
        targetFormat: 'mp3',
        bitrate: '320',
      ),
      throwsA(anything),
    );
    expect((await library.getById('original'))?['filePath'], '/music/a.flac');
    expect(await db.query('library_manual_order'), [
      {'unified_id': 'local_original', 'position': 5},
    ]);
  });

  test('upgrade from 22 preserves library rows across reopen', () async {
    final library = LibraryDatabase.instance;
    await _add(_scanned('old', '/music/a.flac', 'A'));
    final db = await library.database;
    await db.execute('DROP TABLE library_manual_order');
    await db.execute('PRAGMA user_version = 22');
    await library.close();
    final reopened = await library.database;
    expect((await library.getById('old'))?['trackName'], 'A');
    expect(await reopened.query('library_manual_order'), isEmpty);
    expect(
      Sqflite.firstIntValue(await reopened.rawQuery('PRAGMA user_version')),
      23,
    );
  });
}
