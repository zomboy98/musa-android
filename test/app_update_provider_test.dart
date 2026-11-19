import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/providers/app_update_provider.dart';
import 'package:mornye/services/app_update_notification.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Platform implements AppUpdatePlatform {
  int? build = 2232;
  @override
  bool get isAndroid => true;
  @override
  Future<int?> installedBuild() async => build;
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

String _manifest(int build) => jsonEncode({
  'etiqueta': '0.9 beta ${build - 2230}',
  'version': '5.3.1',
  'build': build,
  'canal': 'beta',
  'notes': 'Notas de la version',
  'apk_url':
      'https://github.com/zomboy98/musa-android/releases/download/v1/musa.apk',
  'sha256': 'a' * 64,
  'size_bytes': 1000,
  'published_at': '2026-11-20',
});

void main() {
  late _Platform platform;
  late DateTime clock;
  late int requests;
  late int publishedBuild;
  late bool offline;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = _Platform();
    clock = DateTime(2026, 11, 20, 10);
    requests = 0;
    publishedBuild = 2233;
    offline = false;
  });

  ProviderContainer container() {
    final service = AppUpdateService(
      platform: platform,
      now: () => clock,
      client: MockClient((request) async {
        requests++;
        if (offline) throw const SocketException('sin red');
        return http.Response(_manifest(publishedBuild), 200);
      }),
    );
    final c = ProviderContainer(
      overrides: [
        appUpdateServiceProvider.overrideWithValue(service),
        appUpdateClockProvider.overrideWithValue(() => clock),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 20));

  test('la oferta sigue disponible tras ocultar el aviso y se restaura', () async {
    final first = container();
    final notifier = first.read(appUpdateProvider.notifier);
    expect(await notifier.checkNow(), isTrue);
    expect(first.read(appUpdateProvider).stage, AppUpdateStage.available);

    notifier.dismissBanner();
    await notifier.markOfferSeen();
    clock = clock.add(const Duration(days: 3));
    final state = first.read(appUpdateProvider);
    expect(state.hasOffer, isTrue);
    expect(state.showBanner, isFalse);
    expect(state.stage, AppUpdateStage.available);

    await settle();
    final second = container();
    await second.read(appUpdateProvider.notifier).ready;
    final restored = second.read(appUpdateProvider);
    expect(restored.hasOffer, isTrue);
    expect(restored.offer!.build, 2233);
    expect(restored.offer!.label, 'v0.9 beta 3');
    expect(restored.checkedAt, DateTime(2026, 11, 20, 10));
    expect(restored.showBanner, isTrue);
    expect(restored.stage, AppUpdateStage.available);
    expect(requests, 1);
  });

  test('la oferta desaparece cuando lo instalado la alcanza', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    expect(c.read(appUpdateProvider).hasOffer, isTrue);

    platform.build = 2233;
    await notifier.refreshInstalledBuild();
    expect(c.read(appUpdateProvider).hasOffer, isFalse);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.upToDate);

    platform.build = 2232;
    await notifier.refreshInstalledBuild();
    expect(c.read(appUpdateProvider).hasOffer, isTrue);
  });

  test('una compilacion publicada que ya no es mayor limpia la oferta', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    publishedBuild = 2232;
    await notifier.checkNow();
    expect(c.read(appUpdateProvider).offer, isNull);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.upToDate);
  });

  test('al reanudar solo consulta pasados 30 minutos', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkOnResume();
    expect(requests, 1);

    clock = clock.add(const Duration(minutes: 29));
    await notifier.checkOnResume();
    expect(requests, 1);

    clock = clock.add(const Duration(minutes: 2));
    await notifier.checkOnResume();
    expect(requests, 2);
  });

  test('las consultas automaticas dejan 15 minutos y la manual siempre consulta', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkAutomatically();
    clock = clock.add(const Duration(minutes: 10));
    await notifier.checkAutomatically();
    expect(requests, 1);

    await notifier.checkNow();
    expect(requests, 2);

    clock = clock.add(const Duration(minutes: 16));
    await notifier.checkAutomatically();
    expect(requests, 3);
  });

  test('un error de red conserva la ultima oferta y su fecha', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    final checkedAt = c.read(appUpdateProvider).checkedAt;

    offline = true;
    clock = clock.add(const Duration(hours: 2));
    expect(await notifier.checkNow(), isFalse);
    final state = c.read(appUpdateProvider);
    expect(state.checkFailed, isTrue);
    expect(state.hasOffer, isTrue);
    expect(state.stage, AppUpdateStage.available);
    expect(state.checkedAt, checkedAt);

    offline = false;
    await notifier.checkNow();
    expect(c.read(appUpdateProvider).checkFailed, isFalse);
  });

  test('sin red y sin oferta previa el estado es error, no una oferta', () async {
    offline = true;
    final c = container();
    await c.read(appUpdateProvider.notifier).checkNow();
    final state = c.read(appUpdateProvider);
    expect(state.stage, AppUpdateStage.error);
    expect(state.hasOffer, isFalse);
  });

  test('el aviso del sistema se dispara una sola vez por compilacion', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    expect(await notifier.claimNotification(), isTrue);
    expect(await notifier.claimNotification(), isFalse);

    await settle();
    final restarted = container();
    final again = restarted.read(appUpdateProvider.notifier);
    await again.ready;
    expect(await again.claimNotification(), isFalse);

    publishedBuild = 2234;
    await again.checkNow();
    expect(await again.claimNotification(), isTrue);
    expect(await again.claimNotification(), isFalse);
  });

  test('el cuadro de arranque se anuncia solo la primera vez por compilacion', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    expect(notifier.startupDialogPending, isTrue);
    await notifier.markOfferSeen();
    expect(notifier.startupDialogPending, isFalse);
    expect(c.read(appUpdateProvider).hasOffer, isTrue);
  });

  test('el progreso de descarga pasa por los estados y vuelve a disponible', () async {
    final c = container();
    final notifier = c.read(appUpdateProvider.notifier);
    await notifier.checkNow();
    notifier.reportFlow(AppUpdateStage.downloading, 0.5);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.downloading);
    expect(c.read(appUpdateProvider).progress, 0.5);
    expect(await notifier.checkNow(), isFalse);
    notifier.reportFlow(AppUpdateStage.installing, null);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.installing);
    notifier.reportFlow(AppUpdateStage.available, null);
    expect(c.read(appUpdateProvider).stage, AppUpdateStage.available);
  });

  test('un toque en el aviso espera al manejador y se entrega una vez', () {
    final router = AppUpdateNotificationRouter();
    var opened = 0;
    router.receive('otro');
    router.receive(AppUpdateNotificationRouter.payload);
    router.setHandler(() => opened++);
    expect(opened, 1);
    router.setHandler(() => opened++);
    expect(opened, 1);
    router.receive(AppUpdateNotificationRouter.payload);
    expect(opened, 2);
  });
}
