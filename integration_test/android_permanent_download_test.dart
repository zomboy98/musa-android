import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
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
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/ffmpeg_support.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Use the fresh x86_64 Android integration installation and toolchain described
// in android_download_failure_diagnostics_test.dart, substituting this target.
// The default case tests the app's Opus conversion settings. For the FLAC case,
// add --dart-define=MORNYE_PERMANENT_DOWNLOAD_CASE=flac to both the APK build
// and the flutter test command. A prebuilt APK must already contain the flag.
// Use MORNYE_PERMANENT_DOWNLOAD_CASE=selector for the saved-quality regression.
// Start with fresh dedicated app data for each case.
const _downloadCase = String.fromEnvironment(
  'MORNYE_PERMANENT_DOWNLOAD_CASE',
  defaultValue: 'opus',
);
const _package = 'org.musa.music.catalogintegration';
const _provider = 'permanent.fixture';
const _quality = 'LOSSLESS';
const _legacyQuality = ' lossless ';
const _backend = 'com.zarz.mornye/backend';
const _codec = StandardMethodCodec();
const _track = Track(
  id: '$_provider:fixture-tone',
  name: 'Synthetic tone',
  artistName: 'Synthetic artist',
  albumName: 'Synthetic album',
  source: _provider,
  duration: 1,
);

