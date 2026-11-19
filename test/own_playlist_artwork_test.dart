import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/screens/library_tracks_folder_screen.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/desktop/link_desktop_host.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/playlist_cover_collage.dart';
import 'package:mornye/widgets/track_collection_quick_actions.dart';
import 'package:mornye/widgets/desktop/track_list_table.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/fixed_settings.dart';

CollectionTrackEntry entry(String id, String? cover) => CollectionTrackEntry(
  key: id,
  addedAt: DateTime(2026),
  track: Track(
    id: id,
    name: id,
    artistName: 'Artist',
    albumName: 'Album',
    duration: 10,
    coverUrl: cover,
  ),
);

class _Collections extends LibraryCollectionsNotifier {
  _Collections({this.local = false, this.customCover = false});
  final bool local;
  final bool customCover;
  CollectionTrackEntry get song => local
      ? CollectionTrackEntry(
          key: 'Song',
          addedAt: DateTime(2026),
          track: entry('Song', null).track.copyWith(source: 'local'),
        )
      : entry('Song', null);
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(
    isLoaded: true,
    loved: [song],
    playlists: [
      UserPlaylistCollection(
        id: 'mix',
        name: 'Mix',
        coverImagePath: customCover ? 'C:/fake/custom.png' : null,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
        tracks: [
          entry('Song', customCover ? 'C:/fake/one.png' : null),
          entry('Other', customCover ? 'C:/fake/two.png' : null),
          CollectionTrackEntry(
            key: 'repeat',
            addedAt: DateTime(2026),
            track: entry('Song', null).track,
          ),
        ],
      ),
    ],
  );
  @override
  Future<void> ensurePlaylistLoaded(String id) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

class _Host extends LinkDesktopHost {
  @override
  LinkDesktopHostState build() => const LinkDesktopHostState();
}

class _Playback extends PlaybackController {
  int plays = 0;
  List<String> ids = [];
  int? index;
  String? playlist;
  bool? exact;
  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async =>
      List.filled(tracks.length, null);
  @override
  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? playlistId,
    bool exactStart = false,
    bool requireLocalStart = false,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    if (requireLocalStart) throw const LocalTrackUnavailableException();
    plays++;
    ids = tracks.map((track) => track.id).toList();
    index = startIndex;
    playlist = playlistId;
    exact = exactStart;
  }
}

