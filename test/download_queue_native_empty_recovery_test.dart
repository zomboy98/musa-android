import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
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
  for (final clear in [false, true]) {
    test(
      'stopped snapshot ${clear ? 'after clear' : 'empty'} releases ownership',
      () async {
        FlutterLocalNotificationsPlatform.instance = _Notifications();
        SharedPreferences.setMockInitialValues({
          'download_queue_native_worker_run_id': 'empty-run',
        });
        final item = DownloadItem(
          id: 'discard',
          track: const Track(
            id: 'discard',
            name: 'Discard',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1,
          ),
          service: 'fixture',
          createdAt: DateTime.utc(2026),
        );
        final finalSnapshot = {
          'run_id': 'empty-run',
          'contract_version': 1,
          'is_running': false,
          'items': clear
              ? [
                  {'item_id': item.id, 'status': 'completed'},
                ]
              : <Object?>[],
        };
        var ackCount = 0;
        final discards = NativeDiscardMemory();
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getNativeDownloadWorkerSnapshot')
            return finalSnapshot;
          if (call.method == 'acknowledgeNativeDownloadWorkerItems') ackCount++;
          if (call.method == 'discardStoppedNativeDownloadWorkerItems') {
            finalSnapshot['items'] = <Object?>[];
            return true;
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
                nativeSnapshotForTesting: () async => {},
                queuePersistenceForTesting: (items, onError) =>
                    DownloadQueuePersistence(
                      currentItems: items,
                      onError: onError,
                      loadRows: () async => clear
                          ? [
                              {
                                'id': item.id,
                                'item_json':
                                    encodeDownloadQueueItemForPersistence(item),
                                'status': 'queued',
                                'created_at': item.createdAt.toIso8601String(),
                                'updated_at': item.createdAt.toIso8601String(),
                              },
                            ]
                          : [],
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
        if (clear) notifier.clearAll();
        notifier.resumeQueue();
        for (
          var i = 0;
          i < 300 &&
              container.read(downloadQueueProvider).nativeRecoveryRequired;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          container.read(downloadQueueProvider).nativeRecoveryRequired,
          isFalse,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'download_queue_native_worker_run_id',
          ),
          isNull,
        );
        expect(ackCount, 0);
        expect(container.read(downloadQueueProvider).items, isEmpty);
        container.dispose();
      },
    );
  }
}
