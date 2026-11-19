import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/library_collections_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_apple_artwork_provider.dart';
import 'package:mornye/providers/player_artwork_video_provider.dart';
import 'package:mornye/providers/player_canvas_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/services/motion_artwork_store.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/player_artwork.dart';
import 'package:mornye/widgets/player_canvas_background.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

class _Platform extends VideoPlayerPlatform {
  final playing = <int, bool>{};
  final disposed = <int>[];
  final sources = <int, DataSource>{};
  int creations = 0;
  Size videoSize = const Size(720, 960);

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
      size: videoSize,
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
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async => disposed.add(playerId);
}

class _Settings extends SettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  AppSettings build() => value;
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}

const _item = MediaItem(
  id: 'cover',
  title: 'Song Name',
  artist: 'Main Artist',
  album: 'Album',
  duration: Duration(minutes: 3),
  extras: {
    'source': 'network://host/cover.flac',
    'resolvedSource': 'content://library/cover.flac',
  },
);

const _tall = MotionArtwork('file:///tall.mp4', aspectRatio: 0.75);
const _square = MotionArtwork('file:///square.mp4', aspectRatio: 1);
const _canvasLoop = MotionArtwork('file:///canvas.mp4');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  late StreamController<MediaItem?> mediaItems;
  late StreamController<PlaybackState> playback;
  late _Platform platform;
  late VideoPlayerPlatform previousPlatform;

  setUp(() {
    DecorativePhase.debugHoldClock = true;
    SharedPreferences.setMockInitialValues({});
    previousPlatform = VideoPlayerPlatform.instance;
    platform = _Platform();
    VideoPlayerPlatform.instance = platform;
    mediaItems = StreamController<MediaItem?>.broadcast();
    playback = StreamController<PlaybackState>.broadcast();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    messenger.setMockMethodCallHandler(backendChannel, (call) async {
      if (call.method == 'setScreenAwake') return null;
      if (call.method == 'readFileMetadata') {
        return jsonEncode({'title': 'Song Name'});
      }
      fail('Unexpected platform call: ${call.method}');
    });
  });

  tearDown(() async {
    DecorativePhase.debugHoldClock = false;
    VideoPlayerPlatform.instance = previousPlatform;
    await mediaItems.close();
    await playback.close();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(backendChannel, null);
    messenger.setMockMethodCallHandler(secureStorageChannel, null);
  });

  Future<void> settle(WidgetTester tester, [int steps = 12]) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpPlayer(
    WidgetTester tester, {
    Size size = const Size(411, 915),
    double textScale = 1,
    Future<MotionArtwork?> Function()? tall,
    Future<MotionArtwork?> Function()? square,
    Future<MotionArtwork?> Function()? canvas,
    AppSettings settings = const AppSettings(),
    bool disableAnimations = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => _Settings(settings)),
          currentMediaItemProvider.overrideWithBuild(
            (ref, notifier) => mediaItems.stream,
          ),
          playerMotionArtworkProvider.overrideWith((ref, album) async => null),
          playerAppleTallArtworkProvider.overrideWith(
            (ref, item) => (tall ?? () async => null)(),
          ),
          playerSquareCoverMotionProvider.overrideWith(
            (ref, item) => (square ?? () async => null)(),
          ),
          playerCanvasProvider.overrideWith(
            (ref, item) => (canvas ?? () async => null)(),
          ),
          playerArtworkVideoProvider.overrideWith(
            (ref, source) => Completer<VideoPlayerController>().future,
          ),
          playerCollectionTrackProvider.overrideWith(
            (ref, item) async => Track(
              id: item.id,
              name: item.title,
              artistName: item.artist ?? '',
              albumName: item.album ?? '',
              duration: 180,
              source: 'local',
            ),
          ),
          libraryCollectionsProvider.overrideWith(_Collections.new),
          playbackStateProvider.overrideWith((ref) => playback.stream),
          playQueueProvider.overrideWith((ref) => Stream.value(const [])),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        ],
        child: MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScale),
              disableAnimations: disableAnimations,
            ),
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
    playback.add(PlaybackState(playing: true));
    mediaItems.add(_item);
    await settle(tester);
  }

  final coverFrame = find.byType(PlayerArtwork);

  for (final (size, scale) in const [
    (Size(360, 640), 1.0),
    (Size(411, 915), 1.0),
    (Size(360, 640), 2.0),
    (Size(411, 915), 2.0),
  ]) {
    testWidgets('a tall loop fills the screen at $size text $scale', (
      tester,
    ) async {
      await pumpPlayer(
        tester,
        size: size,
        textScale: scale,
        tall: () async => _tall,
      );
      expect(find.byType(PlayerCanvasBackground), findsOneWidget);
      final video = tester.getRect(find.byType(PlayerCanvasBackground));
      expect(video.size, size);
      expect(coverFrame, findsNothing);
      expect(find.byKey(const ValueKey('canvas-edge-scrims')), findsOneWidget);
      final controls = tester.getRect(find.byType(PlayerPlaybackControls));
      expect(video.contains(controls.center), isTrue);
      final fit = tester.getRect(
        find.byKey(const ValueKey('canvas-video-fit-width')),
      );
      expect(fit.width, size.width);
      expect(fit.top, 0);
      expect(fit.bottom, lessThan(size.height));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('a 3:4 loop shows whole at the screen width, top aligned', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      size: const Size(411, 891),
      tall: () async => _tall,
    );
    final fit = find.byKey(const ValueKey('canvas-video-fit-width'));
    expect(fit, findsOneWidget);
    final rect = tester.getRect(fit);
    expect(rect.width, 411);
    expect(rect.top, 0);
    expect(rect.height, closeTo(411 / 0.75, 0.01));
    expect(rect.bottom, lessThan(891));
    final video = tester.getRect(find.byType(VideoPlayer));
    expect(video.width, 411);
    expect(video.left, 0);
    expect(
      find.descendant(
        of: find.byType(PlayerCanvasBackground),
        matching: find.byType(FittedBox),
      ),
      findsNothing,
    );
    expect(find.byType(CoverMimicLayer), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a loop close to the screen shape keeps covering it', (
    tester,
  ) async {
    platform.videoSize = const Size(540, 1080);
    await pumpPlayer(
      tester,
      size: const Size(411, 891),
      tall: () async => _tall,
    );
    expect(find.byKey(const ValueKey('canvas-video-fit-width')), findsNothing);
    final fitted = tester.widget<FittedBox>(
      find.descendant(
        of: find.byType(PlayerCanvasBackground),
        matching: find.byType(FittedBox),
      ),
    );
    expect(fitted.fit, BoxFit.cover);
    expect(fitted.alignment, Alignment.center);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('the scrim over the text region keeps white text readable', () {
    double channel(double v) =>
        v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4) * 1.0;
    final worstBackground = channel(1 - fullBleedScrimText);
    expect(1.05 / (worstBackground + 0.05), greaterThanOrEqualTo(4.5));
  });

  testWidgets('a Canvas goes full screen when Apple has no tall loop', (
    tester,
  ) async {
    await pumpPlayer(
      tester,
      canvas: () async => _canvasLoop,
      square: () async => _square,
    );
    expect(find.byType(PlayerCanvasBackground), findsOneWidget);
    expect(coverFrame, findsNothing);
    expect(platform.creations, 1);
    expect(platform.sources.values.single.uri, endsWith('canvas.mp4'));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a square loop stays in the cover frame', (tester) async {
    await pumpPlayer(tester, square: () async => _square);
    expect(find.byType(PlayerCanvasBackground), findsNothing);
    expect(coverFrame, findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('without a loop the complete still cover is shown', (
    tester,
  ) async {
    await pumpPlayer(tester);
    expect(find.byType(PlayerCanvasBackground), findsNothing);
    expect(coverFrame, findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the adaptive setting off keeps the frame', (tester) async {
    await pumpPlayer(
      tester,
      settings: const AppSettings(playerAdaptiveFullBleed: false),
      tall: () async => _tall,
    );
    expect(find.byType(PlayerCanvasBackground), findsNothing);
    expect(coverFrame, findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('remove animations uses the still cover', (tester) async {
    await pumpPlayer(
      tester,
      disableAnimations: true,
      tall: () async => _tall,
      canvas: () async => _canvasLoop,
    );
    expect(find.byType(PlayerCanvasBackground), findsNothing);
    expect(coverFrame, findsWidgets);
    expect(platform.creations, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the player turns full screen when the loop is ready', (
    tester,
  ) async {
    final ready = Completer<MotionArtwork?>();
    await pumpPlayer(tester, tall: () => ready.future);
    expect(find.byType(PlayerCanvasBackground), findsNothing);
    expect(coverFrame, findsWidgets);
    ready.complete(_tall);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(PlayerCanvasBackground), findsOneWidget);
    await settle(tester, 10);
    expect(coverFrame, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the loop follows playback and is released with the screen', (
    tester,
  ) async {
    await pumpPlayer(tester, tall: () async => _tall);
    expect(platform.creations, 1);
    expect(platform.playing[1], isTrue);
    playback.add(PlaybackState(playing: false));
    await settle(tester, 3);
    expect(platform.playing[1], isFalse);
    playback.add(PlaybackState(playing: true));
    await settle(tester, 3);
    expect(platform.playing[1], isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    expect(platform.disposed, contains(1));
    expect(platform.creations, 1);
  });
}
