import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_metadata.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/models/track.dart';

void main() {
  test(
    'catalog Track tags survive playable queue, serialization and file probe',
    () {
      const track = Track(
        id: 'catalog-id',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
        source: 'catalog-provider',
        composer: 'Real composer',
        genre: 'Rock',
        label: 'Real label',
        copyright: '2026 Owner',
        isrc: 'TEST00000001',
        releaseDate: '2026-01-02',
        albumArtist: 'Album Artist',
        trackNumber: 3,
        discNumber: 1,
        previewUrl: 'https://example.test/private?token=secret',
        comment: 'private note',
      );
      final playable = playableFromCatalogTrack(track);
      final restored = PlayableMedia.fromJson(playable.toJson())!;
      final item = restored.toMediaItem(resolvedSource: '/cache/audio.m4a');
      final tags = playbackAudioMetadataFromMediaItem(item);
      expect(item.extras?['source'], playable.source);
      expect(item.extras?['resolvedSource'], '/cache/audio.m4a');
      expect(tags, {
        'composer': 'Real composer',
        'genre': 'Rock',
        'label': 'Real label',
        'copyright': '2026 Owner',
        'isrc': 'TEST00000001',
        'date': '2026-01-02',
        'album_artist': 'Album Artist',
        'track_number': 3,
        'disc_number': 1,
      });
      expect(tags.values, isNot(contains('private note')));
      expect(tags.toString(), isNot(contains('secret')));
      final merged = mergePlaybackFileMetadata(tags, {
        'composer': '',
        'label': null,
        'copyright': 'New verified owner',
        'lyrics': '',
      });
      expect(merged['composer'], '');
      expect(merged['label'], isNull);
      expect(merged['copyright'], 'New verified owner');
      expect(mergePlaybackFileMetadata(tags, {})['composer'], 'Real composer');
      expect(
        playableFromTrack(track, 'network://music/song').displayMetadata,
        tags,
      );
      final empty = playableFromTrack(
        const Track(
          id: 'empty',
          name: '',
          artistName: '',
          albumName: '',
          duration: 0,
          composer: '  ',
        ),
        '/music/empty',
      );
      expect(empty.displayMetadata, isEmpty);
    },
  );
  test('display metadata preserves bounded verified credit fields', () {
    final result = playbackDisplayMetadata({
      'lyricist': 'Writer',
      'composer': 'Composer',
      'lyrics_provider': 'Provider',
      'label': 'Label',
      'source': '/private/audio.flac',
    });
    expect(result, {
      'lyricist': 'Writer',
      'composer': 'Composer',
      'lyrics_provider': 'Provider',
      'label': 'Label',
    });
    expect(playbackDisplayMetadata({'lyricist': 'x' * 4097}), isEmpty);
  });
}
