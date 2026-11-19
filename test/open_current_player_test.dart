import 'package:audio_service/audio_service.dart' as audio;
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/open_current_player.dart';
import 'package:mornye/providers/playback_provider.dart';
import 'package:mornye/widgets/track_card.dart';
import 'package:mornye/widgets/track_list_tile.dart';

class _SpyPlayback extends PlaybackController {
  final played = <List<Track>>[];

  @override
  Future<void> playTrackList(
    List<Track> tracks, {
    int startIndex = 0,
    String? playlistId,
    bool exactStart = false,
    bool requireLocalStart = false,
    String? listContext,
    List<String>? listOccurrences,
  }) async {
    played.add(tracks);
  }
}

const _current = Track(
  id: 'track-1',
  name: 'Current song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 180,
);

const _other = Track(
  id: 'track-2',
  name: 'Other song',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 200,
);

void main() {
  late _SpyPlayback spy;
  late int opened;

  Future<void> tap(
    WidgetTester tester,
    Track track, {
    List<Track>? queue,
    int startIndex = 0,
    bool playing = true,
    bool hasCurrent = true,
  }) async {
    spy = _SpyPlayback();
    opened = 0;
    late BuildContext context;
    late WidgetRef ref;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackProvider.overrideWith(() => spy),
          openNowPlayingProvider.overrideWithValue(() => opened++),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => Stream.value(
              hasCurrent
                  ? const audio.MediaItem(
                      id: '/music/current.flac',
                      title: 'Current',
                    )
                  : null,
            ),
          ),
          currentTrackIdentityProvider.overrideWith(
            (ref) async => const CurrentTrackIdentity(
              recordIds: {'track-1'},
              matchKey: 'currentsong|artist',
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(audio.PlaybackState(playing: playing)),
          ),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (c, r, _) {
              context = c;
              ref = r;
              r.watch(currentMediaItemProvider);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    await tester.runAsync(() async {
      await TrackListTile.activate(
        context,
        ref,
        track,
        queue: queue,
        startIndex: startIndex,
        isInHistory: false,
        onDownload: ({bool forceQualityPicker = false}) {},
      );
    });
  }

  testWidgets('tapping the playing track opens the player without playing', (
    tester,
  ) async {
    await tap(tester, _current, queue: [_other, _current], startIndex: 1);
    expect(opened, 1);
    expect(spy.played, isEmpty);
  });

  testWidgets('tapping the paused track opens the player and stays paused', (
    tester,
  ) async {
    await tap(tester, _current, playing: false);
    expect(opened, 1);
    expect(spy.played, isEmpty);
  });

  testWidgets('tapping another track plays it as before', (tester) async {
    await tap(tester, _other, queue: [_current, _other], startIndex: 1);
    expect(opened, 0);
    expect(spy.played, hasLength(1));
    expect(spy.played.single, [_current, _other]);
  });

  testWidgets('the same track from another collection keeps the queue', (
    tester,
  ) async {
    await tap(
      tester,
      _current,
      queue: [_other, _current, _other],
      startIndex: 1,
    );
    expect(opened, 1);
    expect(spy.played, isEmpty);
  });

  testWidgets('without a player session a tap plays the track', (tester) async {
    await tap(tester, _current, hasCurrent: false);
    expect(opened, 0);
    expect(spy.played, hasLength(1));
  });

  testWidgets('the current row announces that it opens the player', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    Widget row({required bool playing}) => ProviderScope(
      child: MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: TrackCard(
            leading: const SizedBox(width: 32),
            title: 'Current song',
            isCurrent: true,
            isPlaying: playing,
            onTap: () {},
          ),
        ),
      ),
    );

    await tester.pumpWidget(row(playing: true));
    expect(
      tester.getSemantics(find.byType(TrackCard)).hint,
      contains('Playing, open player'),
    );
    await tester.pumpWidget(row(playing: false));
    expect(
      tester.getSemantics(find.byType(TrackCard)).hint,
      contains('Paused, open player'),
    );
    semantics.dispose();
  });
}
