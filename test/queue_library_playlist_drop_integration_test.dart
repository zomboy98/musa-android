import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/library_playlist_drag_source.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/library_playlist_drag_batch.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_directory_provider.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/app_alert_dialog.dart';
import 'package:mornye/widgets/desktop/desktop_selection.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/library_selection_playback_actions.dart';
import 'package:mornye/providers/library_query_selection_provider.dart';
import 'package:mornye/widgets/batch_convert_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);

  final AppSettings? initial;

  // The Rewind banner animates for as long as it is shown; keep it off so
  // the page settles.
  @override
  AppSettings build() =>
      initial ??
      const AppSettings(
        defaultLibraryView: 'all',
        historyViewMode: 'list',
        listeningStatisticsEnabled: false,
      );
}

/// Downloaded songs added on [dates]. With a queue item present and the
/// database page empty, the Library renders this in-memory snapshot.
class _History extends DownloadHistoryNotifier {
  _History(this.dates);

  final List<DateTime> dates;

  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      for (final (index, date) in dates.indexed)
        DownloadHistoryItem(
          id: 'song-$index',
          trackName: 'Song $index',
          artistName: 'Artist',
          albumName: 'Album $index',
          filePath: '/music/song-$index.${index == 0 ? 'flac' : 'mp3'}',
          format: index == 0 ? 'flac' : 'mp3',
          service: 'example-provider',
          downloadedAt: date,
        ),
    ],
    totalCount: dates.length,
  );
}

class _Local extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Collections extends LibraryCollectionsNotifier {
  _Collections(this.playlists, _SavedRows db) : super(database: db);

  final List<UserPlaylistCollection> playlists;

  @override
  LibraryCollectionsState build() =>
      LibraryCollectionsState(isLoaded: true, playlists: playlists);
}

/// Exercise the real notifier's batch preparation/write/publication path.
class _SavedRows implements LibraryCollectionsDatabase {
  final rows = <Map<String, String>>[];

