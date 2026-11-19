import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/screens/downloaded_album_screen.dart';
import 'package:mornye/screens/local_album_screen.dart';
import 'package:mornye/services/library_database.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/mornye_player_artwork.dart';
import 'package:mornye/widgets/motion_header_banner.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:video_player/video_player.dart';

class _VideoPlatform extends VideoPlayerPlatform {
  bool playing = false;
  int playCalls = 0;
  bool looping = false;
  double volume = 1;
  DataSource? source;
  int creations = 0;
  int disposals = 0;
  Map<int, StreamController<VideoEvent>>? events;
  Completer<void>? disposalPending;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    source = options.dataSource;
    final id = ++creations;
    events?[id] = StreamController<VideoEvent>();
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      events?[playerId]?.stream ??
      Stream.value(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 30),
          size: const Size(320, 180),
        ),
      );

  @override
  Future<void> play(int playerId) async {
    playing = true;
    playCalls++;
  }

  @override
  Future<void> pause(int playerId) async => playing = false;

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      this.looping = looping;

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      this.volume = volume;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async {
    disposals++;
    playing = false;
    await disposalPending?.future;
    await events?[playerId]?.close();
  }
}

class _MotionSettings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings();
}

class _PlaybackFlag extends Notifier<bool> {
  _PlaybackFlag(this.initial);
  final bool initial;
  @override
  bool build() => initial;
  void set(bool value) => state = value;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('borrowed video appears after lifecycle resume without rebuild', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final controller = VideoPlayerController.networkUrl(
      Uri.parse('https://example.com/cover.mp4'),
    );
    await tester.runAsync(controller.initialize);
    addTearDown(controller.dispose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
        child: MaterialApp(
          home: MotionHeaderBanner(
            videoUrl: 'https://example.com/cover.mp4',
            controller: controller,
            fallback: const Text('Still artwork'),
          ),
        ),
      ),
    );
    expect(find.byType(VideoPlayer), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump();
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(platform.playing, isTrue);
    expect(platform.creations, 1);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('hidden banner defers decoder creation until visible', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    Widget app(bool visible) => ProviderScope(
      overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
      child: MaterialApp(
        home: TickerMode(
          enabled: visible,
          child: const MotionHeaderBanner(
            videoUrl: 'https://example.com/cover.mp4',
            fallback: Text('Still artwork'),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(false));
    await tester.pump();
    expect(platform.creations, 0);
    await tester.pumpWidget(app(true));
    await tester.pumpAndSettle();
    expect(platform.creations, 1);
    expect(platform.playing, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
  for (final borrowed in [false, true]) {
    testWidgets('reduced motion stops decoding and restores only visible video '
        '(borrowed: $borrowed)', (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      VideoPlayerController? controller;
      if (borrowed) {
        controller = VideoPlayerController.networkUrl(
          Uri.parse('https://example.com/cover.mp4'),
        );
        await tester.runAsync(() => controller!.initialize());
        addTearDown(controller.dispose);
      }
      Widget app({
        required bool reduced,
        bool active = true,
        bool otherVisible = false,
      }) => ProviderScope(
        overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
        child: MaterialApp(
          home: Column(
            children: [
              MediaQuery(
                data: MediaQueryData(disableAnimations: reduced),
                child: TickerMode(
                  enabled: active,
                  child: SizedBox(
                    height: 100,
                    child: MotionHeaderBanner(
                      videoUrl: 'https://example.com/cover.mp4',
                      controller: controller,
                      fallback: const Text('Still artwork'),
                    ),
                  ),
                ),
              ),
              if (otherVisible)
                SizedBox(
                  height: 100,
                  child: MotionHeaderBanner(
                    videoUrl: 'https://example.com/cover.mp4',
                    controller: controller,
                    fallback: const Text('Other artwork'),
                  ),
                ),
            ],
          ),
        ),
      );
      await tester.pumpWidget(app(reduced: true));
      await tester.pumpAndSettle();
      expect(platform.creations, borrowed ? 1 : 0);
      expect(platform.playing, isFalse);
      expect(find.byType(VideoPlayer), findsNothing);
      await tester.pumpWidget(app(reduced: false));
      await tester.pumpAndSettle();
      expect(platform.playing, isTrue);
      await tester.pumpWidget(app(reduced: true));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.playing, isFalse);
      expect(find.byType(VideoPlayer), findsNothing);
      await tester.pumpWidget(app(reduced: false, active: false));
      await tester.pumpAndSettle();
      expect(platform.playing, isFalse);
      await tester.pumpWidget(app(reduced: false));
      await tester.pumpAndSettle();
      expect(platform.playing, isTrue);
      if (borrowed) {
        await tester.pumpWidget(app(reduced: false, otherVisible: true));
        await tester.pumpAndSettle();
        await tester.pumpWidget(app(reduced: true, otherVisible: true));
        await tester.pumpAndSettle();
        expect(
          platform.playing,
          isTrue,
          reason: 'The other visible borrower still needs the controller',
        );
        expect(platform.disposals, 0);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
  for (final prepared in [false, true]) {
    testWidgets(
      'failed video is disposed while its owner stays mounted ($prepared)',
      (tester) async {
        final previous = VideoPlayerPlatform.instance;
        final platform = _VideoPlatform()
          ..events = {}
          ..disposalPending = Completer<void>();
        VideoPlayerPlatform.instance = platform;
        addTearDown(() => VideoPlayerPlatform.instance = previous);
        final container = ProviderContainer(
          overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
        );
        const source = 'file:///failed-cover.mp4';
        final failure = PlatformException(
          code: 'video',
          message: 'Invalid cover',
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              home: prepared
                  ? Consumer(
                      builder: (context, ref, _) {
                        final video = ref.watch(
                          playerArtworkVideoProvider(source),
                        );
                        return Text(
                          video.hasError ? 'Failed cover' : 'Preparing',
                        );
                      },
                    )
                  : const MotionHeaderBanner(
                      videoUrl: source,
                      fallback: Text('Failed cover'),
                    ),
            ),
          ),
        );
        await tester.pump();
        expect(platform.creations, 1);
        platform.events![1]!.addError(failure);
        await tester.pump();
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(find.text('Failed cover'), findsOneWidget);
        expect(platform.disposals, 1);
        // Tear down before platform disposal completes to cover concurrent calls.
        await tester.pumpWidget(const SizedBox());
        container.dispose();
        await tester.pump();
        expect(platform.disposals, 1);
        platform.disposalPending!.complete();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        expect(platform.disposals, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('artwork switch prevents decoding and disposes active video', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final container = ProviderContainer(
      overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
    );
    addTearDown(container.dispose);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(false);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: MotionHeaderBanner(
            videoUrl: 'file:///cover.mp4',
            fallback: Text('Still artwork'),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(platform.creations, 0);
    expect(find.text('Still artwork'), findsOneWidget);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(true);
    await tester.pumpAndSettle();
    expect(platform.creations, 1);
    expect(platform.playing, isTrue);
    container.read(settingsProvider.notifier).setMotionArtworkEnabled(false);
    await tester.pumpAndSettle();
    expect(find.text('Still artwork'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Controller disposal awaits cancellation of the platform event stream.
    await tester.runAsync(() async => Future<void>.delayed(Duration.zero));
    expect(platform.disposals, 1);
    await tester.pumpWidget(const SizedBox());
  });
  for (final downloaded in [false, true]) {
    for (final mode in ['saved', 'missing', 'reduced motion']) {
      testWidgets(
        'local album uses saved motion with fallback (downloaded: $downloaded, $mode)',
        (tester) async {
          SharedPreferences.setMockInitialValues({});
          final previous = VideoPlayerPlatform.instance;
          final platform = _VideoPlatform();
          VideoPlayerPlatform.instance = platform;
          addTearDown(() => VideoPlayerPlatform.instance = previous);
          const channel = MethodChannel('com.zarz.mornye/backend');
          final messenger =
              TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
          messenger.setMockMethodCallHandler(channel, (_) async => null);
          addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
          var lookups = 0;
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                playerMotionArtworkProvider.overrideWith((ref, album) async {
                  lookups++;
                  expect(album, (album: 'Album', artist: 'Track Artist'));
                  return mode == 'missing'
                      ? null
                      : const MotionArtwork('file:///album-cover.mp4');
                }),
                downloadedAlbumTracksProvider(
                  const DownloadedAlbumTracksRequest(
                    albumName: 'Album',
                    artistName: 'Album Artist',
                  ),
                ).overrideWith(
                  (ref) async => [
                    DownloadHistoryItem(
                      id: 'track',
                      trackName: 'Track',
                      artistName: 'Track Artist',
                      albumName: 'Album',
                      albumArtist: 'Album Artist',
                      filePath: 'content://library/track.flac',
                      service: 'provider-a',
                      downloadedAt: DateTime(2026),
                    ),
                  ],
                ),
              ],
              child: MaterialApp(
                theme: MornyeTheme.build(Brightness.light),
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(disableAnimations: mode == 'reduced motion'),
                  child: child!,
                ),
                home: downloaded
                    ? const DownloadedAlbumScreen(
                        albumName: 'Album',
                        artistName: 'Album Artist',
                      )
                    : LocalAlbumScreen(
                        albumName: 'Album',
                        artistName: 'Album Artist',
                        tracks: [
                          LocalLibraryItem(
                            id: 'track',
                            trackName: 'Track',
                            artistName: 'Track Artist',
                            albumName: 'Album',
                            albumArtist: 'Album Artist',
                            filePath: 'content://library/track.flac',
                            scannedAt: DateTime(2026),
                          ),
                        ],
                      ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(lookups, mode == 'reduced motion' ? 0 : 1);
          if (mode == 'saved') {
            expect(find.byType(MotionHeaderBanner), findsOneWidget);
            expect(platform.source?.sourceType, DataSourceType.file);
            expect(platform.playing, isTrue);
            expect(platform.looping, isTrue);
            expect(platform.volume, 0);
          } else {
            expect(find.byType(MotionHeaderBanner), findsNothing);
            expect(platform.creations, 0);
          }
          expect(find.text('Album Artist'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  testWidgets(
    'prepared player video opens without a new decoder and fades over the still',
    (tester) async {
      final previous = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      final show = ValueNotifier(false);
      addTearDown(show.dispose);
      final playing = NotifierProvider<_PlaybackFlag, bool>(
        () => _PlaybackFlag(true),
      );
      final loading = NotifierProvider<_PlaybackFlag, bool>(
        () => _PlaybackFlag(false),
      );
      late WidgetRef playerRef;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            playbackPlayingProvider.overrideWith((ref) => ref.watch(playing)),
            playbackLoadingProvider.overrideWith((ref) => ref.watch(loading)),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, _) {
                playerRef = ref;
                ref.watch(playerArtworkVideoProvider('file:///cover.mp4'));
                return ValueListenableBuilder(
                  valueListenable: show,
                  builder: (_, visible, _) => visible
                      ? const MornyePlayerArtwork(
                          mediaItem: MediaItem(id: 'song', title: 'Song'),
                          videoUrl: 'file:///cover.mp4',
                        )
                      : const SizedBox(),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();
      expect(platform.creations, 1);
      expect(platform.playing, isFalse);
      show.value = true;
      await tester.pump();
      expect(platform.creations, 1);
      expect(platform.playing, isTrue);
      final banner = tester.widget<MotionHeaderBanner>(
        find.byType(MotionHeaderBanner),
      );
      expect(banner.controller!.value.isInitialized, isTrue);
      expect(banner.fadeDuration, const Duration(milliseconds: 450));
      playerRef.read(playing.notifier).set(false);
      await tester.pump();
      expect(platform.playing, isFalse);
      expect(platform.disposals, 0);
      expect(find.byType(VideoPlayer), findsOneWidget);
      playerRef.read(playing.notifier).set(true);
      playerRef.read(loading.notifier).set(true);
      await tester.pump();
      expect(platform.playing, isFalse);
      playerRef.read(loading.notifier).set(false);
      await tester.pump();
      expect(platform.playing, isTrue);
      expect(platform.creations, 1);
      show.value = false;
      await tester.pump();
      expect(platform.playing, isFalse);
      expect(platform.disposals, 0);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      expect(platform.disposals, 1);
    },
  );

  testWidgets('an outgoing cover leaves the shared video playing', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    // Rotating the player fades the portrait cover out while the landscape
    // cover borrows the same video.
    final covers = ValueNotifier({'portrait'});
    addTearDown(covers.dispose);
    final playing = NotifierProvider<_PlaybackFlag, bool>(
      () => _PlaybackFlag(true),
    );
    late WidgetRef playerRef;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackPlayingProvider.overrideWith((ref) => ref.watch(playing)),
          playbackLoadingProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: Consumer(
            builder: (context, ref, _) {
              playerRef = ref;
              ref.watch(playerArtworkVideoProvider('file:///cover.mp4'));
              return ValueListenableBuilder(
                valueListenable: covers,
                builder: (_, shown, _) => Column(
                  children: [
                    for (final cover in shown)
                      SizedBox(
                        key: ValueKey(cover),
                        height: 100,
                        child: const MornyePlayerArtwork(
                          mediaItem: MediaItem(id: 'song', title: 'Song'),
                          videoUrl: 'file:///cover.mp4',
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {'portrait', 'landscape'};
    await tester.pump();
    expect(platform.playing, isTrue);
    playerRef.read(playing.notifier).set(false);
    await tester.pump();
    expect(platform.playing, isFalse);
    expect(platform.creations, 1);
    expect(platform.disposals, 0);
    playerRef.read(playing.notifier).set(true);
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {'landscape'};
    await tester.pump();
    expect(platform.playing, isTrue);
    covers.value = {};
    await tester.pump();
    expect(platform.playing, isFalse);
    expect(platform.disposals, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  });

  testWidgets('changing tracks retains video until the new frame is ready', (
    tester,
  ) async {
    final previous = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform()..events = {};
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previous);
    final source = ValueNotifier('file:///first.mp4');
    addTearDown(source.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackPlayingProvider.overrideWith((ref) => true),
          playbackLoadingProvider.overrideWith((ref) => false),
        ],
        child: MaterialApp(
          home: ValueListenableBuilder(
            valueListenable: source,
            builder: (_, url, _) => MornyePlayerArtwork(
              mediaItem: MediaItem(id: url, title: 'Song'),
              videoUrl: url,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    void ready(int id) => platform.events![id]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(300, 400),
      ),
    );
    ready(1);
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      source.value,
    );
    source.value = 'file:///second.mp4';
    await tester.pump();
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      'file:///first.mp4',
    );
    expect(platform.disposals, 0);
    ready(2);
    await tester.pump();
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(platform.disposals, 1, reason: 'Release the outgoing decoder');
    expect(
      tester
          .widget<MotionHeaderBanner>(find.byType(MotionHeaderBanner))
          .videoUrl,
      source.value,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
    'offline cover uses a silent looping file and reports its ratio',
    (tester) async {
      final previousPlatform = VideoPlayerPlatform.instance;
      final platform = _VideoPlatform();
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
      double? ratio;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
          child: MaterialApp(
            home: SizedBox(
              width: 320,
              height: 180,
              child: MotionHeaderBanner(
                videoUrl: 'file:///app/motion_artwork/cover.mp4',
                fallback: const ColoredBox(color: Colors.black),
                onAspectRatioChanged: (value) => ratio = value,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(platform.source?.sourceType, DataSourceType.file);
      expect(platform.looping, isTrue);
      expect(platform.volume, 0);
      expect(platform.playing, isTrue);
      expect(ratio, closeTo(320 / 180, 0.001));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('collapsed headers pause video and visible headers resume', (
    tester,
  ) async {
    final previousPlatform = VideoPlayerPlatform.instance;
    final platform = _VideoPlatform();
    VideoPlayerPlatform.instance = platform;
    addTearDown(() => VideoPlayerPlatform.instance = previousPlatform);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);

    Widget app({bool active = true}) => ProviderScope(
      overrides: [settingsProvider.overrideWith(_MotionSettings.new)],
      child: MaterialApp(
        home: Scaffold(
          body: TickerMode(
            enabled: active,
            child: CustomScrollView(
              controller: scroll,
              slivers: const [
                SliverAppBar(
                  pinned: true,
                  expandedHeight: 300,
                  flexibleSpace: FlexibleSpaceBar(
                    background: MotionHeaderBanner(
                      videoUrl: 'https://example.com/banner.m3u8',
                      fallback: ColoredBox(color: Colors.blue),
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: SizedBox(height: 2000)),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.pumpWidget(app());
    await tester.pump();
    expect(platform.playing, isTrue);
    expect(platform.looping, isTrue);
    expect(platform.volume, 0);
    final initialPlayCalls = platform.playCalls;

    scroll.jumpTo(50);
    await tester.pump();
    expect(platform.playCalls, initialPlayCalls);
    scroll.jumpTo(400);
    await tester.pump();
    expect(platform.playing, isFalse);

    scroll.jumpTo(0);
    await tester.pump();
    expect(platform.playing, isTrue);
    await tester.pumpWidget(app(active: false));
    await tester.pump();
    expect(platform.playing, isFalse);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(platform.playing, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.playing, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.playing, isTrue);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  group('animated cover replaces the still one', () {
    late _VideoPlatform platform;
    late NotifierProvider<_PlaybackFlag, bool> playing;
    late WidgetRef playerRef;
    setUp(() {
      final previous = VideoPlayerPlatform.instance;
      platform = _VideoPlatform()..events = {};
      VideoPlayerPlatform.instance = platform;
      addTearDown(() => VideoPlayerPlatform.instance = previous);
      playing = NotifierProvider<_PlaybackFlag, bool>(
        () => _PlaybackFlag(true),
      );
    });

    Widget cover({bool reduced = false}) => ProviderScope(
      overrides: [
        playbackPlayingProvider.overrideWith((ref) => ref.watch(playing)),
        playbackLoadingProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduced),
          child: Consumer(
            builder: (context, ref, _) {
              playerRef = ref;
              if (!reduced) {
                ref.watch(playerArtworkVideoProvider('file:///loop.mp4'));
              }
              return const MornyePlayerArtwork(
                mediaItem: MediaItem(id: 'song', title: 'Song'),
                videoUrl: 'file:///loop.mp4',
              );
            },
          ),
        ),
      ),
    );

    void videoReady() => platform.events![1]!.add(
      VideoEvent(
        eventType: VideoEventType.initialized,
        duration: const Duration(seconds: 10),
        size: const Size(400, 400),
      ),
    );

    double videoOpacity(WidgetTester tester) => tester
        .widget<FadeTransition>(
          find.descendant(
            of: find.byType(AnimatedOpacity),
            matching: find.byType(FadeTransition),
          ),
        )
        .opacity
        .value;

    testWidgets('the still stays visible while loading, then crossfades', (
      tester,
    ) async {
      await tester.pumpWidget(cover());
      await tester.pump();
      expect(find.byType(PlayerArtwork), findsOneWidget);
      expect(find.byType(VideoPlayer), findsNothing);
      videoReady();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(find.byType(PlayerArtwork), findsOneWidget);
      expect(find.byType(VideoPlayer), findsOneWidget);
      final fade = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(fade.duration, greaterThan(Duration.zero));
      await tester.pump(const Duration(milliseconds: 150));
      expect(videoOpacity(tester), inExclusiveRange(0, 1));
      await tester.pumpAndSettle();
      expect(videoOpacity(tester), 1);
      expect(platform.looping, isTrue);
      expect(platform.volume, 0);
      expect(platform.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('pausing playback or leaving the app holds the loop', (
      tester,
    ) async {
      await tester.pumpWidget(cover());
      await tester.pump();
      videoReady();
      await tester.pump();
      await tester.pump();
      expect(platform.playing, isTrue);
      playerRef.read(playing.notifier).set(false);
      await tester.pump();
      expect(platform.playing, isFalse);
      playerRef.read(playing.notifier).set(true);
      await tester.pump();
      expect(platform.playing, isTrue);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(platform.playing, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(platform.playing, isTrue);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    });

    testWidgets('remove animations keeps the still cover and no decoder', (
      tester,
    ) async {
      await tester.pumpWidget(cover(reduced: true));
      await tester.pump();
      expect(find.byType(PlayerArtwork), findsOneWidget);
      expect(find.byType(MotionHeaderBanner), findsNothing);
      expect(platform.creations, 0);
    });
  });
}
