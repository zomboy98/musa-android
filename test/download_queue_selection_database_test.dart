import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  SharedPreferences.setMockInitialValues({});

  test('retry completes while native discard is reserved', () async {
    final dir = await Directory.systemTemp.createTemp('native-retry-');
    final db = await AppStateDatabase.openWithFactory(
      databaseFactoryFfi,
      '${dir.path}/state.db',
    );
    final store = AppStateDatabase.withDatabase(db);
    DownloadItem item(String id) => DownloadItem(
      id: id,
      track: const Track(
        id: 't',
        name: 'S',
        artistName: 'A',
        albumName: 'B',
        duration: 1,
      ),
      service: 's',
      createdAt: DateTime.utc(2026),
    );
    var items = [item('a')];
    var attempt = 0;
    final writer = DownloadQueuePersistence(
      currentItems: () => items,
      onError: (_) {},
      loadRows: store.getPendingDownloadQueueRows,
      applyChanges: ({required upserts, required deletedIds}) =>
          store.applyPendingDownloadQueueChanges(
            upserts: upserts,
            deletedIds: deletedIds,
          ),
      applySelectionChanges:
          ({
            required upserts,
            required deletedIds,
            required selectionEvents,
          }) async {
            if (attempt++ == 0) throw StateError('disk full');
            await store.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: deletedIds,
              selectionEvents: selectionEvents,
            );
          },
      applyNativeDiscardChanges:
          ({
            required upserts,
            required deletedIds,
            required runId,
            required requestIds,
            required allRequests,
          }) => store.applyPendingDownloadQueueChanges(
            upserts: upserts,
            deletedIds: deletedIds,
            discardRunId: runId,
            discardRequestIds: requestIds,
            discardAllRequests: allRequests,
          ),
    );
    try {
      await expectLater(
        writer.persistSelectionEvents([
          {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'},
        ]),
        throwsStateError,
      );
      writer.reserveNativeDiscard();
      items = [item('new')];
      writer.schedule();
      await writer.persistSelectionEvents([]);
      expect((await store.getPendingDownloadQueueRows()).single['id'], 'a');
      await writer.persistNativeDiscard('run', snapshot: [], allRequests: true);
      writer.dispose();
      expect((await writer.restore()).single.id, 'new');
      expect((await store.loadNativeDiscards('run')).allRequests, isTrue);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('native reservation orders foreground schedule after discard', () async {
    DownloadItem item(String id) => DownloadItem(
      id: id,
      track: const Track(
        id: 't',
        name: 'S',
        artistName: 'A',
        albumName: 'B',
        duration: 1,
      ),
      service: 's',
      createdAt: DateTime.utc(2026),
    );
    var items = <DownloadItem>[];
    final writes = <String>[];
    final writer = DownloadQueuePersistence(
      currentItems: () => items,
      onError: (_) {},
      loadRows: () async => [],
      applyNativeDiscardChanges:
          ({
            required upserts,
            required deletedIds,
            required runId,
            required requestIds,
            required allRequests,
          }) async => writes.add('discard:$runId'),
      applyChanges: ({required upserts, required deletedIds}) async =>
          writes.add('queue:${upserts.single['id']}'),
    );
    writer.reserveNativeDiscard();
    writer.reserveNativeDiscard();
    items = [item('new')];
    writer.schedule();
    await writer.flush();
    expect(writes, isEmpty);
    final discard = writer.persistNativeDiscard(
      'run',
      snapshot: [],
      allRequests: true,
    );
    await discard;
    await writer.flush();
    expect(writes, ['discard:run']);
    writer.releaseNativeDiscard();
    writer.dispose();
    await writer.restore();
    expect(writes, ['discard:run', 'queue:new']);
  });

  test(
    'native discards commit with queue and survive restart by run',
    () async {
      final dir = await Directory.systemTemp.createTemp('native-discard-');
      final path = '${dir.path}/state.db';
      var db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
      var store = AppStateDatabase.withDatabase(db);
      final row = <String, dynamic>{
        'id': 'old',
        'item_json': '{}',
        'status': 'queued',
        'created_at': 'a',
        'updated_at': 'a',
      };
      try {
        await store.applyPendingDownloadQueueChanges(
          upserts: [row],
          deletedIds: [],
        );
        await expectLater(
          store.applyPendingDownloadQueueChanges(
            upserts: [],
            deletedIds: ['old'],
            discardRunId: 'run-a',
            discardRequestIds: {''},
          ),
          throwsArgumentError,
        );
        expect(await store.getPendingDownloadQueueRows(), hasLength(1));
        await store.applyPendingDownloadQueueChanges(
          upserts: [],
          deletedIds: ['old'],
          discardRunId: 'run-a',
          discardRequestIds: {'old'},
        );
        await store.applyPendingDownloadQueueChanges(
          upserts: [
            {...row, 'id': 'new'},
          ],
          deletedIds: [],
          discardRunId: 'run-b',
          discardAllRequests: true,
        );
        await db.close();
        db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
        store = AppStateDatabase.withDatabase(db);
        expect((await store.loadNativeDiscards('run-a')).requestIds, {'old'});
        expect((await store.loadNativeDiscards('run-a')).allRequests, isFalse);
        expect((await store.loadNativeDiscards('run-b')).allRequests, isTrue);
        expect((await store.loadNativeDiscards('other')).requestIds, isEmpty);
        expect((await store.getPendingDownloadQueueRows()).single['id'], 'new');
        await store.ackNativeDiscards('run-a', requestIds: {'old'});
        expect((await store.loadNativeDiscards('run-a')).requestIds, isEmpty);
        expect((await store.loadNativeDiscards('run-b')).allRequests, isTrue);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'retry preserves later scheduled queue snapshot after dispose',
    () async {
      final dir = await Directory.systemTemp.createTemp('queue-retry-');
      final db = await AppStateDatabase.openWithFactory(
        databaseFactoryFfi,
        '${dir.path}/state.db',
      );
      final store = AppStateDatabase.withDatabase(db);
      DownloadItem item(String id) => DownloadItem(
        id: id,
        track: const Track(
          id: 'track',
          name: 'Song',
          artistName: 'A',
          albumName: 'B',
          duration: 1,
        ),
        service: 'service',
        createdAt: DateTime.utc(2026),
      );
      var items = [item('a')];
      var attempt = 0;
      final writer = DownloadQueuePersistence(
        currentItems: () => items,
        onError: (_) {},
        loadRows: store.getPendingDownloadQueueRows,
        applyChanges: ({required upserts, required deletedIds}) =>
            store.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: deletedIds,
            ),
        applySelectionChanges:
            ({
              required upserts,
              required deletedIds,
              required selectionEvents,
            }) async {
              if (attempt++ == 0) throw StateError('disk full');
              await store.applyPendingDownloadQueueChanges(
                upserts: upserts,
                deletedIds: deletedIds,
                selectionEvents: selectionEvents,
              );
            },
      );
      try {
        await expectLater(
          writer.persistSelectionEvents([
            {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'},
          ]),
          throwsStateError,
        );
        items = [item('b')];
        writer.schedule();
        // Simulate the debounce expiring while the failed gesture is blocked.
        await writer.flush();
        await writer.persistSelectionEvents([]);
        writer.dispose();
        expect((await writer.restore()).map((i) => i.id), ['b']);
        expect(
          (await store.getDownloadQueueSelectionEvents()).single['request_id'],
          'a',
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'dispose waits for selection commit and saves later scheduled snapshot',
    () async {
      DownloadItem item(String id) => DownloadItem(
        id: id,
        track: const Track(
          id: 'track',
          name: 'S',
          artistName: 'A',
          albumName: 'B',
          duration: 1,
        ),
        service: 'service',
        createdAt: DateTime.utc(2026),
      );
      var items = [item('a')];
      final entered = Completer<void>();
      final release = Completer<void>();
      final snapshots = <List<String>>[];
      final writer = DownloadQueuePersistence(
        currentItems: () => items,
        onError: (_) {},
        applySelectionChanges:
            ({
              required upserts,
              required deletedIds,
              required selectionEvents,
            }) async {
              snapshots.add(upserts.map((r) => r['id'] as String).toList());
              entered.complete();
              await release.future;
            },
        applyChanges: ({required upserts, required deletedIds}) async {
          snapshots.add(upserts.map((r) => r['id'] as String).toList());
        },
        loadRows: () async => [],
      );
      final write = writer.persistSelectionEvents([
        {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'},
      ]);
      await entered.future;
      items = [item('b')];
      writer.schedule();
      writer.dispose();
      release.complete();
      await write;
      await writer.restore();
      expect(snapshots, [
        ['a'],
        ['b'],
      ]);
    },
  );

  test('explicit retry uses each original frozen selection snapshot', () async {
    DownloadItem item(String id) => DownloadItem(
      id: id,
      track: const Track(
        id: 'track',
        name: 'S',
        artistName: 'A',
        albumName: 'B',
        duration: 1,
      ),
      service: 'service',
      createdAt: DateTime.utc(2026),
    );
    var items = [item('a')];
    var attempt = 0;
    final snapshots = <List<String>>[];
    final writer = DownloadQueuePersistence(
      currentItems: () => items,
      onError: (_) {},
      applySelectionChanges:
          ({
            required upserts,
            required deletedIds,
            required selectionEvents,
          }) async {
            snapshots.add(upserts.map((r) => r['id'] as String).toList());
            if (attempt++ == 0) throw StateError('disk full');
          },
    );
    await expectLater(
      writer.persistSelectionEvents([
        {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'},
      ]),
      throwsStateError,
    );
    items = [item('b')];
    await expectLater(
      writer.persistSelectionEvents([
        {'event_id': 'b', 'request_id': 'b', 'track_json': '{}'},
      ]),
      throwsStateError,
    );
    items = [item('c')];
    await writer.persistSelectionEvents([]);
    expect(snapshots, [
      ['a'],
      ['a'],
      ['b'],
    ]);
  });

  test(
    'selection invalidates older debounce but preserves later schedules',
    () async {
      final dir = await Directory.systemTemp.createTemp('queue-debounce-');
      final db = await AppStateDatabase.openWithFactory(
        databaseFactoryFfi,
        '${dir.path}/state.db',
      );
      final store = AppStateDatabase.withDatabase(db);
      DownloadItem item(String id) => DownloadItem(
        id: id,
        track: const Track(
          id: 'track',
          name: 'Song',
          artistName: 'A',
          albumName: 'B',
          duration: 1,
        ),
        service: 'service',
        createdAt: DateTime.utc(2026),
      );
      var items = [item('old')];
      DownloadQueuePersistence create() => DownloadQueuePersistence(
        currentItems: () => items,
        onError: (_) {},
        loadRows: store.getPendingDownloadQueueRows,
        applyChanges: ({required upserts, required deletedIds}) =>
            store.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: deletedIds,
            ),
        applySelectionChanges:
            ({
              required upserts,
              required deletedIds,
              required selectionEvents,
            }) => store.applyPendingDownloadQueueChanges(
              upserts: upserts,
              deletedIds: deletedIds,
              selectionEvents: selectionEvents,
            ),
      );
      try {
        var writer = create();
        writer.schedule();
        items = [item('new')];
        await writer.persistSelectionEvents([
          {'event_id': '1', 'request_id': 'new', 'track_json': '{}'},
        ]);
        writer.dispose();
        expect((await writer.restore()).map((i) => i.id), ['new']);

        writer = create();
        await writer.restore();
        items = [item('later')];
        writer.schedule();
        writer.dispose();
        expect((await writer.restore()).map((i) => i.id), ['later']);
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('gesture freezes a mutable queue snapshot', () async {
    DownloadItem item(String id) => DownloadItem(
      id: id,
      track: const Track(
        id: 'track',
        name: 'Song',
        artistName: 'A',
        albumName: 'B',
        duration: 1,
      ),
      service: 'service',
      createdAt: DateTime.utc(2026),
    );
    final items = [item('a')];
    final savedIds = <String>[];
    final persistence = DownloadQueuePersistence(
      currentItems: () => items,
      onError: (_) {},
      applySelectionChanges:
          ({
            required upserts,
            required deletedIds,
            required selectionEvents,
          }) async {
            savedIds.addAll(upserts.map((row) => row['id'] as String));
          },
    );
    final write = persistence.persistSelectionEvents([
      {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'},
    ]);
    items.add(item('b'));
    await write;
    expect(savedIds, ['a']);
    persistence.dispose();
  });

  test('v5 upgrade preserves queue and creates an empty ledger', () async {
    final dir = await Directory.systemTemp.createTemp('queue-v5-');
    final path = '${dir.path}/state.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 5,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE download_queue_items '
            '(id TEXT PRIMARY KEY, item_json TEXT NOT NULL, status TEXT NOT NULL, '
            'created_at TEXT NOT NULL, updated_at TEXT NOT NULL)',
          );
          await db.insert('download_queue_items', {
            'id': 'legacy',
            'item_json': '{}',
            'status': 'queued',
            'created_at': 'a',
            'updated_at': 'a',
          });
        },
      ),
    );
    await old.close();
    final db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
    final store = AppStateDatabase.withDatabase(db);
    try {
      expect(await store.getDownloadQueueSelectionEvents(), isEmpty);
      expect(
        (await store.getPendingDownloadQueueRows()).single['id'],
        'legacy',
      );
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test(
    'failed events retry before later gestures in one durable batch',
    () async {
      var attempts = 0;
      final batches = <List<String>>[];
      final persistence = DownloadQueuePersistence(
        currentItems: () => [],
        onError: (_) {},
        applySelectionChanges:
            ({
              required upserts,
              required deletedIds,
              required selectionEvents,
            }) async {
              batches.add(
                selectionEvents.map((e) => e['event_id'] as String).toList(),
              );
              if (attempts++ == 0) throw StateError('disk full');
            },
      );
      final a = {'event_id': 'a', 'request_id': 'a', 'track_json': '{}'};
      final b = {'event_id': 'b', 'request_id': 'b', 'track_json': '{}'};
      await expectLater(
        persistence.persistSelectionEvents([a]),
        throwsStateError,
      );
      await expectLater(
        persistence.persistSelectionEvents([b]),
        throwsStateError,
      );
      await persistence.flush();
      expect(batches, [
        ['a'],
      ]);
      await persistence.persistSelectionEvents([]);
      expect(batches, [
        ['a'],
        ['a'],
        ['b'],
      ]);
      persistence.dispose();
    },
  );

  test(
    'selection and queue commit together, survive restart and replay',
    () async {
      final dir = await Directory.systemTemp.createTemp('queue-selection-');
      final path = '${dir.path}/state.db';
      var db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
      var store = AppStateDatabase.withDatabase(db);
      final row = <String, dynamic>{
        'id': 'request',
        'item_json': '{}',
        'status': 'queued',
        'created_at': 'a',
        'updated_at': 'a',
      };
      final event = <String, dynamic>{
        'event_id': 'event-1',
        'request_id': 'request',
        'track_json': '{}',
      };
      try {
        await store.applyPendingDownloadQueueChanges(
          upserts: [row],
          deletedIds: [],
          selectionEvents: [event],
        );
        await db.close();
        db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
        store = AppStateDatabase.withDatabase(db);
        await store.applyPendingDownloadQueueChanges(
          upserts: [],
          deletedIds: [],
          selectionEvents: [event],
        );
        expect(await store.getPendingDownloadQueueRows(), hasLength(1));
        expect(await store.getDownloadQueueSelectionEvents(), hasLength(1));

        await expectLater(
          store.applyPendingDownloadQueueChanges(
            upserts: [
              {...row, 'item_json': '{"changed":true}'},
            ],
            deletedIds: [],
            selectionEvents: [
              {...event, 'request_id': 'different'},
            ],
          ),
          throwsStateError,
        );
        expect(
          (await store.getPendingDownloadQueueRows()).single['item_json'],
          '{}',
        );
        expect(await store.getDownloadQueueSelectionEvents(), hasLength(1));
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
