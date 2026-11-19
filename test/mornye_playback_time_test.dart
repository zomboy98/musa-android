import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/mornye_playback_time.dart';

Widget _app(int seconds, {bool remaining = false, bool reduceMotion = false}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduceMotion),
        child: Scaffold(
          body: Align(
            alignment: Alignment.centerRight,
            child: MornyePlaybackTime(
              seconds: seconds,
              remaining: remaining,
              style: const TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('Reduced-motion remaining time stays left to right in RTL', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Directionality(
            textDirection: TextDirection.rtl,
            child: MornyePlaybackTime(
              seconds: 599,
              remaining: true,
              style: TextStyle(fontSize: 14),
            ),
          ),
        ),
      ),
    );
    final paragraph = tester.renderObject<RenderParagraph>(find.text('-9:59'));
    expect(paragraph.textDirection, TextDirection.ltr);
    expect(find.bySemanticsLabel('-9:59'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    semantics.dispose();
  });

  testWidgets('Each counter is a single tabular Text with no overlap', (
    tester,
  ) async {
    await tester.pumpWidget(_app(34));
    expect(find.byType(Text), findsOneWidget);
    expect(find.byType(AnimatedSwitcher), findsNothing);
    final text = tester.widget<Text>(find.text('0:34'));
    expect(text.style?.fontFeatures, contains(const FontFeature.tabularFigures()));

    await tester.pumpWidget(_app(35));
    await tester.pump(const Duration(milliseconds: 80));
    expect(find.byType(Text), findsOneWidget);
    expect(find.text('0:34'), findsNothing);
    expect(find.text('0:35'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('Remaining time keeps one Text across minute rollover', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(_app(599, remaining: true));
    expect(find.byType(Text), findsOneWidget);
    await tester.pumpWidget(_app(600, remaining: true));
    expect(find.byType(Text), findsOneWidget);
    expect(find.bySemanticsLabel('-10:00'), findsOneWidget);
    expect(find.bySemanticsLabel('-9:59'), findsNothing);
    semantics.dispose();
  });

  testWidgets('Reduce Motion updates time directly', (tester) async {
    await tester.pumpWidget(_app(34, reduceMotion: true));
    await tester.pumpWidget(_app(36, reduceMotion: true));
    expect(find.text('0:36'), findsOneWidget);
    expect(find.byType(Text), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
