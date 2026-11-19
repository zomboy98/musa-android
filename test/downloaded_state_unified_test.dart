import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_download_removal.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/downloaded_format_mark.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/track_list_tile.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/fixed_settings.dart';

class _History extends DownloadHistoryNotifier {
  _History(this.initial);
  final List<DownloadHistoryItem> initial;
  @override
  DownloadHistoryState build() =>
      DownloadHistoryState(items: initial, totalCount: initial.length);
}

class _Library extends LocalLibraryNotifier {
  @override
  LocalLibraryState build() => LocalLibraryState();
}

const _albumTrack = Track(
  id: 'album-from-search-1',
  name: 'SANA SANA',
  artistName: 'Chuyin',
  albumName: 'Los Locos Nunca Mueren',
  duration: 180,
  isrc: 'ESABC2400011',
);

const _playlistTrack = Track(
  id: 'playlist-entry-9',
  name: 'SANA SANA',
  artistName: 'Chuyin',
  albumName: 'Los Locos Nunca Mueren',
  duration: 180,
  isrc: 'ESABC2400011',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('downloaded-unified-');
    final previous = databaseFactoryOrNull;
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    const paths = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(paths, (_) async => root.path);
    addTearDown(() async {
      await LibraryDatabase.instance.close();
      await HistoryDatabase.instance.close();
      messenger.setMockMethodCallHandler(paths, null);
      databaseFactory = previous;
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // A just-closed database file may stay locked for a moment on Windows.
      }
    });
  });

  Future<String> scannedFile({String? isrc, int duration = 180}) async {
    final path = '${root.path}/11 - SANA SANA.m4a';
    await File(path).writeAsBytes([1, 2, 3]);
    await LibraryDatabase.instance.upsertBatchExcludingHistory([
      LocalLibraryItem(
        id: 'scan-1',
        trackName: 'SANA SANA',
        artistName: 'Chuyin',
        albumName: 'Los Locos Nunca Mueren',
        filePath: path,
        scannedAt: DateTime(2026),
        isrc: isrc,
        duration: duration,
      ).toJson(),
    ], sourceId: LocalLibraryItem.legacySourceId);
    return path;
  }

  Future<String> historyFile({
    required String isrc,
    required int duration,
  }) async {
    final path = '${root.path}/11 - SANA SANA.m4a';
    await File(path).writeAsBytes([1, 2, 3]);
    await HistoryDatabase.instance.upsertBatch([
      DownloadHistoryItem(
        id: 'h1',
        trackName: 'SANA SANA',
        artistName: 'Chuyin',
        albumName: 'Los Locos Nunca Mueren',
        filePath: path,
        service: 'example-provider',
        spotifyId: 'history-1',
        isrc: isrc,
        duration: duration,
        downloadedAt: DateTime(2026),
      ).toJson(),
    ]);
    return path;
  }

  ProviderContainer containerFor() {
    final container = ProviderContainer(
      overrides: [
        localLibraryProvider.overrideWith(_Library.new),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            const AppSettings(
              localLibraryEnabled: true,
              localLibraryShowDuplicates: true,
            ),
          ),
        ),
        downloadQueueProvider.overrideWith(DownloadQueueNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<bool> isDownloaded(ProviderContainer container, Track track) async {
    final subscription = container.listen(
      playlistRealDownloadProvider(track),
      (_, _) {},
    );
    addTearDown(subscription.close);
    return container.read(playlistRealDownloadProvider(track).future);
  }

  test(
    'a file known only to the scanned library counts as downloaded in every view',
    () async {
      await scannedFile();
      final container = containerFor();
      expect(await isDownloaded(container, _playlistTrack), isTrue);
      expect(await isDownloaded(container, _albumTrack), isTrue);
    },
  );

  test(
    'the same song under another ISRC and the same length is one download',
    () async {
      final path = await historyFile(isrc: 'ESXYZ2400099', duration: 181);
      final container = containerFor();
      expect(await isDownloaded(container, _albumTrack), isTrue);

      final deleted = await removeTrackDownloads(container, _albumTrack);
      expect(deleted, 1);
      expect(File(path).existsSync(), isFalse);
      container.invalidate(playlistRealDownloadProvider(_albumTrack));
      expect(await isDownloaded(container, _albumTrack), isFalse);
      expect(await isDownloaded(container, _playlistTrack), isFalse);
    },
  );

  test(
    'another ISRC with a very different length is another recording',
    () async {
      await historyFile(isrc: 'ESXYZ2400099', duration: 260);
      final container = containerFor();
      expect(await isDownloaded(container, _albumTrack), isFalse);
    },
  );

  test(
    'a row of another recording is downloaded in neither the album nor the playlist',
    () async {
      final path = '${root.path}/other.m4a';
      await File(path).writeAsBytes([1]);
      final other = DownloadHistoryItem(
        id: 'h2',
        trackName: 'SANA SANA',
        artistName: 'Chuyin',
        albumName: 'Single',
        filePath: path,
        service: 'example-provider',
        spotifyId: 'history-2',
        isrc: 'ESXYZ2400099',
        downloadedAt: DateTime(2026),
      );
      await HistoryDatabase.instance.upsertBatch([other.toJson()]);
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => _History([other])),
          localLibraryProvider.overrideWith(_Library.new),
          downloadQueueProvider.overrideWith(DownloadQueueNotifier.new),
        ],
      );
      addTearDown(container.dispose);
      expect(await isDownloaded(container, _albumTrack), isFalse);
      expect(await isDownloaded(container, _playlistTrack), isFalse);
    },
  );

  Future<void> pumpRow(WidgetTester tester) async {
    final container = containerFor();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: TrackListTile(
              track: _albumTrack,
              isInHistory: false,
              clickableArtist: false,
              onDownload: ({bool forceQualityPicker = false}) {},
              leading: const SizedBox(width: 32, child: Text('1')),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 40)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets(
    'album row from search: the blue check is reachable with a finger and deletes the file',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final path = (await tester.runAsync(scannedFile))!;
      await pumpRow(tester);
      await settle(tester);

      final check = find.byKey(const ValueKey('download-library-track'));
      expect(tester.getSize(check).width, greaterThanOrEqualTo(44));
      expect(tester.getSize(check).height, greaterThanOrEqualTo(44));
      expect(find.byType(DownloadedFormatMark), findsOneWidget);

      await tester.tap(check);
      await settle(tester);

      expect(File(path).existsSync(), isFalse);
      expect(find.byType(DownloadedFormatMark), findsNothing);
    },
  );
}
