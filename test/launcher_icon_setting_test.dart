import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/settings/launcher_icon_setting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('musa/launcher_icon');
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  testWidgets('reads and changes the selected icon', (tester) async {
    var selected = 'original';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'set') {
          final arguments = call.arguments as Map<Object?, Object?>;
          selected = arguments['id']! as String;
        }
          return selected;
        });
    await tester.pumpWidget(
      MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: Scaffold(body: LauncherIconSetting())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('App icon'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chrome'));
    await tester.pumpAndSettle();
    expect(selected, 'chrome');
    await tester.tap(find.text('App icon'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListTile>(find.widgetWithText(ListTile, 'Chrome')).selected,
      isTrue,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('shows an error if the native read fails', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          throw PlatformException(code: 'failure');
        });
    await tester.pumpWidget(
      MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: Scaffold(body: LauncherIconSetting())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not read or change the icon.'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
