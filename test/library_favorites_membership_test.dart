import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/library_home_provider.dart';
import 'package:mornye/providers/saved_library_tracks_provider.dart';
import 'package:mornye/services/library_collections_database.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/library_home_fixture.dart';

/// Only the favorites table; every other call is unexpected in these tests.
class _Database implements LibraryCollectionsDatabase {
  final loved = <String, Map<String, dynamic>>{};

  @override
  Future<bool> migrateFromSharedPreferences() async => false;

  @override
  Future<LibraryCollectionsSnapshot> loadSnapshot() async =>
      LibraryCollectionsSnapshot(
        lovedRows: loved.values.toList(),
        playlistRows: const [],
        playlistTrackRows: const [],
        favoriteArtistRows: const [],
      );

  @override
  Future<void> upsertLovedEntry({
    required String trackKey,
    required String trackJson,
    required String addedAt,
  }) async {
    loved[trackKey] = {
      'track_key': trackKey,
      'track_json': trackJson,
      'added_at': addedAt,
    };
  }

  @override
  Future<void> deleteLovedEntry(String trackKey) async =>
      loved.remove(trackKey);

  @override
  Future<void> deleteLovedTracks(List<String> keys) async =>
      keys.forEach(loved.remove);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final a = libraryTrack('a');
  final b = libraryTrack('b');

  ProviderContainer container(_Database db, {List<Track> saved = const []}) {
    seedSavedTracks(saved);
    final container = ProviderContainer(
      overrides: [
        libraryCollectionsProvider.overrideWith(
          () => LibraryCollectionsNotifier(database: db),
        ),
        promoteSavedCatalogAudioProvider.overrideWithValue((_) async => false),
        pendingSavedCatalogPromotionProvider.overrideWithValue((_) => null),
        savedCatalogRetentionLockProvider.overrideWithValue(
          <T>(Future<T> Function() action) => action(),
        ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Future<List<String>> savedIds(ProviderContainer container) async => [
    for (final track in await container.read(savedLibraryTracksProvider.future))
      track.id,
  ];

  test('starring stores the song in the library as well', () async {
    final db = _Database();
    final c = container(db);
    final notifier = c.read(libraryCollectionsProvider.notifier);
    expect(await notifier.toggleLoved(a), isTrue);
    expect(db.loved.keys, [trackCollectionKey(a)]);
    expect(await savedIds(c), ['a']);
  });

  test('removing the star keeps the song in the library', () async {
    final db = _Database();
    final c = container(db);
    final notifier = c.read(libraryCollectionsProvider.notifier);
    await notifier.toggleLoved(a);
    expect(await notifier.toggleLoved(a), isFalse);
    expect(db.loved, isEmpty);
    expect(await savedIds(c), ['a']);
    expect(c.read(librarySongsProvider).single.favorite, isFalse);
  });

  test('existing favorites are kept when their star is removed', () async {
    // A favorite from before the link: starred, never added with "+".
    final seedDb = _Database();
    final seed = container(seedDb);
    await seed.read(libraryCollectionsProvider.notifier).toggleLoved(a);
    final stored = Map.of(seedDb.loved);

    final db = _Database()..loved.addAll(stored);
    final c = container(db);
    final notifier = c.read(libraryCollectionsProvider.notifier);
    await notifier.ensurePlaylistsLoaded(const []);
    expect(await savedIds(c), isEmpty);
    expect(c.read(librarySongsProvider).single.saved, isFalse);

    expect(await notifier.removeLovedTracks([trackCollectionKey(a)]), 1);
    expect(db.loved, isEmpty);
    expect(await savedIds(c), ['a']);
  });

  test('keeping favorites is idempotent and preserves saved order', () async {
    final c = container(_Database(), saved: [b]);
    final saved = c.read(savedLibraryTracksProvider.notifier);
    expect(await saved.ensureSaved([a, b, a]), 1);
    expect(await savedIds(c), ['a', 'b']);
    expect(await saved.ensureSaved([a, b]), 0);
    expect(await savedIds(c), ['a', 'b']);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SavedLibraryTracksNotifier.storageKey),
      contains('"id":"a"'),
    );
  });

  test('"+" removal drops the star; the star never drops the song', () async {
    final db = _Database();
    final c = container(db);
    final membership = c.read(libraryMembershipProvider);
    expect(
      await membership.toggleFavorite(a),
      LibraryMembershipChange.favorited,
    );
    expect(membership.isInLibrary(a), isTrue);
    expect(await membership.toggleLibrary(a), LibraryMembershipChange.removed);
    expect(membership.isInLibrary(a), isFalse);
    expect(membership.isFavorite(a), isFalse);
    expect(db.loved, isEmpty);
    expect(await savedIds(c), isEmpty);

    expect(await membership.toggleLibrary(a), LibraryMembershipChange.added);
    expect(membership.isInLibrary(a), isTrue);
    expect(membership.isFavorite(a), isFalse);
  });

  test('a failed library write does not undo the star', () async {
    final db = _Database();
    seedSavedTracks(const []);
    final c = ProviderContainer(
      overrides: [
        libraryCollectionsProvider.overrideWith(
          () => LibraryCollectionsNotifier(database: db),
        ),
        favoriteLibrarySyncProvider.overrideWithValue(
          (_) async => throw StateError('disk full'),
        ),
      ],
    );
    addTearDown(c.dispose);
    final notifier = c.read(libraryCollectionsProvider.notifier);
    expect(await notifier.toggleLoved(a), isTrue);
    expect(c.read(libraryCollectionsProvider).isLoved(a), isTrue);
  });
}
