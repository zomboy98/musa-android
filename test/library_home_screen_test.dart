import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/library_collections.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_browse_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/library_search_provider.dart';
import 'package:mornye/screens/library/library_home_screen.dart';
import 'package:mornye/screens/mornye_library_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/library_home_widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_home_fixture.dart';

final _a = libraryTrack('a', name: 'Zebra', artist: 'Beta');
final _b = libraryTrack('b', name: 'Apple', artist: 'Alfa');

Finder _entry(String id) => find.byKey(ValueKey('library-entry-$id'));
Finder _song(Track track) => _entry('song:${trackCollectionKey(track)}');
Finder _chip(String name) => find.byKey(ValueKey('library-filter-$name'));

/// Chips beyond the screen edge are reached by sliding the row.
Future<void> _tapChip(WidgetTester tester, String name) async {
  await tester.dragUntilVisible(
    _chip(name),
    find.byType(LibraryFilterChipsBar),
    const Offset(-120, 0),
  );
  await tester.pumpAndSettle();
  await tester.tap(_chip(name));
}

Future<List<String>> _pump(
  WidgetTester tester, {
  List<Track> saved = const [],
  List<Track> favorites = const [],
  List<UserPlaylistCollection> playlists = const [],
  List<LibraryBrowseEntry> albums = const [],
  List<CollectionArtistEntry> artists = const [],
  int downloadedCount = 0,
  List<LibraryBrowseRequest>? browseRequests,
  List<LibrarySearchRequest>? searches,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  seedSavedTracks(saved);
  final opened = <String>[];
  await tester.pumpWidget(
    ProviderScope(
      overrides: libraryHomeOverrides(
        favorites: favorites.map(favoriteEntry).toList(),
        playlists: playlists,
        albums: albums,
        favoriteArtists: artists,
        downloadedCount: downloadedCount,
        browseRequests: browseRequests,
        searches: searches,
      ),
      child: MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: MornyeLibraryScreen(onOpenSection: opened.add)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

List<CollectionArtistEntry> _artists(List<String> names) => [
  for (final name in names)
    CollectionArtistEntry(
      key: 'catalog:$name',
      artistId: name,
      providerId: 'catalog',
      name: name,
      addedAt: DateTime(2026),
    ),
];

void main() {
  testWidgets('everything lists no artist, group of artists or album', (
    tester,
  ) async {
    final names = ['Zeta', 'Ñandú', 'Árbol', 'nube', 'El Randal'];
    final requests = <LibraryBrowseRequest>[];
    await _pump(
      tester,
      artists: _artists(names),
      albums: [libraryAlbum('Blue', artist: 'Joni')],
      browseRequests: requests,
    );
    expect(_entry('artists:group'), findsNothing);
    for (final name in names) {
      expect(_entry('artist:catalog:$name'), findsNothing);
    }
    expect(find.text('Blue'), findsNothing);
    expect(requests, isEmpty);
  });

  testWidgets('everything holds three collections and the playlists only', (
    tester,
  ) async {
    final requests = <LibraryBrowseRequest>[];
    await _pump(
      tester,
      saved: [_a, _b],
      playlists: [
        UserPlaylistCollection(
          id: 'p1',
          name: 'Viaje',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tracks: const [],
        ),
        UserPlaylistCollection(
          id: 'p2',
          name: 'Gym',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tracks: const [],
        ),
      ],
      albums: [libraryAlbum('Blue'), libraryAlbum('Aguas')],
      artists: _artists(['Luna']),
      downloadedCount: 116,
      browseRequests: requests,
    );
    expect(
      find.byWidgetPredicate((w) {
        final key = w.key;
        return key is ValueKey<String> &&
            key.value.startsWith('library-entry-');
      }),
      findsNWidgets(5),
    );
    expect(_entry('pinned:favorites'), findsOneWidget);
    expect(_entry('pinned:songs'), findsOneWidget);
    expect(_entry('pinned:downloaded'), findsOneWidget);
    expect(_entry('playlist:p1'), findsOneWidget);
    expect(_entry('playlist:p2'), findsOneWidget);
    expect(find.text('Blue'), findsNothing);
    expect(requests, isEmpty);

    await tester.tap(_chip('albums'));
    await tester.pumpAndSettle();
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Aguas'), findsOneWidget);
  });

  testWidgets('the artists chip lists them by name', (tester) async {
    await _pump(tester, artists: _artists(['Zeta', 'Árbol', 'Mar']));
    await _tapChip(tester, 'artists');
    await tester.pumpAndSettle();
    expect(_entry('artists:group'), findsNothing);
    final tops = [
      for (final name in ['Árbol', 'Mar', 'Zeta'])
        tester.getTopLeft(_entry('artist:catalog:$name')).dy,
    ];
    expect(tops, [...tops]..sort());
  });

  testWidgets('favorites and downloads are fixed shortcuts with counts', (
    tester,
  ) async {
    final opened = await _pump(
      tester,
      saved: [_a, _b],
      favorites: [_b],
      downloadedCount: 5,
    );
    expect(find.byType(LibraryHomeScreen), findsOneWidget);
    expect(find.text('Your library'), findsWidgets);
    expect(
      find.descendant(
        of: _entry('pinned:favorites'),
        matching: find.text('1 song'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _entry('pinned:songs'),
        matching: find.text('2 songs'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _entry('pinned:downloaded'),
        matching: find.text('5 songs · On this device'),
      ),
      findsOneWidget,
    );
    // The shortcuts come before anything else in the list.
    final first = tester.getTopLeft(_entry('pinned:favorites')).dy;
    expect(first, lessThan(tester.getTopLeft(_entry('pinned:songs')).dy));
    expect(
      tester.getTopLeft(_entry('pinned:songs')).dy,
      lessThan(tester.getTopLeft(_entry('pinned:downloaded')).dy),
    );

    // "Downloaded" opens the files already on the device.
    await tester.tap(_entry('pinned:downloaded'));
    await tester.pumpAndSettle();
    expect(opened, ['all']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the song list has no favorites folder inside it', (
    tester,
  ) async {
    await _pump(tester, saved: [_a, _b], favorites: [_b]);
    await tester.tap(_chip('songs'));
    await tester.pumpAndSettle();

    expect(_song(_a), findsOneWidget);
    expect(_song(_b), findsOneWidget);
    expect(_entry('pinned:favorites'), findsNothing);
    expect(_entry('pinned:songs'), findsNothing);
    expect(find.text('Loved'), findsNothing);
    expect(find.text('Wishlist'), findsNothing);

    // The "x" chip returns to everything.
    expect(find.byKey(const ValueKey('library-filter-clear')), findsOneWidget);
    expect(_chip('all'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-filter-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('library-filter-clear')), findsNothing);
    expect(_entry('pinned:favorites'), findsOneWidget);
    expect(_song(_a), findsNothing);
  });

  testWidgets('the favorites chip filters the same library', (tester) async {
    await _pump(tester, saved: [_a, _b], favorites: [_b]);
    await _tapChip(tester, 'favorites');
    await tester.pumpAndSettle();
    expect(_song(_b), findsOneWidget);
    expect(_song(_a), findsNothing);
  });

  testWidgets('starring a row keeps the song in the library either way', (
    tester,
  ) async {
    await _pump(tester, saved: [_a], favorites: const []);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(LibraryHomeScreen)),
    );
    await tester.tap(_chip('songs'));
    await tester.pumpAndSettle();
    final star = find.byKey(
      ValueKey('library-favorite-${trackCollectionKey(_a)}'),
    );
    expect(find.byTooltip('Mark as favorite'), findsOneWidget);
    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from favorites'), findsOneWidget);
    expect(container.read(libraryFavoriteCountProvider), 1);

    await tester.tap(star);
    await tester.pumpAndSettle();
    expect(container.read(libraryFavoriteCountProvider), 0);
    expect(_song(_a), findsOneWidget);
    expect(container.read(librarySongsProvider).single.saved, isTrue);
  });

  testWidgets('empty views say how to fill them', (tester) async {
    await _pump(tester);
    expect(find.byKey(const ValueKey('library-empty')), findsOneWidget);
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(
      find.text('Add songs with + from search or the player'),
      findsOneWidget,
    );
    // The shortcuts stay visible, with zero counts.
    expect(_entry('pinned:favorites'), findsOneWidget);

    await tester.tap(_chip('songs'));
    await tester.pumpAndSettle();
    expect(find.text('Your library is empty'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('order and layout are chosen in place and remembered', (
    tester,
  ) async {
    await _pump(tester, saved: [_a, _b]);
    await tester.tap(_chip('songs'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_song(_a)).dy,
      lessThan(tester.getTopLeft(_song(_b)).dy),
    );

    await tester.tap(find.byKey(const ValueKey('library-sort')));
    await tester.pumpAndSettle();
    expect(find.text('Recently added'), findsOneWidget);
    expect(find.text('Artist or creator'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('library-sort-alphabetical')));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(_song(_b)).dy,
      lessThan(tester.getTopLeft(_song(_a)).dy),
    );

    expect(find.byType(SliverGrid), findsNothing);
    await tester.tap(find.byKey(const ValueKey('library-view')));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.byType(LibraryEntryCell), findsNWidgets(2));
    await tester.tap(find.byKey(const ValueKey('library-view')));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsNothing);
    expect(
      tester
          .widgetList<LibraryEntryTile>(find.byType(LibraryEntryTile))
          .every((tile) => tile.compact),
      isTrue,
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(LibraryHomePreferencesNotifier.sortKey),
      'alphabetical',
    );
    expect(prefs.getString(LibraryHomePreferencesNotifier.viewKey), 'compact');
  });

  testWidgets('search stays inside the library', (tester) async {
    final searches = <LibrarySearchRequest>[];
    await _pump(
      tester,
      saved: [_a, _b],
      playlists: [
        UserPlaylistCollection(
          id: 'p',
          name: 'Road trip',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
          tracks: const [],
        ),
      ],
      searches: searches,
    );
    expect(_entry('playlist:p'), findsOneWidget);
    expect(find.text('Playlist · 0 songs'), findsOneWidget);

    await tester.tap(find.byTooltip('Search your library'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zeb');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(_song(_a), findsOneWidget);
    expect(_song(_b), findsNothing);
    expect(_entry('playlist:p'), findsNothing);
    expect(_entry('pinned:favorites'), findsNothing);
    expect(searches, isNotEmpty);

    await tester.enterText(find.byType(TextField), 'nothing matches');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(_song(_a), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('albums are rows with artwork, kind and artist', (tester) async {
    final requests = <LibraryBrowseRequest>[];
    await _pump(
      tester,
      albums: [libraryAlbum('Blue', artist: 'Joni')],
      browseRequests: requests,
    );
    expect(find.text('Blue'), findsNothing);
    expect(requests, isEmpty);

    await tester.tap(_chip('albums'));
    await tester.pumpAndSettle();
    expect(find.text('Blue'), findsOneWidget);
    expect(find.text('Album · Joni'), findsOneWidget);
    expect(requests.last.artists, isFalse);
    expect(requests.last.sort, 'latest');
    expect(_entry('pinned:favorites'), findsNothing);
    expect(_entry('pinned:downloaded'), findsNothing);
  });

  testWidgets('no button or route opens a download queue', (tester) async {
    final opened = await _pump(
      tester,
      saved: [_a],
      albums: [libraryAlbum('Blue')],
      downloadedCount: 3,
    );
    expect(find.byTooltip('Downloads'), findsNothing);
    expect(find.byIcon(Icons.downloading_outlined), findsNothing);
    expect(find.textContaining('Downloading'), findsNothing);

    // "Downloaded" is a filter over finished files, with its shortcut.
    await _tapChip(tester, 'downloaded');
    await tester.pumpAndSettle();
    expect(_entry('pinned:downloaded'), findsOneWidget);
    expect(find.text('3 songs · On this device'), findsOneWidget);
    expect(find.text('Blue'), findsOneWidget);
    await tester.tap(_entry('pinned:downloaded'));
    await tester.pumpAndSettle();
    expect(opened, ['all']);
    expect(opened, isNot(contains('downloads')));
  });
}
