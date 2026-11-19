import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  // The panel is the Android default. A build can disable it for rollback.
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const panel = MethodChannel('com.zarz.mornye/verification_panel');
  const browser = MethodChannel('plugins.flutter.io/url_launcher');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDesktopPlatformOverride = false;
    messenger.setMockMethodCallHandler(backend, (_) async => {
      'auth_url': 'https://example.invalid/verify?state=fixture',
    });
    messenger.setMockMethodCallHandler(browser, (_) async {
      fail('Embedded verification must not open a browser automatically');
    });
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    for (final channel in [backend, panel, browser]) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  });

  test('Android pending verification uses panel and respects user cancellation', () async {
    var opens = 0;
    messenger.setMockMethodCallHandler(panel, (call) async {
      expect(call.method, 'open');
      expect((call.arguments as Map)['url'], startsWith('https://example.invalid/'));
      opens++;
      return false;
    });
    expect(await openPendingExtensionVerification('fixture'), isFalse);
    expect(opens, 1);
  }, skip: !embeddedExtensionVerificationEnabled);

  test('pending verification uses the panel even with legacy external preference', () async {
    var opens = 0;
    messenger.setMockMethodCallHandler(panel, (call) async {
      expect(call.method, 'open');
      opens++;
      return false;
    });
    expect(
      await openPendingExtensionVerification('fixture', browserMode: 'external_first'),
      isFalse,
    );
    expect(opens, 1);
  }, skip: !embeddedExtensionVerificationEnabled);

  testWidgets('panel unavailable stays silent without opening a browser', (tester) async {
    messenger.setMockMethodCallHandler(panel, (_) async => null);
    try {
      await tester.pumpWidget(MaterialApp(
        navigatorKey: AppNavigationService.rootNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Text('Library')),
      ));
      expect(await openPendingExtensionVerification('fixture'), isFalse);
      await tester.pump();
      expect(find.byType(SnackBar), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      // flutter_test verifies foundation debug variables when the testWidgets
      // body ends, i.e. BEFORE package:test runs tearDown callbacks. Resetting
      // only in tearDown therefore reports "debug variable changed".
      debugDefaultTargetPlatformOverride = null;
      debugDesktopPlatformOverride = null;
    }
  }, skip: !embeddedExtensionVerificationEnabled);

  test('flow cancellation closes only its own embedded panel', () async {
    final started = Completer<String>();
    final pending = Completer<bool>();
    final cancellation = Completer<void>();
    String? closed;
    messenger.setMockMethodCallHandler(panel, (call) async {
      final id = (call.arguments as Map)['id'] as String;
      if (call.method == 'open') {
        started.complete(id);
        return pending.future;
      }
      expect(call.method, 'close');
      closed = id;
      pending.complete(false);
      return null;
    });
    final flow = openPendingExtensionVerification('fixture', cancellationSignal: cancellation.future);
    final id = await started.future;
    cancellation.complete();
    expect(await flow, isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(closed, id);
  }, skip: !embeddedExtensionVerificationEnabled);

  test('already authenticated provider does not show activation panel', () async {
    messenger.setMockMethodCallHandler(backend, (_) async => {'authenticated': true});
    messenger.setMockMethodCallHandler(panel, (_) async {
      fail('No pending challenge requires no activation UI');
    });
    expect(await openPendingExtensionVerification('fixture'), isFalse);
  });
}
