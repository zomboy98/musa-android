import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/youtube_track_video_source.dart';

Track _track({String? source}) => Track(
  id: source == null ? 'dz:1' : '$source:99',
  name: 'BRILLO',
  artistName: 'Tito Double P',
  albumName: 'Album',
  duration: 200,
  source: source,
);

Map<String, dynamic> _row({
  String id = 'abcdefghijk',
  String name = 'BRILLO (Video Oficial)',
  String artists = 'Tito Double P',
  String itemType = 'track',
  int durationMs = 200000,
  Map<String, dynamic> extra = const {},
}) => {
  'id': id,
  'name': name,
  'artists': artists,
  'item_type': itemType,
  'duration_ms': durationMs,
  ...extra,
};

YoutubeTrackVideoSource _source(
  Map<String?, List<Map<String, dynamic>>> byFilter, {
  List<String?>? asked,
}) => YoutubeTrackVideoSource(
  isAvailable: () => true,
  networkAllowed: () async => true,
  search: (query, {filter}) async {
    asked?.add(filter);
    return byFilter[filter] ?? const [];
  },
  fetch: (track, id) async => null,
  probe: (path) async => true,
);

void main() {
  group('video offer evidence from the provider filter', () {
    test('a row of the videos filter without per-row flags is offered', () async {
      final offer = await _source({
        videosSearchFilter: [_row()],
      }).offerFor(_track());
      expect(offer?.videoId, 'abcdefghijk');
      expect(offer?.provider, youtubeVideoProviderId);
    });

    test('the same row from the unfiltered search is not offered', () async {
      expect(
        await _source({
          null: [_row()],
        }).offerFor(_track()),
        isNull,
      );
    });

    test('audio-only art tracks and collections never count', () async {
      for (final extra in <Map<String, dynamic>>[
        {'music_video_type': 'MUSIC_VIDEO_TYPE_ATV'},
        {'is_video': false},
      ]) {
        expect(
          await _source({
            videosSearchFilter: [_row(extra: extra)],
          }).offerFor(_track()),
          isNull,
        );
      }
      for (final type in ['album', 'artist', 'playlist']) {
        expect(
          await _source({
            videosSearchFilter: [_row(itemType: type)],
          }).offerFor(_track()),
          isNull,
        );
      }
    });

    test('title, artist and length must still match', () async {
      for (final row in [
        _row(name: 'Otra cancion'),
        _row(artists: 'Alguien Mas'),
        _row(durationMs: 260000),
        _row(id: 'short'),
      ]) {
        expect(
          await _source({
            videosSearchFilter: [row],
          }).offerFor(_track()),
          isNull,
        );
      }
    });

    test('asks the videos filter first and stops at the first match', () async {
      final asked = <String?>[];
      await _source({
        videosSearchFilter: [_row()],
      }, asked: asked).offerFor(_track());
      expect(asked, [videosSearchFilter]);
    });

    test('the audio provider of the track is irrelevant to the offer', () async {
      final offer = await _source({
        videosSearchFilter: [_row()],
      }).offerFor(_track(source: 'tidal'));
      expect(offer?.videoId, 'abcdefghijk');
    });
  });
}