  @override
  Future<void> upsertPlaylistTracksBatch({
    required String playlistId,
    required String playlistUpdatedAt,
    required List<Map<String, String>> tracks,
  }) async {
    for (final track in tracks) {
      rows.removeWhere((row) => row['track_key'] == track['track_key']);
      rows.add(Map.of(track));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Queue extends DownloadQueueNotifier {
  @override
  DownloadQueueState build() => DownloadQueueState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final queries = <String>[];
  late _SavedRows saved;
  var queryRows = 2;
  var paginated = false;
  var failCounts = false;
  var countFailures = 0;
  var duplicatePageBoundary = false;
  var secondPageQueries = 0;
  var selectionModelLoads = 0;
  var failSelectionLoad = false;
  String? missingSelectionId;
  Future<List<String>> Function(QueueLibraryDbQuery)? queryIdsOverride;

  setUp(() {
    queries.clear();
    queryRows = 2;
    paginated = false;
    failCounts = false;
    countFailures = 0;
    duplicatePageBoundary = false;
    secondPageQueries = 0;
    selectionModelLoads = 0;
    failSelectionLoad = false;
    missingSelectionId = null;
    queryIdsOverride = null;
    saved = _SavedRows();
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
      queries.add(sql);
      if (sql.toLowerCase().contains('pragma user_version')) {
        return {
          'columns': ['user_version'],
          'rows': [
            [versions[args['id']]],
          ],
        };
      }
      if (paginated && sql.contains('COALESCE(SUM(all_count)')) {
        if (failCounts) {
          countFailures++;
          throw PlatformException(
            code: 'sqlite_error',
            message: 'count failed',
          );
        }
        return {
          'columns': ['all_count', 'album_count', 'single_count'],
          'rows': [
            [queryRows, 0, queryRows],
          ],
        };
      }
      if (sql.contains('AS unified_id') &&
          sql.trimLeft().startsWith('SELECT *')) {
        final formats = (args['arguments'] as List?) ?? const [];
        final offset = paginated && sql.contains('OFFSET ?')
            ? (formats.last as int)
            : 0;
        if (offset >= 300) secondPageQueries++;
        final filtered = formats.any(
          (value) => value.toString().toLowerCase().contains('flac'),
        );
        final columns = [
          'queue_source',
          'unified_id',
          'id',
          'track_name',
          'artist_name',
          'album_name',
          'file_path',
          'service',
          'downloaded_at',
          'format',
          'sort_added',
          'sort_track',
        ];
        return {
          'columns': columns,
          'rows': [
            for (final i
                in filtered
                    ? [0]
                    : List.generate(
                        paginated
                            ? (queryRows - offset).clamp(0, 300)
                            : queryRows,
                        (i) =>
                            i +
                            offset -
                            (duplicatePageBoundary && offset >= 300 ? 1 : 0),
                      ))
              [
                'downloaded',
                'dl_song-$i',
                'song-$i',
                'Song $i',
                'Artist',
                'Album $i',
                '/music/song-$i.${i == 0 ? 'flac' : 'mp3'}',
                'example-provider',
                '2026-01-01T00:00:00.000',
                i == 0 ? 'flac' : 'mp3',
                1767225600000,
                'song $i',
              ],
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
    bool desktop = false,
    bool mornye = false,
    bool reduceMotion = false,
    List<DateTime>? dates,
    List<UserPlaylistCollection> playlists = const [],
    bool withQueueItem = true,
    bool manual = false,
    bool grid = false,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    debugDesktopPlatformOverride = desktop;
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final queue = DownloadQueueLookup.fromItems([
      if (withQueueItem)
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
        retry: (_, _) => null,
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(
              manual
                  ? AppSettings(
                      defaultLibraryView: 'all',
                      historyViewMode: grid ? 'grid' : 'list',
                      historySortMode: 'manual',
                      listeningStatisticsEnabled: false,
                    )
                  : hasPersistedAppSettings(preferences)
                  ? loadBootstrapSettings(preferences)
                  : null,
            ),
          ),
          downloadHistoryProvider.overrideWith(
            () => _History(dates ?? [DateTime(2026, 1, 10)]),
          ),
          localLibraryProvider.overrideWith(_Local.new),
          libraryCollectionsProvider.overrideWith(
            () => _Collections(playlists, saved),
          ),
          libraryDirectoryItemsLoaderProvider.overrideWith(
            (ref) => (tracks) async {
              selectionModelLoads++;
              if (failSelectionLoad)
                throw StateError('selection lookup failed');
              final ids = tracks.map((e) => e.itemId).toSet();
              return [
                for (final item in ref.read(downloadHistoryProvider).items)
                  if (ids.contains('dl_${item.id}') &&
                      missingSelectionId != 'dl_${item.id}')
                    UnifiedLibraryItem.fromDownloadHistory(item),
              ];
            },
          ),
          libraryQueryIdsLoaderProvider.overrideWith(
            (ref) =>
                (query) async => queryIdsOverride != null
                ? queryIdsOverride!(query)
                : [for (var i = 0; i < queryRows; i++) 'dl_song-$i'],
          ),
          downloadQueueProvider.overrideWith(_Queue.new),
          downloadQueueLookupProvider.overrideWithValue(queue),
        ],
        child: MaterialApp(
          theme: mornye
              ? MornyeTheme.build(Brightness.light)
              : AppTheme.light(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          // Mornye opens Songs as a section page from its Library root.
          home: const Scaffold(body: QueueTab(librarySection: 'all')),
        ),
      ),
    );
    // A loading indicator spins while the database page is pending, so the
    // page never settles; pump for a bounded time instead.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> selectEntireQuery(WidgetTester tester) async {
    paginated = true;
    queryRows = 1000;
    await pumpLibrary(
      tester,
      dates: [for (var i = 0; i < queryRows; i++) DateTime(2026, 1, 1)],
    );
    tester
        .widget<DesktopListScope>(find.byType(DesktopListScope))
        .onSelectAll!();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
    final bar = tester.widget<LibraryTrackSelectionBar>(
      find.byType(LibraryTrackSelectionBar),
    );
    expect(bar.selectedCount, 1000);
    expect(bar.allSelected, isTrue);
    expect(selectionModelLoads, 0);
    expect(secondPageQueries, 0);
  }

  testWidgets('whole-query selection toggles without hydrating songs', (
    tester,
  ) async {
    await selectEntireQuery(tester);
    tester
        .widget<LibraryTrackSelectionBar>(find.byType(LibraryTrackSelectionBar))
        .onToggleSelectAll();
    await tester.pump();
    expect(find.byType(LibraryTrackSelectionBar), findsNothing);
  });

  testWidgets('late select-all cannot reopen a cancelled selection', (
    tester,
  ) async {
    await selectEntireQuery(tester);
    final pending = Completer<List<String>>();
    queryIdsOverride = (_) => pending.future;
    tester
        .widget<DesktopListScope>(find.byType(DesktopListScope))
        .onSelectAll!();
    tester
        .widget<LibraryTrackSelectionBar>(find.byType(LibraryTrackSelectionBar))
        .onClose();
    pending.complete(['dl_song-0']);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(LibraryTrackSelectionBar), findsNothing);
    expect(selectionModelLoads, 0);
  });

  testWidgets('failed select-all preserves the existing complete selection', (
    tester,
  ) async {
    await selectEntireQuery(tester);
    queryIdsOverride = (_) async => throw StateError('query failed');
    tester
        .widget<DesktopListScope>(find.byType(DesktopListScope))
        .onSelectAll!();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(
      tester
          .widget<LibraryTrackSelectionBar>(
            find.byType(LibraryTrackSelectionBar),
          )
          .selectedCount,
      1000,
    );
    expect(
      find.text('Could not select all songs. Please try again.'),
      findsOneWidget,
    );
  });

  testWidgets(
    'playback actions load every selected song before becoming available',
    (tester) async {
      await selectEntireQuery(tester);
      expect(find.byType(LibrarySelectionPlaybackActions), findsNothing);
      await tester.tap(find.text('Load actions for all 1000 selected songs'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(selectionModelLoads, 1);
      final actions = tester.widget<LibrarySelectionPlaybackActions>(
        find.byType(LibrarySelectionPlaybackActions),
      );
      expect(actions.items.length, 1000);
      expect(actions.items.map((item) => item.id).toSet().length, 1000);
    },
  );

  testWidgets('delete confirmation includes every selected song', (
    tester,
  ) async {
    await selectEntireQuery(tester);
    tester
        .widget<LibraryTrackSelectionBar>(find.byType(LibraryTrackSelectionBar))
        .onDelete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(selectionModelLoads, 1);
    expect(find.byType(AppAlertDialog), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppAlertDialog),
        matching: find.textContaining('1000'),
      ),
      findsOneWidget,
    );
  });

  testWidgets(
    'delete revalidates rows after actions have already been cached',
    (tester) async {
      await selectEntireQuery(tester);
      await tester.tap(find.text('Load actions for all 1000 selected songs'));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(selectionModelLoads, 1);
      missingSelectionId = 'dl_song-999';
      tester
          .widget<LibraryTrackSelectionBar>(
            find.byType(LibraryTrackSelectionBar),
          )
          .onDelete();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(selectionModelLoads, 2);
      expect(find.byType(AppAlertDialog), findsNothing);
      expect(
        find.text('Could not load all selected songs. Please try again.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LibraryTrackSelectionBar>(
              find.byType(LibraryTrackSelectionBar),
            )
            .selectedCount,
        1000,
      );
    },
  );

  testWidgets(
    'conversion resolves the whole selection and stops on lookup failure',
    (tester) async {
      await selectEntireQuery(tester);
      failSelectionLoad = true;
      tester
          .widget<LibraryTrackSelectionBar>(
            find.byType(LibraryTrackSelectionBar),
          )
          .onConvert();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(selectionModelLoads, 1);
      expect(
        find.text('Could not load all selected songs. Please try again.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LibraryTrackSelectionBar>(
              find.byType(LibraryTrackSelectionBar),
            )
            .selectedCount,
        1000,
      );
      failSelectionLoad = false;
      tester
          .widget<LibraryTrackSelectionBar>(
            find.byType(LibraryTrackSelectionBar),
          )
          .onConvert();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(selectionModelLoads, 2);
      expect(find.byType(BatchConvertSheet), findsOneWidget);
      expect(
        tester
            .widget<BatchConvertSheet>(find.byType(BatchConvertSheet))
            .confirmLabel,
        contains('1000'),
      );
    },
  );

  testWidgets('manual drop uses the row under the released pointer', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: [now, now]);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('Song 1')));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('Confirm move'), findsOneWidget);
    expect(find.textContaining('before Song 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed counts never expose the global end target', (
    tester,
  ) async {
    queryRows = 310;
    paginated = true;
    failCounts = true;
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: List.filled(queryRows, now));
    expect(countFailures, greaterThan(0));
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('manual_library_end_drop')), findsNothing);
    await gesture.cancel();
    await tester.pump();
  });

