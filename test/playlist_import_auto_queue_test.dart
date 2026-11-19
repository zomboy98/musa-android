import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/widgets/create_playlist_sheet.dart';

void main() {
  test(
    'different provider identities remain distinct with identical metadata',
    () async {
      const a = Track(
        id: 'provider-one',
        source: 'music',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      );
      const b = Track(
        id: 'provider-two',
        source: 'music',
        name: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 180,
      );
      final queued = <Track>[];
      await queueImportedTracksOnce([
        a,
        b,
        a,
      ], (track) async => queued.add(track));
      expect(queued, [a, b]);
    },
  );
  test('different recordings with the same title are retained', () async {
    const a = Track(
      id: '1',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Original',
      duration: 180,
      isrc: 'AA1111111111',
    );
    const b = Track(
      id: '2',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Original',
      duration: 180,
      isrc: 'BB2222222222',
    );
    const c = Track(
      id: '3',
      name: 'Song',
      artistName: 'Artist',
      albumName: 'Live',
      duration: 210,
    );
    final queued = <Track>[];
    await queueImportedTracksOnce([
      a,
      b,
      c,
    ], (track) async => queued.add(track));
    expect(queued, [a, b, c]);
  });
  test(
    'automatic import queues unique remote songs and skips local files',
    () async {
      const a = Track(
        id: 'csv_1',
        name: 'A',
        artistName: 'Artist',
        albumName: '',
        duration: 0,
      );
      const b = Track(
        id: 'csv_2',
        name: 'B',
        artistName: 'Artist',
        albumName: '',
        duration: 0,
      );
      const repeatedA = Track(
        id: 'csv_3',
        name: 'A',
        artistName: 'Artist',
        albumName: '',
        duration: 0,
      );
      const local = Track(
        id: 'local',
        name: 'Local',
        artistName: 'Artist',
        albumName: '',
        duration: 0,
        source: 'local',
      );
      final queued = <Track>[];
      await queueImportedTracksOnce([
        a,
        b,
        repeatedA,
        local,
      ], (track) async => queued.add(track));
      expect(queued, [a, b]);
    },
  );
}
