import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/album_quality_provider.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/utils/album_quality.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/track_quality_choices.dart';
import 'package:mornye/widgets/album_quality_badge.dart';
import 'package:mornye/widgets/quality_badge_art.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _options = [
  QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(
    id: 'HI_RES_LOSSLESS',
    label: 'Hi-Res 24-bit',
    kind: 'lossless',
  ),
];

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    providerPriority: ['tidal'],
    extensions: [
      Extension(
        id: 'tidal',
        name: 'tidal',
        displayName: 'Tidal',
        version: '1.0.0',
        description: '',
        enabled: true,
        status: 'loaded',
        hasDownloadProvider: true,
        qualityOptions: _options,
      ),
    ],
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(defaultService: 'tidal', audioQuality: 'LOSSLESS');
}

class _History extends DownloadHistoryNotifier {
  _History(this.items);

  final List<DownloadHistoryItem> items;

  @override
  DownloadHistoryState build() => DownloadHistoryState(items: items);
}

const _tracks = [
  Track(
    id: 'a',
    name: 'Uno',
    artistName: 'Artista',
    albumName: 'Album',
    duration: 100,
    isrc: 'USAAA0000001',
  ),
  Track(
    id: 'b',
    name: 'Dos',
    artistName: 'Artista',
    albumName: 'Album',
    duration: 100,
    isrc: 'USAAA0000002',
  ),
];

DownloadHistoryItem _download(
  Track track,
  String quality, {
  String album = 'Album',
  String? format,
  int? sampleRate,
  int? bitDepth,
}) => DownloadHistoryItem(
  id: 'h-${track.id}',
  trackName: track.name,
  artistName: track.artistName,
  albumName: album,
  filePath: '/music/${track.id}.flac',
  service: 'tidal',
  downloadedAt: DateTime(2026, 11, 1),
  isrc: track.isrc,
  quality: quality,
  format: format,
  sampleRate: sampleRate,
  bitDepth: bitDepth,
);

class _Replace {
  final calls = <({String track, String quality, String previous})>[];

  Future<String?> call(
    Track track,
    String service,
    String qualityId, {
    required String previousPath,
    required String previousHistoryId,
  }) async {
    calls.add((track: track.id, quality: qualityId, previous: previousPath));
    return '/music/new-${track.id}.flac';
  }
}

Widget _host(
  List<DownloadHistoryItem> history,
  _Replace replace, {
  double width = 320,
  double fontScale = 1,
}) => ProviderScope(
  overrides: [
    extensionProvider.overrideWith(_Extensions.new),
    settingsProvider.overrideWith(_Settings.new),
    downloadHistoryProvider.overrideWith(() => _History(history)),
    trackQualityReplaceProvider.overrideWithValue(replace.call),
  ],
  child: MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: MediaQuery(
      data: MediaQueryData(
        size: Size(width, 640),
        textScaler: TextScaler.linear(fontScale),
      ),
      child: const Scaffold(
        body: Center(
          child: AlbumQualityBadge(
            albumName: 'Album',
            artistName: 'Artista',
            catalogTracks: _tracks,
          ),
        ),
      ),
    ),
  ),
);

ProviderContainer _container(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AlbumQualityBadge)));

QualityBadgeFormat _shown(WidgetTester tester) => tester
    .widget<TrackQualitySelector>(find.byType(TrackQualitySelector))
    .currentFormat;

