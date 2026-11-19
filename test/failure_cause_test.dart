import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/equalizer_error_message.dart';
import 'package:mornye/utils/extension_error_message.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:mornye/utils/user_facing_error.dart';

void main() {
  const providerTypes = [
    'verification_required',
    'auth',
    'authentication_error',
    'provider_auth_failed',
    'request_auth_invalid',
    'provider_reauth_required',
    'not_found',
    'provider_unavailable',
    'quality_unavailable',
    'rate_limit',
    'rate_limited',
    'subscription_required',
    'isp_blocked',
    'network',
    'transient_network',
    'timeout',
    'expired_stream',
    'file_error',
    'storage_error',
    'permission',
    'integrity_failed',
    'http_error',
  ];

  test('cada causa distinta del proveedor produce una clave distinta', () {
    final byCause = <FailureCause, Set<String>>{};
    for (final type in providerTypes) {
      final reason = providerFailureReasonFor(type);
      final cause = failureCauseForReason(reason)!;
      byCause.putIfAbsent(cause, () => {}).add(type);
    }
    final keys = {for (final cause in byCause.keys) failureL10nKey(cause)};
    expect(keys.length, byCause.length);
    expect(byCause.length, 15);
    expect(
      failureCauseForReason(providerFailureReasonFor('verification_required')),
      FailureCause.verificationRequired,
    );
    expect(
      failureCauseForReason(providerFailureReasonFor('auth')),
      FailureCause.sessionExpired,
    );
    expect(
      failureCauseForReason(
        providerFailureReasonFor('provider_reauth_required'),
      ),
      FailureCause.reauthRequired,
    );
  });

  test('todas las causas tienen clave unica y existen en todos los arb', () {
    final keys = [for (final c in FailureCause.values) failureL10nKey(c)];
    expect(keys.toSet().length, keys.length);
    final arbs = Directory(
      'lib/l10n/arb',
    ).listSync().whereType<File>().where((f) => !f.path.contains('es_MX'));
    for (final file in arbs) {
      final data = jsonDecode(file.readAsStringSync()) as Map;
      for (final key in keys) {
        expect(data.containsKey(key), isTrue, reason: '${file.path} $key');
      }
    }
  });

  test('cada causa produce un texto distinto en ingles y espanol', () async {
    for (final locale in const [Locale('en'), Locale('es')]) {
      final l10n = await AppLocalizations.delegate.load(locale);
      final texts = {
        for (final c in FailureCause.values) failureMessage(l10n, c),
      };
      expect(texts.length, FailureCause.values.length, reason: '$locale');
    }
  });

  test('las razones de preparacion se agrupan en una sola funcion', () {
    const reasons = [
      'encrypted output unsupported',
      'invalid provider output',
      'progressive position unavailable',
      'finalization failed',
      'invalid finalization output',
      'AC-4 repair failed',
      'audio stream not identified',
      'unsupported audio format',
      'flac remux failed',
      'invalid audio output',
      'invalid temporary copy',
      'preparation timed out',
      'verification timed out',
      'AAC conversion failed',
    ];
    for (final reason in reasons) {
      expect(isKnownFailureReason(reason), isTrue, reason: reason);
      expect(failureCauseForReason(reason), isNotNull, reason: reason);
    }
    expect(isKnownFailureReason('cancelled'), isTrue);
    expect(isKnownFailureReason('invalid temporary request'), isFalse);
    expect(
      failureCauseForPlaybackError(
        'CatalogPlaybackException: preparation failed',
      ),
      FailureCause.generic,
    );
    expect(
      failureCauseForPlaybackError('Bad state: $localFileUnavailableText'),
      FailureCause.localFileUnavailable,
    );
    expect(failureCauseForPlaybackError('PlatformException(x)'), isNull);
  });

  test('los tipos de error de descarga se traducen a causas', () {
    final causes = {
      for (final type in DownloadErrorType.values)
        type: failureCauseForDownload(type),
    };
    expect(causes[DownloadErrorType.unknown], isNull);
    expect(causes[DownloadErrorType.verificationRequired], isNull);
    expect(
      causes[DownloadErrorType.permission],
      FailureCause.downloadFolderAccess,
    );
    expect(causes[DownloadErrorType.timeout], FailureCause.providerTimedOut);
    expect(
      causes[DownloadErrorType.qualityUnavailable],
      FailureCause.qualityUnavailable,
    );
    expect(causes[DownloadErrorType.ispBlocked], FailureCause.ispBlocked);
    expect(causes[DownloadErrorType.fileError], FailureCause.storageFailed);
    expect(causes[DownloadErrorType.workerFailed], FailureCause.downloadFailed);
    expect(causes[DownloadErrorType.emptyResult], FailureCause.downloadFailed);
    expect(
      causes[DownloadErrorType.decryptFailed],
      FailureCause.downloadDecryptFailed,
    );
    expect(
      causes[DownloadErrorType.conversionFailed],
      FailureCause.downloadConvertFailed,
    );
    expect(
      causes[DownloadErrorType.libraryAddFailed],
      FailureCause.downloadLibraryFailed,
    );
    expect(
      causes[DownloadErrorType.networkTransferFailed],
      FailureCause.networkFailed,
    );
  });

  test(
    'los tipos nuevos de descarga no cuentan como fallo de red ni se restauran',
    () {
      for (final type in [
        DownloadErrorType.workerFailed,
        DownloadErrorType.emptyResult,
        DownloadErrorType.decryptFailed,
        DownloadErrorType.conversionFailed,
        DownloadErrorType.libraryAddFailed,
        DownloadErrorType.networkTransferFailed,
      ]) {
        expect(type.isNetworkFailure, isFalse, reason: type.name);
        expect(type.providerMessage, isNull, reason: type.name);
      }
    },
  );

  test('cada causa de descarga tiene texto en todos los idiomas', () async {
    final causes = {
      for (final type in DownloadErrorType.values)
        if (failureCauseForDownload(type) case final cause?) cause,
    };
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = await AppLocalizations.delegate.load(locale);
      for (final cause in causes) {
        expect(
          failureMessage(l10n, cause).trim(),
          isNotEmpty,
          reason: '$locale $cause',
        );
      }
    }
  });

  test('errores del ecualizador se distinguen', () {
    expect(
      equalizerErrorCause('Equalizer is not available on this system'),
      EqualizerErrorCause.system,
    );
    expect(
      equalizerErrorCause('Equalizer is unavailable on this output: x'),
      EqualizerErrorCause.output,
    );
    expect(
      equalizerErrorCause(
        'The balance and compressor is not available in this system audio library',
      ),
      EqualizerErrorCause.balanceCompressor,
    );
    expect(
      equalizerErrorCause(
        'The compressor is not available in this system audio library',
      ),
      EqualizerErrorCause.compressor,
    );
    expect(
      equalizerErrorCause('Could not read saved equalizer settings.'),
      EqualizerErrorCause.readSettings,
    );
    expect(
      equalizerErrorCause('Could not save equalizer settings.'),
      EqualizerErrorCause.saveSettings,
    );
    expect(equalizerErrorCause('boom'), EqualizerErrorCause.generic);
  });

  test('causas de proveedor de descarga ausente', () {
    Extension ext({required bool enabled, String status = 'loaded'}) =>
        Extension.fromJson({
          'id': 'a',
          'name': 'a',
          'display_name': 'a',
          'version': '1',
          'author': 'a',
          'description': 'a',
          'enabled': enabled,
          'status': status,
          'has_download_provider': true,
        });
    expect(
      noDownloadProviderCause(const ExtensionState()),
      NoDownloadProviderCause.noneInstalled,
    );
    expect(
      noDownloadProviderCause(
        ExtensionState(extensions: [ext(enabled: false)]),
      ),
      NoDownloadProviderCause.allDisabled,
    );
    expect(
      noDownloadProviderCause(
        ExtensionState(extensions: [ext(enabled: true, status: 'error')]),
      ),
      NoDownloadProviderCause.withError,
    );
    expect(
      noDownloadProviderCause(ExtensionState(extensions: [ext(enabled: true)])),
      NoDownloadProviderCause.selectedMissing,
    );
    expect(
      noDownloadProviderCauseFor([ext(enabled: false)]),
      NoDownloadProviderCause.allDisabled,
    );
    expect(
      noDownloadProviderCauseFor(const []),
      NoDownloadProviderCause.noneInstalled,
    );
  });

  test('userFacingErrorMessage localiza cuando recibe l10n', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('es'));
    expect(
      userFacingErrorMessage(
        'SocketException: Failed host lookup: x',
        l10n: l10n,
      ),
      l10n.userFacingNoConnection,
    );
    expect(
      userFacingErrorMessage('TimeoutException after 5s', l10n: l10n),
      l10n.userFacingTimeout,
    );
    expect(userFacingErrorMessage(null, l10n: l10n), l10n.userFacingGeneric);
    expect(
      userFacingErrorMessage('No space left on device', l10n: l10n),
      l10n.userFacingStorageFull,
    );
  });
}
