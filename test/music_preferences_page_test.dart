import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/settings/music_preferences_page.dart';
import 'package:mornye/utils/download_quality_options.dart';
import 'package:mornye/utils/quality_selection.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.initial);
  final AppSettings initial;
  @override
  AppSettings build() => initial;

  @override
  void setPlaybackQuality(String quality) {
    state = state.copyWith(playbackQuality: quality);
  }

  @override
  void setAudioQualityForProvider(
    String provider,
    String quality, {
    QualityOption? option,
  }) {
    final key = provider.trim().toLowerCase();
    state = state.copyWith(
      audioQuality: key == state.defaultService.trim().toLowerCase()
          ? quality
          : state.audioQuality,
      downloadQualityByProvider: {
        ...state.downloadQualityByProvider,
        key: quality,
      },
    );
  }

  @override
  bool setDefaultDownloadExtension(
    Extension matching, {
    bool confirmed = false,
  }) {
    state = state.copyWith(defaultService: matching.id);
    return true;
  }
}

class _Extensions extends ExtensionNotifier {
  _Extensions(this.initial);
  final ExtensionState initial;
  @override
  ExtensionState build() => initial;
}

Extension _source(String id, List<QualityOption> options) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  qualityOptions: options,
);

Widget _app(AppSettings settings, List<Extension> extensions) => ProviderScope(
  overrides: [
    settingsProvider.overrideWith(() => _Settings(settings)),
    extensionProvider.overrideWith(
      () => _Extensions(
        ExtensionState(
          extensions: extensions,
          providerPriority: [for (final e in extensions) e.id],
          isInitialized: true,
        ),
      ),
    ),
  ],
  child: MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const MusicPreferencesPage(expandSectionsForTest: true),
  ),
);

