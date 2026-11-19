import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/screens/settings/settings_tab.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  final navigator = GlobalKey<NavigatorState>();

  Future<void> pumpPanel(
    WidgetTester tester, {
    ThemeData? theme,
    double textScale = 1,
    Size size = const Size(320, 640),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: theme ?? AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          home: Stack(
            children: [
              const Positioned.fill(
                child: ColoredBox(
                  key: ValueKey('home-backdrop'),
                  color: Colors.red,
                ),
              ),
              Navigator(
                key: navigator,
                onGenerateRoute: (_) => PageRouteBuilder<void>(
                  opaque: false,
                  pageBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    unawaited(navigator.currentState!.push(SettingsTab.glassRoute()));
    await tester.pumpAndSettle();
  }

  testWidgets('root panel shows header, profile card and glass groups', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.text('MUSA'), findsOneWidget);
    expect(find.byKey(const ValueKey('close-settings-panel')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-profile-card')), findsOneWidget);
    expect(find.byType(VisionGlassCard), findsWidgets);
    expect(find.byType(VisionIconBadge), findsWidgets);
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('home backdrop stays visible behind the scrim', (tester) async {
    await pumpPanel(tester);

    expect(find.byKey(const ValueKey('home-backdrop')), findsOneWidget);
    final scrim = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(SettingsTab),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    final gradient = (scrim.decoration as BoxDecoration).gradient!;
    expect(gradient.colors.every((color) => color.a < 1), isTrue);
    expect(gradient.colors.first.a, greaterThanOrEqualTo(.92));
  });

  testWidgets('computer link entry is hidden from the menu and search', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.text('MUSA en tu computadora'), findsNothing);
    await tester.enterText(find.byType(TextField), 'computer');
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.computer), findsNothing);
  });

  testWidgets('close button pops the panel', (tester) async {
    await pumpPanel(tester);

    await tester.tap(find.byKey(const ValueKey('close-settings-panel')));
    await tester.pumpAndSettle();

    expect(find.byType(SettingsTab), findsNothing);
  });

  for (final dark in [true, false]) {
    testWidgets('no overflow at 320dp with 2x text (dark: $dark)', (
      tester,
    ) async {
      await pumpPanel(
        tester,
        theme: dark ? AppTheme.dark() : AppTheme.light(),
        textScale: 2,
      );

      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -500));
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('search filters rows inside one glass card', (tester) async {
    await pumpPanel(tester);

    await tester.enterText(find.byType(TextField), 'lyrics');
    await tester.pumpAndSettle();

    expect(find.byType(VisionGlassCard), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
