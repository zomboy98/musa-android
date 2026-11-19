import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/app_update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakePlatform implements AppUpdatePlatform {
  _FakePlatform(this.dir);

  final Directory dir;
  int? build = 2232;
  int? free;
  bool canInstall = true;
  bool installerOk = true;
  final opened = <String>[];

  @override
  bool get isAndroid => true;
  @override
  Future<int?> installedBuild() async => build;
  @override
  Future<bool> canInstallPackages() async => canInstall;
  @override
  Future<void> openInstallPermissionSettings() async {}
  @override
  Future<int?> freeBytes(String path) async => free;
  @override
  Future<Directory> updateDirectory() async => dir;
  @override
  Future<bool> openInstaller(String path) async {
    opened.add(path);
    return installerOk;
  }
}

final _apkBytes = List<int>.generate(1000, (i) => i % 251);
final _apkSha = sha256.convert(_apkBytes).toString();
const _apkUrl =
    'https://github.com/zomboy98/musa-android/releases/download/v0.9.0-beta.3/musa.apk';

Map<String, Object?> _manifest({
  Object? build = 2233,
  Object? sha = 'x',
  Object? size = 1000,
  Object? apk = _apkUrl,
  Object? etiqueta = '0.9 beta 3',
}) => {
  'etiqueta': etiqueta,
  'version': '5.3.1',
  'build': build,
  'canal': 'beta',
  'notes': 'Notas de la version',
  'apk_url': apk,
  'sha256': sha == 'x' ? _apkSha : sha,
  'size_bytes': size,
  'published_at': '2026-11-20',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late _FakePlatform platform;
  var manifestRequests = 0;
  final requestedHeaders = <Map<String, String>>[];

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    tmp = Directory.systemTemp.createTempSync('musa_update_test');
    platform = _FakePlatform(Directory('${tmp.path}/updates'));
    manifestRequests = 0;
    requestedHeaders.clear();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  AppUpdateService service({
    Object? manifest,
    String? body,
    List<int>? apk,
    FileHasher? hasher,
    int manifestStatus = 200,
    DateTime Function()? now,
  }) {
    return AppUpdateService(
      platform: platform,
      now: now,
      hashFile:
          hasher ??
          (path) async =>
              sha256.convert(await File(path).readAsBytes()).toString(),
      client: MockClient.streaming((request, _) async {
        if (request.url.path.endsWith('latest.json')) {
          manifestRequests++;
          requestedHeaders.add(request.headers);
          final bytes = utf8.encode(
            body ?? jsonEncode(manifest ?? _manifest()),
          );
          return http.StreamedResponse(
            Stream.value(bytes),
            manifestStatus,
            contentLength: bytes.length,
          );
        }
        final data = apk ?? _apkBytes;
        return http.StreamedResponse(
          Stream.fromIterable([
            data.sublist(0, data.length ~/ 2),
            data.sublist(data.length ~/ 2),
          ]),
          200,
          contentLength: data.length,
        );
      }),
    );
  }

  group('comparacion por numero de compilacion', () {
    test('ofrece una compilacion mayor con su etiqueta publica', () async {
      final check = await service().checkForUpdate();
      expect(check.status, AppUpdateStatus.available);
      expect(check.offer!.label, 'v0.9 beta 3');
      expect(check.offer!.build, 2233);
    });

    test('no ofrece la misma compilacion ni una menor', () async {
      for (final build in [2232, 2200]) {
        final check = await service(
          manifest: _manifest(build: build),
        ).checkForUpdate();
        expect(check.status, AppUpdateStatus.upToDate, reason: '$build');
      }
    });

    test('no consulta nada fuera de Android', () async {
      final unsupported = AppUpdateService(
        platform: _NotAndroid(platform),
        client: MockClient((_) async => fail('no debe consultar')),
      );
      expect(
        (await unsupported.checkForUpdate()).status,
        AppUpdateStatus.unavailable,
      );
    });

    test('la consulta solo envia un GET sin datos personales', () async {
      await service().checkForUpdate();
      expect(manifestRequests, 1);
      expect(
        requestedHeaders.single.keys.map((k) => k.toLowerCase()),
        everyElement(anyOf('accept', 'content-length')),
      );
    });

    test('un error del servidor se ignora', () async {
      final check = await service(manifestStatus: 500).checkForUpdate();
      expect(check.status, AppUpdateStatus.unavailable);
    });
  });

  group('validacion estricta', () {
    final invalid = <String, Object?>{
      'JSON invalido': 'no es json',
      'sin build': {..._manifest()}..remove('build'),
      'build como texto': _manifest(build: '2233'),
      'sha256 corto': _manifest(sha: 'abc123'),
      'sha256 no hexadecimal': _manifest(sha: 'z' * 64),
      'apk http': _manifest(apk: _apkUrl.replaceFirst('https', 'http')),
      'apk en otro host': _manifest(apk: 'https://evil.example.com/musa.apk'),
      'apk en otro repositorio': _manifest(
        apk:
            'https://github.com/mornyeapp/Mornye/releases/download/v1/musa.apk',
      ),
      'host con prefijo engañoso': _manifest(
        apk: 'https://github.com.evil.example/zomboy98/musa-android/a.apk',
      ),
      'tamano ausente': _manifest(size: null),
      'etiqueta vacia': _manifest(etiqueta: ' '),
      'lista en vez de objeto': <Object?>[],
    };
    for (final entry in invalid.entries) {
      test('ignora ${entry.key}', () async {
        final body = entry.value is String
            ? entry.value as String
            : jsonEncode(entry.value);
        final check = await service(body: body).checkForUpdate();
        expect(check.status, AppUpdateStatus.unavailable);
        expect(check.offer, isNull);
      });
    }

    test('el manifiesto solo se pide a musa.heyshin.app', () async {
      final other = AppUpdateService(
        platform: platform,
        manifestUrl: Uri.parse('https://evil.example.com/latest.json'),
        client: MockClient((_) async => fail('no debe consultar')),
      );
      expect(
        (await other.checkForUpdate()).status,
        AppUpdateStatus.unavailable,
      );
    });

    test('acepta el APK en musa.heyshin.app', () {
      expect(
        parseAppUpdateManifest(
          jsonEncode(
            _manifest(apk: 'https://musa.heyshin.app/descargas/musa.apk'),
          ),
        ),
        isNotNull,
      );
    });
  });

  group('ahora no', () {
    test('se recuerda 24 horas para esa compilacion', () async {
      var clock = DateTime(2026, 11, 20, 10);
      final s = service(now: () => clock);
      await s.snooze(2233);
      expect((await s.checkForUpdate()).status, AppUpdateStatus.snoozed);
      expect(
        (await s.checkForUpdate(ignoreSnooze: true)).status,
        AppUpdateStatus.available,
      );
      clock = clock.add(const Duration(hours: 25));
      expect((await s.checkForUpdate()).status, AppUpdateStatus.available);
    });

    test('una compilacion nueva no hereda el aplazamiento', () async {
      final s = service(now: () => DateTime(2026, 11, 20));
      await s.snooze(2233);
      final next = service(
        manifest: _manifest(build: 2234),
        now: () => DateTime(2026, 11, 20),
      );
      expect((await next.checkForUpdate()).status, AppUpdateStatus.available);
    });
  });

  group('descarga', () {
    Future<AppUpdateOffer> offer(AppUpdateService s) async =>
        (await s.checkForUpdate()).offer!;

    test('con hash y tamaño correctos avanza a instalar', () async {
      final s = service();
      final progress = <int>[];
      final file = await s.download(
        await offer(s),
        onProgress: (received, total) => progress.add(received),
      );
      expect(await file.readAsBytes(), _apkBytes);
      expect(progress.last, 1000);
      await s.install(file);
      expect(platform.opened, [file.path]);
    });

    test('con hash incorrecto borra el archivo y falla sin instalar', () async {
      final tampered = List<int>.of(_apkBytes)..[10] = 0;
      final s = service(apk: tampered);
      final o = await offer(s);
      await expectLater(
        s.download(o),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.hashMismatch,
          ),
        ),
      );
      expect(platform.dir.listSync(), isEmpty);
      expect(platform.opened, isEmpty);
    });

    test('con tamaño distinto falla como descarga cortada', () async {
      final s = service(apk: _apkBytes.sublist(0, 600));
      final o = await offer(s);
      await expectLater(
        s.download(o),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.incomplete,
          ),
        ),
      );
      expect(platform.dir.listSync(), isEmpty);
    });

    test('con mas bytes de los anunciados falla', () async {
      final s = service(apk: [..._apkBytes, 1, 2, 3]);
      final o = await offer(s);
      await expectLater(
        s.download(o),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.incomplete,
          ),
        ),
      );
    });

    test('sin espacio suficiente no descarga', () async {
      platform.free = 10;
      final s = service();
      final o = await offer(s);
      await expectLater(
        s.download(o),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.insufficientSpace,
          ),
        ),
      );
    });

    test('cancelar detiene la descarga y limpia', () async {
      final s = service();
      final o = await offer(s);
      final token = AppUpdateCancelToken();
      await expectLater(
        s.download(
          o,
          cancel: token,
          onProgress: (received, _) {
            if (received > 0) token.cancel();
          },
        ),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.cancelled,
          ),
        ),
      );
      expect(platform.dir.listSync(), isEmpty);
    });

    test('sin red falla con error de red', () async {
      final s = AppUpdateService(
        platform: platform,
        client: MockClient((_) async => throw const SocketException('sin red')),
      );
      final o = parseAppUpdateManifest(jsonEncode(_manifest()))!;
      await expectLater(
        s.download(o),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.network,
          ),
        ),
      );
    });

    test('sin permiso de instalar no abre el instalador', () async {
      platform.canInstall = false;
      final s = service();
      final file = await s.download(await offer(s));
      await expectLater(
        s.install(file),
        throwsA(
          isA<AppUpdateException>().having(
            (e) => e.failure,
            'failure',
            AppUpdateFailure.permissionRequired,
          ),
        ),
      );
      expect(platform.opened, isEmpty);
    });
  });
}

class _NotAndroid implements AppUpdatePlatform {
  _NotAndroid(this.inner);
  final AppUpdatePlatform inner;
  @override
  bool get isAndroid => false;
  @override
  Future<int?> installedBuild() => inner.installedBuild();
  @override
  Future<bool> canInstallPackages() => inner.canInstallPackages();
  @override
  Future<void> openInstallPermissionSettings() =>
      inner.openInstallPermissionSettings();
  @override
  Future<int?> freeBytes(String path) => inner.freeBytes(path);
  @override
  Future<Directory> updateDirectory() => inner.updateDirectory();
  @override
  Future<bool> openInstaller(String path) => inner.openInstaller(path);
}
