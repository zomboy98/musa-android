import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:mornye/utils/provider_text_localizer.dart';
import 'package:mornye/widgets/download_service_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _es = Locale('es');
const _en = Locale('en');

Map<String, Map<String, dynamic>> _bundledManifests() {
  final result = <String, Map<String, dynamic>>{};
  for (final file in Directory('assets/bundled_extensions').listSync()) {
    if (file is! File || !file.path.endsWith('.sflx')) continue;
    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final entry = archive.findFile('manifest.json');
    if (entry == null) continue;
    final manifest =
        jsonDecode(utf8.decode(entry.content as List<int>))
            as Map<String, dynamic>;
    result[manifest['name'] as String] = manifest;
  }
  return result;
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultService: 'tidal-web');

  @override
  Future<void> ensureLoaded() async {}
}

void main() {
  test('known texts are translated for es and kept for en', () {
    expect(
      localizedProviderText(
        _es,
        extensionId: 'tidal-web',
        optionId: 'HIGH',
        kind: 'description',
        original: 'Require TIDAL High without falling back to Low',
      ),
      'Exigir TIDAL Alta sin bajar a Baja',
    );
    expect(
      localizedProviderText(
        _es,
        extensionId: 'tidal-web',
        optionId: 'LOW',
        kind: 'label',
        original: 'Low',
      ),
      'Baja (AAC 96 kbps)',
    );
    expect(
      localizedProviderText(
        _en,
        extensionId: 'tidal-web',
        optionId: 'LOW',
        kind: 'description',
        original: 'Require TIDAL Low',
      ),
      'Require TIDAL Low',
    );
    expect(
      localizedProviderText(
        const Locale('es', 'MX'),
        kind: 'description',
        original: 'Require TIDAL Low',
      ),
      'Exigir TIDAL Baja',
    );
  });

  test('unknown text and other languages return the original', () {
    expect(
      localizedProviderText(_es, kind: 'label', original: 'Something new'),
      'Something new',
    );
    expect(
      localizedProviderText(
        const Locale('fr'),
        extensionId: 'tidal-web',
        optionId: 'LOW',
        kind: 'label',
        original: 'Low',
      ),
      'Low',
    );
  });

  test('the table covers every bundled manifest text', () {
    final missing = <String>[];
    for (final entry in _bundledManifests().entries) {
      final id = entry.key;
      final manifest = entry.value;
      void check(String? optionId, String kind, String? original) {
        if (original == null || original.isEmpty) return;
        if (!hasProviderTextTranslation(
          extensionId: id,
          optionId: optionId,
          kind: kind,
          original: original,
        )) {
          missing.add('$id|$optionId|$kind|$original');
        }
      }

      check('description', 'description', manifest['description'] as String?);
      for (final q in (manifest['qualityOptions'] as List? ?? const [])) {
        final option = q as Map<String, dynamic>;
        check(option['id'] as String, 'label', option['label'] as String?);
        check(
          option['id'] as String,
          'description',
          option['description'] as String?,
        );
      }
      for (final s in (manifest['settings'] as List? ?? const [])) {
        final setting = s as Map<String, dynamic>;
        check(
          setting['key'] as String,
          'setting_title',
          setting['label'] as String?,
        );
        check(
          setting['key'] as String,
          'setting_description',
          setting['description'] as String?,
        );
      }
    }
    expect(missing, isEmpty);
  });

  testWidgets('quality rows show the Spanish text with es and ids stay', (
    tester,
  ) async {
    late ({IconData icon, String label, String description}) es;
    await tester.pumpWidget(
      MaterialApp(
        locale: _es,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            es = qualityOptionDisplay(
              context,
              const QualityOption(
                id: 'HIGH',
                label: 'High',
                description: 'Require TIDAL High without falling back to Low',
                kind: 'lossy',
              ),
              extensionId: 'tidal-web',
            );
            return const SizedBox();
          },
        ),
      ),
    );
    expect(es.label, 'Alta (AAC 320 kbps)');
    expect(es.description, 'Exigir TIDAL Alta sin bajar a Baja');
  });

  testWidgets('the Listen page shows translated provider quality text', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 5000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          extensionProvider.overrideWith(_ListenExtensions.new),
        ],
        child: MaterialApp(
          locale: _es,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MusicPreferencesPage(expandSectionsForTest: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Exigir TIDAL Alta sin bajar a Baja'), findsWidgets);
    expect(find.text('Exigir TIDAL Baja'), findsWidgets);
    expect(find.text('Require TIDAL Low'), findsNothing);
  });
}

class _ListenExtensions extends ExtensionNotifier {
  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    providerPriority: ['tidal-web'],
    extensions: [
      Extension(
        id: 'tidal-web',
        name: 'tidal-web',
        displayName: 'Tidal',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: [
          QualityOption(
            id: 'HIGH',
            label: 'High',
            description: 'Require TIDAL High without falling back to Low',
            kind: 'lossy',
          ),
          QualityOption(
            id: 'LOW',
            label: 'Low',
            description: 'Require TIDAL Low',
            kind: 'lossy',
          ),
        ],
      ),
    ],
  );
}
