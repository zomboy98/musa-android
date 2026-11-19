import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/cover_mimic.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';
import 'package:mornye/widgets/player_canvas_background.dart';
import 'package:mornye/widgets/player_video_surface.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  final sources = <int, DataSource>{};
  final playing = <int, bool>{};
  final volumes = <int, double>{};
  final looping = <int, bool>{};
  final seeks = <int, List<Duration>>{};
  final disposed = <int>[];
  final positions = <int, Duration>{};
  final speeds = <int, List<double>>{};
  int creations = 0;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = ++creations;
    sources[id] = options.dataSource;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 30),
      size: const Size(720, 1280),
    ),
  );

  @override
  Future<void> play(int playerId) async => playing[playerId] = true;

  @override
  Future<void> pause(int playerId) async => playing[playerId] = false;

  @override
  Future<void> setLooping(int playerId, bool looping) async =>
      this.looping[playerId] = looping;

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      volumes[playerId] = volume;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async =>
      (speeds[playerId] ??= []).add(speed);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    (seeks[playerId] ??= []).add(position);
    positions[playerId] = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async =>
      positions[playerId] ?? Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);
}

class _Flag<T> extends Notifier<T> {
  _Flag(this.initial);
  final T initial;
  @override
  T build() => initial;
  void set(T value) => state = value;
}

VideoPlayerController _factory(File file) => VideoPlayerController.file(file);

Future<void> _noop() async {}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Widget _canvas(String? source, {bool playing = true}) => MaterialApp(
  home: SizedBox(
    width: 360,
    height: 800,
    child: source == null
        ? const SizedBox()
        : PlayerCanvasBackground(
            source: source,
            playing: playing,
            controllerFactory: _factory,
            afterOpen: _noop,
          ),
  ),
);