  testWidgets('simultaneous row drags cannot replace the active batch', (
    tester,
  ) async {
    queryRows = 3;
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      manual: true,
      dates: List.filled(3, now),
      playlists: [
        UserPlaylistCollection(
          id: 'target',
          name: 'Target playlist',
          createdAt: now,
          updatedAt: now,
          tracks: const [],
        ),
      ],
    );
    final first = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
      pointer: 1,
    );
    final second = await tester.startGesture(
      tester.getCenter(find.text('Song 1')),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await second.moveTo(tester.getCenter(find.text('Target playlist')));
    await second.up();
    await tester.pump();
    expect(find.text('Confirm move'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(saved.rows, isEmpty);
    await first.moveTo(tester.getCenter(find.text('Song 2')));
    await first.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('Move 1 songs before Song 2'), findsOneWidget);
  });

  for (final desktop in [false, true]) {
    testWidgets(
      'frozen batch member remains ineligible after deselection (desktop: $desktop)',
      (tester) async {
        final now = DateTime(2026);
        await pumpLibrary(
          tester,
          manual: true,
          desktop: desktop,
          dates: [now, now, now],
        );
        for (final song in ['Song 0', 'Song 1']) {
          if (desktop) {
            final row = tester.widget<ManualLibraryDragRow>(
              find
                  .ancestor(
                    of: find.text(song),
                    matching: find.byType(ManualLibraryDragRow),
                  )
                  .first,
            );
            tester
                .widget<SliverTrackTable>(find.byType(SliverTrackTable))
                .onSelect(row.id, DesktopClick.toggle, [row.id]);
            await tester.pump();
          } else {
            final gesture = await tester.startGesture(
              tester.getCenter(find.text(song)),
            );
            await tester.pump(const Duration(milliseconds: 600));
            await gesture.up();
            await tester.pump(const Duration(milliseconds: 200));
          }
        }
        final drag = await tester.startGesture(
          tester.getCenter(find.text('Song 0')),
          pointer: 10,
        );
        await tester.pump(const Duration(milliseconds: 600));
        if (desktop) {
          final target = tester.widget<ManualLibraryDragRow>(
            find
                .ancestor(
                  of: find.text('Song 1'),
                  matching: find.byType(ManualLibraryDragRow),
                )
                .first,
          );
          expect(target.selected, isTrue);
          tester
              .widget<SliverTrackTable>(find.byType(SliverTrackTable))
              .onSelect(target.id, DesktopClick.toggle, [target.id]);
        } else {
          await tester.tap(find.text('Song 1'), pointer: 11);
        }
        await tester.pump();
        final row = tester.widget<ManualLibraryDragRow>(
          find
              .ancestor(
                of: find.text('Song 1'),
                matching: find.byType(ManualLibraryDragRow),
              )
              .first,
        );
        expect(row.selected, isFalse);
        expect(row.canAccept, isFalse);
        await drag.moveTo(tester.getCenter(find.text('Song 1')));
        await tester.pump();
        await drag.up();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Confirm move'), findsNothing);
      },
    );
  }

