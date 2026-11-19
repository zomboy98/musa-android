import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/screens/track_metadata_screen.dart';
import 'package:mornye/services/downloaded_embedded_cover_resolver.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/mornye_context_menu.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.viewMode, {this.filterMode = 'all'});

  final String viewMode;
  final String filterMode;

  // The Rewind banner animates for as long as it is shown; keep it off so
  // the page settles.
  @override
  AppSettings build() => AppSettings(
    defaultLibraryView: filterMode,
    historyFilterMode: filterMode,
    historyViewMode: viewMode,
    listeningStatisticsEnabled: false,
  );
}

/// Two downloaded songs. With a queue item present and the database page
/// empty, the Library renders this in-memory snapshot.
class _History extends DownloadHistoryNotifier {
  _History({this.withQuality = false});

  final bool withQuality;
  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      for (final (index, name) in ['Bravo', 'Alpha'].indexed)
        DownloadHistoryItem(
          id: 'song-$index',
          trackName: name,
          artistName: 'Artist',
          albumName: 'Album $index',
          filePath: '/music/$name.flac',
          service: 'example-provider',
          quality: withQuality ? 'HI_RES' : null,
          bitDepth: withQuality ? 24 : null,
          sampleRate: withQuality ? 192000 : null,
          downloadedAt: DateTime(2026, 1, 10 + index),
        ),
    ],
    totalCount: 2,
  );
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections({this.withPlaylistTracks = false});

  final bool withPlaylistTracks;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      if (withPlaylistTracks)
        UserPlaylistCollection(
          id: 'playlist',
          name: 'Playlist',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tracks: const [],
          tracksLoaded: false,
          trackKeys: {'example-provider:song-0', 'example-provider:song-1'},
        ),
    ],
  );
}

class _Queue extends DownloadQueueNotifier {
  _Queue([this.pending]);

  final DownloadItem? pending;

  @override
  DownloadQueueState build() =>
      const DownloadQueueState().copyWith(items: [?pending], isPaused: true);

  void complete(String? path) {
    state = state.copyWith(
      items: [
        pending!.copyWith(status: DownloadStatus.completed, filePath: path),
      ],
    );
  }
}

class _Playback extends PlaybackController {
  final started = <String>[];

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
    started.add(path);
  }

  @override
  Future<void> playMediaQueue(
    Iterable<PlayableMedia> queue, {
    required int startIndex,
    required String externalPath,
    String? playlistId,
  }) async {
    started.add(externalPath);
  }
}

/// The Library's database page keeps a loading indicator spinning, so this
/// settles with bounded pumps.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryMouseButton,
  );
  await gesture.up();
  await _settle(tester);
}

