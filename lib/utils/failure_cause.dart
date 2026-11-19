import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';

enum FailureCause {
  providerFailed,
  trackNotFound,
  providerUnavailable,
  providerOffline,
  verificationRequired,
  verificationTimedOut,
  sessionExpired,
  reauthRequired,
  qualityUnavailable,
  rateLimited,
  subscriptionRequired,
  ispBlocked,
  networkFailed,
  providerTimedOut,
  streamExpired,
  storageFailed,
  preparationTimedOut,
  providersExhausted,
  encryptedUnsupported,
  invalidOutput,
  finalizationFailed,
  conversionFailed,
  unsupportedFormat,
  localFileUnavailable,
  downloadFailed,
  downloadDecryptFailed,
  downloadConvertFailed,
  downloadLibraryFailed,
  downloadFolderAccess,
  generic,
}

const catalogFailurePrefix = 'CatalogPlaybackException: ';
const localFileUnavailableText = 'El archivo local no está disponible.';
const failureReasonCancelled = 'cancelled';
const failureReasonGeneric = 'preparation failed';
const failureReasonProvidersExhausted = 'providers exhausted';

const _reasonCauses = <String, FailureCause>{
  'provider download failed': FailureCause.providerFailed,
  'provider track not found': FailureCause.trackNotFound,
  'provider unavailable': FailureCause.providerUnavailable,
  'provider intervention required': FailureCause.verificationRequired,
  'verification timed out': FailureCause.verificationTimedOut,
  'provider session expired': FailureCause.sessionExpired,
  'provider reauth required': FailureCause.reauthRequired,
  'provider quality unavailable': FailureCause.qualityUnavailable,
  'provider rate limited': FailureCause.rateLimited,
  'provider subscription required': FailureCause.subscriptionRequired,
  'provider network blocked': FailureCause.ispBlocked,
  'provider network failed': FailureCause.networkFailed,
  'provider timed out': FailureCause.providerTimedOut,
  'provider stream expired': FailureCause.streamExpired,
  'provider storage failed': FailureCause.storageFailed,
  'preparation timed out': FailureCause.preparationTimedOut,
  failureReasonProvidersExhausted: FailureCause.providersExhausted,
  'encrypted output unsupported': FailureCause.encryptedUnsupported,
  'invalid provider output': FailureCause.invalidOutput,
  'invalid audio output': FailureCause.invalidOutput,
  'invalid temporary copy': FailureCause.invalidOutput,
  'audio stream not identified': FailureCause.invalidOutput,
  'progressive position unavailable': FailureCause.finalizationFailed,
  'finalization failed': FailureCause.finalizationFailed,
  'invalid finalization output': FailureCause.finalizationFailed,
  'AC-4 repair failed': FailureCause.finalizationFailed,
  'private finalization unavailable': FailureCause.finalizationFailed,
  'AAC conversion failed': FailureCause.conversionFailed,
  'invalid AAC output': FailureCause.conversionFailed,
  'Opus conversion failed': FailureCause.conversionFailed,
  'invalid Opus output': FailureCause.conversionFailed,
  'flac remux failed': FailureCause.conversionFailed,
  'unsupported audio format': FailureCause.unsupportedFormat,
};

FailureCause? failureCauseForReason(String reason) => _reasonCauses[reason];

bool isKnownFailureReason(String reason) =>
    reason == failureReasonCancelled || _reasonCauses.containsKey(reason);

const providerResultReasons = <String>{
  'provider download failed',
  'provider track not found',
  'provider unavailable',
  'provider intervention required',
  'provider session expired',
  'provider reauth required',
  'provider quality unavailable',
  'provider rate limited',
  'provider subscription required',
  'provider network blocked',
  'provider network failed',
  'provider timed out',
  'provider stream expired',
  'provider storage failed',
  'encrypted output unsupported',
  failureReasonCancelled,
};

