import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/utils/settings_search_catalog.dart';

/// Auditoria de Ajustes: el indice de busqueda no debe apuntar a controles
/// retirados, debe encontrar los ajustes nuevos, y el espanol de Mexico no
/// debe mostrar textos en ingles en las pantallas de Ajustes.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final mx = lookupAppLocalizations(const Locale('es', 'MX'));
  final es = lookupAppLocalizations(const Locale('es'));

  List<SettingsSearchEntry> everyEntry(AppLocalizations l10n) {
    final catalog = SettingsSearchCatalog(l10n, androidAudio: true);
    return [
      ...catalog.appearance,
      ...catalog.startup,
      ...catalog.library,
      ...catalog.playback,
      ...catalog.metadata,
      ...catalog.lyrics,
      ...catalog.download,
      ...catalog.files,
      ...catalog.app,
      ...catalog.cache,
      ...catalog.backup,
      ...catalog.logs,
      ...catalog.about,
    ];
  }

  group('indice de busqueda de Ajustes', () {
    test('no ofrece controles retirados (ask-quality, formato, Telegram)', () {
      final titles = everyEntry(en).map((entry) => entry.title).toSet();
      for (final retired in [
        en.downloadAskBeforeDownload,
        en.downloadLossyFormat,
        en.downloadAutoConvert,
        en.aboutMobileSource,
        en.aboutReportIssue,
        en.aboutFeatureRequest,
        en.aboutTelegramChannel,
        en.aboutTelegramChat,
      ]) {
        expect(titles, isNot(contains(retired)));
      }
    });

    test('encuentra calidad de descarga, estilo, idioma y animacion de inicio', () {
      SettingsSearchEntry? find(List<SettingsSearchEntry> from, String term) {
        final query = SettingsSearchQuery(term);
        for (final entry in from) {
          if (entry.matches(query)) return entry;
        }
        return null;
      }

      final catalog = SettingsSearchCatalog(mx, androidAudio: true);
      expect(find(catalog.musicPreferences, mx.musicPrefsDownloadQuality), isNotNull);
      expect(find(catalog.musicPreferences, mx.musicPrefsStreamingQuality), isNotNull);
      expect(find(catalog.musicPreferences, 'flac'), isNotNull);
      expect(find(catalog.download, 'flac'), isNull);
      expect(find(catalog.download, mx.autoDownloadSavedTracksTitle), isNotNull);
      expect(find(catalog.appearance, mx.appearanceStyle), isNotNull);
      expect(find(catalog.appearance, mx.appearanceLanguage), isNotNull);
      expect(find(catalog.startup, mx.startupAnimation), isNotNull);
      expect(find(catalog.startup, mx.startupSound), isNotNull);
    });
  });

  group('espanol de Ajustes', () {
    test('los textos de Ajustes ya no salen en ingles en es_MX', () {
      final pairs = <String, (String, String)>{
        'cacheTitle': (mx.cacheTitle, en.cacheTitle),
        'cacheClearAll': (mx.cacheClearAll, en.cacheClearAll),
        'aboutTitle': (mx.aboutTitle, en.aboutTitle),
        'settingsAutoExportFailed': (
          mx.settingsAutoExportFailed,
          en.settingsAutoExportFailed,
        ),
        'optionsAutoFallback': (mx.optionsAutoFallback, en.optionsAutoFallback),
        'sectionPerformance': (mx.sectionPerformance, en.sectionPerformance),
        'sectionSearchSource': (mx.sectionSearchSource, en.sectionSearchSource),
        'appearanceLanguage': (mx.appearanceLanguage, en.appearanceLanguage),
        'allFilesAccess': (mx.allFilesAccess, en.allFilesAccess),
        'collectionLoved': (mx.collectionLoved, en.collectionLoved),
      };
      for (final entry in pairs.entries) {
        expect(
          entry.value.$1,
          isNot(entry.value.$2),
          reason: '${entry.key} sigue en ingles en es_MX',
        );
      }
    });

    test('correcciones puntuales de redaccion', () {
      expect(mx.startupAnimation, 'Animación de inicio');
      expect(mx.startupSound, 'Sonido de inicio');
      expect(mx.cleanupOrphanedDownloads, 'Borrar descargas huérfanas');
      expect(mx.appearanceGlassClear, 'Transparente');
      expect(mx.linkActive, 'En uso');
      expect(mx.musicPrefsNoneSelected, 'Ninguno seleccionado');
      expect(mx.timeMinutesAgo(2), 'hace 2 minutos');
      expect(mx.timeHoursAgo(1), 'hace 1 hora');
      expect(mx.downloadNativeWorker, 'Servicio de descargas en segundo plano');
      expect(
        mx.backupRestoreRestartHint,
        startsWith('Reinicia la aplicación'),
      );
    });

    test('es base y es_MX comparten la correccion', () {
      expect(es.cacheTitle, mx.cacheTitle);
      expect(es.settingsAutoExportFailed, isNot(en.settingsAutoExportFailed));
    });
  });
}
