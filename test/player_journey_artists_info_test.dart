import 'dart:typed_data';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/artist_avatar.dart';
import 'package:mornye/widgets/journey_artists_list.dart';
import 'package:mornye/widgets/player_song_journey.dart';
import 'package:mornye/widgets/player_track_info_card.dart';

Widget _app(
  Widget child, {
  Locale locale = const Locale('es'),
  double scale = 1,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

MediaItem _item({Map<String, dynamic> meta = const {}, Duration? duration}) =>
    MediaItem(
      id: 'mdld',
      title: 'MDLD',
      artist: 'Natanael Cano, Bajo Perfil',
      album: 'Natanael Cano, Vol.1',
      duration: duration,
      extras: {'source': '/music/mdld.flac', 'displayMetadata': meta},
    );

TrackInfoFacts _facts(MediaItem item) => buildTrackInfoFacts(
  item: item,
  field: (key) {
    final value = (item.extras?['displayMetadata'] as Map?)?[key]?.toString();
    return value == null || value.trim().isEmpty ? null : value.trim();
  },
);

class _BrokenImage extends ImageProvider<_BrokenImage> {
  @override
  Future<_BrokenImage> obtainKey(ImageConfiguration configuration) =>
      Future.value(this);

  @override
  ImageStreamCompleter loadImage(
    _BrokenImage key,
    ImageDecoderCallback decode,
  ) => OneFrameImageStreamCompleter(Future.error(StateError('sin imagen')));
}

void main() {
  test('separa artistas combinados y respeta nombres con coma conocidos', () {
    expect(splitJourneyArtists('Natanael Cano, Bajo Perfil'), [
      'Natanael Cano',
      'Bajo Perfil',
    ]);
    expect(splitJourneyArtists('A & B'), ['A', 'B']);
    expect(splitJourneyArtists('A con B'), ['A', 'B']);
    expect(splitJourneyArtists('A feat. B'), ['A', 'B']);
    expect(splitJourneyArtists('Tyler, The Creator'), ['Tyler, The Creator']);
    expect(splitJourneyArtists('Tyler, The Creator, Kali Uchis'), [
      'Tyler, The Creator',
      'Kali Uchis',
    ]);
    expect(splitJourneyArtists('Bad Bunny'), ['Bad Bunny']);
    expect(splitJourneyArtists('  '), isEmpty);
  });

  test('sellos unidos por barra se separan', () {
    expect(splitRecordLabels('Rancho Humilde/Sony Music Latin'), [
      'Rancho Humilde',
      'Sony Music Latin',
    ]);
    expect(splitRecordLabels('Sony / sony'), ['Sony']);
  });

  testWidgets('artistas combinados: una fila y un avatar por artista', (
    tester,
  ) async {
    final asked = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      _app(
        JourneyArtistsList(
          artistNames: 'Natanael Cano, Bajo Perfil',
          resolver: (context, name, extensionId) async {
            asked.add(name);
            return name == 'Bajo Perfil' ? 'https://img.test/bp.jpg' : null;
          },
          imageProviderFactory: (url, pixels) => _BrokenImage(),
          onArtist: opened.add,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(asked, ['Natanael Cano', 'Bajo Perfil']);
    expect(
      find.byKey(const ValueKey('journey-artist-row-Natanael Cano')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('journey-artist-row-Bajo Perfil')),
      findsOneWidget,
    );
    expect(find.text('Natanael Cano, Bajo Perfil'), findsNothing);
    expect(find.byType(ArtistAvatar), findsNWidgets(2));
    expect(find.text('NC'), findsOneWidget);
    expect(find.text('BP'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('journey-artist-row-Bajo Perfil')),
    );
    expect(opened, ['Bajo Perfil']);
  });

  testWidgets('un fallo del resolvedor o de la imagen deja las iniciales', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            ArtistAvatar(
              name: 'Natanael Cano',
              resolver: (context, name, extensionId) async =>
                  throw StateError('sin red'),
            ),
            ArtistAvatar(
              name: 'Bajo Perfil',
              resolver: (context, name, extensionId) async =>
                  'https://img.test/bp.jpg',
              imageProviderFactory: (url, pixels) =>
                  MemoryImage(Uint8List.fromList([1, 2, 3])),
            ),
            ArtistAvatar(
              name: 'Rota',
              imageUrl: 'https://img.test/rota.jpg',
              imageProviderFactory: (url, pixels) => _BrokenImage(),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(tester.takeException(), isNull);
    expect(find.text('NC'), findsOneWidget);
    expect(find.text('BP'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    expect(find.byIcon(Icons.person_outline), findsNothing);
  });

  testWidgets('con muchos artistas se apilan y se pliegan', (tester) async {
    await tester.pumpWidget(
      _app(
        JourneyArtistsList(
          artistNames: 'A, B, C, D, E',
          resolver: (context, name, extensionId) async => null,
        ),
      ),
    );
    expect(
      find.byKey(const ValueKey('journey-artists-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('journey-artist-row-C')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('journey-artists-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('journey-artist-row-E')), findsOneWidget);
  });

  testWidgets('PlayerSongJourney muestra dos filas para artistas combinados', (
    tester,
  ) async {
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    final item = _item();
    await metadata.load(item);
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerSongJourney(
            item: item,
            metadata: metadata,
            playerHeight: 1,
            player: const SizedBox(),
            lyrics: const SizedBox(),
            onArtist: () => opened.add('todos'),
            onArtistNamed: opened.add,
            artistImageResolver: (context, name, extensionId) async => null,
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('journey-artist-row-Bajo Perfil')),
    );
    expect(opened, ['Bajo Perfil']);
  });

  group('tarjeta de informacion', () {
    final full = _item(
      duration: const Duration(minutes: 3, seconds: 7),
      meta: {
        'label': 'Rancho Humilde/Sony Music Latin',
        'date': '2026-08-28',
        'isrc': 'qz9qq2600351',
        'track_number': 3,
        'genre': 'Regional Mexican',
        'composer': 'Natanael Cano',
        'copyright': 'P 2026 Rancho Humilde',
      },
    );

    testWidgets('oculta filas sin dato y no crea tarjeta vacia', (
      tester,
    ) async {
      final facts = _facts(_item(meta: {'label': 'Solo sello'}));
      expect(facts.isEmpty, isFalse);
      expect(_facts(_item()).isEmpty, isFalse); // The credited artists remain.
      expect(const TrackInfoFacts().isEmpty, isTrue);
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: facts)));
      expect(find.text('Solo sello'), findsOneWidget);
      for (final absent in [
        'Fecha de lanzamiento',
        'ISRC',
        'Duración',
        'Pista',
        'Créditos',
        'BPM',
        'Tonalidad',
        'Género',
        'Explícito',
      ]) {
        expect(find.text(absent), findsNothing, reason: absent);
      }
    });

    test('ignora solo el marcador exacto de artista desconocido', () {
      TrackInfoFacts factsFor(String artist) => buildTrackInfoFacts(
        item: MediaItem(id: 'track', title: 'Track', artist: artist),
        field: (_) => null,
      );
      expect(factsFor('Unknown artist').isEmpty, isTrue);
      expect(factsFor('  UNKNOWN ARTIST  ').artists, isEmpty);
      expect(factsFor('Unknown Artist Orchestra').artists, [
        'Unknown Artist Orchestra',
      ]);
    });

    testWidgets('fecha formateada en espanol y en ingles', (tester) async {
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: _facts(full))));
      expect(find.text('28 de agosto de 2026'), findsOneWidget);
      await tester.pumpWidget(
        _app(
          PlayerTrackInfoCard(facts: _facts(full)),
          locale: const Locale('en'),
        ),
      );
      await tester.pump();
      expect(find.text('August 28, 2026'), findsOneWidget);
    });

    testWidgets('separa sellos, muestra pista, duracion y genero', (
      tester,
    ) async {
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: _facts(full))));
      expect(find.text('Rancho Humilde'), findsOneWidget);
      expect(find.text('Sony Music Latin'), findsOneWidget);
      expect(find.text('Pista 3'), findsOneWidget);
      expect(find.text('3:07'), findsOneWidget);
      expect(find.text('Regional mexicano'), findsOneWidget);
      expect(find.text('P 2026 Rancho Humilde'), findsOneWidget);
      expect(find.text('Natanael Cano'), findsNWidgets(2));
    });

    testWidgets('copia el ISRC al portapapeles y confirma', (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: _facts(full))));
      expect(find.text('QZ9QQ2600351'), findsOneWidget);
      expect(find.byIcon(Icons.check), findsNothing);
      final size = tester.getSize(
        find.byKey(const ValueKey('journey-copy-isrc')),
      );
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
      await tester.tap(find.byKey(const ValueKey('journey-copy-isrc')));
      await tester.pump();
      expect(copied, ['QZ9QQ2600351']);
      expect(find.byIcon(Icons.check), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsNothing);
    });

    testWidgets('creditos se pliegan', (tester) async {
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: _facts(full))));
      expect(find.text('Compositor'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('journey-credits-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Compositor'), findsNothing);
    });

    testWidgets('separa identidades y conserva el resto de los datos', (
      tester,
    ) async {
      final facts = _facts(
        _item(
          meta: {
            'label': 'Sello Uno/Sello Dos',
            'producer': 'Productora Uno; Productora Dos',
            'date': '2026-08-28',
          },
        ),
      );
      expect(facts.artists, ['Natanael Cano', 'Bajo Perfil']);
      final enriched = facts.copyWith(
        labelImages: const {
          'Sello Uno': JourneyIdentityArtwork(
            url: 'http://example.test/logo.png',
            attribution: 'Autor / Licencia',
            license: 'CC0',
          ),
        },
      );
      expect(enriched.releaseDate, facts.releaseDate);
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: enriched)));
      for (final name in [
        'Sello Uno',
        'Sello Dos',
        'Productora Uno',
        'Productora Dos',
        'Natanael Cano',
        'Bajo Perfil',
      ]) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      // An insecure URL is not requested or presented as verified artwork.
      expect(find.byType(Image), findsNothing);
      expect(find.text('Autor / Licencia'), findsNothing);
    });

    testWidgets('muestra fuente de arte verificado y exige licencia enlazada', (
      tester,
    ) async {
      final facts = _facts(_item(meta: {'label': 'Sello Uno'}));
      final noLicenseLink = facts.copyWith(
        labelImages: const {
          'Sello Uno': JourneyIdentityArtwork(
            url: 'https://example.test/logo.png',
            attribution: 'Autor · CC BY-SA 4.0',
            license: 'CC BY-SA 4.0',
            sourceUrl: 'https://example.test/source',
          ),
        },
      );
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: noLicenseLink)));
      expect(find.byType(Image), findsNothing);
      expect(find.text('Autor · CC BY-SA 4.0'), findsNothing);

      final publicDomain = facts.copyWith(
        labelImages: const {
          'Sello Uno': JourneyIdentityArtwork(
            url: 'https://example.test/logo.png',
            attribution: 'Autor · Public domain',
            license: 'Public domain',
            sourceUrl: 'https://example.test/source',
          ),
        },
      );
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: publicDomain)));
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('Autor · Public domain'), findsOneWidget);
      expect(find.text('Origen'), findsOneWidget);
      expect(tester.takeException(), isNull);

      final licensed = facts.copyWith(
        labelImages: const {
          'Sello Uno': JourneyIdentityArtwork(
            url: 'https://example.test/logo.png',
            attribution: 'Autor · CC BY-SA 4.0',
            license: 'CC BY-SA 4.0',
            sourceUrl: 'https://example.test/source',
            licenseUrl: 'https://example.test/license',
          ),
        },
      );
      await tester.pumpWidget(_app(PlayerTrackInfoCard(facts: licensed)));
      await tester.pump();
      expect(find.text('Autor · CC BY-SA 4.0'), findsOneWidget);
      expect(find.text('Origen'), findsOneWidget);
      expect(find.text('Licencias'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'identidades se adaptan en pantalla estrecha con texto grande',
      (tester) async {
        tester.view.physicalSize = const Size(320, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final facts = _facts(
          _item(
            meta: {
              'label':
                  'Un sello con nombre muy largo / Otro sello también largo',
              'producer':
                  'Una productora con nombre bastante largo; Otra productora',
            },
          ),
        );
        await tester.pumpWidget(
          _app(PlayerTrackInfoCard(facts: facts), scale: 2),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('Otra productora'), findsOneWidget);
      },
    );

    testWidgets('no desborda a 360 dp con escala de texto 1.3', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final item = _item(
        duration: const Duration(minutes: 3, seconds: 7),
        meta: {
          'label':
              'Sello con un nombre extremadamente largo/Otro sello igualmente largo',
          'date': '2026-08-28',
          'isrc': 'QZ9QQ2600351',
          'track_number': '3/12',
          'disc_number': '2/2',
          'genre': 'Regional Mexican; Hip Hop; Trap',
          'composer': 'Compositor con un nombre larguisimo, Otra persona',
          'lyricist': 'Letrista',
          'producer': 'Productor',
          'engineer': 'Ingeniero',
          'bpm': '128',
          'key': 'C minor',
          'copyright': 'P 2026 Un titular de derechos con nombre muy largo',
          'explicit': true,
        },
      );
      await tester.pumpWidget(
        _app(PlayerTrackInfoCard(facts: _facts(item)), scale: 1.3),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('BPM'), findsOneWidget);
      expect(find.text('Tonalidad'), findsOneWidget);
      expect(find.text('Pista 3 de 12 · Disco 2'), findsOneWidget);
      expect(find.text('E'), findsOneWidget);
    });
  });
}
