import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_update_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements AppUpdatePlatform {
  _Platform(this.dir);
  final Directory dir;
  bool canInstall = true;
  final opened = <String>[];
  @override
  bool get isAndroid => true;
  @override
  Future<int?> installedBuild() async => 2232;
  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<void> openInstallPermissionSettings() async {}
  @override
  Future<int?> freeBytes(String path) async => null;
  @override
  Future<Directory> updateDirectory() async => dir;
  @override
  Future<bool> openInstaller(String path) async {
    opened.add(path);
    return true;
  }
}

void main() {
  final bytes = List<int>.generate(2048, (i) => i % 200);
  final manifest = jsonEncode({
    'etiqueta': '0.9 beta 3',
    'version': '5.3.1',
    'build': 2233,
    'canal': 'beta',
    'notes': 'Mejoras de reproduccion',
    'apk_url':
        'https://github.com/zomboy98/musa-android/releases/download/v0.9.0-beta.3/musa.apk',
    'sha256': sha256.convert(bytes).toString(),
    'size_bytes': bytes.length,
    'published_at': '2026-11-20',
  });

  late Directory tmp;
  late _Platform platform;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('musa_update_dialog');
    platform = _Platform(Directory('${tmp.path}/updates'));
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<AppUpdateService> pump(WidgetTester tester, {List<int>? apk}) async {
    final service = AppUpdateService(
      platform: platform,
      hashFile: (path) async =>
          sha256.convert(await File(path).readAsBytes()).toString(),
      client: MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('latest.json')) {
          final body = utf8.encode(manifest);
          return http.StreamedResponse(Stream.value(body), 200);
        }
        return http.StreamedResponse(Stream.value(apk ?? bytes), 200);
      }),
    );
    final offer = (await service.checkForUpdate()).offer!;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: MornyeTheme.build(Brightness.dark),
          locale: const Locale('es'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAppUpdateDialog(
                  context,
                  service: service,
                  offer: offer,
                ),
                child: const Text('Abrir'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Abrir'));
    await tester.pumpAndSettle();
    return service;
  }

  testWidgets('anuncia la version con su etiqueta, notas y tamano', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Actualización disponible: v0.9 beta 3'), findsOneWidget);
    expect(find.text('Mejoras de reproduccion'), findsOneWidget);
    expect(find.textContaining('2.0 KB'), findsOneWidget);
    expect(find.text('Actualizar'), findsOneWidget);
    expect(find.text('Ahora no'), findsOneWidget);
  });

  testWidgets('Ahora no recuerda la compilacion 24 horas', (tester) async {
    final service = await pump(tester);
    await tester.tap(find.text('Ahora no'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Actualización disponible'), findsNothing);
    expect(await service.isSnoozed(2233), isTrue);
  });

  testWidgets('Actualizar descarga, verifica y abre el instalador', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await pump(tester);
      await tester.tap(find.text('Actualizar'));
      for (var i = 0; i < 50 && platform.opened.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
      }
    });
    await tester.pumpAndSettle();
    expect(platform.opened, hasLength(1));
    expect(File(platform.opened.single).lengthSync(), bytes.length);
  });

  testWidgets('un hash distinto muestra el error y no instala', (tester) async {
    await tester.runAsync(() async {
      await pump(tester, apk: List<int>.of(bytes)..[5] = 255);
      await tester.tap(find.text('Actualizar'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.text('Reintentar').evaluate().isNotEmpty) break;
      }
    });
    expect(find.textContaining('no coincide'), findsOneWidget);
    expect(platform.opened, isEmpty);
    expect(platform.dir.listSync(), isEmpty);
  });

  testWidgets('sin permiso de instalar guia al ajuste', (tester) async {
    platform.canInstall = false;
    await pump(tester);
    await tester.tap(find.text('Actualizar'));
    await tester.pumpAndSettle();
    expect(find.text('Abrir ajustes'), findsOneWidget);
    expect(platform.opened, isEmpty);
  });
}
