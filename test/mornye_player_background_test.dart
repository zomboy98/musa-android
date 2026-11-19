import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_mimic.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';
import 'package:mornye/widgets/mornye_player_background.dart';

const _width = 200.0;
const _height = 400.0;
const _boundary = ValueKey('boundary');

Future<CoverMimicData> _cover(List<Color> quadrants) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const half = 8.0;
  for (var i = 0; i < 4; i++) {
    canvas.drawRect(
      Rect.fromLTWH((i % 2) * half, (i ~/ 2) * half, half, half),
      Paint()..color = quadrants[i],
    );
  }
  final picture = recorder.endRecording();
  final image = await picture.toImage(16, 16);
  picture.dispose();
  final data = (await CoverMimicCache.blurCover(image))!;
  image.dispose();
  return data;
}

void main() {
  late Map<String, CoverMimicData> covers;

  setUp(() {
    covers = {};
    CoverMimicCache.debugClear();
    CoverMimicCache.debugLoader = (source) async {
      for (final entry in covers.entries) {
        if (source.endsWith(entry.key)) return entry.value;
      }
      return null;
    };
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.single;
    view.physicalSize = const Size(_width, _height);
    view.devicePixelRatio = 1;
  });
  tearDown(() {
    CoverMimicCache.debugLoader = null;
    TestWidgetsFlutterBinding.instance.platformDispatcher.views.single.reset();
  });

  Widget host(Widget child, {bool reduced = false}) => Directionality(
    textDirection: TextDirection.ltr,
    child: MediaQuery(
      data: MediaQueryData(
        size: const Size(_width, _height),
        disableAnimations: reduced,
      ),
      child: RepaintBoundary(
        key: _boundary,
        child: SizedBox(width: _width, height: _height, child: child),
      ),
    ),
  );

  Widget scope(String name, {bool reduced = false}) => host(
    CoverMimicScope(
      source: 'file:///$name',
      artworkHeight: _width,
      builder: (context, scene) => CoverMimicLayer(scene: scene),
    ),
    reduced: reduced,
  );

  Future<ByteData> pixels(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final image = await tester
            .renderObject<RenderRepaintBoundary>(find.byKey(_boundary))
            .toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!;
      }))!;

  List<int> at(ByteData data, int x, int y) {
    final i = (y * _width.toInt() + x) * 4;
    return [data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)];
  }

  int distance(List<int> a, List<int> b) {
    var total = 0;
    for (var i = 0; i < 3; i++) {
      total += (a[i] - b[i]).abs();
    }
    return total;
  }

  Future<void> load(WidgetTester tester, Map<String, List<Color>> specs) async {
    for (final entry in specs.entries) {
      covers[entry.key] = (await tester.runAsync(() => _cover(entry.value)))!;
    }
  }

  const warm = [
    Color(0xffe05020),
    Color(0xfff0a030),
    Color(0xffc03020),
    Color(0xffffd060),
  ];
  const cool = [
    Color(0xff2040e0),
    Color(0xff20a0d0),
    Color(0xff101890),
    Color(0xff60e0f0),
  ];

  testWidgets('mutates to the next cover instead of cutting', (tester) async {
    await load(tester, {'a.png': warm, 'b.png': cool});
    await tester.pumpWidget(scope('a.png'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final first = at(await pixels(tester), 100, 300);

    await tester.pumpWidget(scope('b.png'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final middle = at(await pixels(tester), 100, 300);
    await tester.pump(const Duration(seconds: 1));
    final last = at(await pixels(tester), 100, 300);

    expect(distance(first, last), greaterThan(40));
    expect(distance(middle, first), greaterThan(8));
    expect(distance(middle, last), greaterThan(8));
  });

  testWidgets('without animations it changes at once and never moves', (
    tester,
  ) async {
    await load(tester, {'a.png': warm, 'b.png': cool});
    await tester.pumpWidget(scope('a.png', reduced: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final first = at(await pixels(tester), 100, 300);
    await tester.pumpWidget(scope('b.png', reduced: true));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    final next = at(await pixels(tester), 100, 300);
    expect(distance(first, next), greaterThan(40));
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pump(const Duration(seconds: 30));
    expect(at(await pixels(tester), 100, 300), next);
  });

  testWidgets('drifts slowly with one ticker and stops with its route', (
    tester,
  ) async {
    CoverMimicScope.debugAmbientDrift = true;
    addTearDown(() => CoverMimicScope.debugAmbientDrift = false);
    await load(tester, {'a.png': warm});
    CoverMimicScene? scene;
    await tester.pumpWidget(
      host(
        CoverMimicScope(
          source: 'file:///a.png',
          artworkHeight: _width,
          builder: (context, value) {
            scene = value;
            return CoverMimicLayer(scene: value);
          },
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(scene!.clock, closeTo(5, 0.1));
    expect(tester.binding.hasScheduledFrame, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(tester.binding.hasScheduledFrame, isFalse);
  });

  testWidgets('keeps 4.5:1 for white text on light, dark and flat covers', (
    tester,
  ) async {
    final specs = <String, List<Color>>{
      'white.png': List.filled(4, Colors.white),
      'cream.png': List.filled(4, const Color(0xfffff6d0)),
      'black.png': List.filled(4, Colors.black),
      'gray.png': const [
        Color(0xff101010),
        Color(0xffe8e8e8),
        Color(0xff404040),
        Color(0xffa0a0a0),
      ],
      'yellow.png': List.filled(4, const Color(0xffffff00)),
    };
    await load(tester, specs);
    for (final name in specs.keys) {
      await tester.pumpWidget(scope(name));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      final data = await pixels(tester);
      var worst = 21.0;
      for (var y = 0; y < _height; y += 10) {
        for (var x = 0; x < _width; x += 10) {
          final p = at(data, x, y);
          final ratio = mimicContrastWithWhite(
            mimicPixelLuminance(p[0], p[1], p[2]),
          );
          if (ratio < worst) worst = ratio;
        }
      }
      expect(worst, greaterThanOrEqualTo(4.5), reason: name);
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('the artwork melts into the backdrop without an edge', (
    tester,
  ) async {
    await load(tester, {'a.png': warm});
    await tester.pumpWidget(
      host(
        MornyePlayerBackground(
          artUri: Uri.parse('file:///a.png'),
          artwork: const ColoredBox(color: Color(0xffff0000)),
          fadeStart: 0.58,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    final data = await pixels(tester);
    final above = at(data, 100, _width.toInt() - 2);
    final below = at(data, 100, _width.toInt() + 2);
    expect(distance(above, below), lessThan(12));
    expect(at(data, 100, 5), [255, 0, 0]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('lays out without overflow at small sizes', (tester) async {
    for (final size in const [Size(120, 160), Size(200, 400), Size(360, 200)]) {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: MediaQueryData(size: size),
            child: SizedBox.fromSize(
              size: size,
              child: const MornyePlayerBackground(
                artUri: null,
                artwork: ColoredBox(color: Colors.blue),
                artworkAspectRatio: 0.8,
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(tester.takeException(), isNull);
    }
  });

  group('scene', () {
    final a = mimicLookOf(
      CoverMimicZones(List.filled(5, const Color(0xffe05020))),
    );
    final b = mimicLookOf(
      CoverMimicZones(List.filled(5, const Color(0xff2040e0))),
    );

    test('interpolates colours over the adapt duration', () {
      final scene = CoverMimicScene();
      scene.apply(a, duration: const Duration(milliseconds: 600));
      scene.tick(0.3);
      expect(scene.transitioning, isTrue);
      expect(scene.colors[0], isNot(a.colors[0]));
      scene.tick(0.7);
      expect(scene.transitioning, isFalse);
      expect(scene.colors, a.colors);
      scene.dispose();
    });

    test('a live step starts a transition only for a real colour change', () {
      final scene = CoverMimicScene();
      scene.apply(a);
      scene.tick(1);
      scene.applyLive(a);
      scene.tick(1.1);
      expect(scene.transitioning, isFalse);
      scene.applyLive(b);
      scene.tick(1.2);
      expect(scene.transitioning, isTrue);
      scene.tick(1.2 + mimicLiveAdaptDuration.inMilliseconds / 1000 + 0.05);
      expect(scene.colors, b.colors);
      scene.dispose();
    });

    test('is instant when not animated', () {
      final scene = CoverMimicScene(animated: false);
      scene.apply(b);
      expect(scene.transitioning, isFalse);
      expect(scene.colors, b.colors);
      scene.dispose();
    });
  });
}
