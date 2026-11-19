import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/video_network_policy.dart';
import 'package:mornye/services/youtube_track_video_source.dart';

Track _track({int duration = 200}) => Track(
  id: 'dz:1',
  name: 'Song Name',
  artistName: 'The Artist, Guest',
  albumName: 'Album',
  duration: duration,
);

Map<String, dynamic> _item({
  String id = 'abcdefghijk',
  String name = 'Song Name (Official Video)',
  String artists = 'The Artist',
  Object? kind = 'MUSIC_VIDEO_TYPE_OMV',
  int durationMs = 201000,
}) => {
  'id': id,
  'name': name,
  'artists': artists,
  'duration_ms': durationMs,
  'music_video_type': ?kind,
};

YoutubeTrackVideoSource _source({
  List<Map<String, dynamic>> results = const [],
  bool available = true,
  bool network = true,
  Future<String?> Function(Track, String)? fetch,
  bool probes = true,
  List<String?>? filters,
}) => YoutubeTrackVideoSource(
  isAvailable: () => available,
  networkAllowed: () async => network,
  search: (query, {filter}) async {
    filters?.add(filter);
    return results;
  },
  fetch: fetch ?? (track, id) async => '/tmp/$id.mp4',
  probe: (path) async => probes,
);

void main() {
  group('offerFor', () {
    test('offers a matching music video from the extension', () async {
      final offer = await _source(results: [_item()]).offerFor(_track());
      expect(offer?.videoId, 'abcdefghijk');
      expect(offer?.provider, youtubeVideoProviderId);
    });

    test(
      'never offers audio-only art tracks or items without evidence',
      () async {
        expect(
          await _source(
            results: [_item(kind: 'MUSIC_VIDEO_TYPE_ATV')],
          ).offerFor(_track()),
          isNull,
        );
        final unfiltered = YoutubeTrackVideoSource(
          isAvailable: () => true,
          networkAllowed: () async => true,
          search: (query, {filter}) async =>
              filter == null ? [_item(kind: null)] : const [],
          fetch: (track, id) async => null,
          probe: (path) async => true,
        );
        expect(await unfiltered.offerFor(_track()), isNull);
      },
    );

    test('rejects other songs, other artists and different lengths', () async {
      expect(
        await _source(results: [_item(name: 'Other')]).offerFor(_track()),
        isNull,
      );
      expect(
        await _source(
          results: [_item(artists: 'Someone Else')],
        ).offerFor(_track()),
        isNull,
      );
      expect(
        await _source(results: [_item(durationMs: 240000)]).offerFor(_track()),
        isNull,
      );
    });

    test('does not ask when unavailable or without allowed network', () async {
      final filters = <String?>[];
      expect(
        await _source(
          results: [_item()],
          available: false,
          filters: filters,
        ).offerFor(_track()),
        isNull,
      );
      expect(
        await _source(
          results: [_item()],
          network: false,
          filters: filters,
        ).offerFor(_track()),
        isNull,
      );
      expect(filters, isEmpty);
    });

    test(
      'tries the video filter first and then an unfiltered search',
      () async {
        final filters = <String?>[];
        await _source(filters: filters).offerFor(_track());
        expect(filters, ['videos', null]);
      },
    );

    test('a failing search offers nothing', () async {
      final source = YoutubeTrackVideoSource(
        isAvailable: () => true,
        networkAllowed: () async => true,
        search: (query, {filter}) async => throw StateError('down'),
        fetch: (track, id) async => null,
        probe: (path) async => true,
      );
      expect(await source.offerFor(_track()), isNull);
    });
  });

  group('prepare', () {
    const offer = TrackVideoOffer(
      provider: youtubeVideoProviderId,
      videoId: 'abcdefghijk',
    );

    test('returns the fetched file when it holds real video', () async {
      expect(await _source().prepare(_track(), offer), '/tmp/abcdefghijk.mp4');
    });

    test('returns null when the file has no moving video', () async {
      expect(await _source(probes: false).prepare(_track(), offer), isNull);
    });

    test('returns null when nothing could be fetched', () async {
      expect(
        await _source(fetch: (t, i) async => null).prepare(_track(), offer),
        isNull,
      );
    });

    test('asks for Wi-Fi instead of using mobile data', () async {
      await expectLater(
        _source(network: false).prepare(_track(), offer),
        throwsA(isA<TrackVideoNeedsNetwork>()),
      );
    });

    test('refuses an id that is not a video id', () async {
      expect(
        await _source().prepare(
          _track(),
          const TrackVideoOffer(provider: 'x', videoId: 'short'),
        ),
        isNull,
      );
    });
  });

  group('videoNetworkAllowed', () {
    Future<bool> run(List<ConnectivityResult> results, bool mobile) =>
        videoNetworkAllowed(
          allowMobileData: mobile,
          check: () async => results,
        );

    test('wifi and ethernet are always allowed', () async {
      expect(await run([ConnectivityResult.wifi], false), isTrue);
      expect(await run([ConnectivityResult.ethernet], false), isTrue);
    });

    test('mobile data needs the setting', () async {
      expect(await run([ConnectivityResult.mobile], false), isFalse);
      expect(await run([ConnectivityResult.mobile], true), isTrue);
    });

    test('no link or an unreadable state never allows', () async {
      expect(await run([ConnectivityResult.none], true), isFalse);
      expect(await run([], true), isFalse);
      expect(
        await videoNetworkAllowed(
          allowMobileData: true,
          check: () async => throw StateError('x'),
        ),
        isFalse,
      );
    });
  });
}
