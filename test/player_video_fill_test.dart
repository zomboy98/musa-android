import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/player_video_fill.dart';
import 'package:mornye/widgets/player_video_pill.dart';

Widget _host(Widget child, {bool reduce = false}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: Scaffold(body: Center(child: child)),
  ),
);

VideoFillClipper _clipper(WidgetTester tester) => tester
    .widgetList<ClipRect>(
      find.descendant(
        of: find.byType(PreparingVideoMark),
        matching: find.byType(ClipRect),
      ),
    )
    .map((c) => c.clipper)
    .whereType<VideoFillClipper>()
    .first;

VideoFillGlowPainter _glow(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(find.byKey(const ValueKey('video-fill-glow')))
            .painter!
        as VideoFillGlowPainter;

void main() {
  test('estimated fill is monotone, capped and moves in every second', () {
    var previous = -1.0;
    for (var ms = 0; ms <= 60000; ms += 100) {
      final value = videoFillProgress(ms / 1000);
      expect(value, greaterThanOrEqualTo(previous));
      expect(value, lessThan(0.95 + 1e-9));
      previous = value;
    }
    for (var s = 0; s < 45; s++) {
      expect(
        videoFillProgress(s + 1.0),
        greaterThan(videoFillProgress(s.toDouble())),
        reason: 'standing still during second $s',
      );
    }
    expect(videoFillProgress(6), closeTo(0.95 * (1 - 1 / 2.718281828), 1e-3));
  });

  test('completion rises to one within 180 ms and never goes back', () {
    final from = videoFillProgress(4);
    var previous = from;
    for (var ms = 0; ms <= 200; ms += 10) {
      final value = videoFillAt(
        seconds: 4 + ms / 1000,
        doneAt: 4,
        fillAtDone: from,
      );
      expect(value, greaterThanOrEqualTo(previous));
      previous = value;
    }
    expect(
      videoFillAt(seconds: 4.2, doneAt: 4, fillAtDone: from),
      closeTo(1, 1e-9),
    );
  });

  test('a real progress never lowers the estimate and stays under one', () {
    expect(
      videoFillAt(seconds: 10, real: 0.1),
      videoFillProgress(10),
    );
    expect(videoFillAt(seconds: 1, real: 2), 0.95);
  });

  testWidgets('the mark advances continuously, completes and honors reduce', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(PreparingVideoMark(started: DateTime.now())),
    );
    expect(find.text('…'), findsWidgets);
    expect(find.textContaining('%'), findsNothing);
    expect(_glow(tester).shimmer, isTrue);
    var previous = _clipper(tester).fill;
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      final now = _clipper(tester).fill;
      expect(now, greaterThan(previous), reason: 'still at ${i * 500} ms');
      previous = now;
    }
    await tester.pumpWidget(
      _host(PreparingVideoMark(started: DateTime.now(), done: true)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    await tester.pumpWidget(
      _host(PreparingVideoMark(started: DateTime.now()), reduce: true),
    );
    expect(_glow(tester).shimmer, isFalse);
    final a = _clipper(tester).fill;
    await tester.pump(const Duration(seconds: 1));
    expect(_clipper(tester).fill, greaterThan(a));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a real progress shows its number', (tester) async {
    await tester.pumpWidget(
      _host(PreparingVideoMark(started: DateTime.now(), realProgress: 0.42)),
    );
    expect(find.text('42 %'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
