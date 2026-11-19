import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/setup_quality_step.dart';

Future<void> _pump(WidgetTester tester, Locale locale) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: SingleChildScrollView(child: SetupQualityStep()),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('aviso en espanol sin reloj de arena', (tester) async {
    await _pump(tester, const Locale('es'));
    expect(find.text('Tiempo de preparación'), findsOneWidget);
    expect(
      find.text(
        'Las calidades más altas requieren unos instantes adicionales antes '
        'de iniciar la reproducción y completar la descarga.',
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.hourglass_top_rounded), findsNothing);
    expect(
      find.byKey(const ValueKey('setup_quality_wait_notice_accent')),
      findsOneWidget,
    );
  });

  testWidgets('aviso en ingles', (tester) async {
    await _pump(tester, const Locale('en'));
    expect(find.text('Preparation time'), findsOneWidget);
    expect(
      find.text(
        'Higher qualities need a few extra moments before playback starts and '
        'the download completes.',
      ),
      findsOneWidget,
    );
  });
}