Future<void> _pick(WidgetTester tester, String label) async {
  await tester.tap(find.byType(TrackQualitySelector));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
  await tester.tap(
    find.descendant(
      of: find.byKey(const ValueKey('track-quality-panel')),
      matching: find.byWidgetPredicate(
        (w) => w is QualityBadgeArt && w.semanticLabel == label,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('shows the quality a download would use before any download', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const [], _Replace()));
    await tester.pumpAndSettle();
    expect(find.byType(QualityBadgeArt), findsOneWidget);
    expect(_shown(tester), QualityBadgeFormat.flac);
    final art = tester.widget<QualityBadgeArt>(find.byType(QualityBadgeArt));
    expect(art.size, greaterThanOrEqualTo(28));
  });

  testWidgets('tapping opens the formats window', (tester) async {
    await tester.pumpWidget(_host(const [], _Replace()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
    expect(find.text('FLAC 16-bit'), findsNothing);
  });

  testWidgets('not downloaded: the choice is stored for the album only', (
    tester,
  ) async {
    final replace = _Replace();
    await tester.pumpWidget(_host(const [], replace));
    await tester.pumpAndSettle();
    await _pick(tester, 'Hi-Res 24-bit');
    final container = _container(tester);
    expect(container.read(albumQualityChoicesProvider), {
      albumQualityKey('Album', 'Artista'): 'HI_RES_LOSSLESS',
    });
    expect(container.read(settingsProvider).audioQuality, 'LOSSLESS');
    expect(find.byType(AlertDialog), findsNothing);
    expect(replace.calls, isEmpty);
    expect(_shown(tester), QualityBadgeFormat.hiRes);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(AlbumQualityChoices.storageKey),
      contains('HI_RES_LOSSLESS'),
    );
  });

  testWidgets('downloaded: asks first and replaces every song one by one', (
    tester,
  ) async {
    final replace = _Replace();
    await tester.pumpWidget(
      _host([
        _download(_tracks[0], 'LOSSLESS'),
        _download(_tracks[1], 'LOSSLESS'),
      ], replace),
    );
    await tester.pumpAndSettle();
    expect(_shown(tester), QualityBadgeFormat.flac);
    await _pick(tester, 'Hi-Res 24-bit');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.textContaining('2 songs'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(replace.calls, isEmpty);
    expect(_container(tester).read(albumQualityChoicesProvider), isEmpty);

    await _pick(tester, 'Hi-Res 24-bit');
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(replace.calls.map((c) => c.track), ['a', 'b']);
    expect(replace.calls.every((c) => c.quality == 'HI_RES_LOSSLESS'), isTrue);
    expect(replace.calls.map((c) => c.previous), [
      '/music/a.flac',
      '/music/b.flac',
    ]);
    final container = _container(tester);
    expect(container.read(albumQualityChoicesProvider).values, [
      'HI_RES_LOSSLESS',
    ]);
    expect(container.read(settingsProvider).audioQuality, 'LOSSLESS');
    final progress = container.read(albumQualityReplacerProvider).values.single;
    expect(progress.running, isFalse);
    expect(progress.done, 2);
  });

  testWidgets('mixed album shows its lowest tied quality and a caption', (
    tester,
  ) async {
    final replace = _Replace();
    await tester.pumpWidget(
      _host([
        _download(_tracks[0], 'LOSSLESS'),
        _download(_tracks[1], 'HI_RES_LOSSLESS'),
      ], replace),
    );
    await tester.pumpAndSettle();
    expect(_shown(tester), QualityBadgeFormat.flac);
    expect(find.text('Mixed qualities'), findsOneWidget);
    await _pick(tester, 'Hi-Res 24-bit');
    expect(find.textContaining('1 song'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await tester.pumpAndSettle();
    expect(replace.calls.map((c) => c.track), ['a']);
  });

  testWidgets('other albums are not touched', (tester) async {
    final replace = _Replace();
    await tester.pumpWidget(
      _host([_download(_tracks[0], 'AAC_96', album: 'Otro album')], replace),
    );
    await tester.pumpAndSettle();
    expect(_shown(tester), QualityBadgeFormat.flac);
    await _pick(tester, 'Hi-Res 24-bit');
    expect(find.byType(AlertDialog), findsNothing);
    expect(replace.calls, isEmpty);
  });

  for (final (width, scale) in [(320.0, 1.0), (320.0, 2.0)]) {
    testWidgets('no overflow at ${width}dp and text x$scale', (tester) async {
      await tester.pumpWidget(
        _host(
          [
            _download(_tracks[0], 'LOSSLESS'),
            _download(_tracks[1], 'HI_RES_LOSSLESS'),
          ],
          _Replace(),
          width: width,
          fontScale: scale,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlbumQualityBadge), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test(
    'the lowest tied format wins and the choice survives a restart',
    () async {
      const choices = <TrackQualityChoice>[];
      final view = resolveAlbumQuality(
        downloads: [
          _download(_tracks[0], 'AAC_96'),
          _download(_tracks[1], 'LOSSLESS'),
        ],
        choices: choices,
      );
      expect(view?.format, QualityBadgeFormat.aac);
      expect(view?.mixed, isTrue);
      expect(view?.downloaded, isTrue);

      final first = ProviderContainer();
      addTearDown(first.dispose);
      await first
          .read(albumQualityChoicesProvider.notifier)
          .choose('k', 'HI_RES_LOSSLESS');
      final second = ProviderContainer();
      addTearDown(second.dispose);
      second.read(albumQualityChoicesProvider);
      await second.read(albumQualityChoicesProvider.notifier).ready;
      expect(second.read(albumQualityChoicesProvider), {
        'k': 'HI_RES_LOSSLESS',
      });
    },
  );

  testWidgets('shows the real mark of the downloaded codec, bare', (
    tester,
  ) async {
    final history = [
      _download(_tracks[0], 'AAC_96', format: 'mp3'),
      _download(_tracks[1], 'AAC_96', format: 'mp3'),
    ];
    await tester.pumpWidget(_host(history, _Replace()));
    await tester.pumpAndSettle();
    final art = tester.widget<QualityBadgeArt>(find.byType(QualityBadgeArt));
    expect(art.mark, QualityMark.mp3);
    final selector = tester.widget<TrackQualitySelector>(
      find.byType(TrackQualitySelector),
    );
    expect(selector.currentMark, QualityMark.mp3);
    expect(find.byType(DecoratedBox), findsNothing);
    expect(find.byIcon(Icons.unfold_more_rounded), findsNothing);
  });

  testWidgets('opus files show the OPUS mark and tapping opens the window', (
    tester,
  ) async {
    final history = [_download(_tracks[0], 'AAC_96', format: 'opus')];
    await tester.pumpWidget(_host(history, _Replace()));
    await tester.pumpAndSettle();
    expect(
      tester.widget<QualityBadgeArt>(find.byType(QualityBadgeArt)).mark,
      QualityMark.opus,
    );
    await tester.tap(find.byType(TrackQualitySelector));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('track-quality-panel')), findsOneWidget);
  });

  test('resolveAlbumQuality derives the mark from the verified codec', () {
    final view = resolveAlbumQuality(
      downloads: [_download(_tracks[0], '', format: 'flac', sampleRate: 96000)],
      choices: const [],
    );
    expect(view?.mark, QualityMark.hiRes);
    final plain = resolveAlbumQuality(
      downloads: [_download(_tracks[0], '', format: 'flac', sampleRate: 44100)],
      choices: const [],
    );
    expect(plain?.mark, QualityMark.flac);
  });
}
