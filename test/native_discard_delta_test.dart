import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final all in [false, true]) {
    for (final plural in [false, true]) {
      test('discard all=${all} plural=${plural}', () async {
        SharedPreferences.setMockInitialValues({
          'download_queue_native_worker_run_id': 'delta-run',
        });
        final item = DownloadItem(
          id: 'discarded',
          track: const Track(
            id: 'track',
            name: 'Track',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1,
          ),
          service: 'fixture',
          createdAt: DateTime.utc(2026),
        );
        final discards = NativeDiscardMemory();
        final pollEntered = Completer<void>();
        final nextPoll = Completer<void>();
        final deltaRelease = Completer<void>();
        var polls = 0;
        var nativeAcks = 0;
        var durableAcks = 0;
        var ready = 0;
        var publicationCalls = 0;
        final delta = {
          'item_id': item.id,
          'status': 'completed',
          'result': {
            'file_path': '/should-not-be-published.flac',
            'native_finalized': true,
          },
        };
        final initial = {
          'run_id': 'delta-run',
          'contract_version': 1,
          'is_running': true,
          'items': [
            {'item_id': item.id, 'status': 'queued'},
          ],
        };
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'isDownloadServiceRunning') return true;
          if (call.method == 'getNativeDownloadWorkerSnapshot') {
            polls++;
            if (polls == 1) {
              pollEntered.complete();
              await deltaRelease.future;
              return {
                'run_id': 'delta-run',
                'contract_version': 1,
                'is_running': true,
                if (plural) 'item_deltas': [delta] else 'item_delta': delta,
              };
            }
            if (!nextPoll.isCompleted) nextPoll.complete();
            return {
              'run_id': 'delta-run',
              'contract_version': 1,
              'is_running': true,
            };
          }
          if (call.method == 'acknowledgeNativeDownloadWorkerItems' ||
              call.method == 'discardStoppedNativeDownloadWorkerItems')
            nativeAcks++;
          if (call.method == 'readFileMetadata' ||
              call.method == 'scanLocalLibrary')
            publicationCalls++;
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
                nativeSnapshotForTesting: () async => initial,
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
                      ackNativeDiscardsInStorage:
                          (
                            runId, {
                            required requestIds,
                            required allRequests,
                          }) async {
                            durableAcks++;
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
        final notifier = container.read(downloadQueueProvider.notifier);
        await pollEntered.future.timeout(const Duration(seconds: 5));
        if (all) {
          // Simulate the durable clear committed by a prior gesture while the
          // native poll was in flight; this exercises the actual monitor path.
          await discards.apply(
            upserts: [],
            deletedIds: [],
            runId: 'delta-run',
            requestIds: {},
            allRequests: true,
          );
        } else {
          notifier.cancelItem(item.id);
          await notifier.flushQueuePersistence();
        }
        deltaRelease.complete();
        await nextPoll.future.timeout(const Duration(seconds: 5));
        expect(ready, 0);
        expect(container.exists(downloadHistoryProvider), isFalse);
        expect(publicationCalls, 0);
        expect(nativeAcks, 0);
        expect(durableAcks, 0);
        expect((await discards.load('delta-run')).allRequests, all);
        if (!all)
          expect(
            (await discards.load('delta-run')).requestIds,
            contains(item.id),
          );
        expect(
          (await SharedPreferences.getInstance()).getString(
            'download_queue_native_worker_run_id',
          ),
          'delta-run',
        );
        expect(
          container
              .read(downloadQueueProvider)
              .items
              .where((it) => it.status == DownloadStatus.completed),
          isEmpty,
        );
        container.dispose();
      });
    }
  }
}
