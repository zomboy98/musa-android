import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_color_utilities/hct/hct.dart';
import 'package:mornye/theme/cover_backdrop.dart';
import 'package:mornye/theme/cover_palette.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

/// Straight RGBA pixels of a [size] square made of [rects]: (left, top,
/// width, height, colour) in pixels, later rects painted over earlier ones.
ByteData synthetic(
  List<(int, int, int, int, int)> rects, {
  int size = 100,
  int base = 0xff000000,
}) {
  final data = ByteData(size * size * 4);
  void put(int x, int y, int argb) {
    final offset = (y * size + x) * 4;
    data
      ..setUint8(offset, (argb >> 16) & 255)
      ..setUint8(offset + 1, (argb >> 8) & 255)
      ..setUint8(offset + 2, argb & 255)
      ..setUint8(offset + 3, 255);
  }

  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      put(x, y, base);
    }
  }
  for (final (left, top, width, height, argb) in rects) {
    for (var y = top; y < top + height; y++) {
      for (var x = left; x < left + width; x++) {
        put(x, y, argb);
      }
    }
  }
  return data;
}

double hueOf(int argb) => Hct.fromInt(argb).hue;

double hueGap(double a, double b) {
  final delta = (a - b).abs() % 360;
  return delta > 180 ? 360 - delta : delta;
}

double contrastWithWhite(Color color) =>
    1.05 / (color.computeLuminance() + 0.05);

/// All the colours a Mornye player background can show for [backdrop].
List<Color> surfaces(CoverBackdrop backdrop) => [
  for (final fullBleed in [true, false])
    ...mornyeBackdropGradient(backdrop, fullBleed: fullBleed).colors,
];

double maxChroma(Iterable<Color> colors) => colors
    .map((color) => Hct.fromInt(color.toARGB32()).chroma)
    .reduce((a, b) => a > b ? a : b);

