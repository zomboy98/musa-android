import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/settings_provider.dart';

enum VerificationOperation { track, playlist, other }

enum VerificationOutcome { resumed, cancelled, expired, failed }

class VerificationRequired {
  const VerificationRequired({
    required this.operationId,
    required this.extensionId,
    required this.providerName,
    required this.kind,
  });

  final String operationId;
  final String extensionId;
  final String providerName;
  final VerificationOperation kind;
}

abstract interface class VerificationFacade {
  Future<VerificationOutcome> verifyAndResume(String operationId);
}

bool isExplicitVerificationRequired(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('verification_required') ||
      message.contains('verify_required');
}

class _InterimOperation {
  _InterimOperation(this.required, this.resume);

  final VerificationRequired required;
  final FutureOr<void> Function() resume;
  final Completer<void> cancellation = Completer<void>();
  Future<VerificationOutcome>? inFlight;
  bool cancelled = false;
}

class InterimVerificationFacade implements VerificationFacade {
  InterimVerificationFacade({required this.openVerification});

  final Future<bool> Function(String extensionId, Future<void> cancellation)
  openVerification;

  final Map<String, _InterimOperation> _operations = {};
  int _sequence = 0;

  VerificationRequired begin({
    required String extensionId,
    required String providerName,
    required VerificationOperation kind,
    required FutureOr<void> Function() resume,
  }) {
    final superseded = _operations.values
        .where(
          (op) =>
              op.required.extensionId == extensionId &&
              op.required.kind == kind,
        )
        .map((op) => op.required.operationId)
        .toList();
    superseded.forEach(release);
    final required = VerificationRequired(
      operationId: 'op-${++_sequence}',
      extensionId: extensionId,
      providerName: providerName,
      kind: kind,
    );
    _operations[required.operationId] = _InterimOperation(required, resume);
    return required;
  }

  void release(String operationId) {
    final op = _operations.remove(operationId);
    if (op != null && !op.cancellation.isCompleted) {
      op.cancellation.complete();
    }
  }

  void cancel(String operationId) {
    final op = _operations[operationId];
    if (op == null) return;
    op.cancelled = true;
    if (!op.cancellation.isCompleted) op.cancellation.complete();
  }

  @override
  Future<VerificationOutcome> verifyAndResume(String operationId) {
    final op = _operations[operationId];
    if (op == null) return Future.value(VerificationOutcome.expired);
    return op.inFlight ??= _run(op).whenComplete(() => op.inFlight = null);
  }

  Future<VerificationOutcome> _run(_InterimOperation op) async {
    var verified = false;
    try {
      verified = await openVerification(
        op.required.extensionId,
        op.cancellation.future,
      );
    } catch (_) {
      verified = false;
    }
    final id = op.required.operationId;
    if (op.cancelled) {
      _operations.remove(id);
      return VerificationOutcome.cancelled;
    }
    if (!identical(_operations[id], op)) return VerificationOutcome.expired;
    if (!verified) return VerificationOutcome.failed;
    _operations.remove(id);
    unawaited(Future<void>.sync(op.resume).catchError((_) {}));
    return VerificationOutcome.resumed;
  }
}

final interimVerificationFacadeProvider = Provider<InterimVerificationFacade>(
  (ref) => InterimVerificationFacade(
    openVerification: (extensionId, cancellation) =>
        openVerificationAndAwaitGrant(
          extensionId,
          browserMode: ref
              .read(settingsProvider)
              .extensionVerificationBrowserMode,
          cancellationSignal: cancellation,
        ),
  ),
);

final verificationFacadeProvider = Provider<VerificationFacade>(
  (ref) => ref.watch(interimVerificationFacadeProvider),
);
