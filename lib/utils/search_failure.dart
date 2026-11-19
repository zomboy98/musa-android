import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/l10n/app_localizations.dart';

enum SearchFailure {
  rateLimited,
  urlNotRecognized,
  verificationRequired,
  offline,
  timedOut,
  providerUnavailable,
  generic,
}

const urlNotRecognizedError = 'url_not_recognized';

SearchFailure searchFailureFor(String error) {
  if (error == urlNotRecognizedError) return SearchFailure.urlNotRecognized;
  final lower = error.toLowerCase();
  if (error.contains('429') ||
      lower.contains('rate limit') ||
      lower.contains('too many requests')) {
    return SearchFailure.rateLimited;
  }
  if (isExtensionVerificationRequired(error)) {
    return SearchFailure.verificationRequired;
  }
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable')) {
    return SearchFailure.offline;
  }
  if (lower.contains('timeoutexception') ||
      lower.contains('timed out') ||
      lower.contains('timeout')) {
    return SearchFailure.timedOut;
  }
  if (lower.contains('is disabled') ||
      lower.contains('no longer installed') ||
      lower.contains('extension not found') ||
      lower.contains('is unavailable') ||
      lower.contains('extension providers are disabled')) {
    return SearchFailure.providerUnavailable;
  }
  return SearchFailure.generic;
}

String searchFailureMessage(
  AppLocalizations l10n,
  SearchFailure failure, {
  required bool fromUrl,
}) => switch (failure) {
  SearchFailure.rateLimited => l10n.errorRateLimitedMessage,
  SearchFailure.urlNotRecognized => l10n.errorUrlNotRecognizedMessage,
  SearchFailure.verificationRequired => l10n.errorSearchVerification,
  SearchFailure.offline => l10n.userFacingNoConnection,
  SearchFailure.timedOut => l10n.userFacingTimeout,
  SearchFailure.providerUnavailable => l10n.errorSearchProviderUnavailable,
  SearchFailure.generic =>
    fromUrl ? l10n.errorUrlFetchFailed : l10n.errorSearchFailed,
};
