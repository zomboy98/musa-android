import 'dart:io';
import 'dart:ui' as ui;
import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/player_song_journey.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader('Inter')..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader('MaterialIcons')..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final config in [(390.0, 844.0, 1.0), (320.0, 568.0, 2.0)]) {
    for (final credits in [true, false]) {
      testWidgets('journey $config credits=$credits', (tester) async {
        tester.view.physicalSize = Size(config.$1, config.$2);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final metadata = PlayerMetadataController();
        addTearDown(metadata.dispose);
        final item = MediaItem(id: 'fixture', title: 'Canción de prueba', artist: 'Artista de prueba', album: 'Álbum de prueba', extras: {'displayMetadata': credits ? {'lyricist': 'Letrista de prueba', 'composer': 'Compositora de prueba', 'label': 'Sello de prueba', 'copyright': 'Titular de prueba', 'genre': 'Género de prueba', 'date': '2026', 'lyrics_provider': 'Proveedor de prueba'} : <String, String>{}});
        await metadata.load(item);
        final key = GlobalKey();
        await tester.pumpWidget(RepaintBoundary(key: key, child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: MornyeTheme.build(Brightness.dark), locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(config.$3), disableAnimations: true), child: child!),
          home: Scaffold(body: PlayerSongJourney(item: item, metadata: metadata, playerHeight: config.$2,
            player: LayoutBuilder(builder: (context, constraints) => Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Container(width: config.$1 * .65, height: config.$1 * .65, decoration: BoxDecoration(color: Colors.blueGrey.shade900, borderRadius: BorderRadius.circular(18)), child: const Icon(Icons.music_note, size: 80)),
              const SizedBox(height: 20), const Text('Canción de prueba'), const Text('Artista de prueba'),
              const Row(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.skip_previous), SizedBox(width: 30), Icon(Icons.play_circle, size: 50), SizedBox(width: 30), Icon(Icons.skip_next)])])),
            lyrics: const Padding(padding: EdgeInsets.all(20), child: Text('Una luz cruza la sala,\nse dibuja sobre el suelo.\nHoy inventamos el ritmo,\ny dejamos pasar el tiempo.')),
            nextItem: const MediaItem(id: 'next', title: 'Siguiente canción de prueba'), onArtist: () {}, onAlbum: () {}, onNextItem: () {}, onOpenQueue: () {}, compactAction: const Icon(Icons.play_arrow),
          )))));
        await tester.pumpAndSettle();
        if (credits) {
          for (final label in ['Derechos de autor', 'Género', 'Fecha de lanzamiento', 'Proveedor de letras', 'Letra', 'Letrista de prueba']) {
            expect(find.text(label), findsOneWidget);
          }
          for (final label in ['Copyright', 'Genre', 'Date', 'Lyrics Provider', 'Written by: Letrista de prueba']) {
            expect(find.text(label), findsNothing);
          }
        }
        Future<void> capture(String stage) async {
          final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            final dir = Directory('design/diagnostico-reproductor'); await dir.create(recursive: true);
            await File('${dir.path}/${config.$1.toInt()}x${config.$2.toInt()}-texto${(config.$3*100).toInt()}-${credits ? 'con' : 'sin'}-creditos-$stage.png').writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await capture('inicio');
        await tester.drag(find.byKey(const ValueKey('player-song-journey')), Offset(0, -config.$2 * .8)); await tester.pumpAndSettle(); await capture('letra');
        await tester.drag(find.byKey(const ValueKey('player-song-journey')), Offset(0, -config.$2 * .8)); await tester.pumpAndSettle(); await capture('datos');
        await tester.drag(find.byKey(const ValueKey('player-song-journey')), const Offset(0, -2000)); await tester.pumpAndSettle(); await capture('final');
        expect(tester.takeException(), isNull);
      });
    }
  }
}
