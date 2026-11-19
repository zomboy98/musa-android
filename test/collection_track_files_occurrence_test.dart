import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/collection_track_files_provider.dart';
import 'package:mornye/providers/playback_provider.dart';

const track = Track(
  id: 'a',
  name: 'A',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 1,
);
const missing = Track(
  id: 'missing',
  name: 'Missing',
  artistName: 'Artist',
  albumName: 'Album',
  duration: 1,
);

class FakePlayback extends PlaybackController {
  @override
  PlaybackState build() => PlaybackState();

  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async =>
      tracks.map((t) => t.id == 'missing' ? null : '/music/a.mp3').toList();
}

void main() {
  test(
    'resolution retains duplicate occurrence across missing paths and contexts',
    () async {
      final container = ProviderContainer(
        overrides: [playbackProvider.overrideWith(FakePlayback.new)],
      );
      addTearDown(container.dispose);
      final request = CollectionTrackFilesRequest(
        [track, missing, track],
        listContext: 'ownPlaylist:one',
        listOccurrences: ['first', 'missing', 'second'],
      );
      final subscription = container.listen(
        collectionTrackFilesProvider(request),
        (_, __) {},
      );
      addTearDown(subscription.close);
      final media = await container.read(
        collectionTrackFilesProvider(request).future,
      );
      expect(media.map((m) => m.listOccurrence), ['first', 'second']);
      expect(media.map((m) => m.listContext), [
        'ownPlaylist:one',
        'ownPlaylist:one',
      ]);
      expect(media.last.toMediaItem().extras?['listOccurrence'], 'second');
      expect(
        request,
        isNot(
          CollectionTrackFilesRequest(
            [track, missing, track],
            listContext: 'ownPlaylist:two',
            listOccurrences: ['first', 'missing', 'second'],
          ),
        ),
      );
      expect(
        request,
        isNot(
          CollectionTrackFilesRequest(
            [track, missing, track],
            listContext: 'ownPlaylist:one',
            listOccurrences: ['second', 'missing', 'first'],
          ),
        ),
      );
    },
  );
}
