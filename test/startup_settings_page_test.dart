import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/app_localizations_en.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/startup_settings_page.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'support/settle.dart';

void main() {
  Future<void> openPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const StartupSettingsPage(),
        ),
      ),
    );
    await pumpSettled(tester);
  }

  testWidgets('startup animation and sound switches persist and are read', (
    tester,
  ) async {
    final l10n = AppLocalizationsEn();
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await openPage(tester);

    Finder row(String title) => find.ancestor(
      of: find.text(title),
      matching: find.byType(SettingsSwitchItem),
    );
    bool shown(String title) =>
        tester.widget<SettingsSwitchItem>(row(title)).value;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(StartupSettingsPage)),
    );

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text(l10n.startupSound),
      200,
      scrollable: scrollable,
    );
    expect(find.text(l10n.startupAnimation), findsOneWidget);
    expect(find.text(l10n.startupSound), findsOneWidget);
    // Defaults: the intro video plays, without sound.
    expect(shown(l10n.startupAnimation), isTrue);
    expect(shown(l10n.startupSound), isFalse);

    // Centrada, para que la cabecera fija no tape la fila.
    Future<void> toggle(String title) async {
      await Scrollable.ensureVisible(
        tester.element(find.text(title)),
        alignment: 0.5,
      );
      await tester.pump();
      await tester.tap(find.text(title));
      await tester.pump();
    }

    await toggle(l10n.startupAnimation);
    await toggle(l10n.startupSound);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(shown(l10n.startupAnimation), isFalse);
    expect(shown(l10n.startupSound), isTrue);
    final live = container.read(settingsProvider);
    expect(live.startupAnimation, isFalse);
    expect(live.startupSound, isTrue);

    // Saved with the rest of the app settings, and read back on restart.
    final saved =
        jsonDecode(prefs.getString('app_settings')!) as Map<String, dynamic>;
    expect(saved['startupAnimation'], isFalse);
    expect(saved['startupSound'], isTrue);
    final reloaded = ProviderContainer();
    addTearDown(reloaded.dispose);
    await tester.runAsync(
      () => reloaded.read(settingsProvider.notifier).ensureLoaded(),
    );
    expect(reloaded.read(settingsProvider).startupAnimation, isFalse);
    expect(reloaded.read(settingsProvider).startupSound, isTrue);
    // The bootstrap read the app uses before the first frame agrees.
    final boot = loadBootstrapSettings(prefs);
    expect(boot.startupAnimation, isFalse);
    expect(boot.startupSound, isTrue);

    // Turning them back restores the defaults.
    await toggle(l10n.startupAnimation);
    await toggle(l10n.startupSound);
    await tester.pump(const Duration(seconds: 1));
    expect(shown(l10n.startupAnimation), isTrue);
    expect(shown(l10n.startupSound), isFalse);
  });
}