const formatFailureReasons = <String>{
  'provider quality unavailable',
  'invalid provider output',
  'invalid audio output',
  'invalid temporary copy',
  'audio stream not identified',
  'unsupported audio format',
  'flac remux failed',
  'finalization failed',
  'invalid finalization output',
  'AC-4 repair failed',
  'AAC conversion failed',
  'invalid AAC output',
  'Opus conversion failed',
  'invalid Opus output',
};

String providerFailureReasonFor(String errorType) => switch (errorType) {
  'verification_required' => 'provider intervention required',
  'auth' ||
  'authentication_error' ||
  'provider_auth_failed' ||
  'request_auth_invalid' => 'provider session expired',
  'provider_reauth_required' => 'provider reauth required',
  'not_found' => 'provider track not found',
  'provider_unavailable' => 'provider unavailable',
  'quality_unavailable' => 'provider quality unavailable',
  'rate_limit' || 'rate_limited' => 'provider rate limited',
  'subscription_required' => 'provider subscription required',
  'isp_blocked' => 'provider network blocked',
  'network' || 'transient_network' => 'provider network failed',
  'timeout' => 'provider timed out',
  'expired_stream' => 'provider stream expired',
  'file_error' || 'storage_error' || 'permission' => 'provider storage failed',
  'integrity_failed' => 'invalid provider output',
  _ => 'provider download failed',
};

FailureCause? failureCauseForPlaybackError(String message) {
  if (message.startsWith(catalogFailurePrefix)) {
    final reason = message.substring(catalogFailurePrefix.length);
    return failureCauseForReason(reason) ?? FailureCause.generic;
  }
  if (message.contains(localFileUnavailableText)) {
    return FailureCause.localFileUnavailable;
  }
  return null;
}

FailureCause? failureCauseForDownload(DownloadErrorType? type) =>
    switch (type) {
      null || DownloadErrorType.unknown => null,
      DownloadErrorType.workerFailed ||
      DownloadErrorType.emptyResult => FailureCause.downloadFailed,
      DownloadErrorType.decryptFailed => FailureCause.downloadDecryptFailed,
      DownloadErrorType.conversionFailed => FailureCause.downloadConvertFailed,
      DownloadErrorType.libraryAddFailed => FailureCause.downloadLibraryFailed,
      DownloadErrorType.networkTransferFailed => FailureCause.networkFailed,
      DownloadErrorType.verificationRequired => null,
      DownloadErrorType.permission => FailureCause.downloadFolderAccess,
      DownloadErrorType.notFound => FailureCause.trackNotFound,
      DownloadErrorType.rateLimit => FailureCause.rateLimited,
      DownloadErrorType.network ||
      DownloadErrorType.transientNetwork => FailureCause.networkFailed,
      DownloadErrorType.subscriptionRequired =>
        FailureCause.subscriptionRequired,
      DownloadErrorType.expiredStream => FailureCause.streamExpired,
      DownloadErrorType.integrityFailed => FailureCause.invalidOutput,
      DownloadErrorType.authenticationError => FailureCause.sessionExpired,
      DownloadErrorType.providerReauthRequired => FailureCause.reauthRequired,
      DownloadErrorType.providerUnavailable => FailureCause.providerOffline,
      DownloadErrorType.fileError => FailureCause.storageFailed,
      DownloadErrorType.ispBlocked => FailureCause.ispBlocked,
      DownloadErrorType.qualityUnavailable => FailureCause.qualityUnavailable,
      DownloadErrorType.timeout => FailureCause.providerTimedOut,
      DownloadErrorType.httpError ||
      DownloadErrorType.notImplemented ||
      DownloadErrorType.invalidUrl ||
      DownloadErrorType.providerError => FailureCause.providerFailed,
    };

