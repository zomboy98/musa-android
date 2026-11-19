import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/cover_image_frame.dart';
import 'package:mornye/widgets/player_artwork.dart';

Future<Uint8List> _png(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint()..color = const Color(0xFFCC3355),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

void main() {
  setUp(clearCoverAspectCache);

  Future<void> pumpFrame(
    WidgetTester tester, {
    required int imageWidth,
    required int imageHeight,
    required Size frame,
  }) async {
    final bytes = (await tester.runAsync(() => _png(imageWidth, imageHeight)))!;
    final provider = MemoryImage(bytes);
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.fromSize(
            size: frame,
            child: CoverImageFrame(image: provider),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await precacheImage(
        provider,
        tester.element(find.byType(CoverImageFrame)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    await tester.pump();
  }

  Image foreground(WidgetTester tester) =>
      tester.widget<Image>(find.byKey(CoverImageFrame.foregroundKey));

  Size painted(Size image, Size frame, BoxFit fit) =>
      applyBoxFit(fit, image, frame).destination;

  testWidgets('a square cover in a square frame is cropped by cover only', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      imageWidth: 100,
      imageHeight: 100,
      frame: const Size(200, 200),
    );
    expect(foreground(tester).fit, BoxFit.cover);
    expect(find.byKey(CoverImageFrame.fillKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 16:9 cover is shown whole over a blurred fill', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      imageWidth: 160,
      imageHeight: 90,
      frame: const Size(240, 240),
    );
    expect(foreground(tester).fit, BoxFit.contain);
    expect(find.byKey(CoverImageFrame.fillKey), findsOneWidget);
    expect(find.byType(ImageFiltered), findsOneWidget);
    final shown = painted(
      const Size(160, 90),
      const Size(240, 240),
      BoxFit.contain,
    );
    expect(shown.width, closeTo(240, 0.01));
    expect(shown.width / shown.height, closeTo(16 / 9, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 3:4 cover is shown whole in a square frame', (tester) async {
    await pumpFrame(
      tester,
      imageWidth: 90,
      imageHeight: 120,
      frame: const Size(240, 240),
    );
    expect(foreground(tester).fit, BoxFit.contain);
    expect(find.byType(ImageFiltered), findsOneWidget);
    final shown = painted(
      const Size(90, 120),
      const Size(240, 240),
      BoxFit.contain,
    );
    expect(shown.height, closeTo(240, 0.01));
    expect(shown.width / shown.height, closeTo(3 / 4, 0.001));
  });

  testWidgets('a square cover in a tall frame is not cropped at the sides', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      imageWidth: 100,
      imageHeight: 100,
      frame: const Size(200, 320),
    );
    expect(foreground(tester).fit, BoxFit.contain);
    expect(find.byKey(CoverImageFrame.fillKey), findsOneWidget);
  });

  testWidgets('a small frame uses the surface colour instead of a blur', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      imageWidth: 160,
      imageHeight: 90,
      frame: const Size(52, 52),
    );
    expect(foreground(tester).fit, BoxFit.contain);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.byKey(CoverImageFrame.fillKey), findsOneWidget);
  });

  testWidgets('an almost square cover within tolerance keeps cover', (
    tester,
  ) async {
    await pumpFrame(
      tester,
      imageWidth: 101,
      imageHeight: 100,
      frame: const Size(200, 200),
    );
    expect(foreground(tester).fit, BoxFit.cover);
  });

  test('needsContain compares proportions with a tolerance', () {
    expect(CoverImageFrame.needsContain(1, 1), isFalse);
    expect(CoverImageFrame.needsContain(1.02, 1), isFalse);
    expect(CoverImageFrame.needsContain(16 / 9, 1), isTrue);
    expect(CoverImageFrame.needsContain(0.75, 1), isTrue);
    expect(CoverImageFrame.needsContain(1, 0.5), isTrue);
  });

  testWidgets('PlayerArtwork shows a wide local cover whole when complete', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync('cover_frame_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/wide.png');
    await tester.runAsync(() async => file.writeAsBytes(await _png(160, 90)));
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox.square(
            dimension: 52,
            child: PlayerArtwork(
              complete: true,
              artUri: file.path,
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump();
    }
    expect(find.byType(CoverImageFrame), findsOneWidget);
    expect(foreground(tester).fit, BoxFit.contain);
  });
}
