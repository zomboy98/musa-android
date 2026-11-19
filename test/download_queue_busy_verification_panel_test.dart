import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/download_queue_persistence.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// A manual download of provider B must not fail just because a search keeps
/// provider A's verification panel open (native answers `busy`). The queue
/// waits for that panel's real end, then opens its own challenge once; it
/// never polls, and opens nothing after cancellation or for an unknown holder.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const panel = MethodChannel('com.zarz.mornye/verification_panel');
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const urlLauncher = MethodChannel('plugins.flutter.io/url_launcher');
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const connectivityEvents = MethodChannel(
    'dev.fluttercommunity.plus/connectivity_status',
  );
  const shortWait = Duration(seconds: 8);

  late Directory fixtureDir;
  late List<String> openedUrls;
  late int downloadRequests;
  // Reply of the search panel (provider A); null when no search is running.
  Completer<Object?>? searchPanelReply;
  late Completer<void> searchPanelOpened;
  late Completer<void> downloadPanelBusy;
  late Completer<void> downloadPanelShown;
  // When set, queue persistence blocks until released (simulates a slow flush).
  Completer<void>? persistGate;
  late Completer<void> persistEntered;

  setUp(() async {
    persistGate = null;
    persistEntered = Completer<void>();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDesktopPlatformOverride = false;
    SharedPreferences.setMockInitialValues({});
    fixtureDir = await Directory.systemTemp.createTemp('queue-busy-panel-');
    openedUrls = [];
    downloadRequests = 0;
    searchPanelReply = null;
    searchPanelOpened = Completer<void>();
    downloadPanelBusy = Completer<void>();
    downloadPanelShown = Completer<void>();
    final messenger = binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => fixtureDir.path);
    messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
    messenger.setMockMethodCallHandler(connectivityEvents, (_) async => null);
    messenger.setMockMethodCallHandler(urlLauncher, (_) async {
      fail('Embedded verification must never open a browser');
    });
    messenger.setMockMethodCallHandler(backend, (call) async {
      switch (call.method) {
        case 'getProviderMetadata':
          return <String, Object?>{};
        case 'downloadByStrategy':
          downloadRequests++;
          return {
            'success': false,
            'error_type': 'verification_required',
            'error': 'Verification required',
            'service': 'fixture',
          };
        case 'getExtensionPendingAuth':
          final id = (call.arguments as Map)['extension_id'] as String;
          return {'auth_url': 'https://example.invalid/verify?ext=$id'};
      }
      return null;
    });
    messenger.setMockMethodCallHandler(panel, (call) async {
      if (call.method != 'open') return null;
      final url = (call.arguments as Map)['url'] as String;
      openedUrls.add(url);
      final search = searchPanelReply;
      if (url.endsWith('ext=search-provider')) {
        searchPanelOpened.complete();
        return search!.future;
      }
      // Native keeps one pending request: busy while the search panel is open.
      if (search == null || !search.isCompleted) {
        if (!downloadPanelBusy.isCompleted) downloadPanelBusy.complete();
        return 'busy';
      }
      // The download's own panel is shown; the user dismisses it.
      if (!downloadPanelShown.isCompleted) downloadPanelShown.complete();
      return 'closed';
    });
  });

  tearDown(() async {
    final search = searchPanelReply;
    if (search != null && !search.isCompleted) search.complete('closed');
    final messenger = binding.defaultBinaryMessenger;
    for (final channel in [
      backend,
      panel,
      paths,
      urlLauncher,
      connectivity,
      connectivityEvents,
    ]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    await fixtureDir.delete(recursive: true);
  });

  ProviderContainer createContainer() {
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
                  applyChanges: ({required upserts, required deletedIds}) async {
                    final gate = persistGate;
                    if (gate == null) return;
                    if (!persistEntered.isCompleted) persistEntered.complete();
                    await gate.future;
                  },
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
    return container;
  }

  Future<DownloadQueueNotifier> enqueue(ProviderContainer container) async {
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
    return notifier;
  }

  Future<DownloadItem> failedItem(ProviderContainer container) {
    final failed = Completer<DownloadItem>();
    container.listen(downloadQueueProvider, (_, state) {
      for (final item in state.items) {
        if (item.status == DownloadStatus.failed && !failed.isCompleted) {
          failed.complete(item);
        }
      }
    }, fireImmediately: true);
    return failed.future.timeout(shortWait);
  }

  /// Opens provider A's panel the way a search verification does.
  Future<ExtensionVerificationResult> startSearchVerification() async {
    searchPanelReply = Completer<Object?>();
    final result = resolveExtensionVerification(
      'search-provider',
      browserMode: 'in_app_first',
      quietUnavailable: true,
    );
    await searchPanelOpened.future.timeout(shortWait);
    return result;
  }

  List<String> downloadPanelOpens() =>
      openedUrls.where((url) => url.endsWith('ext=fixture')).toList();

  test('waits for the search panel to end, then opens its own', () async {
    final search = startSearchVerification();
    final container = createContainer();
    final failed = failedItem(container);
    await enqueue(container);

    await downloadPanelBusy.future.timeout(shortWait);
    // Waiting is event driven: nothing else is opened while A is visible.
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(downloadPanelOpens(), hasLength(1));
    expect(
      container.read(downloadQueueProvider).items.single.status,
      isNot(DownloadStatus.failed),
      reason: 'busy must not be a terminal failure while A can still end',
    );

    searchPanelReply!.complete('closed');
    expect((await search.timeout(shortWait)).interactionShown, isTrue);
    await downloadPanelShown.future.timeout(shortWait);

    final item = await failed;
    expect(item.errorType, DownloadErrorType.verificationRequired);
    expect(
      downloadPanelOpens(),
      hasLength(2),
      reason: 'one busy reply, then exactly one real challenge; closing it '
          'never launches another one',
    );
    expect(downloadRequests, 1);
  });

  test('cancelling while waiting opens no further challenge', () async {
    final search = startSearchVerification();
    final container = createContainer();
    final notifier = await enqueue(container);

    await downloadPanelBusy.future.timeout(shortWait);
    notifier.cancelItem(container.read(downloadQueueProvider).items.single.id);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    searchPanelReply!.complete('closed');
    await search.timeout(shortWait);
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(downloadPanelOpens(), hasLength(1));
    expect(downloadPanelShown.isCompleted, isFalse);
    expect(
      container.read(downloadQueueProvider).items.where(
        (item) => item.status == DownloadStatus.failed,
      ),
      isEmpty,
    );
  });

  test('backgrounding during the persistence flush opens no panel until '
      'the app resumes', () async {
    final container = createContainer();
    final notifier = container.read(downloadQueueProvider.notifier);
    await notifier.flushQueuePersistence();
    // Block durable writes only once the queue is set up, so the flush inside
    // the verification flow is the one left pending.
    persistGate = Completer<void>();
    // No other panel occupies the native slot in this scenario.
    searchPanelReply = Completer<Object?>()..complete('closed');
    final failed = failedItem(container);
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

    await persistEntered.future.timeout(shortWait);
    expect(downloadPanelOpens(), isEmpty);

    // The app goes to the background while the flush is still pending.
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    persistGate!.complete();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(
      downloadPanelOpens(),
      isEmpty,
      reason: 'the panel must not launch while the app is in the background',
    );

    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final item = await failed;
    expect(item.errorType, DownloadErrorType.verificationRequired);
    expect(downloadPanelOpens(), hasLength(1));
  });

  test('busy from an unknown holder fails without waiting', () async {
    // No panel request of this isolate holds the native slot, so there is no
    // termination signal: the download fails as before instead of waiting.
    final container = createContainer();
    final failed = failedItem(container);
    await enqueue(container);

    final item = await failed;
    expect(item.errorType, DownloadErrorType.verificationRequired);
    expect(downloadPanelOpens(), hasLength(1));
    expect(downloadPanelShown.isCompleted, isFalse);
  });
}
