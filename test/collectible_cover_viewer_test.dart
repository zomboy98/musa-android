import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/collectible_cover_viewer.dart';
import 'package:mornye/widgets/settled_blur.dart';

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

class _PopCounter extends NavigatorObserver {
  int pops = 0;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => pops++;
}

const _origin = Rect.fromLTWH(30, 120, 140, 140);

class _Host extends StatelessWidget {
  const _Host({
    this.source,
    this.reduce = false,
    this.contrast = false,
    this.origin = _origin,
    this.observer,
  });

  final TiltSource? source;
  final bool reduce;
  final bool contrast;
  final Rect? origin;
  final NavigatorObserver? observer;

  @override
  Widget build(BuildContext context) {
    return MediaQuery(
      data: MediaQueryData(
        size: const Size(400, 800),
        disableAnimations: reduce,
        highContrast: contrast,
      ),
      child: MaterialApp(
        navigatorObservers: [?observer],
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                key: const ValueKey('open'),
                onPressed: () => showCollectibleCover(
                  context,
                  imageProvider: MemoryImage(_png),
                  heroTag: 'cover-test',
                  title: 'Album',
                  tiltSource: source,
                  originRect: origin == null ? null : () => origin,
                  originRadius: 20,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

double _sinY(WidgetTester tester) {
  final transform = tester.widget<Transform>(
    find.byKey(const ValueKey('collectible-tilt')),
  );
  return transform.transform.entry(0, 2).abs();
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('open')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() {
    defaultTiltSourceFactory = () => null;
    collectibleHintShown = true;
  });

  testWidgets('opens the viewer and the close button dismisses it', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    expect(find.byKey(const ValueKey('collectible-viewer')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('collectible-viewer')), findsNothing);
  });

  testWidgets('swipe up past 110 dp pops and the card lands on the origin', (
    tester,
  ) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(0, -40));
    await gesture.moveBy(const Offset(0, -80));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 16));
    final dragged = tester.getCenter(card).dy;
    await gesture.up();
    await tester.pump();
    expect(observer.pops, 0);
    await tester.pump(const Duration(milliseconds: 380));
    expect(observer.pops, 0);
    final rect = tester.getRect(card);
    expect(rect.left, closeTo(_origin.left, 3));
    expect(rect.top, closeTo(_origin.top, 3));
    expect(rect.width, closeTo(_origin.width, 3));
    expect(dragged, lessThan(400));
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
    expect(find.byKey(const ValueKey('collectible-viewer')), findsNothing);
  });

  testWidgets('a fast upward fling closes it', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    await tester.fling(
      find.byKey(const ValueKey('collectible-tilt')),
      const Offset(0, -90),
      1500,
    );
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
  });

  testWidgets('a horizontal drag only tilts and never closes', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final gesture = await tester.startGesture(tester.getCenter(card));
    await gesture.moveBy(const Offset(120, -20));
    await gesture.moveBy(const Offset(120, -40));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(observer.pops, 0);
    expect(find.byKey(const ValueKey('collectible-viewer')), findsOneWidget);
  });

  testWidgets('a mostly diagonal upward drag does not close', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(100, -60));
    await gesture.moveBy(const Offset(100, -80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(observer.pops, 0);
  });

  testWidgets('releasing before the threshold springs back to rest', (
    tester,
  ) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final rest = tester.getCenter(card);
    final gesture = await tester.startGesture(rest);
    await gesture.moveBy(const Offset(0, -30));
    await gesture.moveBy(const Offset(0, -50));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.getCenter(card).dy, lessThan(rest.dy - 40));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(observer.pops, 0);
    expect(tester.getCenter(card).dy, closeTo(rest.dy, 0.5));
    final rect = tester.getRect(card);
    expect(rect.width, closeTo(rect.height, 0.1));
  });

  testWidgets('back closes with the same flight to the origin', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final restWidth = tester.getRect(card).width;
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(observer.pops, 0);
    final mid = tester.getRect(card).width;
    expect(mid, lessThan(restWidth));
    expect(mid, greaterThan(_origin.width));
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
  });

  testWidgets('the close button flies to the origin too', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 380));
    final rect = tester.getRect(card);
    expect(rect.center.dx, closeTo(_origin.center.dx, 3));
    expect(rect.center.dy, closeTo(_origin.center.dy, 3));
    expect(rect.width, closeTo(_origin.width, 3));
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
  });

  testWidgets('the card tilt returns flat during the flight', (tester) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(100, 0));
    await gesture.moveBy(const Offset(100, 0));
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), greaterThan(0.1));
    await gesture.up();
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pump();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), lessThan(0.05));
    await tester.pumpAndSettle();
  });

  testWidgets('without an origin it fades and scales out', (tester) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(origin: null, observer: observer));
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final restRect = tester.getRect(card);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    final rect = tester.getRect(card);
    expect(rect.center.dx, closeTo(restRect.center.dx, 0.5));
    expect(rect.center.dy, closeTo(restRect.center.dy, 0.5));
    expect(rect.width, lessThan(restRect.width));
    expect(rect.width, greaterThan(restRect.width * 0.8));
    expect(observer.pops, 0);
    await tester.pumpAndSettle();
    expect(observer.pops, 1);
  });

  testWidgets('reduced animations fade out in 120 ms with no flight', (
    tester,
  ) async {
    final observer = _PopCounter();
    await tester.pumpWidget(_Host(reduce: true, observer: observer));
    await _open(tester);
    final restRect = tester.getRect(find.byType(Image).last);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.getRect(find.byType(Image).last), restRect);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.pump();
    await tester.pump();
    expect(observer.pops, 1);
  });

  testWidgets('the swipe hint shows once per session and fades out', (
    tester,
  ) async {
    collectibleHintShown = false;
    await tester.pumpWidget(const _Host());
    await _open(tester);
    double hint() => tester
        .widget<AnimatedOpacity>(find.byKey(const ValueKey('collectible-hint')))
        .opacity;
    expect(find.text('Swipe up to exit'), findsOneWidget);
    expect(hint(), 1);
    await tester.pump(const Duration(milliseconds: 2600));
    expect(hint(), 0);
    expect(collectibleHintShown, isTrue);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(hint(), 0);
  });

  testWidgets('the close button keeps its tooltip and button semantics', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    expect(find.byTooltip('Close'), findsOneWidget);
    expect(find.byType(IconButton), findsOneWidget);
  });

  testWidgets('tilt from the source is capped at 12 degrees', (tester) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(_Host(source: source));
    await _open(tester);
    expect(source.hasListener, isTrue);
    source.push(const Offset(9, -9));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    final limit = 0.2079 + 0.002;
    expect(_sinY(tester), lessThanOrEqualTo(limit));
    expect(_sinY(tester), greaterThan(0.15));
  });

  testWidgets('drag tilt without a source is also capped', (tester) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(300, 0));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), lessThanOrEqualTo(0.2079 + 0.002));
    expect(_sinY(tester), greaterThan(0.15));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('sensors are released on close', (tester) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(_Host(source: source));
    await _open(tester);
    expect(source.hasListener, isTrue);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pump();
    expect(source.hasListener, isFalse);
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('sensors are paused while the app is in background', (
    tester,
  ) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(_Host(source: source));
    await _open(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(source.hasListener, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(source.hasListener, isTrue);
  });

  testWidgets('reduced animations: plain image, no sensors, no tilt', (
    tester,
  ) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(_Host(source: source, reduce: true));
    await _open(tester);
    expect(find.byKey(const ValueKey('collectible-viewer')), findsOneWidget);
    expect(source.hasListener, isFalse);
    expect(find.byKey(const ValueKey('collectible-tilt')), findsNothing);
    expect(find.byType(Image), findsNWidgets(2));
  });

  testWidgets('uses the default source when none is passed', (tester) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    defaultTiltSourceFactory = () => source;
    await tester.pumpWidget(const _Host());
    await _open(tester);
    expect(source.hasListener, isTrue);
    source.push(const Offset(1, 0));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), greaterThan(0.15));
  });

  testWidgets('finger drag still works while a source is active', (
    tester,
  ) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(_Host(source: source));
    await _open(tester);
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(300, 0));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), greaterThan(0.15));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a source that ends leaves drag working', (tester) async {
    final source = ManualTiltSource();
    await tester.pumpWidget(_Host(source: source));
    await _open(tester);
    await source.close();
    final gesture = await tester.startGesture(const Offset(200, 400));
    await gesture.moveBy(const Offset(300, 0));
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(_sinY(tester), greaterThan(0.15));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the card follows the finger upward at 0.9 without feedback', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    final card = find.byKey(const ValueKey('collectible-tilt'));
    final start = tester.getCenter(card).dy;
    final gesture = await tester.startGesture(const Offset(200, 300));
    for (var i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(0, -10));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final moved = tester.getCenter(card).dy - start;
    expect(moved, closeTo(-90, 1.5));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('the cover is decoded at a bounded size', (tester) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    final image = tester.widget<Image>(find.byType(Image).last);
    expect(image.image, isA<ResizeImage>());
  });

  testWidgets('a vetoed close leaves the viewer and sensors alive', (
    tester,
  ) async {
    final source = ManualTiltSource();
    addTearDown(source.close);
    await tester.pumpWidget(
      MaterialApp(
        home: PopScope(
          canPop: false,
          child: CollectibleCoverViewer(
            imageProvider: MemoryImage(_png),
            tiltSource: source,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(source.hasListener, isTrue);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pumpAndSettle();
    expect(source.hasListener, isTrue);
    await tester.tap(find.byKey(const ValueKey('collectible-close')));
    await tester.pumpAndSettle();
    expect(source.hasListener, isTrue);
  });

  test('the glare is pure white with alpha, no hue', () {
    for (final peak in [
      collectibleCorePeakAlpha,
      collectibleHaloPeakAlpha,
      collectibleRimPeakAlpha,
    ]) {
      final colors = collectibleGlareColors(peak: peak);
      for (final c in colors) {
        expect(c.r, 1.0);
        expect(c.g, 1.0);
        expect(c.b, 1.0);
      }
      expect(colors.first.a, closeTo(0, 1e-6));
      expect(colors[colors.length ~/ 2].a, closeTo(peak, 0.001));
      expect(colors.last.a, closeTo(0, 1e-6));
    }
    expect(collectibleGlareStops().first, 0);
    expect(collectibleGlareStops().last, 1);
  });

  test('the glare bands are 40 percent wider than the flat sheen', () {
    expect(collectibleCoreWidth, closeTo(0.07 * 1.4, 1e-9));
    expect(collectibleRimWidth, closeTo(0.4 * 1.4, 1e-9));
  });

  test('the peak alphas stay in range', () {
    expect(collectibleCorePeakAlpha, inInclusiveRange(0.16, 0.20));
    expect(collectibleHaloPeakAlpha, inInclusiveRange(0.04, 0.08));
    expect(collectibleRimPeakAlpha, closeTo(0.35, 0.001));
  });

  testWidgets('the backdrop is the blurred cover with a fine grain', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host());
    await _open(tester);
    final blur = tester.widget<SettledBlur>(find.byType(SettledBlur));
    expect(blur.sigma, inInclusiveRange(40, 50));
    expect(find.byKey(const ValueKey('collectible-grain')), findsOneWidget);
    expect(collectibleGrainAlpha, lessThanOrEqualTo(0.03));
    expect(collectibleBackdropDarkness, inInclusiveRange(0.75, 0.85));
  });

  testWidgets('high contrast uses a solid dark backdrop without blur', (
    tester,
  ) async {
    await tester.pumpWidget(const _Host(contrast: true));
    await _open(tester);
    expect(find.byKey(const ValueKey('collectible-viewer')), findsOneWidget);
    expect(find.byType(SettledBlur), findsNothing);
    expect(find.byKey(const ValueKey('collectible-grain')), findsNothing);
  });
}
