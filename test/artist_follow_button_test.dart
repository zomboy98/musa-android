import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/widgets/artist_follow_button.dart';

class _Database extends Fake implements LibraryCollectionsDatabase {
  final artists = <String, String>{};

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async =>
      LibraryCollectionsSnapshot(
        lovedRows: const [],
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: [
          for (final entry in artists.entries)
            {'artist_key': entry.key, 'artist_json': entry.value},
        ],
      );

  @override
  Future<void> upsertFavoriteArtistEntry({
    required String artistKey,
    required String artistJson,
    required String addedAt,
  }) async => artists[artistKey] = artistJson;

  @override
  Future<void> deleteFavoriteArtistEntry(String artistKey) async =>
      artists.remove(artistKey);
}

Widget _app(_Database db, {double scale = 1}) => ProviderScope(
  overrides: [
    libraryCollectionsProvider.overrideWith(
      () => LibraryCollectionsNotifier(database: db),
    ),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(textScaler: TextScaler.linear(scale)),
      child: const Scaffold(
        body: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(width: 50, height: 50),
              SizedBox(width: 24),
              Flexible(
                child: ArtistFollowButton(
                  artistId: 'artist-1',
                  providerId: 'provider',
                  name: 'Example artist',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('shows Follow, toggles to Following and persists', (
    tester,
  ) async {
    final db = _Database();
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(find.text('Follow'), findsOneWidget);

    await tester.tap(find.byType(ArtistFollowButton));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);
    expect(db.artists, hasLength(1));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_app(db));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsOneWidget);

    await tester.tap(find.byType(ArtistFollowButton));
    await tester.pumpAndSettle();
    expect(find.text('Follow'), findsOneWidget);
    expect(db.artists, isEmpty);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets('has no overflow at 320 dp with text x$scale', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_app(_Database(), scale: scale));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ArtistFollowButton));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
