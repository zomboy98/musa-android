// Simulated integration: real search/save/controllers/runtime, silent fake output.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fixed_settings.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/app_state_database.dart';
import 'package:mornye/services/autoplay_personalization.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/services/file_access_check.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/playback_deck.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
import 'support/search_results_fixture.dart';

class _History extends DownloadHistoryNotifier {
  _History(this.path);
  final String path;
  @override
  DownloadHistoryState build() => DownloadHistoryState();
  @override
  Future<DownloadHistoryItem?> getBySpotifyIdAsync(String id) async =>
      DownloadHistoryItem(
        id: 'imported-local',
        trackName: 'Found track 0',
        artistName: 'Example artist 0',
        albumName: '',
        filePath: path,
        service: 'local',
        downloadedAt: DateTime(2026),
        spotifyId: id,
      );
  @override
  Future<DownloadHistoryItem?> getByIsrcAsync(String isrc) async => null;
  @override
  Future<DownloadHistoryItem?> findByTrackAndArtistAsync(
    String name,
    String artist,
  ) async => null;
  @override
  Future<void> removeManyFromHistory(Iterable<String> ids) async {
    expect(ids, isEmpty, reason: 'The local fixture must exist');
  }
}

class _NoDownloads extends DownloadQueueNotifier {
  int attempts = 0;
  @override
  DownloadQueueState build() => const DownloadQueueState();
  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) {
    attempts++;
    throw StateError('Downloading is forbidden in this local integration');
  }

  @override
  Future<String?> addCurrentSavedTrackToQueue(
    Track track,
    String service,
    bool Function() isCurrent,
  ) => addSavedTrackToQueue(track, service);

  @override
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) async {
    attempts++;
    throw StateError('Downloading is forbidden in this local integration');
  }
}

class _PipelineExtensions extends SearchFixtureExtensions {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Offline fixture',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasMetadataProvider: true,
        hasDownloadProvider: true,
        skipMetadataEnrichment: true,
        searchBehavior: SearchBehavior(enabled: true),
      ),
    ],
  );
  @override
  Future<void> ensureInitialized() async {}
}

/// The row "+" opens the add-to-music sheet; flipping Library and confirming
/// saves the song. Confirming touches the real database, so it runs outside
/// the fake clock.
Future<void> _saveThroughSheet(WidgetTester tester, {required Finder plus}) async {
  await tester.tap(plus);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.tap(find.byKey(const ValueKey('add-to-music-library')));
  await tester.pump();
  await tester.runAsync(
    () => tester.tap(find.byKey(const ValueKey('add-to-music-confirm'))),
  );
  await tester.pump();
}