void _tall(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 5000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<void> _switchTo(WidgetTester tester, Extension provider) async {
  final container = _container(tester);
  container
      .read(settingsProvider.notifier)
      .setDefaultDownloadExtension(provider);
  reconcileListenQualities(
    container.read(settingsProvider.notifier),
    container.read(settingsProvider),
    provider,
  );
  await tester.pumpAndSettle();
}

ProviderContainer _container(WidgetTester tester) => ProviderScope.containerOf(
  tester.element(find.byType(MusicPreferencesPage)),
);

void main() {
  final multi = _source('a', const [
    QualityOption(id: 'AAC_128', label: 'AAC 128 kbps', kind: 'lossy'),
    QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
    QualityOption(id: 'HI_RES', label: 'Hi-Res', kind: 'lossless'),
  ]);
  final single = _source('b', const [
    QualityOption(id: 'aac_160', label: 'AAC 160 kbps', kind: 'lossy'),
  ]);

  testWidgets('shows a single provider selection without a streaming note', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    final amazon = _source('amazon', const [
      QualityOption(id: 'opus', label: 'Opus 320 kbps', kind: 'lossy'),
      QualityOption(id: 'flac', label: 'FLAC', kind: 'lossless'),
    ]);
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'a'), [multi, amazon]),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('listen_streaming_provider_note')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('listen_provider_section')), findsNothing);
    expect(find.byKey(const ValueKey('listen_sources_link')), findsOneWidget);
  });

  testWidgets(
    'the single sources entry comes first and replaces the provider strip',
    (tester) async {
      _tall(tester);
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        _app(const AppSettings(defaultService: 'a'), [multi, single]),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('listen_provider_a')), findsNothing);
      expect(find.byKey(const ValueKey('listen_provider_b')), findsNothing);
      final provider = tester
          .getTopLeft(find.byKey(const ValueKey('listen_sources_link')))
          .dy;
      final streaming = tester
          .getTopLeft(find.text('Streaming quality').first)
          .dy;
      final download = tester
          .getTopLeft(find.text('Download quality').first)
          .dy;
      expect(provider, lessThan(streaming));
      expect(streaming, lessThan(download));
    },
  );

  testWidgets('an empty download choice becomes the lossless default', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'a'), [multi]),
    );
    await tester.pumpAndSettle();
    final settings = _container(tester).read(settingsProvider);
    expect(settings.audioQuality, 'LOSSLESS');
    expect(settings.playbackQuality, 'auto_light');
  });

  testWidgets('a provider with one quality shows it as information', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'a'), [multi, single]),
    );
    await tester.pumpAndSettle();
    await _switchTo(tester, single);
    final settings = _container(tester).read(settingsProvider);
    expect(settings.defaultService, 'b');
    expect(settings.playbackQuality, 'aac_160');
    expect(settings.audioQuality, 'aac_160');
    expect(
      find.byKey(const ValueKey('streaming_quality_single')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('download_quality_single')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('streaming_quality_auto_light')),
      findsNothing,
    );
  });

  testWidgets('switching back keeps both choices valid and never empty', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'b', playbackQuality: 'aac_160'), [
        multi,
        single,
      ]),
    );
    await tester.pumpAndSettle();
    await _switchTo(tester, multi);
    final settings = _container(tester).read(settingsProvider);
    expect(settings.defaultService, 'a');
    expect(settings.playbackQuality, 'auto_light');
    expect(settings.audioQuality, 'LOSSLESS');
  });

  testWidgets('changing provider changes the quality list in place', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    final other = _source('c', const [
      QualityOption(id: 'MP3_320', label: 'MP3 320 kbps', kind: 'lossy'),
      QualityOption(id: 'FLAC', label: 'FLAC', kind: 'lossless'),
    ]);
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'a'), [multi, other]),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('download_quality_a_HI_RES')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('download_quality_c_MP3_320')),
      findsNothing,
    );
    await _switchTo(tester, other);
    expect(
      find.byKey(const ValueKey('download_quality_a_HI_RES')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('download_quality_c_MP3_320')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('streaming_quality_MP3_320')),
      findsOneWidget,
    );
    expect(_container(tester).read(settingsProvider).audioQuality, 'FLAC');
  });

  testWidgets('choosing a quality is stored at once, without a button', (
    tester,
  ) async {
    _tall(tester);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      _app(const AppSettings(defaultService: 'a'), [multi]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('download_quality_a_HI_RES')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('streaming_quality_LOSSLESS')));
    await tester.pumpAndSettle();
    final settings = _container(tester).read(settingsProvider);
    expect(settings.audioQuality, 'HI_RES');
    expect(settings.playbackQuality, 'LOSSLESS');
    await tester.tap(
      find.byKey(const ValueKey('streaming_quality_auto_light')),
    );
    await tester.pumpAndSettle();
    expect(
      _container(tester).read(settingsProvider).playbackQuality,
      'auto_light',
    );
    expect(find.byType(FilledButton), findsNothing);
  });

  testWidgets('quality rows open and close in place when tapped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 2.75;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(
            () => _Settings(const AppSettings(defaultService: 'a')),
          ),
          extensionProvider.overrideWith(
            () => _Extensions(
              ExtensionState(
                extensions: [multi],
                providerPriority: const ['a'],
                isInitialized: true,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MusicPreferencesPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('download_quality_a_HI_RES')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('section_header_download')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('download_quality_a_HI_RES')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('section_header_download')));
    await tester.pump(const Duration(milliseconds: 220));
    expect(
      find.byKey(const ValueKey('download_quality_a_HI_RES')),
      findsNothing,
    );
  });

  group('default download quality per provider', () {
    String? pick(List<QualityOption> options) =>
        defaultDownloadQualityOf(options)?.id;

    test('tidal-web: standard lossless, not hi-res', () {
      expect(
        pick(const [
          QualityOption(id: 'LOW', label: 'Low', kind: 'lossy'),
          QualityOption(id: 'HIGH', label: 'High', kind: 'lossy'),
          QualityOption(id: 'LOSSLESS', label: 'FLAC', kind: 'lossless'),
          QualityOption(
            id: 'HI_RES_LOSSLESS',
            label: 'Hi-Res 24-bit',
            kind: 'lossless',
          ),
        ]),
        'LOSSLESS',
      );
    });

    test('deezer and qobuz with only lossless: the standard one', () {
      expect(
        pick(const [
          QualityOption(id: 'flac', label: 'FLAC', kind: 'lossless'),
        ]),
        'flac',
      );
      expect(
        pick(const [
          QualityOption(id: 'HI_RES', label: 'Hi-Res 24-bit', kind: 'lossless'),
          QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
        ]),
        'LOSSLESS',
      );
    });

    test('amazon: best available over opus and spatial', () {
      expect(
        pick(const [
          QualityOption(id: 'best', label: 'Best'),
          QualityOption(id: 'opus', label: 'Opus 320 kbps', kind: 'lossy'),
          QualityOption(id: 'eac3', label: 'Dolby Atmos', kind: 'spatial'),
        ]),
        'best',
      );
    });

    test('jiosaavn picks AAC 320 and soundcloud its only tier', () {
      expect(
        pick(const [
          QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
          QualityOption(id: 'AAC_160', label: 'AAC 160 kbps', kind: 'lossy'),
          QualityOption(id: 'AAC_320', label: 'AAC 320 kbps', kind: 'lossy'),
        ]),
        'AAC_320',
      );
      expect(
        pick(const [
          QualityOption(id: 'aac_160', label: 'AAC 160 kbps', kind: 'lossy'),
        ]),
        'aac_160',
      );
    });
  });
}
