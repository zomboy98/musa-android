import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Run in an isolated checkout on a fresh x86_64 Android emulator (API 33+).
// With the repo's Android CI toolchain and $serial set to that emulator:
// export MORNYE_CATALOG_INTEGRATION=1 MORNYE_RUST_ANDROID_ABIS=x86_64
// export MORNYE_DISCORD_SDK=0 CARGO_BUILD_JOBS=2
// suite=integration_test/android_download_failure_diagnostics_test.dart
// flutter build apk --debug --target-platform android-x64 -t "$suite"
// adb -s "$serial" install -g -t build/app/outputs/flutter-apk/app-debug.apk
// flutter test --no-pub -d "$serial" "$suite"
// For repeats, start with a fresh AVD or uninstall only the dedicated package
// from that AVD after its process has stopped, then install with -g again.
const _package = 'org.musa.music.catalogintegration';
const _provider = 'diagnostics.fixture';
const _backendChannel = 'com.zarz.mornye/backend';
const _notificationChannel = 'dexterous.com/flutter/local_notifications';
const _codec = StandardMethodCodec();
const _canary = 'fixture-private-9e8146b28a6744b9';

const _cases = {
  'opaque': 'encrypted_validation_guard',
  'opus_320': 'strict_quality_mismatch',
};

// Same minimal FLAC stream used by the Rust strict-codec regression test.
const _flac =
    'ZkxhQwAAACISABIAAAAAACQVCsRA8AAAAAAAAAAAAAAAAAAAAAAAAAAAhAAALg0AAABMYXZmNjIu'
    'MTIuMTAwAQAAABUAAABlbmNvZGVyPUxhdmY2Mi4xMi4xMDD/+HkIAAG4VQAAAIxD';

Future<void> _writeProvider(Directory sources) async {
  final provider = await Directory(p.join(sources.path, _provider)).create();
  await File(p.join(provider.path, 'manifest.json')).writeAsString(
    jsonEncode({
      'name': _provider,
      'version': '1',
      'description': 'Local download diagnostics fixture',
      'type': ['download_provider'],
      'permissions': {'file': true},
      'skipMetadataEnrichment': true,
      'qualityOptions': [
        {'id': 'opaque', 'label': 'Opaque', 'kind': 'lossy'},
        {'id': 'opus_320', 'label': 'Opus 320 kbps', 'kind': 'lossy'},
      ],
    }),
  );
  await File(p.join(provider.path, 'index.js')).writeAsString('''
registerExtension({
  checkAvailability(id) { return { available: true, track_id: id }; },
  download(trackId, quality, outputPath) {
    if (quality === 'opaque') {
      file.writeBytes(outputPath, 'SUQzBAAAAAAA');
      return { success: true, file_path: outputPath,
               decryption_key: '$_canary', error_message: 'private: $_canary',
               fixture_note: { internal: ['$_canary'] } };
    }
    if (quality === 'opus_320') {
      file.writeBytes(outputPath, '$_flac');
      return { success: true, file_path: outputPath,
               actual_extension: '.mp3', audio_codec: 'opus' };
    }
    throw new Error('Unexpected fixture quality');
  }
});
''');
}

bool _containsCanary(Object? value) => switch (value) {
  final String text => text.contains(_canary),
  final ByteData bytes =>
    ascii
        .decode(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          allowInvalid: true,
        )
        .contains(_canary),
  final Map<Object?, Object?> map =>
    map.keys.any(_containsCanary) || map.values.any(_containsCanary),
  final Iterable<Object?> entries => entries.any(_containsCanary),
  _ => false,
};

// Observe the snapshots already read by the queue, including terminal rows
// that Kotlin may remove after the queue durably acknowledges them. The hooks
// forward requests and responses unchanged to the actual platform messenger.
class _PlatformObservation {
  final expectedCauses = <String, String>{};
  final failureTransitions = <String, int>{};
  final _lastStatuses = <String, String>{};
  String? runId;
  num _lastSnapshotSerial = 0;
  int workerStarts = 0;
  int foregroundDownloads = 0;
  int localNotificationShowOrScheduleCalls = 0;
  bool unexpectedNativeFailure = false;
  bool canaryInChannelTraffic = false;

