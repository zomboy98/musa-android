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
import 'package:mornye/screens/now_playing_screen.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/decorative_phase.dart';
import 'package:mornye/widgets/player_playback_controls.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const longTitle = 'OLIVIA LA FLAKA';
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
      if (call.method == 'readFileMetadata') {
        return jsonEncode({'title': longTitle});
      }
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
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<double> coverWidth(
    WidgetTester tester, {
    required Size size,
    required bool playing,
    double pixelRatio = 1,
    double textScale = 1,
    bool network = true,
  }) async {
    tester.view.physicalSize = size * pixelRatio;
    tester.view.devicePixelRatio = pixelRatio;
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
            (ref) => Stream.value(PlaybackState(playing: playing)),
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
      const MediaItem(
        id: 'cover',
        title: longTitle,
        artist: 'Natanael Cano, Tito Double P, Peso Pluma',
        album: 'Album',
        duration: Duration(minutes: 3),
        extras: {
          'source': 'network://host/cover.flac',
          'resolvedSource': 'content://library/cover.flac',
        },
      ),
    );
    await settle(tester);
    final cover = tester.getRect(
      find.byKey(const ValueKey('full-player-artwork')).first,
    );
    final header = tester.getRect(
      find.byKey(const ValueKey('player-track-header')),
    );
    final controls = tester.getRect(find.byType(PlayerPlaybackControls));
    expect(cover.height, closeTo(cover.width, 0.5));
    expect(cover.bottom, lessThanOrEqualTo(header.top + 0.5));
    expect(header.bottom, lessThanOrEqualTo(controls.top + 0.5));
    expect(find.text('Reproduciendo desde este dispositivo'), findsNothing);
    expect(
      find.bySemanticsLabel('Reproduciendo desde este dispositivo'),
      findsNothing,
    );
    final width = cover.width;
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    return width;
  }

  for (final size in const [
    Size(360, 800),
    Size(393, 852),
    Size(412, 842),
    Size(412, 915),
  ]) {
    for (final pixelRatio in const [1.0, 2.6]) {
      for (final textScale in const [1.0, 1.3]) {
        testWidgets(
          'the cover stays large at $size dpr $pixelRatio text $textScale',
          (tester) async {
            final playing = await coverWidth(
              tester,
              size: size,
              playing: true,
              pixelRatio: pixelRatio,
              textScale: textScale,
            );
            final paused = await coverWidth(
              tester,
              size: size,
              playing: false,
              pixelRatio: pixelRatio,
              textScale: textScale,
            );
            expect(playing, greaterThanOrEqualTo(size.width * 0.92));
            expect(paused, greaterThan(size.width * 0.88));
            expect(paused, greaterThanOrEqualTo(playing * 0.95));
          },
        );
      }
    }
  }

  for (final size in const [Size(360, 640), Size(320, 568), Size(411, 915)]) {
    for (final textScale in const [1.0, 2.0]) {
      testWidgets('the cover frame is square at $size text $textScale', (
        tester,
      ) async {
        final playing = await coverWidth(
          tester,
          size: size,
          playing: true,
          textScale: textScale,
        );
        final paused = await coverWidth(
          tester,
          size: size,
          playing: false,
          textScale: textScale,
        );
        expect(playing, lessThanOrEqualTo(size.width));
        expect(paused, lessThanOrEqualTo(size.width));
      });
    }
  }
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}
