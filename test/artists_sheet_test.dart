import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:mornye/widgets/artists_sheet.dart';

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

const _artists = [
  ArtistsSheetArtist(
    name: 'Natanael Cano',
    id: 'deezer:1',
    extensionId: 'deezer',
    imageUrl: 'https://example.invalid/a.jpg',
  ),
  ArtistsSheetArtist(
    name: 'Fuerza Regida',
    id: 'deezer:2',
    extensionId: 'deezer',
    imageUrl: 'https://example.invalid/b.jpg',
  ),
];

Widget _app(
  _Database db, {
  required List<ArtistsSheetArtist> artistas,
  ArtistsSheetAlbum? album,
  String? currentArtistName,
  String? currentArtistId,
  double scale = 1,
  Locale locale = const Locale('en'),
}) => ProviderScope(
  overrides: [
    libraryCollectionsProvider.overrideWith(
      () => LibraryCollectionsNotifier(database: db),
    ),
  ],
  child: MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(scale)),
      child: child!,
    ),
    home: Scaffold(
      body: Consumer(
        builder: (context, ref, _) => TextButton(
          onPressed: () => showArtistsSheet(
            context,
            ref,
            artistas: artistas,
            album: album,
            currentArtistName: currentArtistName,
            currentArtistId: currentArtistId,
          ),
          child: const Text('open'),
        ),
      ),
    ),
  ),
);

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('lists every artist with Follow and the album below', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Database(),
        artistas: _artists,
        album: ArtistsSheetAlbum(
          name: 'OLIVIA LA FLAKA',
          type: 'album',
          onAdd: () {},
        ),
      ),
    );
    await _open(tester);

    expect(find.text('Natanael Cano'), findsOneWidget);
    expect(find.text('Fuerza Regida'), findsOneWidget);
    expect(find.text('Artist'), findsNWidgets(2));
    expect(find.text('Follow'), findsNWidgets(2));
    expect(find.text('OLIVIA LA FLAKA'), findsOneWidget);
    expect(find.text('Album'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
  });

  testWidgets('a single release is labelled and has no plus without onAdd', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Database(),
        artistas: [_artists.first],
        album: const ArtistsSheetAlbum(name: 'Un sencillo', type: 'single'),
      ),
    );
    await _open(tester);

    expect(find.text('Single'), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsNothing);
  });

  testWidgets('labels follow the Spanish locale', (tester) async {
    await tester.pumpWidget(
      _app(
        _Database(),
        artistas: [_artists.first],
        album: const ArtistsSheetAlbum(name: 'Un sencillo', type: 'single'),
        locale: const Locale('es'),
      ),
    );
    await _open(tester);

    expect(find.text('Artista'), findsOneWidget);
    expect(find.text('Seguir'), findsOneWidget);
    expect(find.text('Sencillo'), findsOneWidget);
  });

  testWidgets('Follow uses the favourite artists store and toggles back', (
    tester,
  ) async {
    final db = _Database();
    await tester.pumpWidget(_app(db, artistas: _artists));
    await _open(tester);

    await tester.tap(find.text('Follow').first);
    await tester.pumpAndSettle();

    expect(find.text('Following'), findsOneWidget);
    expect(find.text('Follow'), findsOneWidget);
    expect(db.artists.keys, ['deezer:1']);

    await tester.tap(find.text('Following'));
    await tester.pumpAndSettle();
    expect(find.text('Following'), findsNothing);
    expect(db.artists, isEmpty);
  });

  testWidgets('Follow explains when the artist is not in the catalog', (
    tester,
  ) async {
    final db = _Database();
    await tester.pumpWidget(
      _app(db, artistas: const [ArtistsSheetArtist(name: 'Sin Catalogo Sa')]),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(OutlinedButton).first);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.text('Could not find this artist in the catalog to follow.'),
      findsOneWidget,
    );
    expect(db.artists, isEmpty);
  });

  testWidgets('does nothing for the artist whose page is already open', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Database(),
        artistas: [_artists.first],
        currentArtistName: 'natanael cano',
      ),
    );
    await _open(tester);
    expect(find.text('Follow'), findsNothing);

    await tester.pumpWidget(
      _app(_Database(), artistas: [_artists.first], currentArtistId: '1'),
    );
    await _open(tester);
    expect(find.text('Follow'), findsNothing);
  });

  testWidgets('opens when the current page belongs to another artist', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        _Database(),
        artistas: [_artists.first],
        currentArtistName: 'Someone else',
      ),
    );
    await _open(tester);
    expect(find.text('Follow'), findsOneWidget);
  });

  testWidgets('long names and large text do not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        _Database(),
        scale: 2,
        artistas: const [
          ArtistsSheetArtist(
            name: 'Un artista con un nombre extraordinariamente largo',
            id: 'deezer:9',
            extensionId: 'deezer',
            imageUrl: 'https://example.invalid/c.jpg',
          ),
          ArtistsSheetArtist(
            name: 'Otro',
            id: 'deezer:8',
            extensionId: 'deezer',
            imageUrl: 'https://example.invalid/d.jpg',
          ),
        ],
        album: const ArtistsSheetAlbum(
          name: 'Un álbum con un título también muy largo para la pantalla',
        ),
      ),
    );
    await _open(tester);
    expect(tester.takeException(), isNull);
  });

  test('artistsSheetArtistsFrom splits credits and resolves each by name', () {
    final parsed = artistsSheetArtistsFrom(
      'Natanael Cano, Fuerza Regida',
      '1,2',
      extensionId: 'deezer',
    );
    expect(parsed.map((a) => a.name), ['Natanael Cano', 'Fuerza Regida']);
    expect(parsed.map((a) => a.id), [null, null]);
    final single = artistsSheetArtistsFrom(
      'Armenta',
      'deezer:5',
      extensionId: 'deezer',
    );
    expect(single.single.id, 'deezer:5');
    expect(single.single.extensionId, 'deezer');
    expect(artistsSheetArtistsFrom('', null), isEmpty);
  });
}
