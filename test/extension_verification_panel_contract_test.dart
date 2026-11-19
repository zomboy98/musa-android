import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/utils/desktop_platform.dart';

/// Observes one `resolveExtensionVerification` call without awaiting it.
///
/// Awaiting the flow directly inside `testWidgets` never resumes: its mocked
/// channel replies and `Future.any` hops are fake-zone microtasks that only
/// `tester.pump` flushes. The flow is therefore started un-awaited and driven
/// by the `settle` helper inside `main`.
class _FlowProbe {
  ExtensionVerificationResult? result;
  Object? error;
  StackTrace? stackTrace;
  bool get done => result != null || error != null;
}

/// Contract between the native `verification_panel` channel and Dart.
/// Deterministic: mocked channels only, fake time, no network or device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backend = MethodChannel('com.zarz.mornye/backend');
  const panel = MethodChannel('com.zarz.mornye/verification_panel');
  const browser = MethodChannel('plugins.flutter.io/url_launcher');

  group('VerificationPanelReply.parse', () {
    test('maps native status strings', () {
      expect(
        VerificationPanelReply.parse('granted'),
        VerificationPanelReply.granted,
      );
      expect(
        VerificationPanelReply.parse('closed'),
        VerificationPanelReply.closed,
      );
      expect(
        VerificationPanelReply.parse('error'),
        VerificationPanelReply.error,
      );
      expect(VerificationPanelReply.parse('busy'), VerificationPanelReply.busy);
      expect(
        VerificationPanelReply.parse('unavailable'),
        VerificationPanelReply.unavailable,
      );
    });

    test('keeps the legacy boolean/null contract', () {
      expect(
        VerificationPanelReply.parse(true),
        VerificationPanelReply.granted,
      );
      expect(
        VerificationPanelReply.parse(false),
        VerificationPanelReply.closed,
      );
      expect(
        VerificationPanelReply.parse(null),
        VerificationPanelReply.unavailable,
      );
    });

    test('unknown replies are conservative (treated as shown)', () {
      expect(
        VerificationPanelReply.parse('future-status'),
        VerificationPanelReply.error,
      );
      expect(VerificationPanelReply.parse(3), VerificationPanelReply.error);
    });

    test('only granted/closed/error count as presented', () {
      expect(VerificationPanelReply.values.where((r) => r.shown), [
        VerificationPanelReply.granted,
        VerificationPanelReply.closed,
        VerificationPanelReply.error,
      ]);
    });
  });

  group('resolveExtensionVerification with the Android panel', () {
    // Each test uses its own extension id: shared flows are keyed per id.
    var counter = 0;
    late String extensionId;
    late List<MethodCall> panelCalls;

    Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
      MaterialApp(
        navigatorKey: AppNavigationService.rootNavigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: Text('Library')),
      ),
    );

    void androidPanelTest(
      String description,
      Future<void> Function(WidgetTester tester) body,
    ) {
      testWidgets(
        description,
        (tester) async {
          debugDefaultTargetPlatformOverride = TargetPlatform.android;
          debugDesktopPlatformOverride = false;
          extensionId = 'contract-${counter++}';
          panelCalls = [];
          final messenger = tester.binding.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(browser, (_) async {
            fail('Embedded verification must never open a browser');
          });
          try {
            await pumpApp(tester);
            await body(tester);
            await tester.pumpWidget(const SizedBox.shrink());
          } finally {
            for (final channel in [backend, panel, browser]) {
              messenger.setMockMethodCallHandler(channel, null);
            }
            // Reset inside the body: flutter_test checks debug variables before
            // tearDown runs.
            debugDefaultTargetPlatformOverride = null;
            debugDesktopPlatformOverride = null;
          }
        },
        skip: !embeddedExtensionVerificationEnabled,
        // Real-time guard: a regression fails instead of hanging the suite.
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }

    void mockChallenge(WidgetTester tester) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        backend,
        (call) async => call.method == 'getExtensionPendingAuth'
            ? {'auth_url': 'https://example.invalid/verify?state=contract'}
            : null,
      );
    }

    void mockPanel(
      WidgetTester tester,
      Future<Object?> Function(MethodCall call) reply,
    ) {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(panel, (
        call,
      ) {
        panelCalls.add(call);
        return reply(call);
      });
    }

    // Starts the flow without awaiting it (see [_FlowProbe]).
    _FlowProbe startFlow({bool quiet = false}) {
      final probe = _FlowProbe();
      unawaited(
        resolveExtensionVerification(
          extensionId,
          browserMode: 'in_app_first',
          quietUnavailable: quiet,
        ).then<void>(
          (value) => probe.result = value,
          onError: (Object error, StackTrace stackTrace) {
            probe.error = error;
            probe.stackTrace = stackTrace;
          },
        ),
      );
      return probe;
    }

    // One deterministic turn: flush fake-zone microtasks and frames, then give
    // the real zone one event-loop turn for anything scheduled outside the
    // fake zone. Never blocks: both calls complete on their own.
    Future<void> turn(WidgetTester tester) async {
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    }

    // Drives the flow to completion with a bounded number of turns. If it
    // does not settle, the flow's own 3-minute deadline is fired so no fake
    // timer or panel request is left behind, and the test fails with context
    // instead of hanging.
    Future<ExtensionVerificationResult> settle(
      WidgetTester tester,
      _FlowProbe probe, {
      int maxTurns = 100,
    }) async {
      for (var i = 0; i < maxTurns && !probe.done; i++) {
        await turn(tester);
      }
      if (!probe.done) {
        await tester.pump(extensionVerificationGrantTimeout);
        for (var i = 0; i < 20 && !probe.done; i++) {
          await turn(tester);
        }
        fail(
          'Verification flow did not settle after $maxTurns turns '
          '(panel calls: ${panelCalls.map((c) => c.method).toList()})',
        );
      }
      // Let a shown SnackBar mount (or confirm none appears).
      await tester.pump();
      final error = probe.error;
      if (error != null) {
        Error.throwWithStackTrace(
          error,
          probe.stackTrace ?? StackTrace.current,
        );
      }
      return probe.result!;
    }

    Future<ExtensionVerificationResult> resolve(
      WidgetTester tester, {
      bool quiet = false,
    }) => settle(tester, startFlow(quiet: quiet));

    // (1) Native showFailure after the panel was presented answers `error`.
    androidPanelTest(
      'error after presentation is an interaction, not "unavailable"',
      (tester) async {
        mockChallenge(tester);
        mockPanel(tester, (_) async => 'error');
        final result = await resolve(tester, quiet: true);
        expect(result.successful, isFalse);
        expect(result.interactionShown, isTrue);
        expect(result.blocksProviderFallback, isTrue);
        expect(panelCalls.map((c) => c.method), ['open']);
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    androidPanelTest('closed panel blocks fallback', (tester) async {
      mockChallenge(tester);
      mockPanel(tester, (_) async => 'closed');
      final result = await resolve(tester, quiet: true);
      expect(result.interactionShown, isTrue);
      expect(result.blocksProviderFallback, isTrue);
    });

    // (4) Busy is distinct from unavailable.
    androidPanelTest('busy panel blocks fallback and shows no message', (
      tester,
    ) async {
      mockChallenge(tester);
      mockPanel(tester, (_) async => 'busy');
      final result = await resolve(tester);
      expect(result.panelBusy, isTrue);
      expect(result.interactionShown, isFalse);
      expect(result.blocksProviderFallback, isTrue);
      expect(
        find.byType(SnackBar),
        findsNothing,
        reason: 'a panel is already on screen; "unavailable" would be false',
      );
    });

    // (5) quietUnavailable in every branch, with a non-quiet control.
    for (final reply in <Object?>['unavailable', null]) {
      androidPanelTest(
        'panel $reply without quiet is still silent (embedded is always quiet)',
        (tester) async {
          mockChallenge(tester);
          mockPanel(tester, (_) async => reply);
          final result = await resolve(tester);
          expect(result.blocksProviderFallback, isFalse);
          expect(find.byType(SnackBar), findsNothing);
        },
      );

      androidPanelTest(
        'panel $reply with quietUnavailable stays silent and allows fallback',
        (tester) async {
          mockChallenge(tester);
          mockPanel(tester, (_) async => reply);
          final result = await resolve(tester, quiet: true);
          expect(result.successful, isFalse);
          expect(result.blocksProviderFallback, isFalse);
          expect(find.byType(SnackBar), findsNothing);
        },
      );
    }

    androidPanelTest('panel PlatformException with quiet stays silent', (
      tester,
    ) async {
      mockChallenge(tester);
      mockPanel(tester, (_) async => throw PlatformException(code: 'boom'));
      final result = await resolve(tester, quiet: true);
      expect(result.blocksProviderFallback, isFalse);
      expect(find.byType(SnackBar), findsNothing);
    });

    androidPanelTest(
      'lookup failure with quiet stays silent and allows fallback',
      (tester) async {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          backend,
          (_) async => throw PlatformException(code: 'lookup_failed'),
        );
        mockPanel(tester, (_) async => fail('no challenge, no panel'));
        final result = await resolve(tester, quiet: true);
        expect(result.blocksProviderFallback, isFalse);
        expect(result.lookupError, isA<PlatformException>());
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    // (2) Timeout while the panel request is unanswered (panel on screen).
    androidPanelTest(
      'timeout while the panel may be visible blocks fallback and closes it',
      (tester) async {
        mockChallenge(tester);
        final pendingOpen = Completer<Object?>();
        // Never leave the native panel request unanswered, even on failure.
        addTearDown(() {
          if (!pendingOpen.isCompleted) pendingOpen.complete('closed');
        });
        mockPanel(tester, (call) async {
          if (call.method == 'open') return pendingOpen.future;
          expect(call.method, 'close');
          if (!pendingOpen.isCompleted) pendingOpen.complete('closed');
          return null;
        });
        final probe = startFlow(quiet: true);
        await turn(tester);
        await turn(tester);
        expect(panelCalls.map((c) => c.method), ['open']);
        expect(probe.done, isFalse);

        await tester.pump(extensionVerificationGrantTimeout);
        final result = await settle(tester, probe);

        expect(
          result.interactionShown,
          isTrue,
          reason: 'an unanswered open may be on screen: never fall back',
        );
        expect(result.blocksProviderFallback, isTrue);
        expect(panelCalls.map((c) => c.method), ['open', 'close']);
        expect(
          (panelCalls[1].arguments as Map)['id'],
          (panelCalls[0].arguments as Map)['id'],
          reason: "only the flow's own panel is closed",
        );
        expect(find.byType(SnackBar), findsNothing);
      },
    );

    androidPanelTest(
      'unavailable before dispatch timeout does not block fallback',
      (tester) async {
        // Control for the conservative rule: a stalled lookup (no panel
        // request ever sent) times out as an invisible failure.
        final stalled = Completer<Object?>();
        // Release the stalled lookup even if an assertion fails first.
        addTearDown(() {
          if (!stalled.isCompleted) stalled.complete(null);
        });
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          backend,
          (_) => stalled.future,
        );
        mockPanel(tester, (_) async => fail('no challenge, no panel'));
        final probe = startFlow(quiet: true);
        await turn(tester);
        expect(probe.done, isFalse, reason: 'the lookup is still stalled');
        await tester.pump(extensionVerificationGrantTimeout);
        final result = await settle(tester, probe);
        expect(result.blocksProviderFallback, isFalse);
        expect(panelCalls, isEmpty);
        stalled.complete(null);
        await turn(tester);
        expect(find.byType(SnackBar), findsNothing);
      },
    );
  });
}
