import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/runtime_profile_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'support/settle.dart';

void main() {
  // El reloj decorativo a vsync nunca termina y estas pruebas esperan con
  // pumpSettled (no pumpAndSettle): se mantiene quieto durante la prueba.
  setUp(() => DecorativePhase.debugHoldClock = true);
  tearDown(() => DecorativePhase.debugHoldClock = false);

  test(
    'old themes retain outlines and new themes serialize the preference',
    () {
      expect(ThemeSettings.fromJson({}).mornyeGlassOutlines, isTrue);
      const settings = ThemeSettings(mornyeGlassOutlines: false);
      expect(ThemeSettings.fromJson(settings.toJson()), settings);
      expect(
        settings.copyWith(mornyeGlassClarity: 1).mornyeGlassOutlines,
        isFalse,
      );
      expect(settings, isNot(const ThemeSettings()));
    },
  );
  test('glass clarity restores safely from old and invalid settings', () {
    expect(
      ThemeSettings.fromJson({}).mornyeGlassClarity,
      kDefaultMornyeGlassClarity,
    );
    for (final (saved, expected) in [
      (0, 0.0),
      (1, 1.0),
      (-1, 0.0),
      (2, 1.0),
      (double.nan, kDefaultMornyeGlassClarity),
    ]) {
      final settings = ThemeSettings.fromJson({kMornyeGlassClarityKey: saved});
      expect(settings.mornyeGlassClarity, expected);
      expect(ThemeSettings.fromJson(settings.toJson()), settings);
    }
  });
  test('custom accents keep text readable in both appearances', () {
    double contrast(Color first, Color second) {
      final a = first.computeLuminance();
      final b = second.computeLuminance();
      return a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
    }

    for (final brightness in Brightness.values) {
      // Grouped settings cells, where tinted action rows sit.
      final cell = brightness == Brightness.dark
          ? const Color(0xff1c1c1e)
          : Colors.white;
      for (final accent in MornyeAccent.values) {
        final scheme = MornyeTheme.build(
          brightness,
          accent: accent,
        ).colorScheme;
        expect(
          contrast(scheme.primary, scheme.surface),
          greaterThanOrEqualTo(4.5),
          reason: '$accent on $brightness',
        );
        expect(
          contrast(scheme.primary, cell),
          greaterThanOrEqualTo(4.5),
          reason: '$accent on a $brightness grouped cell',
        );
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
          reason: 'Button text for $accent on $brightness',
        );
      }
    }
  });

  Future<void> openSettings(
    WidgetTester tester,
    SharedPreferences prefs, {
    bool lowEnd = false,
    bool settle = true,
  }) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          initialThemeSettingsProvider.overrideWithValue(
            loadBootstrapThemeSettings(prefs),
          ),
          // Low-end Android without forced blur renders flat, opaque glass.
          if (lowEnd) lowEndDeviceProvider.overrideWithValue(true),
        ],
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            theme: light,
            darkTheme: dark,
            themeMode: mode,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MornyeSettingsTheme(child: AppearanceSettingsPage()),
          ),
        ),
      ),
    );
    if (settle) {
      await pumpSettled(tester);
    } else {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('switching theme style updates the app in place', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        initialThemeSettingsProvider.overrideWithValue(
          loadBootstrapThemeSettings(prefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DynamicColorWrapper(
          builder: (light, dark, mode) => MaterialApp(
            theme: light,
            home: const Scaffold(body: TextField(key: ValueKey('app-state'))),
          ),
        ),
      ),
    );
    final before = tester.state(find.byKey(const ValueKey('app-state')));

    await container.read(themeProvider.notifier).setStyle(AppThemeStyle.mornye);
    await pumpSettled(tester);
    expect(tester.state(find.byKey(const ValueKey('app-state'))), before);

    await container
        .read(themeProvider.notifier)
        .setStyle(AppThemeStyle.material);
    await pumpSettled(tester);
    expect(tester.state(find.byKey(const ValueKey('app-state'))), before);
  });

  testWidgets('open preset preview follows system brightness', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    SharedPreferences.setMockInitialValues({
      kThemeStyleKey: 'mornye',
      kThemeModeKey: 'system',
      kMornyeAccentKey: 'blue',
      kMornyeAccentMovedToBlueKey: true,
    });
    final prefs = await SharedPreferences.getInstance();
    await openSettings(tester, prefs, settle: false);
    final picker = find.byTooltip('Custom color');
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pump(const Duration(seconds: 1));
    Color preview() =>
        (tester
                    .widget<Container>(
                      find.byKey(
                        const ValueKey('mornye-custom-accent-preview'),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color!;
    expect(
      preview(),
      MornyeTheme.accentColor(MornyeAccent.blue, Brightness.light),
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      preview(),
      MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
    );
    final sliders = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Slider),
    );
    final darkHsv = HSVColor.fromColor(
      MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
    );
    expect(
      tester.widget<Slider>(sliders.at(0)).value,
      closeTo(darkHsv.hue, 0.01),
    );
    expect(
      tester.widget<Slider>(sliders.at(1)).value,
      closeTo(darkHsv.saturation * 100, 0.01),
    );
    expect(
      tester.widget<Slider>(sliders.at(2)).value,
      closeTo(darkHsv.value * 100, 0.01),
    );
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString(kMornyeAccentKey), 'blue');
    expect(prefs.getInt(kMornyeCustomAccentKey), isNull);

    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(picker);
    await tester.pump(const Duration(seconds: 1));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    tester.widget<Slider>(sliders.at(0)).onChanged!(120);
    await tester.pump();
    final edited = darkHsv.withHue(120);
    expect(
      preview(),
      MornyeTheme.readableAccent(edited.toColor(), Brightness.dark),
    );
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(tester.widget<Slider>(sliders.at(0)).value, 120);
    expect(
      tester.widget<Slider>(sliders.at(1)).value,
      closeTo(edited.saturation * 100, 0.01),
    );
    expect(
      preview(),
      MornyeTheme.readableAccent(edited.toColor(), Brightness.light),
    );
    tester.widget<Slider>(sliders.at(0)).onChanged!(darkHsv.hue);
    await tester.pump();
    expect(
      tester.widget<Slider>(sliders.at(1)).value,
      closeTo(darkHsv.saturation * 100, 0.01),
    );
    expect(
      preview(),
      MornyeTheme.readableAccent(darkHsv.toColor(), Brightness.light),
    );
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getInt(kMornyeCustomAccentKey), darkHsv.toColor().toARGB32());
  });

  testWidgets('returning to preset before system change keeps preset', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    SharedPreferences.setMockInitialValues({
      kThemeStyleKey: 'mornye',
      kThemeModeKey: 'system',
      kMornyeAccentKey: 'blue',
      kMornyeAccentMovedToBlueKey: true,
    });
    final prefs = await SharedPreferences.getInstance();
    await openSettings(tester, prefs, settle: false);
    final picker = find.byTooltip('Custom color');
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pump(const Duration(seconds: 1));
    final sliders = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Slider),
    );
    final darkHsv = HSVColor.fromColor(
      MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
    );
    tester.widget<Slider>(sliders.at(0)).onChanged!(120);
    await tester.pump();
    tester.widget<Slider>(sliders.at(0)).onChanged!(darkHsv.hue);
    await tester.pump();
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final light = MornyeTheme.accentColor(MornyeAccent.blue, Brightness.light);
    final lightHsv = HSVColor.fromColor(light);
    expect(
      tester.widget<Slider>(sliders.at(1)).value,
      closeTo(lightHsv.saturation * 100, 0.01),
    );
    final preview = tester.widget<Container>(
      find.byKey(const ValueKey('mornye-custom-accent-preview')),
    );
    expect((preview.decoration! as BoxDecoration).color, light);
    await tester.tap(find.text('OK'));
    await tester.pump(const Duration(seconds: 1));
    expect(prefs.getString(kMornyeAccentKey), 'blue');
    expect(prefs.getInt(kMornyeCustomAccentKey), isNull);
  });

  testWidgets('opening during system theme transition uses target HSV', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    SharedPreferences.setMockInitialValues({
      kThemeStyleKey: 'mornye',
      kThemeModeKey: 'system',
      kMornyeAccentKey: 'blue',
      kMornyeAccentMovedToBlueKey: true,
    });
    final prefs = await SharedPreferences.getInstance();
    await openSettings(tester, prefs, settle: false);
    final picker = find.byTooltip('Custom color');
    await tester.ensureVisible(picker);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    await tester.tap(picker);
    await tester.pump(const Duration(seconds: 1));
    final sliders = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(Slider),
    );
    final hsv = HSVColor.fromColor(
      MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
    );
    expect(
      tester.widget<Slider>(sliders.at(1)).value,
      closeTo(hsv.saturation * 100, 0.01),
    );
  });

  for (final brightness in Brightness.values) {
    testWidgets('preset preview keeps the applied blue ($brightness)', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: 'system',
        kMornyeAccentKey: 'blue',
        kMornyeAccentMovedToBlueKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs, settle: false);
      final page = find.byType(AppearanceSettingsPage);
      final current = Theme.of(tester.element(page)).colorScheme.primary;
      final picker = find.byTooltip('Custom color');
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pump(const Duration(seconds: 1));
      Color preview() =>
          (tester
                      .widget<Container>(
                        find.byKey(
                          const ValueKey('mornye-custom-accent-preview'),
                        ),
                      )
                      .decoration!
                  as BoxDecoration)
              .color!;
      expect(preview(), current);
      final sliders = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(Slider),
      );
      tester.widget<Slider>(sliders.at(2)).onChanged!(0);
      await tester.pump();
      expect(
        preview(),
        MornyeTheme.build(
          brightness,
          customAccent: Colors.black,
        ).colorScheme.primary,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(seconds: 1));
      expect(prefs.getInt(kMornyeCustomAccentKey), isNull);
    });

    testWidgets('custom accent preview and persistence ($brightness)', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: 'system',
        kMornyeAccentKey: 'orange',
        kMornyeAccentMovedToBlueKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs, settle: false);
      final picker = find.byTooltip('Custom color');
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pump(const Duration(seconds: 1));
      final dialog = find.byType(AlertDialog);
      final sliders = find.descendant(
        of: dialog,
        matching: find.byType(Slider),
      );
      final orange = MornyeTheme.accentColor(MornyeAccent.orange, brightness);
      expect(
        tester.widget<Slider>(sliders.at(0)).value,
        closeTo(HSVColor.fromColor(orange).hue, 0.01),
      );
      await tester.tap(find.text('OK'));
      await tester.pump(const Duration(seconds: 1));
      expect(prefs.getString(kMornyeAccentKey), 'orange');
      expect(prefs.getInt(kMornyeCustomAccentKey), isNull);

      await tester.tap(picker);
      await tester.pump(const Duration(seconds: 1));
      tester.widget<Slider>(sliders.at(2)).onChanged!(0);
      await tester.pump();
      final preview = tester.widget<Container>(
        find.byKey(const ValueKey('mornye-custom-accent-preview')),
      );
      final expected = MornyeTheme.build(
        brightness,
        customAccent: Colors.black,
      ).colorScheme.primary;
      expect((preview.decoration! as BoxDecoration).color, expected);
      await tester.tap(find.text('OK'));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(prefs.getInt(kMornyeCustomAccentKey), Colors.black.toARGB32());
      expect(
        Theme.of(
          tester.element(find.byType(AppearanceSettingsPage)),
        ).colorScheme.primary,
        expected,
      );
      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs, settle: false);
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widget<Slider>(sliders.at(2)).value, 0);
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(
                        const ValueKey('mornye-custom-accent-preview'),
                      ),
                    )
                    .decoration!
                as BoxDecoration)
            .color,
        expected,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pump(const Duration(seconds: 1));
      expect(prefs.getInt(kMornyeCustomAccentKey), Colors.black.toARGB32());
    });
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets(
      'glass outlines toggle survives restart and local themes ($mode)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kThemeStyleKey: 'mornye',
          kThemeModeKey: mode.name,
        });
        final prefs = await SharedPreferences.getInstance();
        await openSettings(tester, prefs);
        final toggle = find.byKey(const ValueKey('mornye-glass-outlines'));
        await tester.ensureVisible(toggle);
        await pumpSettled(tester);
        await tester.tap(find.text('Glass outlines'));
        await pumpSettled(tester);
        expect(prefs.getBool(kMornyeGlassOutlinesKey), isFalse);
        final context = tester.element(toggle);
        expect(MornyeTheme.glassOutlinesOf(context), isFalse);
        final local = MornyeTheme.fromContext(
          context,
          brightness: Brightness.dark,
        );
        expect(local.extension<MornyeTheme>()!.glassOutlines, isFalse);
        expect(
          local.extension<MornyeTheme>()!.glassClarity,
          kDefaultMornyeGlassClarity,
        );
        await tester.pumpWidget(const SizedBox());
        await openSettings(tester, prefs);
        expect(MornyeTheme.glassOutlinesOf(tester.element(toggle)), isFalse);
        await tester.ensureVisible(toggle);
        await pumpSettled(tester);
        await tester.tap(find.text('Glass outlines'));
        await pumpSettled(tester);
        expect(prefs.getBool(kMornyeGlassOutlinesKey), isTrue);
        final picker = find.byType(MornyeSegmentedControl);
        await tester.scrollUntilVisible(
          picker,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        // The theme picker sits on an opaque group card.
        expect(
          find.descendant(of: picker, matching: find.byType(BackdropFilter)),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('glass clarity previews live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      await tester.ensureVisible(slider);
      await pumpSettled(tester);
      await tester.drag(slider, const Offset(160, 0));
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).value, 1);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 1);
      final context = tester.element(slider);
      expect(MornyeTheme.glassClarityOf(context), 1);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsOneWidget,
      );
      expect(
        MornyeTheme.fromContext(
          context,
          brightness: Brightness.dark,
        ).extension<MornyeTheme>()!.glassClarity,
        1,
      );
      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(tester.widget<Slider>(slider).value, 1);
      await tester.ensureVisible(slider);
      await pumpSettled(tester);
      await tester.drag(slider, const Offset(-320, 0));
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).value, 0);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 0);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('glass clarity waits for blur on flat devices ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs, lowEnd: true);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      final hint = find.byKey(
        const ValueKey('mornye-glass-clarity-unavailable'),
      );
      await tester.ensureVisible(slider);
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      expect(
        find.byKey(const ValueKey('mornye-glass-clear-performance')),
        findsNothing,
      );
      expect(
        tester.widget<Text>(hint).data,
        'Glass is opaque on this device. Turn on '
        '“Always use blur effects” to adjust clarity.',
      );
      await tester.drag(slider, const Offset(160, 0));
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).value, kDefaultMornyeGlassClarity);
      expect(prefs.getDouble(kMornyeGlassClarityKey), isNull);

      final forceBlur = find.text('Always use blur effects');
      await tester.scrollUntilVisible(
        forceBlur,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await pumpSettled(tester);
      await tester.tap(forceBlur);
      await pumpSettled(tester);
      // The lazily built slider scrolled away; bring it back.
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await pumpSettled(tester);
      expect(hint, findsNothing);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      await tester.drag(slider, const Offset(160, 0));
      await pumpSettled(tester);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('glass clarity can override system contrast ($mode)', (
      tester,
    ) async {
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(highContrast: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
      await tester.ensureVisible(slider);
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).onChanged, isNull);
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('mornye-glass-clarity-unavailable')),
            )
            .data,
        'Your system requests increased contrast, so glass stays opaque. '
        'Turn on “Always use blur effects” to use glass anyway; '
        'text contrast is preserved.',
      );
      final forceBlur = find.text('Always use blur effects');
      await tester.scrollUntilVisible(
        forceBlur,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await pumpSettled(tester);
      await tester.tap(forceBlur);
      await pumpSettled(tester);
      await tester.scrollUntilVisible(
        slider,
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      expect(
        find.byKey(const ValueKey('mornye-glass-clarity-unavailable')),
        findsNothing,
      );
      expect(MediaQuery.highContrastOf(tester.element(slider)), isTrue);
      expect(find.byType(BackdropFilter), findsWidgets);
      await tester.drag(slider, const Offset(160, 0));
      await pumpSettled(tester);
      expect(prefs.getDouble(kMornyeGlassClarityKey), 1);

      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      await tester.ensureVisible(slider);
      await pumpSettled(tester);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);
      expect(tester.widget<Slider>(slider).value, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Mornye accent updates live and survives restart ($mode)', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        kThemeStyleKey: 'mornye',
        kThemeModeKey: mode.name,
        kSeedColorKey: 0xff123456,
        kMornyeAccentKey: 'red',
        kMornyeAccentMovedToBlueKey: true,
      });
      final prefs = await SharedPreferences.getInstance();
      await openSettings(tester, prefs);
      final page = find.byType(AppearanceSettingsPage);
      final initial = Theme.of(tester.element(page));
      expect(
        initial.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.red, initial.brightness),
      );

      final blue = find.byTooltip('Blue');
      await tester.ensureVisible(blue);
      await tester.tap(blue);
      await pumpSettled(tester);
      final theme = Theme.of(tester.element(page));
      expect(
        theme.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.blue, theme.brightness),
      );
      expect(prefs.getString(kMornyeAccentKey), 'blue');
      expect(prefs.getInt(kSeedColorKey), 0xff123456);
      final overlay = MornyeTheme.fromContext(
        tester.element(page),
        brightness: Brightness.dark,
      );
      expect(overlay.extension<MornyeTheme>()!.accent, MornyeAccent.blue);
      expect(
        overlay.colorScheme.primary,
        MornyeTheme.accentColor(MornyeAccent.blue, Brightness.dark),
      );

      await tester.pumpWidget(const SizedBox());
      await openSettings(tester, prefs);
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        theme.colorScheme.primary,
      );
      await tester.ensureVisible(find.byTooltip('Red (default)'));
      await tester.tap(find.byTooltip('Red (default)'));
      await pumpSettled(tester);
      expect(
        Theme.of(tester.element(page)).colorScheme.primary,
        initial.colorScheme.primary,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final style in AppThemeStyle.values) {
    testWidgets(
      'system font persists and restores the default ($style)',
      (tester) async {
        SharedPreferences.setMockInitialValues({
          kThemeStyleKey: style.name,
          kMornyeAccentKey: 'blue',
          kUseDynamicColorKey: false,
        });
        final prefs = await SharedPreferences.getInstance();
        await openSettings(tester, prefs);
        final page = find.byType(AppearanceSettingsPage);
        final original = Theme.of(
          tester.element(page),
        ).textTheme.bodyLarge!.fontFamily;
        final setting = find.text('Use system font');
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpSettled(tester);
        await tester.tap(setting);
        await pumpSettled(tester);
        final theme = Theme.of(tester.element(page));
        final systemFamily = theme.textTheme.bodyLarge!.fontFamily;
        expect(systemFamily, isNot('Inter'));
        expect(systemFamily, isNot('Google Sans Flex'));
        expect(prefs.getBool(kUseSystemFontKey), isTrue);
        if (style == AppThemeStyle.mornye) {
          final overlay = MornyeTheme.fromContext(
            tester.element(page),
            brightness: Brightness.dark,
          );
          expect(overlay.extension<MornyeTheme>()!.useSystemFont, isTrue);
          expect(overlay.extension<MornyeTheme>()!.accent, MornyeAccent.blue);
          expect(overlay.textTheme.bodyLarge!.fontFamily, systemFamily);
        }
        await tester.pumpWidget(const SizedBox());
        await openSettings(tester, prefs);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          systemFamily,
        );
        await tester.scrollUntilVisible(
          setting,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await pumpSettled(tester);
        await tester.tap(setting);
        await pumpSettled(tester);
        expect(prefs.getBool(kUseSystemFontKey), isFalse);
        expect(
          Theme.of(tester.element(page)).textTheme.bodyLarge!.fontFamily,
          original,
        );
        expect(tester.takeException(), isNull);
      },
      variant: const TargetPlatformVariant({
        TargetPlatform.android,
        TargetPlatform.iOS,
      }),
    );
  }
}
