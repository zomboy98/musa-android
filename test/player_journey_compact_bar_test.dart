import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_backdrop.dart';
import 'package:mornye/widgets/player_song_journey.dart';
import 'package:mornye/widgets/settings_group.dart';

const _warm = CoverBackdrop([
  CoverBackdropSample(hue: 30, chroma: 50, tone: 40, share: 1),
], meanChroma: 40);
const _cool = CoverBackdrop([
  CoverBackdropSample(hue: 240, chroma: 50, tone: 40, share: 1),
], meanChroma: 40);

Widget _bar(
  CoverBackdrop backdrop, {
  MediaItem? item,
  bool highContrast = false,
  bool disableAnimations = false,
}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(
      highContrast: highContrast,
      disableAnimations: disableAnimations,
    ),
    child: Scaffold(
      body: Center(
        child: PlayerJourneyCompactBar(
          key: const ValueKey('bar'),
          item:
              item ??
              const MediaItem(
                id: 'a',
                title: 'Sad Valentine',
                artist: 'Jorsshh',
                artUri: null,
              ),
          backdrop: backdrop,
          onTap: () {},
          action: IconButton(
            tooltip: 'Pausa',
            onPressed: () {},
            icon: const Icon(Icons.pause),
          ),
        ),
      ),
    ),
  ),
);

Color _fill(WidgetTester tester) => tester
    .widget<ColoredBox>(find.byKey(const ValueKey('journey-compact-fill')))
    .color;

double _contrast(Color a, Color b) {
  final x = a.computeLuminance();
  final y = b.computeLuminance();
  final hi = x > y ? x : y;
  final lo = x > y ? y : x;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  testWidgets('la barra muestra miniatura de respaldo, texto y pausa', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(_warm));
    expect(find.text('Sad Valentine'), findsOneWidget);
    expect(find.text('Jorsshh'), findsOneWidget);
    expect(find.byIcon(Icons.music_note), findsOneWidget);
    expect(find.byTooltip('Pausa'), findsOneWidget);
    final size = tester.getSize(find.byTooltip('Pausa'));
    expect(size.width >= 44 && size.height >= 44, isTrue);
  });

  testWidgets('el color cambia con fundido al cambiar la paleta', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(_warm));
    await tester.pumpAndSettle();
    final warm = _fill(tester);
    await tester.pumpWidget(_bar(_cool));
    await tester.pump(const Duration(milliseconds: 250));
    final middle = _fill(tester);
    await tester.pumpAndSettle();
    final cool = _fill(tester);
    expect(warm, isNot(cool));
    expect(middle, isNot(warm));
    expect(middle, isNot(cool));
  });

  testWidgets('sin animaciones el color cambia de golpe', (tester) async {
    await tester.pumpWidget(_bar(_warm, disableAnimations: true));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_bar(_cool, disableAnimations: true));
    await tester.pump();
    final expected = Color.alphaBlend(
      journeyCoverTint(_cool).withValues(alpha: .62),
      Colors.black.withValues(alpha: .30),
    );
    expect(_fill(tester), expected);
  });

  testWidgets('el texto mantiene contraste 4.5 y alto contraste es solido', (
    tester,
  ) async {
    for (final backdrop in [_warm, _cool, CoverBackdrop.neutral]) {
      await tester.pumpWidget(_bar(backdrop, highContrast: true));
      await tester.pumpAndSettle();
      final background = _fill(tester);
      expect(background.a, 1.0);
      final title = tester.widget<Text>(find.text('Sad Valentine'));
      expect(_contrast(title.style!.color!, background) >= 4.5, isTrue);
      expect(find.byType(BackdropFilter), findsOneWidget);
      expect(
        tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
        isFalse,
      );
    }
  });

  testWidgets('la tarjeta en degradado invierte el lado en RTL', (
    tester,
  ) async {
    LinearGradient gradient() =>
        (tester
                        .widget<DecoratedBox>(
                          find.descendant(
                            of: find.byType(VisionGradientCard),
                            matching: find.byType(DecoratedBox),
                          ),
                        )
                        .decoration
                    as BoxDecoration)
                .gradient!
            as LinearGradient;
    for (final dir in [TextDirection.ltr, TextDirection.rtl]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: dir,
            child: const Scaffold(
              body: VisionGradientCard(child: SizedBox(height: 40)),
            ),
          ),
        ),
      );
      final g = gradient();
      expect(
        g.begin,
        dir == TextDirection.ltr ? Alignment.centerLeft : Alignment.centerRight,
      );
      expect(g.colors.first.a > g.colors.last.a, isTrue);
    }
  });
}
