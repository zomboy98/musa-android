import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/deleted_library_files.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/local_library_provider.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/library_database.dart';

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

DownloadHistoryItem _item(int n, String path, {int? spotify}) =>
    DownloadHistoryItem(
      id: 'download-$n',
      trackName: 'Song $n',
      artistName: 'Artist',
      albumName: 'Album',
      filePath: path,
      service: 'example-provider',
      spotifyId: 'catalog-${spotify ?? n}',
      isrc: 'ISRC000000$n',
      downloadedAt: DateTime(2026),
    );

Track _track(int n) => Track(
  id: 'catalog-$n',
  name: 'Song $n',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 100,
  isrc: 'ISRC000000$n',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'deleting downloads clears every view of the downloaded state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('deleted-download-');
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
        await root.delete(recursive: true);
      });

      final items = [
        _item(1, '${root.path}/1.flac'),
        _item(2, '${root.path}/2.flac'),
        _item(3, '${root.path}/3.flac'),
        _item(4, '${root.path}/stale-of-1.flac', spotify: 1),
      ];
      for (final n in [1, 2, 3]) {
        await File('${root.path}/$n.flac').writeAsBytes([1]);
      }
      await HistoryDatabase.instance.upsertBatch([
        for (final item in items) item.toJson(),
      ]);
      final container = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => _History(items)),
          localLibraryProvider.overrideWith(_Library.new),
        ],
      );
      addTearDown(container.dispose);

      final tracks = [for (var n = 1; n <= 3; n++) _track(n)];
      final request = HistoryBatchLookupRequest.snapshot(
        tracks.map(historyLookupForTrack),
      );
      final provider = downloadHistoryVisibleBatchExistsProvider(request);
      final subscription = container.listen(provider, (_, _) {});
      addTearDown(subscription.close);
      await container.read(downloadHistoryBatchExistsProvider(request).future);
      expect(container.read(provider), hasLength(3));

      await File(items[0].filePath).delete();
      await File(items[1].filePath).delete();
      await removeDeletedLibraryFileEntries(container, [
        items[0].filePath,
        items[1].filePath,
      ]);
      await container.read(downloadHistoryBatchExistsProvider(request).future);
      await container.pump();

      expect(container.read(provider), {request.lookupKeys[2]});
      final reopened = HistoryBatchLookupRequest.snapshot(
        tracks.map(historyLookupForTrack),
      );
      final fresh = ProviderContainer(
        overrides: [
          downloadHistoryProvider.overrideWith(() => _History(const [])),
          localLibraryProvider.overrideWith(_Library.new),
        ],
      );
      addTearDown(fresh.dispose);
      final persisted = await fresh.read(
        downloadHistoryBatchExistsProvider(reopened).future,
      );
      expect(persisted, {reopened.lookupKeys[2]});
    },
  );
}
