import 'package:flutter/services.dart';
import 'package:mornye/l10n/app_localizations.dart';

const defaultUserFacingErrorMessage =
    'The operation could not be completed. Please try again.';

/// Converts an internal exception or backend error into text that is safe to
/// render in the UI. The original error should still be sent to the app logger
/// before this function is called when diagnostic detail is needed.
String userFacingErrorMessage(
  Object? error, {
  String fallback = defaultUserFacingErrorMessage,
  AppLocalizations? l10n,
}) {
  final defaultMessage =
      l10n?.userFacingGeneric ?? defaultUserFacingErrorMessage;
  final safeFallback =
      fallback.trim().isEmpty ||
          (l10n != null && fallback == defaultUserFacingErrorMessage)
      ? defaultMessage
      : fallback.trim();

  if (error == null) return safeFallback;

  if (error is PlatformException) {
    final message = error.message?.trim();
    if (_isMeaningful(message)) {
      return _sanitizeText(message!, fallback: safeFallback, l10n: l10n);
    }
    return _messageFromCode(error.code, fallback: safeFallback, l10n: l10n);
  }

  return _sanitizeText(error.toString(), fallback: safeFallback, l10n: l10n);
}

String _sanitizeText(
  String raw, {
  required String fallback,
  AppLocalizations? l10n,
}) {
  var message = raw.trim();
  if (!_isMeaningful(message)) return fallback;

  message = _stripLeadingWrappers(message);

  final platformMatch = RegExp(
    r'^PlatformException\(\s*([^,]+)\s*,\s*(.*)\)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(message);
  if (platformMatch != null) {
    final code = platformMatch.group(1)?.trim() ?? '';
    final body = platformMatch.group(2)?.trim() ?? '';
    final parsedMessage = _platformMessage(body);
    if (_isMeaningful(parsedMessage)) {
      return _sanitizeText(parsedMessage!, fallback: fallback, l10n: l10n);
    }
    return _messageFromCode(code, fallback: fallback, l10n: l10n);
  }

  final lower = message.toLowerCase();
  if (lower.contains('socketexception') ||
      lower.contains('failed host lookup') ||
      lower.contains('connection refused') ||
      lower.contains('network is unreachable')) {
    return l10n?.userFacingNoConnection ??
        'Unable to connect. Check your internet connection.';
  }
  if (lower.contains('timeoutexception') ||
      lower.contains('timed out') ||
      lower.contains('timeout')) {
    return l10n?.userFacingTimeout ??
        'The request timed out. Please try again.';
  }
  if (lower.contains('missingpluginexception') ||
      lower.contains('no implementation found for method') ||
      lower.contains('channel-error') ||
      lower.contains('null check operator used on a null value') ||
      lower.contains('lateinitializationerror') ||
      lower.contains('nosuchmethoderror') ||
      lower.contains('is not a subtype of') ||
      lower.startsWith('instance of ')) {
    return fallback;
  }

  if (l10n != null) {
    if (lower.contains('no space left') ||
        lower.contains('enospc') ||
        lower.contains('disk full')) {
      return l10n.userFacingStorageFull;
    }
    if (lower.contains('permission denied') || lower.contains('eacces')) {
      return l10n.userFacingPermissionDenied;
    }
  }

  final stackStart = message.indexOf(
    RegExp(r'\n\s*(?:#\d+|at\s+\S+|<asynchronous suspension>)'),
  );
  if (stackStart >= 0) message = message.substring(0, stackStart);

  message = message
      .replaceFirst(RegExp(r'\s*\(OS Error:.*$', dotAll: true), '')
      .replaceFirst(
        RegExp(
          r',\s*(?:path|source|target)\s*=\s*.*$',
          caseSensitive: false,
          dotAll: true,
        ),
        '',
      )
      .replaceFirst(
        RegExp(r',\s*errno\s*=\s*\d+.*$', caseSensitive: false),
        '',
      );

  message = _stripLeadingWrappers(
    message,
  ).replaceAll(RegExp(r'\s+'), ' ').trim();
  message = message.replaceFirst(RegExp(r'^[,;:\s]+'), '').trim();

  if (!_isMeaningful(message) ||
      message.toLowerCase().contains('platformexception')) {
    return fallback;
  }

  const maxLength = 240;
  if (message.length > maxLength) {
    final shortened = message.substring(0, maxLength);
    final lastSpace = shortened.lastIndexOf(' ');
    message =
        '${shortened.substring(0, lastSpace > 160 ? lastSpace : maxLength)}…';
  }
  return message;
}

String? _platformMessage(String body) {
  final withDetailsAndStack = RegExp(
    r'^(.*),\s*(?:null|\{.*\}|\[.*\]),\s*(?:null|.*)$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(body);
  var candidate = withDetailsAndStack?.group(1)?.trim();

  candidate ??= RegExp(
    r'^(.*),\s*null\s*,\s*null$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(body)?.group(1)?.trim();
  candidate ??= RegExp(
    r'^(.*),\s*null$',
    caseSensitive: false,
    dotAll: true,
  ).firstMatch(body)?.group(1)?.trim();
  candidate ??= body.trim();

  return _isMeaningful(candidate) ? candidate : null;
}

String _messageFromCode(
  String code, {
  required String fallback,
  AppLocalizations? l10n,
}) {
  var normalized = code.trim().replaceAll(RegExp(r'''^["']|["']$'''), '');
  final lower = normalized.toLowerCase().replaceAll('-', '_');
  const genericCodes = {
    '',
    'error',
    'err',
    'failed',
    'failure',
    'unknown',
    'exception',
    'internal',
    'internal_error',
    'platform_error',
    'channel_error',
    'unavailable',
    '-1',
  };
  if (genericCodes.contains(lower) || RegExp(r'^\d+$').hasMatch(lower)) {
    return fallback;
  }
  if (lower.contains('cancel')) {
    return l10n?.userFacingCancelled ?? 'The operation was cancelled.';
  }
  if (l10n != null) {
    if (lower.contains('permission') || lower.contains('denied')) {
      return l10n.userFacingPermissionDenied;
    }
    if (lower.contains('no_space') || lower.contains('storage_full')) {
      return l10n.userFacingStorageFull;
    }
  }

  normalized = lower
      .replaceFirst(RegExp(r'^(?:error|err)_'), '')
      .replaceAll(RegExp(r'[_-]+'), ' ')
      .trim();
  if (normalized.isEmpty) return fallback;
  return '${normalized[0].toUpperCase()}${normalized.substring(1)}';
}

String _stripLeadingWrappers(String value) {
  var message = value.trim();
  final wrapper = RegExp(
    r'^(?:Exception|Error|StateError|ArgumentError|FormatException|FileSystemException|HttpException|HandshakeException|Bad state|Invalid argument\(s\))\s*:\s*',
    caseSensitive: false,
  );
  while (wrapper.hasMatch(message)) {
    message = message.replaceFirst(wrapper, '').trim();
  }
  return message;
}

bool _isMeaningful(String? value) {
  if (value == null) return false;
  final normalized = value.trim().toLowerCase();
  return normalized.isNotEmpty &&
      normalized != 'null' &&
      normalized != 'none' &&
      normalized != 'unknown' &&
      normalized != 'error';
}
