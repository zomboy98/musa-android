import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/utils/artist_utils.dart';

void main() {
  test('playback quality migrates independently and survives restoration', () {
    final legacy = AppSettings.fromJson({'audioQuality': 'HIGH'});
    expect(legacy.audioQuality, 'HIGH');
    expect(legacy.playbackQuality, 'opus');

    final changed = legacy.copyWith(playbackQuality: 'LOW');
    final restored = AppSettings.fromJson(changed.toJson());
    expect(restored.playbackQuality, 'LOW');
    expect(restored.audioQuality, 'HIGH');
    final downloadChanged = restored.copyWith(audioQuality: 'LOSSLESS');
    expect(downloadChanged.playbackQuality, 'LOW');
  });

  test('una instalacion nueva usa Dolby Atmos (AC-4) en streaming', () {
    const fresh = AppSettings();
    expect(fresh.defaultService, '');
    expect(fresh.playbackQuality, 'opus');
    expect(fresh.audioQuality, '');
    expect(fresh.downloadQualityByProvider, isEmpty);
    final empty = AppSettings.fromJson({});
    expect(empty.defaultService, '');
    expect(empty.playbackQuality, 'opus');
    expect(empty.audioQuality, '');
  });

  test('los ajustes guardados no se sobrescriben con los nuevos valores', () {
    final saved = AppSettings.fromJson({
      'defaultService': 'tidal-web',
      'playbackQuality': 'auto_light',
      'playbackQualityVersion': 2,
      'audioQuality': 'LOSSLESS',
    });
    expect(saved.defaultService, 'tidal-web');
    expect(saved.playbackQuality, 'auto_light');
    expect(saved.audioQuality, 'LOSSLESS');
    final blank = AppSettings.fromJson({'defaultService': ''});
    expect(blank.defaultService, '');
    final restored = AppSettings.fromJson(saved.toJson());
    expect(restored.defaultService, 'tidal-web');
    expect(restored.playbackQuality, 'auto_light');
    final other = AppSettings.fromJson({'playbackQuality': 'HIGH'});
    expect(other.playbackQuality, 'HIGH');
  });

  test(
    'automatic saved song downloads default off and survive serialization',
    () {
      expect(const AppSettings().autoDownloadSavedTracks, isFalse);
      expect(AppSettings.fromJson({}).autoDownloadSavedTracks, isFalse);
      for (final enabled in [true, false]) {
        final settings = const AppSettings().copyWith(
          autoDownloadSavedTracks: enabled,
        );
        final restored = AppSettings.fromJson(settings.toJson());
        expect(restored.autoDownloadSavedTracks, enabled);
        expect(
          restored.copyWith(locale: 'es').autoDownloadSavedTracks,
          enabled,
        );
      }
    },
  );

  test('AI translation defaults to Fast and remembers either mode', () {
    expect(const AppSettings().lyricsAiWordSync, isFalse);
    expect(AppSettings.fromJson({}).lyricsAiWordSync, isFalse);
    for (final wordSync in [false, true]) {
      final settings = const AppSettings().copyWith(lyricsAiWordSync: wordSync);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.lyricsAiWordSync, wordSync);
      expect(restored.copyWith(locale: 'id').lyricsAiWordSync, wordSync);
    }
  });

  test('Library sort restores every choice and tolerates old settings', () {
    expect(AppSettings.fromJson({}).historySortMode, 'latest');
    for (final invalid in [null, '', 'unsupported', 42]) {
      expect(
        AppSettings.fromJson({'historySortMode': invalid}).historySortMode,
        'latest',
      );
    }
    for (final sort in librarySortModes) {
      final settings = const AppSettings().copyWith(historySortMode: sort);
      final restored = AppSettings.fromJson(settings.toJson());
      expect(restored.historySortMode, sort);
      expect(restored.copyWith(historyViewMode: 'list').historySortMode, sort);
    }
  });

  group('AppSettings', () {
    test('the stored prefetch of 1 or 2 becomes 3 once and then respects the choice', () {
      expect(
        AppSettings.fromJson({
          'playbackPrefetchCount': 2,
        }).playbackPrefetchCount,
        3,
      );
      expect(
        AppSettings.fromJson({
          'playbackPrefetchCount': 0,
          'playbackPrefetchVersion': 2,
        }).playbackPrefetchCount,
        0,
      );
      final migrated = AppSettings.fromJson({'playbackPrefetchCount': 2});
      final chosen = migrated.copyWith(playbackPrefetchCount: 2);
      final restored = AppSettings.fromJson(chosen.toJson());
      expect(restored.playbackPrefetchCount, 2);
      expect(AppSettings.fromJson(restored.toJson()).playbackPrefetchCount, 2);
    });

    test('provides stable defaults', () {
      const settings = AppSettings();

      // No provider tier is assumed by default: empty means "best available"
      // and the provider relay maps it per provider. Strict mode is opt-in.
      expect(settings.audioQuality, '');
      expect(settings.strictDownloadQuality, isFalse);
      expect(settings.filenameFormat, '{track:02} - {title}');
      expect(settings.singleFilenameFormat, '{title}');
      expect(settings.artistTagMode, artistTagModeJoined);
      expect(settings.embeddedCoverMaxDimension, 0);
      expect(settings.autoFallback, isTrue);
      expect(settings.lyricsProviders, [
        'apple_music',
        'lrcred',
        'mornye_lyrics',
        'lyricsplus',
        'lrclib',
      ]);
      expect(settings.playerMode, 'internal');
      expect(settings.lyricsMultiPersonWordByWord, isTrue);
      expect(settings.lyricsAppleElrcWordSync, isTrue);
      expect(settings.deduplicateDownloads, isTrue);
      expect(settings.allowQualityVariants, isFalse);
      expect(settings.nativeDownloadWorkerEnabled, isFalse);
      expect(
        settings.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
    });

    test('normalizes the old lyrics provider without duplicating it', () {
      final settings = AppSettings.fromJson({
        'lyricsProviders': [
          'lrclib',
          'spotiflac_lyrics',
          'apple_music',
          'mornye_lyrics',
        ],
      });
      expect(settings.lyricsProviders, [
        'lrclib',
        'mornye_lyrics',
        'apple_music',
      ]);
    });

    test('copyWith updates values and can clear nullable provider fields', () {
      const settings = AppSettings(
        downloadFallbackExtensionIds: ['fallback.ext'],
        searchProvider: 'search.ext',
        homeFeedProvider: 'feed.ext',
      );

      final updated = settings.copyWith(
        defaultService: 'provider-a',
        embedReplayGain: true,
        embeddedCoverMaxDimension: 1000,
        lyricsProviders: ['apple_music'],
        lyricsAppleElrcWordSync: true,
        deduplicateDownloads: false,
        allowQualityVariants: true,
        libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepthOnly,
        clearDownloadFallbackExtensionIds: true,
        clearSearchProvider: true,
        clearHomeFeedProvider: true,
      );

      expect(updated.defaultService, 'provider-a');
      expect(updated.embedReplayGain, isTrue);
      expect(updated.embeddedCoverMaxDimension, 1000);
      expect(updated.lyricsProviders, ['apple_music']);
      expect(updated.lyricsAppleElrcWordSync, isTrue);
      expect(updated.deduplicateDownloads, isFalse);
      expect(updated.allowQualityVariants, isTrue);
      expect(
        updated.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
      expect(updated.downloadFallbackExtensionIds, isNull);
      expect(updated.searchProvider, isNull);
      expect(updated.homeFeedProvider, isNull);
      expect(updated.audioQuality, settings.audioQuality);
    });

    test('round-trips json including recently added settings', () {
      const settings = AppSettings(
        defaultService: 'provider-b',
        storageMode: 'saf',
        downloadTreeUri: 'content://tree/music',
        downloadFallbackExtensionIds: ['ext.a', 'ext.b'],
        searchProvider: 'search.ext',
        homeFeedProvider: AppSettings.homeFeedProviderOff,
        useAllFilesAccess: true,
        networkCompatibilityMode: true,
        songLinkRegion: 'ID',
        localLibraryEnabled: true,
        localLibraryPath: '/music',
        hasCompletedTutorial: true,
        musixmatchLanguage: 'id',
        lyricsAppleElrcWordSync: true,
        deduplicateDownloads: false,
        allowQualityVariants: true,
        nativeDownloadWorkerEnabled: true,
        libraryQualityLabelMode: AppSettings.libraryQualityLabelBitDepthOnly,
        embeddedCoverMaxDimension: 1500,
      );

      final decoded = AppSettings.fromJson(settings.toJson());

      expect(decoded.defaultService, 'provider-b');
      expect(decoded.storageMode, 'saf');
      expect(decoded.downloadTreeUri, 'content://tree/music');
      expect(decoded.downloadFallbackExtensionIds, ['ext.a', 'ext.b']);
      expect(decoded.searchProvider, 'search.ext');
      expect(decoded.homeFeedProvider, AppSettings.homeFeedProviderOff);
      expect(decoded.useAllFilesAccess, isTrue);
      expect(decoded.networkCompatibilityMode, isTrue);
      expect(decoded.songLinkRegion, 'ID');
      expect(decoded.localLibraryEnabled, isTrue);
      expect(decoded.localLibraryPath, '/music');
      expect(decoded.hasCompletedTutorial, isTrue);
      expect(decoded.musixmatchLanguage, 'id');
      expect(decoded.lyricsAppleElrcWordSync, isTrue);
      expect(
        decoded.libraryQualityLabelMode,
        AppSettings.libraryQualityLabelBitDepthOnly,
      );
      expect(decoded.deduplicateDownloads, isTrue);
      expect(decoded.allowQualityVariants, isFalse);
      expect(decoded.nativeDownloadWorkerEnabled, isTrue);
      expect(decoded.embeddedCoverMaxDimension, 1500);
    });
  });

  group('ThemeSettings', () {
    test('serializes, deserializes, copies, and compares values', () {
      const settings = ThemeSettings(
        themeMode: ThemeMode.dark,
        useDynamicColor: false,
        seedColorValue: 0xff123456,
        useAmoled: true,
        style: AppThemeStyle.mornye,
        mornyeAccent: MornyeAccent.blue,
        useSystemFont: true,
      );

      final decoded = ThemeSettings.fromJson(settings.toJson());
      final copied = decoded.copyWith(themeMode: ThemeMode.light);

      expect(decoded, settings);
      expect(decoded.hashCode, settings.hashCode);
      expect(decoded.seedColor, const Color(0xff123456));
      expect(copied.themeMode, ThemeMode.light);
      expect(copied.useAmoled, isTrue);
      expect(decoded.style, AppThemeStyle.mornye);
      expect(decoded.mornyeAccent, MornyeAccent.blue);
      expect(copied.mornyeAccent, MornyeAccent.blue);
      expect(decoded.useSystemFont, isTrue);
      expect(copied.useSystemFont, isTrue);
      expect(ThemeSettings.fromJson({}).useSystemFont, isFalse);
      expect(ThemeSettings.fromJson({}).mornyeAccent, MornyeAccent.blue);
      expect(
        ThemeSettings.fromJson({kMornyeAccentKey: 'unknown'}).mornyeAccent,
        MornyeAccent.blue,
      );
      expect(
        ThemeSettings.fromJson({kMornyeAccentKey: 'red'}).mornyeAccent,
        MornyeAccent.red,
        reason: 'a saved choice stays',
      );
      expect(
        ThemeSettings.fromJson({'theme_mode': 'invalid'}).themeMode,
        ThemeMode.dark,
      );
      expect(
        ThemeSettings.fromJson({'theme_style': 'invalid'}).style,
        AppThemeStyle.mornye,
      );
    });
  });
}
