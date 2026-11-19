import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/setup_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const secure = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  testWidgets(
    'real settings load failure preserves saved data and retry persists completion',
    (tester) async {
      const original = AppSettings(
        downloadDirectory: '/existing/music',
        autoDownloadSavedTracks: true,
        playbackQuality: 'HIGH',
      );
      final originalJson = jsonEncode(original.toJson());
      final draft = jsonEncode({
        'flowVersion': 2,
        'step': 2,
      });
      final oldTaste = jsonEncode({
        'genres': ['Jazz'],
        'artists': ['Old artist'],
      });
      SharedPreferences.setMockInitialValues({
        'app_settings': originalJson,
        'settings_migration_version': 15,
        'setup_progress_v1': draft,
        'music_preferences_v1': oldTaste,
      });
      final prefs = await SharedPreferences.getInstance();
      var failLoad = true;
      var loadAttempts = 0;
      Future<SharedPreferences> loadPreferences() async {
        loadAttempts++;
        if (failLoad) throw StateError('controlled preferences failure');
        return prefs;
      }

      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        secure,
        (_) async => null,
      );
      addTearDown(
        () => binding.defaultBinaryMessenger.setMockMethodCallHandler(
          secure,
          null,
        ),
      );
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
            settingsProvider.overrideWith(
              () => SettingsNotifier(preferences: loadPreferences),
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
      expect(loadAttempts, greaterThan(0));
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('setup_import_playlist_link')),
            )
            .enabled,
        isFalse,
      );
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.byType(SetupScreen), findsOneWidget);
      expect(prefs.getString('app_settings'), originalJson);
      expect(prefs.getString('music_preferences_v1'), oldTaste);
      expect(prefs.getString('setup_progress_v1'), draft);

      failLoad = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('setup_import_playlist_link')),
            )
            .enabled,
        isTrue,
      );
      expect(
        find.textContaining('queued for automatic download'),
        findsOneWidget,
      );
      await tester.tap(find.text('Get Started'));
      await tester.pumpAndSettle();
      expect(find.text('Home fixture'), findsOneWidget);
      expect(prefs.getString('setup_progress_v1'), isNull);
      final taste = jsonDecode(prefs.getString('music_preferences_v1')!) as Map;
      expect(taste['genres'], ['Jazz']);
      expect(taste['artists'], ['Old artist']);

      // Reconstruct the provider to check actual persisted state, not widget state.
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      await restarted.read(settingsProvider.notifier).ensureLoaded();
      final restored = restarted.read(settingsProvider);
      expect(restored.isFirstLaunch, isFalse);
      expect(restored.hasCompletedTutorial, isTrue);
      expect(restored.downloadDirectory, '/existing/music');
      expect(restored.autoDownloadSavedTracks, isTrue);
      expect(restored.playbackQuality, 'HIGH');
    },
  );
}
