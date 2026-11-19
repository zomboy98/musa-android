import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

Widget _host(Widget child, {double width = 320, double scale = 1}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 640),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(body: Center(child: child)),
      ),
    );

void main() {
  testWidgets('every mark paints and its lockup fits a 320 dp row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final mark in QualityMark.values) {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: 200,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: QualityMarkLockup(mark: mark, detail: '96 kbps'),
            ),
          ),
          scale: 2,
        ),
      );
      expect(tester.takeException(), isNull, reason: mark.name);
    }
  });

  testWidgets('the Spanish lockup never overflows a 360 dp row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 1.3]) {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(360, 640),
              textScaler: TextScaler.linear(scale),
            ),
            child: const Scaffold(
              body: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  width: 230,
                  child: QualityMarkLockup(
                    mark: QualityMark.lossless,
                    detail: '16-bit / 44.1 kHz',
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'scale $scale');
    }
  });

  testWidgets('gallery of the marks', (tester) async {
    final dir = Platform.environment['QUALITY_GALLERY_DIR'];
    if (dir == null) return;
    tester.view.physicalSize = const Size(900, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          backgroundColor: const Color(0xFF6B5033),
          body: RepaintBoundary(
            key: key,
            child: Container(
              color: const Color(0xFF6B5033),
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 24,
                runSpacing: 24,
                children: [
                  for (final mark in QualityMark.values)
                    QualityMarkIcon(mark: mark, size: 96, color: Colors.white),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/marks.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    });
  });

  testWidgets('lockup text never drops below 11 px and scale is capped', (
    tester,
  ) async {
    for (final scale in [0.8, 1.0, 3.0]) {
      await tester.pumpWidget(
        _host(
          const QualityMarkLockup(
            mark: QualityMark.flac,
            detail: '96 kbps',
            size: 22,
          ),
          scale: scale,
        ),
      );
      final texts = tester.widgetList<Text>(
        find.descendant(
          of: find.byType(QualityMarkLockup),
          matching: find.byType(Text),
        ),
      );
      expect(texts, isNotEmpty);
      for (final text in texts) {
        final base = text.style!.fontSize!;
        expect(base, greaterThanOrEqualTo(minQualityTextSize));
        expect(
          text.textScaler!.scale(base),
          lessThanOrEqualTo(base * 1.3 + 0.01),
        );
        expect(
          text.textScaler!.scale(base),
          greaterThanOrEqualTo(minQualityTextSize * 0.8),
        );
      }
    }
  });

  testWidgets('a compact lockup keeps only the icon and the name', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        const QualityMarkLockup(
          mark: QualityMark.flac,
          detail: '96 kbps',
          size: 22,
          compact: true,
        ),
      ),
    );
    expect(find.text('FLAC'), findsOneWidget);
    expect(find.text('Free Lossless'), findsNothing);
    expect(find.text('Audio Codec'), findsNothing);
  });
}
