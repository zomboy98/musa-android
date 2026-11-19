import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/local_playback.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/track.dart';

void main() {
  const track = Track(
    id: 'shared-id', name: 'Song', artistName: 'Artist', albumName: '',
    duration: 200, source: 'provider-a', isrc: 'USABC1234567',
  );
  DownloadHistoryItem history({String? isrc, String title = 'Song', String artist = 'Artist'}) =>
      DownloadHistoryItem(
        id: 'history', spotifyId: 'shared-id', trackName: title,
        artistName: artist, albumName: '', filePath: '/song',
        service: 'provider-b', downloadedAt: DateTime(2024), isrc: isrc,
      );

  test('rejects a foreign catalog ID collision', () {
    expect(historyMatchesTrack(track, history(isrc: 'USXYZ7654321', title: 'Other')), isFalse);
    expect(historyMatchesTrack(track, history(title: 'Other')), isFalse);
  });

  test('accepts matching ISRC or matching legacy metadata', () {
    expect(historyMatchesTrack(track, history(isrc: ' usabc1234567 ', title: 'Different title')), isTrue);
    expect(historyMatchesTrack(track, history(title: ' song ', artist: 'ARTIST')), isTrue);
  });

  test('rejects conflicting ISRC even when title and artist match', () {
    expect(historyMatchesTrack(track, history(isrc: 'USXYZ7654321')), isFalse);
  });

  test('history lookup skips a conflicting ID and selects the ISRC match', () async {
    final collision = history(isrc: 'USXYZ7654321', title: 'Other');
    final correct = history(isrc: 'USABC1234567');
    var nameLookups = 0;
    final selected = await findMatchingHistory(
      track,
      byId: (_) async => collision,
      byIsrc: (_) async => correct,
      byName: (_, _) async { nameLookups++; return null; },
    );
    expect(selected, same(correct));
    expect(nameLookups, 0);
  });

  test('history lookup returns no candidate for a collision alone', () async {
    final collision = history(isrc: 'USXYZ7654321');
    final selected = await findMatchingHistory(
      track,
      byId: (_) async => collision,
      byIsrc: (_) async => null,
      byName: (_, _) async => collision,
    );
    expect(selected, isNull);
  });
}
