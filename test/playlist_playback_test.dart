import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/screens/playlist_screen.dart';
import 'package:mornye/services/download_file_inventory.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/selection_action_button.dart';
import 'package:mornye/widgets/destructive_selection_button.dart';
import 'package:mornye/widgets/selection_bottom_bar.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/app_icon_finder.dart';

final _tracks = [
  for (final name in ['First', 'Unavailable', 'Selected', 'Last'])
    Track(
      id: name,
      name: name,
      artistName: 'Artist',
      albumName: 'Album',
      duration: 180,
    ),
];

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'internal');

  @override
  void setPlayerMode(String mode) => state = state.copyWith(playerMode: mode);
}

class _Handler extends Fake implements MusicPlayerHandler {}

class _Player extends MusicPlayerController {
  List<PlayableMedia> queue = [];
  int? index;
  bool? shuffle;
  bool? insertedNext;

  @override
  Future<void> enqueueMedia(
    List<PlayableMedia> media, {
    bool playNext = false,
    bool Function()? isCurrentRequest,
  }) async {
    queue = media;
    insertedNext = playNext;
  }

  @override
  Future<MusicPlayerHandler?> ensureInitialized() async => _Handler();

  @override
  Future<void> setShuffle(bool enabled) async => shuffle = enabled;

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    bool Function()? isCurrentRequest,
  }) async {
    queue = items;
    index = initialIndex;
  }

  @override
  Future<void> playAllFromPlaylist(
    List<PlayableMedia> items, {
    required int initialIndex,
    required Future<void> Function() onStarted,
    bool Function()? isCurrentRequest,
  }) => playAll(
    items,
    initialIndex: initialIndex,
    isCurrentRequest: isCurrentRequest,
  );
}

class _Playback extends PlaybackController {
  final List<List<String>> resolvedRequests = [];
  Completer<List<String?>>? delayedResolution;
  final Map<String, String?> paths = {
    'First': 'content://library/first',
    'Selected': 'content://library/selected',
    'Last': 'content://library/last',
  };

  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async {
    resolvedRequests.add(tracks.map((track) => track.id).toList());
    if (tracks.length == 1 &&
        tracks.single.id == 'DelayedLocal' &&
        delayedResolution != null) {
      return delayedResolution!.future;
    }
    return [for (final track in tracks) paths[track.id]];
  }
}

class _RacePlayback extends PlaybackController {
  final pending = Completer<void>();
  bool delayed = false;
  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async {
    if (tracks.any((track) => track.id == 'local-a') && !delayed) {
      delayed = true;
      await pending.future;
    }
    return [
      for (final track in tracks) track.id == 'local-a' ? '/a.flac' : null,
    ];
  }
}

class _RaceCollections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    loved: [
      CollectionTrackEntry(
        key: 'local-a',
        addedAt: DateTime(2026),
        track: const Track(
          id: 'local-a',
          source: 'local',
          name: 'Local A',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 10,
        ),
      ),
    ],
  );
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      UserPlaylistCollection(
        id: 'playlist',
        name: 'Playlist',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          for (final track in _tracks)
            CollectionTrackEntry(
              key: track.id,
              track: track,
              addedAt: DateTime(2026),
            ),
        ],
      ),
    ],
  );

  @override
  Future<void> ensurePlaylistLoaded(String playlistId) async {}
}

class _AllCollections extends _Collections {
  @override
  LibraryCollectionsState build() {
    final initial = super.build();
    final tracks = initial.playlists.single.tracks;
    return initial.copyWith(loved: tracks);
  }
}

class _RowDownloads extends DownloadQueueNotifier {
  final calls = <(Track, String?, int?)>[];
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
    calls.add((track, playlistName, playlistPosition));
    return 'queued';
  }

  @override
  String addToQueue(
    Track track,
    String service, {
    String? qualityOverride,
    String? playlistName,
    int? playlistPosition,
    DownloadOrigin? origin,
  }) {
    calls.add((track, playlistName, playlistPosition));
    return 'queued';
  }
}

