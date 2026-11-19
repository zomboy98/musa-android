import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/widgets/import_tracks_collage.dart';

Track _track(String id, String? cover) => Track(
  id: id,
  name: id,
  artistName: 'A',
  albumName: 'B',
  duration: 1,
  coverUrl: cover,
);

void main() {
  test('portadas unicas, validas y con tope', () {
    final tracks = [
      _track('1', 'https://x/a.jpg'),
      _track('2', 'https://x/a.jpg'),
      _track('3', null),
      _track('4', 'file:///b.jpg'),
      for (var i = 0; i < 12; i++) _track('t$i', 'https://x/$i.jpg'),
    ];
    final urls = importCoverUrls(tracks);
    expect(urls.length, 9);
    expect(urls.first, 'https://x/a.jpg');
    expect(urls.toSet().length, 9);
  });

  test('titulo solo emojis usa el respaldo', () {
    expect(importDisplayName('🔥🎵', 'Lista importada'), 'Lista importada');
    expect(importDisplayName('Hits 🔥', 'Lista importada'), 'Hits 🔥');
    expect(importDisplayName('  ', 'Lista importada'), 'Lista importada');
  });
}
