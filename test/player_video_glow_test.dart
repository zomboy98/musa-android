import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/theme_settings.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/player_video_glow.dart';
import 'package:mornye/widgets/player_canvas_background.dart';
import 'package:mornye/widgets/player_video_glow.dart';
import 'package:mornye/widgets/player_video_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  int creations = 0;
  final disposed = <int>[];
  final seeks = <int>[];
  final speeds = <double>[];
  final playing = <int, bool>{};
  Duration position = Duration.zero;

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async =>
      ++creations;

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => Stream.value(
    VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 30),
      size: const Size(1280, 720),
    ),
  );

  @override
  Future<void> play(int playerId) async => playing[playerId] = true;

  @override
  Future<void> pause(int playerId) async => playing[playerId] = false;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async =>
      speeds.add(speed);

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {
    seeks.add(position.inMilliseconds);
    this.position = position;
  }

  @override
  Future<Duration> getPosition(int playerId) async => position;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);
}

class _FixedTheme extends ThemeNotifier {
  _FixedTheme(this.settings);
  final ThemeSettings settings;
  @override
  ThemeSettings build() => settings;
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

Future<VideoPlayerController> _ready() async {
  final controller = VideoPlayerController.file(File('/clips/v.mp4'));
  await controller.initialize();
  return controller;
}

Future<void> _microtasks(WidgetTester tester) =>
    tester.runAsync(() => Future<void>.delayed(Duration.zero));

Widget _glow(
  PlayerVideoGlowSource source, {
  bool reduce = false,
  bool amoled = false,
}) => ProviderScope(
  overrides: [
    themeProvider.overrideWith(
      () => _FixedTheme(
        ThemeSettings(style: defaultAppThemeStyle(), useAmoled: amoled),
      ),
    ),
  ],
  child: MediaQuery(
    data: MediaQueryData(disableAnimations: reduce),
    child: MaterialApp(
      home: Stack(
        fit: StackFit.expand,
        children: [PlayerVideoGlow(source: source, timings: false)],
      ),
    ),
  ),
);

void main() {
  late _Platform platform;
  late VideoPlayerPlatform previous;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    previous = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() => VideoPlayerPlatform.instance = previous);

  group('glow', () {
    testWidgets('appears only while a video is published and fades away', (
      tester,
    ) async {
      final source = PlayerVideoGlowSource();
      await tester.pumpWidget(_glow(source));
      expect(find.byType(VideoPlayer), findsNothing);
      final controller = await tester.runAsync(_ready);
      source.publish(controller!);
      await _microtasks(tester);
      await tester.pump();
      expect(find.byType(VideoPlayer), findsOneWidget);
      await tester.pump(playerVideoGlowFadeIn);
      expect(
        tester
            .widget<AnimatedOpacity>(
              find.byKey(const ValueKey('player-video-glow')),
            )
            .opacity,
        playerVideoGlowOpacity,
      );
      source.retire(controller);
      await _microtasks(tester);
      await tester.pump();
      expect(platform.disposed, isEmpty);
      await tester.pump(playerVideoGlowFadeIn);
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(VideoPlayer), findsNothing);
      await _microtasks(tester);
      expect(platform.disposed, [1]);
    });

    testWidgets('stays off with reduced motion', (tester) async {
      final source = PlayerVideoGlowSource();
      final controller = await tester.runAsync(_ready);
      await tester.pumpWidget(_glow(source, reduce: true));
      source.publish(controller!);
      await _microtasks(tester);
      await tester.pump(playerVideoGlowFadeIn);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(ImageFiltered), findsNothing);
    });

    testWidgets('stays off on AMOLED black', (tester) async {
      final source = PlayerVideoGlowSource();
      final controller = await tester.runAsync(_ready);
      await tester.pumpWidget(_glow(source, amoled: true));
      await tester.pump();
      source.publish(controller!);
      await _microtasks(tester);
      await tester.pump(playerVideoGlowFadeIn);
      expect(find.byType(VideoPlayer), findsNothing);
    });

