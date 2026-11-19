import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/extensions_page.dart';
import 'package:mornye/screens/settings/metadata_settings_page.dart';
import 'package:mornye/screens/settings/sources_page.dart';

import 'support/fixed_settings.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions(this.list);
  final List<Extension> list;

  @override
  ExtensionState build() =>
      ExtensionState(isInitialized: true, extensions: list);
}

Extension _ext(String id, {bool download = false, bool metadata = false}) =>
    Extension(
      id: id,
      name: id,
      displayName: id,
      version: '1',
      description: '',
      enabled: true,
      status: 'loaded',
      hasDownloadProvider: download,
      hasMetadataProvider: metadata,
    );

List<Override> _overrides(List<Extension> list) => [
  settingsProvider.overrideWith(
    () => FixedSettingsNotifier(const AppSettings(homeFeedProvider: null)),
  ),
  extensionProvider.overrideWith(() => _Extensions(list)),
];

Widget _app(List<Extension> list, Widget home) => ProviderScope(
  overrides: _overrides(list),
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: home,
  ),
);

void main() {
  final list = [
    _ext('dl', download: true),
    _ext('both', download: true, metadata: true),
    _ext('meta', metadata: true),
  ];

  test('download list holds only download providers, info list only metadata', () {
    final container = ProviderContainer(overrides: _overrides(list));
    addTearDown(container.dispose);
    final notifier = container.read(extensionProvider.notifier);
    expect(notifier.getAllDownloadProviders().toSet(), {'dl', 'both'});
    expect(notifier.getAllMetadataProviders().toSet(), {'both', 'meta'});
  });

  testWidgets('one Sources page holds music, audio and lyrics without repeats', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(list, const SourcesPage()));
    await tester.pumpAndSettle();
    expect(find.text('Sources'), findsOneWidget);
    expect(find.text('Music'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('Lyrics'), findsOneWidget);
    expect(find.text('Search Provider'), findsNothing);
    expect(find.text('Default Search Tab'), findsNothing);
    expect(find.text('Home feed provider'), findsNothing);
    expect(find.text('Metadata Priority'), findsNothing);
    expect(find.text('Download Priority'), findsNothing);
    expect(find.text('Fallback Add-ons'), findsNothing);
  });

  testWidgets('the home and search-tab exceptions sit in a folded Advanced', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(list, const SourcesPage()));
    await tester.pumpAndSettle();
    expect(find.text('Default Search Tab'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sources_advanced_toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Default Search Tab'), findsOneWidget);
    expect(find.textContaining('overrides that list'), findsOneWidget);
  });

  testWidgets('the add-ons page only links to Sources', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(list, const ExtensionsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Sources and order'), findsOneWidget);
    expect(find.text('Download Priority'), findsNothing);
    expect(find.text('Metadata Priority'), findsNothing);
    expect(find.text('Search Provider'), findsNothing);
    expect(find.text('Provider cooldown'), findsNothing);
  });

  testWidgets('the metadata page has no provider order row', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_app(list, const MetadataSettingsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Metadata providers'), findsNothing);
  });
}
