import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/backend/backend_channel.dart';
import 'package:mornye/services/backend/method_channel_backend.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/fixed_settings.dart';

/// Desktop backend double: keeps `isDesktopPlatform` real for the launcher but
/// routes every backend call (and host to Dart callbacks) through the mocked
/// `com.zarz.mornye/backend` MethodChannel instead of loading
/// `mornye_desktop.dll`.
class _ChannelBackedDesktopBackend extends RustFfiBackend {
  static const _channel = MethodChannelBackend.shared;

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      _channel.invokeMethod<T>(method, arguments);

  @override
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) => _channel.invokeMapMethod<K, V>(method, arguments);

  @override
  void setMethodCallHandler(BackendCallHandler? handler) =>
      _channel.setMethodCallHandler(handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/url_launcher');
  const backend = MethodChannel('com.zarz.mornye/backend');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final uri = Uri.parse('https://example.invalid/verify?state=sample');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    debugDesktopPlatformOverride = null;
    RustFfiBackend.debugShared = null;
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(backend, null);
  });

  // `flutter test` reports Android, where verification opens the embedded
  // panel (`com.zarz.mornye/verification_panel`) instead of url_launcher.
  // Tests that wait for the external browser opt into the desktop path, which
  // always uses url_launcher. The desktop backend is replaced by a double that
  // forwards to the mocked MethodChannel, so no native library is loaded.
  // tearDown restores every override even when the test fails or times out.
  void useExternalBrowserPlatform([
    TargetPlatform platform = TargetPlatform.linux,
  ]) {
    debugDesktopPlatformOverride = true;
    debugDefaultTargetPlatformOverride = platform;
    RustFfiBackend.debugShared = _ChannelBackedDesktopBackend();
  }

  const stepTimeout = Duration(seconds: 2);

  List<String> mockIosLaunches({
    Future<bool> Function()? startSession,
    Future<bool> Function(bool inApp)? openBrowser,
  }) {
    final attempts = <String>[];
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'getExtensionPendingAuth') {
        return {'auth_url': uri.toString()};
      }
      expect(call.method, 'startWebAuthSession');
      expect(call.arguments, {
        'url': uri.toString(),
        'callback_scheme': 'mornye',
      });
      attempts.add('web-auth');
      return startSession == null ? true : await startSession();
    });
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'launch');
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      expect(arguments['url'], uri.toString());
      final inApp = arguments['useWebView'] as bool;
      attempts.add(inApp ? 'in-app' : 'external');
      return openBrowser == null ? true : await openBrowser(inApp);
    });
    return attempts;
  }

  test(
    'distinct pending grants keep independent results and duplicates join',
    () async {
      final firstReply = Completer<bool>();
      final secondReply = Completer<bool>();
      var calls = 0;
      messenger.setMockMethodCallHandler(backend, (call) {
        calls++;
        return calls == 1 ? firstReply.future : secondReply.future;
      });
      final first = PlatformBridge.completeExtensionSessionGrant(
        'Provider-Test',
        'a',
      );
      final duplicate = PlatformBridge.completeExtensionSessionGrant(
        ' provider-test ',
        'a',
      );
      final second = PlatformBridge.completeExtensionSessionGrant(
        'PROVIDER-TEST',
        'b',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      firstReply.complete(false);
      secondReply.complete(true);
      expect(await first, isFalse);
      expect(await duplicate, isFalse);
      expect(await second, isTrue);
    },
  );

  test('grant event matches provider regardless of case', () async {
    useExternalBrowserPlatform();
    final launched = Completer<void>();
    final cancelled = Completer<void>();
    messenger.setMockMethodCallHandler(backend, (call) async {
      if (call.method == 'getExtensionPendingAuth')
        return {'auth_url': uri.toString()};
      return true;
    });
    messenger.setMockMethodCallHandler(channel, (_) async {
      launched.complete();
      return true;
    });
    final result = openVerificationAndAwaitGrant(
      'Provider-Case',
      browserMode: 'external_first',
      cancellationSignal: cancelled.future,
    );
    await launched.future.timeout(stepTimeout);
    await PlatformBridge.completeExtensionSessionGrant('provider-case', 'c');
    final outcome = await result.timeout(
      stepTimeout,
      onTimeout: () {
        cancelled.complete();
        return false;
      },
    );
    expect(outcome, isTrue);
  });

  test(
    'failed grant does not finish flow while another grant is pending',
    () async {
      useExternalBrowserPlatform();
      final launched = Completer<void>();
      final a = Completer<bool>();
      final b = Completer<bool>();
      var calls = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth')
          return {'auth_url': uri.toString()};
        return await (++calls == 1 ? a.future : b.future);
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launched.complete();
        return true;
      });
      final flow = openVerificationAndAwaitGrant(
        'provider-integration',
        browserMode: 'external_first',
      );
      await launched.future.timeout(stepTimeout);
      final first = PlatformBridge.completeExtensionSessionGrant(
        'provider-integration',
        'a',
      );
      final second = PlatformBridge.completeExtensionSessionGrant(
        'provider-integration',
        'b',
      );
      await Future<void>.delayed(Duration.zero);
      a.complete(false);
      expect(await first, isFalse);
      await Future<void>.delayed(Duration.zero);
      b.complete(true);
      expect(await second, isTrue);
      expect(await flow, isTrue);
    },
  );

  for (final throwsError in [false, true]) {
    test('last failed grant finishes flow: throws=$throwsError', () async {
      useExternalBrowserPlatform();
      final launched = Completer<void>();
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth')
          return {'auth_url': uri.toString()};
        if (throwsError) throw PlatformException(code: 'FAILED');
        return false;
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launched.complete();
        return true;
      });
      final flow = openVerificationAndAwaitGrant(
        'provider-failure',
        browserMode: 'external_first',
      );
      await launched.future.timeout(stepTimeout);
      final completion = PlatformBridge.completeExtensionSessionGrant(
        'provider-failure',
        'a',
      );
      if (throwsError) {
        await expectLater(completion, throwsA(isA<PlatformException>()));
      } else {
        expect(await completion, isFalse);
      }
      expect(await flow.timeout(const Duration(seconds: 1)), isFalse);
    });
  }

  for (final verificationId in <String?>[null, 'shared-fixture-id']) {
    test(
      'native failure is suppressed during matching redemption (ID: $verificationId)',
      () async {
        final pending = Completer<bool>();
        messenger.setMockMethodCallHandler(backend, (_) => pending.future);
        final events = <bool>[];
        final subscription = PlatformBridge.extensionSessionGrantEvents()
            .where((event) => event.extensionId == 'provider-native')
            .listen((event) => events.add(event.success));
        addTearDown(subscription.cancel);
        final completion = PlatformBridge.completeExtensionSessionGrant(
          verificationId == null ? 'provider-native' : 'provider-alias',
          'a',
          verificationId: verificationId,
        );
        Future<void> sendNative(bool success) async {
          final reply = Completer<void>();
          messenger.handlePlatformMessage(
            'com.zarz.mornye/backend',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('extensionSessionGrantCompleted', {
                'extension_id': 'provider-native',
                'success': success,
                if (verificationId != null) 'verification_id': verificationId,
              }),
            ),
            (_) => reply.complete(),
          );
          await reply.future;
          await Future<void>.delayed(Duration.zero);
        }

        await sendNative(false);
        expect(events, isEmpty);
        await sendNative(true);
        expect(events, [true]);
        pending.complete(true);
        await completion;
      },
    );
  }

  test('exception clears single flight for identical retry', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(backend, (_) async {
      if (++calls == 1) throw PlatformException(code: 'FAILED');
      return true;
    });
    await expectLater(
      PlatformBridge.completeExtensionSessionGrant('provider-retry', 'a'),
      throwsA(isA<PlatformException>()),
    );
    expect(
      await PlatformBridge.completeExtensionSessionGrant('PROVIDER-RETRY', 'a'),
      isTrue,
    );
    expect(calls, 2);
  });

  test('same grant for different providers remains independent', () async {
    final firstReply = Completer<bool>();
    final secondReply = Completer<bool>();
    var calls = 0;
    messenger.setMockMethodCallHandler(
      backend,
      (_) => ++calls == 1 ? firstReply.future : secondReply.future,
    );
    final first = PlatformBridge.completeExtensionSessionGrant(
      'provider-one',
      'a',
    );
    final second = PlatformBridge.completeExtensionSessionGrant(
      'provider-two',
      'a',
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, 2);
    firstReply.complete(false);
    secondReply.complete(true);
    expect(await first, isFalse);
    expect(await second, isTrue);
  });

  for (final lateSuccess in [false, true]) {
    test(
      'old Dart result does not finish new flow: success=$lateSuccess',
      () async {
        useExternalBrowserPlatform();
        final launches = StreamController<void>.broadcast(sync: true);
        addTearDown(launches.close);
        final oldPending = Completer<bool>();
        final newPending = Completer<bool>();
        var calls = 0;
        messenger.setMockMethodCallHandler(backend, (call) async {
          if (call.method == 'getExtensionPendingAuth')
            return {'auth_url': uri.toString()};
          switch (++calls) {
            case 1:
              return true;
            case 2:
              return await oldPending.future;
            default:
              return await newPending.future;
          }
        });
        messenger.setMockMethodCallHandler(channel, (_) async {
          launches.add(null);
          return true;
        });
        var launched = launches.stream.first;
        final firstFlow = openVerificationAndAwaitGrant(
          'provider-stale',
          browserMode: 'external_first',
        );
        await launched.timeout(stepTimeout);
        final first = PlatformBridge.completeExtensionSessionGrant(
          'provider-stale',
          'a',
        );
        final late = PlatformBridge.completeExtensionSessionGrant(
          'provider-stale',
          'b',
        );
        expect(await first, isTrue);
        expect(await firstFlow, isTrue);
        launched = launches.stream.first;
        final secondFlow = openVerificationAndAwaitGrant(
          'provider-stale',
          browserMode: 'external_first',
        );
        await launched.timeout(stepTimeout);
        var finished = false;
        secondFlow.then((_) => finished = true);
        oldPending.complete(lateSuccess);
        expect(await late, lateSuccess);
        await Future<void>.delayed(Duration.zero);
        expect(finished, isFalse);
        final current = PlatformBridge.completeExtensionSessionGrant(
          'provider-stale',
          'c',
        );
        newPending.complete(true);
        expect(await current, isTrue);
        expect(await secondFlow, isTrue);
      },
    );
  }

  test(
    'cancelled flow cannot affect a later flow with a late Dart result',
    () async {
      useExternalBrowserPlatform();
      final launches = StreamController<void>.broadcast(sync: true);
      addTearDown(launches.close);
      final oldPending = Completer<bool>();
      final cancel = Completer<void>();
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth')
          return {'auth_url': uri.toString()};
        return await oldPending.future;
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches.add(null);
        return true;
      });
      var launched = launches.stream.first;
      final oldFlow = openVerificationAndAwaitGrant(
        'provider-cancelled',
        browserMode: 'external_first',
        cancellationSignal: cancel.future,
      );
      await launched.timeout(stepTimeout);
      final oldCompletion = PlatformBridge.completeExtensionSessionGrant(
        'provider-cancelled',
        'a',
      );
      cancel.complete();
      expect(await oldFlow, isFalse);
      launched = launches.stream.first;
      final newCancel = Completer<void>();
      final newFlow = openVerificationAndAwaitGrant(
        'provider-cancelled',
        browserMode: 'external_first',
        cancellationSignal: newCancel.future,
      );
      await launched.timeout(stepTimeout);
      var finished = false;
      newFlow.then((_) => finished = true);
      oldPending.complete(true);
      expect(await oldCompletion, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      newCancel.complete();
      expect(await newFlow, isFalse);
    },
  );

  for (final beforeLookup in [false, true]) {
    test(
      'late native result from a cancelled challenge cannot close its replacement '
      '(before lookup: $beforeLookup)',
      () async {
        useExternalBrowserPlatform();
        const provider = 'provider-native-replaced';
        final launches = StreamController<void>.broadcast(sync: true);
        addTearDown(launches.close);
        final releaseOldExchange = Completer<void>();
        final newLookupStarted = Completer<void>();
        final releaseNewLookup = Completer<void>();
        final cancelOld = Completer<void>();
        final cancelNew = Completer<void>();
        var pendingLookups = 0;
        messenger.setMockMethodCallHandler(backend, (call) async {
          expect(call.method, 'getExtensionPendingAuth');
          final state = ++pendingLookups == 1 ? 'fixture-old' : 'fixture-new';
          if (pendingLookups == 2) {
            newLookupStarted.complete();
            if (beforeLookup) await releaseNewLookup.future;
          }
          return {
            'auth_url': 'https://example.invalid/verify?state=$state',
            'verification_id': 'verification-$pendingLookups',
          };
        });
        messenger.setMockMethodCallHandler(channel, (_) async {
          launches.add(null);
          return true;
        });

        Future<void> completeNative(
          String? verificationId,
          bool success, {
          String owner = provider,
        }) async {
          final reply = Completer<void>();
          messenger.handlePlatformMessage(
            'com.zarz.mornye/backend',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('extensionSessionGrantCompleted', {
                'extension_id': owner,
                'success': success,
                if (verificationId != null) 'verification_id': verificationId,
              }),
            ),
            (_) => reply.complete(),
          );
          await reply.future;
          await Future<void>.delayed(Duration.zero);
        }

        var launched = launches.stream.first;
        final first = openVerificationAndAwaitGrant(
          provider,
          browserMode: 'external_first',
          cancellationSignal: cancelOld.future,
        );
        await launched.timeout(stepTimeout);
        final oldExchange = releaseOldExchange.future.then(
          (_) => completeNative('verification-1', beforeLookup),
        );
        cancelOld.complete();
        expect(await first, isFalse);

        launched = launches.stream.first;
        final second = openVerificationAndAwaitGrant(
          provider,
          browserMode: 'external_first',
          cancellationSignal: cancelNew.future,
        );
        try {
          await newLookupStarted.future;
          if (!beforeLookup) await launched.timeout(stepTimeout);
          bool? secondOutcome;
          unawaited(second.then((value) => secondOutcome = value));
          releaseOldExchange.complete();
          await oldExchange;
          await completeNative(null, true);
          releaseNewLookup.complete();
          await launched.timeout(stepTimeout);
          await Future<void>.delayed(Duration.zero);
          expect(secondOutcome, isNull);
          await completeNative(null, true, owner: 'different-owner');
          expect(secondOutcome, isNull);
          await completeNative(
            'verification-2',
            !beforeLookup,
            owner: 'shared-challenge-owner',
          );
          expect(await second, !beforeLookup);
        } finally {
          if (!releaseNewLookup.isCompleted) releaseNewLookup.complete();
          cancelNew.complete();
          await second;
        }
      },
    );
  }

  test(
    'new attempt joins pending identical grant without a second redemption',
    () async {
      useExternalBrowserPlatform();
      final launches = StreamController<void>.broadcast(sync: true);
      addTearDown(launches.close);
      final pending = Completer<bool>();
      var calls = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth')
          return {'auth_url': uri.toString()};
        calls++;
        return await pending.future;
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches.add(null);
        return true;
      });
      final cancel = Completer<void>();
      var launched = launches.stream.first;
      final oldFlow = openVerificationAndAwaitGrant(
        'provider-join',
        browserMode: 'external_first',
        cancellationSignal: cancel.future,
      );
      await launched.timeout(stepTimeout);
      final oldCompletion = PlatformBridge.completeExtensionSessionGrant(
        'provider-join',
        'a',
      );
      cancel.complete();
      expect(await oldFlow, isFalse);
      launched = launches.stream.first;
      final newFlow = openVerificationAndAwaitGrant(
        'provider-join',
        browserMode: 'external_first',
      );
      await launched.timeout(stepTimeout);
      final newCompletion = PlatformBridge.completeExtensionSessionGrant(
        'provider-join',
        'a',
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      pending.complete(true);
      expect(await oldCompletion, isTrue);
      expect(await newCompletion, isTrue);
      expect(await newFlow, isTrue);
    },
  );

  test(
    'shared redemption exception clears backend and attempt observers',
    () async {
      final pending = Completer<bool>();
      var calls = 0;
      messenger.setMockMethodCallHandler(backend, (_) async {
        if (++calls == 1) return await pending.future;
        return true;
      });
      final a = PlatformBridge.beginExtensionGrantAttempt(
        'provider-shared-error',
      );
      final first = PlatformBridge.completeExtensionSessionGrant(
        'provider-shared-error',
        'a',
      );
      final firstError = expectLater(first, throwsA(isA<PlatformException>()));
      PlatformBridge.endExtensionGrantAttempt('provider-shared-error', a);
      final b = PlatformBridge.beginExtensionGrantAttempt(
        'provider-shared-error',
      );
      final second = PlatformBridge.completeExtensionSessionGrant(
        'provider-shared-error',
        'a',
      );
      final secondError = expectLater(
        second,
        throwsA(isA<PlatformException>()),
      );
      pending.completeError(PlatformException(code: 'FAILED'));
      await firstError;
      await secondError;
      expect(calls, 1);
      expect(
        await PlatformBridge.completeExtensionSessionGrant(
          'provider-shared-error',
          'a',
        ),
        isTrue,
      );
      expect(calls, 2);
      PlatformBridge.endExtensionGrantAttempt('provider-shared-error', b);
    },
  );

  group('iOS verification browser preference', () {
    setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);

    test(
      'external preference opens the browser without a web auth sheet',
      () async {
        final attempts = mockIosLaunches();
        expect(
          await launchExtensionAuthUrl(uri, browserMode: ' EXTERNAL_FIRST '),
          isTrue,
        );
        expect(attempts, ['external']);
      },
    );

    test('in-app preference keeps callback capture through web auth', () async {
      final attempts = mockIosLaunches();
      expect(
        await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
        isTrue,
      );
      expect(attempts, ['web-auth']);
    });

    for (final throwsError in [false, true]) {
      test(
        'external launch falls back to web auth: throws=$throwsError',
        () async {
          final attempts = mockIosLaunches(
            openBrowser: (inApp) async {
              expect(inApp, isFalse);
              if (throwsError) throw PlatformException(code: 'LAUNCH_FAILED');
              return false;
            },
          );
          expect(
            await launchExtensionAuthUrl(uri, browserMode: 'external_first'),
            isTrue,
          );
          expect(attempts, ['external', 'web-auth']);
        },
      );

      test(
        'failed web auth retains browser fallbacks: throws=$throwsError',
        () async {
          final attempts = mockIosLaunches(
            startSession: () async {
              if (throwsError) throw PlatformException(code: 'SESSION_FAILED');
              return false;
            },
            openBrowser: (inApp) async => !inApp,
          );
          expect(
            await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
            isTrue,
          );
          expect(attempts, ['web-auth', 'in-app', 'external']);
        },
      );
    }

    test(
      'external preference can fall back when web auth is unavailable',
      () async {
        final attempts = mockIosLaunches(
          startSession: () async => false,
          openBrowser: (inApp) async => inApp,
        );
        expect(
          await launchExtensionAuthUrl(uri, browserMode: 'external_first'),
          isTrue,
        );
        expect(attempts, ['external', 'web-auth', 'in-app']);
      },
    );

    for (final mode in ['external_first', 'in_app_first']) {
      test('all launch failures allow manual help: $mode', () async {
        final attempts = mockIosLaunches(
          startSession: () async => false,
          openBrowser: (_) async => false,
        );
        expect(await launchExtensionAuthUrl(uri, browserMode: mode), isFalse);
        expect(
          attempts,
          mode == 'external_first'
              ? ['external', 'web-auth', 'in-app']
              : ['web-auth', 'in-app', 'external'],
        );
      });
    }

    test(
      'late web auth failure does not launch a browser after cancellation',
      () async {
        final started = Completer<void>();
        final session = Completer<bool>();
        final cancellation = Completer<void>();
        final attempts = mockIosLaunches(
          startSession: () {
            started.complete();
            return session.future;
          },
        );
        final opening = openPendingExtensionVerification(
          'provider-a',
          browserMode: 'in_app_first',
          cancellationSignal: cancellation.future,
        );
        await started.future.timeout(const Duration(seconds: 1));
        cancellation.complete();
        expect(await opening, isFalse);
        session.complete(false);
        await Future<void>.delayed(Duration.zero);
        expect(attempts, ['web-auth']);
      },
    );
  });

  test(
    'concurrent waiters share browser and surviving waiter receives grant',
    () async {
      useExternalBrowserPlatform();
      final launched = Completer<void>();
      final cancelled = Completer<void>();
      var launches = 0;
      var lookups = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth') {
          lookups++;
          return {'auth_url': uri.toString()};
        }
        if (call.method == 'completeExtensionSessionGrant') return true;
        fail('Unexpected backend call: ${call.method}');
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches++;
        launched.complete();
        return true;
      });
      final first = openVerificationAndAwaitGrant(
        'provider-shared',
        browserMode: 'external_first',
        cancellationSignal: cancelled.future,
      );
      final second = openVerificationAndAwaitGrant(
        'PROVIDER-SHARED',
        browserMode: 'external_first',
      );
      await launched.future.timeout(stepTimeout);
      cancelled.complete();
      expect(await first, isFalse);
      await PlatformBridge.completeExtensionSessionGrant(
        'provider-shared',
        'test-grant',
      );
      expect(await second, isTrue);
      expect(lookups, 1);
      expect(launches, 1);
    },
  );

  test(
    'browser backgrounding keeps grant wait and retries operation',
    () async {
      useExternalBrowserPlatform();
      var foreground = true;
      var attempts = 0;
      final launched = Completer<void>();
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method == 'getExtensionPendingAuth') {
          return {'auth_url': uri.toString()};
        }
        if (call.method == 'completeExtensionSessionGrant') return true;
        fail('Unexpected backend call: ${call.method}');
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        foreground = false;
        launched.complete();
        return true;
      });
      final result = runExtensionOperationWithVerificationRetry(
        extensionId: 'provider-background',
        browserMode: 'external_first',
        operation: () async {
          attempts++;
          if (attempts == 1) throw Exception('VERIFY_REQUIRED');
          return 'ok';
        },
        verify: () => openVerificationAndAwaitGrant(
          'provider-background',
          browserMode: 'external_first',
          canLaunch: () => foreground,
        ),
      );
      await launched.future.timeout(stepTimeout);
      await Future<void>.delayed(Duration.zero);
      await PlatformBridge.completeExtensionSessionGrant(
        'provider-background',
        'test-grant',
      );
      expect(await result, 'ok');
      expect(attempts, 2);
    },
  );

  test(
    'foreground guard is checked after pending lookup before browser launch',
    () async {
      useExternalBrowserPlatform();
      final pending = Completer<Map<String, String>>();
      final started = Completer<void>();
      var foreground = true;
      var launches = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        expect(call.method, 'getExtensionPendingAuth');
        started.complete();
        return pending.future;
      });
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches++;
        return true;
      });
      final result = openPendingExtensionVerification(
        'provider-guard',
        canLaunch: () => foreground,
      );
      await started.future.timeout(stepTimeout);
      foreground = false;
      pending.complete({'auth_url': uri.toString()});
      expect(await result, isFalse);
      expect(launches, 0);
    },
  );

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test('desktop $platform always uses the external browser', () async {
      useExternalBrowserPlatform(platform);
      final attempts = mockIosLaunches();
      for (final mode in ['external_first', 'in_app_first']) {
        expect(await launchExtensionAuthUrl(uri, browserMode: mode), isTrue);
      }
      expect(attempts, ['external', 'external']);
    });
  }

  for (final inAppFirst in [true, false]) {
    final browserMode = inAppFirst ? 'in_app_first' : 'external_first';
    for (final throwsError in [true, false]) {
      test(
        'browser fallback after launch failure: $browserMode, throws=$throwsError',
        () async {
          final modes = <bool>[];
          messenger.setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'launch');
            final arguments = Map<String, dynamic>.from(call.arguments as Map);
            expect(arguments['url'], uri.toString());
            modes.add(arguments['useWebView'] as bool);
            if (modes.length == 1) {
              if (throwsError) {
                throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
              }
              return false;
            }
            return true;
          });
          expect(
            await launchExtensionAuthUrl(uri, browserMode: browserMode),
            isTrue,
          );
          expect(modes, [inAppFirst, !inAppFirst]);
        },
      );
    }
  }

  test(
    'both browser failures return false so manual help can be shown',
    () async {
      var launches = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        launches++;
        throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
      });
      expect(
        await launchExtensionAuthUrl(uri, browserMode: 'in_app_first'),
        isFalse,
      );
      expect(launches, 2);
    },
  );

  test(
    'direct search verifies through the fallback browser and retries once',
    () async {
      // Browser fallback only exists on the mobile url_launcher path that is
      // not the Android embedded panel: iOS (web auth session, then browsers).
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      var searches = 0;
      var pendingLookups = 0;
      var launches = 0;
      messenger.setMockMethodCallHandler(backend, (call) async {
        switch (call.method) {
          case 'startWebAuthSession':
            return false;
          case 'customSearchWithExtension':
            searches++;
            if (searches == 1) {
              throw PlatformException(
                code: 'ERROR',
                message:
                    "verification_required: extension 'sample-provider' needs signed-session verification: Error: VERIFY_REQUIRED",
              );
            }
            return [
              {
                'id': 'sample-track',
                'name': 'Sample track',
                'artist_name': 'Artist',
              },
            ];
          case 'getExtensionPendingAuth':
            pendingLookups++;
            expect(call.arguments, {'extension_id': 'sample-provider'});
            return {'auth_url': uri.toString()};
          case 'completeExtensionSessionGrant':
            return true;
          default:
            fail('Unexpected backend call: ${call.method}');
        }
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        launches++;
        if (launches == 1) throw PlatformException(code: 'ACTIVITY_NOT_FOUND');
        unawaited(
          PlatformBridge.completeExtensionSessionGrant(
            'sample-provider',
            'test-grant',
          ),
        );
        return true;
      });
      final container = ProviderContainer(
        overrides: [settingsProvider.overrideWith(FixedSettingsNotifier.new)],
      );
      addTearDown(container.dispose);
      await container
          .read(trackProvider.notifier)
          .customSearch('sample-provider', 'fallback verification');
      final state = container.read(trackProvider);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
      expect(state.tracks.single.id, 'sample-track');
      expect(searches, 2);
      expect(pendingLookups, 1);
      expect(launches, 2);
    },
  );
}
