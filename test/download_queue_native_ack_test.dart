import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeDiscardMemory discards;
  setUp(() {
    discards = NativeDiscardMemory();
  });
  for (final running in [true, false]) {
    test('native snapshot running=$running waits for durable retry', () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'run-ack',
        'download_queue_user_paused_v1': true,
      });
      final item = DownloadItem(
        id: 'ack-item',
        track: const Track(
          id: 'ack',
          name: 'Ack',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
        service: 'fixture',
        createdAt: DateTime.utc(2026),
      );
      final writeAttempt = Completer<void>();
      final acknowledged = Completer<void>();
      var allowWrite = false;
      var writes = 0;
      var acknowledgements = 0;
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isDownloadServiceRunning') return true;
        if (call.method == 'acknowledgeNativeDownloadWorkerItems') {
          acknowledgements++;
          if (!acknowledged.isCompleted) acknowledged.complete();
          return null;
        }
        if (call.method == 'getNativeDownloadWorkerSnapshot')
          return {
            'run_id': 'run-ack',
            'contract_version': 1,
            'is_running': false,
            'items': <Object?>[],
          };
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final snapshot = {
        'run_id': 'run-ack',
        'contract_version': 1,
        'is_running': running,
        'items': [
          {'item_id': item.id, 'status': 'skipped'},
        ],
      };
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(downloadDirectory: '/fixture'),
            ),
          ),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeSnapshotForTesting: () async => snapshot,
              nativeRequestJsonForTesting: (_) async => '{}',
              queuePersistenceForTesting: (items, onError) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: onError,
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
                        ({required upserts, required deletedIds}) async {
                          writes++;
                          if (!writeAttempt.isCompleted)
                            writeAttempt.complete();
                          if (!allowWrite) throw StateError('disk unavailable');
                        },
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
      container.read(downloadQueueProvider);
      await writeAttempt.future.timeout(const Duration(seconds: 5));
      expect(acknowledgements, 0);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('download_queue_native_worker_run_id'), 'run-ack');
      allowWrite = true;
      if (running) {
        await acknowledged.future.timeout(const Duration(seconds: 5));
      } else {
        for (
          var i = 0;
          i < 400 &&
              prefs.getString('download_queue_native_worker_run_id') != null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(prefs.getString('download_queue_native_worker_run_id'), isNull);
      }
      expect(writes, greaterThanOrEqualTo(2));
      expect(acknowledgements, running ? 1 : 0);
      container.dispose();
    });
  }

  test(
    'unconfirmed cancellation preserves recovery state and ownership',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'uncertain',
      });
      final cancelAttempt = Completer<void>();
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'cancelNativeDownloadWorker') {
          cancelAttempt.complete();
          throw PlatformException(code: 'unavailable');
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(downloadDirectory: '/fixture'),
            ),
          ),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              queuePersistenceForTesting: (items, onError) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: onError,
                    loadRows: () async => [],
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
      final notifier = container.read(downloadQueueProvider.notifier);
      for (
        var i = 0;
        i < 200 &&
            !container.read(downloadQueueProvider).nativeRecoveryRequired;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isTrue,
      );
      notifier.resumeQueue();
      await cancelAttempt.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(Duration.zero);
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isTrue,
      );
      expect(container.read(downloadQueueProvider).isPaused, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'download_queue_native_worker_run_id',
        ),
        'uncertain',
      );
      container.dispose();
    },
  );

  test(
    'confirmed cancellation reconciles final item before releasing ownership',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'recover',
      });
      final item = DownloadItem(
        id: 'recover-item',
        track: const Track(
          id: 'recover',
          name: 'Recover',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
        service: 'fixture',
        createdAt: DateTime.utc(2026),
      );
      final finalSnapshot = {
        'run_id': 'recover',
        'contract_version': 1,
        'is_running': false,
        'items': [
          {'item_id': item.id, 'status': 'skipped'},
        ],
      };
      var initialReads = 0;
      var committed = false;
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getNativeDownloadWorkerSnapshot')
          return finalSnapshot;
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(downloadDirectory: '/fixture'),
            ),
          ),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeSnapshotForTesting: () async =>
                  ++initialReads == 1 ? <String, dynamic>{} : finalSnapshot,
              nativeRequestJsonForTesting: (_) async => '{}',
              queuePersistenceForTesting: (items, onError) =>
                  DownloadQueuePersistence(
                    currentItems: items,
                    onError: onError,
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
                        ({required upserts, required deletedIds}) async {
                          if (!writeEntered.isCompleted)
                            writeEntered.complete();
                          await releaseWrite.future;
                          committed = true;
                        },
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
      final notifier = container.read(downloadQueueProvider.notifier);
      for (
        var i = 0;
        i < 200 &&
            !container.read(downloadQueueProvider).nativeRecoveryRequired;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isTrue,
      );
      notifier.resumeQueue();
      await writeEntered.future.timeout(const Duration(seconds: 5));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('download_queue_native_worker_run_id'), 'recover');
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isTrue,
      );
      releaseWrite.complete();
      for (
        var i = 0;
        i < 200 && container.read(downloadQueueProvider).nativeRecoveryRequired;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(committed, isTrue);
      expect(prefs.getString('download_queue_native_worker_run_id'), isNull);
      expect(
        container.read(downloadQueueProvider).nativeRecoveryRequired,
        isFalse,
      );
      expect(
        container.read(downloadQueueProvider).items.single.status,
        DownloadStatus.skipped,
      );
      container.dispose();
    },
  );
}
