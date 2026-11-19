import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'support/fixed_settings.dart';

const song = Track(
  id: 'song',
  name: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 120,
  isrc: 'USABC1234567',
);

class _RealHistory extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _ErroredExtension extends ExtensionNotifier {
  _ErroredExtension({
    required this.stopProviderFallback,
    this.enabled = true,
    this.id = 'errored',
  });

  final bool stopProviderFallback;
  final bool enabled;
  final String id;

  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': id,
        'enabled': enabled,
        'status': 'error',
        'stop_provider_fallback': stopProviderFallback,
        'has_download_provider': true,
        'quality_options': [
          {'id': 'allowed', 'label': 'Allowed'},
          if (id == 'deezer') {'id': 'flac', 'label': 'FLAC'},
        ],
      }),
      Extension.fromJson({
        'id': 'alternative',
        'enabled': true,
        'has_download_provider': true,
      }),
    ],
  );

  @override
  Future<void> ensureInitialized() async {}
}

class _Playback extends PlaybackController {
  String? playedPath;
  @override
  Future<void> playLocalPath({
    required String path,
    required String title,
    required String artist,
    String album = '',
    String coverUrl = '',
    Duration? duration,
    int? bitDepth,
    int? sampleRate,
    int? bitrate,
    String? format,
    bool? explicit,
  }) async {
    playedPath = path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  const paths = MethodChannel('plugins.flutter.io/path_provider');
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('playlist-sqlite-');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
  });
  tearDownAll(() async {
    await HistoryDatabase.instance.close();
    await (await AppStateDatabase.instance.database).close();
    messenger.setMockMethodCallHandler(paths, null);
    await root.delete(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await HistoryDatabase.instance.clearAll();
  });
  tearDown(() {
    debugDesktopPlatformOverride = null;
    messenger.setMockMethodCallHandler(backend, null);
  });

  Map<String, dynamic> row(
    String id,
    String path,
    int day, {
    String isrc = 'USABC1234567',
  }) => {
    'id': id,
    'spotifyId': 'song',
    'trackName': 'Song',
    'artistName': 'Artist',
    'albumName': 'Album',
    'filePath': path,
    'service': 'test',
    'isrc': isrc,
    'downloadedAt': DateTime.utc(2026, 1, day).toIso8601String(),
  };

  testWidgets('SQLite older available copy drives indicator and playback', (
    tester,
  ) async {
    final file = await tester.runAsync(
      () => File('${root.path}/old.flac').writeAsBytes([1, 2, 3]),
    );
    await tester.runAsync(
      () => HistoryDatabase.instance.upsertBatch([
        row('old', file!.path, 1),
        row('new', '${root.path}/missing.flac', 2),
      ]),
    );
    final playback = _Playback();
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(_RealHistory.new),
        playbackProvider.overrideWith(() => playback),
        persistentCatalogAudioProvider.overrideWith(
          (ref) =>
              (_) async => false,
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = await tester.runAsync(
      () async =>
          container.listen(playlistDownloadedFileProvider(song), (_, _) {}),
    );
    addTearDown(sub!.close);
    expect(
      await tester.runAsync(
        () => container.read(playlistDownloadedFileProvider(song).future),
      ),
      isTrue,
    );
    late BuildContext context;
    late WidgetRef widgetRef;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Consumer(
            builder: (ctx, ref, _) {
              context = ctx;
              widgetRef = ref;
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    expect(
      await tester.runAsync(
        () => playLocalIfAvailable(context, widgetRef, song),
      ),
      isTrue,
    );
    expect(playback.playedPath, file!.path);
  });

  test('SAF requires readable nonempty document', () async {
    debugDesktopPlatformOverride = false;
    var readable = true;
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'safCanOpenRead') return readable;
      if (call.method == 'safStat') return {'exists': true, 'size': 10};
      return null;
    });
    await HistoryDatabase.instance.upsertBatch([
      row('saf', 'content://tree/song', 1),
    ]);
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(_RealHistory.new),
        persistentCatalogAudioProvider.overrideWith(
          (ref) =>
              (_) async => false,
        ),
      ],
    );
    addTearDown(container.dispose);
    final sub = container.listen(
      playlistDownloadedFileProvider(song),
      (_, _) {},
    );
    addTearDown(sub.close);
    expect(
      await container.read(playlistDownloadedFileProvider(song).future),
      isTrue,
    );
    readable = false;
    TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
      AppLifecycleState.resumed,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(
      await container.read(playlistDownloadedFileProvider(song).future),
      isFalse,
    );
  });

  test(
    'automatic save searches older SQLite history and retries if missing',
    () async {
      final old = await File('${root.path}/queue-old.flac').writeAsBytes([1]);
      await HistoryDatabase.instance.upsertBatch([
        row('old', old.path, 1),
        row('new', '${root.path}/queue-missing.flac', 2),
      ]);
      expect(
        (await HistoryDatabase.instance.getBySpotifyId(song.id))?['id'],
        'new',
      );
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(_RealHistory.new),
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                downloadDirectory: root.path,
                localLibraryEnabled: false,
              ),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final queue = container.read(downloadQueueProvider.notifier);
      queue.pauseQueue();
      expect(await queue.addSavedTrackToQueue(song, 'test'), isNull);
      expect(container.read(downloadQueueProvider).items, isEmpty);
      await old.delete();
      final retry = await queue.addSavedTrackToQueue(song, 'test');
      expect(retry, isNotNull);
      expect(container.read(downloadQueueProvider).items.single.id, retry);
      await queue.flushQueuePersistence();
      queue.removeItem(retry!);
      await queue.flushQueuePersistence();
    },
  );

  for (final policy in [
    'disabled',
    'excluded',
    'provider opt-out',
    'allowed',
    'missing provider quality',
    'remembered provider quality',
    'declared provider default',
  ]) {
    test(
      'unavailable provider respects permanent fallback policy: $policy',
      () async {
        final provider = policy == 'declared provider default'
            ? 'deezer'
            : 'errored';
        final expectedQuality = switch (policy) {
          'allowed' => 'HI_RES_LOSSLESS',
          'remembered provider quality' => 'allowed',
          // The default is the MP3-equivalent tier: the highest lossy one up
          // to 320 kbps, ahead of the lossless 'flac' the provider also declares.
          'declared provider default' => 'allowed',
          _ => null,
        };
        final requests = <Map<String, dynamic>>[];
        messenger.setMockMethodCallHandler(backend, (call) async {
          if (call.method != 'downloadByStrategy') return null;
          requests.add(
            jsonDecode(call.arguments as String) as Map<String, dynamic>,
          );
          return {'success': false, 'error_type': 'quality_unavailable'};
        });
        final container = ProviderContainer(
          overrides: [
            extensionProvider.overrideWith(
              () => _ErroredExtension(
                stopProviderFallback: policy == 'provider opt-out',
                enabled: false,
                id: provider,
              ),
            ),
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(
                AppSettings(
                  downloadDirectory: root.path,
                  defaultService: 'alternative',
                  audioQuality: 'MP3',
                  downloadQualityByProvider:
                      policy == 'remembered provider quality'
                      ? {provider: 'allowed'}
                      : const {},
                  autoFallback: policy != 'disabled',
                  downloadFallbackExtensionIds: policy == 'excluded'
                      ? const []
                      : const ['alternative'],
                ),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        final queue = container.read(downloadQueueProvider.notifier);
        queue.pauseQueue();
        await queue.flushQueuePersistence();
        final id = queue.addToQueue(
          song.copyWith(id: 'extension:catalog:song'),
          provider,
          qualityOverride: policy == 'allowed' ? 'HI_RES_LOSSLESS' : null,
        );
        final failed = Completer<DownloadItem>();
        final idle = Completer<void>();
        final sub = container.listen(downloadQueueProvider, (_, state) {
          final item = state.lookup.byItemId[id];
          if (item == null) return;
          if (item.status == DownloadStatus.failed && !failed.isCompleted) {
            failed.complete(item);
          }
          if (failed.isCompleted && !state.isProcessing && !idle.isCompleted) {
            idle.complete();
          }
        });
        addTearDown(sub.close);
        queue.resumeQueue();
        final item = await failed.future.timeout(const Duration(seconds: 5));
        await idle.future.timeout(const Duration(seconds: 5));
        queue.removeItem(id);
        await queue.flushQueuePersistence();
        expect(item.service, provider);
        if (expectedQuality != null) {
          final request = requests.single;
          expect(request['service'], provider);
          expect(request['quality'], expectedQuality);
          expect(request['use_fallback'], true);
          expect(request['allow_quality_fallback'], isNot(true));
          expect(item.errorType, DownloadErrorType.qualityUnavailable);
        } else if (policy == 'missing provider quality') {
          // Relay is the default: a tier nobody chose no longer stops the
          // download in Dart. The backend is asked for the best available
          // tier (empty request) and reports unavailable only after every
          // provider and quality class failed, as this fake backend does.
          final request = requests.single;
          expect(request['service'], provider);
          expect(request['quality'], '');
          expect(request['quality_relay'], true);
          expect(request['use_fallback'], true);
          expect(item.errorType, DownloadErrorType.qualityUnavailable);
        } else {
          expect(requests, isEmpty);
          expect(item.error, 'Provider is unavailable');
          expect(item.errorType, DownloadErrorType.providerUnavailable);
          expect(item.preparationStage, isEmpty);
        }
      },
    );
  }

  for (final duringOutput in [false, true]) {
    for (final pause in [false, true]) {
      test(
        'network download respects ${pause ? 'pause' : 'cancel'} during '
        '${duringOutput ? 'output preparation' : 'staging lookup'}',
        () async {
          AndroidFlutterLocalNotificationsPlugin.registerWith();
          const notifications = MethodChannel(
            'dexterous.com/flutter/local_notifications',
          );
          messenger.setMockMethodCallHandler(notifications, (_) async => null);
          addTearDown(
            () => messenger.setMockMethodCallHandler(notifications, null),
          );
          final container = ProviderContainer(
            overrides: [
              extensionProvider.overrideWith(
                () => _ErroredExtension(stopProviderFallback: false),
              ),
              settingsProvider.overrideWith(
                () => FixedSettingsNotifier(
                  AppSettings(
                    downloadDirectory: root.path,
                    networkDownloadFolder: 'smb://example.test/music',
                    autoFallback: duringOutput,
                  ),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          final queue = container.read(downloadQueueProvider.notifier);
          queue.pauseQueue();
          await queue.flushQueuePersistence();
          final id = queue.addToQueue(
            song.copyWith(id: 'extension:catalog:song'),
            'errored',
          );
          await queue.flushQueuePersistence();
          final entered = Completer<void>();
          final release = Completer<void>();
          var stagingCalls = 0;
          var backendDownloads = 0;
          messenger.setMockMethodCallHandler(paths, (call) async {
            if (call.method == 'getApplicationSupportDirectory' &&
                ++stagingCalls == (duringOutput ? 2 : 1)) {
              entered.complete();
              await release.future;
            }
            return root.path;
          });
          addTearDown(() {
            if (!release.isCompleted) release.complete();
            messenger.setMockMethodCallHandler(paths, (_) async => root.path);
          });
          messenger.setMockMethodCallHandler(backend, (call) async {
            if (call.method == 'downloadByStrategy') backendDownloads++;
            return null;
          });
          final idle = Completer<void>();
          final sub = container.listen(downloadQueueProvider, (previous, next) {
            if (previous?.isProcessing == true &&
                !next.isProcessing &&
                !idle.isCompleted) {
              idle.complete();
            }
          });
          addTearDown(sub.close);

          queue.resumeQueue();
          await entered.future.timeout(const Duration(seconds: 5));
          if (pause) {
            queue.pauseQueue();
          } else {
            queue.cancelItem(id);
          }
          release.complete();
          await idle.future.timeout(const Duration(seconds: 5));

          final item = container
              .read(downloadQueueProvider)
              .lookup
              .byItemId[id];
          expect(
            item?.status,
            pause ? DownloadStatus.queued : DownloadStatus.skipped,
          );
          expect(item?.errorType, isNull);
          expect(backendDownloads, 0);
          queue.removeItem(id);
          await queue.flushQueuePersistence();
        },
      );
    }
  }

  test(
    'private inventory refreshes mounted indicator and survives restart',
    () async {
      final file = await File('${root.path}/private.flac').writeAsBytes([1]);
      ProviderContainer createContainer() => ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(_RealHistory.new),
          persistentCatalogAudioProvider.overrideWith(
            (ref) =>
                (_) async => false,
          ),
        ],
      );
      var container = createContainer();
      var sub = container.listen(
        playlistDownloadedFileProvider(song),
        (_, _) {},
      );
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isFalse,
      );
      await DownloadFileInventory.record(song, file.path);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isTrue,
      );
      sub.close();
      container.dispose();
      SharedPreferences.resetStatic();
      container = createContainer();
      sub = container.listen(playlistDownloadedFileProvider(song), (_, _) {});
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isTrue,
      );
      await file.delete();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isFalse,
      );
      sub.close();
      container.dispose();
    },
  );

  test(
    'clearing history retains the file indicator and prevents an automatic duplicate',
    () async {
      final file = await File('${root.path}/keep.flac').writeAsBytes([1]);
      await DownloadFileInventory.record(song, file.path);
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(_RealHistory.new),
          settingsProvider.overrideWith(
            () => FixedSettingsNotifier(
              AppSettings(
                saveDownloadHistory: false,
                localLibraryEnabled: false,
              ),
            ),
          ),
          persistentCatalogAudioProvider.overrideWith(
            (ref) =>
                (_) async => false,
          ),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        playlistDownloadedFileProvider(song),
        (_, _) {},
      );
      addTearDown(sub.close);
      await container.read(downloadHistoryProvider.notifier).clearHistory();
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isTrue,
      );
      final queuedId = await container
          .read(downloadQueueProvider.notifier)
          .addSavedTrackToQueue(song, 'test');
      expect(queuedId, isNull);
      expect(container.read(downloadQueueProvider).items, isEmpty);
      expect(await file.exists(), isTrue);
    },
  );

  test(
    'promotion updates an already mounted indicator and resume rechecks file',
    () async {
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(_RealHistory.new),
          catalogAudioStoreProvider.overrideWith((ref) => Future.value(store)),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(
        playlistDownloadedFileProvider(song),
        (_, _) {},
      );
      addTearDown(sub.close);
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isFalse,
      );
      final source = await File('${root.path}/source.opus').writeAsBytes([1]);
      final id = trackCollectionKey(song);
      await store.putTemporary(id, source);
      final entry = (await store.promote(id))!;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isTrue,
      );
      await File(entry.path).delete();
      TestWidgetsFlutterBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isFalse,
      );
      await store.putTemporary(id, source);
      await store.promote(id);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        await container.read(playlistDownloadedFileProvider(song).future),
        isTrue,
      );
    },
  );
}
