import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/widgets/add_to_music_sheet.dart';

import 'support/library_home_fixture.dart';

final _song = libraryTrack('a', name: 'Zebra', artist: 'Beta');

/// Collections in memory with playlist add/remove, like the real notifier.
class _Collections extends MemoryCollections {
  _Collections(super.initial);

  @override
  Future<bool> addTrackToPlaylist(String playlistId, Track track) async {
    final entry = favoriteEntry(track);
    state = state.copyWith(
      playlists: [
        for (final p in state.playlists)
          if (p.id == playlistId)
            p.copyWith(tracks: [...p.tracks, entry])
          else
            p,
      ],
    );
    return true;
  }

  @override
  Future<int> removeTracksFromPlaylist(
    String playlistId,
    Iterable<String> trackKeys,
  ) async {
    final keys = trackKeys.toSet();
    state = state.copyWith(
      playlists: [
        for (final p in state.playlists)
          if (p.id == playlistId)
            p.copyWith(
              tracks: p.tracks.where((e) => !keys.contains(e.key)).toList(),
            )
          else
            p,
      ],
    );
    return keys.length;
  }
}

UserPlaylistCollection _playlist(String id, {List<Track> tracks = const []}) =>
    UserPlaylistCollection(
      id: id,
      name: 'List $id',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
      tracks: [for (final t in tracks) favoriteEntry(t)],
    );

Finder _row(String id) => find.byKey(ValueKey('add-to-music-$id'));
final _confirm = find.byKey(const ValueKey('add-to-music-confirm'));

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<Track> saved = const [],
  List<UserPlaylistCollection> playlists = const [],
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  seedSavedTracks(saved);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...libraryHomeOverrides(
          playlists: playlists,
          collections: _Collections.new,
        ),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showAddToMusicSheet(context, ref, _song),
              child: const Text('plus'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.text('plus')));
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('plus'));
  await tester.pumpAndSettle();
}

bool _selected(WidgetTester tester, String id) => tester
    .widget<ListTile>(
      find.descendant(of: _row(id), matching: find.byType(ListTile)),
    )
    .selected;

List<Track> _saved(ProviderContainer c) =>
    c.read(savedLibraryTracksProvider).value ?? const [];

bool _hasSong(ProviderContainer c, String playlistId) => c
    .read(libraryCollectionsProvider)
    .playlistById(playlistId)!
    .containsTrackKey(trackCollectionKey(_song));

void main() {
  testWidgets('sheet is partial height and lists library plus playlists', (
    tester,
  ) async {
    await _pump(
      tester,
      playlists: [for (var i = 0; i < 12; i++) _playlist('p$i')],
    );
    await _open(tester);
    expect(_row('library'), findsOneWidget);
    expect(_row('playlist-p0'), findsOneWidget);
    // Even with many playlists the sheet stays under 65 % of the screen.
    final top = tester.getTopLeft(find.text('Add to music')).dy;
    expect(top, greaterThan(844 * 0.35));
    expect(tester.getRect(_confirm).bottom, lessThanOrEqualTo(844));
    // Confirm stays disabled until something is chosen.
    expect(tester.widget<FilledButton>(_confirm).onPressed, isNull);
  });

  testWidgets('several rows light up and confirm adds to every one', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      playlists: [_playlist('a'), _playlist('b'), _playlist('c')],
    );
    await _open(tester);
    expect(_selected(tester, 'library'), isFalse);
    await tester.tap(_row('library'));
    await tester.tap(_row('playlist-a'));
    await tester.tap(_row('playlist-c'));
    await tester.pump();
    expect(_selected(tester, 'library'), isTrue);
    expect(_selected(tester, 'playlist-a'), isTrue);
    expect(_selected(tester, 'playlist-b'), isFalse);
    expect(_selected(tester, 'playlist-c'), isTrue);
    expect(
      find.descendant(
        of: _row('library'),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
    );
    expect(find.text('Add (3)'), findsOneWidget);

    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(_confirm, findsNothing);
    expect(_saved(container).single.id, 'a');
    expect(_hasSong(container, 'a'), isTrue);
    expect(_hasSong(container, 'b'), isFalse);
    expect(_hasSong(container, 'c'), isTrue);
  });

  testWidgets('cancel changes nothing', (tester) async {
    final container = await _pump(tester, playlists: [_playlist('a')]);
    await _open(tester);
    await tester.tap(_row('library'));
    await tester.tap(_row('playlist-a'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('add-to-music-cancel')));
    await tester.pumpAndSettle();
    expect(_saved(container), isEmpty);
    expect(_hasSong(container, 'a'), isFalse);
  });

  testWidgets('what already holds the song starts selected; deselect removes', (
    tester,
  ) async {
    final container = await _pump(
      tester,
      saved: [_song],
      playlists: [
        _playlist('a', tracks: [_song]),
        _playlist('b'),
      ],
    );
    await _open(tester);
    expect(_selected(tester, 'library'), isTrue);
    expect(_selected(tester, 'playlist-a'), isTrue);
    expect(_selected(tester, 'playlist-b'), isFalse);
    expect(find.textContaining('Already added'), findsNWidgets(2));

    await tester.tap(_row('playlist-a'));
    await tester.pump();
    expect(find.text('Will be removed'), findsOneWidget);
    expect(find.text('Apply (1)'), findsOneWidget);
    await tester.tap(_confirm);
    await tester.pumpAndSettle();
    expect(_hasSong(container, 'a'), isFalse);
    // The library entry was not touched.
    expect(
      container.read(libraryMembershipProvider).isInLibrary(_song),
      isTrue,
    );
  });

  testWidgets('a second tap on "+" while open does not stack sheets', (
    tester,
  ) async {
    await _pump(tester);
    final plus = tester.widget<TextButton>(find.byType(TextButton)).onPressed!;
    plus();
    plus();
    await tester.pumpAndSettle();
    expect(find.text('Add to music'), findsOneWidget);
  });
}
