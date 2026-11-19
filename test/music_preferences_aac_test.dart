import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'legacy bitrate remains stored without an ineffective playback control',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'app_settings': jsonEncode({
          'playbackQuality': 'HI_RES',
          'playbackCacheBitrate': '192k',
          'audioQuality': 'LOSSLESS',
          'autoConvertFormat': 'opus',
          'autoConvertBitrate': '160k',
        }),
      });
      Widget app(Locale locale) => ProviderScope(
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MusicPreferencesPage(expandSectionsForTest: true),
        ),
      );
      await tester.pumpWidget(app(const Locale('es')));
      await tester.pumpAndSettle();
      expect(find.text('Calidad de streaming'), findsOneWidget);
      expect(find.text('Audio temporal AAC'), findsNothing);
      expect(find.text('Bitrate de reproducción'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      var container = ProviderScope.containerOf(
        tester.element(find.byType(MusicPreferencesPage)),
      );
      expect(container.read(settingsProvider).playbackCacheBitrate, '192k');
      expect(container.read(settingsProvider).playbackQuality, 'HI_RES');
      expect(container.read(settingsProvider).audioQuality, 'LOSSLESS');
      final prefs = await SharedPreferences.getInstance();
      expect((jsonDecode(prefs.getString('app_settings')!) as Map)['playbackCacheBitrate'], '192k');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app(const Locale('en')));
      await tester.pumpAndSettle();
      container = ProviderScope.containerOf(
        tester.element(find.byType(MusicPreferencesPage)),
      );
      expect(find.text('Streaming quality'), findsOneWidget);
      expect(find.text('Temporary AAC audio'), findsNothing);
      expect(find.text('Playback bitrate'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(container.read(settingsProvider).playbackCacheBitrate, '192k');
    },
  );
}