String failureL10nKey(FailureCause cause) => switch (cause) {
  FailureCause.providerFailed => 'playbackProviderFailed',
  FailureCause.trackNotFound => 'providerTrackNotFound',
  FailureCause.providerUnavailable => 'playbackProviderUnavailable',
  FailureCause.providerOffline => 'failureProviderOffline',
  FailureCause.verificationRequired => 'playbackVerificationRequired',
  FailureCause.verificationTimedOut => 'failureVerificationTimedOut',
  FailureCause.sessionExpired => 'failureSessionExpired',
  FailureCause.reauthRequired => 'failureReauthRequired',
  FailureCause.qualityUnavailable => 'failureQualityUnavailable',
  FailureCause.rateLimited => 'failureRateLimited',
  FailureCause.subscriptionRequired => 'failureSubscriptionRequired',
  FailureCause.ispBlocked => 'failureIspBlocked',
  FailureCause.networkFailed => 'failureNetwork',
  FailureCause.providerTimedOut => 'failureProviderTimedOut',
  FailureCause.streamExpired => 'failureStreamExpired',
  FailureCause.storageFailed => 'failureStorage',
  FailureCause.preparationTimedOut => 'failurePreparationTimedOut',
  FailureCause.providersExhausted => 'failureProvidersExhausted',
  FailureCause.encryptedUnsupported => 'failureEncryptedUnsupported',
  FailureCause.invalidOutput => 'failureInvalidOutput',
  FailureCause.finalizationFailed => 'failureFinalization',
  FailureCause.conversionFailed => 'playbackConversionFailed',
  FailureCause.unsupportedFormat => 'failureUnsupportedFormat',
  FailureCause.localFileUnavailable => 'failureLocalFileUnavailable',
  FailureCause.downloadFailed => 'failureDownloadFailed',
  FailureCause.downloadDecryptFailed => 'failureDownloadDecrypt',
  FailureCause.downloadConvertFailed => 'failureDownloadConvert',
  FailureCause.downloadLibraryFailed => 'failureDownloadLibrary',
  FailureCause.downloadFolderAccess => 'failureDownloadFolderAccess',
  FailureCause.generic => 'playbackPreparationFailed',
};

String failureMessage(AppLocalizations l10n, FailureCause cause) =>
    switch (cause) {
      FailureCause.providerFailed => l10n.playbackProviderFailed,
      FailureCause.trackNotFound => l10n.providerTrackNotFound,
      FailureCause.providerUnavailable => l10n.playbackProviderUnavailable,
      FailureCause.providerOffline => l10n.failureProviderOffline,
      FailureCause.verificationRequired => l10n.playbackVerificationRequired,
      FailureCause.verificationTimedOut => l10n.failureVerificationTimedOut,
      FailureCause.sessionExpired => l10n.failureSessionExpired,
      FailureCause.reauthRequired => l10n.failureReauthRequired,
      FailureCause.qualityUnavailable => l10n.failureQualityUnavailable,
      FailureCause.rateLimited => l10n.failureRateLimited,
      FailureCause.subscriptionRequired => l10n.failureSubscriptionRequired,
      FailureCause.ispBlocked => l10n.failureIspBlocked,
      FailureCause.networkFailed => l10n.failureNetwork,
      FailureCause.providerTimedOut => l10n.failureProviderTimedOut,
      FailureCause.streamExpired => l10n.failureStreamExpired,
      FailureCause.storageFailed => l10n.failureStorage,
      FailureCause.preparationTimedOut => l10n.failurePreparationTimedOut,
      FailureCause.providersExhausted => l10n.failureProvidersExhausted,
      FailureCause.encryptedUnsupported => l10n.failureEncryptedUnsupported,
      FailureCause.invalidOutput => l10n.failureInvalidOutput,
      FailureCause.finalizationFailed => l10n.failureFinalization,
      FailureCause.conversionFailed => l10n.playbackConversionFailed,
      FailureCause.unsupportedFormat => l10n.failureUnsupportedFormat,
      FailureCause.localFileUnavailable => l10n.failureLocalFileUnavailable,
      FailureCause.downloadFailed => l10n.failureDownloadFailed,
      FailureCause.downloadDecryptFailed => l10n.failureDownloadDecrypt,
      FailureCause.downloadConvertFailed => l10n.failureDownloadConvert,
      FailureCause.downloadLibraryFailed => l10n.failureDownloadLibrary,
      FailureCause.downloadFolderAccess => l10n.failureDownloadFolderAccess,
      FailureCause.generic => l10n.playbackPreparationFailed,
    };