class _Player extends MusicPlayerController {
  @override
  Future<void> setShuffle(bool enabled) async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => debugDesktopPlatformOverride = null);
  test(
    'own playlist artwork respects custom cover and selects at most four distinct sources',
    () {
      expect(ownPlaylistCollageSources(null, []), isEmpty);
      expect(ownPlaylistCollageSources(null, [entry('1', 'file:///one')]), [
        'file:///one',
      ]);
      final entries = [for (var i = 1; i <= 5; i++) entry('$i', 'file:///$i')];
      expect(ownPlaylistCollageSources(null, entries), [
        'file:///1',
        'file:///2',
        'file:///3',
        'file:///4',
      ]);
      expect(ownPlaylistCollageSources('/custom.png', entries), isEmpty);
    },
  );

  for (final mode in [LibraryTracksFolderMode.loved]) {
    for (final local in [false, true]) {
      testWidgets(
        '$mode ${local ? 'missing local file is rejected' : 'catalog row reaches playback with no local file'}',
        (tester) async {
          debugDesktopPlatformOverride = false;
          final playback = _Playback();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                settingsProvider.overrideWith(FixedSettingsNotifier.new),
                libraryCollectionsProvider.overrideWith(
                  () => _Collections(local: local),
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
                linkDesktopHostProvider.overrideWith(_Host.new),
                playbackProvider.overrideWith(() => playback),
              ],
              child: MaterialApp(
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: LibraryTracksFolderScreen(mode: mode),
              ),
            ),
          );
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('Song'));
          await tester.tap(find.text('Song'));
          await tester.pumpAndSettle();
          expect(playback.plays, local ? 0 : 1);
          expect(playback.ids, local ? isEmpty : ['Song']);
        },
      );
    }
  }

  testWidgets(
    'own playlist row plays and selection removes independent actions',
    (tester) async {
      debugDesktopPlatformOverride = false;
      tester.view.physicalSize = const Size(430, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = _Playback();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
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
            linkDesktopHostProvider.overrideWith(_Host.new),
            playbackProvider.overrideWith(() => playback),
            musicPlayerControllerProvider.overrideWithValue(_Player()),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'mix',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Song').first);
      await tester.tap(find.byKey(const ValueKey('save-library-track')).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        find.byKey(const ValueKey('add-to-music-library')),
        findsOneWidget,
      );
      expect(playback.plays, 0);
      await tester.tap(find.byKey(const ValueKey('add-to-music-cancel')));
      await tester.pumpAndSettle();
      expect(playback.plays, 0);
      await tester.tap(find.byIcon(Icons.download_outlined).first);
      await tester.pumpAndSettle();
      expect(playback.plays, 0);
      expect(find.byType(LibraryTracksFolderScreen), findsOneWidget);
      await tester.tap(find.byType(TrackCollectionQuickActions).first);
      await tester.pumpAndSettle();
      expect(playback.plays, 0);
      Navigator.of(
        tester.element(find.byType(LibraryTracksFolderScreen)),
        rootNavigator: true,
      ).pop();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(HeaderFilledButton));
      await tester.tap(find.byType(HeaderFilledButton));
      await tester.pump();
      expect(playback.ids, ['Song', 'Other', 'Song']);
      expect(playback.index, 0);
      expect(playback.playlist, 'mix');
      await tester.ensureVisible(find.text('Song').last);
      await tester.tap(find.text('Song').last);
      await tester.pump();
      expect(playback.plays, 2);
      expect(playback.index, 2);
      expect(playback.exact, isTrue);
      expect(playback.ids, ['Song', 'Other', 'Song']);
      expect(find.byIcon(Icons.download_outlined), findsWidgets);
      expect(find.byType(TrackCollectionQuickActions), findsWidgets);
      await tester.longPress(find.text('Song').last);
      await tester.pumpAndSettle();
      expect(find.byType(TrackCollectionQuickActions), findsNothing);
      expect(find.byIcon(Icons.download_outlined), findsNothing);
      expect(playback.plays, 2);
      expect(find.byType(PlaylistCoverCollage), findsNothing);
    },
  );

  testWidgets(
    'own playlist opts desktop table into verified status and download',
    (tester) async {
      debugDesktopPlatformOverride = true;
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final playback = _Playback();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(_Collections.new),
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
            linkDesktopHostProvider.overrideWith(_Host.new),
            playbackProvider.overrideWith(() => playback),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'mix',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final table = tester.widget<TrackListTable>(find.byType(TrackListTable));
      expect(table.verifiedDownloadedIndicator, isTrue);
      expect(table.onDownloadRow, isNotNull);
      await tester.ensureVisible(find.byIcon(Icons.download_outlined).first);
      await tester.tap(find.byIcon(Icons.download_outlined).first);
      await tester.pumpAndSettle();
      expect(playback.plays, 0);
    },
  );

  testWidgets(
    'own playlist header retains custom cover when track art exists',
    (tester) async {
      debugDesktopPlatformOverride = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            libraryCollectionsProvider.overrideWith(
              () => _Collections(customCover: true),
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
            linkDesktopHostProvider.overrideWith(_Host.new),
          ],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: LibraryTracksFolderScreen(
              mode: LibraryTracksFolderMode.playlist,
              playlistId: 'mix',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(PlaylistCoverCollage), findsNothing);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Image &&
              widget.image is ResizeImage &&
              (widget.image as ResizeImage).imageProvider is FileImage &&
              ((widget.image as ResizeImage).imageProvider as FileImage)
                      .file
                      .path ==
                  'C:/fake/custom.png',
        ),
        findsWidgets,
      );
    },
  );
}