void main() {
  late _Platform platform;
  late VideoPlayerPlatform previous;

  setUp(() {
    previous = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() => VideoPlayerPlatform.instance = previous);

  testWidgets('canvas plays muted in a loop, covering the screen', (
    tester,
  ) async {
    await tester.pumpWidget(_canvas('file:///clips/a.mp4'));
    expect(find.byType(VideoPlayer), findsNothing);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(VideoPlayer), findsOneWidget);
    expect(find.byKey(const ValueKey('canvas-veil')), findsOneWidget);
    expect(platform.volumes[1], 0);
    expect(platform.looping[1], isTrue);
    expect(platform.playing[1], isTrue);
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
  });

  Widget fitted({CoverMimicLiveSource? live, double width = 411}) =>
      MaterialApp(
        home: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: 891,
            child: PlayerCanvasBackground(
              source: '/clips/a.mp4',
              playing: true,
              controllerFactory: _factory,
              afterOpen: _noop,
              adaptiveFit: true,
              edgeScrims: true,
              liveSource: live,
            ),
          ),
        ),
      );

  testWidgets('a tall video is shown whole at the width, fading below', (
    tester,
  ) async {
    final live = CoverMimicLiveSource();
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(fitted(live: live));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 800));
    final box = find.byKey(const ValueKey('canvas-video-fit-width'));
    final rect = tester.getRect(box);
    expect(rect.width, 411);
    expect(rect.top, 0);
    expect(rect.height, closeTo(411 / (720 / 1280), 0.01));
    expect(rect.bottom, lessThan(891));
    expect(find.byType(ShaderMask), findsOneWidget);
    expect(find.byType(FittedBox), findsNothing);
    expect(live.bottomBand, mimicBottomBand);
    expect(live.boundary, isNotNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a video that fits the area keeps covering it', (tester) async {
    final live = CoverMimicLiveSource();
    tester.view.physicalSize = const Size(600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(fitted(live: live, width: 480));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byKey(const ValueKey('canvas-video-fit-width')), findsNothing);
    expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.cover);
    expect(live.bottomBand, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('canvas holds still while the song is paused', (tester) async {
    await tester.pumpWidget(_canvas('/clips/a.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(platform.playing[1], isTrue);
    await tester.pumpWidget(_canvas('/clips/a.mp4', playing: false));
    await tester.pump();
    expect(platform.playing[1], isFalse);
    await tester.pumpWidget(_canvas('/clips/a.mp4'));
    await tester.pump();
    expect(platform.playing[1], isTrue);
  });

  testWidgets('canvas pauses in the background and resumes', (tester) async {
    await tester.pumpWidget(_canvas('/clips/a.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(platform.playing[1], isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(platform.playing[1], isTrue);
  });

  testWidgets('canvas frees the decoder when the source changes or leaves', (
    tester,
  ) async {
    await tester.pumpWidget(_canvas('/clips/a.mp4'));
    await tester.pump();
    await tester.pumpWidget(_canvas('/clips/b.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await _settle(tester);
    expect(platform.disposed, contains(1));
    expect(platform.sources[2]?.uri, contains('b.mp4'));
    await tester.pumpWidget(_canvas(null));
    await _settle(tester);
    expect(platform.disposed, containsAll([1, 2]));
  });

  testWidgets('canvas draws nothing when animations are reduced', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: PlayerCanvasBackground(
            source: '/clips/a.mp4',
            playing: true,
            controllerFactory: _factory,
            afterOpen: _noop,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.byType(VideoPlayer), findsNothing);
  });

  testWidgets('canvas never opens the decoder when animations are reduced', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: MaterialApp(
          home: PlayerCanvasBackground(
            source: '/clips/a.mp4',
            playing: true,
            controllerFactory: _factory,
            afterOpen: _noop,
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(platform.creations, 0);
  });

  testWidgets('canvas pauses while another route covers the player', (
    tester,
  ) async {
    Widget host(bool covered) => MaterialApp(
      home: TickerMode(
        enabled: !covered,
        child: PlayerCanvasBackground(
          source: '/clips/a.mp4',
          playing: true,
          controllerFactory: _factory,
          afterOpen: _noop,
        ),
      ),
    );
    await tester.pumpWidget(host(false));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(platform.playing[1], isTrue);
    await tester.pumpWidget(host(true));
    await tester.pump();
    expect(platform.playing[1], isFalse);
    await tester.pumpWidget(host(false));
    await tester.pump();
    expect(platform.playing[1], isTrue);
  });

  testWidgets('the veil keeps text readable over bright video', (tester) async {
    await tester.pumpWidget(_canvas('/clips/a.mp4'));
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 800));
    final box = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('canvas-veil')),
    );
    final gradient =
        (box.decoration as BoxDecoration).gradient! as LinearGradient;
    final alphas = gradient.colors.map((c) => c.a).toList();
    expect(alphas.first, greaterThanOrEqualTo(canvasVeilTopFloor - 0.01));
    expect(alphas[2], greaterThanOrEqualTo(canvasVeilTextFloor - 0.01));
    expect(alphas.last, greaterThanOrEqualTo(canvasVeilBottomFloor - 0.01));
    expect(gradient.stops![2], 0.5);
  });

  group('video surface', () {
    var syncClock = Duration.zero;
    setUp(() => syncClock = Duration.zero);
    final playingProvider = NotifierProvider<_Flag<bool>, bool>(
      () => _Flag<bool>(true),
    );
    final positionProvider = NotifierProvider<_Flag<Duration>, Duration>(
      () => _Flag<Duration>(const Duration(seconds: 12)),
    );

    Widget app() => ProviderScope(
      overrides: [
        playbackPlayingProvider.overrideWith(
          (ref) => ref.watch(playingProvider),
        ),
        playbackPositionProvider.overrideWith(
          (ref) => ref.watch(positionProvider),
        ),
      ],
      child: MaterialApp(
        home: SizedBox(
          width: 360,
          height: 300,
          child: PlayerVideoSurface(
            path: '/clips/v.mp4',
            fallback: const Text('cover'),
            controllerFactory: _factory,
            afterOpen: _noop,
            clock: () => syncClock,
          ),
        ),
      ),
    );

    testWidgets('starts at the audio position, silent, over the cover', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      expect(find.text('cover'), findsOneWidget);
      await tester.pump();
      await tester.pump();
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(find.text('cover'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('cover'), findsNothing);
      expect(platform.volumes[1], 0);
      expect(platform.seeks[1]?.first, const Duration(seconds: 12));
      expect(platform.playing[1], isTrue);
    });

    testWidgets(
      'eases small drifts with the playback rate and seeks only far off',
      (tester) async {
        await tester.pumpWidget(app());
        await tester.pump();
        await tester.pump();
        final container = ProviderScope.containerOf(
          tester.element(find.byType(PlayerVideoSurface)),
        );
        final seeks = platform.seeks[1]!.length;
        final speeds = List<double>.of(platform.speeds[1] ?? const []);
        syncClock = const Duration(seconds: 1);
        container
            .read(positionProvider.notifier)
            .set(const Duration(seconds: 12, milliseconds: 60));
        await tester.pump();
        await tester.pump();
        expect(platform.seeks[1]!.length, seeks);
        expect(platform.speeds[1] ?? const [], speeds);
        syncClock = const Duration(seconds: 2);
        container
            .read(positionProvider.notifier)
            .set(const Duration(seconds: 12, milliseconds: 300));
        await tester.pump();
        await tester.pump();
        expect(platform.seeks[1]!.length, seeks);
        expect(platform.speeds[1], [...speeds, playerVideoCatchUpRate]);
        syncClock = const Duration(seconds: 3);
        container
            .read(positionProvider.notifier)
            .set(const Duration(seconds: 12, milliseconds: 320));
        await tester.pump();
        await tester.pump();
        expect(platform.speeds[1], [...speeds, playerVideoCatchUpRate]);
        syncClock = const Duration(milliseconds: 3600);
        container
            .read(positionProvider.notifier)
            .set(const Duration(seconds: 14));
        await tester.pump();
        await tester.pump();
        expect(platform.seeks[1]!.length, seeks + 1);
        expect(platform.speeds[1], [...speeds, playerVideoCatchUpRate, 1.0]);
        final landed = platform.seeks[1]!.last;
        expect(landed >= const Duration(seconds: 14), isTrue);
        expect(landed < const Duration(seconds: 14, milliseconds: 700), isTrue);
        syncClock = const Duration(seconds: 4);
        container
            .read(positionProvider.notifier)
            .set(const Duration(seconds: 17));
        await tester.pump();
        await tester.pump();
        expect(platform.seeks[1]!.length, seeks + 1);
        container.read(playingProvider.notifier).set(false);
        await tester.pump();
        expect(platform.playing[1], isFalse);
      },
    );

    testWidgets('does not seek once the audio is past the end of the clip', (
      tester,
    ) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerVideoSurface)),
      );
      final seeks = platform.seeks[1]!.length;
      container
          .read(positionProvider.notifier)
          .set(const Duration(seconds: 45));
      await tester.pump();
      await tester.pump();
      expect(platform.seeks[1]!.length, seeks);
    });

    test('video correction rules', () {
      const audio = Duration(seconds: 10);
      expect(
        playerVideoCorrection(
          video: audio + const Duration(milliseconds: 100),
          audio: audio,
        ),
        PlayerVideoCorrection.none,
      );
      expect(
        playerVideoCorrection(
          video: audio + const Duration(milliseconds: 200),
          audio: audio,
        ),
        PlayerVideoCorrection.slowDown,
      );
      expect(
        playerVideoCorrection(
          video: audio - const Duration(milliseconds: 200),
          audio: audio,
        ),
        PlayerVideoCorrection.speedUp,
      );
      expect(
        playerVideoCorrection(
          video: audio - const Duration(milliseconds: 900),
          audio: audio,
        ),
        PlayerVideoCorrection.seek,
      );
      expect(
        playerVideoCorrection(
          video: const Duration(seconds: 30),
          audio: const Duration(seconds: 40),
          duration: const Duration(seconds: 30),
        ),
        PlayerVideoCorrection.none,
      );
    });

    testWidgets('releases the decoder when removed', (tester) async {
      await tester.pumpWidget(app());
      await tester.pump();
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _settle(tester);
      expect(platform.disposed, contains(1));
    });
  });
}
