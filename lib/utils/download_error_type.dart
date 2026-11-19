import 'package:mornye/models/download_item.dart';

// Mirrors the provider failure vocabulary in Rust and DownloadFailureDiagnostics
// on Android. Multiple codes can share a queue category while keeping their
// original code in diagnostics.
const _backendErrorTypes = {
  'not_found': DownloadErrorType.notFound,
  'rate_limit': DownloadErrorType.rateLimit,
  'rate_limited': DownloadErrorType.rateLimit,
  'network': DownloadErrorType.network,
  'permission': DownloadErrorType.permission,
  'verification_required': DownloadErrorType.verificationRequired,
  'quality_unavailable': DownloadErrorType.qualityUnavailable,
  'subscription_required': DownloadErrorType.subscriptionRequired,
  'expired_stream': DownloadErrorType.expiredStream,
  'http_error': DownloadErrorType.httpError,
  'integrity_failed': DownloadErrorType.integrityFailed,
  'transient_network': DownloadErrorType.transientNetwork,
  'timeout': DownloadErrorType.timeout,
  'auth': DownloadErrorType.authenticationError,
  'authentication_error': DownloadErrorType.authenticationError,
  'provider_auth_failed': DownloadErrorType.authenticationError,
  'request_auth_invalid': DownloadErrorType.authenticationError,
  'provider_reauth_required': DownloadErrorType.providerReauthRequired,
  'provider_unavailable': DownloadErrorType.providerUnavailable,
  'storage_error': DownloadErrorType.fileError,
  'file_error': DownloadErrorType.fileError,
  'isp_blocked': DownloadErrorType.ispBlocked,
  'not_implemented': DownloadErrorType.notImplemented,
  'invalid_url': DownloadErrorType.invalidUrl,
  'provider_error': DownloadErrorType.providerError,
  'extension_error': DownloadErrorType.providerError,
  'runtime_error': DownloadErrorType.providerError,
  'script_error': DownloadErrorType.providerError,
  'download_error': DownloadErrorType.providerError,
  'init_error': DownloadErrorType.providerError,
  'api_error': DownloadErrorType.providerError,
};

String _normalizeBackendErrorType(Object? value) =>
    value is String ? value.trim().toLowerCase() : '';

/// Null permits legacy message inference when no supported type was supplied.
DownloadErrorType? downloadErrorTypeFromBackend(String? errorType) =>
    _backendErrorTypes[_normalizeBackendErrorType(errorType)];

String downloadDiagnosticErrorType(Object? errorType) {
  final normalized = _normalizeBackendErrorType(errorType);
  if (normalized == 'rate_limited') return 'rate_limit';
  if (normalized == 'cancelled' || _backendErrorTypes.containsKey(normalized)) {
    return normalized;
  }
  return 'unknown';
}

/// Queue history must retain only fixed messages for typed provider failures.
String? typedDownloadFailureMessage(
  Object? reportedType,
  DownloadErrorType type,
) {
  final normalized = _normalizeBackendErrorType(reportedType);
  final message = type.providerMessage;
  if (message != null) return message;
  if (normalized.isEmpty || normalized == 'cancelled') return null;
  final reported = _backendErrorTypes[normalized];
  if (reported != null && reported.providerMessage == null) return null;
  return switch (type) {
    DownloadErrorType.network => 'Connection failed, check your internet',
    DownloadErrorType.rateLimit =>
      'Service rate limit reached. Wait before retrying.',
    DownloadErrorType.permission =>
      'Cannot write to folder, check storage permission',
    _ => 'Download failed',
  };
}
