import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/search_region_settings.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.withApple);
  final bool withApple;

  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    extensions: [
      if (withApple)
        const Extension(
          id: 'apple-music',
          name: 'apple-music',
          displayName: 'Apple Music',
          version: '1.4.19',
          description: '',
          enabled: true,
          status: 'loaded',
          searchBehavior: SearchBehavior(enabled: true),
        ),
    ],
  );
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  Widget child, {
  AppSettings settings = const AppSettings(),
  bool withApple = true,
  Locale locale = const Locale('en'),
}) async {
  final container = ProviderContainer(
    overrides: [
      settingsProvider.overrideWith(() => _Settings(settings)),
      extensionProvider.overrideWith(() => _Extensions(withApple)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('region setting defaults to automatic and picks a country', (
    tester,
  ) async {
    final container = await _pump(tester, const SearchRegionSelector());
    expect(container.read(settingsProvider).searchRegion, 'auto');
    expect(find.text('Results region'), findsOneWidget);
    expect(find.textContaining('Automatic ('), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-region-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('No region (global)'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).searchRegion, 'none');

    await tester.tap(find.byKey(const ValueKey('search-region-setting')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canada'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).searchRegion, 'ca');
  });

  testWidgets('personalization is on by default and the switch turns it off', (
    tester,
  ) async {
    final container = await _pump(tester, const PersonalizeSearchSwitch());
    expect(container.read(settingsProvider).personalizeSearchResults, isTrue);
    expect(find.textContaining('Uses only what you follow'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('personalize-search-setting')));
    await tester.pump();
    expect(container.read(settingsProvider).personalizeSearchResults, isFalse);
  });

  testWidgets('the results note names the region and its neighbors', (
    tester,
  ) async {
    await _pump(
      tester,
      const SearchRegionNote(),
      settings: const AppSettings(searchRegion: 'us'),
    );
    expect(
      find.text('Results for United States and neighbors'),
      findsOneWidget,
    );
  });

  testWidgets('the note is in Spanish and hidden without a region', (
    tester,
  ) async {
    await _pump(
      tester,
      const SearchRegionNote(),
      settings: const AppSettings(searchRegion: 'mx'),
      locale: const Locale('es'),
    );
    expect(find.text('Resultados para México y vecinos'), findsOneWidget);
    await _pump(
      tester,
      const SearchRegionNote(),
      settings: const AppSettings(searchRegion: 'none'),
    );
    expect(find.byKey(const ValueKey('search-region-note')), findsNothing);
    await _pump(
      tester,
      const SearchRegionNote(),
      settings: const AppSettings(searchRegion: 'us'),
      withApple: false,
    );
    expect(find.byKey(const ValueKey('search-region-note')), findsNothing);
  });

  test('settings read tolerantly: old data gets the defaults', () {
    final settings = AppSettings.fromJson(const <String, dynamic>{});
    expect(settings.searchRegion, 'auto');
    expect(settings.personalizeSearchResults, isTrue);
    final copy = settings.copyWith(searchRegion: 'ca');
    expect(AppSettings.fromJson(copy.toJson()).searchRegion, 'ca');
  });
}