void main() {
  testWidgets(
    'save queues offline provider, persists real history and search replays without redownload',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'mornye-real-queue-',
      );
      final output = Directory('${directory.path}/audio')..createSync();
      final fixture = File('${directory.path}/fixture.wav');
      final bytes = Uint8List(1644);
      final header = ByteData.sublistView(bytes);
      void tag(int at, String text) {
        for (var i = 0; i < text.length; i++) {
          bytes[at + i] = text.codeUnitAt(i);
        }
      }

      tag(0, 'RIFF');
      header.setUint32(4, 1636, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      header.setUint32(16, 16, Endian.little);
      header.setUint16(20, 1, Endian.little);
      header.setUint16(22, 1, Endian.little);
      header.setUint32(24, 8000, Endian.little);
      header.setUint32(28, 16000, Endian.little);
      header.setUint16(32, 2, Endian.little);
      header.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      header.setUint32(40, 1600, Endian.little);
      fixture.writeAsBytesSync(bytes);
      sqfliteFfiInit();
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      AndroidFlutterLocalNotificationsPlugin.registerWith();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const backend = MethodChannel('com.zarz.mornye/backend');
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      const notifications = MethodChannel(
        'dexterous.com/flutter/local_notifications',
      );
      const connectivity = MethodChannel(
        'dev.fluttercommunity.plus/connectivity_status',
      );
      const connectivityMethods = MethodChannel(
        'dev.fluttercommunity.plus/connectivity',
      );
      const progress = MethodChannel(
        'com.zarz.mornye/download_progress_stream',
      );
      messenger.setMockMethodCallHandler(paths, (_) async => directory.path);
      messenger.setMockMethodCallHandler(
        notifications,
        (call) async => call.method == 'initialize' ? true : null,
      );
      messenger.setMockMethodCallHandler(connectivity, (_) async => null);
      messenger.setMockMethodCallHandler(
        connectivityMethods,
        (_) async => ['wifi'],
      );
      messenger.setMockMethodCallHandler(progress, (_) async => null);
      final requests = <Map<String, dynamic>>[];
      final providerGate = Completer<void>();
      String? downloadedPath;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'downloadByStrategy') {
          final request = (jsonDecode(call.arguments as String) as Map)
              .cast<String, dynamic>();
          requests.add(request);
          await providerGate.future;
          final path = '${request['output_dir']}/saved-fixture.wav';
          File(path).parent.createSync(recursive: true);
          fixture.copySync(path);
          downloadedPath = path;
          return {
            'success': true,
            'file_path': path,
            'service': 'example',
            'actual_extension': '.wav',
            'actual_bit_depth': 16,
            'actual_sample_rate': 8000,
          };
        }
        if (call.method == 'readFileMetadata') return <String, dynamic>{};
        if (call.method == 'getDownloadProgress') return <String, dynamic>{};
        return null;
      });
      const base = AppSettings(
        searchProvider: 'example',
        defaultService: 'example',
        playerMode: 'internal',
        autoDownloadSavedTracks: true,
        localLibraryEnabled: false,
        embedMetadata: false,
        embedLyrics: false,
        embedReplayGain: false,
        motionArtworkEnabled: false,
        autoFallback: false,
        // Preserve the WAV fixture in this download-and-replay test.
        saveDownloadHistory: true,
        nativeDownloadWorkerEnabled: false,
      );
      final settings = base.copyWith(downloadDirectory: output.path);
      final deck = _Deck();
      final session = _Session();
      final runtime = MusicPlayerRuntime(
        settings: settings,
        dependencies: PlaybackDependencies(
          createDeck: (_) => deck,
          audioSession: () async => session,
          initializeHandler: (builder) async => builder(),
          synchronizePlaybackState: () async {},
          createPersonalization: () => AutoplayPersonalization(
            load: () async => null,
            save: (_) async {},
          ),
          sessionDatabase: _SessionStore(),
          volumeChanges: const Stream.empty(),
          readMetadata: (_, {displayName}) async => {},
          recoverMissingFile: (path) async {
            expect(File(path).existsSync(), isTrue);
            return null;
          },
          resolveNetworkSource: (_) async =>
              throw StateError('Network forbidden'),
          recorder: ListeningRecorder(
            write: (_) async {},
            elapsed: () => Duration.zero,
            now: () => DateTime(2026),
          ),
          isAndroid: false,
          isIOS: false,
          isMacOS: false,
        ),
      );
      late ProviderContainer container;
      addTearDown(() async {
        if (!providerGate.isCompleted) providerGate.complete();
        var disposed = false;
        final disposing = runtime.dispose().whenComplete(() => disposed = true);
        for (var i = 0; i < 100 && !disposed; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await disposing;
        await tester.runAsync(() async {
          await session.dispose();
          await HistoryDatabase.instance.close();
          await LibraryDatabase.instance.close();
          await (await AppStateDatabase.instance.database).close();
        });
        for (final channel in [
          backend,
          paths,
          notifications,
          connectivity,
          connectivityMethods,
          progress,
        ]) {
          messenger.setMockMethodCallHandler(channel, null);
        }
        databaseFactory = previousFactory;
        // Windows can briefly retain handles after the FFI database closes.
        await tester.runAsync(() async {
          for (var attempt = 0; ; attempt++) {
            try {
              await directory.delete(recursive: true);
              break;
            } on PathAccessException {
              if (!Platform.isWindows || attempt == 9) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 50));
            }
          }
        });
      });
      SharedPreferences.setMockInitialValues({});
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.runAsync(() async {
        container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(
              () => FixedSettingsNotifier(settings),
            ),
            extensionProvider.overrideWith(_PipelineExtensions.new),
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            trackProvider.overrideWith(SearchFixtureResults.new),
          ],
        );
        container.read(downloadQueueProvider);
        container.read(downloadHistoryProvider);
        await container
            .read(downloadHistoryProvider.notifier)
            .getBySpotifyIdAsync('track-0');
        await container.read(savedLibraryTracksProvider.future);
        await container
            .read(downloadQueueProvider.notifier)
            .flushQueuePersistence();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: HomeTab(mode: HomeTabMode.search)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Example');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      final queue = container.read(downloadQueueProvider.notifier);
      final states = <DownloadStatus>[];
      final listener = container.listen(downloadQueueProvider, (_, next) {
        for (final item in next.items) {
          if (states.lastOrNull != item.status) states.add(item.status);
        }
      });
      addTearDown(listener.close);
      final save = find.byWidgetPredicate(
        (w) => w is SaveLibraryTrackButton && w.track.id == 'track-0',
      );
      final track = tester.widget<SaveLibraryTrackButton>(save).track;
      final saveButton = find.descendant(
        of: save,
        matching: find.byKey(const ValueKey('save-library-track')),
      );
      // The "+" opens the add-to-music sheet; confirming Library saves it.
      await _saveThroughSheet(tester, plus: saveButton);
      // Advance widget timers while letting the real database and provider run.
      for (var i = 0; i < 200 && requests.isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(requests, hasLength(1));
      await tester.runAsync(() async {
        await queue.flushQueuePersistence();
        final persisted = await AppStateDatabase.instance
            .getPendingDownloadQueueRows();
        expect(persisted, hasLength(1));
        expect(persisted.single['item_json'], contains('track-0'));
        providerGate.complete();
      });
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (states.contains(DownloadStatus.completed) &&
            !container.read(downloadQueueProvider).isProcessing) {
          break;
        }
      }
      await tester.runAsync(() async {
        await queue.flushQueuePersistence();
        final saved = await container
            .read(downloadHistoryProvider.notifier)
            .getBySpotifyIdAsync('track-0');
        expect(saved?.filePath, downloadedPath);
        expect(saved, isNotNull);
        expect(File(saved!.filePath).readAsBytesSync(), bytes);
        expect(
          await AppStateDatabase.instance.getPendingDownloadQueueRows(),
          isEmpty,
        );
        // Close/reopen the production history DB to demonstrate on-disk persistence.
        await HistoryDatabase.instance.close();
        final reloaded = await HistoryDatabase.instance.getBySpotifyId(
          'track-0',
        );
        expect(reloaded?['file_path'] ?? reloaded?['filePath'], downloadedPath);
      });
      await tester.pumpAndSettle();
      expect(
        states,
        containsAllInOrder([
          DownloadStatus.queued,
          DownloadStatus.downloading,
          DownloadStatus.completed,
        ]),
      );
      expect(
        container
            .read(savedLibraryTracksProvider)
            .requireValue
            .map((t) => t.id),
        ['track-0'],
      );
      await tester.runAsync(() async {
        await tester.tap(find.text('Found track 0'));
        for (
          var i = 0;
          i < 100 && deck.state != PlaybackDeckState.playing;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(deck.sources, [downloadedPath]);
      expect(deck.sourceBytes.single, bytes);
      expect(runtime.handler!.playbackState.value.playing, isTrue);
      expect(
        runtime.handler!.mediaItem.value!.extras!['source'],
        downloadedPath,
      );
      expect(
        requests,
        hasLength(1),
        reason: 'Search must reuse saved file rather than redownload',
      );
      expect(container.read(downloadQueueProvider).items, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.runAsync(queue.flushQueuePersistence);
      // Let the visible save button finish its history lookup before disposal.
      final downloadStatus = playlistRealDownloadProvider(track);
      for (
        var i = 0;
        i < 200 && container.read(downloadStatus).isLoading;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
      }
      expect(container.read(downloadStatus).requireValue, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'save catalog result then tap plays existing PCM file through runtime without downloading',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('mornye-search-runtime-');
      SharedPreferences.setMockInitialValues({});
      sqfliteFfiInit();
      final previousFactory = databaseFactoryOrNull;
      databaseFactory = databaseFactoryFfi;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const paths = MethodChannel('plugins.flutter.io/path_provider');
      messenger.setMockMethodCallHandler(paths, (_) async => dir.path);
      addTearDown(() async {
        await tester.runAsync(() async {
          await HistoryDatabase.instance.close();
          await LibraryDatabase.instance.close();
        });
        messenger.setMockMethodCallHandler(paths, null);
        databaseFactory = previousFactory;
        dir.deleteSync(recursive: true);
      });
      final file = File('${dir.path}/song.wav');
      // Valid mono PCM WAV: 800 silent samples at 8 kHz, 16 bits.
      final wav = ByteData(44 + 1600);
      void tag(int offset, String value) {
        for (var i = 0; i < value.length; i++) {
          wav.setUint8(offset + i, value.codeUnitAt(i));
        }
      }

      tag(0, 'RIFF');
      wav.setUint32(4, 1636, Endian.little);
      tag(8, 'WAVE');
      tag(12, 'fmt ');
      wav.setUint32(16, 16, Endian.little);
      wav.setUint16(20, 1, Endian.little);
      wav.setUint16(22, 1, Endian.little);
      wav.setUint32(24, 8000, Endian.little);
      wav.setUint32(28, 16000, Endian.little);
      wav.setUint16(32, 2, Endian.little);
      wav.setUint16(34, 16, Endian.little);
      tag(36, 'data');
      wav.setUint32(40, 1600, Endian.little);
      file.writeAsBytesSync(wav.buffer.asUint8List());
      final deck = _Deck();
      final downloads = _NoDownloads();
      final session = _Session();
      await tester.runAsync(() async {
        await HistoryDatabase.instance.upsert(
          DownloadHistoryItem(
            id: 'imported-local',
            trackName: 'Found track 0',
            artistName: 'Example artist 0',
            albumName: '',
            filePath: file.path,
            service: 'local',
            downloadedAt: DateTime(2026),
            spotifyId: 'track-0',
          ).toJson(),
        );
      });
      const settings = AppSettings(
        searchProvider: 'example',
        playerMode: 'internal',
        localLibraryEnabled: false,
        autoDownloadSavedTracks: false,
      );
      var remoteCalls = 0;
      final runtime = MusicPlayerRuntime(
        settings: settings,
        dependencies: PlaybackDependencies(
          createDeck: (_) => deck,
          audioSession: () async => session,
          createPersonalization: () => AutoplayPersonalization(
            load: () async => null,
            save: (_) async {},
          ),
          initializeHandler: (builder) async => builder(),
          synchronizePlaybackState: () async {},
          sessionDatabase: _SessionStore(),
          volumeChanges: const Stream.empty(),
          readMetadata: (_, {displayName}) async => {},
          fileAccess: (path) async {
            final stat = File(path).statSync();
            return stat.type == FileSystemEntityType.file
                ? FileAccessFound(
                    FileAccessStat(size: stat.size, modified: stat.modified),
                  )
                : const FileAccessMissing();
          },
          resolveNetworkSource: (_) async {
            remoteCalls++;
            throw StateError('Network forbidden');
          },
          recoverMissingFile: (path) async {
            if (File(path).existsSync()) return null;
            remoteCalls++;
            throw StateError('Recovery forbidden');
          },
          recoverMovedDownload: (_, _, _) async {
            remoteCalls++;
            throw StateError('Download forbidden');
          },
          recorder: ListeningRecorder(
            write: (_) async {},
            elapsed: () => Duration.zero,
            now: () => DateTime(2026),
          ),
          isAndroid: false,
          isIOS: false,
          isMacOS: false,
        ),
      );
      addTearDown(session.dispose);
      addTearDown(() async {
        var done = false;
        final disposing = runtime.dispose().whenComplete(() => done = true);
        for (var i = 0; i < 100 && !done; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        await disposing;
      });
      await pumpSearchFixture(
        tester,
        size: const Size(390, 1400),
        mornye: true,
        settings: settings,
        history: _History(file.path),
        runtime: runtime,
        queue: downloads,
        simulateNoCachedAudio: true,
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(SaveLibraryTrackButton).first),
      );
      final save = find.byWidgetPredicate(
        (widget) =>
            widget is SaveLibraryTrackButton && widget.track.id == 'track-0',
      );
      await _saveThroughSheet(
        tester,
        plus: find.descendant(
          of: save,
          matching: find.byKey(const ValueKey('save-library-track')),
        ),
      );
      // Retention checks access real storage and run outside the fake clock.
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        if (container.read(savedLibraryTracksProvider).value?.isNotEmpty ??
            false) {
          break;
        }
      }
      await tester.pumpAndSettle();
      expect(
        container
            .read(savedLibraryTracksProvider)
            .requireValue
            .map((t) => t.id),
        ['track-0'],
      );
      expect(deck.sources, isEmpty);
      expect(runtime.handler, isNull);
      await tester.runAsync(() async {
        final paths = await container
            .read(playbackProvider.notifier)
            .resolveTrackFilePaths([
              searchFixtureItem('track', 0, source: 'example'),
            ])
            .timeout(const Duration(seconds: 5));
        expect(paths, [file.path]);
      });
      await tester.runAsync(() async {
        await tester.tap(find.text('Found track 0'));
        for (
          var i = 0;
          i < 100 && deck.state != PlaybackDeckState.playing;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pumpAndSettle();
      expect(deck.sources, [file.path]);
      expect(deck.sourceBytes.single, wav.buffer.asUint8List());
      expect(deck.state, PlaybackDeckState.playing);
      expect(runtime.handler!.mediaItem.value!.extras!['source'], file.path);
      expect(runtime.handler!.mediaItem.value!.title, 'Found track 0');
      expect(runtime.handler!.playbackState.value.playing, isTrue);
      expect(runtime.handler!.queue.value, hasLength(1));
      expect(container.read(downloadQueueProvider).items, isEmpty);
      expect(downloads.attempts, 0);
      expect(remoteCalls, 0);
      expect(file.readAsBytesSync(), wav.buffer.asUint8List());
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}

class _Deck implements PlaybackDeck {
  @override
  PlaybackDeckState state = PlaybackDeckState.stopped;
  final volumes = <double>[];
  Map<String, bool>? outputOptions;
  final sources = <String>[];
  final sourceBytes = <Uint8List>[];
  Duration position = Duration.zero;
  int disposals = 0;
  bool failStop = false;
  Future<void> Function()? beforeDispose;

  @override
  bool get isDirect => false;
  @override
  bool get needsSourceReload => false;
  @override
  Stream<PlaybackDeckState> get onPlayerStateChanged => const Stream.empty();
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<void> get onPlayerComplete => const Stream.empty();
  @override
  void startPositionUpdates(Duration interval, {bool Function()? wanted}) {}
  @override
  Future<void> configureOutput() async {}
  @override
  Future<void> setVolume(double volume) async => volumes.add(volume);
  @override
  Future<void> cancelPreparation() async {}
  @override
  Future<void> stop() async {
    if (failStop) throw StateError('Transport failed');
    state = PlaybackDeckState.stopped;
  }

  @override
  Future<void> pause() async => state = PlaybackDeckState.paused;
  @override
  Future<void> resume() async => state = PlaybackDeckState.playing;
  @override
  Future<void> seek(Duration value) async => position = value;
  @override
  Future<Duration?> getDuration() async => const Duration(seconds: 60);
  @override
  Future<Duration?> getCurrentPosition() async => position;
  @override
  Future<void> dispose() async {
    await beforeDispose?.call();
    disposals++;
  }

  @override
  Future<void> setFileSource(
    String path, {
    bool preferBitPerfect = false,
    bool directUsb = false,
    bool allowDop = false,
    bool requiresDsd = false,
    bool allowFixedVolume = false,
    bool dapExclusive = false,
  }) async {
    sources.add(path);
    sourceBytes.add(File(path).readAsBytesSync());
    outputOptions = {
      'bitPerfect': preferBitPerfect,
      'direct': directUsb,
      'dop': allowDop,
      'fixedVolume': allowFixedVolume,
      'exclusive': dapExclusive,
    };
  }

  @override
  Future<void> setNetworkSource(String url, {bool arriving = false}) async =>
      sources.add('${arriving ? 'arriving' : 'stream'} $url');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements AudioSession {
  int configurations = 0;
  final activations = <bool>[];
  bool focusGranted = true;
  Object? activationError;
  Completer<void>? configureBarrier;
  final interruptions = StreamController<AudioInterruptionEvent>.broadcast();

  Future<void> dispose() => interruptions.close();

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {
    configurations++;
    await configureBarrier?.future;
  }

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    activations.add(active);
    if (activationError case final error?) throw error;
    return !active || focusGranted;
  }

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      interruptions.stream;
  @override
  Stream<void> get becomingNoisyEventStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SessionStore implements AppStateDatabase {
  int clears = 0;
  int? persistedPositionMs;

  @override
  Future<Map<String, dynamic>?> getPlaybackSession() async => null;
  @override
  Future<void> savePlaybackSession({
    required Uint8List mediaJson,
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    persistedPositionMs = positionMs;
  }

  @override
  Future<bool> updatePlaybackSessionState({
    required int index,
    required int positionMs,
    required bool shuffle,
    required String repeatMode,
  }) async {
    persistedPositionMs = positionMs;
    return true;
  }

  @override
  Future<void> clearPlaybackSession() async => clears++;

  @override
  Future<void> archivePlaybackSession(Map<String, dynamic> media) async =>
      clears++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
