import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/quality_replace_result.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/local_file_catalog_track_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tidalOptions = [
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(
    id: 'HI_RES_LOSSLESS',
    label: 'Hi-Res 24-bit',
    kind: 'lossless',
  ),
];

const _amazonOptions = [
  QualityOption(id: 'best', label: 'Best', kind: 'lossless'),
  QualityOption(id: 'ac4', label: 'Dolby Atmos (AC-4)', kind: 'spatial'),
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
  @override
  ExtensionState build() {
    final all = [
      _extension('amazon', _amazonOptions),
      _extension('tidal', _tidalOptions),
    ];
    return ExtensionState(
      isInitialized: true,
      providerPriority: [for (final e in all) e.id],
      extensions: all,
    );
  }
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
  _Queue({this.fake});

  final QualityReplaceResult? fake;
  final asked = <({String service, String quality, String previous})>[];

  @override
  DownloadQueueState build() {
    super.build();
    return const DownloadQueueState().copyWith(isProcessing: true);
  }

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
  }) {
    asked.add((service: service, quality: qualityId, previous: previousPath));
    final answer = fake;
    if (answer != null) return Future.value(answer);
    return super.replaceTrackQuality(
      track,
      service,
      qualityId,
      previousPath: previousPath,
      previousHistoryId: previousHistoryId,
      onReady: onReady,
      timeout: timeout,
      measureDuration: (_) async => 180,
    );
  }

  void finishLast(String path) => updateItemStatus(
    state.items.last.id,
    DownloadStatus.completed,
    filePath: path,
  );
}

