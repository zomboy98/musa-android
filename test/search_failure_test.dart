import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/search_failure.dart';

void main() {
  group('searchFailureFor', () {
    test('reconoce cada causa por separado', () {
      expect(
        searchFailureFor('url_not_recognized'),
        SearchFailure.urlNotRecognized,
      );
      expect(
        searchFailureFor('HTTP 429 Too Many Requests'),
        SearchFailure.rateLimited,
      );
      expect(
        searchFailureFor('PlatformException(ERROR, verification_required)'),
        SearchFailure.verificationRequired,
      );
      expect(
        searchFailureFor('SocketException: Failed host lookup'),
        SearchFailure.offline,
      );
      expect(
        searchFailureFor('TimeoutException after 0:00:30'),
        SearchFailure.timedOut,
      );
      expect(
        searchFailureFor('extension is disabled or no longer installed'),
        SearchFailure.providerUnavailable,
      );
      expect(searchFailureFor('algo raro'), SearchFailure.generic);
    });
  });

  group('searchFailureMessage', () {
    late AppLocalizations l10n;

    setUp(() async {
      l10n = await AppLocalizations.delegate.load(const Locale('en'));
    });

    test('cada causa tiene un texto propio', () {
      final texts = {
        for (final failure in SearchFailure.values)
          failure: searchFailureMessage(l10n, failure, fromUrl: false),
      };
      expect(texts.values.toSet().length, SearchFailure.values.length);
    });

    test('el fallo generico distingue enlace de busqueda', () {
      expect(
        searchFailureMessage(l10n, SearchFailure.generic, fromUrl: true),
        l10n.errorUrlFetchFailed,
      );
      expect(
        searchFailureMessage(l10n, SearchFailure.generic, fromUrl: false),
        l10n.errorSearchFailed,
      );
    });
  });
}
