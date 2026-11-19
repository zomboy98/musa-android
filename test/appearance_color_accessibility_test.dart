import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'support/settle.dart';

void main() {
  // El reloj decorativo a vsync nunca termina y estas pruebas esperan con
  // pumpAndSettle: se mantiene quieto durante la prueba.
  setUp(() => DecorativePhase.debugHoldClock = true);
  tearDown(() => DecorativePhase.debugHoldClock = false);

  Future<SharedPreferences> open(WidgetTester tester, String style) async {
    SharedPreferences.setMockInitialValues({
      kThemeStyleKey: style,
      kUseDynamicColorKey: false,
    });
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialThemeSettingsProvider.overrideWithValue(
            loadBootstrapThemeSettings(prefs),
          ),
        ],
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            locale: const Locale('en'),
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const AppearanceSettingsPage(),
          ),
        ),
      ),
    );
    await pumpSettled(tester);
    return prefs;
  }

  testWidgets('Material palette accepts Tab and Enter', (tester) async {
    final prefs = await open(tester, 'material');
    final semantics = tester.ensureSemantics();
    final first = find.bySemanticsLabel('Select accent color FF1DB954');
    await tester.scrollUntilVisible(
      first,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(first), alignment: .5);
    await pumpSettled(tester);
    final firstButton = find.descendant(
      of: first,
      matching: find.byType(InkWell),
    );
    final button = tester.widget<InkWell>(firstButton);
    for (var i = 0; i < 40; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      if (FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<InkWell>() ==
          button)
        break;
    }
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<InkWell>(),
      same(button),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await pumpSettled(tester);
    expect(prefs.getInt(kSeedColorKey), 0xff6750a4);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  test('actual custom accents keep readable foregrounds', () {
    double contrast(Color a, Color b) {
      final x = a.computeLuminance();
      final y = b.computeLuminance();
      return x > y ? (x + .05) / (y + .05) : (y + .05) / (x + .05);
    }

    for (final brightness in Brightness.values) {
      for (final color in [
        Colors.black,
        Colors.white,
        Colors.yellow,
        const Color(0xff123456),
        const Color(0xff777777),
      ]) {
        final scheme = MornyeTheme.build(
          brightness,
          customAccent: color,
        ).colorScheme;
        expect(
          contrast(scheme.primary, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.primary, scheme.surfaceContainerHigh),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
        );
      }
    }
  });

  testWidgets('custom color dialog fits short viewport with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(700, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, 'mornye');
    final custom = find.byTooltip('Custom color');
    await tester.scrollUntilVisible(
      custom,
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(tester.element(custom), alignment: .5);
    await pumpSettled(tester);
    await tester.tap(custom);
    await pumpSettled(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
