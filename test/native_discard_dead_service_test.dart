import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final form in ['initial', 'poll']) {
    test('dead service retains unknown result during $form', () async {
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
      final known = {
        'item_id': 'known',
        'status': 'completed',
        'result': {'file_path': '/known.flac', 'native_finalized': true},
      };
      final unknown = {
        'item_id': 'unknown',
        'status': 'completed',
        'result': {'file_path': '/unknown.flac', 'native_finalized': true},
      };
      final snapshot = <String, dynamic>{
        'run_id': 'mixed-run',
        'contract_version': 1,
        'is_running': true,
        'items': [known, unknown],
      };
      final discards = NativeDiscardMemory();
      var ready = 0;
      var acks = 0;
      var serviceChecks = 0;
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isDownloadServiceRunning') {
          serviceChecks++;
          return form == 'poll' && serviceChecks == 1;
        }
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
              nativeSnapshotForTesting: () async => snapshot,
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
      final inventory =
          jsonDecode(prefs.getString('download_file_inventory_v1')!) as List;
      expect(
        inventory.where((row) => row['path'] == '/known.flac'),
        hasLength(1),
      );
      expect(inventory.where((row) => row['path'] == '/unknown.flac'), isEmpty);
      expect(container.exists(downloadHistoryProvider), isFalse);
      expect(ready, 0);
      expect(acks, form == 'poll' ? 1 : 0);
      container.dispose();
    });
  }
}
