import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/player_video_session_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_track_line.dart';
import 'package:mornye/widgets/player_video_fill.dart';
import 'package:mornye/widgets/player_video_pill.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/track_quality_selector.dart';
import 'package:mornye/widgets/track_video_chip.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

class _Measure {
  _Measure(this.cover, this.header, this.controls, this.line, this.selector);
  final Rect cover;
  final Rect header;
  final Rect controls;
  final Rect line;
  final Rect? selector;
}

class _Session extends PlayerVideoSessionNotifier {
  void put(PlayerVideoSession next) => state = next;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late StreamController<MediaItem?> mediaItems;

  setUp(() {
    DecorativePhase.debugHoldClock = true;
    SharedPreferences.setMockInitialValues({});
    mediaItems = StreamController<MediaItem?>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    messenger.setMockMethodCallHandler(backendChannel, (call) async {
      if (call.method == 'setScreenAwake') return null;
      if (call.method == 'readFileMetadata') return jsonEncode({});
      fail('Unexpected platform call: ${call.method}');
    });
  });

  tearDown(() async {
    DecorativePhase.debugHoldClock = false;
    await mediaItems.close();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(backendChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<_Measure> measure(
    WidgetTester tester, {
    Size size = const Size(360, 800),
    double textScale = 1,
    bool playing = true,
    Map<String, Object> extras = const {},
    String? error,
    Duration duration = const Duration(minutes: 3),
    String title = 'Por Amarte Asi',
    String album = 'Album',
    String artist = 'Artista',
    bool explicit = false,
  }) async {
    mediaItems = StreamController<MediaItem?>.broadcast();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => mediaItems.stream,
          ),
          playerMotionArtworkProvider.overrideWith((ref, album) async => null),
          playerArtworkVideoProvider.overrideWith(
            (ref, source) => Completer<VideoPlayerController>().future,
          ),
          playerCollectionTrackProvider.overrideWith(
            (ref, item) async => Track(
              id: item.id,
              name: item.title,
              artistName: item.artist ?? '',
              albumName: item.album ?? '',
              duration: item.duration?.inSeconds ?? 0,
              source: 'local',
            ),
          ),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(playing: playing, errorMessage: error),
            ),
          ),
          playQueueProvider.overrideWith((ref) => Stream.value(const [])),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!,
          ),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          theme: MornyeTheme.build(Brightness.dark),
          home: NowPlayingScreen(
            metadataControllerFactory: () =>
                PlayerMetadataController(automaticOnlineSearch: false),
          ),
        ),
      ),
    );
    mediaItems.add(
      MediaItem(
        id: 'fixed',
        title: title,
        artist: artist,
        album: album,
        duration: duration,
        extras: {
          'source': 'catalog:fixed',
          if (explicit) 'explicit': true,
          ...extras,
        },
      ),
    );
    await settle(tester);
    final selector = find.byType(TrackQualitySelector);
    final result = _Measure(
      tester.getRect(find.byKey(const ValueKey('full-player-artwork')).first),
      tester.getRect(find.byKey(const ValueKey('player-track-header'))),
      tester.getRect(find.byType(PlayerPlaybackControls)),
      tester.getRect(find.byType(PlayerTrackLine)),
      selector.evaluate().isEmpty ? null : tester.getRect(selector),
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    return result;
  }

  const flac = {'verifiedAudioCodec': 'flac', 'verifiedAudioSampleRate': 44100};
  const longTitle = 'Un titulo muy largo que no cabe en una sola linea';
  const longAlbum = 'Un album igual de largo para forzar la marquesina';
  const longArtist = 'Artista Uno, Artista Dos, Artista Tres, Artista Cuatro';

  for (final size in const [Size(360, 800), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3]) {
      testWidgets('the cover has one fixed size at $size text $scale', (
        tester,
      ) async {
        final base = await measure(tester, size: size, textScale: scale);
        expect(base.cover.width, greaterThanOrEqualTo(size.width * 0.94));
        expect(base.cover.width, base.cover.height);
        final variants = <String, _Measure>{
          'quality': await measure(
            tester,
            size: size,
            textScale: scale,
            extras: flac,
          ),
          'paused': await measure(
            tester,
            size: size,
            textScale: scale,
            playing: false,
            extras: flac,
          ),
          'verification': await measure(
            tester,
            size: size,
            textScale: scale,
            error: 'verification_required',
          ),
          'long text': await measure(
            tester,
            size: size,
            textScale: scale,
            title: longTitle,
            album: longAlbum,
            artist: longArtist,
            explicit: true,
          ),
        };
        for (final entry in variants.entries) {
          expect(entry.value.cover, base.cover, reason: entry.key);
          expect(entry.value.header, base.header, reason: entry.key);
          expect(entry.value.controls, base.controls, reason: entry.key);
        }
      });
    }
  }

  testWidgets('the track line keeps one fixed height', (tester) async {
    final short = await measure(tester);
    expect(short.line.height, playerTrackLineHeight);
    final long = await measure(
      tester,
      title: longTitle,
      album: longAlbum,
      artist: longArtist,
    );
    expect(long.line.height, playerTrackLineHeight);
    expect(long.header, short.header);
  });

  testWidgets('the line carries every field and a marquee', (tester) async {
    const item = MediaItem(
      id: 'x',
      title: longTitle,
      album: longAlbum,
      artist: longArtist,
    );
    final metadata = PlayerMetadataController(automaticOnlineSearch: false);
    addTearDown(metadata.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: 240,
            child: PlayerTrackLine(
              mediaItem: item,
              metadata: metadata,
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(OverflowMarquee), findsOneWidget);
    final label = PlayerTrackLine.semanticLabel(item);
    expect(label, contains(longTitle));
    expect(label, contains(longAlbum));
    expect(label, contains(longArtist));
    expect(
      tester.getSize(find.byType(PlayerTrackLine)).height,
      playerTrackLineHeight,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('with reduced motion the line ends in an ellipsis', (
    tester,
  ) async {
    final metadata = PlayerMetadataController(automaticOnlineSearch: false);
    addTearDown(metadata.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: PlayerTrackLine(
              mediaItem: const MediaItem(
                id: 'x',
                title: longTitle,
                album: 'Album largo',
                artist: 'Artista largo',
              ),
              metadata: metadata,
              colorScheme: const ColorScheme.dark(),
            ),
          ),
        ),
      ),
    );
    final text = tester.widget<Text>(
      find.descendant(
        of: find.byType(PlayerTrackLine),
        matching: find.byType(Text),
      ).last,
    );
    expect(text.overflow, TextOverflow.ellipsis);
    expect(text.maxLines, 1);
    expect(find.byType(OverflowMarquee), findsOneWidget);
  });

  group('the quality badge is centered in a 28 dp row', () {
    final cases = <(String, Duration, Map<String, Object>)>[
      ('FLAC', const Duration(minutes: 3), flac),
      (
        'HI-RES',
        const Duration(minutes: 10),
        {'verifiedAudioCodec': 'flac', 'verifiedAudioSampleRate': 96000},
      ),
      (
        'ATMOS',
        const Duration(hours: 1, minutes: 2, seconds: 3),
        {'verifiedAudioCodec': 'eac3', 'verifiedAudioSampleRate': 48000},
      ),
      (
        'AAC',
        const Duration(minutes: 4),
        {'verifiedAudioCodec': 'aac', 'verifiedAudioSampleRate': 44100},
      ),
    ];
    for (final (name, duration, extras) in cases) {
      testWidgets(name, (tester) async {
        final result = await measure(
          tester,
          extras: extras,
          duration: duration,
        );
        final selector = result.selector!;
        expect(selector.center.dx, closeTo(180, 1));
        expect(selector.height, lessThanOrEqualTo(28.5));
      });
    }
  });

  group('the video pill', () {
    Future<Rect> chip(
      WidgetTester tester, {
      bool active = false,
      bool loading = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: TrackVideoChip(
                onPressed: () {},
                active: active,
                loading: loading,
              ),
            ),
          ),
        ),
      );
      return tester.getRect(find.byType(TrackVideoChip));
    }

    testWidgets('keeps its rect at rest, loading, active and failed', (
      tester,
    ) async {
      final rest = await chip(tester);
      expect(rest.height, greaterThanOrEqualTo(44));
      expect(await chip(tester, loading: true), rest);
      expect(await chip(tester, active: true), rest);
      expect(await chip(tester, active: true, loading: true), rest);
      expect(await chip(tester), rest);
    });

    testWidgets('the video mark fills the quality slot and then leaves', (
      tester,
    ) async {
      final metadata = PlayerMetadataController(automaticOnlineSearch: false);
      addTearDown(metadata.dispose);
      await metadata.load(
        const MediaItem(
          id: 'song',
          title: 'Song',
          extras: {
            'source': 'catalog:song',
            'verifiedAudioCodec': 'flac',
            'verifiedAudioSampleRate': 44100,
          },
        ),
      );
      final session = _Session();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [playerVideoSessionProvider.overrideWith(() => session)],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Center(
                child: PlayerCoverQuality(
                  metadata: metadata,
                  colorScheme: const ColorScheme.dark(),
                  slim: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(TrackQualitySelector), findsOneWidget);
      expect(find.byType(PreparingVideoMark), findsNothing);

      final started = DateTime.now();
      session.put(PlayerVideoSession(loadingKey: 'k', started: started));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PreparingVideoMark), findsOneWidget);
      expect(find.byType(TrackQualitySelector), findsNothing);
      double fill() => tester
          .widgetList<ClipRect>(
            find.descendant(
              of: find.byType(PreparingVideoMark),
              matching: find.byType(ClipRect),
            ),
          )
          .map((c) => c.clipper)
          .whereType<VideoFillClipper>()
          .first
          .fill;
      await tester.pump(const Duration(seconds: 1));
      final early = fill();
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 300));
      final late = fill();
      expect(early, greaterThan(0));
      expect(late, greaterThan(early));
      expect(late, lessThanOrEqualTo(0.95));
      expect(
        tester.getRect(find.byType(PreparingVideoMark)).height,
        lessThanOrEqualTo(28.5),
      );

      session.put(
        PlayerVideoSession(
          loadingKey: 'k',
          started: started,
          done: true,
          activeKey: 'k',
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 500));
      expect(fill(), closeTo(1, 0.01));

      session.put(const PlayerVideoSession(activeKey: 'k'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(PreparingVideoMark), findsNothing);
      expect(find.byType(TrackQualitySelector), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}
