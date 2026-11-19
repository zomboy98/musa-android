import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/settings/bug_log_page.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/services/app_remote_config_service.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  // Keep the process-wide production singleton in one fake async zone.
  testWidgets('Settings bug log flow across themes and viewport sizes', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    for (final dark in [false, true]) {
      for (final size in [const Size(360, 640), const Size(1280, 800)]) {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        String? copied;
        String? shared;
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform, (
          call,
        ) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        });
        const shareChannel = MethodChannel('dev.fluttercommunity.plus/share');
        messenger.setMockMethodCallHandler(shareChannel, (call) async {
          shared = (call.arguments as Map)['text'] as String?;
          return 'success';
        });
        addTearDown(() {
          messenger.setMockMethodCallHandler(SystemChannels.platform, null);
          messenger.setMockMethodCallHandler(shareChannel, null);
        });
        await tester.pumpWidget(
          ProviderScope(
            child: MaterialApp(
              theme: dark
                  ? MornyeTheme.build(Brightness.dark)
                  : AppTheme.light(),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: SettingsTab(
                  remoteConfigService: AppRemoteConfigService(
                    client: MockClient((_) async => http.Response('{}', 200)),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).first, 'bug');
        await tester.pumpAndSettle();
        expect(find.text('Bug log'), findsOneWidget);
        await tester.tap(find.text('Bug log'));
        await tester.pumpAndSettle();
        expect(find.byType(BugLogPage), findsOneWidget);
        expect(
          find.textContaining(
            'Notes you add are included when copied or shared',
          ),
          findsOneWidget,
        );
        expect(find.text('No errors recorded yet.'), findsOneWidget);
        await tester.tap(find.text('Add note'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Optional. Do not include sensitive information'),
          findsOneWidget,
        );
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(await BugLog.instance.entries(), isEmpty);
        await tester.tap(find.text('Add note'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'Stopped after play');
        await tester.tap(find.text('Save'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('Copy'));
        await tester.tap(find.text('Copy'));
        await tester.pumpAndSettle();
        expect(copied, contains('Stopped after play'));
        await tester.tap(find.text('Share'));
        await tester.pumpAndSettle();
        expect(shared, copied);
        await tester.ensureVisible(find.text('Clear'));
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect((await BugLog.instance.entries()).length, 1);
        await tester.tap(find.text('Clear'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Clear').last);
        await tester.pumpAndSettle();
        expect(find.text('No errors recorded yet.'), findsOneWidget);
        expect(await BugLog.instance.entries(), isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      }
    }
  });
}
