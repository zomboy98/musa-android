import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/cupertino.dart';
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
import 'package:mornye/widgets/overflow_marquee.dart';
import 'package:mornye/widgets/player_volume_control.dart';
import 'package:mornye/widgets/player_track_line.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'support/app_icon_finder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const backendChannel = MethodChannel('com.zarz.mornye/backend');
  const secureStorageChannel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );
  const longTitle = 'No Te Detengas (Remasterizado)';
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

  testWidgets('a long title in the compact header stays on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
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
          playbackStateProvider.overrideWith((ref) => const Stream.empty()),
          playQueueProvider.overrideWith((ref) => Stream.value(const [])),
          systemVolumeProvider.overrideWith((ref) => Stream.value(0.5)),
        ],
        child: MaterialApp(
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
        id: 'long',
        title: longTitle,
        artist: 'Artist',
        album: 'Album',
        duration: Duration(minutes: 3),
        extras: {'source': 'content://library/long.flac'},
      ),
    );
    await settle(tester);
    Finder line() => find.byType(PlayerTrackLine);
    Text lineText() => tester.widget<Text>(
      find.descendant(of: line(), matching: find.byType(Text)).first,
    );
    Text subtitleText() => tester.widget<Text>(
      find.descendant(of: line(), matching: find.byType(Text)).last,
    );
    expect(line(), findsOneWidget);
    expect(lineText().maxLines, 1);
    expect(lineText().data, contains('No Te Detengas'));
    expect(subtitleText().data, contains('Album'));
    expect(subtitleText().data, contains('Artist'));
    expect(
      find.descendant(of: line(), matching: find.byType(OverflowMarquee)),
      findsOneWidget,
    );
    final fullHeight = tester.getSize(line()).height;

    await tester.tap(findAppIcon(CupertinoIcons.quote_bubble));
    await settle(tester);
    expect(line(), findsOneWidget);
    expect(lineText().maxLines, 1);
    expect(tester.getSize(line()).height, fullHeight);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _Collections extends LibraryCollectionsNotifier {
  @override
  LibraryCollectionsState build() => LibraryCollectionsState(isLoaded: true);
}
