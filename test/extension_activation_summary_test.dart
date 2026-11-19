import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/settings/extensions_page.dart';

void main() {
  testWidgets('shows the current active providers and global scope', (
    tester,
  ) async {
    Future<void> show(List<String> names) => tester.pumpWidget(
      MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ExtensionActivationSummary(activeNames: names)),
      ),
    );

    await show(['First', 'Second']);
    expect(find.textContaining('Active: First, Second.'), findsOneWidget);
    expect(find.textContaining('also affects search and metadata'), findsOneWidget);
    await show(['Second']);
    expect(find.textContaining('Active: Second.'), findsOneWidget);
    expect(find.textContaining('Active: First'), findsNothing);
    await show([]);
    expect(find.textContaining('Active: None.'), findsOneWidget);
  });
}
