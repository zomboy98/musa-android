import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/widgets/player_song_journey.dart';
import 'package:mornye/utils/lyrics_parser.dart';

class _TickProbe extends StatefulWidget {
  const _TickProbe(this.onTick);
  final VoidCallback onTick;
  @override
  State<_TickProbe> createState() => _TickProbeState();
}

class _TickProbeState extends State<_TickProbe>
    with SingleTickerProviderStateMixin {
  late final ticker = createTicker((_) => widget.onTick());
  @override
  void initState() {
    super.initState();
    ticker.start();
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

void main() {
  testWidgets('cleared credits replace a previously loaded details snapshot', (
    tester,
  ) async {
    const track = Track(
      id: 'song',
      name: 'Song',
      artistName: '',
      albumName: '',
      duration: 1,
      composer: 'Old composer',
      label: 'Old label',
    );
    final item = playableFromTrack(track, '/music/song.flac').toMediaItem();
    var cleared = false;
    final metadata = PlayerMetadataController(
      readMetadata: (_) async => cleared
          ? {'composer': null, 'label': ''}
          : {'composer': 'Old composer', 'label': 'Old label'},
    );
    addTearDown(metadata.dispose);
    await metadata.load(item);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerSongJourney(
            item: item,
            metadata: metadata,
            playerHeight: 600,
            player: const SizedBox(),
            lyrics: const SizedBox(),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byKey(const ValueKey('player-song-journey')),
      const Offset(0, -400),
    );
    await tester.pumpAndSettle();
    expect(find.text('Old composer'), findsOneWidget);
    expect(find.text('Old label'), findsOneWidget);
    // Re-probe the same visible widget while it retains its older details
    // snapshot, as after a confirmed edit. Explicit null/empty must win.
    cleared = true;
    await metadata.load(null);
    await metadata.load(item);
    await tester.pump();
    expect(find.text('Old composer'), findsNothing);
    expect(find.text('Old label'), findsNothing);
    // The one-second duration remains valid even after those credits clear.
    expect(find.byKey(const ValueKey('journey-credits')), findsOneWidget);
    expect(find.text('0:01'), findsOneWidget);
  });
  testWidgets(
    'real catalog Track pipeline renders credits after resolving audio',
    (tester) async {
      const track = Track(
        id: 'catalog-song',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
        source: 'provider',
        composer: 'Catalog composer',
        label: 'Catalog label',
        copyright: '2026 Owner',
        genre: 'Rock',
        releaseDate: '2026-01-02',
        isrc: 'TEST00000001',
      );
      final playable = playableFromCatalogTrack(track);
      final item = PlayableMedia.fromJson(
        playable.toJson(),
      )!.toMediaItem(resolvedSource: '/cache/resolved.m4a');
      final metadata = PlayerMetadataController(
        readMetadata: (path) async {
          expect(path, '/cache/resolved.m4a');
          return {};
        },
      );
      addTearDown(metadata.dispose);
      await metadata.load(item);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerSongJourney(
              item: item,
              metadata: metadata,
              playerHeight: 1,
              player: const SizedBox(),
              lyrics: const SizedBox(),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.byKey(const ValueKey('journey-credits')));
      expect(find.text('Catalog composer'), findsOneWidget);
      expect(find.text('Catalog label'), findsOneWidget);
      expect(find.text('2026 Owner'), findsOneWidget);
      expect(find.text('Rock'), findsOneWidget);
      expect(find.text('January 2, 2026'), findsOneWidget);
      expect(find.text('TEST00000001'), findsOneWidget);
    },
  );
  testWidgets('artist and album navigate, credits retain distinct roles', (
    tester,
  ) async {
    const item = MediaItem(
      id: 'one',
      title: 'Song',
      artist: 'Artist',
      album: 'Album',
      extras: {
        'source': 'https://example.test/song',
        'displayMetadata': {
          'lyricist': 'Writer',
          'composer': 'Composer',
          'label': 'Label',
        },
      },
    );
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    await metadata.load(item);
    var artistOpened = false;
    var albumOpened = false;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerSongJourney(
            item: item,
            metadata: metadata,
            playerHeight: 1,
            player: const SizedBox(),
            lyrics: const SizedBox(),
            onArtist: () => artistOpened = true,
            onAlbum: () => albumOpened = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('journey-artist')));
    expect(artistOpened, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('journey-album')));
    await tester.tap(find.byKey(const ValueKey('journey-album')));
    expect(albumOpened, isTrue);
    expect(find.text('Writer'), findsOneWidget);
    expect(find.text('Lyrics'), findsWidgets);
    expect(find.text('Composer'), findsWidgets);
    expect(find.text('Label'), findsWidgets);
    expect(find.byKey(const ValueKey('journey-credits')), findsOneWidget);
    const other = MediaItem(
      id: 'one',
      title: 'Other',
      extras: {'source': 'https://example.test/other'},
    );
    // Keep the old controller loaded: an unrelated source must never leak tags.
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerSongJourney(
            item: other,
            metadata: metadata,
            playerHeight: 600,
            player: const SizedBox(),
            lyrics: const SizedBox(),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('journey-credits')), findsNothing);
    expect(find.byKey(const ValueKey('journey-artist')), findsNothing);
  });
  testWidgets('next track plays and a separate action opens queue', (
    tester,
  ) async {
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    var opened = false;
    var played = false;
    Widget screen(MediaItem? next) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: PlayerSongJourney(
          item: const MediaItem(id: 'one', title: 'One'),
          metadata: metadata,
          playerHeight: 600,
          player: const SizedBox(),
          lyrics: const SizedBox(),
          nextItem: next,
          onNextItem: () => played = true,
          onOpenQueue: () => opened = true,
        ),
      ),
    );
    await tester.pumpWidget(
      screen(const MediaItem(id: 'two', title: 'Next song')),
    );
    await tester.drag(
      find.byKey(const ValueKey('player-song-journey')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    expect(find.text('Next song'), findsOneWidget);
    await tester.tap(find.text('Next song'));
    expect(played, isTrue);
    expect(opened, isFalse);
    await tester.tap(find.byKey(const ValueKey('journey-open-queue')));
    expect(opened, isTrue);
    await tester.pumpWidget(screen(null));
    await tester.pump();
    expect(find.text('Next song'), findsNothing);
  });
  testWidgets('compact playback bar appears only after scrolling', (
    tester,
  ) async {
    final metadata = PlayerMetadataController();
    addTearDown(metadata.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PlayerSongJourney(
            item: const MediaItem(id: 'one', title: 'One'),
            metadata: metadata,
            playerHeight: 600,
            player: const SizedBox(),
            lyrics: const SizedBox(),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('journey-compact-player')), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey('player-song-journey')),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey('journey-compact-player')),
      findsOneWidget,
    );
  });

  testWidgets('visible SAF lyrics load on demand and ignore stale tracks', (
    tester,
  ) async {
    const first = MediaItem(
      id: 'one',
      title: 'One',
      extras: {'source': 'content://songs/one'},
    );
    const second = MediaItem(
      id: 'two',
      title: 'Two',
      extras: {'source': 'content://songs/two'},
    );
    final reads = <String>[];
    final pending = <String, Completer<Map<String, dynamic>>>{};
    final metadata = PlayerMetadataController(
      readMetadata: (path) {
        reads.add(path);
        return (pending[path] = Completer()).future;
      },
      parseLyrics: (raw) async => LyricsParser.parse(raw!),
    );
    addTearDown(metadata.dispose);
    Widget screen(MediaItem item) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: PlayerSongJourney(
          item: item,
          metadata: metadata,
          playerHeight: 600,
          player: const SizedBox(),
          lyrics: const SizedBox(),
        ),
      ),
    );
    await metadata.load(first);
    await tester.pumpWidget(screen(first));
    expect(reads, isEmpty);
    await tester.drag(
      find.byKey(const ValueKey('player-song-journey')),
      const Offset(0, -300),
    );
    await tester.pump();
    expect(reads, ['content://songs/one']);
    await metadata.load(second);
    await tester.pumpWidget(screen(second));
    await tester.pump();
    expect(reads, ['content://songs/one', 'content://songs/two']);
    pending['content://songs/two']!.complete({'lyrics': 'Second lyrics'});
    await tester.pump();
    pending['content://songs/one']!.complete({'lyrics': 'Stale lyrics'});
    await tester.pump();
    expect(metadata.metadata?['lyrics'], 'Second lyrics');
    await tester.drag(
      find.byKey(const ValueKey('player-song-journey')),
      const Offset(0, 400),
    );
    await tester.pump();
    await metadata.load(first);
    await tester.pumpWidget(screen(first));
    await tester.pump();
    expect(reads.length, 2);
  });
  testWidgets(
    'offscreen lyrics do not tick; scrolling into view resumes them',
    (tester) async {
      final metadata = PlayerMetadataController();
      addTearDown(metadata.dispose);
      var ticks = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlayerSongJourney(
              item: const MediaItem(id: 'one', title: 'One'),
              metadata: metadata,
              playerHeight: 600,
              player: const SizedBox(),
              lyrics: _TickProbe(() => ticks++),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks, 0);
      await tester.drag(
        find.byKey(const ValueKey('player-song-journey')),
        const Offset(0, -300),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks, greaterThan(0));
      await tester.drag(
        find.byKey(const ValueKey('player-song-journey')),
        const Offset(0, 400),
      );
      await tester.pump();
      final afterReturn = ticks;
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ticks, afterReturn);
    },
  );
}
