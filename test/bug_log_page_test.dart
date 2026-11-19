import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/settings/bug_log_page.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('unreadable log is preserved until explicitly cleared', (tester) async {
    const corrupt = '{invalid test data';
    SharedPreferences.setMockInitialValues({BugLog.key: corrupt});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: BugLogPage(bugLog: BugLog())));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load the log.'), findsOneWidget);
    expect(find.text('No errors recorded yet.'), findsNothing);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.textContaining('The log is unreadable.'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(prefs.getString(BugLog.key), corrupt);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(prefs.getString(BugLog.key), isNull);
    expect(find.text('No errors recorded yet.'), findsOneWidget);
  });
  testWidgets('note dialog fits with enlarged text and keyboard', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: const TextScaler.linear(2)),
      child: child!,
    ), home: BugLogPage(bugLog: BugLog())));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Add note'), 200);
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Playback failed');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect((await BugLog().entries()).single['note'], 'Playback failed');
  });
  testWidgets('adds an explicit note and includes it in copied report', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: BugLogPage(bugLog: log)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add note'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Do not include sensitive information'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Player stopped after tapping play');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Player stopped after tapping play'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('Player stopped after tapping play'));
  });
  testWidgets('lists sanitized records, copies and clears after confirmation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final log = BugLog();
    await log.record(
      'download',
      error: StateError('password=secret https://host/?token=abc'),
    );
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: BugLogPage(bugLog: log)));
    await tester.pumpAndSettle();
    expect(find.text('download · StateError'), findsOneWidget);
    expect(find.textContaining('secret'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, contains('StateError'));
    expect(copied, isNot(contains('secret')));
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('download · StateError'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(find.text('No errors recorded yet.'), findsOneWidget);
  });

  testWidgets('shows clear failure and preserves the displayed record', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var fail = false;
    final log = BugLog(
      preferences: () async {
        if (fail) throw StateError('unavailable');
        return prefs;
      },
    );
    await log.record('player');
    await tester.pumpWidget(MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,home: BugLogPage(bugLog: log)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    fail = true;
    await tester.tap(find.text('Clear').last);
    await tester.pumpAndSettle();
    expect(find.text('Could not clear the log.'), findsOneWidget);
    expect(find.text('player · Error'), findsOneWidget);
  });
}