Future<TrackQualitySelector> _pump(
  WidgetTester tester,
  _Queue queue,
  String path, {
  required String isrc,
}) async {
  SharedPreferences.setMockInitialValues({});
  final metadata = PlayerMetadataController(
    readMetadata: (_) async => const {'format': 'opus', 'bitrate': 332},
  );
  addTearDown(metadata.dispose);
  await tester.runAsync(
    () => metadata.load(
      MediaItem(
        id: path,
        title: 'Titulo',
        artist: 'Artist',
        album: 'Album',
        duration: const Duration(seconds: 180),
        extras: {
          'source': path,
          'verifiedAudioCodec': 'opus',
          'verifiedAudioSampleRate': 48000,
          'isrc': isrc,
        },
      ),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        extensionProvider.overrideWith(_Extensions.new),
        settingsProvider.overrideWith(_Settings.new),
        downloadHistoryProvider.overrideWith(_History.new),
        downloadQueueProvider.overrideWith(() => queue),
        downloadHistoryForFileProvider(path).overrideWith((ref) => null),
        localFileCatalogTrackProvider(path).overrideWith((ref) => null),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
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
  return tester.widget<TrackQualitySelector>(find.byType(TrackQualitySelector));
}

Future<void> _settle(
  WidgetTester tester, {
  required bool Function() until,
  int rounds = 60,
}) async {
  for (var i = 0; i < rounds && !until(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
  }
}

AppLocalizations _l10n(WidgetTester tester) =>
    AppLocalizations.of(tester.element(find.byType(Scaffold)));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File previous;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('musa_local_queue_');
    previous = File('${dir.path}/Titulo.m4a')..writeAsStringSync('old');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  testWidgets('a failed switch in a queue of local files keeps every format '
      'listed, marks the one that failed and lets it be asked again', (
    tester,
  ) async {
    final queue = _Queue(
      fake: const QualityReplaceResult.failed(
        QualityReplaceFailure.downloadFailed,
        detail: 'Requested quality unavailable from this provider',
        errorType: DownloadErrorType.qualityUnavailable,
        summary: 'stage_backend_download, error_type_quality_unavailable',
      ),
    );
    final selector = await _pump(
      tester,
      queue,
      previous.path,
      isrc: 'USFAIL000001',
    );
    final before = [for (final c in selector.choices) '${c.service}/${c.id}'];
    expect(before, contains('amazon/ac4'));
    expect(before, contains('tidal/HI_RES_LOSSLESS'));

    selector.onSelected(
      selector.choices.firstWhere((c) => c.service == 'amazon' && c.id == 'ac4'),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(queue.asked.single.service, 'amazon');
    expect(queue.asked.single.quality, 'ac4');
    expect(queue.asked.single.previous, previous.path);
    final after = tester.widget<TrackQualitySelector>(
      find.byType(TrackQualitySelector),
    );
    expect([for (final c in after.choices) '${c.service}/${c.id}'], before);
    final failed = after.choices.firstWhere(
      (c) => c.service == 'amazon' && c.id == 'ac4',
    );
    expect(failed.failedLast, isTrue);
    expect(failed.available, isTrue);
    expect(
      after.choices.where((c) => c.failedLast).map((c) => c.id),
      ['ac4'],
    );

    final l10n = _l10n(tester);
    expect(
      find.text(
        l10n.qualityReplaceDownloadFailed(
          l10n.failureQualityUnavailable,
        ),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text(l10n.qualityPickerSwitchDetails));
    await tester.pumpAndSettle();
    final body = tester
        .widget<SelectableText>(find.byType(SelectableText))
        .data!;
    expect(body, contains('ac4'));
    expect(body, contains('Amazon'));
    expect(body, contains('Requested quality unavailable'));
    expect(body, contains('error_type_quality_unavailable'));
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();

    after.onSelected(failed);
    await tester.pump();
    expect(queue.asked.length, 2);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('a format picked in a queue of local files is downloaded, '
      'checked and replaces the old file', (tester) async {
    final queue = _Queue();
    final selector = await _pump(
      tester,
      queue,
      previous.path,
      isrc: 'USOKAY000001',
    );
    final fresh = File('${dir.path}/Titulo - 24bit.flac')
      ..writeAsStringSync('new');

    selector.onSelected(
      selector.choices.firstWhere(
        (c) => c.service == 'tidal' && c.id == 'HI_RES_LOSSLESS',
      ),
    );
    await tester.pump();
    expect(queue.asked.single.quality, 'HI_RES_LOSSLESS');
    expect(queue.state.items.last.qualityOverride, 'HI_RES_LOSSLESS');
    expect(queue.state.items.last.service, 'tidal');
    expect(queue.state.items.last.preserveQualityVariant, isTrue);

    queue.finishLast(fresh.path);
    final finalFile = File('${dir.path}/Titulo.flac');
    await _settle(
      tester,
      until: () => !previous.existsSync() && finalFile.existsSync(),
    );
    await _settle(
      tester,
      until: () => find
          .text(_l10n(tester).qualityReplacedReload)
          .evaluate()
          .isNotEmpty,
    );

    expect(previous.existsSync(), isFalse);
    expect(finalFile.existsSync(), isTrue);
    expect(finalFile.readAsStringSync(), 'new');
    expect(fresh.existsSync(), isFalse);
    expect(find.text(_l10n(tester).qualityReplacedReload), findsOneWidget);
    expect(
      SpecialQualityAvailability.instance.attemptFailed(
        Track(
          id: previous.path,
          name: 'Titulo',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 180,
          isrc: 'USOKAY000001',
        ),
        'tidal',
        'HI_RES_LOSSLESS',
      ),
      isFalse,
    );
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('the provider handing back the very same file is reported as '
      'such, not as a failed download', (tester) async {
    final queue = _Queue();
    final selector = await _pump(
      tester,
      queue,
      previous.path,
      isrc: 'USSAME000001',
    );
    selector.onSelected(
      selector.choices.firstWhere(
        (c) => c.service == 'tidal' && c.id == 'HI_RES_LOSSLESS',
      ),
    );
    await tester.pump();
    queue.finishLast(previous.path);
    await _settle(tester, until: () => false, rounds: 8);
    await tester.pump(const Duration(milliseconds: 600));

    expect(previous.existsSync(), isTrue);
    final l10n = _l10n(tester);
    expect(find.text(l10n.qualityReplaceNoOtherFormat), findsOneWidget);
    final after = tester.widget<TrackQualitySelector>(
      find.byType(TrackQualitySelector),
    );
    expect(after.choices.any((c) => c.failedLast), isFalse);
    await tester.pump(const Duration(seconds: 11));
  });
}
