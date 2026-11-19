import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/player_track_info_card.dart';

void main() {
  testWidgets(
    'capture information card',
    (tester) async {
      await (FontLoader('Inter')
            ..addFont(rootBundle.load('assets/fonts/InterVariable.ttf')))
          .load();
      await (FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
          .load();
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: ThemeData.dark().copyWith(
            textTheme: ThemeData.dark().textTheme.apply(fontFamily: 'Inter'),
          ),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: RepaintBoundary(
                  key: key,
                  child: const PlayerTrackInfoCard(
                    facts: TrackInfoFacts(
                      labels: ['Sello musical', 'Segundo sello'],
                      artists: ['Artista principal', 'Artista invitado'],
                      releaseDate: '2026-01-18',
                      isrc: 'USAAA1234567',
                      duration: Duration(minutes: 3, seconds: 28),
                      credits: [
                        (TrackCreditRole.producer, 'Productora musical'),
                        (TrackCreditRole.composer, 'Compositor invitado'),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory.systemTemp.createTempSync('musa-info-card-');
        final file = File('${directory.path}${Platform.pathSeparator}tarjeta.png');
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
        // Deliberately prints only a local temporary path, not metadata.
        // ignore: avoid_print
        print('CAPTURA_TARJETA: ${file.path}');
      });
      expect(find.text('Artista principal'), findsOneWidget);
      expect(find.text('Sello musical'), findsOneWidget);
    },
    skip: !const bool.fromEnvironment('MUSA_CARD_CAPTURE'),
  );
}
