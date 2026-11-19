import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
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

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<void> cancel({required int id}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeDiscardMemory discards;
  setUp(() { discards = NativeDiscardMemory(); });

  test(
    'clear during native snapshot adoption never restores the old item',
    () async {
      FlutterLocalNotificationsPlatform.instance = _Notifications();
      SharedPreferences.setMockInitialValues({
        'download_queue_native_worker_run_id': 'run-1',
        'download_queue_user_paused_v1': true,
      });
      final item = DownloadItem(
        id: 'old',
        track: const Track(
          id: 'old',
          name: 'Old',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
        service: '',
        createdAt: DateTime.utc(2026),
      );
      final entered = Completer<void>();
      final release = Completer<Map<String, dynamic>>();
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
              nativeSnapshotForTesting: () {
                entered.complete();
                return release.future;
              },
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
      final queue = container.read(downloadQueueProvider.notifier);
      await entered.future;
      queue.clearAll();
      release.complete({
        'run_id': 'run-1',
        'is_running': true,
        'item_ids': ['old'],
      });
      await queue.flushQueuePersistence();
      expect(container.read(downloadQueueProvider).items, isEmpty);
      container.dispose();
    },
  );
}
