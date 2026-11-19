import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(FixedSettingsNotifier.new),
          extensionProvider.overrideWith(_Extensions.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Settings no longer lists the add-ons section or the store', (
    tester,
  ) async {
    await pump(
      tester,
      Scaffold(
        body: SettingsTab(
          remoteConfigService: AppRemoteConfigService(
            client: MockClient((_) async => http.Response('{}', 200)),
          ),
        ),
      ),
    );
    final l10n = AppLocalizations.of(tester.element(find.byType(SettingsTab)));
    expect(find.text(l10n.settingsExtensions), findsNothing);
    expect(find.text(l10n.sourcesAndOrderTitle), findsNothing);
    expect(find.text(l10n.navStore), findsNothing);
    expect(find.text(l10n.settingsGroupProviders), findsNothing);
  });

  testWidgets('the add-ons page holds the code card, search and store', (
    tester,
  ) async {
    await pump(tester, const ExtensionsPage());
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ExtensionsPage)),
    );
    expect(find.text(l10n.addonsCodeTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('plugin-code-field')), findsOneWidget);
    expect(find.text(l10n.addonsCodeAdd), findsOneWidget);
    expect(find.text(l10n.addonsCodeHelp), findsOneWidget);
    expect(find.text(l10n.sourcesAndOrderTitle), findsOneWidget);
    expect(find.text(l10n.storeTitle), findsOneWidget);
  });

  testWidgets('an invalid code shows the invalid code message', (tester) async {
    await pump(tester, const ExtensionsPage());
    final l10n = AppLocalizations.of(
      tester.element(find.byType(ExtensionsPage)),
    );
    await tester.enterText(
      find.byKey(const ValueKey('plugin-code-field')),
      'ab',
    );
    await tester.tap(find.byKey(const ValueKey('plugin-code-add')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.addonsCodeInvalid), findsOneWidget);
  });

  testWidgets('no visible Spanish or English string says extension', (
    tester,
  ) async {
    await pump(tester, const ExtensionsPage());
    final es = AppLocalizations.of(tester.element(find.byType(ExtensionsPage)));
    final en = lookupAppLocalizations(const Locale('en'));
    for (final text in [
      es.settingsExtensions,
      es.extensionsTitle,
      es.storeTitle,
      en.settingsExtensions,
      en.extensionsTitle,
      en.storeTitle,
    ]) {
      expect(text.toLowerCase(), isNot(contains('extensi')));
    }
  });
}
