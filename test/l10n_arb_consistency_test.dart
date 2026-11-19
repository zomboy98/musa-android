import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every translation file must carry every key of app_en.arb with the same
/// placeholders, so that no language silently falls back to English or
/// breaks at runtime on a mismatched placeholder.
///
/// app_es_MX.arb is the one exception: it only overrides the wording that
/// differs from app_es.arb and inherits the rest.
const _partialLocales = {'es_MX'};

final _directory = Directory('lib/l10n/arb');

Map<String, dynamic> _load(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

/// The placeholders app_en.arb declares for [key]; plural and select
/// branches are text, so only declared names are looked for.
Set<String> _declared(Map<String, dynamic> english, String key) {
  final meta = english['@$key'];
  if (meta is! Map || meta['placeholders'] is! Map) return {};
  return (meta['placeholders'] as Map).keys.cast<String>().toSet();
}

bool _usesPlaceholder(String message, String name) =>
    RegExp(r'\{' + name + r'\s*[,}]').hasMatch(message);

bool _isMessage(String key) => !key.startsWith('@');

void main() {
  final files =
      _directory
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('.arb'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final english = _load(File('${_directory.path}/app_en.arb'));
  final englishKeys = english.keys.where(_isMessage).toList();

  test('the arb folder has the template and the translations', () {
    expect(englishKeys, isNotEmpty);
    expect(files.length, greaterThan(10));
  });

  for (final file in files) {
    final locale = file.uri.pathSegments.last
        .replaceFirst('app_', '')
        .replaceFirst('.arb', '');
    if (locale == 'en') continue;
    final messages = _load(file);

    test('$locale defines every key of app_en.arb', () {
      if (_partialLocales.contains(locale)) {
        final unknown = messages.keys
            .where((key) => _isMessage(key) && !english.containsKey(key))
            .toList();
        expect(unknown, isEmpty, reason: '$locale overrides unknown keys');
        return;
      }
      final missing = englishKeys
          .where((key) => !messages.containsKey(key))
          .toList();
      expect(
        missing,
        isEmpty,
        reason: '$locale lost ${missing.length} keys, e.g. ${missing.take(5)}',
      );
    });

    test('$locale keeps the placeholders and braces of app_en.arb', () {
      final problems = <String>[];
      for (final key in englishKeys) {
        final value = messages[key];
        if (value is! String) continue;
        for (final name in _declared(english, key)) {
          if (!_usesPlaceholder(value, name)) {
            problems.add('$key: missing placeholder {$name}');
          }
        }
        if ('{'.allMatches(value).length != '}'.allMatches(value).length) {
          problems.add('$key: unbalanced braces');
        }
      }
      expect(problems, isEmpty, reason: problems.take(10).join('\n'));
    });
  }
}
