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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'ledger read failure preserves run ownership and requires recovery',
    () async {
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'run-recovery',
      });
      final item = DownloadItem(
        id: 'keep',
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
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startNativeDownloadWorker') starts++;
        if (call.method == 'isDownloadServiceRunning') return true;
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
                'run_id': 'run-recovery',
                'contract_version': 1,
                'is_running': true,
                'items': [
                  {'item_id': 'keep', 'status': 'queued'},
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
                    loadNativeDiscardsFromStorage: (_) async =>
                        throw StateError('database unavailable'),
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
      container.read(downloadQueueProvider);
      for (
        var i = 0;
        i < 300 &&
            !container.read(downloadQueueProvider).nativeRecoveryRequired;
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      final state = container.read(downloadQueueProvider);
      expect(state.nativeRecoveryRequired, isTrue);
      expect(state.isPaused, isTrue);
      expect(starts, 0);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'download_queue_native_worker_run_id',
        ),
        'run-recovery',
      );
      container.dispose();
    },
  );
}
