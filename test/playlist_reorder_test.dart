import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/services/library_collections_database.dart';

import 'support/link_sync_support.dart';

ProviderContainer _container(LibraryCollectionsDatabase database) {
  final container = ProviderContainer(
    overrides: [
      libraryCollectionsProvider.overrideWith(
        () => LibraryCollectionsNotifier(database: database),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _order(ProviderContainer container, String playlistId) => [
  for (final entry
      in container
          .read(libraryCollectionsProvider)
          .playlistById(playlistId)!
          .tracks)
    entry.track.id,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'playlist CAS preserves external order and duplicate occurrences',
    () async {
      final directory = await linkSyncTempDirectory();
      final db = await openLinkCollectionsDatabase(directory, 'cas-playlist');
      final database = LibraryCollectionsDatabase.withDatabase(db);
      final container = _container(database);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      final id = await notifier.createPlaylist('Mix');
      await notifier.addTracksToPlaylist(id, [
        linkTestTrack('a'),
        linkTestTrack('b'),
        linkTestTrack('a'),
      ], preserveOccurrences: true);
      final original = container
          .read(libraryCollectionsProvider)
          .playlistById(id)!
          .tracks
          .map((e) => e.key)
          .toList();
      expect(original.toSet(), hasLength(3));
      final external = [original[1], original[2], original[0]];
      expect(
        await database.reorderPlaylistTracks(
          playlistId: id,
          expectedOrder: original,
          addedAtByKey: {
            for (final (i, key) in external.indexed)
              key: DateTime(2020, 1, 1, 0, 0, i).toIso8601String(),
          },
          playlistUpdatedAt: DateTime.now().toIso8601String(),
        ),
        isTrue,
      );
      expect(
        await notifier.reorderPlaylistTracks(
          id,
          original.reversed.toList(),
          expectedOrder: original,
        ),
        isFalse,
      );
      expect(
        container
            .read(libraryCollectionsProvider)
            .playlistById(id)!
            .tracks
            .map((e) => e.key),
        external,
      );
      final reloaded = _container(database);
      await reloaded
          .read(libraryCollectionsProvider.notifier)
          .ensurePlaylistLoaded(id);
      expect(
        reloaded
            .read(libraryCollectionsProvider)
            .playlistById(id)!
            .tracks
            .map((e) => e.key),
        external,
      );
      expect(
        await notifier.reorderPlaylistTracks(
          id,
          original,
          expectedOrder: external,
        ),
        isTrue,
      );
    },
  );

  for (final mode in [LibraryTracksFolderMode.loved]) {
    test('${mode.name} CAS preserves a concurrent reorder', () async {
      final directory = await linkSyncTempDirectory();
      final db = await openLinkCollectionsDatabase(
        directory,
        'cas-${mode.name}',
      );
      final database = LibraryCollectionsDatabase.withDatabase(db);
      final container = _container(database);
      final notifier = container.read(libraryCollectionsProvider.notifier);
      for (final id in ['a', 'b', 'c']) {
        await notifier.toggleLoved(linkTestTrack(id));
      }
      List<String> keys(ProviderContainer c) =>
          c.read(libraryCollectionsProvider).loved.map((e) => e.key).toList();
      final original = keys(container);
      final external = [original[1], original[2], original[0]];
      expect(
        await database.reorderSavedTracks(
          mode: mode,
          expectedOrder: original,
          addedAtByKey: {
            for (final (i, key) in external.indexed)
              key: DateTime(2020, 1, 1, 0, 0, 3 - i).toIso8601String(),
          },
        ),
        isTrue,
      );
      expect(
        await notifier.reorderSavedTracks(
          mode,
          original.reversed.toList(),
          expectedOrder: original,
        ),
        isFalse,
      );
      expect(keys(container), external);
      final reloaded = _container(database);
      await reloaded
          .read(libraryCollectionsProvider.notifier)
          .ensurePlaylistLoaded('unused');
      expect(keys(reloaded), external);
      expect(
        await notifier.reorderSavedTracks(
          mode,
          original,
          expectedOrder: external,
        ),
        isTrue,
      );
    });
  }

  test('a reorder persists, syncs and keeps later additions last', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'reorder');
    final database = LibraryCollectionsDatabase.withDatabase(db);
    final container = _container(database);
    final notifier = container.read(libraryCollectionsProvider.notifier);

    final id = await notifier.createPlaylist('Mix');
    // One batch shares a single stamp, so only rowid orders these tracks.
    await notifier.addTracksToPlaylist(id, [
      for (final id in ['a', 'b', 'c', 'd']) linkTestTrack(id),
    ]);
    final keys = [
      for (final entry
          in container
              .read(libraryCollectionsProvider)
              .playlistById(id)!
              .tracks)
        entry.key,
    ];
    final syncedBefore =
        (await db.rawQuery(
              'SELECT MAX(seq) AS seq FROM link_sync_changes',
            )).first['seq']!
            as int;

    expect(
      await notifier.reorderPlaylistTracks(id, [
        keys[2],
        keys[0],
        keys[3],
        keys[1],
      ]),
      isTrue,
    );
    expect(_order(container, id), ['c', 'a', 'd', 'b']);
    await notifier.addTrackToPlaylist(id, linkTestTrack('e'));
    expect(_order(container, id), ['c', 'a', 'd', 'b', 'e']);

    final reloaded = _container(database);
    await reloaded
        .read(libraryCollectionsProvider.notifier)
        .ensurePlaylistLoaded(id);
    expect(_order(reloaded, id), ['c', 'a', 'd', 'b', 'e']);

    final stamps = (await db.rawQuery(
      'SELECT added_at FROM playlist_tracks WHERE playlist_id = ? '
      'ORDER BY added_at, rowid',
      [id],
    )).map((row) => row['added_at']! as String).toList();
    expect(stamps.toSet(), hasLength(5));
    final changes = await db.rawQuery(
      "SELECT key FROM link_sync_changes WHERE kind = 'playlistTrack' "
      'AND scope = ? AND seq > ?',
      [id, syncedBefore],
    );
    expect(changes, hasLength(5));
  });

  test('a reorder must name every track exactly once', () async {
    final directory = await linkSyncTempDirectory();
    final db = await openLinkCollectionsDatabase(directory, 'invalid');
    final container = _container(LibraryCollectionsDatabase.withDatabase(db));
    final notifier = container.read(libraryCollectionsProvider.notifier);
    final id = await notifier.createPlaylist('Mix');
    await notifier.addTracksToPlaylist(id, [
      linkTestTrack('a'),
      linkTestTrack('b'),
    ]);
    final keys = [
      for (final entry
          in container
              .read(libraryCollectionsProvider)
              .playlistById(id)!
              .tracks)
        entry.key,
    ];

    for (final order in [
      [keys[1]],
      [keys[1], keys[1]],
      [keys[1], 'missing'],
      keys,
    ]) {
      expect(await notifier.reorderPlaylistTracks(id, order), isFalse);
    }
    expect(_order(container, id), ['a', 'b']);
  });

  for (final mode in [LibraryTracksFolderMode.loved]) {
    test(
      '${mode.name} order survives reload, syncs and keeps new songs first',
      () async {
        final directory = await linkSyncTempDirectory();
        final db = await openLinkCollectionsDatabase(directory, mode.name);
        final database = LibraryCollectionsDatabase.withDatabase(db);
        final container = _container(database);
        final notifier = container.read(libraryCollectionsProvider.notifier);
        final tracks = [
          for (final id in ['a', 'b', 'c', 'd']) linkTestTrack(id),
        ];
        await notifier.toggleLovedTracks(tracks);
        List<CollectionTrackEntry> entries(ProviderContainer c) =>
            c.read(libraryCollectionsProvider).loved;
        final byId = {
          for (final entry in entries(container)) entry.track.id: entry,
        };
        final before =
            (await db.rawQuery(
                  'SELECT MAX(seq) AS seq FROM link_sync_changes',
                )).first['seq']!
                as int;
        expect(
          await notifier.reorderSavedTracks(mode, [
            for (final id in ['c', 'a', 'd', 'b']) byId[id]!.key,
          ]),
          isTrue,
        );
        expect(entries(container).map((e) => e.track.id), ['c', 'a', 'd', 'b']);
        await notifier.toggleLovedTracks([linkTestTrack('e')]);
        final reloaded = _container(database);
        await reloaded
            .read(libraryCollectionsProvider.notifier)
            .ensurePlaylistLoaded('unused');
        expect(entries(reloaded).map((e) => e.track.id), [
          'e',
          'c',
          'a',
          'd',
          'b',
        ]);
        final changes = await db.rawQuery(
          'SELECT key FROM link_sync_changes WHERE kind = ? AND seq > ?',
          [mode.name, before],
        );
        expect(changes, hasLength(5));
        final stable = entries(reloaded).map((e) => e.key).toList();
        final restored = reloaded.read(libraryCollectionsProvider.notifier);
        expect(
          await restored.reorderSavedTracks(mode, [stable.first]),
          isFalse,
        );
        expect(
          await restored.reorderSavedTracks(mode, [
            for (final _ in stable) stable.first,
          ]),
          isFalse,
        );
        expect(await restored.reorderSavedTracks(mode, stable), isFalse);
        expect(entries(reloaded).map((e) => e.track.id), [
          'e',
          'c',
          'a',
          'd',
          'b',
        ]);
      },
    );
  }
}
