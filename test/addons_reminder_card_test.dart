import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/widgets/addons_reminder_card.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Extensions extends ExtensionNotifier {
  _Extensions(this.loading);
  final bool loading;

  @override
  ExtensionState build() =>
      ExtensionState(isInitialized: true, isLoading: loading);
}

Widget _app({bool loading = false, VoidCallback? onEnter}) => ProviderScope(
  overrides: [extensionProvider.overrideWith(() => _Extensions(loading))],
  child: MaterialApp(
    locale: const Locale('es'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: AddonsReminderCard(onEnterCode: onEnter ?? () {}),
    ),
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the reminder when no add-on is installed', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Consigue más funciones'), findsOneWidget);
    expect(find.text('Pedir código'), findsOneWidget);
  });

  testWidgets('hidden while extensions load', (tester) async {
    await tester.pumpWidget(_app(loading: true));
    await tester.pumpAndSettle();
    expect(find.text('Consigue más funciones'), findsNothing);
  });

  testWidgets('enter-code button calls back and close stays dismissed', (
    tester,
  ) async {
    var entered = 0;
    await tester.pumpWidget(_app(onEnter: () => entered++));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ya tengo un código'));
    expect(entered, 1);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Consigue más funciones'), findsNothing);
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    expect(find.text('Consigue más funciones'), findsNothing);
  });
}
