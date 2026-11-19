import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/report/report_page.dart';
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('about page offers to report an issue and opens the report screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.dark(),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const AboutPage(),
        ),
      ),
    );
    await tester.pump();

    final row = find.text('Reportar un problema');
    await tester.scrollUntilVisible(row, 200);
    expect(row, findsOneWidget);
    expect(
      find.text('Reporta cualquier problema que encuentres'),
      findsOneWidget,
    );

    await tester.ensureVisible(row);
    await tester.pump();
    await tester.tap(row);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ReportPage), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
  });
}
