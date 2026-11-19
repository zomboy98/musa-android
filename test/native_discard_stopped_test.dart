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
  for (final all in [false, true]) {
    test(
      'stopped discard retries durable ACK across restart, all=' +
          all.toString(),
      () async {
        SharedPreferences.setMockInitialValues({
          'download_queue_native_worker_run_id': 'old-run',
          'download_queue_user_paused_v1': true,
        });
        final discards = NativeDiscardMemory();
        await discards.apply(
          upserts: [],
          deletedIds: [],
          runId: 'old-run',
          requestIds: all ? {} : {'old'},
          allRequests: all,
        );
        await discards.apply(
          upserts: [],
          deletedIds: [],
          runId: 'other-run',
          requestIds: {'other'},
          allRequests: false,
        );
        final item = DownloadItem(
          id: 'new',
          track: const Track(
            id: 'new-track',
            name: 'New',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1,
          ),
          service: 'fixture',
          createdAt: DateTime.utc(2026),
        );
        final snapshot = {
          'run_id': 'old-run',
          'contract_version': 1,
          'is_running': false,
          'items': [
            {
              'item_id': 'old',
              'status': 'completed',
              'result': {'file_path': '/old.flac', 'native_finalized': true},
            },
          ],
        };
        final calls = <String>[];
        var rejectAck = true;
        var ready = 0;
        final arguments = <Map<dynamic, dynamic>>[];
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'discardStoppedNativeDownloadWorkerItems') {
            calls.add('native');
            arguments.add(Map<dynamic, dynamic>.from(call.arguments as Map));
            return true;
          }
          if (call.method == 'acknowledgeNativeDownloadWorkerItems')
            fail('legacy ACK must not discard a stopped snapshot');
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
        ProviderContainer makeContainer() => ProviderContainer(
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
                          ({required upserts, required deletedIds}) async {
                            calls.add('queue');
                          },
                      applySelectionChanges:
                          ({
                            required upserts,
                            required deletedIds,
                            required selectionEvents,
                          }) async {},
                      applyNativeDiscardChanges: discards.apply,
                      loadNativeDiscardsFromStorage: discards.load,
                      ackNativeDiscardsInStorage:
                          (
                            runId, {
                            required requestIds,
                            required allRequests,
                          }) async {
                            calls.add('ack');
                            if (rejectAck)
                              throw StateError('storage unavailable');
                            await discards.ack(
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
        var container = makeContainer();
        container.read(downloadQueueProvider);
        for (
          var i = 0;
          i < 300 &&
              !container.read(downloadQueueProvider).nativeRecoveryRequired;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(
          container.read(downloadQueueProvider).nativeRecoveryRequired,
          isTrue,
        );
        expect(calls, containsAllInOrder(['native', 'ack']));
        expect(
          (await SharedPreferences.getInstance()).getString(
            'download_queue_native_worker_run_id',
          ),
          'old-run',
        );
        expect((await discards.load('old-run')).allRequests, all);
        if (!all)
          expect((await discards.load('old-run')).requestIds, contains('old'));
        container.dispose();
        rejectAck = false;
        container = makeContainer();
        container.read(downloadQueueProvider);
        final prefs = await SharedPreferences.getInstance();
        for (
          var i = 0;
          i < 300 &&
              prefs.getString('download_queue_native_worker_run_id') != null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(prefs.getString('download_queue_native_worker_run_id'), isNull);
        expect(arguments.length, 2);
        for (final args in arguments) {
          expect(args['run_id'], 'old-run');
          expect(args['all_requests'], all);
          expect(args['item_ids'], all ? isEmpty : ['old']);
        }
        final pending = await discards.load('old-run');
        expect(pending.allRequests, isFalse);
        expect(pending.requestIds, isEmpty);
        expect((await discards.load('other-run')).requestIds, {'other'});
        expect(
          container.read(downloadQueueProvider).items.map((e) => e.id),
          contains('new'),
        );
        expect(ready, 0);
        container.dispose();
      },
    );
  }
}
