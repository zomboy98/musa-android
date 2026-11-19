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
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/widgets/download_progress_icon.dart';
import 'package:mornye/widgets/playlist_download_status.dart';
import 'package:mornye/widgets/save_library_track_button.dart';
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

DownloadHistoryItem _row(String id, String path) => DownloadHistoryItem(
  id: id,
  trackName: 'Los Locos Nunca Mueren',
  artistName: 'Chuyin',
  albumName: 'Los Locos Nunca Mueren',
  filePath: path,
  service: 'example-provider',
  spotifyId: 'history-$id',
  isrc: 'ESABC2400001',
  downloadedAt: DateTime(2026),
);

const _searchedTrack = Track(
  id: 'catalog-from-search',
  name: 'Los Locos Nunca Mueren',
  artistName: 'Chuyin',
  albumName: 'Los Locos Nunca Mueren',
  duration: 100,
  isrc: 'ES-ABC-24-00001',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('downloaded-state-');
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

  Future<List<DownloadHistoryItem>> seed(List<String> names) async {
    final items = [
      for (var i = 0; i < names.length; i++)
        _row('d$i', '${root.path}/${names[i]}'),
    ];
    for (final name in names) {
      await File('${root.path}/$name').writeAsBytes([1]);
    }
    await HistoryDatabase.instance.upsertBatch([
      for (final item in items) item.toJson(),
    ]);
    return items;
  }

  ProviderContainer containerFor(
    List<DownloadHistoryItem> items, {
    FileExistenceCheck? check,
  }) {
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => _History(items)),
        localLibraryProvider.overrideWith(_Library.new),
        if (check != null)
          historyFileExistenceCheckProvider.overrideWithValue(check),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  final request = HistoryBatchLookupRequest.snapshot([
    historyLookupForTrack(_searchedTrack),
  ]);

  Future<Set<String>> visibleKeys(ProviderContainer container) async {
    final provider = downloadHistoryVisibleBatchExistsProvider(request);
    final subscription = container.listen(provider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(downloadHistoryBatchExistsProvider(request).future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await container.pump();
    return container.read(provider);
  }

  test(
    'an album opened from search stops marking a track whose file is gone',
    () async {
      final items = await seed(['a.flac']);
      final container = containerFor(items);
      expect(await visibleKeys(container), {request.lookupKeys.single});

      await File(items.single.filePath).delete();
      container.invalidate(historyFilePresenceProvider);
      container.invalidate(downloadHistoryBatchExistsProvider(request));
      expect(await visibleKeys(container), isEmpty);
    },
  );

  test('an inconclusive existence check keeps the download marked', () async {
    final items = await seed(['a.flac']);
    await File(items.single.filePath).delete();
    final container = containerFor(
      items,
      check: (paths) async => {for (final path in paths) path: null},
    );
    expect(await visibleKeys(container), {request.lookupKeys.single});
  });

  test('a stale row does not hide another copy that still exists', () async {
    final items = await seed(['a.flac', 'b.flac']);
    await File(items.first.filePath).delete();
    final container = containerFor(items);
    expect(await visibleKeys(container), {request.lookupKeys.single});
  });

  test(
    'removing a track deletes every file behind it and clears all views',
    () async {
      final items = await seed(['a.flac', 'b.flac']);
      final container = containerFor(items);
      expect(await visibleKeys(container), {request.lookupKeys.single});

      final deleted = await removeTrackDownloads(container, _searchedTrack);

      expect(deleted, 2);
      for (final item in items) {
        expect(File(item.filePath).existsSync(), isFalse);
      }
      expect(await visibleKeys(container), isEmpty);
      final persisted = await HistoryDatabase.instance
          .findAllExistingTrackFiles(request.tracks);
      expect(persisted.single, isEmpty);
    },
  );

  testWidgets('tapping the blue check removes the download everywhere', (
    tester,
  ) async {
    final items = await tester.runAsync(() => seed(['a.flac']));
    final path = items!.single.filePath;
    final store = await tester.runAsync(() async {
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      return store;
    });
    final container = ProviderContainer(
      overrides: [
        downloadHistoryProvider.overrideWith(() => _History(items)),
        localLibraryProvider.overrideWith(_Library.new),
        catalogAudioStoreProvider.overrideWithValue(Future.value(store)),
        persistentCatalogAudioProvider.overrideWithValue((_) async => false),
        playlistRealDownloadProvider(_searchedTrack).overrideWith((ref) async {
          ref.watch(historyFilePresenceProvider);
          return File(path).existsSync();
        }),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(const AppSettings()),
        ),
        downloadQueueProvider.overrideWith(DownloadQueueNotifier.new),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: SaveLibraryTrackButton(track: _searchedTrack),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    bool showsCheck() => find
        .descendant(
          of: find.byKey(const ValueKey('download-library-track')),
          matching: find.byType(CustomPaint),
        )
        .evaluate()
        .map((e) => (e.widget as CustomPaint).painter)
        .whereType<DownloadIconPainter>()
        .any((p) => p.phase == DownloadIconPhase.completed);

    expect(showsCheck(), isTrue);
    await tester.tap(find.byKey(const ValueKey('download-library-track')));
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(SnackBar).evaluate().isNotEmpty) break;
    }
    expect(find.byType(SnackBar), findsOneWidget);
    expect(File(path).existsSync(), isFalse);
    expect(showsCheck(), isFalse);
    final persisted = await tester.runAsync(
      () => HistoryDatabase.instance.findAllExistingTrackFiles(request.tracks),
    );
    expect(persisted!.single, isEmpty);
  });
}
