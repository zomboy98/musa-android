import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/screens/report/report_page.dart';
import 'package:mornye/services/analytics/install_id.dart';
import 'package:mornye/services/diagnostics/report_client.dart';
import 'package:mornye/services/diagnostics/report_device_info.dart';
import 'package:mornye/services/diagnostics/report_models.dart';
import 'package:mornye/services/diagnostics/report_queue.dart';
import 'package:mornye/services/diagnostics/report_rate_limiter.dart';
import 'package:mornye/services/diagnostics/report_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = ReportDeviceInfo(
  model: 'Google Pixel 8',
  systemRelease: '14',
  sdk: 34,
  abi: 'arm64-v8a',
  appVersion: '5.3.1+2228',
  locale: 'es',
);

final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 9, 9, 9]);
final _jpeg = Uint8List.fromList(img.encodeJpg(img.Image(width: 2, height: 2)));

void main() {
  late List<http.Request> requests;
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    temp = await Directory.systemTemp.createTemp('musa_report_page');
  });

  tearDown(() async {
    try {
      await temp.delete(recursive: true);
    } on FileSystemException {
      return;
    }
  });

  ReportService service({String log = 'token=ABC123\nlinea ok'}) {
    final client = MockClient((request) async {
      requests.add(request);
      return http.Response(
        jsonEncode({'ok': true, 'id': 9, 'ref': 'FB-9', 'images': 0}),
        201,
      );
    });
    return ReportService(
      client: ReportClient(client: client),
      queue: ReportQueue(root: () async => Directory('${temp.path}/q')),
      limiter: ReportRateLimiter(),
      installId: InstallId(),
      logSource: () async => log,
      deviceInfo: (_) async => _device,
      delay: (_) async {},
      workDirectory: () async => temp,
    );
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 120)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> show(
    WidgetTester tester, {
    ReportService? svc,
    ReportKind kind = ReportKind.error,
    ReportGalleryPicker? pick,
    ReportScreenCapture? capture,
    Future<Uint8List?>? previous,
  }) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ReportPage(
          service: svc ?? service(),
          initialKind: kind,
          pickImages: pick ?? () async => [_png],
          captureScreen: capture ?? () async => _png,
          compressImage: (_) async => _jpeg,
          previousScreen: previous,
        ),
      ),
    );
    await settle(tester);
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(ValueKey(key)), text);
    await tester.pump();
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  bool isOn(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(ValueKey(key))).value;

  testWidgets('the error log switch is on for errors and follows the type', (
    tester,
  ) async {
    await show(tester);
    expect(isOn(tester, 'report-attach-log'), isTrue);
    expect(isOn(tester, 'report-attach-device'), isFalse);

    await tap(tester, 'report-kind-idea');
    expect(isOn(tester, 'report-attach-log'), isFalse);
    await tap(tester, 'report-kind-error');
    expect(isOn(tester, 'report-attach-log'), isTrue);

    await tap(tester, 'report-attach-log');
    expect(isOn(tester, 'report-attach-log'), isFalse);
    await tap(tester, 'report-kind-idea');
    await tap(tester, 'report-kind-error');
    expect(isOn(tester, 'report-attach-log'), isFalse);
  });

  testWidgets('starting as idea leaves the log off', (tester) async {
    await show(tester, kind: ReportKind.idea);
    expect(isOn(tester, 'report-attach-log'), isFalse);
  });

  testWidgets('description is required and nothing is sent without it', (
    tester,
  ) async {
    await show(tester);
    await tap(tester, 'report-consent');
    await tap(tester, 'report-send');
    expect(find.text('Escribe una descripción.'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('explicit consent is required before sending', (tester) async {
    await show(tester);
    await type(tester, 'report-text', 'Se cierra al abrir');
    expect(find.byKey(const ValueKey('report-consent-text')), findsOneWidget);
    expect(find.textContaining('musa-api.heyshin.app'), findsWidgets);
    await tap(tester, 'report-send');
    expect(find.byKey(const ValueKey('report-consent-error')), findsOneWidget);
    expect(requests, isEmpty);

    await tap(tester, 'report-consent');
    expect(find.byKey(const ValueKey('report-consent-error')), findsNothing);
    await tap(tester, 'report-send');
    expect(requests, hasLength(1));
  });

  testWidgets('limits: 2000 characters of text and 120 of contact', (
    tester,
  ) async {
    await show(tester);
    await type(tester, 'report-text', 'a' * 2500);
    await type(tester, 'report-contact', 'c' * 200);
    final text = tester.widget<TextField>(
      find.byKey(const ValueKey('report-text')),
    );
    final contact = tester.widget<TextField>(
      find.byKey(const ValueKey('report-contact')),
    );
    expect(text.controller!.text.length, 2000);
    expect(contact.controller!.text.length, 120);
    expect(find.textContaining('Solo se usa para responderte'), findsOneWidget);
  });

  testWidgets('sending shows the reference and clears the form', (
    tester,
  ) async {
    await show(tester);
    await type(tester, 'report-text', 'Se cierra al abrir');
    await type(tester, 'report-contact', 'yo@example.com');
    await tap(tester, 'report-attach-device');
    await tap(tester, 'report-capture');
    expect(find.byKey(const ValueKey('report-thumb-0')), findsOneWidget);
    await tap(tester, 'report-consent');
    await tap(tester, 'report-send');

    expect(requests, hasLength(1));
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body['kind'], 'error');
    expect(body['text'], 'Se cierra al abrir');
    expect(body['contact'], 'yo@example.com');
    expect(body['os'], 14);
    expect(
      body['log'],
      'MUSA: 5.3.1+2228\nDispositivo: Google Pixel 8\nAndroid: 14 (API 34)\n'
      'ABI: arm64-v8a\nIdioma: es\n\ntoken=[redactado]\nlinea ok',
    );
    expect(body['images'], [
      {'mime': 'image/jpeg', 'data': base64Encode(_jpeg)},
    ]);
    expect(find.byKey(const ValueKey('report-sent-body')), findsOneWidget);
    expect(find.textContaining('FB-9'), findsOneWidget);

    await tester.tap(find.text('Listo'));
    await settle(tester);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('report-text')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.byKey(const ValueKey('report-thumb-0')), findsNothing);
  });

  testWidgets('at most three screenshots and they can be removed', (
    tester,
  ) async {
    await show(
      tester,
      pick: () async => [_png, _png, _png, _png, _png],
      previous: Future.value(_png),
    );
    await tap(tester, 'report-gallery');
    expect(find.byKey(const ValueKey('report-thumb-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-thumb-1')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-thumb-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('report-thumb-3')), findsNothing);
    expect(find.text('Máximo 3 capturas.'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('report-capture')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('report-gallery')))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const ValueKey('report-thumb-remove')).first);
    await settle(tester);
    expect(find.byKey(const ValueKey('report-thumb-2')), findsNothing);
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const ValueKey('report-capture')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a picture that cannot be used shows a message', (tester) async {
    tester.view.physicalSize = const Size(800, 3600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ReportPage(
          service: service(),
          pickImages: () async => [_png],
          compressImage: (_) async => null,
        ),
      ),
    );
    await settle(tester);
    await tap(tester, 'report-gallery');
    expect(find.text('No se pudo usar esa imagen.'), findsOneWidget);
    expect(find.byKey(const ValueKey('report-thumb-0')), findsNothing);
  });

  testWidgets('"Ver qué se envía" shows the redacted text that will be sent', (
    tester,
  ) async {
    await show(tester);
    await type(tester, 'report-text', 'Fallo de reproducción');
    await tap(tester, 'report-attach-device');
    await tap(tester, 'report-preview');
    final log = tester.widget<SelectableText>(
      find.byKey(const ValueKey('report-preview-log')),
    );
    final shown = log.data!;
    expect(shown, contains('token=[redactado]'));
    expect(shown, isNot(contains('ABC123')));
    expect(shown, contains('Google Pixel 8'));
    expect(
      tester
          .widget<SelectableText>(
            find.byKey(const ValueKey('report-preview-text')),
          )
          .data,
      contains('Fallo de reproducción'),
    );
    expect(requests, isEmpty);

    await tester.tap(find.text('Cerrar'));
    await settle(tester);
    await tap(tester, 'report-consent');
    await tap(tester, 'report-send');
    expect((jsonDecode(requests.single.body) as Map)['log'], shown);
  });

  testWidgets('the share-as-file fallback needs only a description', (
    tester,
  ) async {
    final shared = <File>[];
    final svc = ReportService(
      client: ReportClient(
        client: MockClient((r) async => http.Response('', 500)),
      ),
      queue: ReportQueue(root: () async => Directory('${temp.path}/q')),
      limiter: ReportRateLimiter(),
      installId: InstallId(),
      logSource: () async => 'linea',
      deviceInfo: (_) async => _device,
      delay: (_) async {},
      share: (file, _) async => shared.add(file),
      workDirectory: () async => temp,
    );
    await show(tester, svc: svc);
    await tap(tester, 'report-share');
    expect(find.text('Escribe una descripción.'), findsOneWidget);
    expect(shared, isEmpty);

    await type(tester, 'report-text', 'Sin red');
    await tester.tap(find.byKey(const ValueKey('report-share')));
    for (var i = 0; i < 40 && shared.isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 15)),
      );
      await tester.pump();
    }
    expect(shared, hasLength(1));
    expect(shared.single.path, endsWith('.zip'));
    expect(requests, isEmpty);
  });
}
