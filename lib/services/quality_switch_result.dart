import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/failure_cause.dart';

enum QualitySwitchFailure {
  unavailable,
  timedOut,
  unsupportedFormat,
  verificationRequired,
  cancelled,
  other,
}

/// How a live quality switch ended. Carries only a category and, when the
/// provider needs a verification, its id; never URLs, paths or credentials.
class QualitySwitchResult {
  const QualitySwitchResult.success() : failure = null, providerId = null;
  const QualitySwitchResult.failed(this.failure, {this.providerId});

  final QualitySwitchFailure? failure;
  final String? providerId;

  bool get ok => failure == null;

  @override
  bool operator ==(Object other) =>
      other is QualitySwitchResult &&
      other.failure == failure &&
      other.providerId == providerId;

  @override
  int get hashCode => Object.hash(failure, providerId);

  @override
  String toString() =>
      ok ? 'QualitySwitchResult.ok' : 'QualitySwitchResult.${failure!.name}';
}

QualitySwitchFailure qualitySwitchFailureForReason(String reason) {
  if (reason == failureReasonCancelled) return QualitySwitchFailure.cancelled;
  return switch (failureCauseForReason(reason)) {
    FailureCause.qualityUnavailable ||
    FailureCause.trackNotFound ||
    FailureCause.providersExhausted => QualitySwitchFailure.unavailable,
    FailureCause.providerTimedOut ||
    FailureCause.preparationTimedOut ||
    FailureCause.verificationTimedOut => QualitySwitchFailure.timedOut,
    FailureCause.unsupportedFormat ||
    FailureCause.encryptedUnsupported => QualitySwitchFailure.unsupportedFormat,
    FailureCause.verificationRequired =>
      QualitySwitchFailure.verificationRequired,
    _ => QualitySwitchFailure.other,
  };
}

QualitySwitchResult qualitySwitchResultForError(
  Object error, {
  String? verificationProvider,
}) {
  final String reason;
  String? providerId;
  if (error is CatalogPlaybackException) {
    reason = error.category;
  } else if (error is TemporaryTrackException) {
    reason = error.reason;
    if (error is TemporaryVerificationRequired) providerId = error.extensionId;
  } else {
    return const QualitySwitchResult.failed(QualitySwitchFailure.other);
  }
  final failure = qualitySwitchFailureForReason(reason);
  if (failure == QualitySwitchFailure.verificationRequired) {
    final id = providerId ?? verificationProvider;
    return QualitySwitchResult.failed(
      failure,
      providerId: id == null || id.trim().isEmpty ? null : id.trim(),
    );
  }
  return QualitySwitchResult.failed(failure);
}
