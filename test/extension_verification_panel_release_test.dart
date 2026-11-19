import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Release signal of a `busy` verification panel reply.
///
/// Native keeps a single pending panel request and answers `busy` while it
/// exists. The release signal must be tied to the real end of a request this
/// isolate dispatched, never to a timer or polling. Mocked channels only.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const panel = MethodChannel('com.zarz.mornye/verification_panel');
  const browser = MethodChannel('plugins.flutter.io/url_launcher');

  group('awaitVerificationPanelRelease', () {
    ExtensionVerificationResult busyUntil(Future<void> released) =>
        ExtensionVerificationResult.busyUntil(released);

    test('does not wait for results without a release signal', () async {
      for (final result in [
        ExtensionVerificationResult.busy,
        ExtensionVerificationResult.failed,
        ExtensionVerificationResult.failedAfterInteraction,
        const ExtensionVerificationResult(ExtensionVerificationStatus.granted),
      ]) {
        expect(
          await awaitVerificationPanelRelease(
            result,
            timeout: const Duration(seconds: 5),
          ).timeout(const Duration(milliseconds: 200)),
          isFalse,
        );
      }
      expect(ExtensionVerificationResult.busyUntil(null).panelReleased, isNull);
    });

    test('completes when the holding panel ends', () async {
      final released = Completer<void>();
      final waiting = awaitVerificationPanelRelease(
        busyUntil(released.future),
        timeout: const Duration(seconds: 5),
      );
      released.complete();
      expect(await waiting.timeout(const Duration(seconds: 1)), isTrue);
    });

    test('stops at the timeout when the panel never ends', () async {
      expect(
        await awaitVerificationPanelRelease(
          busyUntil(Completer<void>().future),
          timeout: const Duration(milliseconds: 30),
        ).timeout(const Duration(seconds: 2)),
        isFalse,
      );
    });

    test('stops on cancellation, also when it races the release', () async {
      final cancel = Completer<void>();
      final waiting = awaitVerificationPanelRelease(
        busyUntil(Completer<void>().future),
        cancellationSignal: cancel.future,
        timeout: const Duration(seconds: 5),
      );
      cancel.complete();
      expect(await waiting.timeout(const Duration(seconds: 1)), isFalse);

      expect(
        await awaitVerificationPanelRelease(
          busyUntil(Future<void>.value()),
          cancellationSignal: Future<void>.value(),
          timeout: const Duration(seconds: 5),
        ).timeout(const Duration(seconds: 1)),
        isFalse,
        reason: 'an already cancelled wait must never open a new challenge',
      );
    });

    test('cancellation derived from a completed future still wins', () async {
      // `.then` adds a microtask hop: the cancellation settles after the
      // already completed release signal.
      final derivedCancel = Future<void>.value().then((_) {});
      expect(
        await awaitVerificationPanelRelease(
          busyUntil(Future<void>.value()),
          cancellationSignal: derivedCancel,
          timeout: const Duration(seconds: 5),
        ).timeout(const Duration(seconds: 1)),
        isFalse,
        reason: 'a cancellation must not lose to a release one hop earlier',
      );
    });
  });

  group('busy reply release signal', () {
    var counter = 0;
    late List<MethodCall> panelCalls;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugDesktopPlatformOverride = false;
      panelCalls = [];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(browser, (_) async {
        fail('Embedded verification must never open a browser');
      });
      messenger.setMockMethodCallHandler(backend, (call) async {
        if (call.method != 'getExtensionPendingAuth') return null;
        final id = (call.arguments as Map)['extension_id'] as String;
        return {'auth_url': 'https://example.invalid/verify?ext=$id'};
      });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in [backend, panel, browser]) {
        messenger.setMockMethodCallHandler(channel, null);
      }
      debugDefaultTargetPlatformOverride = null;
      debugDesktopPlatformOverride = null;
    });

    String urlOf(MethodCall call) => (call.arguments as Map)['url'] as String;

    void mockPanel(Future<Object?> Function(MethodCall call) reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(panel, (call) {
            panelCalls.add(call);
            return reply(call);
          });
    }

    Future<ExtensionVerificationResult> resolve(String id) =>
        resolveExtensionVerification(
          id,
          browserMode: 'in_app_first',
          quietUnavailable: true,
        );

    test('busy behind an in-flight panel completes when it ends', () async {
      final holder = 'holder-${counter++}';
      final waiter = 'waiter-${counter++}';
      final holderReply = Completer<Object?>();
      final holderOpened = Completer<void>();
      addTearDown(() {
        if (!holderReply.isCompleted) holderReply.complete('closed');
      });
      mockPanel((call) async {
        if (call.method != 'open') return null;
        if (urlOf(call).contains(holder)) {
          holderOpened.complete();
          return holderReply.future;
        }
        return holderReply.isCompleted ? 'closed' : 'busy';
      });

      final holderFlow = resolve(holder);
      await holderOpened.future.timeout(const Duration(seconds: 2));
      final busy = await resolve(waiter).timeout(const Duration(seconds: 2));

      expect(busy.panelBusy, isTrue);
      expect(busy.interactionShown, isFalse);
      expect(busy.blocksProviderFallback, isTrue);
      final released = busy.panelReleased;
      expect(released, isNotNull);
      var releasedNow = false;
      unawaited(released!.then((_) => releasedNow = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(releasedNow, isFalse, reason: 'the holder panel is still open');

      final waiting = awaitVerificationPanelRelease(
        busy,
        timeout: const Duration(seconds: 2),
      );
      holderReply.complete('closed');
      expect(await waiting, isTrue);
      expect(releasedNow, isTrue);
      final holderResult = await holderFlow.timeout(const Duration(seconds: 2));
      expect(holderResult.interactionShown, isTrue);
      expect(
        panelCalls.where((c) => c.method == 'open').map(urlOf),
        [contains(holder), contains(waiter)],
        reason: 'waiting itself never opens another challenge',
      );
    });

    test('busy without a holder known to this isolate has no signal', () async {
      final waiter = 'orphan-${counter++}';
      mockPanel((call) async => call.method == 'open' ? 'busy' : null);
      final result = await resolve(waiter).timeout(const Duration(seconds: 2));
      expect(result.panelBusy, isTrue);
      expect(result.panelReleased, isNull);
      expect(identical(result, ExtensionVerificationResult.busy), isTrue);
      expect(await awaitVerificationPanelRelease(result), isFalse);
    });

    test('concurrent busy replies behind an unknown holder signal nothing',
        () async {
      // Native's slot is held by a request unknown to this isolate. Two opens
      // are in flight together and both are answered `busy`, first then
      // second: neither reply may count as the other's release.
      final first = 'race-first-${counter++}';
      final second = 'race-second-${counter++}';
      final firstArrived = Completer<void>();
      final secondArrived = Completer<void>();
      final firstGate = Completer<Object?>();
      final secondGate = Completer<Object?>();
      addTearDown(() {
        for (final gate in [firstGate, secondGate]) {
          if (!gate.isCompleted) gate.complete('busy');
        }
      });
      mockPanel((call) async {
        if (call.method != 'open') return null;
        if (urlOf(call).contains(first)) {
          firstArrived.complete();
          return firstGate.future;
        }
        secondArrived.complete();
        return secondGate.future;
      });

      final firstFlow = resolve(first);
      await firstArrived.future.timeout(const Duration(seconds: 2));
      final secondFlow = resolve(second);
      await secondArrived.future.timeout(const Duration(seconds: 2));

      firstGate.complete('busy');
      final firstResult = await firstFlow.timeout(const Duration(seconds: 2));
      secondGate.complete('busy');
      final secondResult = await secondFlow.timeout(const Duration(seconds: 2));

      for (final result in [firstResult, secondResult]) {
        expect(result.panelBusy, isTrue);
        expect(result.panelReleased, isNull);
        expect(await awaitVerificationPanelRelease(result), isFalse);
      }
      expect(
        panelCalls.where((c) => c.method == 'open').map(urlOf),
        [contains(first), contains(second)],
      );
    });

    test('a pending candidate that turns out busy never signals release',
        () async {
      // Same unknown holder, but the later request is answered first: its
      // only candidate is still in flight, so the signal is pending, and it
      // must end as "no release" once that candidate is also `busy`.
      final first = 'late-first-${counter++}';
      final second = 'late-second-${counter++}';
      final firstArrived = Completer<void>();
      final firstGate = Completer<Object?>();
      addTearDown(() {
        if (!firstGate.isCompleted) firstGate.complete('busy');
      });
      mockPanel((call) async {
        if (call.method != 'open') return null;
        if (urlOf(call).contains(first)) {
          firstArrived.complete();
          return firstGate.future;
        }
        return 'busy';
      });

      final firstFlow = resolve(first);
      await firstArrived.future.timeout(const Duration(seconds: 2));
      final secondResult = await resolve(
        second,
      ).timeout(const Duration(seconds: 2));
      expect(secondResult.panelBusy, isTrue);
      expect(secondResult.panelReleased, isNotNull);

      final waiting = awaitVerificationPanelRelease(
        secondResult,
        timeout: const Duration(seconds: 5),
      );
      firstGate.complete('busy');
      expect(
        await waiting.timeout(const Duration(seconds: 1)),
        isFalse,
        reason: 'a busy reply is not proof that its request held the slot',
      );
      final firstResult = await firstFlow.timeout(const Duration(seconds: 2));
      expect(firstResult.panelReleased, isNull);
    });

    test('holder answered before the busy reply resolves at once', () async {
      final holder = 'early-holder-${counter++}';
      final waiter = 'early-waiter-${counter++}';
      final holderReply = Completer<Object?>();
      final holderOpened = Completer<void>();
      addTearDown(() {
        if (!holderReply.isCompleted) holderReply.complete('closed');
      });
      mockPanel((call) async {
        if (call.method != 'open') return null;
        if (urlOf(call).contains(holder)) {
          holderOpened.complete();
          return holderReply.future;
        }
        // Native rejected this request while the holder was pending, but the
        // holder's own reply reaches Dart first.
        holderReply.complete('closed');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'busy';
      });

      final holderFlow = resolve(holder);
      await holderOpened.future.timeout(const Duration(seconds: 2));
      final busy = await resolve(waiter).timeout(const Duration(seconds: 2));
      await holderFlow.timeout(const Duration(seconds: 2));

      expect(busy.panelBusy, isTrue);
      expect(busy.panelReleased, isNotNull);
      expect(
        await awaitVerificationPanelRelease(
          busy,
          timeout: const Duration(milliseconds: 200),
        ),
        isTrue,
      );
    });
  });
}
