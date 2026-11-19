import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/support_project_card.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.dark}) =>
    MaterialApp(
      theme: MornyeTheme.build(brightness),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('es'),
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );

void main() {
  testWidgets('hidden when the url is empty', (tester) async {
    await tester.pumpWidget(_host(const SupportProjectCard(url: '')));
    await tester.pumpAndSettle();
    expect(find.text('Apoyar el proyecto'), findsNothing);
    expect(find.byKey(const ValueKey('profile-panel-support')), findsNothing);
  });

  for (final brightness in Brightness.values) {
    testWidgets('shows copy and opens the link ($brightness)', (tester) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        _host(
          SupportProjectCard(
            url: 'https://example.com/x',
            launcher: (uri) async {
              launched.add(uri);
              return true;
            },
          ),
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Apoyar el proyecto'), findsOneWidget);
      expect(
        find.text('Ayuda a mejorar el soporte y las actualizaciones'),
        findsOneWidget,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('profile-panel-support')))
            .height,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byKey(const ValueKey('profile-panel-support')));
      await tester.pump();
      expect(launched, [Uri.parse('https://example.com/x')]);
    });
  }

  testWidgets('no overflow at 320 dp with 2x text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(16),
            child: SupportProjectCard(url: 'https://example.com/x'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Apoyar el proyecto'), findsOneWidget);
  });

  testWidgets('failed launch shows a message', (tester) async {
    await tester.pumpWidget(
      _host(
        SupportProjectCard(
          url: 'https://example.com/x',
          launcher: (_) async => false,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('profile-panel-support')));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
