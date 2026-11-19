import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/journey_enriched_info_card.dart';
import 'package:mornye/widgets/player_track_info_card.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('es'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  testWidgets('conserva metadatos y añade créditos encontrados', (
    tester,
  ) async {
    final pending = Completer<JourneyEnrichment>();
    await tester.pumpWidget(
      _app(
        JourneyEnrichedInfoCard(
          item: const MediaItem(id: 'one', title: 'Uno', artist: 'Artista'),
          facts: const TrackInfoFacts(
            isrc: 'USAAA1234567',
            labels: ['Sello original'],
          ),
          loader: (_, _) => pending.future,
        ),
      ),
    );
    pending.complete(
      const JourneyEnrichment(
        labels: ['Otro sello'],
        producers: ['Productora verificada'],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Sello original'), findsOneWidget);
    expect(find.text('Otro sello'), findsNothing);
    expect(find.text('Productora verificada'), findsOneWidget);
  });

  testWidgets('un resultado tardío no se muestra en otra canción', (
    tester,
  ) async {
    final first = Completer<JourneyEnrichment>();
    final second = Completer<JourneyEnrichment>();
    Future<JourneyEnrichment> loader(MediaItem item, TrackInfoFacts facts) =>
        item.id == 'one' ? first.future : second.future;
    Widget card(String id) => _app(
      JourneyEnrichedInfoCard(
        item: MediaItem(id: id, title: id, artist: 'Artista'),
        facts: TrackInfoFacts(
          isrc: id == 'one' ? 'USAAA1234567' : 'USBBB1234567',
        ),
        loader: loader,
      ),
    );
    await tester.pumpWidget(card('one'));
    await tester.pumpWidget(card('two'));
    first.complete(const JourneyEnrichment(labels: ['Sello antiguo']));
    second.complete(const JourneyEnrichment(labels: ['Sello nuevo']));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Sello antiguo'), findsNothing);
    expect(find.text('Sello nuevo'), findsOneWidget);
  });
}
