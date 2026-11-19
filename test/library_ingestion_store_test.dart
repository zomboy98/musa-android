import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/library_ingestion_store.dart';

import 'support/library_native_fixture.dart';
import 'support/sqlite_process_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SqliteProcessDatabase database;
  late LibraryIngestionStore store;

  setUp(() async {
    database = await SqliteProcessDatabase.open();
    await createNativeLibraryFixture(database);
    store = LibraryIngestionStore(
      openDatabase: () async => database,
      ensureHistoryAttached: (_) async {},
    );
    await addNativeLibraryTrack(database, nativeLibraryTrack('kept'));
    await addNativeLibraryTrack(database, nativeLibraryTrack('gone'));
    await addNativeLibraryTrack(
      database,
      nativeLibraryTrack('elsewhere'),
      source: 'other',
    );
    await addNativeLibraryDownload(database, '/music/downloaded.flac');
  });
  tearDown(() => database.close());

  Future<List<String>> ids() async => [
    for (final row in await database.rawQuery(
      'SELECT id, source_id, track_name FROM library ORDER BY id',
    ))
      '${row['id']}@${row['source_id']}:${row['track_name']}',
  ];

  Future<List<String>> keyOwners() async => [
    for (final row in await database.rawQuery(
      'SELECT DISTINCT item_id FROM library_path_keys ORDER BY item_id',
    ))
      row['item_id'] as String,
  ];

  Future<List<Object?>> tempTables() async => [
    for (final row in await database.rawQuery(
      "SELECT name FROM sqlite_temp_master WHERE type = 'table'",
    ))
      row['name'],
  ];

  test('incremental upserts skip History files and keep the rest', () async {
    final result = await store.upsertBatchExcludingHistory([
      {...nativeLibraryTrack('kept'), 'trackName': 'Renamed'},
      nativeLibraryTrack('new'),
      nativeLibraryTrack('download', path: '/music/downloaded.flac'),
      {...nativeLibraryTrack('new'), 'trackName': 'Latest'},
    ], sourceId: 'source');

    expect(result, (upserted: 2, skipped: 1));
    expect(await ids(), [
      'elsewhere@other:Track elsewhere',
      'gone@source:Track gone',
      'kept@source:Renamed',
      'new@source:Latest',
    ]);
    expect(await keyOwners(), ['elsewhere', 'gone', 'kept', 'new']);
    expect(await tempTables(), isEmpty);
    await expectLater(
      store.upsertBatchExcludingHistory([
        {...nativeLibraryTrack('blank'), 'id': ' '},
      ], sourceId: 'source'),
      throwsFormatException,
    );
    expect(await tempTables(), isEmpty);
  });

  test('source replacement swaps one source and excludes History', () async {
    final result = await store.replaceSourceStream(
      'source',
      Stream.fromIterable([
        {...nativeLibraryTrack('kept'), 'trackName': 'Renamed'},
        nativeLibraryTrack('new'),
        nativeLibraryTrack('download', path: '/music/downloaded.flac'),
      ]),
      batchSize: 2,
    );

    expect(result, (inserted: 2, skipped: 1));
    expect(await ids(), [
      'elsewhere@other:Track elsewhere',
      'kept@source:Renamed',
      'new@source:Track new',
    ]);
    expect(await keyOwners(), ['elsewhere', 'kept', 'new']);
    expect(await tempTables(), isEmpty);
  });

  test(
    'partial rescan transfers only the matching path and keeps orphans',
    () async {
      await database.insert('library_manual_order', {
        'unified_id': 'local_kept',
        'position': 4,
      });
      await database.insert('library_manual_order', {
        'unified_id': 'local_missing',
        'position': 8,
      });
      await store.replaceSourceStream(
        'source',
        Stream.value(
          nativeLibraryTrack('replacement', path: '/music/kept.flac'),
        ),
        preserveMissing: true,
      );
      final order = await database.query(
        'library_manual_order',
        orderBy: 'position',
      );
      expect(order, [
        {'unified_id': 'local_replacement', 'position': 4},
        {'unified_id': 'local_missing', 'position': 8},
      ]);
    },
  );

  test('rescan leaves both positions when the new ID has an order', () async {
    await database.insert('library_manual_order', {
      'unified_id': 'local_kept',
      'position': 4,
    });
    await database.insert('library_manual_order', {
      'unified_id': 'local_replacement',
      'position': 9,
    });
    await store.replaceSourceStream(
      'source',
      Stream.value(nativeLibraryTrack('replacement', path: '/music/kept.flac')),
    );
    expect(await database.query('library_manual_order', orderBy: 'position'), [
      {'unified_id': 'local_kept', 'position': 4},
      {'unified_id': 'local_replacement', 'position': 9},
    ]);
  });

  test(
    'rescan rejects an ID owned by another source before transferring order',
    () async {
      await database.insert('library_manual_order', {
        'unified_id': 'local_kept',
        'position': 4,
      });
      await expectLater(
        store.replaceSourceStream(
          'source',
          Stream.value(
            nativeLibraryTrack('elsewhere', path: '/music/kept.flac'),
          ),
        ),
        throwsStateError,
      );
      expect(await database.query('library_manual_order'), [
        {'unified_id': 'local_kept', 'position': 4},
      ]);
    },
  );

  test(
    'same path in a different source is rejected without moving order',
    () async {
      await database.insert('library_manual_order', {
        'unified_id': 'local_kept',
        'position': 4,
      });
      await expectLater(
        store.replaceSourceStream(
          'other',
          Stream.value(
            nativeLibraryTrack('replacement', path: '/music/kept.flac'),
          ),
        ),
        throwsStateError,
      );
      expect(await database.query('library_manual_order'), [
        {'unified_id': 'local_kept', 'position': 4},
      ]);
    },
  );

  for (final incremental in [false, true]) {
    test(
      'History-skipped collision is harmless (${incremental ? 'incremental' : 'full'})',
      () async {
        final skipped = incremental
            ? (await store.upsertBatchExcludingHistory([
                nativeLibraryTrack('elsewhere', path: '/music/downloaded.flac'),
              ], sourceId: 'source')).skipped
            : (await store.replaceSourceStream(
                'source',
                Stream.value(
                  nativeLibraryTrack(
                    'elsewhere',
                    path: '/music/downloaded.flac',
                  ),
                ),
                preserveMissing: true,
              )).skipped;
        expect(skipped, 1);
        final owner = await database.query(
          'library',
          where: 'id = ?',
          whereArgs: ['elsewhere'],
        );
        expect(owner.single['source_id'], 'other');
        expect(owner.single['file_path'], '/music/elsewhere.flac');
      },
    );
    for (final collision in ['path', 'id', 'both']) {
      test(
        '${incremental ? 'incremental' : 'full'} scan preserves all data on cross-source $collision conflict',
        () async {
          await database.update(
            'library',
            {'cover_path': '/covers/owner.jpg', 'isrc': 'OWNER-ISRC'},
            where: 'id = ?',
            whereArgs: ['elsewhere'],
          );
          await database.insert('library_manual_order', {
            'unified_id': 'local_kept',
            'position': 4,
          });
          await database.insert('library_manual_order', {
            'unified_id': 'local_elsewhere',
            'position': 8,
          });
          final before = await nativeLibraryDigest(database);
          final orderBefore = await database.query(
            'library_manual_order',
            orderBy: 'unified_id',
          );
          final items = [
            // Would transfer an order and change same-source metadata if the
            // merge mutated data before discovering the next conflicting row.
            nativeLibraryTrack('replacement', path: '/music/kept.flac'),
            nativeLibraryTrack(
              collision == 'path' ? 'intruder' : 'elsewhere',
              path: collision == 'id'
                  ? '/music/unclaimed.flac'
                  : '/music/elsewhere.flac',
            ),
          ];
          await expectLater(
            incremental
                ? store.upsertBatchExcludingHistory(items, sourceId: 'source')
                : store.replaceSourceStream(
                    'source',
                    Stream.fromIterable(items),
                  ),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                contains('Library scan source conflict'),
              ),
            ),
          );
          expect(await nativeLibraryDigest(database), before);
          expect(
            await database.query('library_manual_order', orderBy: 'unified_id'),
            orderBefore,
          );
          expect(await tempTables(), isEmpty);
        },
      );
    }
  }

  test('failed rescan rolls back position and library rows', () async {
    await database.insert('library_manual_order', {
      'unified_id': 'local_kept',
      'position': 4,
    });
    await database.execute(
      "CREATE TRIGGER reject_scan BEFORE INSERT ON library WHEN NEW.id = 'replacement' BEGIN SELECT RAISE(ABORT, 'test rollback'); END",
    );
    await expectLater(
      store.replaceSourceStream(
        'source',
        Stream.value(
          nativeLibraryTrack('replacement', path: '/music/kept.flac'),
        ),
      ),
      throwsA(anything),
    );
    expect(await database.query('library_manual_order'), [
      {'unified_id': 'local_kept', 'position': 4},
    ]);
    expect(
      await database.query('library', where: 'id = ?', whereArgs: ['kept']),
      hasLength(1),
    );
  });

  test('Windows scan aliases appear once and match downloaded files', () async {
    await addNativeLibraryDownload(database, r'C:\Music\downloaded.flac');
    final result = await store.upsertBatchExcludingHistory([
      nativeLibraryTrack('win-a', path: r'\\?\C:\Music\song.flac'),
      nativeLibraryTrack('win-b', path: r'C:\Music\song.flac'),
      nativeLibraryTrack('win-download', path: r'\\?\C:\Music\downloaded.flac'),
    ], sourceId: 'source');
    expect(result, (upserted: 2, skipped: 1));
    final visible = await database.rawQuery(
      "SELECT id FROM library_visible WHERE id LIKE 'win-%' ORDER BY id",
    );
    expect(visible.map((row) => row['id']), ['win-a']);
    expect(
      await database.query('library', where: 'id = ?', whereArgs: ['win-b']),
      hasLength(1),
    );
  });
}
