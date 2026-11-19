import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/diagnostics_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/analytics/anonymous_metrics.dart';
import 'package:mornye/services/analytics/install_id.dart';
import 'package:mornye/services/diagnostics/report_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);

  final AppSettings initial;

  @override
  AppSettings build() => initial;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<http.Request> requests;
  late List<int> statuses;
  late List<AnonymousMetrics> created;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    statuses = [];
    created = [];
  });

  tearDown(() {
    for (final metrics in created) {
      metrics.dispose();
    }
  });

  AnonymousMetrics metrics({
    Duration interval = const Duration(milliseconds: 60),
  }) {
    final client = MockClient((request) async {
      requests.add(request);
      final status = statuses.isEmpty ? 200 : statuses.removeAt(0);
      return http.Response('{"ok":true}', status);
    });
    final instance = AnonymousMetrics(
      client: client,
      installId: InstallId(),
      osVersion: () async => 14,
      appVersion: '5.3.1+2228',
      interval: interval,
      maxBackoff: const Duration(milliseconds: 400),
    );
    created.add(instance);
    return instance;
  }

  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Map<String, dynamic> body(int index) =>
      jsonDecode(requests[index].body) as Map<String, dynamic>;

  test('sends nothing until policy and switch allow it', () async {
    final m = metrics()..setForeground(true);
    m.recordDownload();
    m.recordStream();
    await wait(200);
    expect(requests, isEmpty);
    expect(m.pendingDownloads, 0);
    expect(m.pendingStreams, 0);

    m.setAllowed(true);
    await wait(40);
    expect(requests, hasLength(1));
    expect(body(0)['dl'], 0);
    expect(body(0)['st'], 0);
  });

  test(
    'turning the switch off stops sending and drops pending counters',
    () async {
      final m = metrics()
        ..setAllowed(true)
        ..setForeground(true);
      await wait(30);
      m.recordDownload();
      m.recordStream();
      await wait(5);
      expect(m.pendingDownloads, 1);
      m.setAllowed(false);
      await wait(5);
      final sent = requests.length;
      expect(m.pendingDownloads, 0);
      expect(m.pendingStreams, 0);
      expect(m.running, isFalse);
      await wait(250);
      expect(requests.length, sent);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(AnonymousMetrics.downloadsKey), 0);
    },
  );

  test('beats only while the app is in the foreground', () async {
    final m = metrics()..setAllowed(true);
    await wait(200);
    expect(requests, isEmpty);

    m.setForeground(true);
    await wait(40);
    expect(requests, hasLength(1));
    await wait(150);
    final whileForeground = requests.length;
    expect(whileForeground, greaterThanOrEqualTo(3));

    m.setForeground(false);
    await wait(10);
    final atPause = requests.length;
    await wait(250);
    expect(requests.length, atPause);
    expect(m.running, isFalse);

    m.setForeground(true);
    await wait(40);
    expect(requests.length, greaterThan(atPause));
  });

  test(
    'request has exactly id, v, os, dl and st and no personal data',
    () async {
      final m = metrics(interval: const Duration(seconds: 30))
        ..setAllowed(true);
      m.recordDownload();
      m.recordDownload();
      m.recordDownload();
      m.recordStream();
      m.recordStream();
      await wait(10);
      m.setForeground(true);
      await wait(60);

      expect(requests, hasLength(1));
      final request = requests.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'https://musa-api.heyshin.app/v1/m');
      expect(request.headers['content-type'], startsWith('application/json'));
      final data = body(0);
      expect(data.keys.toSet(), {'id', 'v', 'os', 'dl', 'st'});
      expect(data['id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(data['v'], '5.3.1+2228');
      expect(data['os'], 14);
      expect(data['dl'], 3);
      expect(data['st'], 2);
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
      expect(
        request.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('cookie')),
      );
    },
  );

  test('counters restart after a delivery and keep accumulating', () async {
    final m = metrics()..setAllowed(true);
    m.recordDownload();
    m.recordStream();
    await wait(5);
    m.setForeground(true);
    await wait(40);
    expect(body(0)['dl'], 1);
    expect(body(0)['st'], 1);
    expect(m.pendingDownloads, 0);
    expect(m.pendingStreams, 0);

    m.recordStream();
    m.recordStream();
    await wait(100);
    final next = requests
        .map((r) => jsonDecode(r.body) as Map)
        .firstWhere((b) => b['st'] == 2);
    expect(next['dl'], 0);
    final last = jsonDecode(requests.last.body) as Map;
    expect(last['dl'], 0);
    expect(last['st'], 0);
  });

  test('a failed delivery keeps the counters and backs off', () async {
    statuses.addAll([500, 500, 500]);
    final m = metrics(interval: const Duration(milliseconds: 20))
      ..setAllowed(true);
    m.recordDownload();
    await wait(5);
    final stopwatch = Stopwatch()..start();
    m.setForeground(true);
    final stamps = <int>[];
    final end = DateTime.now().add(const Duration(milliseconds: 420));
    while (DateTime.now().isBefore(end)) {
      if (requests.length > stamps.length)
        stamps.add(stopwatch.elapsedMilliseconds);
      await wait(2);
    }
    expect(requests.length, greaterThanOrEqualTo(4));
    expect(body(0)['dl'], 1);
    expect(body(1)['dl'], 1);
    expect(body(2)['dl'], 1);
    expect(body(3)['dl'], 1);
    final gap1 = stamps[1] - stamps[0];
    final gap2 = stamps[2] - stamps[1];
    expect(gap2, greaterThan(gap1));
  });

  test('network errors do not lose counters and do not hammer', () async {
    final failing = MockClient((request) async {
      requests.add(request);
      throw http.ClientException('offline');
    });
    final m = AnonymousMetrics(
      client: failing,
      installId: InstallId(),
      osVersion: () async => 14,
      appVersion: '1',
      interval: const Duration(milliseconds: 30),
      maxBackoff: const Duration(milliseconds: 500),
    );
    created.add(m);
    m.setAllowed(true);
    m.recordDownload();
    await wait(5);
    m.setForeground(true);
    await wait(300);
    expect(m.pendingDownloads, 1);
    expect(requests.length, lessThan(8));
  });

  test('429 from the server keeps the counters for the next beat', () async {
    statuses.add(429);
    final m = metrics()..setAllowed(true);
    m.recordStream();
    await wait(5);
    m.setForeground(true);
    await wait(30);
    expect(m.pendingStreams, 1);
    await wait(120);
    expect(m.pendingStreams, 0);
    expect(body(1)['st'], 1);
  });

  test('never sends more than 500 per request and carries the rest', () async {
    final m = metrics(interval: const Duration(milliseconds: 50))
      ..setAllowed(true);
    for (var i = 0; i < 520; i++) {
      m.recordDownload();
    }
    await wait(30);
    m.setForeground(true);
    await wait(200);
    expect(body(0)['dl'], 500);
    expect(body(1)['dl'], 20);
  });

  test('counters survive a restart', () async {
    final first = metrics(interval: const Duration(seconds: 30))
      ..setAllowed(true);
    first.recordDownload();
    first.recordDownload();
    first.recordStream();
    await wait(20);

    final second = metrics(interval: const Duration(seconds: 30))
      ..setAllowed(true)
      ..setForeground(true);
    await wait(60);
    expect(body(0)['dl'], 2);
    expect(body(0)['st'], 1);
    expect(second.pendingDownloads, 0);
  });

  group('allowed provider', () {
    ProviderContainer container(AppSettings settings) {
      final c = ProviderContainer(
        overrides: [settingsProvider.overrideWith(() => _Settings(settings))],
      );
      addTearDown(c.dispose);
      return c;
    }

    test('needs the switch and the accepted policy', () {
      expect(
        container(const AppSettings()).read(analyticsAllowedProvider),
        isFalse,
      );
      expect(
        container(
          const AppSettings(acceptedLegalVersion: 1),
        ).read(analyticsAllowedProvider),
        isTrue,
      );
      expect(
        container(
          const AppSettings(acceptedLegalVersion: 1, analyticsEnabled: false),
        ).read(analyticsAllowedProvider),
        isFalse,
      );
      expect(
        container(
          const AppSettings(analyticsEnabled: true),
        ).read(analyticsAllowedProvider),
        isFalse,
      );
    });

    test('the analytics switch defaults to on', () {
      expect(const AppSettings().analyticsEnabled, isTrue);
      expect(AppSettings.fromJson(const {}).analyticsEnabled, isTrue);
      expect(
        AppSettings.fromJson(const {
          'analyticsEnabled': false,
        }).analyticsEnabled,
        isFalse,
      );
    });

    testWidgets('lifecycle drives the foreground state', (tester) async {
      final m = metrics(interval: const Duration(seconds: 30));
      final c = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(const AppSettings(acceptedLegalVersion: 1)),
          ),
          anonymousMetricsProvider.overrideWithValue(m),
          reportServiceProvider.overrideWithValue(_NoopReports()),
        ],
      );
      addTearDown(c.dispose);
      c.read(diagnosticsRuntimeProvider);
      expect(m.allowed, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      expect(m.foreground, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(m.foreground, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      expect(m.foreground, isFalse);
      m.dispose();
    });
  });
}

class _NoopReports extends ReportService {
  @override
  Future<int> flushPending() async => 0;
}
