import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/services/verification_contract.dart';
import 'package:mornye/widgets/verification_notice.dart';

class _FakeFacade implements VerificationFacade {
  _FakeFacade(this.handler);

  final Future<VerificationOutcome> Function(String operationId) handler;
  final List<String> calls = [];

  @override
  Future<VerificationOutcome> verifyAndResume(String operationId) {
    calls.add(operationId);
    return handler(operationId);
  }
}

const _required = VerificationRequired(
  operationId: 'op-1',
  extensionId: 'provider',
  providerName: 'Proveedor X',
  kind: VerificationOperation.playlist,
);

Widget _host(_FakeFacade facade, {VoidCallback? onRetry}) => ProviderScope(
  overrides: [verificationFacadeProvider.overrideWithValue(facade)],
  child: MaterialApp(
    locale: const Locale('es', 'ES'),
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: VerificationNotice(
        verification: _required,
        onRetry: onRetry ?? () {},
      ),
    ),
  ),
);

Future<void> _tapVerify(WidgetTester tester) async {
  await tester.tap(find.text('Verificar'));
  await tester.pump();
  await tester.pump();
}

const _failedText = 'No se completó la verificación. Inténtalo de nuevo.';
const _noticeText = 'Proveedor X pide verificar tu acceso.';

void main() {
  testWidgets('shows the provider name and does not verify before the tap', (
    tester,
  ) async {
    final facade = _FakeFacade((_) async => VerificationOutcome.resumed);
    await tester.pumpWidget(_host(facade));
    expect(find.text(_noticeText), findsOneWidget);
    expect(find.text('Verificar'), findsOneWidget);
    expect(facade.calls, isEmpty);
  });

  testWidgets('a double tap joins the attempt in progress', (tester) async {
    final completer = Completer<VerificationOutcome>();
    final facade = _FakeFacade((_) => completer.future);
    await tester.pumpWidget(_host(facade));
    await tester.tap(find.text('Verificar'));
    await tester.pump();
    expect(find.text('Verificando…'), findsOneWidget);
    await tester.tap(find.text('Verificando…'), warnIfMissed: false);
    await tester.pump();
    expect(facade.calls, ['op-1']);
    completer.complete(VerificationOutcome.cancelled);
    await tester.pump();
  });

  testWidgets('cancelled returns to the notice without an error', (
    tester,
  ) async {
    final facade = _FakeFacade((_) async => VerificationOutcome.cancelled);
    await tester.pumpWidget(_host(facade));
    await _tapVerify(tester);
    expect(find.text(_noticeText), findsOneWidget);
    expect(find.text(_failedText), findsNothing);
    expect(find.text('Verificar'), findsOneWidget);
  });

  testWidgets('expired shows its message and a normal retry', (tester) async {
    var retries = 0;
    final facade = _FakeFacade((_) async => VerificationOutcome.expired);
    await tester.pumpWidget(_host(facade, onRetry: () => retries++));
    await _tapVerify(tester);
    expect(
      find.text('Esta solicitud ya no está vigente. Vuelve a intentarlo.'),
      findsOneWidget,
    );
    expect(find.text('Verificar'), findsNothing);
    await tester.tap(find.text('Reintentar'));
    expect(retries, 1);
  });

  testWidgets('failed shows its message and allows another attempt', (
    tester,
  ) async {
    final facade = _FakeFacade((_) async => VerificationOutcome.failed);
    await tester.pumpWidget(_host(facade));
    await _tapVerify(tester);
    expect(find.text(_failedText), findsOneWidget);
    expect(find.text('Verificar'), findsOneWidget);
  });

  testWidgets('a thrown error counts as failed', (tester) async {
    final facade = _FakeFacade((_) async => throw StateError('x'));
    await tester.pumpWidget(_host(facade));
    await _tapVerify(tester);
    expect(find.text(_failedText), findsOneWidget);
  });

  testWidgets('resumed shows progress and announces no success', (
    tester,
  ) async {
    final facade = _FakeFacade((_) async => VerificationOutcome.resumed);
    await tester.pumpWidget(_host(facade));
    await _tapVerify(tester);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Verificar'), findsNothing);
    expect(find.text(_failedText), findsNothing);
  });

  test('null, timeout and network failures are not an explicit request', () {
    expect(
      isExplicitVerificationRequired(Exception('getPlaylist returned null')),
      isFalse,
    );
    expect(isExplicitVerificationRequired(TimeoutException('t')), isFalse);
    expect(
      isExplicitVerificationRequired(Exception('SocketException: network')),
      isFalse,
    );
    expect(
      isExplicitVerificationRequired(
        Exception('error_type: verification_required'),
      ),
      isTrue,
    );
  });

  group('InterimVerificationFacade', () {
    test('resumes once for a live operation and then expires it', () async {
      var resumes = 0;
      var opens = 0;
      final facade = InterimVerificationFacade(
        openVerification: (id, cancellation) async {
          opens++;
          return true;
        },
      );
      final op = facade.begin(
        extensionId: 'p',
        providerName: 'P',
        kind: VerificationOperation.track,
        resume: () => resumes++,
      );
      final first = facade.verifyAndResume(op.operationId);
      final second = facade.verifyAndResume(op.operationId);
      expect(await first, VerificationOutcome.resumed);
      expect(await second, VerificationOutcome.resumed);
      expect(opens, 1);
      expect(resumes, 1);
      expect(
        await facade.verifyAndResume(op.operationId),
        VerificationOutcome.expired,
      );
      expect(opens, 1);
    });

    test('false maps to failed without resuming', () async {
      var resumes = 0;
      final facade = InterimVerificationFacade(
        openVerification: (id, cancellation) async => false,
      );
      final op = facade.begin(
        extensionId: 'p',
        providerName: 'P',
        kind: VerificationOperation.track,
        resume: () => resumes++,
      );
      expect(
        await facade.verifyAndResume(op.operationId),
        VerificationOutcome.failed,
      );
      expect(resumes, 0);
    });

    test('cancel maps to cancelled and a released one to expired', () async {
      final gate = Completer<bool>();
      final facade = InterimVerificationFacade(
        openVerification: (id, cancellation) => gate.future,
      );
      final op = facade.begin(
        extensionId: 'p',
        providerName: 'P',
        kind: VerificationOperation.track,
        resume: () {},
      );
      final pending = facade.verifyAndResume(op.operationId);
      facade.cancel(op.operationId);
      gate.complete(false);
      expect(await pending, VerificationOutcome.cancelled);

      final other = facade.begin(
        extensionId: 'q',
        providerName: 'Q',
        kind: VerificationOperation.track,
        resume: () {},
      );
      facade.release(other.operationId);
      expect(
        await facade.verifyAndResume(other.operationId),
        VerificationOutcome.expired,
      );
    });

    test('a late result of a superseded operation does not resume', () async {
      final gate = Completer<bool>();
      final resumed = <String>[];
      final facade = InterimVerificationFacade(
        openVerification: (id, cancellation) => gate.future,
      );
      final old = facade.begin(
        extensionId: 'p',
        providerName: 'P',
        kind: VerificationOperation.playlist,
        resume: () => resumed.add('old'),
      );
      final pending = facade.verifyAndResume(old.operationId);
      facade.begin(
        extensionId: 'p',
        providerName: 'P',
        kind: VerificationOperation.playlist,
        resume: () => resumed.add('new'),
      );
      gate.complete(true);
      expect(await pending, VerificationOutcome.expired);
      expect(resumed, isEmpty);
    });
  });
}