  void _checkForCanary(Object? payload) {
    if (_containsCanary(payload)) canaryInChannelTraffic = true;
  }

  void install(TestDefaultBinaryMessenger messenger) {
    messenger.setMockMessageHandler(_backendChannel, (message) async {
      _checkForCanary(message);
      final method = _codec.decodeMethodCall(message!).method;
      if (method == 'startNativeDownloadWorker') workerStarts++;
      if (method == 'downloadByStrategy') foregroundDownloads++;
      final reply = await messenger.delegate.send(_backendChannel, message);
      _checkForCanary(reply);
      if (method == 'getNativeDownloadWorkerSnapshot' && reply != null) {
        try {
          final snapshot = jsonDecode(_codec.decodeEnvelope(reply) as String);
          _checkForCanary(snapshot);
          _observeSnapshot(snapshot as Map<String, dynamic>);
        } catch (_) {
          unexpectedNativeFailure = true;
        }
      }
      return reply;
    });
    messenger.setMockMessageHandler(_notificationChannel, (message) async {
      _checkForCanary(message);
      final method = _codec.decodeMethodCall(message!).method;
      if (method == 'show' || method == 'zonedSchedule') {
        localNotificationShowOrScheduleCalls++;
      }
      final reply = await messenger.delegate.send(
        _notificationChannel,
        message,
      );
      _checkForCanary(reply);
      return reply;
    });
    addTearDown(() {
      messenger.setMockMessageHandler(_backendChannel, null);
      messenger.setMockMessageHandler(_notificationChannel, null);
    });
  }

  void _observeSnapshot(Map<String, dynamic> snapshot) {
    final rows = [
      if (snapshot['items'] case final List<dynamic> items) ...items,
      if (snapshot['item_delta'] case final Map<String, dynamic> delta) delta,
      if (snapshot['item_deltas'] case final List<dynamic> deltas) ...deltas,
    ];
    final statuses = <String, String>{};
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      final id = row['item_id'];
      final status = row['status'];
      if (id is! String || status is! String) continue;
      final cause = expectedCauses[id];
      if (cause == null) continue;
      statuses[id] = status;
      if (status != 'failed') continue;
      final result = row['result'];
      final expected =
          result is Map<String, dynamic> &&
          result['success'] == false &&
          result['failure_stage'] == 'backend_download' &&
          result['error_type'] == 'quality_unavailable' &&
          result['diagnostic_cause'] == cause &&
          !result.containsKey('decryption') &&
          !result.containsKey('decryption_key');
      if (!expected) unexpectedNativeFailure = true;
    }
    if (statuses.isEmpty) return;
    final observedRunId = snapshot['run_id'];
    if (observedRunId is! String ||
        observedRunId.isEmpty ||
        (runId != null && runId != observedRunId)) {
      unexpectedNativeFailure = true;
      return;
    }
    runId = observedRunId;
    final serial = snapshot['snapshot_serial'];
    if (serial is! num || serial <= _lastSnapshotSerial) return;
    _lastSnapshotSerial = serial;
    // A failure can occur in several snapshots. Count state transitions in
    // their observed order instead of counting polling repetitions.
    for (final entry in statuses.entries) {
      final previous = _lastStatuses[entry.key];
      if (previous != 'failed' && entry.value == 'failed') {
        failureTransitions.update(
          entry.key,
          (count) => count + 1,
          ifAbsent: () => 1,
        );
      }
      _lastStatuses[entry.key] = entry.value;
    }
  }
}

void _expectOnlySafeFailures(List<dynamic> rows) {
  expect(
    _containsCanary(rows),
    isFalse,
    reason: 'BugLog contains fixture-private data',
  );
  final expected = {
    for (final cause in _cases.values)
      'stage_backend_download, error_type_quality_unavailable, cause_$cause',
  };
  final seen = <String>{};
  expect(rows.length, expected.length);
  for (final row in rows) {
    // Assert on a boolean so a failure never prints a potentially leaky row.
    expect(
      row is Map &&
          row.length == 4 &&
          row['category'] == 'download' &&
          row['type'] == 'TerminalDownloadFailure' &&
          row['time'] is String &&
          DateTime.tryParse(row['time'] as String)?.isUtc == true &&
          expected.contains(row['frames']) &&
          seen.add(row['frames'] as String),
      isTrue,
      reason:
          'Each BugLog row must contain only time and one distinct diagnostic',
    );
  }
}

