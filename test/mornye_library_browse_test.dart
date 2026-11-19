import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/services/album_completeness.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_search_field.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(localLibraryEnabled: false);
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

LibraryBrowseEntry _album(int index) => LibraryBrowseEntry(
  source: 'downloaded',
  key: 'album-$index',
  name: 'Album $index',
  artist: 'Artist $index',
  samplePath: '',
  trackCount: 1,
);

void main() {
  testWidgets(
    'Mornye albums filter incomplete and unknown tags without losing search',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final requests = <LibraryBrowseRequest>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(_History.new),
            libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
              final request = page.browse;
              requests.add(request);
              final filter = request.completeness;
              return LibraryBrowsePage([
                LibraryBrowseEntry.fromRow({
                  'queue_source': 'downloaded',
                  'album_key': 'album',
                  'album_name': filter == unknownAlbumCompletenessFilter
                      ? 'Unknown'
                      : 'Album',
                  'artist_name': 'Artist',
                  'track_count': 8,
                  if (filter != null) ...{
                    'album_completeness': filter == incompleteAlbumFilter
                        ? 'incomplete'
                        : 'unknown',
                    'album_present_tracks': 8,
                    'album_expected_tracks': filter == incompleteAlbumFilter
                        ? 12
                        : null,
                  },
                }, isArtist: false),
              ]);
            }),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(Brightness.dark),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MornyeLibraryScreen(
                page: MornyeLibraryPage.albums,
                onOpenSection: (_) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Incomplete albums'));
      await tester.pumpAndSettle();
      expect(requests.last.completeness, incompleteAlbumFilter);
      expect(find.text('8/12'), findsOneWidget);
      expect(find.byTooltip('8/12 tracks · 4 missing'), findsOneWidget);
      await tester.tap(find.byTooltip('Search your library'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'My album');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(requests.last.search, 'My album');
      expect(requests.last.completeness, incompleteAlbumFilter);
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Album completeness unknown'));
      await tester.pumpAndSettle();
      expect(requests.last.completeness, unknownAlbumCompletenessFilter);
      expect(find.text('?'), findsOneWidget);
      await tester.tap(find.byTooltip('Filters'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(requests.last.completeness, isNull);
      expect(find.text('?'), findsNothing);
      expect(find.text('8/12'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('Library home browses without a download queue ($brightness)', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <String>[];
      final requests = <LibraryBrowseRequest>[];
      final searches = <LibrarySearchRequest>[];
      final queue = DownloadQueueLookup.fromItems([
        for (final status in [DownloadStatus.queued, DownloadStatus.completed])
          DownloadItem(
            id: status.name,
            service: 'example',
            status: status,
            createdAt: DateTime(2026),
            track: Track(
              id: status.name,
              name: 'Track',
              artistName: 'Artist',
              albumName: 'Album',
              duration: 100,
            ),
          ),
      ]);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            downloadQueueLookupProvider.overrideWithValue(queue),
            settingsProvider.overrideWith(_Settings.new),
            downloadHistoryProvider.overrideWith(_History.new),
            libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
              final request = page.browse;
              requests.add(request);
              return LibraryBrowsePage([_album(0), _album(1)]);
            }),
            librarySearchProvider.overrideWith((ref, request) async {
              searches.add(request);
              return [];
            }),
          ],
          child: MaterialApp(
            theme: MornyeTheme.build(brightness),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: MornyeLibraryScreen(onOpenSection: opened.add),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // The root is the library home: only the shortcuts and the playlists,
      // no album rows, and creating or importing a playlist is the header's
      // "+".
      expect(find.text('Album 0'), findsNothing);
      expect(requests, isEmpty);
      await tester.tap(find.byKey(const ValueKey('library_import')));
      await tester.pumpAndSettle();
      expect(find.text('Import public link'), findsOneWidget);
      expect(find.text('Import playlist file'), findsOneWidget);
      Navigator.of(tester.element(find.text('Import public link'))).pop();
      await tester.pumpAndSettle();
      // The download queue is no longer a page: nothing opens it, and the
      // files already downloaded are the "Downloaded" shortcut.
      expect(find.byTooltip('Downloads'), findsNothing);
      await tester.tap(
        find.byKey(const ValueKey('library-entry-pinned:downloaded')),
      );
      expect(opened, ['all']);

      await tester.tap(find.byTooltip('Search your library'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'green lilac');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(searches, isNotEmpty);
      expect(find.byType(TextField), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();

      final albumsChip = find.byKey(const ValueKey('library-filter-albums'));
      await tester.ensureVisible(albumsChip);
      await tester.pumpAndSettle();
      await tester.tap(albumsChip);
      await tester.pumpAndSettle();
      expect(find.text('Album 0'), findsOneWidget);
      expect(find.text('Album · Artist 0'), findsOneWidget);

      final artistsChip = find.byKey(const ValueKey('library-filter-artists'));
      await tester.ensureVisible(artistsChip);
      await tester.pumpAndSettle();
      await tester.tap(artistsChip);
      await tester.pumpAndSettle();
      expect(requests.last.artists, isTrue);
      await tester.tap(find.text('Artist 0'));
      await tester.pumpAndSettle();
      expect(requests.last.artists, isFalse);
      expect(requests.last.artist, 'Artist 0');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Library search is local and album pages load on scroll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <LibraryBrowseRequest>[];
    final offsets = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          downloadHistoryProvider.overrideWith(_History.new),
          libraryBrowsePageLoaderProvider.overrideWithValue((page) async {
            final request = page.browse;
            requests.add(request);
            offsets.add(page.offset);
            return LibraryBrowsePage(
              List.generate(request.limit, (i) => _album(page.offset + i)),
            );
          }),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MornyeLibraryScreen(
              page: MornyeLibraryPage.albums,
              onOpenSection: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    scroll.controller!.jumpTo(scroll.controller!.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(requests.last.limit, 40);
    expect(offsets, [0, 40]);
    expect(
      tester
          .widget<SliverGrid>(find.byType(SliverGrid))
          .delegate
          .estimatedChildCount,
      80,
    );
    scroll.controller!.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search your library'));
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    // The field scrolls with the page over its plain background.
    expect(
      find.descendant(
        of: find.byType(AppSearchField),
        matching: find.byType(BackdropFilter),
      ),
      findsNothing,
    );
    await tester.enterText(find.byType(TextField), 'My album');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(requests.last.search, 'My album');
    expect(requests.last.limit, 40);
    expect(offsets.last, 0);
    expect(tester.takeException(), isNull);
  });
}
