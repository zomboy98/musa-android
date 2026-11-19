import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/widgets/collection_header_actions.dart';
import 'package:mornye/widgets/playlist_batch_download_status.dart';
import 'package:mornye/widgets/track_detail_actions.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/widgets/decorative_phase.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

class _DedupSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(
    defaultService: 'example',
    deduplicateDownloads: true,
    localLibraryEnabled: false,
  );

  @override
  void setAllowQualityVariants(bool enabled) {
    state = state.copyWith(allowQualityVariants: enabled);
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(defaultService: 'example', deduplicateDownloads: false);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    extensions: [
      Extension.fromJson({
        'id': 'example',
        'name': 'Example',
        'enabled': true,
        'has_download_provider': true,
      }),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  _Queue({bool publishItems = false}) : _publishItems = publishItems;

  final bool _publishItems;
  final singles = <Track>[];
  final batches = <List<Track>>[];
  List<String> _admittedIds = [];

  void replaceItems(List<DownloadItem> items) {
    state = state.copyWith(items: items);
  }

  List<DownloadItem> get _items => state.items;

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  Future<String?> addSavedTrackToQueue(
    Track track,
    String service, {
    String? playlistName,
    int? playlistPosition,
    String? qualityOverride,
    DownloadOrigin? origin,
  }) async {
    singles.add(track);
    return 'queued';
  }

  @override
  List<String> addMultipleToQueue(
    List<Track> tracks,
    String service, {
    String? qualityOverride,
    bool? allowQualityVariants,
    String? playlistName,
    List<int?>? playlistPositions,
    DownloadOrigin? origin,
  }) {
    batches.add(tracks);
    if (!_publishItems) return const [];
    final admitted = [
      for (final track in tracks)
        DownloadItem(
          id: 'batch-${batches.length}-${track.id}',
          track: track,
          service: service,
          playlistName: playlistName,
          createdAt: DateTime.utc(2026),
        ),
    ];
    replaceItems([..._items, ...admitted]);
    return _admittedIds = admitted.map((item) => item.id).toList();
  }
}

class _PlaylistCollections extends LibraryCollectionsNotifier {
  _PlaylistCollections(this.tracks);
  final List<Track> tracks;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      UserPlaylistCollection(
        id: 'personal-playlist',
        name: 'Playlist',
        createdAt: DateTime.utc(2026),
        updatedAt: DateTime.utc(2026),
        tracks: [
          for (final track in tracks)
            CollectionTrackEntry(
              key: track.id,
              track: track,
              addedAt: DateTime.utc(2026),
            ),
        ],
      ),
    ],
  );
}

class _PlaylistHistory extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<List<DownloadHistoryItem>> findTrackCandidatesAsync(
    HistoryLookupRequest request,
  ) async => const [];
}

class _FeedbackHarness extends StatefulWidget {
  const _FeedbackHarness();

  @override
  State<_FeedbackHarness> createState() => _FeedbackHarnessState();
}

class _FeedbackHarnessState extends State<_FeedbackHarness>
    with PlaylistDownloadFeedback<_FeedbackHarness> {
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: CustomScrollView(slivers: [?playlistDownloadFeedback]));
}

