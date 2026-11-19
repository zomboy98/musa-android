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
}
