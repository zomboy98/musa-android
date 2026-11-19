import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/routes/now_playing_route.dart';
import 'package:mornye/theme/mornye_theme.dart';

const _sheet = Key('player-sheet');
const _height = 852.0;
const _coverRest = Rect.fromLTWH(96, 200, 200, 200);
const _miniSurface = Rect.fromLTWH(20, 760, 353, 52);
const _miniCover = Rect.fromLTWH(28, 764, 44, 44);

class _SheetRoute extends NowPlayingRoute {
  _SheetRoute()
    : super(
        child: const SizedBox(),
        miniPlayerGeometry: () => (surface: _miniSurface, artwork: _miniCover),
      ) {
    readArtwork = () => (
      bounds: _coverRest,
      child: const ColoredBox(color: Colors.red),
      fullBleed: false,
    );
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const ColoredBox(key: _sheet, color: Colors.black);
}

Future<_SheetRoute> _open(
  WidgetTester tester, {
  bool reduceMotion = false,
  bool highContrast = false,
}) async {
  tester.view.physicalSize = const Size(393, _height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: MornyeTheme.build(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(disableAnimations: reduceMotion, highContrast: highContrast),
        child: child!,
      ),
      home: const SizedBox.expand(),
    ),
  );
  final route = _SheetRoute();
  navigator.currentState!.push(route);
  await tester.pumpAndSettle();
  return route;
}

void _drag(_SheetRoute route, double fraction) => route.updateDrag(
  DragUpdateDetails(
    globalPosition: Offset(0, _height * fraction),
    delta: Offset(0, _height * fraction),
    primaryDelta: _height * fraction,
  ),
  _height,
);

double _sheetOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(
      find
          .ancestor(
            of: find.byKey(_sheet, skipOffstage: false),
            matching: find.byType(FadeTransition),
          )
          .first,
    )
    .opacity
    .value;

Rect _flyingCover(WidgetTester tester) {
  final finder = find.byKey(const ValueKey('player-minimize-artwork'));
  return Rect.fromPoints(
    tester.getTopLeft(finder),
    tester.getBottomRight(finder),
  );
}

void main() {
  setUp(() => NowPlayingRoute.miniReveal.value = 1);

  testWidgets('the sheet stays solid at first and turns transparent as it '
      'goes down', (tester) async {
    final route = await _open(tester);
    route.startDrag();
    _drag(route, 0.1);
    await tester.pump();
    expect(_sheetOpacity(tester), 1);

    _drag(route, 0.4);
    await tester.pump();
    final half = _sheetOpacity(tester);
    expect(half, closeTo(0.5 / NowPlayingRoute.sheetSolidUntil, 0.01));

    _drag(route, 0.3);
    await tester.pump();
    expect(_sheetOpacity(tester), lessThan(half));
    _drag(route, 0.2);
    await tester.pump();
    expect(_sheetOpacity(tester), closeTo(0, 0.01));
  });

  testWidgets('high contrast keeps the sheet solid', (tester) async {
    final route = await _open(tester, highContrast: true);
    route.startDrag();
    _drag(route, 0.7);
    await tester.pump();
    expect(_sheetOpacity(tester), 1);
  });

  testWidgets('the cover shrinks and moves towards the mini player thumbnail', (
    tester,
  ) async {
    final route = await _open(tester);
    route.startDrag();
    _drag(route, 0.05);
    await tester.pump();
    expect(_flyingCover(tester).size.width, closeTo(200, 1));

    _drag(route, 0.45);
    await tester.pump();
    final p = 0.5;
    final q = NowPlayingRoute.coverProgress(p, reduceMotion: false);
    final expected = Rect.lerp(_coverRest, _miniCover, q)!;
    final shown = _flyingCover(tester);
    expect(shown.left, closeTo(expected.left, 1));
    expect(shown.top, closeTo(expected.top, 1));
    expect(shown.width, closeTo(expected.width, 1));
    expect(shown.width, lessThan(200));
    expect(shown.width, greaterThan(44));

    _drag(route, 0.5);
    await tester.pump();
    final end = _flyingCover(tester);
    expect(end.width, closeTo(44, 2));
    expect(end.center.dx, closeTo(_miniCover.center.dx, 2));
    expect(end.center.dy, closeTo(_miniCover.center.dy, 2));
  });

  test('the cover trails the sheet and settles with a small overshoot', () {
    expect(NowPlayingRoute.coverProgress(0, reduceMotion: false), 0);
    expect(NowPlayingRoute.coverProgress(0.1, reduceMotion: false), 0);
    expect(NowPlayingRoute.coverProgress(1, reduceMotion: false), 1);
    var peak = 0.0;
    for (var p = 0.0; p <= 1; p += 0.01) {
      final q = NowPlayingRoute.coverProgress(p, reduceMotion: false);
      if (q > peak) peak = q;
    }
    expect(peak, greaterThan(1.04));
    expect(peak, lessThan(1.15));
  });

  test('reduced motion has no lag and no overshoot', () {
    var previous = 0.0;
    for (var p = 0.0; p <= 1; p += 0.01) {
      final q = NowPlayingRoute.coverProgress(p, reduceMotion: true);
      expect(q, closeTo(p, 1e-9));
      expect(q, lessThanOrEqualTo(1));
      expect(q, greaterThanOrEqualTo(previous));
      previous = q;
    }
  });

  testWidgets('with reduced motion the cover follows the drag linearly', (
    tester,
  ) async {
    final route = await _open(tester, reduceMotion: true);
    route.startDrag();
    _drag(route, 0.1);
    await tester.pump();
    final expected = Rect.lerp(_coverRest, _miniCover, 0.1)!;
    expect(_flyingCover(tester).width, closeTo(expected.width, 1));
  });

  testWidgets('the mini player appears as the sheet goes down', (tester) async {
    final route = await _open(tester);
    route.startDrag();
    _drag(route, 0.1);
    await tester.pump();
    expect(NowPlayingRoute.miniReveal.value, 0);
    _drag(route, 0.5);
    await tester.pump();
    final middle = NowPlayingRoute.miniReveal.value;
    expect(middle, inExclusiveRange(0, 1));
    _drag(route, 0.4);
    await tester.pump();
    expect(NowPlayingRoute.miniReveal.value, greaterThan(middle));
  });

  testWidgets('releasing past the threshold minimizes the player', (
    tester,
  ) async {
    final route = await _open(tester);
    route.startDrag();
    _drag(route, 0.5);
    await tester.pump();
    route.endDrag(DragEndDetails(primaryVelocity: 0), _height);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.byKey(const ValueKey('player-minimize-artwork')), findsOne);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsNothing);
    expect(NowPlayingRoute.miniReveal.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('releasing before the threshold expands it again', (
    tester,
  ) async {
    final route = await _open(tester);
    route.startDrag();
    _drag(route, 0.1);
    await tester.pump();
    route.endDrag(DragEndDetails(primaryVelocity: 0), _height);
    await tester.pumpAndSettle();
    expect(find.byKey(_sheet), findsOneWidget);
    expect(find.byKey(const ValueKey('player-minimize-artwork')), findsNothing);
    expect(NowPlayingRoute.miniReveal.value, 1);
    expect(_sheetOpacity(tester), 1);
  });
}
