import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/screens/settings/download_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/utils/desktop_platform.dart';

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    extensions: [
      Extension(
        id: 'example',
        name: 'example',
        displayName: 'Example',
        version: '1.0',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [
          QualityOption(id: 'low', label: 'Low quality'),
          QualityOption(id: 'LOW', label: 'Duplicate low quality'),
          QualityOption(id: 'high', label: 'High quality'),
        ],
      ),
    ],
  );
}

void main() {
  testWidgets(
    'download settings offer neither conversion nor quality or provider choices',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger = tester.binding.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(secure, (_) async => null);
      addTearDown(() => messenger.setMockMethodCallHandler(secure, null));
      SharedPreferences.setMockInitialValues({
        'settings_migration_version': 15,
        'app_settings': jsonEncode({
          'autoConvertDownloads': true,
          'autoConvertFormat': 'flac',
          'autoConvertMaxBitDepth': 24,
        }),
      });
      await tester.pumpWidget(
        ProviderScope(
          overrides: [extensionProvider.overrideWith(_Extensions.new)],
          child: const MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: DownloadSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(CustomScrollView).first,
        const Offset(0, -560),
      );
      await tester.pumpAndSettle();
      expect(find.text('Default download format'), findsNothing);
      expect(find.text('FLAC (legacy preference)'), findsNothing);
      expect(find.text('Audio Quality'), findsNothing);
      expect(find.text('Service'), findsNothing);
    },
  );
}
