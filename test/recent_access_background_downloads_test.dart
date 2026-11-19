import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/services/app_state_database.dart';

class _MemoryDatabase implements AppStateDatabase {
  final rows = <String, String>{};

  @override
  Future<bool> migrateRecentAccessFromSharedPreferences() async => true;

  @override
  Future<List<Map<String, dynamic>>> getRecentAccessRows({int? limit}) async =>
      [for (final json in rows.values) {'item_json': json}];

  @override
  Future<Set<String>> getHiddenRecentDownloadIds() async => {};

  @override
  Future<DateTime?> getRecentDownloadsClearedAt() async => null;

  @override
  Future<void> upsertRecentAccessRow({
    required String uniqueKey,
    required String itemJson,
    required String accessedAt,
  }) async {
    rows[uniqueKey] = itemJson;
  }

  @override
  Future<void> deleteRecentAccessRow(String uniqueKey) async {
    rows.remove(uniqueKey);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeHistory extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState(
    items: [
      for (var i = 0; i < 5; i++)
        DownloadHistoryItem(
          id: 'dl$i',
          trackName: 'Cancion $i',
          artistName: 'Artista',
          albumName: 'Album $i',
          filePath: '/musica/$i.flac',
          service: 'queue',
          downloadedAt: DateTime.utc(2026, 11, 1, 12, i),
          spotifyId: 'sp$i',
        ),
    ],
    totalCount: 5,
  );
}

void main() {
  test('downloaded tracks never appear in search recents', () async {
    final database = _MemoryDatabase();
    final container = ProviderContainer(
      overrides: [
        recentAccessProvider.overrideWith(
          () => RecentAccessNotifier(database: database),
        ),
        downloadHistoryProvider.overrideWith(_FakeHistory.new),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(downloadHistoryProvider).items, hasLength(5));
    container.listen(recentAccessProvider, (_, _) {});
    while (!container.read(recentAccessProvider).isLoaded) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(container.read(recentAccessProvider).items, isEmpty);
    expect(container.read(recentAccessViewProvider).uniqueItems, isEmpty);

    container
        .read(recentAccessProvider.notifier)
        .recordAlbumAccess(id: 'alb1', name: 'Elegido', artistName: 'X');

    final shown = container.read(recentAccessViewProvider).uniqueItems;
    expect(shown.map((e) => e.name), ['Elegido']);
    expect(container.read(recentAccessProvider).items, hasLength(1));
  });
}
