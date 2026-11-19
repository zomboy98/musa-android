import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _providerName = 'Zeta Provider';
const _providerId = 'zeta-provider';
const _notice =
    'The higher the quality, the longer you may wait until you can listen to your whole song and have it ready.';

AppSettings _fixture = const AppSettings(defaultService: _providerId);
ExtensionState _extensions = const ExtensionState();

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => _fixture;

  @override
  Future<void> ensureLoaded() async {}
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => _extensions;

  @override
  Future<void> ensureInitialized() async {}

  void publish(ExtensionState next) => state = next;
}

ExtensionState _loaded() => ExtensionState(
  isInitialized: true,
  providerPriority: const [_providerId],
  extensions: [
    Extension.fromJson({
      'id': _providerId,
      'name': _providerId,
      'display_name': _providerName,
      'enabled': true,
      'has_download_provider': true,
      'quality_options': [
        {'id': 'AAC_128', 'label': 'AAC 128 kbps', 'kind': 'lossy'},
        {'id': 'LOSSLESS', 'label': 'FLAC', 'kind': 'lossless'},
        {'id': 'HI_RES', 'label': 'Hi-Res', 'kind': 'lossless'},
      ],
    }),
  ],
);

Widget _app() => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(_Settings.new),
    extensionProvider.overrideWith(_Extensions.new),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const SetupScreen(),
  ),
);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(SetupScreen)));

void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    _fixture = const AppSettings(defaultService: _providerId);
    _extensions = _loaded();
    await prefs.setString(
      'setup_progress_v1',
      jsonEncode({'flowVersion': 4, 'step': 0}),
    );
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('1/2'), findsOneWidget);
  }

  Finder tile(String key) => find.byKey(ValueKey(key));

  bool selected(WidgetTester tester, String key) {
    final semantics = tester.getSemantics(tile(key));
    return semantics.getSemanticsData().flagsCollection.isSelected ==
        Tristate.isTrue;
  }

  testWidgets('light automatic and best download are selected by default', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    expect(selected(tester, 'setup_streaming_auto_light'), isTrue);
    expect(selected(tester, 'setup_streaming_AAC_128'), isFalse);
    expect(selected(tester, 'setup_provider_$_providerId'), isTrue);
    expect(selected(tester, 'setup_download_AAC_128'), isTrue);
    expect(selected(tester, 'setup_download_LOSSLESS'), isFalse);
    expect(find.text('Streaming quality'), findsOneWidget);
    expect(find.text('Download quality'), findsOneWidget);
    expect(find.text('AAC 128 kbps'), findsNWidgets(2));
    handle.dispose();
  });

  testWidgets('wait notice and the preselected provider are shown', (
    tester,
  ) async {
    await open(tester);
    expect(find.text(_notice), findsOneWidget);
    expect(find.text(_providerName), findsOneWidget);
  });

  testWidgets('changing streaming and download quality persists', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester);
    await tester.ensureVisible(tile('setup_streaming_AAC_128'));
    await tester.tap(tile('setup_streaming_AAC_128'));
    await tester.pumpAndSettle();
    expect(
      _container(tester).read(settingsProvider).playbackQuality,
      'AAC_128',
    );
    expect(selected(tester, 'setup_streaming_AAC_128'), isTrue);
    expect(selected(tester, 'setup_streaming_auto_light'), isFalse);

    await tester.ensureVisible(tile('setup_download_HI_RES'));
    await tester.tap(tile('setup_download_HI_RES'));
    await tester.pumpAndSettle();
    final settings = _container(tester).read(settingsProvider);
    expect(settings.audioQuality, 'HI_RES');
    expect(selected(tester, 'setup_download_HI_RES'), isTrue);
    expect(selected(tester, 'setup_download_LOSSLESS'), isFalse);

    // Back to light automatic.
    await tester.ensureVisible(tile('setup_streaming_auto_light'));
    await tester.tap(tile('setup_streaming_auto_light'));
    await tester.pumpAndSettle();
    expect(
      _container(tester).read(settingsProvider).playbackQuality,
      'auto_light',
    );
    handle.dispose();
  });

  testWidgets('skipping keeps the defaults and moves on', (tester) async {
    await open(tester);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('2/2'), findsOneWidget);
    expect(find.text('Import library'), findsOneWidget);
    final settings = _container(tester).read(settingsProvider);
    expect(settings.playbackQuality, 'auto_light');
    expect(settings.audioQuality, 'AAC_128');
  });

  testWidgets('stale stored quality falls back to light automatic', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _fixture = const AppSettings(
      defaultService: _providerId,
      playbackQuality: 'GONE',
    );
    await open(tester);
    expect(selected(tester, 'setup_streaming_auto_light'), isTrue);
    expect(
      _container(tester).read(settingsProvider).playbackQuality,
      'auto_light',
    );
    handle.dispose();
  });

  testWidgets('gives a notice when qualities never load', (tester) async {
    _extensions = const ExtensionState();
    await tester.pumpWidget(_app());
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('setup_quality_gave_up')), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('setup_quality_loading')), findsNothing);
    expect(find.byKey(const ValueKey('setup_quality_gave_up')), findsOneWidget);
    expect(
      find.text(
        'Qualities could not be loaded. Standard options are shown, and you can change them later in Settings.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('best available is saved as the download quality', (
    tester,
  ) async {
    _extensions = const ExtensionState();
    await tester.pumpWidget(_app());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final tile = find.byKey(const ValueKey('setup_download_best_available'));
    await tester.ensureVisible(tile);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 100));
    final container = _container(tester);
    expect(container.read(settingsProvider).audioQuality, 'best');
  });

  testWidgets('before providers load generic defaults stay selected', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    _extensions = const ExtensionState();
    // The discreet spinner never settles, so pump fixed frames instead.
    await tester.pumpWidget(_app());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('1/2'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup_quality_loading')), findsOneWidget);
    expect(selected(tester, 'setup_streaming_auto_light'), isTrue);
    expect(selected(tester, 'setup_download_best_available'), isTrue);
    expect(find.text(_notice), findsOneWidget);

    // The user can already move on, and picks stay valid once options arrive.
    final container = _container(tester);
    (container.read(extensionProvider.notifier) as _Extensions).publish(
      _loaded(),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('setup_quality_loading')), findsNothing);
    expect(selected(tester, 'setup_streaming_auto_light'), isTrue);
    expect(selected(tester, 'setup_download_AAC_128'), isTrue);
    expect(
      find.byKey(const ValueKey('setup_download_best_available')),
      findsNothing,
    );
    handle.dispose();
  });

  testWidgets('next button stays above the bottom system inset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 48);
    tester.view.viewPadding = const FakeViewPadding(bottom: 48);
    addTearDown(tester.view.reset);
    await open(tester);
    final next = tester.getRect(find.text('Next'));
    expect(next.bottom, lessThanOrEqualTo(800 - 48));
    final actions = tester.getRect(
      find.byKey(const ValueKey('setup_navigation')),
    );
    expect(actions.bottom, lessThanOrEqualTo(800 - 48));
    // The list scrolls instead of overflowing on a short screen.
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screen with large text scrolls without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_Extensions.new),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: const SetupScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text(_notice), findsOneWidget);
    final actions = tester.getRect(
      find.byKey(const ValueKey('setup_navigation')),
    );
    expect(actions.bottom, lessThanOrEqualTo(568));
    expect(tester.takeException(), isNull);
  });
}