    testWidgets('blurs the shared texture inside its own repaint boundary', (
      tester,
    ) async {
      final source = PlayerVideoGlowSource();
      final controller = await tester.runAsync(_ready);
      await tester.pumpWidget(_glow(source));
      source.publish(controller!);
      await _microtasks(tester);
      await tester.pump();
      expect(find.byType(ImageFiltered), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(ImageFiltered),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
      expect(
        find.byKey(const ValueKey('player-video-glow-veil')),
        findsOneWidget,
      );
    });

    test('frame governor gives up only after sustained slow frames', () {
      final governor = PlayerVideoGlowFrameGovernor(warmup: 2, window: 10);
      const fast = Duration(milliseconds: 8);
      const slow = Duration(milliseconds: 30);
      for (var i = 0; i < 2; i++) {
        expect(governor.add(slow), isFalse);
      }
      var gaveUp = false;
      for (var i = 0; i < 10; i++) {
        gaveUp = governor.add(i.isEven ? fast : slow);
      }
      expect(gaveUp, isTrue);
      for (var i = 0; i < 10; i++) {
        gaveUp = governor.add(i == 0 ? slow : fast);
      }
      expect(gaveUp, isFalse);
    });
  });

  group('surface', () {
    final playing = NotifierProvider<_Flag<bool>, bool>(
      () => _Flag<bool>(true),
    );
    final position = NotifierProvider<_Flag<Duration>, Duration>(
      () => _Flag<Duration>(const Duration(seconds: 5)),
    );

    Widget app(PlayerVideoGlowSource source, {int rebuild = 0}) =>
        ProviderScope(
          overrides: [
            playbackPlayingProvider.overrideWith((ref) => ref.watch(playing)),
            playbackPositionProvider.overrideWith((ref) => ref.watch(position)),
          ],
          child: MaterialApp(
            home: Column(
              children: [
                Text('rebuild $rebuild'),
                SizedBox(
                  width: 360,
                  height: 200,
                  child: PlayerVideoSurface(
                    path: '/clips/v.mp4',
                    fallback: const Text('cover'),
                    controllerFactory: _factory,
                    afterOpen: _noop,
                    glowSource: source,
                  ),
                ),
              ],
            ),
          ),
        );

    testWidgets('keeps one controller across rebuilds and reveals the first '
        'frame over the cover', (tester) async {
      final source = PlayerVideoGlowSource();
      await tester.pumpWidget(app(source));
      await tester.pump();
      await tester.pump();
      expect(platform.creations, 1);
      expect(find.text('cover'), findsOneWidget);
      expect(source.value, isNull);
      for (var i = 1; i <= 5; i++) {
        await tester.pumpWidget(app(source, rebuild: i));
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(platform.creations, 1);
      expect(platform.disposed, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(milliseconds: 300));
      await _microtasks(tester);
      expect(source.value, isNotNull);
      expect(find.text('cover'), findsNothing);
    });

    testWidgets('publishes to the glow and hands the decoder over on exit', (
      tester,
    ) async {
      final source = PlayerVideoGlowSource();
      await tester.pumpWidget(app(source));
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      await _microtasks(tester);
      expect(source.value, isNotNull);
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await _microtasks(tester);
      await tester.pump();
      expect(source.value, isNull);
      expect(platform.disposed, [1]);
    });

    testWidgets('a drift under the seek threshold never seeks', (tester) async {
      final source = PlayerVideoGlowSource();
      await tester.pumpWidget(app(source));
      await tester.pump();
      await tester.pump();
      final seeks = platform.seeks.length;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(PlayerVideoSurface)),
      );
      for (var i = 1; i <= 20; i++) {
        container
            .read(position.notifier)
            .set(Duration(seconds: 5, milliseconds: 300 + i * 10));
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
      }
      expect(platform.seeks.length, seeks);
    });
  });

  group('sync governor', () {
    Duration ms(int v) => Duration(milliseconds: v);

    test('absorbs a moderate drift with rate nudges and restores the rate', () {
      final governor = PlayerVideoSyncGovernor();
      final actions = <PlayerVideoCorrection>[];
      var video = 9700;
      for (var t = 0; t < 20000; t += 500) {
        final action = governor.correction(
          now: ms(t),
          video: ms(video),
          audio: ms(10000 + t),
        );
        if (action != PlayerVideoCorrection.none) actions.add(action);
        video += (500 * governor.rate).round();
      }
      expect(actions, isNotEmpty);
      expect(actions.first, PlayerVideoCorrection.speedUp);
      expect(actions.last, PlayerVideoCorrection.restoreSpeed);
      expect(actions.contains(PlayerVideoCorrection.seek), isFalse);
      expect(governor.corrections, 0);
      expect(governor.rate, 1.0);
    });

    test('repeated evaluations of the same drift change the rate once', () {
      final governor = PlayerVideoSyncGovernor();
      var changes = 0;
      for (var t = 0; t < 10000; t += 500) {
        final action = governor.correction(
          now: ms(t),
          video: ms(10400),
          audio: ms(10000),
        );
        if (action != PlayerVideoCorrection.none) changes++;
      }
      expect(changes, 1);
      expect(governor.rate, playerVideoEaseRate);
    });
  });

  group('canvas', () {
    testWidgets('keeps the video inside a repaint boundary and fades in', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 360,
            height: 800,
            child: PlayerCanvasBackground(
              source: 'file:///clips/a.mp4',
              playing: false,
              controllerFactory: _factory,
              afterOpen: _noop,
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(VideoPlayer),
          matching: find.byType(RepaintBoundary),
        ),
        findsWidgets,
      );
    });
  });
}
