import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/screens/settings/appearance_settings_page.dart';
import 'package:mornye/theme/dynamic_color_wrapper.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Arrastrar "Transparencia del vidrio" no debe reconstruir el tema global ni
/// la pagina entera: solo la vista previa y el deslizador. El tema global y
/// SharedPreferences se actualizan una sola vez, al soltar.
void main() {
  testWidgets('arrastrar el vidrio no reconstruye tema ni pagina por tick', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({kThemeStyleKey: 'mornye'});
    final prefs = await SharedPreferences.getInstance();
    var themeBuilds = 0;
    var homeBuilds = 0;
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(
      overrides: [
        initialThemeSettingsProvider.overrideWithValue(
          loadBootstrapThemeSettings(prefs),
        ),
      ],
    );
    addTearDown(container.dispose);
    var stateChanges = 0;
    container.listen(themeProvider, (_, _) => stateChanges++);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: DynamicColorWrapper(
          builder: (light, dark, mode) {
            themeBuilds++;
            return MaterialApp(
              theme: light,
              darkTheme: dark,
              themeMode: mode,
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Builder(
                builder: (context) {
                  homeBuilds++;
                  return const MornyeSettingsTheme(
                    child: AppearanceSettingsPage(),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    final slider = find.byKey(const ValueKey('mornye-glass-clarity'));
    await tester.ensureVisible(slider);
    await tester.pump(const Duration(seconds: 1));

    final themeBefore = themeBuilds;
    final homeBefore = homeBuilds;
    final stateBefore = stateChanges;
    final gesture = await tester.startGesture(tester.getCenter(slider));
    for (var i = 0; i < 12; i++) {
      await gesture.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 16));
    }
    final themeDuring = themeBuilds - themeBefore;
    final homeDuring = homeBuilds - homeBefore;
    final stateDuring = stateChanges - stateBefore;
    // ignore: avoid_print
    print(
      'MEDIDA arrastre: tema global=$themeDuring, home=$homeDuring, '
      'estado themeProvider=$stateDuring, '
      'prefs=${prefs.getDouble(kMornyeGlassClarityKey)}',
    );
    expect(
      themeDuring,
      0,
      reason: 'el tema global no cambia mientras arrastra',
    );
    expect(stateDuring, 0);
    expect(prefs.getDouble(kMornyeGlassClarityKey), isNull);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(
      stateChanges - stateBefore,
      1,
      reason: 'una sola escritura al soltar',
    );
    expect(prefs.getDouble(kMornyeGlassClarityKey), isNotNull);
    expect(
      MornyeTheme.glassClarityOf(tester.element(slider)),
      prefs.getDouble(kMornyeGlassClarityKey),
    );
    expect(homeDuring, 0);
  });
}
