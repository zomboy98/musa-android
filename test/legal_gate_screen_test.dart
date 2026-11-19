import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/app.dart';
import 'package:mornye/constants/legal_links.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/legal_gate_screen.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Widget _app(
  Widget home, {
  double textScale = 1,
  Locale locale = const Locale('es'),
}) => ProviderScope(
  child: MaterialApp(
    theme: AppTheme.dark(),
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: home,
  ),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('continue stays disabled until the terms are accepted', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const LegalGateScreen()));
    await tester.pump();
    final button = find.byKey(const Key('legal-continue'));
    await tester.scrollUntilVisible(button, 200);
    expect(tester.widget<FilledButton>(button).onPressed, isNull);
    await tester.tap(find.byKey(const Key('legal-accept-checkbox')));
    await tester.pump();
    expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
  });

  testWidgets('declining calls the close handler', (tester) async {
    var closed = 0;
    await tester.pumpWidget(_app(LegalGateScreen(onDecline: () => closed++)));
    await tester.pump();
    final decline = find.byKey(const Key('legal-decline'));
    await tester.scrollUntilVisible(decline, 200);
    await tester.tap(decline);
    expect(closed, 1);
    expect(
      find.text('Si no aceptas, MUSA se cierra y no se guarda nada.'),
      findsOneWidget,
    );
  });

  testWidgets('accepting stores the policy version and date', (tester) async {
    late WidgetRef captured;
    await tester.pumpWidget(
      _app(
        Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const LegalGateScreen();
          },
        ),
      ),
    );
    await tester.pump();
    final check = find.byKey(const Key('legal-accept-checkbox'));
    await tester.scrollUntilVisible(check, 200);
    await tester.tap(check);
    await tester.pump();
    await tester.tap(find.byKey(const Key('legal-continue')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    final saved = captured.read(settingsProvider);
    expect(saved.acceptedLegalVersion, legalPolicyVersion);
    expect(DateTime.tryParse(saved.acceptedLegalAt), isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_settings'), contains('acceptedLegalVersion'));
  });

  test('a newer policy version asks again and routes to the gate', () {
    expect(
      initialLocationForAppState(
        isFirstLaunch: false,
        hasCompletedTutorial: true,
        legalAccepted: false,
      ),
      '/legal',
    );
    expect(
      initialLocationForAppState(
        isFirstLaunch: true,
        hasCompletedTutorial: false,
        legalAccepted: true,
      ),
      '/setup',
    );
    const old = AppSettings(acceptedLegalVersion: legalPolicyVersion);
    expect(old.acceptedLegalVersion >= legalPolicyVersion, isTrue);
    expect(old.acceptedLegalVersion >= legalPolicyVersion + 1, isFalse);
    expect(const AppSettings().acceptedLegalVersion, 0);
    expect(const AppSettings().analyticsEnabled, isTrue);
  });

  test('settings read tolerantly and keep acceptance', () {
    final plain = AppSettings.fromJson(<String, dynamic>{});
    expect(plain.acceptedLegalVersion, 0);
    expect(plain.analyticsEnabled, isTrue);
    final round = AppSettings.fromJson(
      const AppSettings(
        acceptedLegalVersion: 3,
        acceptedLegalAt: '2026-11-18T10:00:00Z',
        analyticsEnabled: false,
      ).toJson(),
    );
    expect(round.acceptedLegalVersion, 3);
    expect(round.analyticsEnabled, isFalse);
  });

  testWidgets('shows the web links and the local reader', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _app(LegalGateScreen(openUrl: (url) async => opened.add(url))),
    );
    await tester.pump();
    final privacy = find.byKey(const Key('legal-open-privacy'));
    await tester.scrollUntilVisible(privacy, 200);
    await tester.tap(privacy);
    await tester.tap(find.byKey(const Key('legal-open-terms')));
    expect(opened, [legalPrivacyUrl, legalTermsUrl]);
    expect(legalPrivacyUrl, 'https://musa.heyshin.app/privacidad.html');
    expect(legalTermsUrl, 'https://musa.heyshin.app/terminos.html');
    await tester.tap(find.byKey(const Key('legal-read-here')));
    await tester.pumpAndSettle();
    expect(find.byType(LegalTextsScreen), findsOneWidget);
    expect(find.text('Política de privacidad'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0]) {
    for (final locale in [const Locale('es'), const Locale('en')]) {
      testWidgets('no overflow at 360x640, text x$scale, $locale', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(360, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _app(const LegalGateScreen(), textScale: scale, locale: locale),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.drag(
          find.byType(SingleChildScrollView),
          const Offset(0, -3000),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          _app(const LegalTextsScreen(), textScale: scale, locale: locale),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
