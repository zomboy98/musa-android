import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final form in ['initial', 'poll']) {
    for (final invalid in ['missing', 'null', 'string']) {
      test('invalid running $invalid retains ownership during $form', () async {
        SharedPreferences.setMockInitialValues({
          'download_queue_native_worker_run_id': 'mixed-run',
        });
        final item = DownloadItem(
          id: 'known',
          track: const Track(
            id: 'known-track',
            name: 'Known',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1,
          ),
          service: 'fixture',
          createdAt: DateTime.utc(2026),
        );
        final known = {'item_id': 'known', 'status': 'downloading'};
        final snapshot = <String, dynamic>{
          'run_id': 'mixed-run',
          'contract_version': 1,
          if (invalid != 'missing')
            'is_running': invalid == 'null' ? null : 'false',
          'items': [known],
        };
        final initialSnapshot = form == 'poll'
            ? {...snapshot, 'is_running': true}
            : snapshot;
        final discards = NativeDiscardMemory();
        var ready = 0;
        var acks = 0;
        var serviceChecks = 0;
        var starts = 0;
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isDownloadServiceRunning') {
            serviceChecks++;
            return true;
          }
          if (call.method == 'startNativeDownloadWorker') starts++;
          if (call.method == 'getNativeDownloadWorkerSnapshot') return snapshot;
          if (call.method == 'acknowledgeNativeDownloadWorkerItems' ||
              call.method == 'discardStoppedNativeDownloadWorkerItems') {
            expect(call.arguments.toString(), isNot(contains('unknown')));
            acks++;
          }
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                const AppSettings(
                  downloadDirectory: '/fixture',
                  saveDownloadHistory: false,
                ),
              ),
            ),
            downloadQueueProvider.overrideWith(
              () => DownloadQueueNotifier(
                isAndroidForTesting: true,
                nativeSnapshotForTesting: () async => initialSnapshot,
                nativeRequestJsonForTesting: (_) async => '{}',
                notifyReadyForTesting: (_, __) async {
                  ready++;
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
        for (
          var i = 0;
          i < 700 &&
              !container.read(downloadQueueProvider).nativeRecoveryRequired;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        final state = container.read(downloadQueueProvider);
        expect(state.nativeRecoveryRequired, isTrue);
        expect(state.isPaused, isTrue);
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('download_queue_native_worker_run_id'),
          'mixed-run',
        );
        expect(state.items.single.id, 'known');
        expect(state.items.single.status, isNot(DownloadStatus.completed));
        expect(ready, 0);
        expect(acks, 0);
        expect(starts, 0);
        container.dispose();
      });
    }
  }
}