Future<void> _openDetails(
  WidgetTester tester,
  Finder menuItem, {
  required String expectedId,
}) async {
  final screen = find.byType(TrackMetadataScreen);
  await tester.tap(menuItem);
  // Metadata navigation preflights artwork and file stats using real I/O.
  for (var attempt = 0; attempt < 20 && screen.evaluate().isEmpty; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(screen, findsOneWidget);
  expect(tester.widget<TrackMetadataScreen>(screen).item?.id, expectedId);
  await _settle(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    final previewCache = Directory.systemTemp.createTempSync(
      'mornye-menu-art-',
    );
    DownloadedEmbeddedCoverResolver.setPersistentCacheDirectoryForTesting(
      previewCache,
    );
    addTearDown(() => previewCache.deleteSync());
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    final previousFactory = databaseFactoryOrNull;
    databaseFactory = databaseFactorySqflitePlugin;
    addTearDown(() => databaseFactory = previousFactory);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    messenger.setMockMethodCallHandler(paths, (_) async => '/test/documents');
    addTearDown(() => messenger.setMockMethodCallHandler(paths, null));
    // An empty database: every page query returns no rows.
    const sqlite = MethodChannel('com.tekartik.sqflite');
    final versions = <int, int>{};
    messenger.setMockMethodCallHandler(sqlite, (call) async {
      final args = (call.arguments as Map?) ?? {};
      if (call.method == 'openDatabase') {
        final id = versions.length + 1;
        versions[id] = (args['path'] as String).endsWith('history.db')
            ? HistoryDatabase.schemaVersion
            : LibraryDatabase.schemaVersion;
        return {'id': id};
      }
      final sql = args['sql'] as String? ?? '';
      if (call.method == 'execute' && sql.contains('CREATE VIRTUAL TABLE')) {
        throw PlatformException(code: 'sqlite_error', message: 'no fts5');
      }
      if (call.method != 'query') return null;
      if (sql.toLowerCase().contains('pragma user_version')) {
        return {
          'columns': ['user_version'],
          'rows': [
            [versions[args['id']]],
          ],
        };
      }
      return {'columns': <String>[], 'rows': <List<Object?>>[]};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(sqlite, null));
  });
  tearDown(() => debugDesktopPlatformOverride = null);

  Future<void> pumpLibrary(
    WidgetTester tester, {
    required bool desktop,
    bool mornye = false,
    String viewMode = 'list',
    String filterMode = 'all',
    bool withPlaylistTracks = false,
    bool root = false,
    PlaybackController? playback,
    _Queue? activeQueue,
    bool largeText = false,
  }) async {
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = desktop
        ? const Size(1280, 900)
        : Size(largeText ? 320 : 390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = DownloadQueueLookup.fromItems([
      DownloadItem(
        id: 'completed',
        track: const Track(
          id: 'song',
          name: 'Song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1000,
        ),
        service: 'example-provider',
        status: DownloadStatus.completed,
        createdAt: DateTime(2026),
      ),
    ]);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(viewMode, filterMode: filterMode),
          ),
          downloadHistoryProvider.overrideWith(
            () => _History(withQuality: largeText),
          ),
          libraryDirectoryItemsLoaderProvider.overrideWith(
            (ref) => (tracks) async {
              final ids = tracks.map((track) => track.itemId).toSet();
              return [
                for (final item in ref.read(downloadHistoryProvider).items)
                  if (ids.contains('dl_${item.id}'))
                    UnifiedLibraryItem.fromDownloadHistory(item),
              ];
            },
          ),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(
            () => _Collections(withPlaylistTracks: withPlaylistTracks),
          ),
          downloadQueueProvider.overrideWith(() => activeQueue ?? _Queue()),
          if (activeQueue == null)
            downloadQueueLookupProvider.overrideWithValue(queue),
          if (playback != null) playbackProvider.overrideWith(() => playback),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: largeText
              ? (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: TextScaler.linear(2)),
                  child: child!,
                )
              : null,
          // Mornye opens Songs as a section page from its Library root.
          home: Scaffold(
            body: QueueTab(librarySection: mornye && !root ? filterMode : null),
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  for (final viewMode in ['list', 'grid']) {
    testWidgets('phone song title starts playback in $viewMode', (
      tester,
    ) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: false,
        viewMode: viewMode,
        playback: playback,
      );
      await tester.tap(find.text('Alpha'));
      await _settle(tester);
      expect(playback.started, ['/music/Alpha.flac']);

      final row = find.ancestor(
        of: find.text('Alpha'),
        matching: find.byType(viewMode == 'list' ? TrackCard : TrackGridCard),
      );
      final context = tester.element(row);
      final menu = find.descendant(
        of: row,
        matching: find.byTooltip(
          MaterialLocalizations.of(context).showMenuTooltip,
        ),
      );
      await tester.tap(menu);
      await _settle(tester);
      final details = find.text(context.l10n.nowPlayingDetails);
      await _openDetails(tester, details, expectedId: 'song-1');
      expect(playback.started, ['/music/Alpha.flac']);
      Navigator.of(tester.element(find.byType(TrackMetadataScreen))).pop();
      await _settle(tester);

      await tester.longPress(find.text('Alpha'));
      await _settle(tester);
      expect(menu, findsNothing);
      expect(playback.started, ['/music/Alpha.flac']);
    });
  }

  testWidgets('narrow phone rows fit a large font and retain actions', (
    tester,
  ) async {
    final playback = _Playback();
    await pumpLibrary(
      tester,
      desktop: false,
      largeText: true,
      playback: playback,
    );
    expect(tester.takeException(), isNull);
    final title = find.text('Alpha');
    await tester.tap(title);
    await _settle(tester);
    expect(playback.started, ['/music/Alpha.flac']);
    await tester.longPress(title);
    await _settle(tester);
    expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final readable in [true, false, null]) {
    testWidgets(
      'completed download keeps its library details (SAF availability: $readable)',
      (tester) async {
        const uri = 'content://storage/document/download%3Asong.flac';
        const channel = MethodChannel('com.zarz.mornye/backend');
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'safExists') {
            return readable == true && call.arguments['uri'] == uri;
          }
          if (call.method == 'getSafFileModTimes') return <String, int>{};
          if (call.method == 'extractCoverToFile') return {'error': 'no cover'};
          if (call.method == 'safStat') return {'size': 1234};
          if (call.method == 'readFileMetadata') return <String, Object?>{};
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

        final playback = _Playback();
        final queue = _Queue(
          DownloadItem(
            id: 'bridge-download',
            track: const Track(
              id: 'bridge-track',
              name: 'Fresh download',
              artistName: 'Artist',
              albumName: 'Album',
              duration: 1000,
            ),
            service: 'example-provider',
            createdAt: DateTime(2026),
          ),
        );
        await pumpLibrary(
          tester,
          desktop: false,
          playback: playback,
          activeQueue: queue,
        );

        queue.complete(readable == null ? null : uri);
        await _settle(tester);
        if (readable == false) {
          for (var retry = 0; retry < 4; retry++) {
            await tester.pump(const Duration(milliseconds: 2200));
          }
          await _settle(tester);
        }
        final title = find.text('Fresh download');
        final row = find.ancestor(of: title, matching: find.byType(TrackCard));
        final context = tester.element(row);
        await tester.tap(title);
        await _settle(tester);

        expect(playback.started, readable == true ? [uri] : isEmpty);
        if (readable == false) {
          expect(
            find.text(context.l10n.queueDownloadedFileMissing),
            findsOneWidget,
          );
        }

        final menu = find.descendant(
          of: row,
          matching: find.byTooltip(
            MaterialLocalizations.of(context).showMenuTooltip,
          ),
        );
        await tester.tap(menu);
        await _settle(tester);
        final details = find.text(context.l10n.nowPlayingDetails);
        expect(details, findsOneWidget);
        if (readable != false) {
          await _openDetails(tester, details, expectedId: 'bridge-download');
        }
        expect(playback.started, readable == true ? [uri] : isEmpty);
      },
    );
  }

  for (final mornye in [false, true]) {
    testWidgets('desktop Songs list is the songs table (mornye: $mornye)', (
      tester,
    ) async {
      await pumpLibrary(tester, desktop: true, mornye: mornye);
      expect(find.byType(SliverTrackTable), findsOneWidget);
      expect(find.byType(TrackCard), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      // No month sections: the table sorts through its header instead.
      expect(find.text('January 2026'), findsNothing);
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      await tester.tap(find.text(l10n.editMetadataFieldTitle));
      await _settle(tester);
      final preferences = await SharedPreferences.getInstance();
      expect(loadBootstrapSettings(preferences).historySortMode, 'a-z');
    });

    testWidgets('a right-click menu leaves the selection toolbar closed '
        '(mornye: $mornye)', (tester) async {
      final playback = _Playback();
      await pumpLibrary(
        tester,
        desktop: true,
        mornye: mornye,
        playback: playback,
      );
      final toolbar = find.byType(LibraryTrackSelectionBar);
      Finder menuRow(String label) => find.descendant(
        of: find.byType(mornye ? MornyeContextMenu : MenuItemButton),
        matching: find.text(label),
      );

      // The menu acts on the song without opening the toolbar under it,
      // and closing the menu ends that selection.
      await _rightClick(tester, find.text('Alpha'));
      expect(menuRow('Play next'), findsOneWidget);
      expect(toolbar, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(menuRow('Play next'), findsNothing);
      expect(toolbar, findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settle(tester);
      expect(toolbar, findsNothing);

      await _rightClick(tester, find.text('Alpha'));
      await tester.tap(menuRow('Play'));
      await _settle(tester);
      expect(playback.started, ['/music/Alpha.flac']);
      expect(toolbar, findsNothing);

      // A bulk action keeps the selection, so the toolbar returns.
      await _rightClick(tester, find.text('Bravo'));
      await tester.tap(menuRow('Delete 1 track'));
      await _settle(tester);
      expect(toolbar, findsOneWidget);
    });
  }

  testWidgets('desktop Songs grid keeps the cover grid', (tester) async {
    await pumpLibrary(tester, desktop: true, viewMode: 'grid');
    expect(find.byType(SliverTrackTable), findsNothing);
    expect(find.text('Alpha'), findsOneWidget);
  });

  testWidgets('phones keep the sectioned song cards', (tester) async {
    await pumpLibrary(tester, desktop: false);
    expect(find.byType(SliverTrackTable), findsNothing);
    expect(find.byType(TrackCard), findsNWidgets(2));
    expect(find.text('January 2026'), findsOneWidget);
  });

  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      for (final viewMode in mornye ? ['list'] : ['list', 'grid']) {
        for (final mode in ['all', 'singles']) {
          testWidgets(
            'playlist members remain visible '
            '(desktop: $desktop, mornye: $mornye, view: $viewMode, mode: $mode)',
            (tester) async {
              await pumpLibrary(
                tester,
                desktop: desktop,
                mornye: mornye,
                viewMode: viewMode,
                filterMode: mode,
                withPlaylistTracks: true,
              );
              expect(find.text('2 tracks'), findsWidgets);
              expect(find.text('Alpha'), findsOneWidget);
              expect(find.text('Bravo'), findsOneWidget);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }

  testWidgets(
    'switching from Mornye to Material keeps playlist songs visible',
    (tester) async {
      await pumpLibrary(
        tester,
        desktop: false,
        mornye: true,
        root: true,
        withPlaylistTracks: true,
      );
      expect(find.byType(MornyeLibraryScreen), findsOneWidget);
      await pumpLibrary(
        tester,
        desktop: false,
        viewMode: 'grid',
        withPlaylistTracks: true,
      );
      expect(find.byType(MornyeLibraryScreen), findsNothing);
      expect(find.text('2 tracks'), findsOneWidget);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Downloaded lists finished files without a queue or nested collections',
    (tester) async {
      final pending = DownloadItem(
        id: 'pending',
        track: const Track(
          id: 'queued',
          name: 'Queued song',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1000,
        ),
        service: 'example-provider',
        status: DownloadStatus.queued,
        createdAt: DateTime(2026),
      );
      await pumpLibrary(
        tester,
        desktop: false,
        mornye: true,
        withPlaylistTracks: true,
        activeQueue: _Queue(pending),
      );
      // The page is the "Downloaded" collection: files already on the device.
      expect(find.text('Downloaded'), findsWidgets);
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Bravo'), findsOneWidget);
      // The download queue is not listed: no group header, no queued rows and
      // no retry, pause or clear controls.
      expect(find.byKey(const ValueKey('dl_header')), findsNothing);
      expect(find.text('Queued song'), findsNothing);
      expect(find.byIcon(Icons.clear_all_rounded), findsNothing);
      expect(find.byIcon(Icons.pause_rounded), findsNothing);
      expect(find.byIcon(Icons.replay_rounded), findsNothing);
      // Playlists and favorites are entries of the library home, never
      // folders nested in this song list.
      expect(find.text('Playlist'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