class _LocalCollections extends _Collections {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    playlists: [
      UserPlaylistCollection(
        id: 'playlist',
        name: 'Local playlist',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          for (var i = 0; i < 620; i++)
            CollectionTrackEntry(
              key: 'local:$i',
              track: Track(
                id: 'local_$i',
                name: 'Local song $i',
                artistName: 'Local artist',
                albumName: 'Local album',
                source: 'local',
                duration: 180,
              ),
              addedAt: DateTime(2026),
            ),
        ],
      ),
    ],
  );
}

class _RemovalCollections extends _Collections {
  _RemovalCollections(this._record);
  final void Function(String, List<String>) _record;

  @override
  LibraryCollectionsState build() {
    final initial = super.build();
    final tracks = initial.playlists.single.tracks;
    return initial.copyWith(loved: tracks);
  }

  Future<int> _remove(String kind, Iterable<String> keys) async {
    final selected = keys.toSet();
    _record(kind, selected.toList());
    List<CollectionTrackEntry> keep(List<CollectionTrackEntry> entries) =>
        entries.where((entry) => !selected.contains(entry.key)).toList();
    state = switch (kind) {
      'loved' => state.copyWith(loved: keep(state.loved)),
      _ => state.copyWith(
        playlists: [
          state.playlists.single.copyWith(
            tracks: keep(state.playlists.single.tracks),
          ),
        ],
      ),
    };
    return selected.length;
  }

  @override
  Future<int> removeLovedTracks(Iterable<String> keys) =>
      _remove('loved', keys);

  @override
  Future<int> removeTracksFromPlaylist(String id, Iterable<String> keys) =>
      _remove('playlist', keys);
}

class _Library extends LocalLibraryNotifier {
  final removedFiles = <String>[];

  @override
  LocalLibraryState build() => LocalLibraryState();

  @override
  Future<void> removePhysicalFiles(Iterable<String> paths) async {
    removedFiles.addAll(paths);
  }
}

class _History extends DownloadHistoryNotifier {
  final removedFiles = <String>[];
  final deletionCompleted = Completer<void>();

  @override
  DownloadHistoryState build() => DownloadHistoryState();

  @override
  Future<void> removePhysicalFiles(Iterable<String> paths) async {
    removedFiles.addAll(paths);
    deletionCompleted.complete();
  }
}

Widget _selectionApp({
  required bool mornye,
  required _Player player,
  required _Playback playback,
  _Library? library,
  _History? history,
  DownloadQueueNotifier? downloads,
  bool internalPlayer = true,
}) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(_Settings.new),
    playerUiEnabledProvider.overrideWithValue(internalPlayer),
    musicPlayerControllerProvider.overrideWithValue(player),
    playbackProvider.overrideWith(() => playback),
    if (downloads != null) downloadQueueProvider.overrideWith(() => downloads),
    libraryCollectionsProvider.overrideWith(_Collections.new),
    localLibraryProvider.overrideWith(() => library ?? _Library()),
    downloadHistoryProvider.overrideWith(() => history ?? _History()),
    downloadHistoryVisibleBatchExistsProvider.overrideWith(
      (ref, request) => const {},
    ),
    localLibraryCoverProvider.overrideWith((ref, request) async => null),
    localLibraryFirstCoverProvider.overrideWith((ref, request) async => null),
  ],
  child: MaterialApp(
    theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.light(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const SelectionOverlayHost(
      child: LibraryTracksFolderScreen(
        mode: LibraryTracksFolderMode.playlist,
        playlistId: 'playlist',
      ),
    ),
  ),
);