void main() {
  // Floral cover: 35 % green, 25 % yellow, 25 % purple, 15 % dark leaves.
  final floral = synthetic([
    (0, 0, 100, 35, 0xff3f9d3a),
    (0, 35, 100, 25, 0xffe8c820),
    (0, 60, 100, 25, 0xff7b3fb0),
  ], base: 0xff10200f);
  // Black and white with a red-green strip of 7 % of the area.
  final strip = synthetic([
    (0, 0, 100, 50, 0xffffffff),
    (0, 93, 4, 7, 0xffc8102e),
    (4, 93, 4, 7, 0xff1f8a3c),
    (8, 93, 4, 7, 0xffc8102e),
  ], base: 0xff0a0a0a);
  // Red curtains, a rose-beige bust in the middle and black at the sides.
  final olympus = synthetic([
    (0, 0, 100, 100, 0xffb3121f),
    (30, 10, 40, 90, 0xffd9b8a8),
    (0, 0, 12, 100, 0xff0a0505),
    (88, 0, 12, 100, 0xff0a0505),
  ]);
  final blue = synthetic([(0, 0, 100, 100, 0xff1e5fd0)]);
  final white = synthetic([(0, 0, 100, 100, 0xfff6f6f4)]);
  final black = synthetic([(0, 0, 100, 100, 0xff070708)]);

  group('dominant colours', () {
    test('a multicolour cover keeps its population-weighted hues', () {
      final backdrop = analyzeCoverBackdrop(floral);
      expect(backdrop.samples.length, 3);
      // Green is the biggest zone; yellow and purple tie for the rest.
      expect(hueGap(backdrop.samples[0].hue, hueOf(0xff3f9d3a)), lessThan(20));
      final rest = backdrop.samples.skip(1).map((s) => s.hue).toList();
      for (final argb in [0xffe8c820, 0xff7b3fb0]) {
        expect(
          rest.any((hue) => hueGap(hue, hueOf(argb)) < 20),
          isTrue,
          reason: '$argb in $rest',
        );
      }
      expect(
        backdrop.samples.fold<double>(0, (sum, s) => sum + s.share),
        closeTo(1, 1e-9),
      );
      final colors = mornyeBackdropGradient(backdrop, fullBleed: false).colors;
      // The background is multicolour: its stops follow the three hues.
      expect(
        hueGap(hueOf(colors[0].toARGB32()), hueOf(colors[1].toARGB32())),
        greaterThan(25),
      );
      expect(
        hueGap(hueOf(colors[1].toARGB32()), hueOf(colors[2].toARGB32())),
        greaterThan(25),
      );
    });

    test('the dominant sample is the biggest zone, not the most saturated', () {
      // 70 % muted blue against 30 % extremely saturated red.
      final backdrop = analyzeCoverBackdrop(
        synthetic([(0, 0, 100, 70, 0xff5a7596), (0, 70, 100, 30, 0xffff0010)]),
      );
      expect(
        hueGap(backdrop.samples.first.hue, hueOf(0xff5a7596)),
        lessThan(15),
      );
    });

    test('a small strip never dominates a black and white cover', () {
      final backdrop = analyzeCoverBackdrop(strip);
      expect(backdrop.samples.first.chroma, lessThan(5));
      expect(backdrop.isMostlyNeutral, isTrue);
      // Neither the strip's red nor its green leaves a visible tint.
      for (final color in surfaces(backdrop)) {
        expect(Hct.fromInt(color.toARGB32()).chroma, lessThan(9));
      }
    });

    test('a saturated red cover gives a vivid red background', () {
      final backdrop = analyzeCoverBackdrop(olympus);
      expect(
        hueGap(backdrop.samples.first.hue, hueOf(0xffb3121f)),
        lessThan(15),
      );
      final hsl = [
        for (final color in mornyeBackdropGradient(
          backdrop,
          fullBleed: true,
        ).colors)
          HSLColor.fromColor(color),
      ];
      for (final color in surfaces(backdrop)) {
        expect(contrastWithWhite(color), greaterThanOrEqualTo(4.5));
      }
      for (final c in hsl) {
        expect(c.saturation, greaterThan(0.35));
        expect(hueGap(c.hue, 355), lessThan(25));
      }
    });

    test('a grayscale gradient cover stays neutral and readable', () {
      final gray = synthetic([
        (0, 0, 100, 50, 0xff808080),
        (0, 50, 100, 50, 0xffc0c0c0),
      ]);
      final backdrop = analyzeCoverBackdrop(gray);
      expect(backdrop.isMostlyNeutral, isTrue);
      for (final color in surfaces(backdrop)) {
        expect(contrastWithWhite(color), greaterThanOrEqualTo(4.5));
        expect(Hct.fromInt(color.toARGB32()).chroma, lessThan(9));
      }
    });

    test('a monochrome cover tints with its own hue, calmly', () {
      final backdrop = analyzeCoverBackdrop(blue);
      expect(backdrop.samples.length, 1);
      expect(
        hueGap(backdrop.samples.first.hue, hueOf(0xff1e5fd0)),
        lessThan(8),
      );
      final colors = surfaces(backdrop);
      for (final color in colors) {
        expect(
          hueGap(hueOf(color.toARGB32()), hueOf(0xff1e5fd0)),
          lessThan(12),
        );
      }
      expect(maxChroma(colors), lessThanOrEqualTo(64));
      expect(maxChroma(colors), greaterThan(15));
    });

    test('almost white and almost black covers give low chroma neutrals', () {
      for (final data in [white, black]) {
        final backdrop = analyzeCoverBackdrop(data);
        expect(backdrop.isMostlyNeutral, isTrue);
        expect(maxChroma(surfaces(backdrop)), lessThan(5));
      }
    });

    test('colourless or missing covers are plain gray', () {
      for (final backdrop in [
        CoverBackdrop.neutral,
        analyzeCoverBackdropBytes(null),
        analyzeCoverBackdrop(ByteData(0)),
      ]) {
        expect(backdrop.isNeutral, isTrue);
        expect(maxChroma(surfaces(backdrop)), lessThan(2));
      }
    });

    test('transparent pixels count for nothing', () {
      final data = ByteData(10 * 10 * 4);
      expect(analyzeCoverBackdrop(data).isNeutral, isTrue);
    });

    test('every backdrop keeps white text readable', () {
      for (final data in [floral, strip, blue, white, black]) {
        for (final color in surfaces(analyzeCoverBackdrop(data))) {
          expect(
            contrastWithWhite(color),
            greaterThanOrEqualTo(4.5),
            reason: '$color',
          );
        }
      }
      // Even a tone-100 yellow cover stays dark enough.
      final yellow = analyzeCoverBackdrop(
        synthetic([(0, 0, 100, 100, 0xfffff200)]),
      );
      for (final color in surfaces(yellow)) {
        expect(contrastWithWhite(color), greaterThanOrEqualTo(4.5));
      }
    });

    test('the same pixels give the same result', () {
      expect(analyzeCoverBackdrop(floral), analyzeCoverBackdrop(floral));
      expect(
        mornyeBackdropGradient(analyzeCoverBackdrop(strip), fullBleed: true),
        mornyeBackdropGradient(analyzeCoverBackdrop(strip), fullBleed: true),
      );
    });

    test('chroma weight is soft and capped', () {
      expect(coverChromaWeight(0), 1);
      expect(coverChromaWeight(60), 2.5);
      expect(coverChromaWeight(120), 2.5);
    });
  });

  group('cover changes', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('backdrop-state-');
    });
    tearDown(() {
      final cache = PaintingBinding.instance.imageCache;
      cache.clear();
      cache.clearLiveImages();
      directory.deleteSync(recursive: true);
    });

    Future<String> write(WidgetTester tester, String name, Color color) async {
      final path = '${directory.path}/$name.png';
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(color, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(32, 32);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        image.dispose();
        picture.dispose();
        await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      });
      return path;
    }

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    CoverBackdrop? shown;
    Widget host(String? source) => CoverBackdropBuilder(
      imageSource: source,
      builder: (context, backdrop) {
        shown = backdrop;
        return const SizedBox();
      },
    );

    const blueArgb = 0xff1565c0;
    const orangeArgb = 0xffe65100;

    testWidgets('moves to the palette of the next track', (tester) async {
      final a = await write(tester, 'a', const Color(blueArgb));
      final b = await write(tester, 'b', const Color(orangeArgb));
      await tester.pumpWidget(host(a));
      await settle(tester);
      expect(hueGap(shown!.samples.first.hue, hueOf(blueArgb)), lessThan(8));
      await tester.pumpWidget(host(b));
      await settle(tester);
      expect(hueGap(shown!.samples.first.hue, hueOf(orangeArgb)), lessThan(8));
      // Coming back to a cached cover answers from the cache at once.
      await tester.pumpWidget(host(a));
      expect(hueGap(shown!.samples.first.hue, hueOf(blueArgb)), lessThan(8));
    });

    testWidgets('a track whose cover fails never keeps the previous palette', (
      tester,
    ) async {
      final a = await write(tester, 'a', const Color(blueArgb));
      await tester.pumpWidget(host(a));
      await settle(tester);
      expect(shown!.isNeutral, isFalse);
      await tester.pumpWidget(host('${directory.path}/missing.png'));
      await settle(tester);
      expect(shown!.isNeutral, isTrue);
      // A cover that is not an image fails the same way.
      final broken = File('${directory.path}/broken.png')
        ..writeAsBytesSync([1, 2, 3, 4]);
      await tester.pumpWidget(host(a));
      await settle(tester);
      expect(shown!.isNeutral, isFalse);
      await tester.pumpWidget(host(broken.path));
      await settle(tester);
      expect(shown!.isNeutral, isTrue);
      // And a track without any cover.
      await tester.pumpWidget(host(a));
      await settle(tester);
      await tester.pumpWidget(host(null));
      expect(shown!.isNeutral, isTrue);
    });

    testWidgets('a late result of the previous track does not overwrite', (
      tester,
    ) async {
      final a = await write(tester, 'a', const Color(blueArgb));
      final b = await write(tester, 'b', const Color(orangeArgb));
      // Both requests are in flight together; A started first.
      await tester.pumpWidget(host(a));
      await tester.pumpWidget(host(b));
      await settle(tester);
      expect(hueGap(shown!.samples.first.hue, hueOf(orangeArgb)), lessThan(8));
      // And the other way round, ending on the failing cover.
      await tester.pumpWidget(host(a));
      await tester.pumpWidget(host('${directory.path}/missing.png'));
      await settle(tester);
      expect(shown!.isNeutral, isTrue);
    });

    testWidgets('the resolver is per cover and deterministic', (tester) async {
      final a = await write(tester, 'a', const Color(blueArgb));
      final b = await write(tester, 'b', const Color(orangeArgb));
      CoverBackdrop? first;
      CoverBackdrop? second;
      CoverBackdrop? other;
      await tester.runAsync(() async {
        first = await CoverPalette.resolveBackdrop(a);
        other = await CoverPalette.resolveBackdrop(b);
        second = await CoverPalette.resolveBackdrop(a);
      });
      expect(first, isNotNull);
      expect(second, first);
      expect(other, isNot(first));
      expect(CoverPalette.peekBackdrop(b), other);
      expect(
        await tester.runAsync(
          () => CoverPalette.resolveBackdrop('${directory.path}/none.png'),
        ),
        isNull,
      );
    });
  });
}
