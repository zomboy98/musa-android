import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/plugin_code_service.dart';

String _hash(List<int> bytes) => sha256.convert(bytes).toString();

Map<String, Object?> _item(
  String id,
  String version,
  List<int> bytes, {
  String? url,
  String? hash,
}) => {
  'id': id,
  'name': 'Name $id',
  'version': version,
  'url': url ?? 'https://files.example.com/$id.mornye-ext',
  'sha256': hash ?? _hash(bytes),
};

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('plugin_code_test_');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  PluginCodeService serviceFor(
    Future<http.Response> Function(http.Request request) handler,
  ) => PluginCodeService(client: MockClient(handler), tempRoot: temp);

  group('normalizePluginCode', () {
    test('trims and uppercases', () {
      expect(normalizePluginCode('  abcd-12  '), 'ABCD-12');
    });

    test('rejects bad length and characters', () {
      expect(normalizePluginCode('abc'), isNull);
      expect(normalizePluginCode('a' * 33), isNull);
      expect(normalizePluginCode('abcd e'), isNull);
      expect(normalizePluginCode('abcd_1'), isNull);
    });
  });

  group('comparePluginVersions', () {
    test('compares numerically', () {
      expect(comparePluginVersions('1.10.0', '1.9.0'), 1);
      expect(comparePluginVersions('1.2', '1.2.0'), 0);
      expect(comparePluginVersions('0.9.9', '1.0.0'), -1);
    });
  });

  group('lookup', () {
    test('invalid code does not hit the network', () async {
      var calls = 0;
      final service = serviceFor((request) async {
        calls++;
        return http.Response('{}', 200);
      });
      await expectLater(
        service.lookup('x'),
        throwsA(
          isA<PluginCodeException>().having(
            (e) => e.failure,
            'failure',
            PluginCodeFailure.invalidFormat,
          ),
        ),
      );
      expect(calls, 0);
    });

    test('normalizes the code and calls only the official host', () async {
      late Uri requested;
      final service = serviceFor((request) async {
        requested = request.url;
        return http.Response(
          jsonEncode({
            'code': 'ABCD',
            'name': 'Pack',
            'items': [
              _item('a', '1.0.0', [1]),
            ],
          }),
          200,
        );
      });
      final bundle = await service.lookup('  abcd ');
      expect(requested.toString(), 'https://musa-api.heyshin.app/v1/code/ABCD');
      expect(bundle.code, 'ABCD');
      expect(bundle.items.single.id, 'a');
    });

    test('404 is a not found failure', () async {
      final service = serviceFor((request) async => http.Response('', 404));
      await expectLater(
        service.lookup('ABCD'),
        throwsA(
          isA<PluginCodeException>().having(
            (e) => e.failure,
            'failure',
            PluginCodeFailure.notFound,
          ),
        ),
      );
    });

    test('malformed JSON is rejected', () async {
      for (final body in [
        'not json',
        '[]',
        '{"items": []}',
        '{"items":[{"id":"a"}]}',
      ]) {
        final service = serviceFor((request) async => http.Response(body, 200));
        await expectLater(
          service.lookup('ABCD'),
          throwsA(
            isA<PluginCodeException>().having(
              (e) => e.failure,
              'failure',
              PluginCodeFailure.malformed,
            ),
          ),
          reason: body,
        );
      }
    });

    test('network errors are reported as network failures', () async {
      final service = serviceFor((request) async {
        throw const SocketException('offline');
      });
      await expectLater(
        service.lookup('ABCD'),
        throwsA(
          isA<PluginCodeException>().having(
            (e) => e.failure,
            'failure',
            PluginCodeFailure.network,
          ),
        ),
      );
    });

    test('does not follow a redirect to another host', () async {
      final service = serviceFor(
        (request) async => http.Response(
          '',
          302,
          headers: {'location': 'https://evil.example.com/x'},
        ),
      );
      await expectLater(
        service.lookup('ABCD'),
        throwsA(
          isA<PluginCodeException>().having(
            (e) => e.failure,
            'failure',
            PluginCodeFailure.insecureUrl,
          ),
        ),
      );
    });
  });

  group('redeem', () {
    final good = utf8.encode('package-good');
    final other = utf8.encode('package-other');

    Future<http.Response> Function(http.Request) server(
      List<Map<String, Object?>> items,
      Map<String, List<int>> files,
    ) => (request) async {
      if (request.url.host == 'musa-api.heyshin.app') {
        return http.Response(
          jsonEncode({'code': 'ABCD', 'name': 'Pack', 'items': items}),
          200,
        );
      }
      final bytes = files[request.url.path];
      return bytes == null
          ? http.Response('', 404)
          : http.Response.bytes(bytes, 200);
    };

    test('wrong hash rejects the item and installs nothing', () async {
      final service = serviceFor(
        server(
          [_item('a', '1.0.0', good, hash: _hash(other))],
          {'/a.mornye-ext': good},
        ),
      );
      final installed = <String>[];
      final report = await service.redeem(
        'ABCD',
        installedVersions: {},
        install: (path) async {
          installed.add(path);
          return true;
        },
        upgrade: (path) async => true,
      );
      expect(installed, isEmpty);
      expect(report.results.single.outcome, PluginCodeOutcome.failed);
      expect(report.results.single.failure, PluginCodeFailure.hashMismatch);
    });

    test('http package URL is rejected', () async {
      final service = serviceFor(
        server(
          [
            _item(
              'a',
              '1.0.0',
              good,
              url: 'http://files.example.com/a.mornye-ext',
            ),
          ],
          {'/a.mornye-ext': good},
        ),
      );
      final report = await service.redeem(
        'ABCD',
        installedVersions: {},
        install: (path) async => true,
        upgrade: (path) async => true,
      );
      expect(report.results.single.failure, PluginCodeFailure.insecureUrl);
    });

    test('two items with one failing still installs the other', () async {
      final service = serviceFor(
        server(
          [
            _item('a', '1.0.0', good),
            _item('b', '2.0.0', good, hash: _hash(other)),
          ],
          {'/a.mornye-ext': good, '/b.mornye-ext': good},
        ),
      );
      final installedBytes = <List<int>>[];
      final report = await service.redeem(
        'abcd',
        installedVersions: {},
        install: (path) async {
          installedBytes.add(await File(path).readAsBytes());
          return true;
        },
        upgrade: (path) async => true,
      );
      expect(installedBytes, [good]);
      expect(report.count(PluginCodeOutcome.added), 1);
      expect(report.count(PluginCodeOutcome.failed), 1);
      expect(report.anyChanged, isTrue);
      expect(temp.listSync(), isEmpty);
    });

    test('same version is already added, newer version upgrades', () async {
      final service = serviceFor(
        server(
          [_item('a', '1.2.0', good), _item('b', '2.0.0', good)],
          {'/a.mornye-ext': good, '/b.mornye-ext': good},
        ),
      );
      var installs = 0;
      var upgrades = 0;
      final report = await service.redeem(
        'ABCD',
        installedVersions: {'a': '1.2.0', 'b': '1.0.0'},
        install: (path) async {
          installs++;
          return true;
        },
        upgrade: (path) async {
          upgrades++;
          return true;
        },
      );
      expect(installs, 0);
      expect(upgrades, 1);
      expect(report.results[0].outcome, PluginCodeOutcome.alreadyAdded);
      expect(report.results[1].outcome, PluginCodeOutcome.updated);
    });

    test('installer returning false is a failed item', () async {
      final service = serviceFor(
        server([_item('a', '1.0.0', good)], {'/a.mornye-ext': good}),
      );
      final report = await service.redeem(
        'ABCD',
        installedVersions: {},
        install: (path) async => false,
        upgrade: (path) async => false,
      );
      expect(report.results.single.failure, PluginCodeFailure.installFailed);
    });

    test('a stuck installer times out and the next item still runs', () async {
      final service = serviceFor(
        server(
          [_item('a', '1.0.0', good), _item('b', '1.0.0', other)],
          {'/a.mornye-ext': good, '/b.mornye-ext': other},
        ),
      );
      var calls = 0;
      final report = await service.redeem(
        'ABCD',
        installedVersions: {},
        itemTimeout: const Duration(milliseconds: 50),
        install: (path) {
          calls++;
          return calls == 1 ? Completer<bool>().future : Future.value(true);
        },
        upgrade: (path) async => true,
      );
      expect(report.results.first.failure, PluginCodeFailure.timeout);
      expect(report.results.last.outcome, PluginCodeOutcome.added);
    });
  });
}
