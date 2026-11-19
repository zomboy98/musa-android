import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  test('temporary catalog media identifies its catalog track', () {
    final track = Track(
      id: '123',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 120,
    );
    final media = playableFromCatalogTrack(track);
    final decoded = PlayableMedia.fromJson({
      'id': media.id,
      'source': media.source,
    });
    final identity = CurrentTrackIdentity.of(
      mediaId: media.id,
      catalogTrack: decoded?.catalogTrack,
    );
    expect(identity.matches(catalogTrackKey(track)), isTrue);
    final different = Track(
      id: '123',
      name: 'Other',
      artistName: 'Artist',
      albumName: 'Album',
      duration: 120,
    );
    expect(identity.matches(catalogTrackKey(different)), isFalse);
  });
}
