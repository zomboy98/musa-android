import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/plugin_code_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:mornye/services/plugin_code_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(downloadDirectory: '/existing/music');

  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  late Directory temp;
  late SharedPreferences prefs;
  var failCode = false;
  var installs = 0;
  var preinstalled = false;
  var installOk = true;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('setup_code_gate_');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    failCode = false;
    installs = 0;
    preinstalled = false;
    installOk = true;
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {}
  });

  Future<http.Response> handler(http.Request request) async {
    if (request.url.host == 'musa-api.heyshin.app') {
      if (failCode) return http.Response('{}', 404);
      return http.Response(
        jsonEncode({
          'name': 'Pack',
          'items': [
            {
              'id': 'p1',
              'name': 'Item 1',
              'version': '1.0.0',
              'url': 'https://files.example.com/p1.mornye-ext',
              'sha256': sha256.convert(utf8.encode('package-1')).toString(),
            },
          ],
        }),
        200,
      );
    }
    return http.Response.bytes(utf8.encode('package-1'), 200);
  }

  Future<ProviderContainer> open(WidgetTester tester) async {
    final router = GoRouter(
      initialLocation: '/setup',
      routes: [
        GoRoute(path: '/setup', builder: (_, _) => const SetupScreen()),
        GoRoute(path: '/', builder: (_, _) => const Text('Home fixture')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          pluginCodeServiceProvider.overrideWithValue(
            PluginCodeService(client: MockClient(handler), tempRoot: temp),
          ),
          pluginCodeInstallerProvider.overrideWithValue(
            PluginCodeInstaller(
              prepare: () async {},
              installedVersions: () => preinstalled ? const {'p1': '1.0.0'} : const {},
              install: (_) async {
                installs++;
                return installOk;
              },
              upgrade: (_) async => true,
              finish: () {},
            ),
          ),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(SetupScreen)));
  }

  Future<void> redeem(WidgetTester tester) async {
    await tester.enterText(
      find.byKey(const ValueKey('plugin-code-field')),
      '9r2-wuh',
    );
    await tester.tap(find.byKey(const ValueKey('plugin-code-add')));
    for (var i = 0; i < 30; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
  }

  testWidgets('the first step asks for a code and shows a single step', (
    tester,
  ) async {
    await open(tester);
    expect(find.textContaining('add-on code'), findsOneWidget);
    expect(find.text('1/1'), findsOneWidget);
    expect(find.text('Skip for now'), findsOneWidget);
    expect(find.text('Next'), findsNothing);
    expect(find.text('Which genres do you like?'), findsNothing);
  });

  testWidgets('skipping finishes setup without catalog steps', (tester) async {
    final container = await open(tester);
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('Home fixture'), findsOneWidget);
    expect(find.text('Which genres do you like?'), findsNothing);
    expect(find.text('Import library'), findsNothing);
    final settings = container.read(settingsProvider);
    expect(settings.isFirstLaunch, isFalse);
    expect(settings.hasCompletedTutorial, isTrue);
    expect(prefs.getString('setup_progress_v1'), isNull);
    expect(prefs.getString('music_preferences_v1'), isNull);
  });

  testWidgets('a redeemed code unlocks Next and continues to quality', (
    tester,
  ) async {
    final container = await open(tester);
    await redeem(tester);
    expect(installs, 1);
    expect(find.text('Added: Item 1'), findsOneWidget);
    expect(find.text('1/3'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('setup_code_next')));
    await tester.pumpAndSettle();
    expect(find.text('Sound quality'), findsOneWidget);
    expect(find.text('2/3'), findsOneWidget);
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    expect(find.text('Import library'), findsOneWidget);
    await tester.tap(find.text('Get Started'));
    await tester.pumpAndSettle();
    expect(find.text('Home fixture'), findsOneWidget);
    final settings = container.read(settingsProvider);
    expect(settings.isFirstLaunch, isFalse);
    expect(settings.hasCompletedTutorial, isTrue);
    expect(prefs.getString('setup_progress_v1'), isNull);
    expect(prefs.getString('music_preferences_v1'), isNull);
  });

  testWidgets('an invalid code can be retried or skipped', (tester) async {
    failCode = true;
    await open(tester);
    await redeem(tester);
    expect(find.text('Invalid code'), findsOneWidget);
    expect(find.byKey(const ValueKey('setup_code_next')), findsNothing);
    expect(find.text('1/1'), findsOneWidget);
    failCode = false;
    await redeem(tester);
    expect(find.byKey(const ValueKey('setup_code_next')), findsOneWidget);
    failCode = true;
    await tester.tap(find.text('Skip for now'));
    await tester.pumpAndSettle();
    expect(find.text('Home fixture'), findsOneWidget);
  });

  testWidgets('items already bundled still unlock Next', (tester) async {
    preinstalled = true;
    await open(tester);
    await redeem(tester);
    expect(installs, 0);
    expect(find.byKey(const ValueKey('setup_code_next')), findsOneWidget);
  });

  testWidgets('all items failing keeps Next hidden', (tester) async {
    installOk = false;
    await open(tester);
    await redeem(tester);
    expect(installs, 1);
    expect(find.byKey(const ValueKey('setup_code_next')), findsNothing);
  });
}
