import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart' show MediaItem;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/explore_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/listening_statistics_provider.dart';
import 'package:mornye/services/listening_statistics.dart';
import 'package:mornye/providers/home_top_picks_provider.dart';
import 'package:mornye/providers/recent_access_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/home_tab.dart';
import 'package:mornye/screens/library_mix_screen.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:mornye/widgets/desktop/track_table.dart';
import 'package:mornye/widgets/album_detail_header.dart';
import 'package:mornye/widgets/expressive_button.dart';
import 'package:mornye/widgets/library_mix_cover.dart';
import 'package:mornye/widgets/library_track_selection_bar.dart';
import 'package:mornye/widgets/mornye_mix_banner.dart';
import 'package:mornye/widgets/track_card.dart';

import 'support/fixed_settings.dart';
import 'support/sqlite_process_database.dart';

final _items = [
  for (var i = 0; i < 24; i++)
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'song$i',
        trackName: 'Song $i',
        artistName: i.isEven ? 'Tyler, The Creator' : 'Frank Ocean',
        albumName: 'Album ${i % 5}',
        filePath: '/music/song$i.flac',
        scannedAt: DateTime(2026, 10, 27),
        duration: 180,
      ),
    ),
];

final _mix = LibraryMixView(
  mix: LibraryMix(
    kind: LibraryMixKind.genre,
    key: 'hiphop',
    label: 'Hip-Hop',
    artists: const ['Tyler, The Creator', 'Frank Ocean'],
    songIds: [for (final item in _items) item.id],
  ),
  items: _items,
);

