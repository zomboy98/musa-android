import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications_platform_interface/flutter_local_notifications_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

class _Notifications extends FlutterLocalNotificationsPlatform {
  @override
  Future<void> cancel({required int id}) async {}
}

class _Extensions extends ExtensionNotifier {
  @override
  Future<void> ensureInitialized() async {}
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'fixture',
        name: 'fixture',
        displayName: 'Fixture',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeDiscardMemory discards;
  setUp(() { discards = NativeDiscardMemory(); });
  test(
    'prepared request cancelled behind durable selection is not appended',
    () async {
      FlutterLocalNotificationsPlatform.instance = _Notifications();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      SharedPreferences.setMockInitialValues({
        'download_queue_user_paused_v1': true,
      });
      final firstStarted = Completer<void>();
      final secondPreparing = Completer<void>();
      final releaseSecond = Completer<void>();
      final selectionStarted = Completer<void>();
      final selectionRelease = Completer<void>();
      final finishPreparing = Completer<void>();
      var blockSelections = false;
      var appended = 0;
      var runId = '';
      const channel = MethodChannel('com.zarz.mornye/backend');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(
        paths,
        (_) async => Directory.systemTemp.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'startNativeDownloadWorker') {
          final args = Map<Object?, Object?>.from(call.arguments as Map);
          final settings =
              jsonDecode(
                    await File(args['settings_path'] as String).readAsString(),
                  )
                  as Map<String, dynamic>;
          await File(args['settings_path'] as String).delete();
          await File(args['requests_path'] as String).delete();
          runId = settings['run_id'] as String;
          firstStarted.complete();
        }
        if (call.method == 'appendNativeDownloadWorkerRequests') appended++;
        if (call.method == 'finishNativeDownloadWorkerPreparation' &&
            !finishPreparing.isCompleted)
          finishPreparing.complete();
        if (call.method == 'isDownloadServiceRunning') return true;
        if (call.method == 'getNativeDownloadWorkerSnapshot')
          return {
            'run_id': runId,
            'contract_version': 1,
            'is_running': true,
            'items': <Object?>[],
          };
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              const AppSettings(
                downloadDirectory: '/fixture',
                nativeDownloadWorkerEnabled: true,
                useExtensionProviders: true,
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: true,
              nativeRequestJsonForTesting: (item) async {
                if (item.track.id == 'second') {
                  secondPreparing.complete();
                  await releaseSecond.future;
                }
                return '{}';
              },
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
                        }) async {
                          if (blockSelections) {
                            if (!selectionStarted.isCompleted)
                              selectionStarted.complete();
                            await selectionRelease.future;
                          }
                        },
                  ),
            ),
          ),
        ],
      );
      final notifier = container.read(downloadQueueProvider.notifier);
      await notifier.flushQueuePersistence();
      notifier.pauseQueue();
      const first = Track(
        id: 'first',
        name: 'First',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      const second = Track(
        id: 'second',
        name: 'Second',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      const later = Track(
        id: 'later',
        name: 'Later',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 1,
      );
      notifier.addToQueue(first, 'fixture');
      final secondId = notifier.addToQueue(second, 'fixture');
      await notifier.flushQueuePersistence();
      notifier.resumeQueue();
      await firstStarted.future.timeout(const Duration(seconds: 8));
      await secondPreparing.future.timeout(const Duration(seconds: 8));
      blockSelections = true;
      notifier.addToQueue(later, 'fixture');
      await selectionStarted.future.timeout(const Duration(seconds: 5));
      notifier.cancelItem(secondId);
      releaseSecond.complete();
      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(appended, 0);
      selectionRelease.complete();
      await finishPreparing.future.timeout(const Duration(seconds: 5));
      expect(appended, 0);
      container.dispose();
    },
  );
}
