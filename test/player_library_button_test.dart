import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_favorite_button.dart';
import 'package:mornye/widgets/player_library_button.dart';

import 'support/library_home_fixture.dart';

const _item = MediaItem(
  id: 'a',
  title: 'Zebra',
  artist: 'Beta',
  album: 'Album',
);
final _track = libraryTrack('a', name: 'Zebra', artist: 'Beta');

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  List<Track> saved = const [],
  List<Track> favorites = const [],
}) async {
  seedSavedTracks(saved);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...libraryHomeOverrides(
          favorites: favorites.map(favoriteEntry).toList(),
        ),
        playerCollectionTrackProvider.overrideWith((ref, item) async => _track),
      ],
      child: MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Row(
            children: [
              PlayerLibraryButton(mediaItem: _item),
              MornyePlayerFavoriteButton(mediaItem: _item),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(PlayerLibraryButton)),
  );
}

List<Track> _saved(ProviderContainer container) =>
    container.read(savedLibraryTracksProvider).value ?? const [];

/// The "+" opens the add-to-music sheet: flip the Library row and confirm.
Future<void> _viaSheet(WidgetTester tester, Finder plus) async {
  await tester.tap(plus);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('add-to-music-library')));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('add-to-music-confirm')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the player shows "+" and the star side by side', (tester) async {
    await _pump(tester);
    expect(find.byType(PlayerLibraryButton), findsOneWidget);
    expect(find.byType(MornyePlayerFavoriteButton), findsOneWidget);
    expect(find.byTooltip('Add to library'), findsOneWidget);
    expect(find.byTooltip('Add to Loved'), findsOneWidget);
  });

  testWidgets('"+" adds the song and then offers to remove it', (tester) async {
    final container = await _pump(tester);
    await _viaSheet(tester, find.byTooltip('Add to library'));
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(find.byTooltip('Add to library'), findsNothing);
    expect(_saved(container).single.id, 'a');
    // Adding to the library does not star the song.
    expect(container.read(libraryFavoriteCountProvider), 0);
    expect(find.byTooltip('Add to Loved'), findsOneWidget);

    await _viaSheet(tester, find.byTooltip('Remove from library'));
    expect(find.byTooltip('Add to library'), findsOneWidget);
    expect(_saved(container), isEmpty);
  });

  testWidgets('starring adds the song to the library; unstarring keeps it', (
    tester,
  ) async {
    final container = await _pump(tester);
    await tester.tap(find.byTooltip('Add to Loved'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from Loved'), findsOneWidget);
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(_saved(container).single.id, 'a');
    expect(container.read(libraryFavoriteCountProvider), 1);

    await tester.tap(find.byTooltip('Remove from Loved'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Add to Loved'), findsOneWidget);
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(_saved(container).single.id, 'a');
  });

  testWidgets('removing a favorite from the library clears its star too', (
    tester,
  ) async {
    final container = await _pump(tester, saved: [_track], favorites: [_track]);
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(find.byTooltip('Remove from Loved'), findsOneWidget);

    await _viaSheet(tester, find.byTooltip('Remove from library'));
    expect(find.byTooltip('Add to library'), findsOneWidget);
    expect(find.byTooltip('Add to Loved'), findsOneWidget);
    expect(_saved(container), isEmpty);
    expect(container.read(librarySongsProvider), isEmpty);
  });

  testWidgets('a favorite starred before the link counts as in the library', (
    tester,
  ) async {
    final container = await _pump(tester, favorites: [_track]);
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(container.read(librarySongsProvider).single.saved, isFalse);
    // Clearing the star stores the reference, so the song stays.
    await tester.tap(find.byTooltip('Remove from Loved'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Remove from library'), findsOneWidget);
    expect(container.read(librarySongsProvider).single.saved, isTrue);
  });
}
