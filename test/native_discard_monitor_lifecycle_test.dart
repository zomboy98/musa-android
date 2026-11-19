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
  test(
    'disposed adoption stops polling another live run without ACK or clear',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'owned-run',
      });
      final item = DownloadItem(
        id: 'item',
        track: const Track(
          id: 't',
          name: 'Track',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
        service: 'fixture',
        createdAt: DateTime.utc(2026),
      );
      final discards = NativeDiscardMemory();
      final otherSnapshotRequested = Completer<void>();
      final releaseSnapshot = Completer<void>();
      var snapshots = 0;
      var serviceChecks = 0;
      var acknowledgements = 0;
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isDownloadServiceRunning') {
          serviceChecks++;
          return true;
        }
        if (call.method == 'getNativeDownloadWorkerSnapshot') {
          snapshots++;
          if (!otherSnapshotRequested.isCompleted)
            otherSnapshotRequested.complete();
          await releaseSnapshot.future;
          return {
            'run_id': 'other-run',
            'contract_version': 1,
            'is_running': true,
          };
        }
        if (call.method == 'acknowledgeNativeDownloadWorkerItems' ||
            call.method == 'discardStoppedNativeDownloadWorkerItems')
          acknowledgements++;
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
              nativeSnapshotForTesting: () async => {
                'run_id': 'owned-run',
                'contract_version': 1,
                'is_running': true,
                'items': [
                  {'item_id': item.id, 'status': 'queued'},
                ],
              },
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
                    applyChanges:
                        ({required upserts, required deletedIds}) async {},
                    applySelectionChanges:
                        ({
                          required upserts,
                          required deletedIds,
                          required selectionEvents,
                        }) async {},
                    applyNativeDiscardChanges: discards.apply,
                    loadNativeDiscardsFromStorage: discards.load,
                    ackNativeDiscardsInStorage: discards.ack,
                  ),
            ),
          ),
        ],
      );
      container.read(downloadQueueProvider);
      await otherSnapshotRequested.future.timeout(const Duration(seconds: 5));
      final priorChecks = serviceChecks;
      container.dispose();
      releaseSnapshot.complete();
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(snapshots, 1);
      expect(serviceChecks, priorChecks);
      expect(acknowledgements, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'download_queue_native_worker_run_id',
        ),
        'owned-run',
      );
    },
  );
}
