import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/quality_replace_result.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_file_catalog_track_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _path = '/storage/emulated/0/Music/MUSA/Artist/Album/01 - Titulo.m4a';

const _options = [
  QualityOption(id: 'AAC_96', label: 'AAC 96 kbps', kind: 'lossy'),
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(
    id: 'HI_RES_LOSSLESS',
    label: 'Hi-Res 24-bit',
    kind: 'lossless',
  ),
];

const _amazonOptions = [
  QualityOption(id: 'best', label: 'Best', kind: 'lossless'),
  QualityOption(id: 'opus', label: 'OPUS 320', kind: 'lossy'),
  QualityOption(id: 'ac4', label: 'Dolby Atmos (AC-4)', kind: 'spatial'),
  QualityOption(id: 'eac3', label: 'Dolby Digital Plus', kind: 'spatial'),
];

Extension _extension(String id, List<QualityOption> options) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1.0.0',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  qualityOptions: options,
);

class _Extensions extends ExtensionNotifier {
  _Extensions(this.extensions);

  final List<Extension> extensions;

  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    providerPriority: [for (final e in extensions) e.id],
    extensions: extensions,
  );
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(defaultService: 'tidal', audioQuality: 'LOSSLESS');
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Queue extends DownloadQueueNotifier {
  final replaced = <({String service, String quality, String previous})>[];

  @override
  Future<QualityReplaceResult> replaceTrackQuality(
    Track track,
    String service,
    String qualityId, {
    required String previousPath,
    required String previousHistoryId,
    Future<bool> Function(String newPath)? onReady,
    Duration timeout = const Duration(minutes: 30),
    Future<int?> Function(String path)? measureDuration,
  }) async {
    replaced.add((
      service: service,
      quality: qualityId,
      previous: previousPath,
    ));
    return const QualityReplaceResult.failed(QualityReplaceFailure.cancelled);
  }
}

final _downloaded = DownloadHistoryItem(
  id: 'row-1',
  trackName: 'Titulo',
  artistName: 'Artist',
  albumName: 'Album',
  filePath: _path,
  service: 'amazon',
  downloadedAt: DateTime(2026, 1, 1),
  isrc: 'USAAA0000001',
);

const _match = Track(
  id: 'provider-song',
  name: 'Titulo',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 100,
  isrc: 'USAAA0000001',
);

final _defaultExtensions = [
  _extension('amazon', _amazonOptions),
  _extension('tidal', _options),
  _extension('deezer', _options),
];

Future<(TrackQualitySelector, _Queue)> _selector(
  WidgetTester tester, {
  List<Extension>? extensions,
  Track? libraryMatch,
  DownloadHistoryItem? stored,
  Map<String, Object?> extras = const {'isrc': 'USAAA0000001'},
}) async {
  SharedPreferences.setMockInitialValues({});
  final queue = _Queue();
  final metadata = PlayerMetadataController(
    readMetadata: (_) async => const {'format': 'opus', 'bitrate': 332},
  );
  addTearDown(metadata.dispose);
  await tester.runAsync(
    () => metadata.load(
      MediaItem(
        id: _path,
        title: 'Titulo',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(seconds: 100),
        extras: {
          'source': _path,
          'verifiedAudioCodec': 'opus',
          'verifiedAudioSampleRate': 48000,
          ...extras,
        },
      ),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionProvider.overrideWith(
          () => _Extensions(extensions ?? _defaultExtensions),
        ),
        settingsProvider.overrideWith(_Settings.new),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadQueueProvider.overrideWith(() => queue),
        downloadHistoryForFileProvider(_path).overrideWith((ref) => stored),
        localFileCatalogTrackProvider(
          _path,
        ).overrideWith((ref) => libraryMatch),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerCoverQuality(
            metadata: metadata,
            colorScheme: const ColorScheme.dark(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return (
    tester.widget<TrackQualitySelector>(find.byType(TrackQualitySelector)),
    queue,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a downloaded file with no history row and no library row '
      'offers every provider quality, by the media item identity', (
    tester,
  ) async {
    final (selector, _) = await _selector(tester);
    final services = {
      for (final c in selector.choices) ...c.candidates.map((x) => x.service),
    };
    expect(services, containsAll(['amazon', 'tidal', 'deezer']));
    final amazon = [
      for (final c in selector.choices)
        for (final x in c.candidates)
          if (x.service == 'amazon') x.id,
    ];
    expect(amazon, containsAll(['opus', 'ac4', 'eac3']));
    expect(selector.replacesFile, isTrue);
    expect(selector.noOffersNote, isNull);
  });

  testWidgets('the same format from two providers is one row that lists both', (
    tester,
  ) async {
    final (selector, _) = await _selector(tester);
    final alike = selector.choices.where(
      (c) => c.candidates.any((x) => x.id == 'HI_RES_LOSSLESS'),
    );
    expect(alike.length, 1);
    expect(alike.single.candidates.map((c) => c.service).toSet(), {
      'tidal',
      'deezer',
    });
  });

  testWidgets('a file with no ISRC still offers qualities from its title '
      'and artist', (tester) async {
    final (selector, _) = await _selector(tester, extras: const {});
    expect(selector.choices.length, greaterThan(1));
    expect(selector.replacesFile, isTrue);
  });

  testWidgets('a history row stored under another form of the path is '
      'found and replaced with its id', (tester) async {
    final (selector, queue) = await _selector(tester, stored: _downloaded);
    expect(selector.replacesFile, isTrue);
    final choice = selector.choices.firstWhere(
      (c) => c.candidates.any((x) => x.id == 'HI_RES_LOSSLESS'),
    );
    selector.onSelected(choice);
    await tester.pump();
    expect(queue.replaced.single.service, 'deezer');
    expect(queue.replaced.single.quality, 'HI_RES_LOSSLESS');
    expect(queue.replaced.single.previous, _path);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('choosing a quality of a file without history replaces the '
      'file at its path', (tester) async {
    final (selector, queue) = await _selector(tester);
    final choice = selector.choices.firstWhere(
      (c) => c.service == 'amazon' && c.id == 'eac3',
    );
    selector.onSelected(choice);
    await tester.pump();
    expect(queue.replaced.single.service, 'amazon');
    expect(queue.replaced.single.quality, 'eac3');
    expect(queue.replaced.single.previous, _path);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('a library match stands in when the media item has no ISRC', (
    tester,
  ) async {
    final (selector, _) = await _selector(
      tester,
      extras: const {},
      libraryMatch: _match,
    );
    expect(selector.choices.length, greaterThan(1));
    expect(selector.replacesFile, isTrue);
  });

  testWidgets('with no download provider enabled the panel says so', (
    tester,
  ) async {
    final (selector, _) = await _selector(tester, extensions: const []);
    expect(selector.choices.length, lessThanOrEqualTo(1));
    expect(selector.noOffersNote, isNotNull);
  });

  test('only files on the device count as local sources', () {
    expect(localSourceKind('/storage/emulated/0/Music/a.m4a'), 'path');
    expect(localSourceKind('content://tree/doc'), 'saf');
    expect(localSourceKind('network://server/a.flac'), isNull);
    expect(localSourceKind('https://host/a.flac'), isNull);
    expect(localSourceKind(null), isNull);
  });
}
