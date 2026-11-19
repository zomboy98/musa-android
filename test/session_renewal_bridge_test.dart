import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/platform_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.zarz.mornye/backend');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('renewal forwards extension and disabled choice', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'renewExistingSession');
      expect(call.arguments, {'extension_id': 'musa', 'enabled': false});
      return '{"status":"disabled"}';
    });
    final result = await PlatformBridge.renewExistingSession('musa', enabled: false);
    expect(result.status, SessionRenewalStatus.disabled);
    expect(result.expiresAt, isNull);
  });

  test('renewal returns the expiry for refreshed and valid sessions', () async {
    for (final entry in {'refreshed': SessionRenewalStatus.refreshed, 'valid_until': SessionRenewalStatus.validUntil}.entries) {
      messenger.setMockMethodCallHandler(channel, (_) async => '{"status":"${entry.key}","expires_at":"2026-01-01T01:00:00Z"}');
      final result = await PlatformBridge.renewExistingSession('musa', enabled: true);
      expect(result.status, entry.value);
      expect(result.expiresAt, '2026-01-01T01:00:00Z');
    }
  });

  test('renewal decodes every non-expiry native status', () async {
    for (final entry in {
      'not_applicable': SessionRenewalStatus.notApplicable,
      'missing': SessionRenewalStatus.missing,
      'blocked': SessionRenewalStatus.blocked,
      'invalid': SessionRenewalStatus.invalid,
      'unavailable': SessionRenewalStatus.unavailable,
    }.entries) {
      messenger.setMockMethodCallHandler(channel, (_) async => '{"status":"${entry.key}"}');
      final result = await PlatformBridge.renewExistingSession('musa', enabled: true);
      expect(result.status, entry.value);
      expect(result.expiresAt, isNull);
    }
  });
  test('renewal rejects unknown status and missing expiry', () async {
    for (final payload in ['{"status":"unexpected"}', '{"status":"valid_until"}']) {
      messenger.setMockMethodCallHandler(channel, (_) async => payload);
      await expectLater(PlatformBridge.renewExistingSession('musa', enabled: true), throwsStateError);
    }
  });
}
