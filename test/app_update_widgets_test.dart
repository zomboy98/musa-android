import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/screens/settings/about_page.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/widgets/app_update_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements AppUpdatePlatform {
  @override
  bool get isAndroid => true;
  @override
  Future<int?> installedBuild() async => 2232;
  @override
  Future<bool> canInstallPackages() async => true;
  @override
  Future<void> openInstallPermissionSettings() async {}
  @override
  Future<int?> freeBytes(String path) async => null;
  @override
  Future<Directory> updateDirectory() async => Directory.systemTemp;
  @override
  Future<bool> openInstaller(String path) async => true;
}

final _checkedAt = DateTime(2026, 11, 20, 9, 30);

void _seed({bool withOffer = true}) {
  SharedPreferences.setMockInitialValues({
    if (withOffer)
      'app_update_offer_v1': jsonEncode({
        'label': 'v0.9 beta 5',
        'version': '5.3.1',
        'build': 2236,
        'channel': 'beta',
        'notes': 'Mejoras de reproduccion',
        'apk_url':
            'https://github.com/zomboy98/musa-android/releases/download/v1/musa.apk',
        'sha256': 'b' * 64,
        'size_bytes': 2048,
        'published_at': '2026-11-20',
      }),
    'app_update_checked_at_ms': _checkedAt.millisecondsSinceEpoch,
  });
}

Future<ProviderContainer> _pump(WidgetTester tester, Widget home) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final service = AppUpdateService(
    platform: _Platform(),
    client: MockClient((request) async => throw const SocketException('x')),
  );
  final container = ProviderContainer(
    overrides: [appUpdateServiceProvider.overrideWithValue(service)],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: home),
      ),
    ),
  );
  await tester.runAsync(() => container.read(appUpdateProvider.notifier).ready);
  await tester.pump();
  return container;
}

void main() {
  testWidgets('el indicador de Inicio aparece con oferta y se oculta solo en la sesion', (
    tester,
  ) async {
    _seed();
    final container = await _pump(tester, const AppUpdateBanner());
    expect(
      find.text('Actualización disponible · v0.9 beta 5'),
      findsOneWidget,
    );
    expect(find.text('Actualizar'), findsOneWidget);

    await tester.tap(find.byTooltip('Ocultar por ahora'));
    await tester.pump();
    expect(find.textContaining('Actualización disponible'), findsNothing);
    expect(container.read(appUpdateProvider).hasOffer, isTrue);
  });

  testWidgets('sin oferta no hay indicador', (tester) async {
    _seed(withOffer: false);
    await _pump(tester, const AppUpdateBanner());
    expect(find.textContaining('Actualización disponible'), findsNothing);
  });

  testWidgets('Acerca muestra la seccion Actualizaciones con la oferta', (
    tester,
  ) async {
    _seed();
    await _pump(tester, const AboutPage(showUpdates: true));
    await tester.pump();
    final title = find.text('Actualizaciones');
    await tester.scrollUntilVisible(title, 200);
    expect(title, findsOneWidget);
    expect(find.text('Versión instalada'), findsOneWidget);
    expect(find.textContaining('compilación 2232'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Actualización disponible: v0.9 beta 5'),
      200,
    );
    expect(find.text('Mejoras de reproduccion'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.text('Actualizar'), findsOneWidget);
    expect(find.text('Buscar actualizaciones'), findsOneWidget);
    expect(find.textContaining('Última consulta'), findsOneWidget);
  });

  testWidgets('Acerca dice que esta al dia cuando no hay oferta', (
    tester,
  ) async {
    _seed(withOffer: false);
    await _pump(tester, const AboutPage(showUpdates: true));
    await tester.pump();
    final status = find.text('MUSA está al día.');
    await tester.scrollUntilVisible(status, 200);
    expect(status, findsOneWidget);
    expect(find.text('Actualizar'), findsNothing);
    expect(find.text('Buscar actualizaciones'), findsOneWidget);
  });

  testWidgets('Acerca sin Android no muestra la seccion', (tester) async {
    _seed();
    await _pump(tester, const AboutPage(showUpdates: false));
    expect(find.text('Actualizaciones'), findsNothing);
  });
}
