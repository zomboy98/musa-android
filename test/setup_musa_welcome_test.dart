import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';

void main() {
  test('welcome copy is available in English and both Spanish locales', () {
    expect(lookupAppLocalizations(const Locale('en')).setupMusicWelcome,
        'Your music, all in one place');
    expect(lookupAppLocalizations(const Locale('es')).setupMusicWelcome,
        'Tu música, en un solo lugar');
    expect(lookupAppLocalizations(const Locale('es', 'ES')).setupMusicWelcome,
        'Tu música, en un solo lugar');
    for (final locale in AppLocalizations.supportedLocales) {
      expect(lookupAppLocalizations(locale).setupMusicWelcome, isNotEmpty);
    }
  });
}