Future<bool> _waitUntil(Future<bool> Function() probe) async {
  const deadline = Duration(seconds: 5);
  const probeTimeout = Duration(seconds: 2);
  const interval = Duration(milliseconds: 50);
  final wait = Stopwatch()..start();
  while (wait.elapsed < deadline) {
    final remaining = deadline - wait.elapsed;
    if (remaining <= Duration.zero) return false;
    try {
      if (await probe().timeout(
        remaining < probeTimeout ? remaining : probeTimeout,
      )) {
        return wait.elapsed <= deadline;
      }
    } on TimeoutException {
      // A missed reply is no evidence that the condition was met.
    }
    final delay = deadline - wait.elapsed;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay < interval ? delay : interval);
    }
  }
  return false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android worker preserves both strict quality diagnostics', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final cache = await getTemporaryDirectory();
    expect(
      p.split(cache.path).contains(_package),
      isTrue,
      reason: 'Use a fresh dedicated installation of the integration package.',
    );
    final observation = _PlatformObservation()
      ..install(binding.defaultBinaryMessenger);
    addTearDown(() {
      expect(
        observation.canaryInChannelTraffic,
        isFalse,
        reason:
            'The backend or notifications channel carried fixture-private data',
      );
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey(BugLog.key), isFalse);
    expect(await PlatformBridge.isDownloadServiceRunning(), isFalse);
    final initialSnapshot =
        await PlatformBridge.getNativeDownloadWorkerSnapshot();
    expect(
      initialSnapshot['run_id'] == '',
      isTrue,
      reason: 'Start with fresh app data',
    );

    final notifications = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    expect(
      await notifications.areNotificationsEnabled(),
      isTrue,
      reason: 'Grant POST_NOTIFICATIONS before running this suite.',
    );
    expect((await notifications.getActiveNotifications()).length, 0);
    expect((await notifications.pendingNotificationRequests()).length, 0);

    final root = await cache.createTemp('download-diagnostics-');
    var safeToClean = true;
    addTearDown(() async {
      if (safeToClean) await root.delete(recursive: true);
    });
    final output = await Directory(p.join(root.path, 'output')).create();
    final sources = await Directory(p.join(root.path, 'sources')).create();
    final data = await Directory(p.join(root.path, 'data')).create();
    await _writeProvider(sources);

    final container = ProviderContainer(
      overrides: [
        initialSettingsProvider.overrideWithValue(
          AppSettings(
            defaultService: _provider,
            downloadDirectory: output.path,
            folderOrganization: 'flat',
            separateSingles: false,
            filenameFormat: '{title}',
            singleFilenameFormat: '{title}',
            nativeDownloadWorkerEnabled: true,
            concurrentDownloads: 1,
            autoFallback: false,
            embedMetadata: false,
            embedLyrics: false,
            embedReplayGain: false,
            lyricsProviders: const [],
            motionArtworkEnabled: false,
          ),
        ),
      ],
    );
    addTearDown(() async {
      if (safeToClean) await PlatformBridge.cleanupExtensions();
    });
    addTearDown(container.dispose);
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['extensions'], 'rust');
    expect(implementations['downloads'], 'rust');
    final extensions = container.read(extensionProvider.notifier);
    await extensions.initialize(
      sources.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 1)),
    );
    await extensions.setExtensionEnabled(
      _provider,
      true,
      reconcilePreferences: false,
    );
    final extensionState = container.read(extensionProvider);
    expect(extensionState.isInitialized, isTrue);
    final provider = extensionState.extensions.single;
    expect(provider.enabled && provider.hasDownloadProvider, isTrue);
    expect(provider.qualityOptions.map((option) => option.id), _cases.keys);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.pauseQueue(persistAcrossRestarts: false);
    await queue.flushQueuePersistence(requireDurable: true);
    expect(container.read(downloadQueueProvider).items.length, 0);
    for (final entry in _cases.entries) {
      final id = queue.addToQueue(
        Track(
          id: '$_provider:${entry.key}',
          name: 'Synthetic title ${entry.key}',
          artistName: 'Synthetic artist',
          albumName: 'Synthetic album',
          source: _provider,
          duration: 1,
        ),
        _provider,
        qualityOverride: entry.key,
      );
      observation.expectedCauses[id] = entry.value;
    }
    await queue.flushQueuePersistence(requireDurable: true);

    final done = Completer<void>();
    final subscription = container.listen(downloadQueueProvider, (_, state) {
      if (!done.isCompleted &&
          !state.isProcessing &&
          state.failedCount == _cases.length) {
        done.complete();
      }
    });
    addTearDown(subscription.close);
    addTearDown(() async {
      if (safeToClean) return;
      try {
        queue.pauseQueue(persistAcrossRestarts: false);
        try {
          if (await PlatformBridge.isDownloadServiceRunning().timeout(
            const Duration(seconds: 2),
          )) {
            await PlatformBridge.cancelNativeDownloadWorker().timeout(
              const Duration(seconds: 2),
            );
          }
        } on TimeoutException {
          // Still ask the stopped store to confirm the exact run below.
        }
        final runId = observation.runId;
        if (runId != null &&
            observation.workerStarts == 1 &&
            observation.foregroundDownloads == 0) {
          // The service's running flag can clear before its jobs return.
          // This acknowledgement also checks for live jobs and pending starts.
          safeToClean = await _waitUntil(
            () => PlatformBridge.discardStoppedNativeDownloadWorkerItems(
              runId: runId,
              itemIds: observation.expectedCauses.keys.toList(),
              allRequests: false,
            ),
          );
        }
      } catch (_) {
        // Treat a failed or timed-out stop probe as unconfirmed.
      }
      expect(
        safeToClean,
        isTrue,
        reason: 'Worker stop unconfirmed; fixture staging retained',
      );
    });

    safeToClean = false;
    queue.resumeQueue();
    await done.future.timeout(const Duration(seconds: 60));
    await queue.flushQueuePersistence(requireDurable: true);
    final settled = container.read(downloadQueueProvider);
    expect(
      settled.items.map((item) => item.id),
      unorderedEquals(observation.expectedCauses.keys),
    );
    expect(
      settled.items.every((item) => item.status == DownloadStatus.failed),
      isTrue,
    );
    expect(settled.items.every((item) => item.filePath == null), isTrue);
    expect(settled.items.any((item) => _containsCanary(item.error)), isFalse);
    expect(settled.outputDir == output.path, isTrue);
    expect(await output.list(recursive: true).isEmpty, isTrue);

    expect(observation.workerStarts, 1);
    expect(observation.foregroundDownloads, 0);
    expect(observation.unexpectedNativeFailure, isFalse);
    expect(observation.failureTransitions.length, _cases.length);
    expect(
      observation.failureTransitions.values.every((count) => count == 1),
      isTrue,
    );

    // Android requires a foreground-service notification while the worker is
    // active, and can remove it after the service clears its running flag.
    // This does not record transient native notifications or collect logcat.
    expect(
      await _waitUntil(
        () async =>
            !await PlatformBridge.isDownloadServiceRunning() &&
            (await notifications.getActiveNotifications()).isEmpty &&
            (await notifications.pendingNotificationRequests()).isEmpty,
      ),
      isTrue,
      reason:
          'The stopped worker must leave no active or pending notifications',
    );
    expect(observation.localNotificationShowOrScheduleCalls, 0);

    _expectOnlySafeFailures(await BugLog.instance.entries());
    await prefs.reload();
    final raw = prefs.getString(BugLog.key);
    expect(raw != null, isTrue);
    expect(
      _containsCanary(raw),
      isFalse,
      reason: 'Persisted BugLog contains fixture-private data',
    );
    final List<dynamic> persisted;
    try {
      persisted = jsonDecode(raw!) as List<dynamic>;
    } catch (_) {
      fail('Persisted BugLog is not a JSON list');
    }
    _expectOnlySafeFailures(persisted);
  });
}