  testWidgets('manual end target is hidden with a format filter', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: [now, now]);
    final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
    final filter = tester.widget<ExpressiveButton>(
      find.ancestor(
        of: find.text(l10n.libraryFilterTitle).hitTestable(),
        matching: find.byType(ExpressiveButton),
      ),
    );
    filter.onPressed!();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('FLAC').last);
    await tester.tap(find.text('FLAC').last);
    await tester.ensureVisible(find.text(l10n.libraryFilterApply));
    tester
        .widget<AppDialogAction>(
          find.ancestor(
            of: find.text(l10n.libraryFilterApply),
            matching: find.byType(AppDialogAction),
          ),
        )
        .onPressed!();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('manual_library_end_drop')), findsNothing);
    await gesture.cancel();
    await tester.pump();
  });

  Future<void> verifyScrollingTarget(
    WidgetTester tester, {
    required bool grid,
  }) async {
    queryRows = 70;
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      manual: true,
      grid: grid,
      dates: List.filled(queryRows, now),
    );
    final row = find
        .ancestor(
          of: find.text('Song 0'),
          matching: find.byType(ManualLibraryDragRow),
        )
        .first;
    final scrollable = find
        .ancestor(of: row, matching: find.byType(Scrollable))
        .first;
    final scrollState = tester.state<ScrollableState>(scrollable);
    final bounds = tester.getRect(scrollable);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final position = Offset(tester.getCenter(row).dx, bounds.bottom - 35);
    await gesture.moveTo(position);
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrollState.position.pixels, greaterThan(100));
    final targets = find.byType(ManualLibraryDragRow).evaluate().where((
      element,
    ) {
      final box = element.renderObject as RenderBox;
      return box.attached &&
          (box.localToGlobal(Offset.zero) & box.size).contains(position);
    }).toList();
    expect(targets, hasLength(1));
    final target = targets.single.widget as ManualLibraryDragRow;
    await tester.pump();
    final decorations = tester.widgetList<DecoratedBox>(
      find.descendant(
        of: find.byWidget(target),
        matching: find.byType(DecoratedBox),
      ),
    );
    expect(
      decorations.any((box) {
        final decoration = box.decoration;
        return decoration is BoxDecoration &&
            decoration.border is Border &&
            (decoration.border! as Border).top.width == 3;
      }),
      isTrue,
    );
    final song = target.id.replaceFirst('dl_song-', '');
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('before Song $song'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'manual list drag scrolls and highlights the actual row',
    (tester) => verifyScrollingTarget(tester, grid: false),
  );
  testWidgets(
    'manual grid drag scrolls and highlights the actual row',
    (tester) => verifyScrollingTarget(tester, grid: true),
  );

  testWidgets('canceling a manual drag stops scrolling without a move', (
    tester,
  ) async {
    queryRows = 70;
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: List.filled(queryRows, now));
    final row = find
        .ancestor(
          of: find.text('Song 0'),
          matching: find.byType(ManualLibraryDragRow),
        )
        .first;
    final scrollable = find
        .ancestor(of: row, matching: find.byType(Scrollable))
        .first;
    final scrollState = tester.state<ScrollableState>(scrollable);
    final bounds = tester.getRect(scrollable);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(Offset(tester.getCenter(row).dx, bounds.bottom - 35));
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(scrollState.position.pixels, greaterThan(0));
    await gesture.cancel();
    await tester.pump();
    final stoppedAt = scrollState.position.pixels;
    await tester.pump(const Duration(seconds: 1));
    expect(scrollState.position.pixels, stoppedAt);
    expect(find.text('Confirm move'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manual drag loads the next page while held', (tester) async {
    queryRows = 310;
    paginated = true;
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: List.filled(queryRows, now));
    final row = find
        .ancestor(
          of: find.text('Song 0'),
          matching: find.byType(ManualLibraryDragRow),
        )
        .first;
    final scrollable = find
        .ancestor(of: row, matching: find.byType(Scrollable))
        .first;
    final scrollState = tester.state<ScrollableState>(scrollable);
    final bounds = tester.getRect(scrollable);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byKey(const ValueKey('manual_library_end_drop')), findsNothing);
    scrollState.position.jumpTo(scrollState.position.maxScrollExtent - 700);
    await tester.pump();
    await gesture.moveTo(Offset(bounds.center.dx, bounds.bottom - 35));
    for (var i = 0; i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(secondPageQueries, greaterThan(0));
    await gesture.cancel();
    await tester.pump();
    expect(find.text('Confirm move'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('overlapping pages do not expose global end', (tester) async {
    queryRows = 310;
    paginated = true;
    duplicatePageBoundary = true;
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: List.filled(queryRows, now));
    final row = find
        .ancestor(
          of: find.text('Song 0'),
          matching: find.byType(ManualLibraryDragRow),
        )
        .first;
    final scrollable = find
        .ancestor(of: row, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    position.jumpTo(position.maxScrollExtent * .8);
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(secondPageQueries, greaterThan(0));
    expect(find.byKey(const ValueKey('manual_library_end_drop')), findsNothing);
    await gesture.cancel();
    await tester.pump();
  });

  testWidgets(
    'scrolling away from a playlist never drops on its stale target',
    (tester) async {
      queryRows = 70;
      final now = DateTime(2026);
      await pumpLibrary(
        tester,
        manual: true,
        dates: List.filled(queryRows, now),
        playlists: [
          UserPlaylistCollection(
            id: 'target',
            name: 'Target playlist',
            createdAt: now,
            updatedAt: now,
            tracks: const [],
          ),
        ],
      );
      final source = find.text('Song 0');
      final scrollable = find
          .ancestor(of: source, matching: find.byType(Scrollable))
          .first;
      final scrollState = tester.state<ScrollableState>(scrollable);
      final gesture = await tester.startGesture(
        tester.getCenter(source),
        pointer: 1,
      );
      await tester.pump(const Duration(milliseconds: 600));
      final point = tester.getCenter(find.text('Target playlist'));
      await gesture.moveTo(point);
      await tester.pump();
      scrollState.position.jumpTo(scrollState.position.pixels + 150);
      await tester.pump();
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 200));
      expect(saved.rows, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('manual mode still drops onto the visible playlist', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      manual: true,
      dates: [now, now],
      playlists: [
        UserPlaylistCollection(
          id: 'target',
          name: 'Target playlist',
          createdAt: now,
          updatedAt: now,
          tracks: const [],
        ),
      ],
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await gesture.moveTo(tester.getCenter(find.text('Target playlist')));
    await tester.pump();
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(saved.rows, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('stationary pointer drops onto playlist moved underneath it', (
    tester,
  ) async {
    queryRows = 70;
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      manual: true,
      dates: List.filled(queryRows, now),
      playlists: [
        for (final name in ['A', 'B'])
          UserPlaylistCollection(
            id: name,
            name: 'Playlist $name',
            createdAt: now,
            updatedAt: now,
            tracks: const [],
          ),
      ],
    );
    final a = find.text('Playlist A');
    final b = find.text('Playlist B');
    final first = tester.getCenter(a).dy < tester.getCenter(b).dy ? a : b;
    final second = identical(first, a) ? b : a;
    final expected = identical(second, a) ? 'A' : 'B';
    final source = find.text('Song 0');
    final scrollable = find
        .ancestor(of: source, matching: find.byType(Scrollable))
        .first;
    final scroll = tester.state<ScrollableState>(scrollable).position;
    final gesture = await tester.startGesture(tester.getCenter(source));
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // The first scroll collapses the header; measure after that layout change.
    scroll.jumpTo(1);
    await tester.pump();
    final point = tester.getCenter(first);
    final delta = tester.getCenter(second).dy - point.dy;
    await gesture.moveTo(point);
    await tester.pump();
    await tester.pump();
    bool highlighted(Finder label) => tester
        .widgetList<AnimatedContainer>(
          find.ancestor(of: label, matching: find.byType(AnimatedContainer)),
        )
        .any(
          (container) =>
              container.decoration is BoxDecoration &&
              (container.decoration! as BoxDecoration).border is Border &&
              ((container.decoration! as BoxDecoration).border! as Border)
                      .top
                      .width ==
                  2,
        );
    expect(highlighted(first), isTrue);
    expect(highlighted(second), isFalse);
    scroll.jumpTo(scroll.pixels + delta);
    await tester.pump();
    await tester.pump();
    expect(tester.getRect(second).contains(point), isTrue);
    expect(highlighted(first), isFalse);
    expect(highlighted(second), isTrue);
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    expect(
      container.read(libraryCollectionsProvider).playlistById(expected)!.tracks,
      hasLength(1),
    );
    expect(saved.rows, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('second finger before long press cannot take over the drag', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: [now, now]);
    final start = tester.getCenter(find.text('Song 0'));
    final first = await tester.startGesture(start, pointer: 1);
    final second = await tester.startGesture(
      start + const Offset(5, 0),
      pointer: 2,
    );
    await tester.pump(const Duration(milliseconds: 600));
    await second.up();
    await tester.pump();
    expect(find.text('Confirm move'), findsNothing);
    await first.moveTo(tester.getCenter(find.text('Song 1')));
    await tester.pump();
    await first.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('before Song 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('remaining finger can drag after first finger leaves early', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(tester, manual: true, dates: [now, now]);
    final start = tester.getCenter(find.text('Song 0'));
    final first = await tester.startGesture(start, pointer: 1);
    final second = await tester.startGesture(
      start + const Offset(5, 0),
      pointer: 2,
    );
    await first.up();
    await tester.pump(const Duration(milliseconds: 600));
    await second.moveTo(tester.getCenter(find.text('Song 1')));
    await tester.pump();
    await second.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('before Song 1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('finger that exceeds slop cannot steal another finger drag', (
    tester,
  ) async {
    Offset? released;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LibraryPlaylistDragSource<int>(
              data: 1,
              onSelect: () {},
              onDragStarted: () {},
              onDragEnd: () {},
              onPointerRelease: (position) => released = position,
              feedbackBuilder: (_) => const SizedBox(width: 20, height: 20),
              child: const SizedBox(
                width: 200,
                height: 200,
                child: Text('source'),
              ),
            ),
          ),
        ),
      ),
    );
    final start = tester.getCenter(find.text('source'));
    final first = await tester.startGesture(start, pointer: 1);
    await first.moveTo(start + const Offset(40, 0));
    await tester.pump();
    final second = await tester.startGesture(start, pointer: 2);
    await tester.pump(const Duration(milliseconds: 600));
    final destination = start + const Offset(0, 30);
    await second.moveTo(destination);
    await tester.pump();
    await second.up();
    await tester.pump(const Duration(milliseconds: 200));
    expect(released, destination);
    await first.cancel();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ambiguous identical fingers do not release a manual drop', (
    tester,
  ) async {
    var releases = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: LibraryPlaylistDragSource<int>(
              data: 1,
              onSelect: () {},
              onDragStarted: () {},
              onDragEnd: () {},
              onPointerRelease: (_) => releases++,
              feedbackBuilder: (_) => const SizedBox(width: 20, height: 20),
              child: const SizedBox(
                width: 200,
                height: 200,
                child: Text('source'),
              ),
            ),
          ),
        ),
      ),
    );
    final start = tester.getCenter(find.text('source'));
    final first = await tester.startGesture(start, pointer: 1);
    final second = await tester.startGesture(start, pointer: 2);
    await tester.pump(const Duration(milliseconds: 600));
    await first.up();
    await second.up();
    await tester.pump();
    expect(releases, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ambiguous drag cannot fall through to native playlist drop', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      manual: true,
      dates: [now, now],
      playlists: [
        UserPlaylistCollection(
          id: 'target',
          name: 'Target playlist',
          createdAt: now,
          updatedAt: now,
          tracks: const [],
        ),
      ],
    );
    final start = tester.getCenter(find.text('Song 0'));
    final first = await tester.startGesture(start, pointer: 1);
    final second = await tester.startGesture(start, pointer: 2);
    await tester.pump(const Duration(milliseconds: 600));
    await first.moveTo(tester.getCenter(find.text('Target playlist')));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(saved.rows, isEmpty);
    expect(
      find.textContaining('Could not identify the dragging finger'),
      findsOneWidget,
    );
    final sources = find.byType(
      LibraryPlaylistDragSource<LibraryPlaylistDragBatch>,
    );
    expect(
      tester
          .widgetList<LibraryPlaylistDragSource<LibraryPlaylistDragBatch>>(
            sources,
          )
          .every((source) => source.enabled),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'removing a drag source stops scrolling and allows another drag',
    (tester) async {
      queryRows = 70;
      final now = DateTime(2026);
      await pumpLibrary(
        tester,
        manual: true,
        dates: List.filled(queryRows, now),
        playlists: [
          UserPlaylistCollection(
            id: 'target',
            name: 'Target playlist',
            createdAt: now,
            updatedAt: now,
            tracks: const [],
          ),
        ],
      );
      final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
      final filter = tester.widget<ExpressiveButton>(
        find.ancestor(
          of: find.text(l10n.libraryFilterTitle).hitTestable(),
          matching: find.byType(ExpressiveButton),
        ),
      );
      final source = find.text('Song 1');
      final scrollable = find
          .ancestor(of: source, matching: find.byType(Scrollable))
          .first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final bounds = tester.getRect(scrollable);
      final gesture = await tester.startGesture(
        tester.getCenter(source),
        pointer: 1,
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveTo(
        Offset(tester.getCenter(source).dx, bounds.bottom - 35),
      );
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(position.pixels, greaterThan(0));
      filter.onPressed!();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.ensureVisible(find.text('FLAC').last);
      await tester.tap(find.text('FLAC').last);
      await tester.ensureVisible(find.text(l10n.libraryFilterApply));
      tester
          .widget<AppDialogAction>(
            find.ancestor(
              of: find.text(l10n.libraryFilterApply),
              matching: find.byType(AppDialogAction),
            ),
          )
          .onPressed!();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Song 1'), findsNothing);
      final active = find.byType(
        LibraryPlaylistDragSource<LibraryPlaylistDragBatch>,
      );
      expect(active, findsWidgets);
      expect(
        tester
            .widgetList<LibraryPlaylistDragSource<LibraryPlaylistDragBatch>>(
              active,
            )
            .every((source) => source.enabled),
        isTrue,
      );
      final stoppedAt = position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(position.pixels, stoppedAt);
      position.jumpTo(0);
      await tester.pump();
      final next = await tester.startGesture(
        tester.getCenter(find.text('Song 0')),
        pointer: 2,
      );
      await tester.pump(const Duration(milliseconds: 600));
      expect(
        tester
            .widgetList<LibraryPlaylistDragSource<LibraryPlaylistDragBatch>>(
              active,
            )
            .any((source) => !source.enabled),
        isTrue,
        reason: 'new drag starts',
      );
      await gesture.moveTo(tester.getCenter(find.text('Target playlist')));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(saved.rows, isEmpty);
      await next.cancel();
      await tester.pump();
      expect(
        tester
            .widgetList<LibraryPlaylistDragSource<LibraryPlaylistDragBatch>>(
              active,
            )
            .every((source) => source.enabled),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('QueueTab filtered group drop persists hidden selected song', (
    tester,
  ) async {
    final now = DateTime(2026);
    await pumpLibrary(
      tester,
      dates: [now, now],
      playlists: [
        UserPlaylistCollection(
          id: 'target',
          name: 'Target playlist',
          createdAt: now,
          updatedAt: now,
          tracks: const [],
        ),
      ],
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(QueueTab)));
    final filter = tester.widget<ExpressiveButton>(
      find.ancestor(
        of: find.text(l10n.libraryFilterTitle).hitTestable(),
        matching: find.byType(ExpressiveButton),
      ),
    );
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('Song 1'), findsOneWidget);
    // Hold selects through the production drag source. Release outside targets.
    for (final name in ['Song 0', 'Song 1']) {
      final gesture = await tester.startGesture(
        tester.getCenter(find.text(name)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.up();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
    // The selection toolbar hides tools, so retain the public button callback
    // before selecting and invoke its real filter sheet after selection.
    filter.onPressed!();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.ensureVisible(find.text('FLAC').last);
    await tester.tap(find.text('FLAC').last);
    await tester.ensureVisible(find.text(l10n.libraryFilterApply));
    tester
        .widget<AppDialogAction>(
          find.ancestor(
            of: find.text(l10n.libraryFilterApply),
            matching: find.byType(AppDialogAction),
          ),
        )
        .onPressed!();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.text('Song 1'), findsNothing);
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
    );
    await tester.pump(const Duration(milliseconds: 600));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('2 tracks'), findsWidgets);
    await gesture.moveTo(tester.getCenter(find.text('Target playlist')));
    await tester.pump();
    await gesture.up();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(saved.rows, hasLength(2));
    expect(
      saved.rows.map((row) => (jsonDecode(row['track_json']!) as Map)['name']),
      ['Song 0', 'Song 1'],
    );
    final container = ProviderScope.containerOf(
      tester.element(find.byType(QueueTab)),
    );
    expect(
      container
          .read(libraryCollectionsProvider)
          .playlistById('target')!
          .tracks
          .map((e) => e.track.name),
      ['Song 0', 'Song 1'],
    );
    expect(tester.takeException(), isNull);
  });
}
