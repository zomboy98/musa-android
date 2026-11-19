import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('empty preferences and JSON agree with the launch defaults', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final bootstrap = loadBootstrapThemeSettings(prefs);
    expect(bootstrap.style, AppThemeStyle.mornye);
    expect(bootstrap.themeMode, ThemeMode.dark);
    expect(ThemeSettings.fromJson({}), bootstrap);
    expect(const ThemeSettings(), bootstrap);
    expect(prefs.containsKey(kThemeStyleKey), isFalse);
    expect(prefs.containsKey(kThemeModeKey), isFalse);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    expect(container.read(initialThemeSettingsProvider), bootstrap);
    container.read(themeProvider);
    await Future<void>.delayed(Duration.zero);
    expect(container.read(themeProvider), bootstrap);
  });

  for (final mode in ThemeMode.values) {
    test('stored Material/${mode.name} remains an explicit choice', () async {
      final saved = <String, Object>{
        kThemeStyleKey: 'material',
        kThemeModeKey: mode.name,
        kUseAmoledKey: false,
      };
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      final bootstrap = loadBootstrapThemeSettings(prefs);
      expect(bootstrap.style, AppThemeStyle.material);
      expect(bootstrap.themeMode, mode);
      expect(bootstrap.useAmoled, isFalse);
      expect(ThemeSettings.fromJson(saved), bootstrap);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(themeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(themeProvider), bootstrap);
      expect(prefs.getString(kThemeStyleKey), 'material');
      expect(prefs.getString(kThemeModeKey), mode.name);
      expect(prefs.getBool(kUseAmoledKey), isFalse);
    });
  }

  for (final savedMaterial in [false, true]) {
    testWidgets(
      savedMaterial
          ? 'wrapper honors saved Material light on a light system'
          : 'wrapper starts MUSA OLED dark even on a light system',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue =
            Brightness.light;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        SharedPreferences.setMockInitialValues({
          if (savedMaterial) kThemeStyleKey: 'material',
          if (savedMaterial) kThemeModeKey: 'light',
        });
        final prefs = await SharedPreferences.getInstance();
        late ThemeData actual;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              initialThemeSettingsProvider.overrideWithValue(
                loadBootstrapThemeSettings(prefs),
              ),
            ],
            child: DynamicColorWrapper(
              builder: (light, dark, mode) => MaterialApp(
                theme: light,
                darkTheme: dark,
                themeMode: mode,
                home: Builder(
                  builder: (context) {
                    actual = Theme.of(context);
                    return const SizedBox();
                  },
                ),
              ),
            ),
          ),
        );
        void verify() {
          expect(
            actual.brightness,
            savedMaterial ? Brightness.light : Brightness.dark,
          );
          if (savedMaterial) {
            expect(actual.extension<MornyeTheme>(), isNull);
          } else {
            expect(actual.extension<MornyeTheme>(), isNotNull);
            expect(actual.colorScheme.surface, Colors.black);
            expect(actual.scaffoldBackgroundColor, Colors.black);
          }
        }

        verify();
        await tester.pumpAndSettle();
        verify();
      },
    );
  }
}
