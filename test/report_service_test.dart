import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mornye/services/analytics/install_id.dart';
import 'package:mornye/services/diagnostics/report_client.dart';
import 'package:mornye/services/diagnostics/report_device_info.dart';
import 'package:mornye/services/diagnostics/report_image_codec.dart';
import 'package:mornye/services/diagnostics/report_models.dart';
import 'package:mornye/services/diagnostics/report_queue.dart';
import 'package:mornye/services/diagnostics/report_rate_limiter.dart';
import 'package:mornye/services/diagnostics/report_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

const _device = ReportDeviceInfo(
  model: 'Google Pixel 8',
  systemRelease: '14',
  sdk: 34,
  abi: 'arm64-v8a',
  appVersion: '5.3.1+2228',
  locale: 'es',
);

void main() {
  late Directory temp;
  late List<http.Request> requests;
  late List<Duration> delays;
  late DateTime clock;
  late List<http.Response Function(http.Request)> script;
  var queueRoot = '';

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('musa_report_service');
    queueRoot = p.join(temp.path, 'queue');
    requests = [];
    delays = [];
    script = [];
    clock = DateTime.utc(2026, 11, 18, 12);
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      return;
    }
  });

  ReportService service({String log = '', List<File>? shared}) {
    final client = MockClient((request) async {
      requests.add(request);
      final next = script.isEmpty ? null : script.removeAt(0);
      if (next == null) return http.Response('{"error":"x"}', 500);
      return next(request);
    });
    return ReportService(
      client: ReportClient(client: client),
      queue: ReportQueue(root: () async => Directory(queueRoot)),
      limiter: ReportRateLimiter(now: () => clock),
      installId: InstallId(),
      logSource: () async => log,
      deviceInfo: (_) async => _device,
      delay: (d) async => delays.add(d),
      share: (file, _) async => shared?.add(file),
      workDirectory: () async => temp,
      now: () => clock,
    );
  }

  http.Response created([int id = 7]) => http.Response(
    jsonEncode({'ok': true, 'id': id, 'ref': 'FB-$id', 'images': 0}),
    201,
    headers: {'content-type': 'application/json'},
  );

  final jpeg = Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3, 4]);

  ReportDraft draft({
    String text = 'Se cierra al abrir',
    String contact = '',
    bool log = false,
    bool device = false,
    List<ReportImage> images = const [],
  }) => ReportDraft(
    kind: ReportKind.error,
    text: text,
    contact: contact,
    includeLog: log,
    includeDevice: device,
    images: images,
  );

  group('request', () {
    test('sends the exact JSON to /v1/feedback', () async {
      script.add((_) => created(12));
      final s = service(
        log: 'linea 1\nAuthorization: Bearer FAKETOKEN123\nlinea 3',
      );
      final package = await s.build(
        draft(
          text: '  Se cierra al abrir  ',
          contact: ' yo@example.com ',
          log: true,
          device: true,
          images: [ReportImage(jpeg)],
        ),
        locale: 'es',
      );
      final outcome = await s.submit(package);

      expect(outcome, isA<ReportSent>());
      expect((outcome as ReportSent).ref, 'FB-12');
      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(
        request.url.toString(),
        'https://musa-api.heyshin.app/v1/feedback',
      );
      expect(request.headers['content-type'], startsWith('application/json'));
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      final id = body['id'] as String;
      expect(id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(body, {
        'id': id,
        'kind': 'error',
        'text': 'Se cierra al abrir',
        'contact': 'yo@example.com',
        'version': '5.3.1+2228',
        'os': 14,
        'log':
            'MUSA: 5.3.1+2228\nDispositivo: Google Pixel 8\n'
            'Android: 14 (API 34)\nABI: arm64-v8a\nIdioma: es\n\n'
            'linea 1\nAuthorization: [redactado]\nlinea 3',
        'images': [
          {'mime': 'image/jpeg', 'data': base64Encode(jpeg)},
        ],
      });
      expect(request.body, isNot(contains('FAKETOKEN123')));
    });

    test('optional parts are left out and the install id is stable', () async {
      script
        ..add((_) => created(1))
        ..add((_) => created(2));
      final s = service();
      await s.submit(await s.build(draft(), locale: 'es'));
      await s.submit(await s.build(draft(), locale: 'es'));
      final first = jsonDecode(requests[0].body) as Map<String, dynamic>;
      final second = jsonDecode(requests[1].body) as Map<String, dynamic>;
      expect(first.keys.toSet(), {'id', 'kind', 'text', 'version', 'os'});
      expect(first['id'], second['id']);
    });

    test('the preview text is the text that is sent', () async {
      script.add((_) => created());
      final s = service(log: 'token=ABCDEF\nok');
      final package = await s.build(draft(log: true), locale: 'es');
      expect(package.logField, 'token=[redactado]\nok');
      await s.submit(package);
      expect(
        (jsonDecode(requests.single.body) as Map)['log'],
        package.logField,
      );
    });

    test(
      'the log respects the 20 KB limit together with device data',
      () async {
        final big = [
          for (var i = 0; i < 400; i++) 'fila $i ${'dato ' * 20}',
        ].join('\n');
        final s = service(log: big);
        final package = await s.build(
          draft(log: true, device: true),
          locale: 'es',
        );
        expect(
          utf8.encode(package.logField).length,
          lessThanOrEqualTo(20 * 1024),
        );
        expect(package.logField, startsWith('MUSA: '));
        expect(package.logField, contains('fila 399'));
      },
    );

    test('keeps at most three images and the documented limits', () async {
      final s = service();
      final package = await s.build(
        draft(
          text: 'x' * 3000,
          contact: 'c' * 300,
          images: [for (var i = 0; i < 5; i++) ReportImage(jpeg)],
        ),
        locale: 'es',
      );
      expect(package.images, hasLength(3));
      expect(package.text.length, 2000);
      expect(package.contact.length, 120);
    });
  });

  group('delivery', () {
    test('retries network failures and then succeeds', () async {
      script
        ..add((_) => throw const SocketException('down'))
        ..add((_) => http.Response('', 503))
        ..add((_) => created(5));
      final s = service();
      final outcome = await s.submit(await s.build(draft(), locale: 'es'));
      expect(outcome, isA<ReportSent>());
      expect(requests, hasLength(3));
      expect(delays, [const Duration(seconds: 1), const Duration(seconds: 3)]);
      expect(await s.pendingCount(), 0);
    });

    test(
      'queues the report when every attempt fails and flushes it later',
      () async {
        script
          ..add((_) => throw const SocketException('down'))
          ..add((_) => throw const SocketException('down'))
          ..add((_) => throw const SocketException('down'));
        final s = service();
        final outcome = await s.submit(await s.build(draft(), locale: 'es'));
        expect(outcome, isA<ReportQueued>());
        expect(requests, hasLength(3));
        expect(await s.pendingCount(), 1);

        script.add((_) => created(9));
        expect(await s.flushPending(), 1);
        expect(await s.pendingCount(), 0);
        final retried = jsonDecode(requests.last.body) as Map;
        expect(retried['text'], 'Se cierra al abrir');
      },
    );

    test(
      'a failed flush keeps the queue; a rejected one drops the item',
      () async {
        script.addAll([
          (_) => throw const SocketException('down'),
          (_) => throw const SocketException('down'),
          (_) => throw const SocketException('down'),
        ]);
        final s = service();
        await s.submit(await s.build(draft(), locale: 'es'));
        script.add((_) => throw const SocketException('still down'));
        expect(await s.flushPending(), 0);
        expect(await s.pendingCount(), 1);
        script.add((_) => http.Response('{"error":"bad_text"}', 400));
        expect(await s.flushPending(), 0);
        expect(await s.pendingCount(), 0);
      },
    );

    test('server limits are reported without queueing', () async {
      script.add((_) => http.Response('{"error":"rate_limited"}', 429));
      var s = service();
      expect(
        await s.submit(await s.build(draft(), locale: 'es')),
        isA<ReportRateLimited>(),
      );
      script.add((_) => http.Response('{"error":"bad_images"}', 400));
      s = service();
      final rejected = await s.submit(await s.build(draft(), locale: 'es'));
      expect(rejected, isA<ReportRejected>());
      expect((rejected as ReportRejected).status, 400);
      expect(await s.pendingCount(), 0);
    });

    test('local limit of 5 reports per hour', () async {
      script.addAll([for (var i = 0; i < 6; i++) (_) => created(i + 1)]);
      final s = service();
      for (var i = 0; i < 5; i++) {
        expect(
          await s.submit(await s.build(draft(), locale: 'es')),
          isA<ReportSent>(),
        );
      }
      expect(
        await s.submit(await s.build(draft(), locale: 'es')),
        isA<ReportRateLimited>(),
      );
      expect(requests, hasLength(5));
      clock = clock.add(const Duration(hours: 1, minutes: 1));
      expect(
        await s.submit(await s.build(draft(), locale: 'es')),
        isA<ReportSent>(),
      );
    });
  });

  group('share as a file', () {
    test(
      'writes a zip with the text, redacted log, device and screenshots',
      () async {
        final shared = <File>[];
        final s = service(
          log: 'error en /home/alex/x.txt\ncookie: sid=FAKE',
          shared: shared,
        );
        final package = await s.build(
          draft(
            contact: 'yo@example.com',
            log: true,
            device: true,
            images: [ReportImage(jpeg), ReportImage(jpeg)],
          ),
          locale: 'es',
        );
        final file = await s.shareAsFile(package);

        expect(shared, [file]);
        expect(p.extension(file.path), '.zip');
        final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
        expect(archive.files.map((f) => f.name).toSet(), {
          'informe.md',
          'dispositivo.txt',
          'registro.txt',
          'capturas/captura-1.jpg',
          'capturas/captura-2.jpg',
        });
        String read(String name) => utf8.decode(
          archive.files.firstWhere((f) => f.name == name).content,
        );
        expect(read('informe.md'), contains('Se cierra al abrir'));
        expect(read('informe.md'), contains('yo@example.com'));
        expect(
          read('registro.txt'),
          'error en /home/[usuario]/x.txt\ncookie: [redactado]',
        );
        expect(read('dispositivo.txt'), contains('Google Pixel 8'));
        expect(
          Uint8List.fromList(
            archive.files
                .firstWhere((f) => f.name == 'capturas/captura-1.jpg')
                .content,
          ),
          jpeg,
        );
        expect(requests, isEmpty);
      },
    );

    test('without optional parts the zip only has the summary', () async {
      final s = service();
      final package = await s.build(draft(), locale: 'es');
      final archive = ZipDecoder().decodeBytes(s.buildZip(package));
      expect(archive.files.map((f) => f.name), ['informe.md']);
    });
  });

  group('device info', () {
    test('only model, Android, ABI, app version and language', () {
      expect(
        _device.toText(),
        'MUSA: 5.3.1+2228\nDispositivo: Google Pixel 8\n'
        'Android: 14 (API 34)\nABI: arm64-v8a\nIdioma: es',
      );
      expect(_device.osMajor, 14);
    });

    test('osMajor falls back to the API level and stays in 1-99', () {
      expect(
        const ReportDeviceInfo(
          model: 'x',
          systemRelease: 'S',
          sdk: 31,
          abi: 'a',
          appVersion: '1',
          locale: 'es',
        ).osMajor,
        31,
      );
      expect(
        const ReportDeviceInfo(
          model: 'x',
          systemRelease: 'S',
          sdk: 0,
          abi: 'a',
          appVersion: '1',
          locale: 'es',
        ).osMajor,
        1,
      );
    });
  });

  group('image codec', () {
    Uint8List noisy(int width, int height, {bool alpha = false}) {
      final image = img.Image(
        width: width,
        height: height,
        numChannels: alpha ? 4 : 3,
      );
      var seed = 7;
      for (final pixel in image) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        pixel
          ..r = seed & 255
          ..g = (seed >> 8) & 255
          ..b = (seed >> 16) & 255;
        if (alpha) pixel.a = 128;
      }
      return Uint8List.fromList(img.encodePng(image));
    }

    test('shrinks a large picture to a JPEG of at most 1 MB and 1600 px', () {
      final out = ReportImageCodec.compressSync(noisy(2400, 1800))!;
      expect(out.length, lessThanOrEqualTo(1024 * 1024));
      expect(out.sublist(0, 3), [0xff, 0xd8, 0xff]);
      final decoded = img.decodeJpg(out)!;
      expect(decoded.width, lessThanOrEqualTo(1600));
      expect(decoded.height, lessThanOrEqualTo(1600));
      expect(decoded.exif.isEmpty, isTrue);
    });

    test('accepts transparent PNGs and rejects non images', () {
      expect(
        ReportImageCodec.compressSync(noisy(300, 200, alpha: true)),
        isNotNull,
      );
      expect(
        ReportImageCodec.compressSync(Uint8List.fromList([1, 2, 3])),
        isNull,
      );
    });
  });

  test('install id is random, persistent and well formed', () async {
    final a = await InstallId().read();
    final b = await InstallId().read();
    expect(a, b);
    expect(
      a,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    SharedPreferences.setMockInitialValues({});
    expect(await InstallId().read(), isNot(a));
  });

  test('the client rejects unusable 2xx bodies as server errors', () async {
    final client = ReportClient(
      client: MockClient((_) async => http.Response('nope', 201)),
    );
    await expectLater(
      client.send({'a': 1}),
      throwsA(
        isA<ReportException>().having(
          (e) => e.failure,
          'failure',
          ReportFailure.server,
        ),
      ),
    );
  });

  test('timeouts are reported as such', () async {
    final client = ReportClient(
      client: MockClient((_) => Completer<http.Response>().future),
      timeout: const Duration(milliseconds: 20),
    );
    await expectLater(
      client.send({'a': 1}),
      throwsA(
        isA<ReportException>().having(
          (e) => e.failure,
          'failure',
          ReportFailure.timeout,
        ),
      ),
    );
  });
}
