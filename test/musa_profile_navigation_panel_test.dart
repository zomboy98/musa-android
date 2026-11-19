import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/user_profile_provider.dart';
import 'package:mornye/services/user_profile_store.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/services/shell_navigation_service.dart';
import 'package:mornye/screens/settings/profile_settings_page.dart';
import 'package:mornye/screens/listening_statistics_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/profile_avatar.dart';
import 'package:mornye/widgets/profile_navigation_panel.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Profile extends UserProfileNotifier {
  @override
  Future<UserProfile> build() async =>
      const UserProfile(name: 'Perfil de prueba');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  setUpAll(() async {
    await (FontLoader(
      'Inter',
    )..addFont(rootBundle.load('assets/fonts/InterVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final highContrast in [false, true]) {
    testWidgets('panel glass respects high contrast $highContrast', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(highContrast: highContrast),
            child: child!,
          ),
          home: MusaProfileNavigationPanel(
            name: 'Perfil de prueba',
            avatar: const ProfileAvatar(name: 'P'),
            onSelected: (_) {},
            onClose: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byType(BackdropFilter),
        highContrast ? findsNothing : findsOneWidget,
      );
      final material = tester.widget<Material>(
        find.byKey(const ValueKey('profile-panel-material')),
      );
      expect(
        material.color!.a,
        highContrast ? 1 : closeTo(kProfilePanelDarkFillAlpha, .001),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('low glass clarity preserves solid panel geometry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: MornyeTheme.build(Brightness.dark, glassClarity: 0),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MusaProfileNavigationPanel(
          name: 'Perfil de prueba',
          avatar: const ProfileAvatar(name: 'P'),
          onSelected: (_) {},
          onClose: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('close-profile-panel'))),
      const Size(48, 48),
    );
    expect(tester.takeException(), isNull);
  });

  test(
    'panel text contrast over bright and dark backdrops with custom accents',
    () {
      double contrast(Color foreground, Color background) {
        final text = Color.alphaBlend(
          foreground,
          background,
        ).computeLuminance();
        final surface = background.computeLuminance();
        return text > surface
            ? (text + .05) / (surface + .05)
            : (surface + .05) / (text + .05);
      }

      for (final accent in [
        Colors.white,
        Colors.black,
        Colors.yellow,
        Colors.red,
        Colors.blue,
        Colors.green,
      ]) {
        final colors = MornyeTheme.build(
          Brightness.dark,
          customAccent: accent,
        ).colorScheme;
        for (final backdrop in [Colors.white, Colors.black]) {
          final panel = Color.alphaBlend(
            colors.surface.withValues(alpha: kProfilePanelDarkFillAlpha),
            Color.alphaBlend(Colors.black.withValues(alpha: .34), backdrop),
          );
          final surfaces = [
            panel,
            Color.alphaBlend(colors.onSurface.withValues(alpha: .035), panel),
            Color.alphaBlend(colors.primary.withValues(alpha: .14), panel),
          ];
          for (final surface in surfaces) {
            expect(
              contrast(colors.onSurface, surface),
              greaterThanOrEqualTo(4.5),
            );
            expect(
              contrast(colors.onSurface.withValues(alpha: .76), surface),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
      }
    },
  );

  Future<void> pumpHome(
    WidgetTester tester, {
    double width = 390,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userProfileProvider.overrideWith(_Profile.new),
          listeningSummaryProvider.overrideWith(
            (ref, period) async => const ListeningSummary(),
          ),
        ],
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(
              title: const Text('Inicio'),
              actions: const [HomeProfileButton()],
            ),
            body: const Text('Contenido de prueba'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('profile tap opens once; close, scrim and back collapse panel', (
    tester,
  ) async {
    await pumpHome(tester);
    Future<void> open() async {
      await tester.tap(find.byType(HomeProfileButton));
      await tester.pumpAndSettle();
      expect(find.byType(MusaProfileNavigationPanel), findsOneWidget);
    }

    await open();
    await tester.tap(find.byKey(const ValueKey('close-profile-panel')));
    await tester.pumpAndSettle();
    expect(find.byType(MusaProfileNavigationPanel), findsNothing);
    await open();
    await tester.tapAt(const Offset(380, 500));
    await tester.pumpAndSettle();
    expect(find.byType(MusaProfileNavigationPanel), findsNothing);
    await open();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(MusaProfileNavigationPanel), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final destination in ProfilePanelDestination.values.where(
    (d) => d != ProfilePanelDestination.extensions,
  )) {
    testWidgets('panel navigates to real ${destination.name}', (tester) async {
      ShellTab? selected;
      final owner = Object();
      ShellNavigationService.registerTabSelectionHandler(
        owner: owner,
        handler: (tab) => selected = tab,
      );
      addTearDown(
        () => ShellNavigationService.unregisterTabSelectionHandler(owner),
      );
      await pumpHome(tester);
      await tester.tap(find.byType(HomeProfileButton));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          destination == ProfilePanelDestination.profile
              ? const ValueKey('profile-panel-identity')
              : ValueKey(destination),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MusaProfileNavigationPanel), findsNothing);
      switch (destination) {
        case ProfilePanelDestination.profile:
          expect(find.byType(ProfileSettingsPage), findsOneWidget);
        case ProfilePanelDestination.statistics ||
            ProfilePanelDestination.recentListening ||
            ProfilePanelDestination.yearly:
          final screen = tester.widget<ListeningStatisticsScreen>(
            find.byType(ListeningStatisticsScreen),
          );
          expect(
            screen.initialYearly,
            destination == ProfilePanelDestination.yearly,
          );
        case ProfilePanelDestination.settings:
          expect(selected, ShellTab.settings);
        case ProfilePanelDestination.extensions:
          break;
      }
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('add-ons card at 320dp text $scale opens add-ons', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final selected = <ProfilePanelDestination>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(scale),
              disableAnimations: true,
            ),
            child: child!,
          ),
          home: Scaffold(
            body: MusaProfileNavigationPanel(
              name: 'Perfil de prueba',
              avatar: const ProfileAvatar(name: 'P'),
              onSelected: selected.add,
              onClose: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(
        const ValueKey(ProfilePanelDestination.extensions),
      );
      await tester.scrollUntilVisible(
        card,
        160,
        scrollable: find.descendant(
          of: find.byType(MusaProfileNavigationPanel),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: card, matching: find.text('Complementos')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.text('Proveedores de audio y video'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: card,
          matching: find.byIcon(Icons.extension_rounded),
        ),
        findsOneWidget,
      );
      expect(tester.getSize(card).height, greaterThanOrEqualTo(48));
      await tester.tap(card);
      await tester.pump();
      expect(selected, [ProfilePanelDestination.extensions]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('panel scrolls at 320dp text $scale; future remains disabled', (
      tester,
    ) async {
      await pumpHome(tester, width: 320, scale: scale);
      await tester.tap(find.byType(HomeProfileButton));
      await tester.pumpAndSettle();
      final future = find.byKey(const ValueKey('profile-panel-future'));
      await tester.scrollUntilVisible(
        future,
        160,
        scrollable: find.descendant(
          of: find.byType(MusaProfileNavigationPanel),
          matching: find.byType(Scrollable),
        ),
      );
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(future);
      expect(tile.enabled, isFalse);
      expect(tile.onTap, isNull);
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Semantics &&
              w.properties.enabled == false &&
              (w.properties.label ?? '').contains('No disponible'),
        ),
        findsOneWidget,
      );
      await tester.tap(future, warnIfMissed: false);
      await tester.pump();
      expect(find.byType(MusaProfileNavigationPanel), findsOneWidget);
      final close = tester.getRect(
        find.byKey(const ValueKey('close-profile-panel')),
      );
      expect(close.width, greaterThanOrEqualTo(48));
      expect(close.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('panel fictitious visual fixture', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: ProviderScope(
          overrides: [userProfileProvider.overrideWith(_Profile.new)],
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: MornyeTheme.build(Brightness.dark),
            locale: const Locale('es'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              appBar: AppBar(
                title: const Text('Inicio · Muestra'),
                actions: const [HomeProfileButton()],
              ),
              body: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Text('Contenido ficticio para revisar el material'),
                  for (final color in [
                    Colors.blueGrey,
                    Colors.teal,
                    Colors.deepPurple,
                  ])
                    Container(
                      height: 140,
                      margin: const EdgeInsets.only(top: 20),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        gradient: LinearGradient(
                          colors: [
                            color.withValues(alpha: .5),
                            color.withValues(alpha: .1),
                          ],
                        ),
                      ),
                      child: const Icon(Icons.music_note, size: 64),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(HomeProfileButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    await tester.runAsync(() async {
      final image = await boundary.toImage();
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory('design/diagnostico-musa-panel-perfil');
      await directory.create(recursive: true);
      await File(
        '${directory.path}/perfil-ficticio-390dp-v2.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      image.dispose();
    });
  });
}