void main() {
  testWidgets('clear hides a retained mix until history validation completes', (
    tester,
  ) async {
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final db = await tester.runAsync(() => SqliteProcessDatabase.open());
    addTearDown(() => db!.close());
    await tester.runAsync(() async {
      await db!.execute(
        'CREATE TABLE listening (day TEXT, track_key TEXT, title TEXT, artist TEXT, plays INTEGER)',
      );
      await db.insert('listening', {
        'day': '2026-11-06',
        'track_key': '/music',
        'title': 'Song',
        'artist': 'Artist',
        'plays': 4,
      });
    });
    final store = ListeningStatisticsStore.forTesting(db!);
    final collections = _MixCollections();
    final pending = Completer<String>();
    final ordinaryRefresh = Completer<List<LibraryMixView>>();
    var loads = 0;
    var cacheLoads = 0;
    late ProviderContainer container;
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpHome(
      tester,
      mornye: false,
      realMixes: true,
      overrides: [
        libraryCollectionsProvider.overrideWith(() => collections),
        libraryPlaylistPickerSummariesProvider.overrideWith(
          (ref, request) async => const [
            PlaylistPickerSummary(
              id: 'manual',
              name: 'Manual playlist',
              trackCount: 2,
              containsAllRequestedTracks: false,
            ),
          ],
        ),
      ],
      store: store,
      revisionLoad: (_, _, _) async => ++loads == 1 ? 'old' : pending.future,
      cacheLoad: (_, revision) async {
        if (++cacheLoads == 2) return ordinaryRefresh.future;
        return revision.contains('old') ? [_mix] : [];
      },
      onContainer: (value) => container = value,
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Hip-Hop Mix', skipOffstage: false), findsOneWidget);
    container.invalidate(libraryMixesProvider);
    await tester.pump();
    expect(find.text('Hip-Hop Mix', skipOffstage: false), findsOneWidget);
    expect(cacheLoads, 2);
    await tester.tap(find.text('Hip-Hop Mix'));
    await tester.pumpAndSettle();
    expect(find.byType(LibraryMixScreen), findsOneWidget);
    expect(find.text('Song 0'), findsOneWidget);
    expect(find.byTooltip('Save as playlist'), findsOneWidget);

    await tester.tap(find.byTooltip('Save as playlist'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Create playlist'), findsOneWidget);
    await tester.tap(find.text('Manual playlist'));
    await tester.pump();
    final done = tester
        .widget<ExpressiveButton>(find.widgetWithText(ExpressiveButton, 'Done'))
        .onPressed!;
    await tester.runAsync(store.clear);
    // A confirmation already captured by the open picker must also be inert.
    done();
    expect(collections._additions, 0);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(pending.isCompleted, isFalse);
    expect(find.text('Create playlist'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LibraryMixScreen), findsOneWidget);
    expect(find.text('No tracks found'), findsOneWidget);
    expect(find.text('Hip-Hop Mix'), findsNothing);
    expect(find.byType(TrackCard), findsNothing);
    expect(find.byType(LibraryMixCover), findsNothing);
    expect(find.byTooltip('Save as playlist'), findsNothing);
    expect(find.byTooltip('Shuffle'), findsNothing);

    // The result of a pre-clear refresh must not resurrect the old detail.
    ordinaryRefresh.complete([_mix]);
    await tester.pump();
    expect(find.text('No tracks found'), findsOneWidget);
    expect(find.byType(TrackCard), findsNothing);

    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(LibraryMixScreen), findsNothing);
    expect(find.text('Hip-Hop Mix', skipOffstage: false), findsNothing);
    expect(find.text('Shortcuts', skipOffstage: false), findsOneWidget);
    // Recreating the provider while the new revision is pending is safe too.
    container.invalidate(libraryMixesProvider);
    await tester.pump();
    expect(find.text('Hip-Hop Mix', skipOffstage: false), findsNothing);
    pending.completeError(StateError('revision failed'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Hip-Hop Mix', skipOffstage: false), findsNothing);
  });
  testWidgets('open desktop mix menu cannot add an invalidated mix', (
    tester,
  ) async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final clears = StreamController<int>.broadcast(sync: true);
    addTearDown(clears.close);
    var generation = 0;
    await _pumpMix(
      tester,
      mornye: false,
      view: LibraryMixView(
        mix: _mix.mix,
        items: _mix.items,
        clearGeneration: generation,
      ),
      overrides: [
        libraryMixClearGenerationProvider.overrideWithValue(() => generation),
        libraryMixClearEventsProvider.overrideWith((ref) => clears.stream),
      ],
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Song 0')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final addToPlaylist = tester
        .widget<MenuItemButton>(
          find.widgetWithText(MenuItemButton, 'Add to playlist'),
        )
        .onPressed!;

    clears.add(++generation);
    addToPlaylist();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Create playlist'), findsNothing);
    expect(find.text('No tracks found'), findsOneWidget);
    expect(find.byType(SliverTrackTable), findsNothing);
  });

  testWidgets('clear blocks captured controls for the current track', (
    tester,
  ) async {
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    tester.view.physicalSize = const Size(430, 932);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final player = _InitializingPlayer();
    final clears = StreamController<int>.broadcast(sync: true);
    addTearDown(clears.close);
    var generation = 0;
    await _pumpMix(
      tester,
      mornye: false,
      view: LibraryMixView(
        mix: _mix.mix,
        items: _mix.items,
        clearGeneration: generation,
      ),
      overrides: [
        libraryMixClearGenerationProvider.overrideWithValue(() => generation),
        libraryMixClearEventsProvider.overrideWith((ref) => clears.stream),
        musicPlayerControllerProvider.overrideWithValue(player),
        currentMediaItemProvider.overrideWithBuild(
          (ref, notifier) =>
              Stream.value(const MediaItem(id: 'song0', title: 'Song 0')),
        ),
      ],
    );
    final onPlay = tester
        .widget<AlbumPlayActions>(find.byType(AlbumPlayActions))
        .onPlay;
    final onTrackTap = tester
        .widget<TrackCard>(find.widgetWithText(TrackCard, 'Song 0'))
        .onTap!;
    onPlay();
    onTrackTap();
    expect(player.toggles, 2);

    clears.add(++generation);
    onPlay();
    onTrackTap();
    await tester.pump();
    expect(player.toggles, 2);
  });

  test('clear cancels enqueue during player initialization', () async {
    final player = _InitializingPlayer();
    final handler = _MixPlaybackHandler();
    var isCurrent = true;
    final enqueue = player.enqueueMedia([
      playableFromLocal(_items.first.localItem!),
    ], isCurrentRequest: () => isCurrent);
    await player.initializing.future;
    isCurrent = false;
    player.initialized.complete(handler);
    await enqueue;
    expect(handler.enqueued, isFalse);
  });

  for (final shuffle in [false, true]) {
    testWidgets('clear cancels mix playback during player initialization '
        '(shuffle: $shuffle)', (tester) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      final file = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('library-mix-test');
        return File('${dir.path}/song.flac').create();
      });
      addTearDown(() => file!.parent.delete(recursive: true));
      final player = (await tester.runAsync(
        () async => _InitializingPlayer(),
      ))!;
      final handler = _MixPlaybackHandler();
      final clears = StreamController<int>.broadcast(sync: true);
      addTearDown(clears.close);
      var generation = 0;

      await _pumpMix(
        tester,
        mornye: false,
        view: LibraryMixView(
          mix: _mix.mix,
          items: [
            UnifiedLibraryItem.fromLocalLibrary(
              LocalLibraryItem(
                id: 'song0',
                trackName: 'Song 0',
                artistName: 'Artist',
                albumName: 'Album',
                filePath: file!.path,
                scannedAt: DateTime(2026),
              ),
            ),
          ],
          clearGeneration: generation,
        ),
        overrides: [
          musicPlayerControllerProvider.overrideWithValue(player),
          libraryMixClearGenerationProvider.overrideWithValue(() => generation),
          libraryMixClearEventsProvider.overrideWith((ref) => clears.stream),
        ],
      );
      final actions = tester.widget<AlbumPlayActions>(
        find.byType(AlbumPlayActions),
      );
      await tester.runAsync(() async {
        (shuffle ? actions.onShuffle : actions.onPlay).call();
        await player.initializing.future.timeout(const Duration(seconds: 5));
        clears.add(++generation);
        player.initialized.complete(handler);
        await player.finished.future.timeout(const Duration(seconds: 5));
      });
      await tester.pump();
      expect(handler.started, isFalse);
      expect(player.shuffleChanges, shuffle ? isEmpty : [false]);
    });
  }

  testWidgets('real feed shows the catalog without a taste shelf', (
    tester,
  ) async {
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    tester.view.physicalSize = const Size(430, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await _pumpHome(tester, mornye: true, feed: true);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Explore the catalog'), findsOneWidget);
    expect(find.text('Cool Jazz'), findsOneWidget);
    expect(find.text('Hot Artists'), findsOneWidget);
    expect(find.text('Based on your preferences'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final locale in [const Locale('es'), const Locale('es', 'ES')]) {
    testWidgets('Home app labels follow $locale and preserve artist names', (
      tester,
    ) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpHome(tester, mornye: true, mixes: [_mix], locale: locale);
      await tester.scrollUntilVisible(
        find.byType(MornyeMixBanner),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Explorar catálogo'), findsOneWidget);
      expect(find.text('Hecho para ti'), findsOneWidget);
      expect(find.textContaining('Tyler, The Creator'), findsOneWidget);
      expect(find.textContaining('Frank Ocean'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('phone Top Picks shows two compact banners', (tester) async {
    debugDesktopPlatformOverride = false;
    addTearDown(() => debugDesktopPlatformOverride = null);
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await _pumpHome(tester, mornye: true, mixes: [_mix, _mix, _mix]);
    await tester.pump(const Duration(seconds: 1));
    final banners = find.byType(MornyeMixBanner);
    expect(banners, findsAtLeastNWidgets(2));
    final first = tester.getRect(banners.at(0));
    final second = tester.getRect(banners.at(1));
    expect(first.width, lessThan(180));
    expect(first.height, lessThan(240));
    expect(second.right, lessThanOrEqualTo(320));
    final titleRect = tester.getRect(
      find.descendant(of: banners.first, matching: find.byType(FittedBox)),
    );
    final captionRect = tester.getRect(
      find.descendant(of: banners.first, matching: find.text('Made for You')),
    );
    expect(titleRect.bottom, lessThanOrEqualTo(captionRect.top));
    expect(tester.takeException(), isNull);
  });
  for (final desktop in [false, true]) {
    for (final mornye in [false, true]) {
      testWidgets('Home lists the mixes and opens one '
          '(desktop: $desktop, Mornye: $mornye)', (tester) async {
        debugDesktopPlatformOverride = desktop;
        addTearDown(() => debugDesktopPlatformOverride = null);
        tester.view.physicalSize = desktop
            ? const Size(1280, 800)
            : const Size(430, 932);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await _pumpHome(tester, mornye: mornye, mixes: [_mix]);

        final title = find.text('Hip-Hop Mix');
        await tester.scrollUntilVisible(
          title,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        // Rows take taps again once the scroll comes to rest.
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('Tyler, The Creator and Frank Ocean'), findsOneWidget);
        if (mornye) {
          expect(find.text('Explore the catalog'), findsOneWidget);
          expect(find.text('Made for You'), findsOneWidget);
          expect(find.byType(MornyeMixBanner), findsOneWidget);
          expect(find.text('Mixes for you'), findsNothing);
          // Music's Home has no tools.
          expect(find.text('Shortcuts', skipOffstage: false), findsNothing);
        } else {
          expect(find.text('Mixes for you'), findsOneWidget);
          expect(find.byType(LibraryMixCover), findsOneWidget);
          expect(find.byType(MornyeMixBanner), findsNothing);
        }

        if (mornye) {
          final card = find
              .ancestor(of: title, matching: find.byType(ClipRRect))
              .first;
          final action = find
              .descendant(of: card, matching: find.byType(InkWell))
              .first;
          expect(action.hitTestable(), findsOneWidget);
          await tester.tap(action);
        } else {
          await tester.tap(title);
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(LibraryMixScreen), findsOneWidget);
        expect(find.text('Hip-Hop Mix'), findsWidgets);
        expect(find.textContaining('Made from your Library'), findsOneWidget);
        expect(find.text('Song 0'), findsOneWidget);
        if (desktop) {
          expect(find.byType(SliverTrackTable), findsOneWidget);
        } else {
          expect(find.byType(TrackCard), findsWidgets);
          expect(find.byTooltip('Save as playlist'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final mornye in [false, true]) {
    testWidgets('a long press on a phone row selects songs for the Library '
        'actions (Mornye: $mornye)', (tester) async {
      debugDesktopPlatformOverride = false;
      addTearDown(() => debugDesktopPlatformOverride = null);
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pumpMix(tester, mornye: mornye);
      expect(find.byType(LibraryTrackSelectionBar), findsNothing);

      final first = find.text('Song 0');
      await tester.scrollUntilVisible(
        first,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.longPress(first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(LibraryTrackSelectionBar), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
      final cards = tester
          .widgetList<TrackCard>(find.byType(TrackCard))
          .toList();
      expect(cards.first.isSelectionMode, isTrue);
      expect(cards.first.isSelected, isTrue);

      // In selection mode a tap adds the song instead of playing it. The
      // bar follows a frame later, from its overlay.
      await tester.tap(find.text('Song 1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('2 selected'), findsOneWidget);
      await tester.tap(find.text('Song 1'));
      await tester.pump();
      await tester.pump();
      expect(find.text('1 selected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Home leaves the section out without mixes', (tester) async {
    await _pumpHome(tester, mornye: false, mixes: const []);
    expect(find.text('Shortcuts'), findsOneWidget);
    expect(find.text('Mixes for you'), findsNothing);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Open Sources'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixes arriving later open below Shortcuts', (tester) async {
    late ProviderContainer container;
    await _pumpHome(
      tester,
      mornye: false,
      mixesProvider: (ref) async => ref.watch(_arrivingMixes),
      onContainer: (value) => container = value,
    );
    expect(find.text('Mixes for you'), findsNothing);
    final shortcutsBottom = tester.getBottomLeft(find.text('Shortcuts')).dy;

    container.read(_arrivingMixes.notifier).arrive([_mix]);
    await tester.pump();
    await tester.pump();
    final title = find.text('Mixes for you', skipOffstage: false);
    expect(title, findsOneWidget);
    final section = find.ancestor(
      of: title,
      matching: find.byType(AnimatedSize),
    );
    final opening = tester.getSize(section.first).height;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    final open = tester.getSize(section.first).height;
    // Home's sections open the space rather than letting it jump in.
    expect(opening, lessThan(open));
    expect(tester.getTopLeft(title).dy, greaterThan(shortcutsBottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixes wait until startup settles', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settled = container.listen(libraryMixesStartupProvider, (_, _) {});
    expect(settled.read(), isFalse);
    // The first frame starts the wait.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(libraryMixesStartupDelay - const Duration(seconds: 1));
    expect(settled.read(), isFalse);
    // Nothing animates, so the next idle check settles it.
    await tester.pump(const Duration(seconds: 3));
    expect(settled.read(), isTrue);
  });

  testWidgets('an endless animation delays the mixes only so long', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final settled = container.listen(libraryMixesStartupProvider, (_, _) {});
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: CircularProgressIndicator())),
    );
    await tester.pump(libraryMixesStartupDelay + const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 16));
    expect(settled.read(), isFalse);
    await tester.pump(libraryMixesIdleTimeout);
    expect(settled.read(), isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  test('mix names follow their kind, in the app language', () async {
    final l10n = await AppLocalizations.delegate.load(const Locale('en'));
    LibraryMix mix(
      LibraryMixKind kind,
      String key, {
      String label = '',
      List<String> artists = const ['A', 'B', 'C'],
    }) => LibraryMix(
      kind: kind,
      key: key,
      label: label,
      artists: artists,
      songIds: const [],
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.favorites, 'favorites')),
      'Favorites Mix',
    );
    // A family takes its translated name, whatever label was cached.
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.genre, 'hiphop', label: 'x')),
      'Hip-Hop Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.genre, 'indie')),
      'Indie & Alternative Mix',
    );
    // A tag outside the families keeps its own spelling.
    expect(
      libraryMixTitle(
        l10n,
        mix(LibraryMixKind.genre, 'tag:sundanese', label: 'Sundanese'),
      ),
      'Sundanese Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.decade, '1990', label: '1990')),
      '1990s Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.fresh, 'fresh')),
      'New Additions Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.rediscover, 'rediscover')),
      'Rediscover Mix',
    );
    expect(
      libraryMixTitle(l10n, mix(LibraryMixKind.discover, 'discover')),
      'Discover Mix',
    );
    expect(
      libraryMixTitle(
        l10n,
        mix(LibraryMixKind.artist, 'frank ocean', label: 'Frank Ocean'),
      ),
      'Frank Ocean Mix',
    );
    for (final family in [
      'hiphop',
      'rnb',
      'pop',
      'kpop',
      'jpop',
      'rock',
      'metal',
      'punk',
      'indie',
      'electronic',
      'chill',
      'jazz',
      'blues',
      'classical',
      'soundtrack',
      'country',
      'folk',
      'latin',
      'reggae',
      'afro',
      'gospel',
      'dangdut',
    ]) {
      expect(
        libraryGenreFamilyName(l10n, family),
        libraryGenreFamilyLabel(family),
        reason: family,
      );
    }
    expect(libraryGenreFamilyName(l10n, 'tag:sundanese'), isNull);

    String subtitle(List<String> artists) => libraryMixSubtitle(
      l10n,
      mix(LibraryMixKind.genre, 'pop', artists: artists),
    );
    expect(subtitle(const ['A']), 'A');
    expect(subtitle(const ['A', 'B']), 'A and B');
    expect(subtitle(const ['A', 'B', 'C']), 'A, B and more');
    expect(subtitle(const []), isEmpty);
  });
}

Future<void> _pumpMix(
  WidgetTester tester, {
  required bool mornye,
  LibraryMixView? view,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(const AppSettings()),
        ),
        downloadHistoryProvider.overrideWith(_History.new),
        ...overrides,
      ],
      child: MaterialApp(
        theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LibraryMixScreen(view: view ?? _mix),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required bool mornye,
  Locale? locale,
  bool feed = false,
  List<LibraryMixView> mixes = const [],
  Future<List<LibraryMixView>> Function(Ref ref)? mixesProvider,
  void Function(ProviderContainer container)? onContainer,
  bool realMixes = false,
  ListeningStatisticsStore? store,
  Future<String> Function(DateTime, bool, String)? revisionLoad,
  Future<List<LibraryMixView>> Function(bool, String)? cacheLoad,
  List<Override> overrides = const [],
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ...overrides,
        homeTopPicksProvider.overrideWith(
          (ref) async => [
            if (feed)
              const ExploreItem(
                id: 'generic',
                uri: 'generic',
                type: 'playlist',
                name: 'Cool Jazz',
                artists: 'Provider artist',
                providerId: 'example',
              ),
          ],
        ),
        settingsProvider.overrideWith(
          () => FixedSettingsNotifier(
            AppSettings(
              searchProvider: 'example',
              homeFeedProvider: feed ? null : AppSettings.homeFeedProviderOff,
            ),
          ),
        ),
        extensionProvider.overrideWith(_Extensions.new),
        exploreProvider.overrideWith(() => _Explore(feed: feed)),
        downloadHistoryProvider.overrideWith(_History.new),
        recentAccessProvider.overrideWith(_Recent.new),
        if (!realMixes)
          libraryMixesProvider.overrideWith(
            mixesProvider ?? (ref) async => mixes,
          ),
        if (realMixes) ...[
          libraryMixClearGenerationProvider.overrideWithValue(
            () => store!.clearGeneration,
          ),
          libraryMixClearEventsProvider.overrideWith((ref) => store!.clears),
          listeningStatisticsEventStreamProvider.overrideWithValue(
            store!.changes,
          ),
          listeningStatisticsInitialFlushProvider.overrideWith((ref) async {}),
          libraryMixListeningRevisionLoadProvider.overrideWithValue(
            revisionLoad!,
          ),
          libraryMixCachedViewsLoadProvider.overrideWithValue(cacheLoad!),
        ],
      ],
      child: Consumer(
        builder: (context, ref, child) {
          onContainer?.call(ProviderScope.containerOf(context));
          return child!;
        },
        child: MaterialApp(
          locale: locale,
          theme: mornye ? MornyeTheme.build(Brightness.dark) : AppTheme.dark(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeTab(
            mode: mornye ? HomeTabMode.browse : HomeTabMode.combined,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

/// Mixes that are built after Home is shown.
final _arrivingMixes = NotifierProvider<_ArrivingMixes, List<LibraryMixView>>(
  _ArrivingMixes.new,
);

class _ArrivingMixes extends Notifier<List<LibraryMixView>> {
  @override
  List<LibraryMixView> build() => const [];

  void arrive(List<LibraryMixView> mixes) => state = mixes;
}

/// Extensions still starting, so Home neither waits for a feed nor asks for
/// a search provider.
class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState();
}

class _Explore extends ExploreNotifier {
  _Explore({this.feed = false});
  final bool feed;
  @override
  ExploreState build() => ExploreState(
    sections: [
      if (feed)
        const ExploreSection(
          uri: 'artists',
          title: 'Hot Artists',
          items: [
            ExploreItem(
              id: 'artist',
              uri: 'artist',
              type: 'artist',
              name: 'Provider artist',
              artists: '',
              providerId: 'example',
            ),
          ],
        ),
    ],
  );

  @override
  Future<void> fetchHomeFeed({bool forceRefresh = false}) async {}
}

class _History extends DownloadHistoryNotifier {
  @override
  DownloadHistoryState build() => DownloadHistoryState();
}

class _Recent extends RecentAccessNotifier {
  @override
  RecentAccessState build() => const RecentAccessState(isLoaded: true);
}

class _InitializingPlayer extends MusicPlayerController {
  final initializing = Completer<void>();
  final initialized = Completer<MusicPlayerHandler>();
  final finished = Completer<void>();
  final shuffleChanges = <bool>[];
  int toggles = 0;

  @override
  Future<void> togglePlayPause(bool isPlaying) async {
    toggles++;
  }

  @override
  Future<MusicPlayerHandler?> ensureInitialized() {
    initializing.complete();
    return initialized.future;
  }

  @override
  Future<void> setShuffle(bool enabled) async => shuffleChanges.add(enabled);

  @override
  Future<void> playAll(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    bool Function()? isCurrentRequest,
  }) async {
    await super.playAll(
      items,
      initialIndex: initialIndex,
      isCurrentRequest: isCurrentRequest,
    );
    finished.complete();
  }
}

class _MixPlaybackHandler extends Fake implements MusicPlayerHandler {
  bool started = false;
  bool enqueued = false;

  @override
  Future<void> enqueueAll(
    List<PlayableMedia> items, {
    bool playNext = false,
  }) async {
    enqueued = true;
  }

  @override
  Future<void> setQueueAndPlay(
    List<PlayableMedia> items, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool? shuffle,
  }) async {
    started = true;
  }
}

class _MixCollections extends LibraryCollectionsNotifier {
  int _additions = 0;

  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);

  @override
  Future<PlaylistAddBatchResult> addTracksToPlaylist(
    String playlistId,
    Iterable<Track> tracks, {
    bool preserveOccurrences = false,
  }) async {
    _additions++;
    return PlaylistAddBatchResult(
      addedCount: tracks.length,
      alreadyInPlaylistCount: 0,
    );
  }
}
