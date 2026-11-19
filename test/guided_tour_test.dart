import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/guided_tour_provider.dart';
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_host.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_overlay.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required GuidedTourAnchors anchors,
  bool withMiniPlayer = false,
  Size size = const Size(400, 800),
  VoidCallback? onNavTap,
  bool withNav = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => GuidedTourHost(
          anchors: anchors,
          startDelay: const Duration(milliseconds: 10),
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (withMiniPlayer)
                  SizedBox(
                    key: anchors.miniPlayerKey,
                    width: double.infinity,
                    height: 64,
                  ),
                if (withNav)
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onNavTap,
                    child: SizedBox(
                      key: anchors.navKey,
                      width: double.infinity,
                      height: 64,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);
  final container = ProviderContainer(
    overrides: [extensionProvider.overrideWith(_Extensions.new)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

GuidedTourAnchors _anchors({bool store = true}) =>
    GuidedTourAnchors()..configure(
      navSlots: {
        GuidedTourTarget.home: 0,
        GuidedTourTarget.finale: 0,
        GuidedTourTarget.library: 1,
        if (store) GuidedTourTarget.store: 2,
        GuidedTourTarget.settings: store ? 3 : 2,
      },
      navSlotCount: store ? 4 : 3,
      sliceable: true,
    );

Rect? _hole(WidgetTester tester) {
  final paint = tester.widget<CustomPaint>(
    find
        .descendant(
          of: find.byType(GuidedTourOverlay),
          matching: find.byType(CustomPaint),
        )
        .first,
  );
  return (paint.painter! as GuidedTourScrimPainter).hole;
}

Future<bool?> _flag() async =>
    (await SharedPreferences.getInstance()).getBool(guidedTourCompletedKey);

Future<void> _next(WidgetTester tester) async {
  await tester.tap(find.text('Siguiente'));
  await tester.pump(const Duration(milliseconds: 150));
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('each step lights its own tab and the last one persists', (
    tester,
  ) async {
    await _pump(tester, anchors: _anchors());
    expect(find.text('Omitir'), findsOneWidget);

    final titles = [
      'Inicio',
      'Biblioteca',
      'Complementos',
      'Ajustes y Fuentes',
      'Listo para empezar',
    ];
    final left = <double>[];
    for (var step = 1; step <= 5; step++) {
      expect(find.text('$step de 5'), findsOneWidget);
      expect(find.text(titles[step - 1]), findsOneWidget);
      final hole = _hole(tester);
      expect(hole, isNotNull);
      expect(hole!.width, lessThan(150));
      left.add(hole.left);
      if (step < 5) await _next(tester);
    }
    expect(left[1], greaterThan(left[0]));
    expect(left[2], greaterThan(left[1]));
    expect(left[3], greaterThan(left[2]));
    expect(left[4], closeTo(left[0], 0.5));
    expect(find.text('Omitir'), findsNothing);

    await tester.tap(find.text('Listo'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Listo para empezar'), findsNothing);
    expect(await _flag(), isTrue);
  });

  testWidgets('skipping persists the flag', (tester) async {
    await _pump(tester, anchors: _anchors());
    await tester.tap(find.text('Omitir'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Siguiente'), findsNothing);
    expect(await _flag(), isTrue);
  });

  testWidgets('tapping the highlighted tab reaches it and advances', (
    tester,
  ) async {
    var taps = 0;
    await _pump(tester, anchors: _anchors(), onNavTap: () => taps++);
    await tester.tapAt(_hole(tester)!.center);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 1);
    expect(find.text('2 de 5'), findsOneWidget);
  });

  testWidgets('taps outside the highlight do not reach the app', (
    tester,
  ) async {
    var taps = 0;
    await _pump(tester, anchors: _anchors(), onNavTap: () => taps++);
    await tester.tapAt(const Offset(350, 745));
    await tester.pump(const Duration(milliseconds: 400));
    expect(taps, 0);
    expect(find.text('1 de 5'), findsOneWidget);
  });

  testWidgets('back gesture skips the tour', (tester) async {
    await _pump(tester, anchors: _anchors());
    expect(find.text('Siguiente'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Siguiente'), findsNothing);
    expect(await _flag(), isTrue);
  });

  testWidgets('does not show when the flag is already set', (tester) async {
    SharedPreferences.setMockInitialValues({guidedTourCompletedKey: true});
    await _pump(tester, anchors: _anchors());
    expect(find.text('Siguiente'), findsNothing);
  });

  testWidgets('steps without a target are skipped', (tester) async {
    await _pump(tester, anchors: _anchors(store: false));
    expect(find.text('1 de 4'), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      await _next(tester);
    }
    expect(find.text('Complementos'), findsNothing);
    expect(find.text('Listo para empezar'), findsOneWidget);
  });

  testWidgets('the mini player step appears only when it is on screen', (
    tester,
  ) async {
    await _pump(tester, anchors: _anchors(), withMiniPlayer: true);
    expect(find.text('1 de 6'), findsOneWidget);
    for (var i = 0; i < 2; i++) {
      await _next(tester);
    }
    expect(find.text('Mini reproductor'), findsOneWidget);
    expect(_hole(tester)!.height, greaterThan(60));
  });

  testWidgets('the card stays inside the screen and off the highlight', (
    tester,
  ) async {
    await _pump(tester, anchors: _anchors(), size: const Size(320, 480));
    final card = tester.getRect(
      find
          .descendant(
            of: find.byType(CustomSingleChildLayout),
            matching: find.byType(Material),
          )
          .first,
    );
    expect(card.left, greaterThanOrEqualTo(0));
    expect(card.right, lessThanOrEqualTo(320));
    expect(card.top, greaterThanOrEqualTo(0));
    expect(card.bottom, lessThanOrEqualTo(480));
    expect(card.overlaps(_hole(tester)!), isFalse);
  });

  testWidgets('a lost anchor ends the tour instead of showing a blind step', (
    tester,
  ) async {
    final container = await _pump(tester, anchors: _anchors(), withNav: false);
    await tester.pump(const Duration(seconds: 12));
    expect(container.read(guidedTourProvider).running, isFalse);
    expect(find.text('Siguiente'), findsNothing);
  });

  testWidgets('with no applicable step nothing is shown or persisted', (
    tester,
  ) async {
    final container = await _pump(tester, anchors: GuidedTourAnchors());
    expect(find.text('Siguiente'), findsNothing);
    expect(container.read(guidedTourProvider).running, isFalse);
    expect(await _flag(), isNull);
  });

  testWidgets('replay resets the flag and launches the tour', (tester) async {
    SharedPreferences.setMockInitialValues({guidedTourCompletedKey: true});
    final container = await _pump(tester, anchors: _anchors());
    expect(find.text('Siguiente'), findsNothing);

    await container.read(guidedTourProvider.notifier).replay();
    expect(await _flag(), isFalse);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Siguiente'), findsOneWidget);

    await tester.tap(find.text('Omitir'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(await _flag(), isTrue);
  });

  testWidgets('the About page row replays the tour', (tester) async {
    SharedPreferences.setMockInitialValues({guidedTourCompletedKey: true});
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AboutPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Ver tutorial'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(container.read(guidedTourProvider).running, isTrue);
    expect(await _flag(), isFalse);
  });
}