void main() {
  // El reloj decorativo a vsync nunca termina y estas pruebas esperan con
  // pumpAndSettle: se mantiene quieto durante la prueba.
  setUp(() {
    DecorativePhase.debugHoldClock = true;
    DownloadFileInventory.resetWritesForTest();
  });
  tearDown(() => DecorativePhase.debugHoldClock = false);
  for (final newerAdmitted in [false, true]) {
    testWidgets(
      newerAdmitted
          ? 'late older admission cannot replace the newer admitted batch'
          : 'an empty newer submission leaves the late older admission visible',
      (tester) async {
        final queue = _Queue();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [downloadQueueProvider.overrideWith(() => queue)],
            child: const MaterialApp(
              locale: Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: _FeedbackHarness(),
            ),
          ),
        );
        ProviderScope.containerOf(
          tester.element(find.byType(_FeedbackHarness)),
        ).read(downloadQueueProvider);
        final screen = tester.state<_FeedbackHarnessState>(
          find.byType(_FeedbackHarness),
        );
        final older = screen.trackPlaylistDownloadBatch();
        final newer = screen.trackPlaylistDownloadBatch();
        const track = Track(
          id: 'song',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        );
        queue.replaceItems([
          DownloadItem(
            id: 'older',
            track: track,
            service: 'example',
            status: DownloadStatus.failed,
            createdAt: DateTime.utc(2026),
          ),
          if (newerAdmitted)
            DownloadItem(
              id: 'newer',
              track: track,
              service: 'example',
              createdAt: DateTime.utc(2026),
            ),
        ]);
        newer(newerAdmitted ? ['newer'] : []);
        older(['older']);
        await tester.pump();
        expect(
          find.text('1 pending'),
          newerAdmitted ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('1 failed'),
          newerAdmitted ? findsNothing : findsOneWidget,
        );
      },
    );
  }

  for (final personal in [false, true]) {
    testWidgets(
      '${personal ? "personal" : "catalog"} playlist shows only its latest batch and links to failures',
      (tester) async {
        tester.view.physicalSize = const Size(360, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        SharedPreferences.setMockInitialValues({});
        final queue = _Queue(publishItems: true);
        const song = Track(
          id: '1',
          name: 'Song 1',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
        );
        final tracks = [
          song,
          song.copyWith(id: '2', name: 'Song 2'),
          song.copyWith(id: '3', name: 'Song 3'),
        ];
        final owner = Object();
        final opened = <String>[];
        ShellNavigationService.registerTabSelectionHandler(
          owner: owner,
          handler: (_) {},
          libraryLinkHandler: (id) {
            opened.add(id);
            return true;
          },
        );
        addTearDown(
          () => ShellNavigationService.unregisterTabSelectionHandler(owner),
        );
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              extensionProvider.overrideWith(_Extensions.new),
              downloadQueueProvider.overrideWith(() => queue),
              libraryCollectionsProvider.overrideWith(
                () => _PlaylistCollections(tracks),
              ),
              downloadHistoryProvider.overrideWith(_PlaylistHistory.new),
            ],
            child: MaterialApp(
              locale: const Locale('en'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: personal
                  ? const LibraryTracksFolderScreen(
                      mode: LibraryTracksFolderMode.playlist,
                      playlistId: 'personal-playlist',
                    )
                  : PlaylistScreen(playlistName: 'Playlist', tracks: tracks),
            ),
          ),
        );
        ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp)),
        ).read(downloadQueueProvider);
        final foreign = DownloadItem(
          id: 'foreign',
          track: song,
          service: 'example',
          playlistName: 'Playlist',
          status: DownloadStatus.failed,
          createdAt: DateTime.utc(2026),
        );
        queue.replaceItems([foreign]);
        await tester.pump();
        expect(find.text('1 failed'), findsNothing);

        Future<void> submitPlaylist() async {
          if (personal) {
            final button = find.byKey(
              const ValueKey('collection-download-all'),
            );
            await tester.ensureVisible(button);
            await tester.tap(button);
          } else {
            tester
                .widget<CollectionHeaderActions>(
                  find.byType(CollectionHeaderActions),
                )
                .onDownloadAll();
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          final dialog = find.byType(AlertDialog);
          await tester.tap(
            find.descendant(of: dialog, matching: find.text('Download')),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
        }

        await submitPlaylist();
        expect(find.text('3 pending'), findsOneWidget);
        final batch = queue._items
            .where((item) => queue._admittedIds.contains(item.id))
            .toList();
        queue.replaceItems([
          foreign,
          batch[0].copyWith(status: DownloadStatus.failed),
          batch[1].copyWith(status: DownloadStatus.skipped),
          batch[2].copyWith(
            status: DownloadStatus.downloading,
            errorType: DownloadErrorType.verificationRequired,
          ),
        ]);
        await tester.pump();
        expect(find.text('1 failed'), findsOneWidget);
        expect(find.text('1 skipped'), findsOneWidget);
        expect(find.text('1 awaiting verification'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.liveRegion == true &&
                widget.properties.label ==
                    'Waiting for verification... Download failed',
          ),
          findsOneWidget,
        );
        expect(find.byType(SnackBar), findsNothing);
        expect(find.widgetWithText(TextButton, 'View Queue'), findsNothing);
        expect(opened, isEmpty);

        await submitPlaylist();
        expect(find.text('3 pending'), findsOneWidget);
        expect(find.text('1 failed'), findsNothing);
        final latest = queue._items.where(
          (item) => queue._admittedIds.contains(item.id),
        );
        queue.replaceItems([
          foreign,
          ...latest.map(
            (item) => item.copyWith(status: DownloadStatus.completed),
          ),
        ]);
        await tester.pump();
        expect(find.text('3 pending'), findsNothing);
        expect(find.byType(SnackBar), findsNothing);
        queue.replaceItems([
          foreign,
          latest.first.copyWith(status: DownloadStatus.failed),
        ]);
        await tester.pump();
        expect(find.text('1 failed'), findsNothing);
        queue.replaceItems([foreign]);
        await tester.pump();
        expect(find.text('3 pending'), findsNothing);
        expect(find.text('1 failed'), findsNothing);
      },
    );
  }

  testWidgets('batch compares physical copies instead of history membership', (
    tester,
  ) async {
    final root = Directory.systemTemp.createTempSync('batch-download-');
    final previousPaths = PathProviderPlatform.instance;
    final previousFactory = databaseFactoryOrNull;
    PathProviderPlatform.instance = _Paths(root.path);
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    addTearDown(() async {
      await HistoryDatabase.instance.close();
      databaseFactory = previousFactory;
      PathProviderPlatform.instance = previousPaths;
      await root.delete(recursive: true);
    });
    Track track(String id, {String? isrc}) => Track(
      id: id,
      source: 'spotify',
      isrc: isrc,
      name: 'Song $id',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    );
    final missing = track('missing');
    final inventory = track('inventory');
    final older = track('older');
    final revoked = track('revoked');
    final missingSaf = track('missing-saf');
    final readableSaf = track('readable-saf');
    final unknownSizeSaf = track('unknown-size-saf');
    final emptySaf = track('empty-saf');
    final historyIsrc = track('history-isrc', isrc: 'USAAA2600003');
    final conflicting = track('conflicting', isrc: 'USAAA2600001');
    final selection = [
      missing,
      inventory,
      older,
      revoked,
      missingSaf,
      readableSaf,
      unknownSizeSaf,
      emptySaf,
      historyIsrc,
      conflicting,
    ];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    var unrelatedWrites = 0;
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.zarz.mornye/backend'),
      (call) async {
        final uri = (call.arguments as Map)['uri'];
        if (call.method == 'safCanOpenRead') {
          return uri == 'content://storage/document/readable';
        }
        if (call.method != 'safStat') throw MissingPluginException();
        if (uri == 'content://storage/document/empty') {
          return '{"exists": true, "size": 0}';
        }
        if (uri == 'content://storage/document/unknown-size') {
          return '{"exists": true, "size": null}';
        }
        if (uri == 'content://storage/document/readable') {
          return '{"exists": true, "size": 10}';
        }
        if (uri == 'content://storage/document/missing') {
          for (var index = 0; index < 2; index++) {
            await DownloadFileInventory.record(
              track('other-$index'),
              '${root.path}/unrelated-$index.mp3',
            );
            unrelatedWrites++;
          }
          return '{"exists": false}';
        }
        throw PlatformException(
          code: 'SECURITY',
          message: 'Permission revoked',
        );
      },
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('com.zarz.mornye/backend'),
        null,
      ),
    );
    Future<void> saveHistory(Track track, String id, String path, int day) =>
        HistoryDatabase.instance.upsert(
          DownloadHistoryItem(
            id: id,
            spotifyId: track.id,
            isrc: track.isrc,
            trackName: track.name,
            artistName: track.artistName,
            albumName: track.albumName,
            filePath: path,
            service: 'example',
            downloadedAt: DateTime.utc(2026, 1, day),
          ).toJson(),
        );

    final queue = _Queue();
    final settings = _DedupSettings();
    Future<void>? action;
    await tester.runAsync(() async {
      DownloadFileInventory.resetWritesForTest();
      HistoryDatabase.discardConnectionForTest();
      final album = await Directory('${root.path}/deleted-album').create();
      final deleted = await File('${album.path}/deleted.mp3').writeAsBytes([1]);
      await saveHistory(missing, 'deleted', deleted.path, 1);
      await album.delete(recursive: true);
      final inventoried = await File(
        '${root.path}/inventory.mp3',
      ).writeAsBytes([2]);
      await DownloadFileInventory.record(inventory, inventoried.path);
      final readable = await File('${root.path}/older.mp3').writeAsBytes([3]);
      await saveHistory(
        track('different-provider-id', isrc: 'US-AAA 26-00003'),
        'formatted-isrc',
        readable.path,
        1,
      );
      final boundary = await HistoryDatabase.instance.findTrackCandidatesBatch([
        for (var index = 0; index < 150; index++)
          historyLookupForTrack(track('unmatched-$index')),
        historyLookupForTrack(historyIsrc),
      ]);
      expect(boundary.take(150), everyElement(isEmpty));
      expect(boundary.last.single['id'], 'formatted-isrc');
      await saveHistory(older, 'older', readable.path, 1);
      final differentRecording = track('conflicting', isrc: 'USAAA2600002');
      await saveHistory(differentRecording, 'different-isrc', readable.path, 1);
      final differentFile = await readable.copy('${root.path}/different.mp3');
      await DownloadFileInventory.record(
        differentRecording,
        differentFile.path,
      );
      await saveHistory(older, 'newer', '${root.path}/newer.mp3', 2);
      await saveHistory(revoked, 'revoked', 'content://storage/document/1', 1);
      for (final (track, id) in [
        (unknownSizeSaf, 'unknown-size'),
        (emptySaf, 'empty'),
      ]) {
        await saveHistory(track, id, 'content://storage/document/$id', 1);
      }
      await saveHistory(
        readableSaf,
        'readable-saf',
        'content://storage/document/readable',
        1,
      );
      await saveHistory(
        missingSaf,
        'missing-saf',
        'content://storage/document/missing',
        1,
      );
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => settings),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => action = queueTracksSkippingDownloaded(
                  context,
                  ref,
                  selection,
                  artistNameForPicker: 'Artist',
                  playlistName: 'Playlist',
                ),
                child: const Text('Batch'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Batch'));
      await action;
      expect(await HistoryDatabase.instance.getById('revoked'), isNotNull);
      expect(await HistoryDatabase.instance.getById('unknown-size'), isNotNull);
      expect(await HistoryDatabase.instance.getById('empty'), isNotNull);
      expect(
        await savedDownloadFileAccessible(
          'content://storage/document/unknown-size',
        ),
        isFalse,
      );
      expect(
        await savedDownloadFileAccessible('content://storage/document/empty'),
        isFalse,
      );
    });
    await tester.pumpAndSettle();
    expect(unrelatedWrites, 2);
    expect(queue.batches.single.map((track) => track.id), [
      missing.id,
      missingSaf.id,
      conflicting.id,
    ]);
    expect(
      find.text(
        'File is currently unavailable. Check storage access and try again.',
      ),
      findsOneWidget,
    );

    await tester.runAsync(() async {
      settings.setAllowQualityVariants(true);
      await tester.tap(find.text('Batch'));
      await action;
      expect(queue.batches.last, selection);

      settings.setAllowQualityVariants(false);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('download_file_inventory_v1', 'invalid JSON');
      await tester.tap(find.text('Batch'));
      await action;
      expect(queue.batches, hasLength(2));
    });
  });
  testWidgets('single and batch downloads enqueue without a snackbar', (
    tester,
  ) async {
    final queue = _Queue();
    final track = Track(
      id: '1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
          downloadQueueProvider.overrideWith(() => queue),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => Column(
                children: [
                  TextButton(
                    onPressed: () => downloadSingleTrack(context, ref, track),
                    child: const Text('Single'),
                  ),
                  TextButton(
                    onPressed: () => queueTracksSkippingDownloaded(
                      context,
                      ref,
                      [track, track],
                      artistNameForPicker: 'Artist',
                    ),
                    child: const Text('Batch'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Single'));
    await tester.pumpAndSettle();
    expect(queue.singles, [track]);
    expect(find.byType(SnackBar), findsNothing);
    await tester.tap(find.text('Batch'));
    await tester.pumpAndSettle();
    expect(queue.batches.single, [track, track]);
    expect(find.byType(SnackBar), findsNothing);
  });
}
