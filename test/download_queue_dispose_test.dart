import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/services/download_keep_awake.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/utils/desktop_folders.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'support/fixed_settings.dart';
import 'support/native_discard_memory.dart';

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

class _KeepAwake implements DownloadKeepAwake {
  _KeepAwake(this.onBegin);

  final Future<void> Function() onBegin;
  final ended = Completer<void>();

  @override
  Future<void> begin() => onBegin();

  @override
  Future<void> end() async {
    if (!ended.isCompleted) ended.complete();
  }
}

class _InventoryStore extends InMemorySharedPreferencesStore {
  _InventoryStore(this.entered, this.release) : super.empty();

  final Completer<void> entered;
  final Future<void> release;

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    if (key == 'flutter.download_file_inventory_v1') {
      entered.complete();
      await release;
    }
    return super.setValue(type, key, value);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  for (final response in [
    'no challenge',
    'authenticated',
    'authenticated then challenge',
    'challenge resolved before launch',
    'network error before launch',
    'network error',
    'cancelled lookup',
  ]) {
    test('download verification lookup: $response', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugDesktopPlatformOverride = false;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugDesktopPlatformOverride = null;
      });
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      final fixtureDir = await Directory.systemTemp.createTemp(
        'queue-no-challenge-',
      );
      addTearDown(() => fixtureDir.delete(recursive: true));
      final messenger = binding.defaultBinaryMessenger;
      const backend = MethodChannel('com.zarz.mornye/backend');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
      const panel = MethodChannel('com.zarz.mornye/verification_panel');
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      messenger.setMockMethodCallHandler(paths, (_) async => fixtureDir.path);
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      var requests = 0;
      var challengeLookups = 0;
      final lookupStarted = Completer<void>();
      final releaseLookup = Completer<Map<String, Object?>>();
      final launched = Completer<String>();
      final panelReply = Completer<String>();
      final panelClosed = Completer<void>();
      const challengeUrl = 'https://example.invalid/challenge';
      messenger.setMockMethodCallHandler(urlLauncher, (call) async {
        if (call.method == 'launch' && !launched.isCompleted) {
          launched.complete(call.arguments['url'] as String);
        }
        return true;
      });
      messenger.setMockMethodCallHandler(panel, (call) async {
        if (call.method == 'open') {
          launched.complete((call.arguments as Map)['url'] as String);
          return panelReply.future;
        }
        if (call.method == 'close') {
          if (!panelReply.isCompleted) panelReply.complete('closed');
          if (!panelClosed.isCompleted) panelClosed.complete();
        }
        return null;
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'getProviderMetadata':
            return <String, Object?>{};
          case 'downloadByStrategy':
            requests++;
            if (response == 'challenge resolved before launch' &&
                requests > 1) {
              return {
                'success': false,
                'error_type': 'network',
                'error': 'Connection failed',
              };
            }
            return {
              'success': false,
              'error_type': 'verification_required',
              'error': 'Verification required',
              'service': 'fixture',
            };
          case 'getExtensionPendingAuth':
            challengeLookups++;
            if (!lookupStarted.isCompleted) lookupStarted.complete();
            if (response == 'authenticated') return {'authenticated': true};
            if (response == 'authenticated then challenge') {
              return challengeLookups == 1
                  ? {'authenticated': true}
                  : {'auth_url': challengeUrl};
            }
            if (response == 'challenge resolved before launch') {
              return challengeLookups == 1
                  ? {'auth_url': challengeUrl}
                  : {'authenticated': true};
            }
            if (response == 'network error before launch' &&
                challengeLookups == 1) {
              return {'auth_url': challengeUrl};
            }
            if (response.startsWith('network error')) {
              throw PlatformException(
                code: 'BACKEND_ERROR',
                message: 'connection reset',
              );
            }
            if (response == 'cancelled lookup') return releaseLookup.future;
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(backend, null);
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
        messenger.setMockMethodCallHandler(urlLauncher, null);
        messenger.setMockMethodCallHandler(panel, null);
        if (!panelReply.isCompleted) panelReply.complete('closed');
      });
      final discards = NativeDiscardMemory();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                downloadDirectory: fixtureDir.path,
                useExtensionProviders: true,
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
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
      addTearDown(container.dispose);
      final terminal = Completer<DownloadItem>();
      final idle = Completer<void>();
      var waitedForVerification = false;
      container.listen(downloadQueueProvider, (_, state) {
        if (lookupStarted.isCompleted &&
            !state.isProcessing &&
            !idle.isCompleted) {
          idle.complete();
        }
        for (final item in state.items) {
          if (item.error == 'Waiting for verification')
            waitedForVerification = true;
          if (item.status == DownloadStatus.failed && !terminal.isCompleted)
            terminal.complete(item);
        }
      });
      final notifier = container.read(downloadQueueProvider.notifier);
      await notifier.flushQueuePersistence();
      notifier.addToQueue(
        const Track(
          id: 'fixture',
          name: 'Fixture',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
        'fixture',
      );
      if (response == 'cancelled lookup') {
        await lookupStarted.future.timeout(const Duration(seconds: 8));
        notifier.cancelItem(
          container.read(downloadQueueProvider).items.single.id,
        );
        try {
          await idle.future.timeout(const Duration(seconds: 2));
        } finally {
          releaseLookup.complete({'auth_url': challengeUrl});
        }
        await Future<void>.delayed(Duration.zero);
      } else if (response == 'authenticated then challenge') {
        expect(
          await launched.future.timeout(const Duration(seconds: 8)),
          challengeUrl,
        );
        notifier.cancelItem(
          container.read(downloadQueueProvider).items.single.id,
        );
        await idle.future.timeout(const Duration(seconds: 2));
        await panelClosed.future.timeout(const Duration(seconds: 2));
      } else {
        final failed = await terminal.future.timeout(
          const Duration(seconds: 8),
        );
        expect(
          failed.errorType,
          response.startsWith('network error') ||
                  response == 'challenge resolved before launch'
              ? DownloadErrorType.network
              : DownloadErrorType.verificationRequired,
        );
      }
      final expectsChallenge = response == 'authenticated then challenge';
      final resolvedBeforeLaunch =
          response == 'challenge resolved before launch';
      final failedBeforeLaunch = response == 'network error before launch';
      final expectedAttempts =
          response.startsWith('authenticated') || resolvedBeforeLaunch ? 2 : 1;
      expect(requests, expectedAttempts);
      expect(
        challengeLookups,
        expectedAttempts + (expectsChallenge || failedBeforeLaunch ? 1 : 0),
      );
      expect(
        waitedForVerification,
        expectsChallenge || resolvedBeforeLaunch || failedBeforeLaunch,
      );
      expect(launched.isCompleted, expectsChallenge);
    });
  }
  for (final stage in [
    'processing',
    'preparation handoff failure',
    'preparation cancellation failure',
    'native completion inventory',
    'stopped native completion inventory',
    'native history fallback',
    'terminal',
    'error',
    'keep awake',
    'inline',
    'native metadata',
    'fallback folder',
    'initial folder',
  ]) {
    test('download queue may be disposed during $stage', () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      SharedPreferences.setMockInitialValues({});
      final discards = NativeDiscardMemory();
      final entered = Completer<void>();
      final release = Completer<void>();
      final cancelled = Completer<void>();
      final doubleFailure = stage == 'preparation cancellation failure';
      final handoffFailure =
          stage == 'preparation handoff failure' || doubleFailure;
      final inventoryRace = stage.endsWith('native completion inventory');
      final historyFallback = stage == 'native history fallback';
      final nativeCompletion = inventoryRace || historyFallback;
      var metadataReads = 0;
      final previousPrefsStore = SharedPreferencesStorePlatform.instance;
      final inventoryStore = _InventoryStore(entered, release.future);
      if (inventoryRace) {
        SharedPreferencesStorePlatform.instance = inventoryStore;
        addTearDown(
          () => SharedPreferencesStorePlatform.instance = previousPrefsStore,
        );
      }
      var acknowledgements = 0;
      final cleanupAfterCancellation = Completer<void>();
      final native = const {
        'processing',
        'preparation handoff failure',
        'preparation cancellation failure',
        'native completion inventory',
        'stopped native completion inventory',
        'native history fallback',
        'terminal',
        'error',
        'native metadata',
      }.contains(stage);
      final pathsBlocked =
          stage == 'fallback folder' || stage == 'initial folder';
      final fixtureDir = await Directory.systemTemp.createTemp(
        'queue-dispose-',
      );
      addTearDown(() => fixtureDir.delete(recursive: true));
      if (pathsBlocked) {
        final notADirectory = File('${fixtureDir.path}/file');
        await notADirectory.create();
        debugDesktopMusicDirectoryOverride = notADirectory.path;
        addTearDown(() => debugDesktopMusicDirectoryOverride = null);
      }
      final logged = <LogEntry>[];
      final previousLoggingEnabled = LogBuffer.loggingEnabled;
      final previousSink = LogBuffer.fileSink;
      LogBuffer.loggingEnabled = true;
      LogBuffer.fileSink = logged.add;
      addTearDown(() {
        LogBuffer.fileSink = previousSink;
        LogBuffer.loggingEnabled = previousLoggingEnabled;
      });
      final keepAwake = _KeepAwake(() async {
        if (stage == 'keep awake') {
          entered.complete();
          await release.future;
        }
      });
      debugDownloadKeepAwake = keepAwake;
      addTearDown(() => debugDownloadKeepAwake = null);
      var runId = '';
      var itemId = '';
      const backend = MethodChannel('com.zarz.mornye/backend');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const connectivityEvents = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      final messenger = binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
      messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
      messenger.setMockMethodCallHandler(paths, (_) async {
        if (pathsBlocked) {
          entered.complete();
          await release.future;
        }
        return fixtureDir.path;
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'getProviderMetadata':
            if (stage == 'native metadata') {
              entered.complete();
              await release.future;
            }
            return <String, Object?>{};
          case 'startNativeDownloadWorker':
            final args = call.arguments as Map;
            final settings = File(args['settings_path'] as String);
            final requests = File(args['requests_path'] as String);
            runId =
                (jsonDecode(await settings.readAsString()) as Map)['run_id']
                    as String;
            itemId =
                ((jsonDecode(await requests.readAsString()) as List).single
                        as Map)['item_id']
                    as String;
            await settings.delete();
            await requests.delete();
            if (stage == 'processing' || handoffFailure) {
              entered.complete();
              await release.future;
            }
            if (stage == 'error') {
              throw PlatformException(code: 'fixture-start-error');
            }
          case 'finishNativeDownloadWorkerPreparation':
            if (handoffFailure) {
              throw PlatformException(code: 'fixture-finish-error');
            }
          case 'cancelNativeDownloadWorker':
            if (handoffFailure) cancelled.complete();
            if (doubleFailure) {
              throw PlatformException(
                code: 'fixture-cancel-error',
                message: 'sensitive fixture details',
              );
            }
            if (stage == 'error') {
              entered.complete();
              await release.future;
              throw PlatformException(code: 'fixture-cancel-error');
            }
          case 'isDownloadServiceRunning':
            return true;
          case 'readFileMetadata':
            if (historyFallback && ++metadataReads == 1) {
              entered.complete();
              await release.future;
            }
            return <String, Object?>{};
          case 'getNativeDownloadWorkerSnapshot':
            final item = {
              'item_id': itemId,
              'status': nativeCompletion ? 'completed' : 'skipped',
              if (nativeCompletion)
                'result': {
                  'success': true,
                  'native_finalized': true,
                  'history_written': false,
                  'file_path': '${fixtureDir.path}/download.flac',
                },
            };
            return {
              'run_id': runId,
              'contract_version': 1,
              'is_running':
                  stage == 'native completion inventory' || historyFallback,
              'items': [item],
              'item_delta': item,
            };
          case 'downloadByStrategy':
            if (stage == 'inline') {
              entered.complete();
              await release.future;
            }
            return {
              'success': false,
              'error_type': stage == 'fallback folder'
                  ? 'permission'
                  : 'network',
              'error': stage == 'fallback folder'
                  ? 'Permission denied'
                  : 'offline',
            };
          case 'acknowledgeNativeDownloadWorkerItems':
            acknowledgements++;
          case 'cleanupConnections':
            if ((handoffFailure && cancelled.isCompleted) || nativeCompletion) {
              cleanupAfterCancellation.complete();
            }
            if (stage == 'terminal' && !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(backend, null);
        messenger.setMockMethodCallHandler(paths, null);
        messenger.setMockMethodCallHandler(connectivity, null);
        messenger.setMockMethodCallHandler(connectivityEvents, null);
      });
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                downloadDirectory: stage == 'initial folder'
                    ? ''
                    : fixtureDir.path,
                nativeDownloadWorkerEnabled: native,
                useExtensionProviders: true,
              ),
            ),
          ),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(
            () => DownloadQueueNotifier(
              isAndroidForTesting: native,
              nativeRequestJsonForTesting: stage == 'native metadata'
                  ? null
                  : (_) async => '{}',
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
      var disposed = false;
      addTearDown(() {
        if (!disposed) container.dispose();
        if (!release.isCompleted) release.complete();
      });
      final notifier = container.read(downloadQueueProvider.notifier);
      if (stage != 'initial folder') {
        await notifier.flushQueuePersistence();
        notifier.addToQueue(
          Track(
            id: stage == 'native metadata' ? 'deezer:42' : 'fixture',
            name: 'Fixture',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 1,
          ),
          'fixture',
        );
      }
      await entered.future.timeout(const Duration(seconds: 8));
      expect(
        container.read(downloadQueueProvider).isProcessing,
        !const {
          'terminal',
          'native metadata',
          'initial folder',
        }.contains(stage),
      );
      container.dispose();
      disposed = true;
      release.complete();
      if (handoffFailure || nativeCompletion) {
        await cleanupAfterCancellation.future.timeout(
          const Duration(seconds: 3),
        );
      }
      if (!native && stage != 'initial folder') {
        await keepAwake.ended.future.timeout(const Duration(seconds: 8));
      }
      // Run pending channel callbacks before the test finishes so an uncaught
      // provider lifecycle error is attributed to this scenario.
      await Future<void>.delayed(Duration.zero);
      expect(logged.where((entry) => entry.level == 'ERROR'), isEmpty);
      if (handoffFailure || nativeCompletion) {
        expect(acknowledgements, 0);
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('download_queue_native_worker_run_id'), runId);
      }
      if (inventoryRace) {
        final stored = await inventoryStore.getAll();
        final records =
            jsonDecode(stored['flutter.download_file_inventory_v1'] as String)
                as List;
        expect(records.single['path'], '${fixtureDir.path}/download.flac');
      }
      if (historyFallback) {
        expect(metadataReads, 1);
        final prefs = await SharedPreferences.getInstance();
        final records =
            jsonDecode(prefs.getString('download_file_inventory_v1')!) as List;
        expect(records.single['path'], '${fixtureDir.path}/download.flac');
      }
      if (doubleFailure) {
        expect(
          logged.map((entry) => entry.message),
          contains(
            contains(
              'Could not cancel native worker after preparation handoff failed',
            ),
          ),
        );
        expect(
          logged.map((entry) => entry.message),
          isNot(contains(contains('sensitive fixture details'))),
        );
      }
    });
  }
}
