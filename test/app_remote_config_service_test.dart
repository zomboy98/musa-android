import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/services/app_remote_config_service.dart';

class _TrackedClient extends MockClient {
  _TrackedClient(super.handler);

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('MUSA defaults skip HTTP creation and cached announcements', () async {
    SharedPreferences.setMockInitialValues({
      'app_remote_config_cached_json': jsonEncode(
        _configPayload(announcementId: 'upstream-cached'),
      ),
    });
    var clientCreations = 0;
    await http.runWithClient(
      () async {
        final service = AppRemoteConfigService();
        expect(await service.fetchConfigSnapshot(locale: 'es'), isNull);
        expect(await service.fetchActiveAnnouncement(locale: 'es'), isNull);
        expect(await service.readCachedConfig(), isNull);
      },
      () {
        clientCreations++;
        throw StateError(
          'Disabled announcements must not create an HTTP client',
        );
      },
    );
    expect(clientCreations, 0);
    // setPrefix throws once getInstance has been called. This verifies that
    // disabled reads did not even open preferences, despite a valid cache.
    try {
      expect(() => SharedPreferences.setPrefix('probe.'), returnsNormally);
    } finally {
      SharedPreferences.resetStatic();
    }
  });

  test('disabled service never calls or closes an injected client', () async {
    var requests = 0;
    final client = _TrackedClient((_) async {
      requests++;
      return http.Response('{}', 200);
    });
    final service = AppRemoteConfigService(client: client);
    expect(await service.fetchConfigSnapshot(), isNull);
    expect(await service.fetchActiveAnnouncement(), isNull);
    expect(requests, 0);
    expect(client.closed, isFalse);
    client.close();
  });

  test('explicit opt-in can use cached announcements when offline', () async {
    SharedPreferences.setMockInitialValues({
      'app_remote_config_cached_json': jsonEncode(
        _configPayload(announcementId: 'cached-announcement'),
      ),
    });
    final service = AppRemoteConfigService(
      enabled: true,
      client: MockClient((_) async => http.Response('', 503)),
    );
    expect(
      (await service.fetchActiveAnnouncement())?.id,
      'cached-announcement',
    );
  });

  test('default request closes its client on success and failure', () async {
    for (final fail in [false, true]) {
      final client = _TrackedClient((_) async {
        if (fail) throw StateError('network unavailable');
        return http.Response('{}', 200);
      });
      final snapshot = await http.runWithClient(
        () => AppRemoteConfigService(enabled: true).fetchConfigSnapshot(),
        () => client,
      );
      expect(snapshot, fail ? isNull : isNotNull);
      expect(client.closed, isTrue);
    }
  });

  test('injected client remains owned by its caller', () async {
    final client = _TrackedClient((_) async => http.Response('{}', 200));
    final service = AppRemoteConfigService(client: client, enabled: true);
    expect(await service.fetchConfigSnapshot(), isNotNull);
    expect(client.closed, isFalse);
    expect(await service.fetchConfigSnapshot(), isNotNull);
    client.close();
  });

  test(
    'refreshes remote config despite a legacy recent-fetch timestamp',
    () async {
      SharedPreferences.setMockInitialValues({
        'app_remote_config_cached_json': jsonEncode(
          _configPayload(announcementId: 'cached-announcement'),
        ),
        'app_remote_config_last_fetch_at': DateTime.now().toIso8601String(),
      });

      var requestCount = 0;
      final service = AppRemoteConfigService(
        enabled: true,
        endpoint: 'https://example.test/config',
        client: MockClient((request) async {
          requestCount++;
          return http.Response(
            jsonEncode(_configPayload(announcementId: 'fresh-announcement')),
            200,
          );
        }),
      );

      final snapshot = await service.fetchConfigSnapshot(locale: 'en-US');

      expect(requestCount, 1);
      expect(snapshot?.changed, isTrue);
      expect(snapshot?.config.announcement?.id, 'fresh-announcement');
    },
  );

  test('checks the endpoint again for each remote config request', () async {
    var requestCount = 0;
    final service = AppRemoteConfigService(
      enabled: true,
      endpoint: 'https://example.test/config',
      client: MockClient((request) async {
        requestCount++;
        return http.Response(
          jsonEncode(
            _configPayload(announcementId: 'announcement-$requestCount'),
          ),
          200,
        );
      }),
    );

    final first = await service.fetchConfigSnapshot(locale: 'en-US');
    final second = await service.fetchConfigSnapshot(locale: 'en-US');

    expect(requestCount, 2);
    expect(first?.config.announcement?.id, 'announcement-1');
    expect(second?.config.announcement?.id, 'announcement-2');
  });
}

Map<String, Object?> _configPayload({required String announcementId}) {
  return {
    'announcement': {
      'id': announcementId,
      'enabled': true,
      'title': 'Announcement',
      'message': 'Announcement message',
    },
  };
}
