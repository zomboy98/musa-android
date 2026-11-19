import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/utils/logger.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/native_discard_memory.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    downloadDirectory: '/fixture',
    allowQualityVariants: true,
    networkDownloadFolder: 'smb://fixture',
  );
}

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<void> cancel({required int id}) async {}
}

const _track = Track(
  id: 'x',
  name: 'x',
  artistName: 'x',
  albumName: 'x',
  duration: 1,
  isrc: 'XX0000000001',
);

Future<void> _until(bool Function() predicate) async {
  for (var i = 0; i < 200 && !predicate(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(predicate(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterLocalNotificationsPlatform.instance = _Notifications();
  });

  test(
    'SQLite native confirmation and ledger ACK retry across restarts',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'mornye-discard-retry-',
      );
      final path = '${dir.path}/state.db';
      var db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
      var store = AppStateDatabase.withDatabase(db);
      final newcomer = DownloadItem(
        id: 'new',
        track: _track,
        service: '',
        createdAt: DateTime.utc(2026),
      );
      await store.applyPendingDownloadQueueChanges(
        upserts: [
          {
            'id': newcomer.id,
            'item_json': encodeDownloadQueueItemForPersistence(newcomer),
            'status': 'queued',
            'created_at': newcomer.createdAt.toIso8601String(),
            'updated_at': newcomer.createdAt.toIso8601String(),
          },
        ],
        deletedIds: [],
        discardRunId: 'run-one',
        discardRequestIds: {'old'},
      );
      await store.applyPendingDownloadQueueChanges(
        upserts: [],
        deletedIds: [],
        discardRunId: 'run-two',
        discardRequestIds: {'other'},
      );
      await db.close();
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'run-one',
        'download_queue_user_paused_v1': true,
      });
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var nativeConfirm = false;
      var failDbAck = false;
      final confirmations = <List<String>>[];
      final snapshot = {
        'run_id': 'run-one',
        'contract_version': 1,
        'is_running': false,
        'items': [
          {'item_id': 'old', 'status': 'completed'},
        ],
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'discardStoppedNativeDownloadWorkerItems') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          confirmations.add((args['item_ids'] as List).cast<String>());
          return nativeConfirm;
        }
        if (call.method == 'getNativeDownloadWorkerSnapshot') return snapshot;
        return null;
      });
      ProviderContainer scope() => ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeSnapshotForTesting: () async => snapshot,
              queuePersistenceForTesting: (items, error) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: error,
                    loadRows: store.getPendingDownloadQueueRows,
                    loadSelectionEvents: store.getDownloadQueueSelectionEvents,
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
                    loadNativeDiscardsFromStorage: store.loadNativeDiscards,
                    ackNativeDiscardsInStorage:
                        (
                          runId, {
                          required requestIds,
                          required allRequests,
                        }) async {
                          if (failDbAck)
                            throw StateError('injected DB ACK failure');
                          await store.ackNativeDiscards(
                            runId,
                            requestIds: requestIds,
                            allRequests: allRequests,
                          );
                        },
                  ),
            ),
          ),
        ],
      );
      ProviderContainer? container;
      try {
        for (var phase = 0; phase < 3; phase++) {
          db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
          store = AppStateDatabase.withDatabase(db);
          nativeConfirm = phase > 0;
          failDbAck = phase == 1;
          container = scope();
          container.read(downloadQueueProvider);
          await _until(() => confirmations.length > phase);
          if (phase < 2) {
            await _until(
              () =>
                  container!.read(downloadQueueProvider).nativeRecoveryRequired,
            );
            expect((await store.loadNativeDiscards('run-one')).requestIds, {
              'old',
            });
          } else {
            await _until(
              () => container!.read(downloadQueueProvider).items.isNotEmpty,
            );
            await _until(
              () => !container!
                  .read(downloadQueueProvider)
                  .nativeRecoveryRequired,
            );
            await _until(() => confirmations.length == 3);
            for (
              var i = 0;
              i < 200 &&
                  (await store.loadNativeDiscards(
                    'run-one',
                  )).requestIds.isNotEmpty;
              i++
            ) {
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
            expect(
              (await store.loadNativeDiscards('run-one')).requestIds,
              isEmpty,
            );
          }
          expect((await store.loadNativeDiscards('run-two')).requestIds, {
            'other',
          });
          expect(
            (await store.getPendingDownloadQueueRows()).map((row) => row['id']),
            contains('new'),
          );
          container.dispose();
          container = null;
          await db.close();
        }
        expect(confirmations, [
          ['old'],
          ['old'],
          ['old'],
        ]);
      } finally {
        container?.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        if (db.isOpen) await db.close();
        if (await File(path).exists()) await File(path).delete();
        await dir.delete();
      }
    },
  );

  test(
    'SQLite discard survives restart and never authorizes unknown result',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'mornye-native-restart-',
      );
      final path = '${dir.path}/state.db';
      var db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
      var store = AppStateDatabase.withDatabase(db);
      await store.applyPendingDownloadQueueChanges(
        upserts: [],
        deletedIds: ['removed'],
        discardRunId: 'sqlite-run',
        discardRequestIds: {'removed'},
      );
      await db.close();
      db = await AppStateDatabase.openWithFactory(databaseFactoryFfi, path);
      store = AppStateDatabase.withDatabase(db);
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'sqlite-run',
      });
      final confirmations = <List<String>>[];
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'discardStoppedNativeDownloadWorkerItems') {
          final args = Map<String, dynamic>.from(call.arguments as Map);
          confirmations.add((args['item_ids'] as List).cast<String>());
          return true;
        }
        return null;
      });
      final snapshot = {
        'run_id': 'sqlite-run',
        'contract_version': 1,
        'is_running': false,
        'items': [
          {'item_id': 'removed', 'status': 'completed'},
          {'item_id': 'unknown', 'status': 'completed'},
        ],
      };
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeSnapshotForTesting: () async => snapshot,
              queuePersistenceForTesting: (items, error) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: error,
                    loadRows: store.getPendingDownloadQueueRows,
                    loadSelectionEvents: store.getDownloadQueueSelectionEvents,
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
                    loadNativeDiscardsFromStorage: store.loadNativeDiscards,
                    ackNativeDiscardsInStorage: store.ackNativeDiscards,
                  ),
            ),
          ),
        ],
      );
      try {
        container.read(downloadQueueProvider);
        await _until(() => confirmations.isNotEmpty);
        await _until(
          () => container.read(downloadQueueProvider).nativeRecoveryRequired,
        );
        expect(confirmations.single, ['removed']);
        expect(container.read(downloadQueueProvider).items, isEmpty);
        expect(
          (await SharedPreferences.getInstance()).getString(
            'download_queue_native_worker_run_id',
          ),
          'sqlite-run',
        );
      } finally {
        container.dispose();
        messenger.setMockMethodCallHandler(channel, null);
        await db.close();
        if (await File(path).exists()) await File(path).delete();
        await dir.delete();
      }
    },
  );

  test(
    'clear releases processing only after native stop is confirmed',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'run-clear',
      });
      final stopped = Completer<void>();
      final cancelStarted = Completer<void>();
      final discards = NativeDiscardMemory();
      final item = DownloadItem(
        id: 'old',
        track: _track,
        service: '',
        createdAt: DateTime.utc(2026),
      );
      final snapshot = {
        'run_id': 'run-clear',
        'contract_version': 1,
        'is_running': true,
        'items': [
          {'item_id': 'old', 'status': 'queued'},
        ],
      };
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelNativeDownloadWorker') {
          if (!cancelStarted.isCompleted) cancelStarted.complete();
          await stopped.future;
        }
        if (call.method == 'isDownloadServiceRunning') return true;
        if (call.method == 'discardStoppedNativeDownloadWorkerItems')
          return true;
        if (call.method == 'getNativeDownloadWorkerSnapshot') {
          return {
            'run_id': 'run-clear',
            'contract_version': 1,
            'is_running': !stopped.isCompleted,
            'items': <Object?>[],
          };
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeSnapshotForTesting: () async => snapshot,
              nativeRequestJsonForTesting: (_) async => '{}',
              queuePersistenceForTesting: (items, error) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: error,
                    loadRows: () async => [
                      {
                        'id': item.id,
                        'item_json': encodeDownloadQueueItemForPersistence(
                          item,
                        ),
                        'status': 'queued',
                        'created_at': item.createdAt.toIso8601String(),
                        'updated_at': item.createdAt.toIso8601String(),
                      },
                    ],
                    loadSelectionEvents: () async => [],
                    applyNativeDiscardChanges: discards.apply,
                    loadNativeDiscardsFromStorage: discards.load,
                    ackNativeDiscardsInStorage: discards.ack,
                    applyChanges:
                        ({required upserts, required deletedIds}) async {},
                    applySelectionChanges:
                        ({
                          required upserts,
                          required deletedIds,
                          required selectionEvents,
                        }) async {},
                  ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      await _until(() => container.read(downloadQueueProvider).isProcessing);
      queue.clearAll();
      await cancelStarted.future;
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isTrue,
      );
      expect(container.read(downloadQueueProvider).isProcessing, isTrue);
      stopped.complete();
      await _until(
        () => !container.read(downloadQueueProvider).nativeRecoveryRequired,
      );
      expect(container.read(downloadQueueProvider).isProcessing, isFalse);
      expect(container.read(downloadQueueProvider).items, isEmpty);
    },
  );

  test(
    'non-transitive identities retain direct history across restore',
    () async {
      const a = Track(
        id: 'same',
        source: 'svc',
        name: 'A',
        artistName: 'A',
        albumName: 'A',
        duration: 1,
        isrc: 'X',
      );
      const c = Track(
        id: 'same',
        source: 'svc',
        name: 'C',
        artistName: 'A',
        albumName: 'A',
        duration: 1,
      );
      const b = Track(
        id: 'same',
        source: 'svc',
        name: 'B',
        artistName: 'A',
        albumName: 'A',
        duration: 1,
        isrc: 'Y',
      );
      final items = [
        for (final entry in [('a', a), ('c', c), ('b', b)])
          DownloadItem(
            id: entry.$1,
            track: entry.$2,
            service: '',
            createdAt: DateTime.utc(2026),
          ),
      ];
      final rows = <String, Map<String, dynamic>>{
        for (final item in items)
          item.id: {
            'id': item.id,
            'item_json': encodeDownloadQueueItemForPersistence(item),
            'status': 'queued',
            'created_at': item.createdAt.toIso8601String(),
            'updated_at': item.createdAt.toIso8601String(),
          },
      };
      final events = <Map<String, dynamic>>[
        for (final item in items)
          {
            'event_id': 'event-${item.id}',
            'request_id': item.id,
            'track_json': jsonEncode(item.track.toJson()),
          },
      ];
      Future<void> apply(
        List<Map<String, dynamic>> upserts,
        List<String> deleted,
      ) async {
        for (final id in deleted) {
          rows.remove(id);
        }
        for (final row in upserts) {
          rows[row['id'] as String] = row;
        }
      }

      ProviderContainer scope() => ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              queuePersistenceForTesting: (current, error) =>
                  DownloadQueuePersistence(
                    currentItems: current,
                    onError: error,
                    loadRows: () async => rows.values.toList(),
                    loadSelectionEvents: () async =>
                        events.map(Map<String, dynamic>.of).toList(),
                    applyChanges: ({required upserts, required deletedIds}) =>
                        apply(upserts, deletedIds),
                    applySelectionChanges:
                        ({
                          required upserts,
                          required deletedIds,
                          required selectionEvents,
                        }) async {
                          await apply(upserts, deletedIds);
                          events.addAll(selectionEvents);
                        },
                  ),
            ),
          ),
        ],
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.zarz.mornye/backend'),
            (call) async => null,
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('com.zarz.mornye/backend'),
              null,
            ),
      );
      final first = scope();
      final queue = first.read(downloadQueueProvider.notifier);
      queue.pauseQueue();
      await queue.flushQueuePersistence();
      expect(queue.isSelectedPermanentDownloadForTesting(items[0]), isFalse);
      expect(queue.isSelectedPermanentDownloadForTesting(items[1]), isFalse);
      expect(queue.isSelectedPermanentDownloadForTesting(items[2]), isTrue);
      queue.cancelItem('a');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, hasLength(3));
      queue.cancelItem('b');
      await _until(() => events.length == 4);
      expect(events.last['request_id'], isNull);
      await queue.flushQueuePersistence(requireDurable: true);
      first.dispose();
      final restored = scope();
      addTearDown(restored.dispose);
      final restoredQueue = restored.read(downloadQueueProvider.notifier);
      restoredQueue.pauseQueue();
      await restoredQueue.flushQueuePersistence();
      expect(
        restoredQueue.isSelectedPermanentDownloadForTesting(items[0]),
        isFalse,
      );
      expect(
        restoredQueue.isSelectedPermanentDownloadForTesting(items[2]),
        isFalse,
      );
      await restoredQueue.retryItem('a');
      await _until(() => events.length == 5);
      await _until(
        () => restoredQueue.isSelectedPermanentDownloadForTesting(items[0]),
      );
      expect(events.last['request_id'], 'a');
      expect(
        restoredQueue.isSelectedPermanentDownloadForTesting(items[2]),
        isFalse,
      );
    },
  );

  test('failed selection blocks later choice until explicit retry', () async {
    final db = await AppStateDatabase.openWithFactory(
      databaseFactoryFfi,
      inMemoryDatabasePath,
    );
    addTearDown(db.close);
    await db.execute("""
      CREATE TRIGGER fixture_fail_selection
      BEFORE INSERT ON download_queue_selection_events
      BEGIN SELECT RAISE(ABORT, 'selection-private-canary track_json'); END
    """);
    final store = AppStateDatabase.withDatabase(db);
    final gate = Completer<void>();
    final started = Completer<void>();
    final attempts = <List<Map<String, dynamic>>>[];
    final rows = <String, Map<String, dynamic>>{};
    var fail = true;
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadQueueProvider.overrideWith(
          () => DownloadQueueNotifier(
            queuePersistenceForTesting: (items, error) =>
                DownloadQueuePersistence(
                  currentItems: items,
                  onError: error,
                  loadRows: () async => [],
                  loadSelectionEvents: () async => [],
                  applyChanges:
                      ({required upserts, required deletedIds}) async {
                        for (final id in deletedIds) {
                          rows.remove(id);
                        }
                        for (final row in upserts) {
                          rows[row['id'] as String] = row;
                        }
                      },
                  applySelectionChanges:
                      ({
                        required upserts,
                        required deletedIds,
                        required selectionEvents,
                      }) async {
                        attempts.add(
                          selectionEvents.map(Map<String, dynamic>.of).toList(),
                        );
                        if (fail) {
                          if (!started.isCompleted) started.complete();
                          await gate.future;
                          await store.applyPendingDownloadQueueChanges(
                            upserts: upserts,
                            deletedIds: deletedIds,
                            selectionEvents: selectionEvents,
                          );
                        }
                        for (final id in deletedIds) {
                          rows.remove(id);
                        }
                        for (final row in upserts) {
                          rows[row['id'] as String] = row;
                        }
                      },
                ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.pauseQueue();
    final a = queue.addToQueue(_track, 'x', qualityOverride: 'HIGH');
    await started.future;
    final b = queue.addToQueue(_track, 'x', qualityOverride: 'LOSSLESS');
    gate.complete();
    await _until(
      () => container.read(downloadQueueProvider).selectionPersistenceBlocked,
    );
    expect(attempts, hasLength(1));
    expect(attempts.first.single['request_id'], a);
    expect(container.read(downloadQueueProvider).isProcessing, isFalse);
    await queue.retrySelectionPersistence();
    expect(container.read(downloadQueueProvider).selectionPersistenceBlocked, isTrue);
    final persistenceLogs = LogBuffer().entries.where(
      (entry) => entry.tag == 'DownloadQueue' &&
          (entry.message.contains('Failed to persist download selection') ||
              entry.message.contains('Failed to retry download selection')),
    );
    expect(persistenceLogs, hasLength(2));
    expect(persistenceLogs.every((entry) => entry.error == null), isTrue);
    expect(persistenceLogs.toString(), isNot(contains('selection-private-canary')));
    expect(persistenceLogs.toString(), isNot(contains('track_json')));

    fail = false;
    await queue.retrySelectionPersistence();
    expect(
      container.read(downloadQueueProvider).selectionPersistenceBlocked,
      isFalse,
    );
    expect(attempts, hasLength(4));
    expect(attempts[1].single['request_id'], a);
    expect(attempts[2].single['request_id'], a);
    expect(attempts[3].single['request_id'], b);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.zarz.mornye/backend'),
          (call) async => null,
        );
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('com.zarz.mornye/backend'),
            null,
          ),
    );
    queue.updateItemStatus(b, DownloadStatus.failed);
    await queue.retryItem(b);
    await _until(() => attempts.length == 5);
    expect(attempts.last.single['request_id'], b);
    expect(
      attempts.last.single['event_id'],
      isNot(attempts[3].single['event_id']),
    );
    expect(rows[b]?['status'], 'queued');
    await _until(
      () => queue.isSelectedPermanentDownloadForTesting(
        container
            .read(downloadQueueProvider)
            .items
            .firstWhere((item) => item.id == b),
      ),
    );
    queue.cancelItem(b);
    await _until(() => attempts.length == 6);
    expect(attempts.last.single['request_id'], isNull);
    await _until(
      () => !queue.isSelectedPermanentDownloadForTesting(
        container
            .read(downloadQueueProvider)
            .items
            .firstWhere((item) => item.id == a),
      ),
    );
  });

  test(
    'clear during restore does not revive hidden rows and keeps later addition',
    () async {
      final gate = Completer<void>();
      final reading = Completer<void>();
      final old = DownloadItem(
        id: 'old',
        track: _track,
        service: '',
        createdAt: DateTime.utc(2026),
      );
      final rows = <String, Map<String, dynamic>>{
        'old': {
          'id': 'old',
          'item_json': encodeDownloadQueueItemForPersistence(old),
          'status': 'queued',
          'created_at': old.createdAt.toIso8601String(),
          'updated_at': old.createdAt.toIso8601String(),
        },
      };
      final events = <Map<String, dynamic>>[];
      Future<void> apply(
        List<Map<String, dynamic>> upserts,
        List<String> deleted,
      ) async {
        for (final id in deleted) {
          rows.remove(id);
        }
        for (final row in upserts) {
          rows[row['id'] as String] = row;
        }
      }

      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              queuePersistenceForTesting: (items, error) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: error,
                    loadRows: () async {
                      reading.complete();
                      await gate.future;
                      return rows.values.toList();
                    },
                    loadSelectionEvents: () async => [
                      {
                        'event_id': 'old-event',
                        'request_id': 'old',
                        'track_json': jsonEncode(_track.toJson()),
                      },
                    ],
                    applyChanges: ({required upserts, required deletedIds}) =>
                        apply(upserts, deletedIds),
                    applySelectionChanges:
                        ({
                          required upserts,
                          required deletedIds,
                          required selectionEvents,
                        }) async {
                          await apply(upserts, deletedIds);
                          events.addAll(selectionEvents);
                        },
                  ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue();
      await reading.future;
      queue.clearAll();
      queue.pauseQueue();
      final added = queue.addToQueue(_track, 'x');
      gate.complete();
      await _until(() => events.length >= 2);
      await queue.flushQueuePersistence(requireDurable: true);
      expect(
        container.read(downloadQueueProvider).items.map((item) => item.id),
        [added],
      );
      expect(rows.keys, [added]);
      expect(events.map((event) => event['request_id']), [null, added]);
    },
  );

  test('selection clear selection retain gesture order and snapshots', () async {
    SharedPreferences.setMockInitialValues({
      'download_queue_native_worker_run_id': 'ordered-run',
    });
    final gate = Completer<void>();
    final reading = Completer<void>();
    final writes = <String>[];
    var failClear = true;
    final old = DownloadItem(
      id: 'hidden-old',
      track: _track,
      service: '',
      createdAt: DateTime.utc(2026),
    );
    final rows = <String, Map<String, dynamic>>{
      'hidden-old': {
        'id': old.id,
        'item_json': encodeDownloadQueueItemForPersistence(old),
        'status': 'queued',
        'created_at': old.createdAt.toIso8601String(),
        'updated_at': old.createdAt.toIso8601String(),
      },
    };
    Future<void> apply(
      List<Map<String, dynamic>> upserts,
      List<String> deleted,
    ) async {
      for (final id in deleted) {
        rows.remove(id);
      }
      for (final row in upserts) {
        rows[row['id'] as String] = row;
      }
    }

    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getNativeDownloadWorkerSnapshot')
        return {
          'run_id': 'ordered-run',
          'contract_version': 1,
          'is_running': false,
          'items': <Object?>[],
        };
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        downloadQueueProvider.overrideWith(
          () => DownloadQueueNotifier(
            isAndroidForTesting: true,
            nativeSnapshotForTesting: () async => {
              'run_id': 'ordered-run',
              'contract_version': 1,
              'is_running': false,
              'items': <Object?>[],
            },
            queuePersistenceForTesting: (items, error) => DownloadQueuePersistence(
              currentItems: items,
              onError: error,
              loadRows: () async {
                reading.complete();
                await gate.future;
                return rows.values.toList();
              },
              loadSelectionEvents: () async => [],
              applyChanges: ({required upserts, required deletedIds}) =>
                  apply(upserts, deletedIds),
              applySelectionChanges:
                  ({
                    required upserts,
                    required deletedIds,
                    required selectionEvents,
                  }) async {
                    await apply(upserts, deletedIds);
                    writes.add(
                      'select:${selectionEvents.single['request_id']}:${rows.keys.join(',')}',
                    );
                  },
              applyNativeDiscardChanges:
                  ({
                    required upserts,
                    required deletedIds,
                    required runId,
                    required requestIds,
                    required allRequests,
                  }) async {
                    if (failClear) throw StateError('discard write failed');
                    await apply(upserts, deletedIds);
                    writes.add(
                      'clear:$runId:$allRequests:${rows.keys.join(',')}',
                    );
                  },
              loadNativeDiscardsFromStorage: (_) async =>
                  (allRequests: false, requestIds: <String>{}),
              ackNativeDiscardsInStorage:
                  (_, {required requestIds, required allRequests}) async {},
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.pauseQueue();
    await reading.future;
    final a = queue.addToQueue(_track, 'x', qualityOverride: 'HIGH');
    queue.clearAll();
    queue.pauseQueue();
    final b = queue.addToQueue(_track, 'x', qualityOverride: 'LOSSLESS');
    gate.complete();
    await _until(
      () => container.read(downloadQueueProvider).selectionPersistenceBlocked,
    );
    expect(writes, ['select:$a:hidden-old,$a']);
    failClear = false;
    await queue.retrySelectionPersistence();
    await _until(() => writes.length >= 4);
    expect(writes[0], 'select:$a:hidden-old,$a');
    expect(writes[1], 'clear:ordered-run:true:');
    expect(writes[2], 'select:null:');
    expect(writes[3], 'select:$b:$b');
  });

  for (final explicitRemoval in [false, true]) {
    test(
      'completion cleanup during restoration (explicit removal: $explicitRemoval)',
      () async {
        final gate = Completer<void>();
        final reading = Completer<void>();
        final events = <Map<String, dynamic>>[];
        final ready = <String>[];
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            downloadQueueProvider.overrideWith(
              () => DownloadQueueNotifier(
                notifyReadyForTesting: (track, path) async {
                  ready.add(path);
                },
                queuePersistenceForTesting: (items, error) =>
                    DownloadQueuePersistence(
                      currentItems: items,
                      onError: error,
                      loadRows: () async => [],
                      loadSelectionEvents: () async {
                        reading.complete();
                        await gate.future;
                        return [
                          {
                            'event_id': 'old',
                            'request_id': 'old',
                            'track_json': jsonEncode(_track.toJson()),
                          },
                        ];
                      },
                      applyChanges:
                          ({required upserts, required deletedIds}) async {},
                      applySelectionChanges:
                          ({
                            required upserts,
                            required deletedIds,
                            required selectionEvents,
                          }) async {
                            events.addAll(selectionEvents);
                          },
                    ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue();
        await reading.future;
        final id = queue.addToQueue(_track, 'x');
        expect(container.read(downloadQueueProvider).items.single.id, id);
        queue.updateItemStatus(
          id,
          DownloadStatus.completed,
          filePath: '/ready.flac',
        );
        final completed = container.read(downloadQueueProvider).items.single;
        if (explicitRemoval) {
          queue.removeItem(id);
        } else {
          queue.removeCompletedItemForTesting(id);
        }
        expect(ready, isEmpty);
        gate.complete();
        await _until(() => events.isNotEmpty);
        await _until(() => events.any((event) => event['request_id'] == id));
        if (explicitRemoval) {
          await _until(
            () => events.any((event) => event['request_id'] == null),
          );
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(ready, isEmpty);
          expect(
            queue.isSelectedPermanentDownloadForTesting(completed),
            isFalse,
          );
        } else {
          await _until(() => ready.isNotEmpty);
          expect(ready, ['/ready.flac']);
          expect(
            queue.isSelectedPermanentDownloadForTesting(completed),
            isTrue,
          );
        }
      },
    );
  }
}
