import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('storage folder labels use MUSA in translated ARB files', () {
    const locales = ['ar', 'de', 'fr', 'hi', 'id', 'it', 'ja', 'ko', 'nl', 'pt_PT', 'ru', 'tr', 'uk', 'vi', 'zh_CN', 'zh_TW'];
    for (final locale in locales) {
      final arb = jsonDecode(File('lib/l10n/arb/app_$locale.arb').readAsStringSync()) as Map<String, dynamic>;
      for (final key in ['storageAutomaticDownloadFolder', 'storageDownloadFolderHint']) {
        expect(arb[key], contains('MUSA'), reason: '$locale: $key');
        expect(arb[key], isNot(contains('Mornye')), reason: '$locale: $key');
      }
    }
  });

  test('connection channels retain their IDs and use MUSA names', () {
    const base = 'android/app/src/main/kotlin/com/zarz/mornye';
    final link = File('$base/LinkConnectionService.kt').readAsStringSync();
    final jam = File('$base/JamConnectionService.kt').readAsStringSync();
    expect(link, contains('const val CHANNEL_ID = "link_connection"'));
    expect(link, contains('NotificationChannel(CHANNEL_ID, "MUSA Link", NotificationManager.IMPORTANCE_LOW)'));
    expect(jam, contains('const val CHANNEL = "jam_connection"'));
    expect(jam, contains('NotificationChannel(CHANNEL, "MUSA Jam", NotificationManager.IMPORTANCE_LOW)'));
  });

  test('Acerca no conserva creditos ni secciones del proyecto anterior', () {
    final about = File('lib/screens/settings/about_page.dart').readAsStringSync();
    final catalog = File('lib/utils/settings_search_catalog.dart').readAsStringSync();
    for (final source in {'about_page': about, 'settings_search_catalog': catalog}.entries) {
      for (final banned in [
        'aboutContributors',
        'aboutTranslators',
        'aboutSpecialThanks',
        'Amonoman',
        'Ruubiiiii',
        'binimum',
        'sachinsenal0x64',
        'crowdin',
        'UniTune',
        'Squigly',
        'Paxsenix',
        'MusicBrainz',
        'zarzet',
      ]) {
        expect(source.value, isNot(contains(banned)), reason: '${source.key}: $banned');
      }
    }
  });

  test('los ARB no traen textos visibles del proyecto anterior', () {
    final banned = RegExp(
      r'zarzet|spotiflac|ruubiiiii|amonoman|binimum|sachinsenal|squigly|paxsenix|unitune|telegram|Mornye(?! Link)',
      caseSensitive: false,
    );
    final removed = [
      'aboutContributors',
      'aboutTranslators',
      'aboutSpecialThanks',
      'aboutLogoArtist',
      'aboutRuubiiiiDesc',
      'aboutBinimumDesc',
      'aboutSachinsenalDesc',
      'aboutUnituneDesc',
      'aboutMusicBrainzDesc',
      'aboutSquiglyDesc',
      'aboutPaxsenixSubtitle',
      'aboutTelegramChannel',
      'aboutTelegramChat',
    ];
    final files = Directory('lib/l10n/arb').listSync().whereType<File>().where((f) => f.path.endsWith('.arb'));
    expect(files, isNotEmpty);
    for (final file in files) {
      final arb = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      for (final key in removed) {
        expect(arb.containsKey(key), isFalse, reason: '${file.path}: $key');
      }
      for (final entry in arb.entries) {
        final value = entry.value;
        if (entry.key.startsWith('@') || value is! String) continue;
        expect(banned.hasMatch(value), isFalse, reason: '${file.path}: ${entry.key}');
      }
    }
  });
}