Future<void> _selectAllTracks(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('First'));
  if (isDesktopPlatform) {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.tap(find.text('First'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  } else {
    await tester.longPress(find.text('First'));
  }
  await tester.pumpAndSettle();
  tester
      .widget<SelectionBottomBar>(find.byType(SelectionBottomBar))
      .onToggleSelectAll();
  await tester.pumpAndSettle();
}

class _DownloadSelection extends DownloadQueueNotifier {
  _DownloadSelection(this._record);
  final void Function(List<Track>, String) _record;

  @override
  DownloadQueueState build() => const DownloadQueueState();

  @override
  void addIndividualTracksToQueue(List<Track> tracks, String service) =>
      _record(tracks, service);
}

class _DownloadExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
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
  for (final mode in [
    LibraryTracksFolderMode.playlist,
    LibraryTracksFolderMode.loved,
  ]) {
    testWidgets(
      'mobile $mode row has independent controls and download context',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        await tester.binding.setSurfaceSize(const Size(360, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final downloads = _RowDownloads();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              libraryCollectionsProvider.overrideWith(_AllCollections.new),
              extensionProvider.overrideWith(_DownloadExtensions.new),
              downloadQueueProvider.overrideWith(() => downloads),
              localLibraryProvider.overrideWith(_Library.new),
              downloadHistoryProvider.overrideWith(_History.new),
              downloadHistoryVisibleBatchExistsProvider.overrideWith(
                (ref, request) => const {},
              ),
              localLibraryCoverProvider.overrideWith(
                (ref, request) async => null,
              ),
              localLibraryFirstCoverProvider.overrideWith(
                (ref, request) async => null,
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: LibraryTracksFolderScreen(
                mode: mode,
                playlistId: mode == LibraryTracksFolderMode.playlist
                    ? 'playlist'
                    : null,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('First'));
        final row = find
            .ancestor(of: find.text('First'), matching: find.byType(TrackCard))
            .first;
        expect(
          find.descendant(
            of: row,
            matching: find.byKey(const ValueKey('save-library-track')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row,
            matching: find.byKey(const ValueKey('download-library-track')),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: row, matching: find.byTooltip('Show menu')),
          findsOneWidget,
        );
        await tester.tap(
          find.descendant(
            of: row,
            matching: find.byKey(const ValueKey('download-library-track')),
          ),
        );
        await tester.pumpAndSettle();
        expect(downloads.calls, hasLength(1));
        expect(downloads.calls.single.$1.id, 'First');
        expect(
          downloads.calls.single.$2,
          mode == LibraryTracksFolderMode.playlist ? 'Playlist' : null,
        );
        expect(
          downloads.calls.single.$3,
          mode == LibraryTracksFolderMode.playlist ? 1 : null,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DownloadFileInventory.resetWritesForTest();
  });

  testWidgets(
    'late local row resolution cannot override a later catalog request from another surface',
    (tester) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      final playback = _RacePlayback();
      final player = _Player();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          musicPlayerControllerProvider.overrideWithValue(player),
          playbackProvider.overrideWith(() => playback),
          libraryCollectionsProvider.overrideWith(_RaceCollections.new),
          localLibraryProvider.overrideWith(_Library.new),
          downloadHistoryProvider.overrideWith(_History.new),
          downloadHistoryVisibleBatchExistsProvider.overrideWith(
            (ref, request) => const {},
          ),
          localLibraryCoverProvider.overrideWith((ref, request) async => null),
          localLibraryFirstCoverProvider.overrideWith(
            (ref, request) async => null,
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.loved,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Local A'));
      await tester.tap(find.text('Local A'));
      await tester.pump();
      expect(playback.delayed, isTrue);
      await container.read(playbackProvider.notifier).playTrackList(const [
        Track(
          id: 'catalog-b',
          name: 'Catalog B',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 10,
        ),
      ], exactStart: true);
      expect(player.queue.single.title, 'Catalog B');
      playback.pending.complete();
      await tester.pumpAndSettle();
      expect(player.queue.single.title, 'Catalog B');
    },
  );

  for (final desktop in [false, true]) {
    testWidgets(
      'catalog playlist row keeps ordered queue (desktop: $desktop)',
      (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = desktop
            ? const Size(1400, 1000)
            : const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final player = _Player();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsProvider.overrideWith(_Settings.new),
              musicPlayerControllerProvider.overrideWithValue(player),
              playbackProvider.overrideWith(_Playback.new),
              localLibraryProvider.overrideWith(_Library.new),
              downloadHistoryProvider.overrideWith(_History.new),
              downloadHistoryVisibleBatchExistsProvider.overrideWith(
                (ref, request) => const {},
              ),
            ],
            child: MaterialApp(
              theme: AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: PlaylistScreen(playlistName: 'Catalog', tracks: _tracks),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Selected'));
        if (desktop) {
          await tester.tap(find.text('Selected'));
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.tap(find.text('Selected'));
        await tester.pumpAndSettle();
        expect(player.queue.map((item) => item.title), [
          'First',
          'Unavailable',
          'Selected',
          'Last',
        ]);
        expect(player.index, 2);
        expect(player.queue[1].isCatalog, isTrue);
        expect(
          player.queue.map((item) => item.listContext).toSet(),
          hasLength(1),
        );
        expect(player.queue.every((item) => item.listContext != null), isTrue);
        expect(
          player.queue.map((item) => item.listOccurrence).toSet(),
          hasLength(4),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mornye in [false, true]) {
    for (final desktop in [false, true]) {
      for (final next in <bool?>[null, true, false]) {
        testWidgets(
          'playlist selection plays or enqueues in order ($mornye, $desktop, $next)',
          (tester) async {
            debugDesktopPlatformOverride = desktop;
            addTearDown(() => debugDesktopPlatformOverride = null);
            tester.view.physicalSize = desktop
                ? const Size(1000, 900)
                : const Size(360, 780);
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.reset);
            final player = _Player();
            final playback = _Playback();
            await tester.pumpWidget(
              _selectionApp(mornye: mornye, player: player, playback: playback),
            );
            await _selectAllTracks(tester);
            final action = find.widgetWithText(
              SelectionActionButton,
              next == null
                  ? 'Play'
                  : next
                  ? 'Play next'
                  : 'Add to queue',
            );
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pumpAndSettle();

            expect(player.queue.map((item) => item.title), [
              'First',
              'Selected',
              'Last',
            ]);
            expect(
              player.queue.map((item) => item.listContext),
              everyElement('ownPlaylist:playlist'),
            );
            expect(player.queue.map((item) => item.listOccurrence), [
              'First',
              'Selected',
              'Last',
            ]);
            expect(
              player.queue[1].toMediaItem().extras?['listOccurrence'],
              'Selected',
            );
            expect(player.insertedNext, next);
            if (next == null) expect(player.index, 0);
            expect(find.byType(SelectionBottomBar), findsNothing);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }

    testWidgets('playlist desktop menu acts on its clicked track ($mornye)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _Player();
      await tester.pumpWidget(
        _selectionApp(mornye: mornye, player: player, playback: _Playback()),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('First'));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('First')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(find.text('Add to queue'), findsOneWidget);
      expect(find.text('Delete 1 track'), findsOneWidget);
      expect(find.text('Remove from playlist (1)'), findsOneWidget);
      await tester.tap(find.text('Play next'));
      await tester.pumpAndSettle();
      expect(player.queue.map((item) => item.title), ['First']);
      expect(player.insertedNext, isTrue);
      expect(find.byType(SelectionBottomBar), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'playlist file deletion confirms and cleans both indexes ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final folder = Directory.systemTemp.createTempSync('playlist-delete-');
        addTearDown(() => folder.delete(recursive: true));
        final files = [
          File('${folder.path}/first.flac'),
          File('${folder.path}/selected.flac'),
        ];
        for (final file in files) {
          file.writeAsBytesSync([1]);
        }
        final playback = _Playback()
          ..paths.addAll({
            'First': files.first.path,
            'Selected': files.last.path,
            'Last': 'network://example/song.flac',
          });
        final library = _Library();
        final history = _History();
        await tester.pumpWidget(
          _selectionApp(
            mornye: mornye,
            player: _Player(),
            playback: playback,
            library: library,
            history: history,
          ),
        );
        await _selectAllTracks(tester);
        // Phones end the selection bar with the full-width delete button.
        final delete = find.widgetWithText(
          DestructiveSelectionButton,
          'Delete 2 tracks',
        );
        await tester.ensureVisible(delete);
        await tester.tap(delete);
        await tester.pumpAndSettle();
        expect(find.text('Delete'), findsOneWidget);
        expect(
          find.textContaining('Permanently delete 2 audio files'),
          findsOneWidget,
        );
        expect(files.every((file) => file.existsSync()), isTrue);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(library.removedFiles, isEmpty);
        expect(history.removedFiles, isEmpty);

        await tester.tap(delete);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        for (
          var attempt = 0;
          attempt < 100 && !history.deletionCompleted.isCompleted;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await tester.pump(const Duration(milliseconds: 16));
        }
        await tester.pumpAndSettle();
        expect(history.deletionCompleted.isCompleted, isTrue);
        expect(files.any((file) => file.existsSync()), isFalse);
        expect(library.removedFiles, files.map((file) => file.path));
        expect(history.removedFiles, files.map((file) => file.path));
        expect(find.byType(SelectionBottomBar), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'playlist leaves unavailable and CUE files out of actions ($mornye)',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final playback = _Playback()..paths.clear();
        playback.paths['First'] = '/album.cue#track01';
        await tester.pumpWidget(
          _selectionApp(mornye: mornye, player: _Player(), playback: playback),
        );
        await _selectAllTracks(tester);
        expect(
          find.widgetWithText(
            SelectionActionButton,
            'Remove from playlist (4)',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Delete '), findsNothing);
        final next = tester.widget<SelectionActionButton>(
          find.widgetWithText(SelectionActionButton, 'Play next'),
        );
        expect(next.onPressed, isNull);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('external player hides collection queue controls ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _selectionApp(
          mornye: mornye,
          player: _Player(),
          playback: _Playback(),
          internalPlayer: false,
        ),
      );
      await _selectAllTracks(tester);
      expect(find.text('Play next'), findsNothing);
      expect(find.text('Add to queue'), findsNothing);
      expect(find.textContaining('Add to playlist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mornye in [false, true]) {
    testWidgets('large local playlist renders and scrolls ($mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            libraryCollectionsProvider.overrideWith(_LocalCollections.new),
            localLibraryProvider.overrideWith(_Library.new),
            downloadHistoryProvider.overrideWith(_History.new),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => const {},
            ),
            localLibraryCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
            localLibraryFirstCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'playlist',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('620 tracks'), findsOneWidget);
      expect(find.text('Local song 0'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Local song 619'),
        1000,
        maxScrolls: 100,
      );
      expect(find.text('Local song 619'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  for (final mode in LibraryTracksFolderMode.values) {
    for (final mornye in [false, true]) {
      testWidgets(
        'selection dispatches one ${mode.name} removal (Mornye: $mornye)',
        (tester) async {
          tester.view.physicalSize = const Size(400, 850);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final calls = <(String, List<String>)>[];
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(_Settings.new),
                musicPlayerControllerProvider.overrideWithValue(_Player()),
                playbackProvider.overrideWith(_Playback.new),
                libraryCollectionsProvider.overrideWith(
                  () => _RemovalCollections(
                    (kind, keys) => calls.add((kind, keys)),
                  ),
                ),
                localLibraryProvider.overrideWith(_Library.new),
                downloadHistoryProvider.overrideWith(_History.new),
                downloadHistoryVisibleBatchExistsProvider.overrideWith(
                  (ref, request) => const {},
                ),
                localLibraryCoverProvider.overrideWith(
                  (ref, request) async => null,
                ),
                localLibraryFirstCoverProvider.overrideWith(
                  (ref, request) async => null,
                ),
              ],
              child: MaterialApp(
                theme: mornye
                    ? MornyeTheme.build(Brightness.dark)
                    : AppTheme.light(),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: LibraryTracksFolderScreen(
                  mode: mode,
                  playlistId: mode == LibraryTracksFolderMode.playlist
                      ? 'playlist'
                      : null,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('First'));
          await tester.longPress(find.text('First'));
          await tester.pumpAndSettle();
          await Scrollable.ensureVisible(
            tester.element(find.text('Unavailable')),
            alignment: 0.15,
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('Unavailable'));
          await tester.pumpAndSettle();
          await tester.tap(findAppIcon(Icons.remove_circle_outline));
          await tester.pumpAndSettle();
          expect(calls, hasLength(1));
          expect(calls.single.$1, mode.name);
          expect(calls.single.$2, ['First', 'Unavailable']);
          expect(find.text('First'), findsNothing);
          expect(find.text('Unavailable'), findsNothing);
          expect(findAppIcon(Icons.remove_circle_outline), findsNothing);
          final l10n = AppLocalizations.of(
            tester.element(find.byType(LibraryTracksFolderScreen)),
          );
          expect(find.text(l10n.selectionSelected(2)), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mornye in [false, true]) {
    testWidgets(
      'catalog playlist row plays without permanent download ($mornye)',
      (tester) async {
        debugDesktopPlatformOverride = false;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final calls = <(List<Track>, String)>[];
        final player = _Player();
        await tester.pumpWidget(
          _selectionApp(
            mornye: mornye,
            player: player,
            playback: _Playback(),
            downloads: _DownloadSelection(
              (tracks, service) => calls.add((tracks, service)),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Unavailable'));
        await tester.tap(find.text('Unavailable'));
        await tester.pumpAndSettle();
        expect(player.queue.map((item) => item.title), [
          'First',
          'Unavailable',
          'Selected',
          'Last',
        ]);
        expect(player.index, 1);
        expect(player.queue[1].isCatalog, isTrue);
        expect(calls, isEmpty);
        expect(find.byType(AlertDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('playlist row queues its neighbors (Mornye: $mornye)', (
      tester,
    ) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _Player();
      final playback = _Playback();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            musicPlayerControllerProvider.overrideWithValue(player),
            playbackProvider.overrideWith(() => playback),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            localLibraryProvider.overrideWith(_Library.new),
            downloadHistoryProvider.overrideWith(_History.new),
            downloadHistoryVisibleBatchExistsProvider.overrideWith(
              (ref, request) => {
                for (final track in request.tracks)
                  if (track.spotifyId != 'Unavailable') track.lookupKey,
              },
            ),
            localLibraryCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
            localLibraryFirstCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'playlist',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Selected'),
        matching: find.byType(TrackCard),
      );
      await tester.scrollUntilVisible(row, 200);
      // Tap the title itself: the row must play, not open metadata.
      await tester.tap(find.text('Selected'));
      await tester.pumpAndSettle();
      expect(playback.resolvedRequests, isNotEmpty);

      expect(player.queue.map((item) => item.title), [
        'First',
        'Unavailable',
        'Selected',
        'Last',
      ]);
      expect(player.index, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('playlist header shuffles every song (Mornye: $mornye)', (
      tester,
    ) async {
      // A narrow phone, so Play, Shuffle and Download all must share it.
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final player = _Player();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            musicPlayerControllerProvider.overrideWithValue(player),
            playbackProvider.overrideWith(_Playback.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            localLibraryProvider.overrideWith(_Library.new),
            downloadHistoryProvider.overrideWith(_History.new),
            localLibraryCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
            localLibraryFirstCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
          ],
          child: MaterialApp(
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'playlist',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('collection-shuffle')));
      await tester.pumpAndSettle();

      expect(player.shuffle, isTrue);
      expect(
        player.queue.every(
          (item) => item.listContext == 'ownPlaylist:playlist',
        ),
        isTrue,
      );
      expect(
        player.queue.map((item) => item.listOccurrence).toSet(),
        hasLength(4),
      );
      // Unresolved catalog songs remain available for on-demand preparation.
      expect(player.queue.map((item) => item.title), [
        'First',
        'Unavailable',
        'Selected',
        'Last',
      ]);
      expect(player.index, inInclusiveRange(0, 3));
      expect(tester.takeException(), isNull);
    });

    testWidgets('playlist header mirrors in Arabic (Mornye: $mornye)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 780);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            musicPlayerControllerProvider.overrideWithValue(_Player()),
            playbackProvider.overrideWith(_Playback.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
            localLibraryProvider.overrideWith(_Library.new),
            downloadHistoryProvider.overrideWith(_History.new),
            localLibraryCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
            localLibraryFirstCoverProvider.overrideWith(
              (ref, request) async => null,
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ar'),
            theme: mornye
                ? MornyeTheme.build(Brightness.dark)
                : AppTheme.light(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'playlist',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final width = tester.view.physicalSize.width;
      // Back sits at the reading start, the right edge in Arabic.
      expect(
        tester.getCenter(find.byTooltip('رجوع').first).dx,
        greaterThan(width / 2),
      );
      // Download All, Play and Shuffle run from the right, and only Play
      // carries a label.
      final download = tester.getCenter(
        find.byKey(const ValueKey('collection-download-all')),
      );
      final play = tester.getCenter(find.byType(HeaderFilledButton));
      final shuffle = tester.getCenter(
        find.byKey(const ValueKey('collection-shuffle')),
      );
      expect(download.dx, greaterThan(play.dx));
      expect(play.dx, greaterThan(shuffle.dx));
      expect(tester.takeException(), isNull);
    });
  }

  late ProviderContainer container;
  late _Player player;
  late _Playback playback;
  setUp(() {
    player = _Player();
    playback = _Playback();
    container = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(_Settings.new),
        musicPlayerControllerProvider.overrideWithValue(player),
        playbackProvider.overrideWith(() => playback),
      ],
    );
    addTearDown(container.dispose);
  });

  test(
    'starting at the last track does not rotate earlier tracks after it',
    () async {
      await container
          .read(playbackProvider.notifier)
          .playTrackList(_tracks, startIndex: 3);
      expect(player.queue.map((item) => item.title), [
        'First',
        'Unavailable',
        'Selected',
        'Last',
      ]);
      expect(player.index, player.queue.length - 1);
    },
  );

  test(
    'missing and virtual CUE tracks do not shift the selected track',
    () async {
      playback.paths['Unavailable'] = '/album.cue#track02';
      await container
          .read(playbackProvider.notifier)
          .playTrackList(
            _tracks,
            startIndex: 2,
            listContext: 'playlist',
            listOccurrences: ['first', 'cue', 'selected', 'last'],
          );
      expect(player.queue.map((item) => item.title), [
        'First',
        'Selected',
        'Last',
      ]);
      expect(player.index, 1);
      expect(player.queue.map((item) => item.listOccurrence), [
        'first',
        'selected',
        'last',
      ]);
    },
  );

  test('repeated tracks retain the selected occurrence', () async {
    await container
        .read(playbackProvider.notifier)
        .playTrackList(
          [_tracks.first, _tracks.last, _tracks.first, _tracks[2]],
          startIndex: 2,
          listContext: 'playlist',
          listOccurrences: ['a-1', 'b', 'a-2', 'c'],
        );
    expect(player.queue.map((item) => item.title), [
      'First',
      'Last',
      'First',
      'Selected',
    ]);
    expect(player.index, 2);
    expect(player.queue[player.index!].listOccurrence, 'a-2');
  });

  test('unavailable selection remains selected for preparation', () async {
    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 1);
    expect(player.queue[player.index!].title, 'Unavailable');
    expect(player.queue[player.index!].isCatalog, isTrue);
  });

  test('missing required local file never becomes catalog audio', () async {
    const missing = Track(
      id: 'missing',
      source: 'local',
      name: 'Missing',
      artistName: 'A',
      albumName: '',
      duration: 1,
    );
    await expectLater(
      container.read(playbackProvider.notifier).playTrackList([
        missing,
      ], requireLocalStart: true),
      throwsA(isA<LocalTrackUnavailableException>()),
    );
    expect(player.queue, isEmpty);
  });

  test(
    'external mode does not prepare a missing required local file',
    () async {
      container.read(settingsProvider.notifier).setPlayerMode('external');
      const missing = Track(
        id: 'missing',
        source: 'local',
        name: 'Missing',
        artistName: 'A',
        albumName: '',
        duration: 1,
      );
      await expectLater(
        container.read(playbackProvider.notifier).playTrackList([missing]),
        throwsA(isA<LocalTrackUnavailableException>()),
      );
      expect(player.queue, isEmpty);
      expect(container.read(internalCatalogSessionProvider), isFalse);
    },
  );

  test(
    'mixed queue skips missing local entries and keeps catalog order',
    () async {
      const missing = Track(
        id: 'missing',
        source: 'local',
        name: 'Missing',
        artistName: 'A',
        albumName: '',
        duration: 1,
      );
      const remote = Track(
        id: 'remote',
        source: 'spotify',
        name: 'Remote',
        artistName: 'A',
        albumName: '',
        duration: 1,
      );
      await container.read(playbackProvider.notifier).playTrackList([
        missing,
        remote,
      ], startIndex: 1);
      expect(player.queue.map((entry) => entry.title), ['Remote']);
      expect(player.queue.single.isCatalog, isTrue);
      expect(player.index, 0);
    },
  );

  test(
    'new request from another entrypoint wins while local resolution waits',
    () async {
      const delayed = Track(
        id: 'DelayedLocal',
        source: 'local',
        name: 'Old',
        artistName: 'A',
        albumName: '',
        duration: 1,
      );
      playback.delayedResolution = Completer<List<String?>>();
      final old = container.read(playbackProvider.notifier).playTrackList([
        delayed,
      ], requireLocalStart: true);
      await container
          .read(playbackProvider.notifier)
          .playLocalPath(path: '/new.mp3', title: 'New', artist: 'A');
      playback.delayedResolution!.complete(['/old.mp3']);
      await old;
      expect(player.queue.single.title, 'New');
    },
  );

  test('empty playlist leaves existing playback alone', () async {
    await container.read(playbackProvider.notifier).playTrackList([]);
    expect(player.index, isNull);
  });

  test('missing files remain in the catalog queue', () async {
    playback.paths.clear();
    await container.read(playbackProvider.notifier).playTrackList(_tracks);
    expect(player.queue.length, _tracks.length);
    expect(player.queue.every((item) => item.isCatalog), isTrue);
    expect(player.index, 0);
  });

  test('external mode opens only the selected available file', () async {
    container.read(settingsProvider.notifier).setPlayerMode('external');
    final calls = <MethodCall>[];
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 2);
    expect(calls.single.method, 'openContentUri');
    expect(
      calls.single.arguments,
      containsPair('uri', 'content://library/selected'),
    );
    expect(player.index, isNull);
    expect(playback.resolvedRequests, [
      ['Selected'],
    ]);
  });

  test('external mode prepares the selected catalog item in MUSA', () async {
    container.read(settingsProvider.notifier).setPlayerMode('external');
    playback.paths['Selected'] = '/album.cue#track02';
    const channel = MethodChannel('com.zarz.mornye/backend');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 1);
    expect(calls, isEmpty);
    expect(player.queue[player.index!].title, 'Unavailable');
    expect(player.queue[player.index!].isCatalog, isTrue);
    expect(container.read(settingsProvider).playerMode, 'external');
    expect(container.read(internalCatalogSessionProvider), isTrue);
  });

  test('external exact row activation never opens a different track', () async {
    container.read(settingsProvider.notifier).setPlayerMode('external');
    await container
        .read(playbackProvider.notifier)
        .playTrackList(_tracks, startIndex: 1, exactStart: true);
    expect(player.queue[player.index!].title, 'Unavailable');
    expect(player.queue[player.index!].isCatalog, isTrue);
  });

  test(
    'external mode routes a network fallback to the internal queue',
    () async {
      container.read(settingsProvider.notifier).setPlayerMode('external');
      playback.paths['Unavailable'] = 'network://storage/track.flac';
      await container
          .read(playbackProvider.notifier)
          .playTrackList(_tracks, startIndex: 1);
      expect(
        player.queue[player.index!].source,
        'network://storage/track.flac',
      );
      expect(playback.resolvedRequests.first, ['Unavailable']);
      expect(playback.resolvedRequests.last, _tracks.map((track) => track.id));
    },
  );
}