Future<void> _writeProvider(Directory sources, int port) async {
  final provider = await Directory(p.join(sources.path, _provider)).create();
  await File(p.join(provider.path, 'manifest.json')).writeAsString(
    jsonEncode({
      'name': _provider,
      'version': '1',
      'description': 'Synthetic loopback FLAC download fixture',
      'type': ['download_provider'],
      'permissions': {
        'network': ['127.0.0.1'],
        'allowHttp': true,
        'file': true,
      },
      'skipMetadataEnrichment': true,
      'qualityOptions': [
        {'id': _quality, 'label': 'FLAC', 'kind': 'lossless'},
        {'id': 'opus_320', 'label': 'Opus', 'kind': 'lossy'},
      ],
    }),
  );
  await File(p.join(provider.path, 'index.js')).writeAsString('''
registerExtension({
  checkAvailability(id) { return { available: true, track_id: id }; },
  download(trackId, quality, outputPath) {
    if (quality !== '$_quality') throw new Error('Unexpected fixture quality');
    const result = file.download('http://127.0.0.1:$port/fixture.flac', outputPath);
    if (!result || !result.success) {
      throw new Error(result && result.error || 'Loopback transfer failed');
    }
    return { success: true, file_path: result.path || outputPath };
  }
});
''');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  if (!const {'flac', 'opus', 'selector'}.contains(_downloadCase)) {
    throw ArgumentError.value(_downloadCase, 'MORNYE_PERMANENT_DOWNLOAD_CASE');
  }
  final loadLegacySelection = _downloadCase == 'selector';
  final preserveFlac = _downloadCase != 'opus';
  final outputCodec = preserveFlac ? 'flac' : 'opus';
  final scenario = loadLegacySelection
      ? 'FLAC from saved legacy quality'
      : '$outputCodec audio';

  testWidgets('Android native worker saves permanent $scenario', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final cache = await getTemporaryDirectory();
    final documents = await getApplicationDocumentsDirectory();
    expect(p.split(cache.path), contains(_package));
    expect(p.split(documents.path), contains(_package));
    expect(await PlatformBridge.isDownloadServiceRunning(), isFalse);
    expect(
      (await PlatformBridge.getNativeDownloadWorkerSnapshot())['run_id'],
      '',
      reason: 'Start with fresh integration app data.',
    );
    final notifications = FlutterLocalNotificationsPlugin()
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()!;
    expect(
      await notifications.areNotificationsEnabled(),
      isTrue,
      reason: 'Grant POST_NOTIFICATIONS for the dedicated integration app.',
    );

    var safeToClean = true;
    final root = await cache.createTemp('permanent-download-fixture-');
    addTearDown(() async {
      if (safeToClean) await root.delete(recursive: true);
    });
    final output = await documents.createTemp('permanent-download-output-');
    final destination = p.join(output.path, '${_track.name}.$outputCodec');
    addTearDown(() async {
      if (!safeToClean) return;
      await output.delete(recursive: true);
      await DownloadFileInventory.removeDeletedPath(destination);
    });
    final sources = await Directory(p.join(root.path, 'sources')).create();
    final data = await Directory(p.join(root.path, 'data')).create();
    final fixture = File(p.join(root.path, 'tone.flac'));
    final generation = await FFmpegKit.executeWithArguments([
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=997:sample_rate=48000',
      '-t',
      '1',
      '-c:a',
      'flac',
      fixture.path,
    ]);
    expect(
      ReturnCode.isSuccess(await generation.getReturnCode()),
      isTrue,
      reason: await generation.getOutput(),
    );
    final audio = await fixture.readAsBytes();
    expect(audio, isNotEmpty);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requests = <String>[];
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      final response = request.response;
      if (request.method == 'GET' && request.uri.path == '/fixture.flac') {
        response.headers.contentType = ContentType('audio', 'flac');
        response.contentLength = audio.length;
        response.add(audio);
      } else {
        response.statusCode = HttpStatus.notFound;
      }
      await response.close();
    });
    await _writeProvider(sources, server.port);

    final baseSettings = AppSettings(
      downloadDirectory: output.path,
      folderOrganization: 'flat',
      separateSingles: false,
      filenameFormat: '{title}',
      singleFilenameFormat: '{title}',
      nativeDownloadWorkerEnabled: true,
      concurrentDownloads: 1,
      saveDownloadHistory: true,
      autoFallback: false,
      embedMetadata: false,
      embedLyrics: false,
      embedReplayGain: false,
      lyricsProviders: const [],
      motionArtworkEnabled: false,
      allowLocalNetwork: true,
    );
    var initialSettings = preserveFlac
        ? baseSettings.copyWith()
        : baseSettings;
    final masterKey = base64Encode(List<int>.filled(32, 1));
    if (loadLegacySelection) {
      // An existing default belongs to an already enabled extension. A new
      // installation starts disabled and startup clears its saved selection.
      await PlatformBridge.initExtensionSystem(
        sources.path,
        data.path,
        masterKey: masterKey,
        lyricsProviders: initialSettings.lyricsProviders,
        lyricsFetchOptions: initialSettings.lyricsFetchOptions,
      );
      try {
        await PlatformBridge.loadExtensionsFromDir(sources.path);
        final installed = (await PlatformBridge.getInstalledExtensions())
            .single;
        expect(installed['id'], _provider);
        expect(installed['has_download_provider'], isTrue);
        expect(installed['enabled'], isFalse);
        await PlatformBridge.setExtensionEnabled(_provider, true);
        final enabled = (await PlatformBridge.getInstalledExtensions()).single;
        expect(enabled['status'], 'loaded');
      } finally {
        await PlatformBridge.cleanupExtensions();
      }

      final prefs = await SharedPreferences.getInstance();
      const settingsKey = 'app_settings';
      final previous = prefs.getString(settingsKey);
      addTearDown(() async {
        if (previous == null) {
          await prefs.remove(settingsKey);
        } else {
          await prefs.setString(settingsKey, previous);
        }
      });
      final legacySettings = {
        ...initialSettings.toJson(),
        'defaultService': _provider,
        'audioQuality': _legacyQuality,
        'downloadQualityByProvider': {_provider: _legacyQuality},
      };
      expect(
        await prefs.setString(settingsKey, jsonEncode(legacySettings)),
        isTrue,
      );
      await prefs.reload();
      initialSettings = loadBootstrapSettings(prefs);
      expect(initialSettings.defaultService, _provider);
      expect(initialSettings.audioQuality, _legacyQuality);
    }

    final container = ProviderContainer(
      overrides: [initialSettingsProvider.overrideWithValue(initialSettings)],
    );
    addTearDown(() async {
      if (!safeToClean) return;
      await PlatformBridge.cleanupExtensions();
      await PlatformBridge.setAllowPrivateNetwork(false);
    });
    addTearDown(container.dispose);
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['extensions'], 'rust');
    expect(implementations['downloads'], 'rust');
    final settings = container.read(settingsProvider.notifier);
    if (loadLegacySelection) {
      await settings.ensureLoaded();
      final loaded = container.read(settingsProvider);
      expect(loaded.defaultService, _provider);
      expect(loaded.audioQuality, _legacyQuality);
    }
    final extensions = container.read(extensionProvider.notifier);
    await extensions.initialize(
      sources.path,
      data.path,
      masterKey: masterKey,
    );
    if (loadLegacySelection) {
      final extension = container.read(extensionProvider).extensions.single;
      expect(extension.id, _provider);
      expect(extension.enabled, isTrue);
      expect(extension.hasDownloadProvider, isTrue);
    } else {
      await extensions.setExtensionEnabled(
        _provider,
        true,
        reconcilePreferences: false,
      );
    }
    await PlatformBridge.setAllowPrivateNetwork(true);
    await settings.ensureLoaded();
    if (!loadLegacySelection) {
      final extension = container.read(extensionProvider).extensions.single;
      expect(settings.setDefaultDownloadExtension(extension), isTrue);
      settings.setAudioQuality(_quality);
    }
    final selection = container.read(settingsProvider);
    expect(selection.defaultService, _provider);
    expect(
      selection.audioQuality,
      loadLegacySelection ? _legacyQuality : _quality,
    );

    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final queue = container.read(downloadQueueProvider.notifier);
    queue.pauseQueue(persistAcrossRestarts: false);
    await queue.flushQueuePersistence(requireDurable: true);
    expect(container.read(downloadQueueProvider).items, isEmpty);
    late final String id;
    final messenger = binding.defaultBinaryMessenger;
    var starts = 0;
    var foregroundDownloads = 0;
    String? runId;
    Map<String, dynamic>? workerRequest;
    Map<String, dynamic>? terminal;
    var observationErrors = 0;
    // Read startup files before the delegate consumes them. Observation
    // failures are recorded separately from the real method result.
    messenger.setMockMessageHandler(_backend, (message) async {
      String? method;
      try {
        final call = _codec.decodeMethodCall(message!);
        method = call.method;
        if (method == 'startNativeDownloadWorker') {
          starts++;
          final arguments = call.arguments as Map;
          final settingsPath = arguments['settings_path'] as String;
          final requestsPath = arguments['requests_path'] as String;
          final workerSettings =
              jsonDecode(
                    await File(
                      settingsPath,
                    ).readAsString().timeout(const Duration(seconds: 1)),
                  )
                  as Map<String, dynamic>;
          runId = workerSettings['run_id'] as String;
          final rows =
              jsonDecode(
                    await File(
                      requestsPath,
                    ).readAsString().timeout(const Duration(seconds: 1)),
                  )
                  as List;
          workerRequest =
              jsonDecode((rows.single as Map)['request_json'] as String)
                  as Map<String, dynamic>;
        }
        if (method == 'downloadByStrategy') foregroundDownloads++;
      } catch (_) {
        observationErrors++;
      }

      final reply = await messenger.delegate.send(_backend, message);
      if (method == 'getNativeDownloadWorkerSnapshot' && reply != null) {
        try {
          final snapshot =
              jsonDecode(_codec.decodeEnvelope(reply) as String)
                  as Map<String, dynamic>;
          final observedRunId = snapshot['run_id'] as String?;
          final rows = [
            if (snapshot['items'] case final List<dynamic> items) ...items,
            if (snapshot['item_delta'] case final Map<String, dynamic> row) row,
            if (snapshot['item_deltas'] case final List<dynamic> rows) ...rows,
          ];
          for (final row in rows.whereType<Map<String, dynamic>>()) {
            if (runId != null &&
                observedRunId == runId &&
                row['item_id'] == id &&
                const {
                  'completed',
                  'failed',
                  'skipped',
                }.contains(row['status'])) {
              terminal = row;
            }
          }
        } catch (_) {
          observationErrors++;
        }
      }
      return reply;
    });
    addTearDown(() => messenger.setMockMessageHandler(_backend, null));

    id = queue.addToQueue(_track, selection.defaultService);
    addTearDown(() async {
      queue.pauseQueue(persistAcrossRestarts: false);
      if (!safeToClean) {
        const stopDeadline = Duration(seconds: 5);
        const probeTimeout = Duration(seconds: 2);
        const retryInterval = Duration(milliseconds: 50);
        final wait = Stopwatch()..start();
        Duration remaining() => stopDeadline - wait.elapsed;
        Duration bounded(Duration limit) =>
            remaining() < limit ? remaining() : limit;

        while (remaining() > Duration.zero) {
          try {
            if (await PlatformBridge.isDownloadServiceRunning().timeout(
                  bounded(probeTimeout),
                ) &&
                remaining() > Duration.zero) {
              await PlatformBridge.cancelNativeDownloadWorker().timeout(
                bounded(probeTimeout),
              );
            }
          } on TimeoutException {
            // The stopped store can still confirm the exact run.
          }
          if (remaining() <= Duration.zero) break;
          final currentRun = runId;
          if (currentRun != null) {
            try {
              safeToClean =
                  await PlatformBridge.discardStoppedNativeDownloadWorkerItems(
                    runId: currentRun,
                    itemIds: [id],
                    allRequests: false,
                  ).timeout(bounded(probeTimeout));
            } on TimeoutException {
              // A delayed acknowledgement can be read on the next probe.
            }
            if (safeToClean) break;
          }
          if (remaining() > Duration.zero) {
            await Future<void>.delayed(bounded(retryInterval));
          }
        }
        expect(
          safeToClean,
          isTrue,
          reason: 'Worker stop unconfirmed; fixtures retained.',
        );
      }
      queue.removeItem(id);
      await queue.flushQueuePersistence(requireDurable: true);
      final history = await HistoryDatabase.instance.findByFilePath(
        destination,
      );
      if (history != null) {
        await HistoryDatabase.instance.deleteByIds([history['id'] as String]);
      }
    });

    await queue.flushQueuePersistence(requireDurable: true);
    expect(
      container.read(downloadQueueProvider).items.single.qualityOverride,
      isNull,
    );
    final done = Completer<DownloadItem>();
    DownloadItem? settledItem;
    final listener = container.listen(downloadQueueProvider, (_, state) {
      if (done.isCompleted) return;
      for (final item in state.items) {
        if (item.id == id &&
            const {
              DownloadStatus.completed,
              DownloadStatus.failed,
            }.contains(item.status)) {
          settledItem = item;
        }
      }
      final item = settledItem;
      if (!state.isProcessing && item != null) done.complete(item);
    });
    addTearDown(listener.close);

    safeToClean = false;
    queue.resumeQueue();
    final item = await done.future.timeout(const Duration(seconds: 60));
    await queue.flushQueuePersistence(requireDurable: true);
    expect(observationErrors, 0, reason: 'Native observer errors');
    expect(starts, 1);
    expect(foregroundDownloads, 0);
    expect(workerRequest?['service'], _provider);
    expect(workerRequest?['quality'], _quality);
    expect(workerRequest?['output_dir'], output.path);
    expect(workerRequest?['auto_convert_downloads'], !preserveFlac);
    if (!preserveFlac) {
      expect(workerRequest?['auto_convert_format'], 'opus');
      expect(workerRequest?['auto_convert_bitrate'], '160k');
    }
    expect(terminal?['status'], 'completed');
    final nativeResult = terminal?['result'] as Map?;
    expect(nativeResult?['success'], isTrue);
    expect(nativeResult?['native_finalized'], isTrue);
    expect(item.status, DownloadStatus.completed, reason: item.error);
    expect(item.filePath, destination);
    expect(requests, ['GET /fixture.flac']);
    final downloaded = File(destination);
    final downloadedBytes = await downloaded.readAsBytes();
    expect(await FFmpegProbe.audioCodec(destination), outputCodec);
    if (preserveFlac) {
      expect(downloadedBytes, audio);
    } else {
      expect(downloadedBytes.take(4), ascii.encode('OggS'));
      final info = await FFmpegExecution.mediaInformation(destination);
      expect(double.tryParse(info?.getDuration() ?? ''), closeTo(1, 0.1));
      final decoded = await FFmpegKit.executeWithArguments([
        '-v',
        'error',
        '-xerror',
        '-i',
        destination,
        '-map',
        '0:a:0',
        '-f',
        'null',
        '-',
      ]);
      expect(ReturnCode.isSuccess(await decoded.getReturnCode()), isTrue);
    }
    expect(
      await output.list(recursive: true).map((entry) => entry.path).toList(),
      [destination],
    );

    final history = await HistoryDatabase.instance.findByFilePath(destination);
    expect(history?['filePath'], destination);
    expect(history?['trackName'], _track.name);
    expect(history?['service'], _provider);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
