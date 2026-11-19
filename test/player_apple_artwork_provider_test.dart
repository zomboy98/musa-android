import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/player_apple_artwork_provider.dart';
import 'package:mornye/providers/player_canvas_provider.dart';
import 'package:mornye/providers/player_motion_artwork_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/apple_animated_artwork.dart';
import 'package:mornye/services/motion_artwork_store.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.value);
  final AppSettings value;
  @override
  AppSettings build() => value;
}

const _item = MediaItem(
  id: 'song-1',
  title: 'Song Name',
  artist: 'Main Artist',
  album: 'Album Name',
);

const _track = Track(
  id: 'song-1',
  name: 'Song Name',
  artistName: 'Main Artist',
  albumName: 'Album Name',
  duration: 200,
);

Map<String, dynamic> _found() => {
  'success': true,
  'type': 'animated_artwork',
  'id': '1001',
  'editorial_video': {
    'motionSquareVideo1x1': {'video': 'https://video.example.test/a.m3u8'},
  },
};

Future<MotionArtwork?> load(
  ProviderContainer c,
  FutureProvider<MotionArtwork?> provider,
) {
  c.listen(provider, (_, _) {});
  return c.read(provider.future);
}

void main() {
  late Directory root;
  late List<String> lookups;
  late List<String> downloads;
  late Map<String, dynamic>? response;
  late bool downloadWorks;
  late List<ConnectivityResult> network;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('apple-animated-');
    lookups = [];
    downloads = [];
    response = _found();
    downloadWorks = true;
    network = [ConnectivityResult.wifi];
  });
  tearDown(() => root.delete(recursive: true));

  ProviderContainer container({AppSettings settings = const AppSettings()}) {
    final store = MotionArtworkStore(
      directory: () async => root,
      validate: (_) async => true,
      download: (source, output) async {
        downloads.add(source);
        if (!downloadWorks) return null;
        await File(output).writeAsBytes([1]);
        return 1.0;
      },
    );
    final lookup = AppleAnimatedArtworkLookup(
      handleUrl: (url) async {
        lookups.add(url);
        return response;
      },
      directory: () async => root,
      log: (_) {},
      retryDelays: const [],
    );
    final result = ProviderContainer(
      overrides: [
        settingsProvider.overrideWith(() => _Settings(settings)),
        playerCollectionTrackProvider.overrideWith((ref, item) async => _track),
        motionArtworkStoreProvider.overrideWithValue(store),
        appleAnimatedArtworkLookupProvider.overrideWithValue(lookup),
        canvasConnectivityProvider.overrideWithValue(() async => network),
      ],
    );
    addTearDown(result.dispose);
    return result;
  }

  test('a found loop is saved once and reused from the store', () async {
    final c = container();
    final artwork = await load(c, playerAppleAnimatedArtworkProvider(_item));
    expect(artwork, isNotNull);
    expect(artwork!.source, startsWith('file:'));
    expect(artwork.aspectRatio, 1.0);
    expect(downloads, ['https://video.example.test/a.m3u8']);
    c.invalidate(playerAppleAnimatedArtworkProvider(_item));
    await load(c, playerAppleAnimatedArtworkProvider(_item));
    expect(lookups, hasLength(1));
    expect(downloads, hasLength(1));
  });

  test('without a loop the still cover stays, with no download', () async {
    response = {'success': true, 'type': 'animated_artwork', 'id': '1001'};
    final c = container();
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    expect(downloads, isEmpty);
  });

  test('a failed lookup is retried later instead of kept as absence', () async {
    response = null;
    final c = container();
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    response = _found();
    c.invalidate(playerAppleAnimatedArtworkProvider(_item));
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    expect(lookups, hasLength(1), reason: 'the failure is held for minutes');
    expect(downloads, isEmpty);
  });

  test('a failed save is not retried on every open', () async {
    downloadWorks = false;
    final c = container();
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    c.invalidate(playerAppleAnimatedArtworkProvider(_item));
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    expect(downloads, hasLength(1));
  });

  test('mobile data is only used when allowed', () async {
    network = [ConnectivityResult.mobile];
    var c = container();
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    expect(lookups, isEmpty);
    c = container(settings: const AppSettings(canvasMobileDataEnabled: true));
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNotNull);
  });

  test('a saved loop plays offline without any lookup', () async {
    await load(container(), playerAppleAnimatedArtworkProvider(_item));
    lookups.clear();
    network = [ConnectivityResult.none];
    final c = container();
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNotNull);
    expect(lookups, isEmpty);
  });

  test('the setting turns the feature off', () async {
    final c = container(
      settings: const AppSettings(motionArtworkEnabled: false),
    );
    expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
    expect(await load(c, playerCoverMotionProvider(_item)), isNull);
    expect(lookups, isEmpty);
  });

  test('a loop saved with the album wins over the Apple lookup', () async {
    final c = container();
    final stored = await c.read(motionArtworkStoreProvider).save((
      album: 'Album Name',
      artist: 'Main Artist',
    ), resolveSource: () async => 'https://video.example.test/own.mp4');
    final cover = await load(c, playerCoverMotionProvider(_item));
    expect(cover?.source, stored?.source);
    expect(lookups, isEmpty);
  });

  group('tall and square loops', () {
    Map<String, dynamic> both() => {
      'success': true,
      'type': 'animated_artwork',
      'id': '1001',
      'editorial_video': {
        'motionSquareVideo1x1': {'video': 'https://video.example.test/sq.m3u8'},
        'motionTallVideo3x4': {'video': 'https://video.example.test/tall.m3u8'},
      },
    };

    test('only the tall loop is downloaded while it can be used', () async {
      response = both();
      final c = container();
      final tall = await load(c, playerAppleTallArtworkProvider(_item));
      expect(tall, isNotNull);
      final square = await load(c, playerAppleAnimatedArtworkProvider(_item));
      expect(square, isNull);
      expect(downloads, ['https://video.example.test/tall.m3u8']);
      expect(lookups, hasLength(1));
      final cover = await load(c, playerCoverMotionProvider(_item));
      expect(cover?.source, tall!.source);
    });

    test('the square loop is the fallback when the tall one fails', () async {
      response = both();
      downloadWorks = false;
      final c = container();
      expect(await load(c, playerAppleTallArtworkProvider(_item)), isNull);
      downloadWorks = true;
      final square = await load(c, playerAppleAnimatedArtworkProvider(_item));
      expect(square, isNotNull);
      expect(downloads, [
        'https://video.example.test/tall.m3u8',
        'https://video.example.test/sq.m3u8',
      ]);
    });

    test('a tall-only album leaves the square slot empty', () async {
      response = {
        'success': true,
        'type': 'animated_artwork',
        'id': '1001',
        'editorial_video': {
          'motionDetailTall': {'video': 'https://video.example.test/t.m3u8'},
        },
      };
      final c = container();
      expect(await load(c, playerAppleTallArtworkProvider(_item)), isNotNull);
      expect(await load(c, playerAppleAnimatedArtworkProvider(_item)), isNull);
      expect(downloads, ['https://video.example.test/t.m3u8']);
    });

    test(
      'with the adaptive setting off only the square loop is used',
      () async {
        response = both();
        final c = container(
          settings: const AppSettings(playerAdaptiveFullBleed: false),
        );
        expect(await load(c, playerAppleTallArtworkProvider(_item)), isNull);
        expect(
          await load(c, playerAppleAnimatedArtworkProvider(_item)),
          isNotNull,
        );
        expect(downloads, ['https://video.example.test/sq.m3u8']);
      },
    );

    test('with the adaptive setting off a tall-only loop is cropped', () async {
      response = {
        'success': true,
        'type': 'animated_artwork',
        'id': '1001',
        'editorial_video': {
          'motionDetailTall': {'video': 'https://video.example.test/t.m3u8'},
        },
      };
      final c = container(
        settings: const AppSettings(playerAdaptiveFullBleed: false),
      );
      expect(
        await load(c, playerAppleAnimatedArtworkProvider(_item)),
        isNotNull,
      );
    });

    test('mobile data without permission downloads nothing', () async {
      response = both();
      network = [ConnectivityResult.mobile];
      final c = container();
      expect(await load(c, playerAppleTallArtworkProvider(_item)), isNull);
      expect(downloads, isEmpty);
    });
  });
}
