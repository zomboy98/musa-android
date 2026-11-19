import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/utils/download_error_type.dart';

void main() {
  test('typed provider auth errors override misleading verification text', () {
    for (final type in [
      'authentication_error',
      'PROVIDER_AUTH_FAILED',
      'request_auth_invalid',
      'provider_reauth_required',
    ]) {
      final errorType =
          downloadErrorTypeFromBackend(type) ??
          (isExtensionVerificationRequired('Verification required upstream')
              ? DownloadErrorType.verificationRequired
              : DownloadErrorType.unknown);
      expect(errorType, DownloadErrorType.unknown, reason: type);
    }
    expect(downloadErrorTypeFromBackend(null), isNull);
    expect(downloadErrorTypeFromBackend('unknown'), isNull);
    expect(
      downloadErrorTypeFromBackend('verification_required'),
      DownloadErrorType.verificationRequired,
    );
  });

  test('provider auth and HTTP status errors do not imply verification', () {
    for (final message in [
      'Provider unauthorized',
      'HTTP 401 for /download',
      'HTTP status 428: precondition required',
      'PROVIDER_AUTH_FAILED: unauthorized',
    ]) {
      expect(
        isExtensionVerificationRequired(message),
        isFalse,
        reason: message,
      );
    }
    for (final message in [
      'verification_required: canonical gateway challenge',
      'VERIFY_REQUIRED',
      'signed session is not authenticated',
      'signed session expired',
    ]) {
      expect(isExtensionVerificationRequired(message), isTrue, reason: message);
    }
  });

  test(
    'does not open a verification flow for a provider authentication error',
    () async {
      var verificationCalls = 0;
      await expectLater(
        runExtensionOperationWithVerificationRetry<void>(
          extensionId: 'provider-a',
          browserMode: 'in_app_first',
          operation: () async => throw StateError('Provider unauthorized'),
          verify: () async {
            verificationCalls++;
            return true;
          },
        ),
        throwsStateError,
      );
      expect(verificationCalls, 0);
    },
  );

  test('verification challenge expires after three minutes', () {
    expect(extensionVerificationGrantTimeout, const Duration(minutes: 3));
  });

  test('extracts the extension that raised a verification challenge', () {
    expect(
      extensionIdFromVerificationError(
        "verification_required: extension 'provider-b' needs verification",
        const ['provider-a', 'provider-b'],
      ),
      'provider-b',
    );
  });

  test('prefers the longest known extension id in legacy errors', () {
    expect(
      extensionIdFromVerificationError(
        'sample-provider verification_required',
        const ['sample', 'sample-provider'],
      ),
      'sample-provider',
    );
  });

  test(
    'retries an extension operation after successful verification',
    () async {
      var operationCalls = 0;
      var verificationCalls = 0;

      final result = await runExtensionOperationWithVerificationRetry(
        extensionId: 'provider-a',
        browserMode: 'in_app_first',
        operation: () async {
          operationCalls++;
          if (operationCalls == 1) throw Exception('VERIFY_REQUIRED');
          return 'artist metadata';
        },
        verify: () async {
          verificationCalls++;
          return true;
        },
      );

      expect(result, 'artist metadata');
      expect(operationCalls, 2);
      expect(verificationCalls, 1);
    },
  );

  test('does not retry when extension verification is not completed', () async {
    var operationCalls = 0;

    await expectLater(
      runExtensionOperationWithVerificationRetry(
        extensionId: 'provider-a',
        browserMode: 'in_app_first',
        operation: () async {
          operationCalls++;
          throw Exception('VERIFY_REQUIRED');
        },
        verify: () async => false,
      ),
      throwsA(isA<Exception>()),
    );

    expect(operationCalls, 1);
  });

  test('verification wait can be cancelled before foreground resume', () async {
    final foreground = Completer<void>();
    final cancellation = Completer<void>();
    final result = openVerificationAndAwaitGrant(
      'provider-a',
      browserMode: 'in_app_first',
      awaitForeground: (_) => foreground.future,
      cancellationSignal: cancellation.future,
    );

    cancellation.complete();

    expect(await result.timeout(const Duration(seconds: 1)), isFalse);
  });

  test('same provider shares a flow with independent cancellation', () async {
    final foreground = Completer<void>();
    final firstCancel = Completer<void>();
    final secondCancel = Completer<void>();
    var starts = 0;
    Future<void> wait(String _) {
      starts++;
      return foreground.future;
    }

    final first = openVerificationAndAwaitGrant(
      'Provider-Race',
      browserMode: 'in_app_first',
      awaitForeground: wait,
      cancellationSignal: firstCancel.future,
    );
    final second = openVerificationAndAwaitGrant(
      'provider-race',
      browserMode: 'in_app_first',
      awaitForeground: wait,
      cancellationSignal: secondCancel.future,
    );
    expect(starts, 1);
    firstCancel.complete();
    expect(await first, isFalse);
    var secondFinished = false;
    second.then((_) => secondFinished = true);
    await Future<void>.delayed(Duration.zero);
    expect(secondFinished, isFalse);
    secondCancel.complete();
    expect(await second, isFalse);
  });

  test('last cancellation permits a fresh flow', () async {
    final foreground = Completer<void>();
    final firstCancel = Completer<void>();
    final secondCancel = Completer<void>();
    var starts = 0;
    Future<void> wait(String _) {
      starts++;
      return foreground.future;
    }

    final first = openVerificationAndAwaitGrant(
      'provider-fresh',
      browserMode: 'in_app_first',
      awaitForeground: wait,
      cancellationSignal: firstCancel.future,
    );
    firstCancel.complete();
    expect(await first, isFalse);
    final second = openVerificationAndAwaitGrant(
      'provider-fresh',
      browserMode: 'in_app_first',
      awaitForeground: wait,
      cancellationSignal: secondCancel.future,
    );
    expect(starts, 2);
    secondCancel.complete();
    expect(await second, isFalse);
  });
}
