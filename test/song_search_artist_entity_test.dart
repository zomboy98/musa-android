import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/search_taste_profile.dart';
import 'package:mornye/services/song_search_ranking.dart';

Track song(
  String id,
  String name,
  String artist, {
  String album = '',
  String? cover,
  String? isrc,
}) => Track(
  id: id,
  name: name,
  artistName: artist,
  albumName: album,
  coverUrl: cover,
  duration: 0,
  isrc: isrc,
  source: 'prov',
);

List<String> ids(List<Track> tracks) => [for (final t in tracks) t.id];

final artistSongs = [
  song('a1', 'Suzuki', 'Fuerza Regida'),
  song('a2', 'GodFather', 'Fuerza Regida'),
  song('a3', 'ayy weyy', 'Fuerza Regida'),
  song('a4', 'OYE', 'Fuerza Regida'),
  song('a5', 'TQM', 'Fuerza Regida'),
];

final lookalikes = [
  song(
    'k1',
    'Fuerza regida',
    'KASSYRIA',
    album: 'Single',
    cover: 'https://img/k1',
  ),
  song(
    't1',
    'FUERZA REGIDA TU SANCHO',
    'TU SANCHO',
    album: 'Tributo',
    cover: 'https://img/t1',
  ),
  song('n1', 'Aunque Les Pese', 'Natanael Cano', cover: 'https://img/n1'),
];

void main() {
  const declared = ['Fuerza Regida'];

  test('declared artist songs lead the lookalike titles of other artists', () {
    final merged = mergeRankedSongs(
      [lookalikes, artistSongs],
      'fuerza regida',
      declaredArtists: declared,
    );
    expect(ids(merged).take(5), ['a1', 'a2', 'a3', 'a4', 'a5']);
    expect(ids(merged).skip(5).toList(), ['k1', 'n1', 't1']);
  });

  test('query without accents or capitals names the artist', () {
    final merged = mergeRankedSongs(
      [lookalikes, artistSongs],
      '  FUÉRZA  Regída ',
      declaredArtists: ['Fuérza Regída'],
    );
    expect(ids(merged).take(5), ['a1', 'a2', 'a3', 'a4', 'a5']);
  });

  test('a partial query names a declared artist by whole-word prefix', () {
    final merged = mergeRankedSongs(
      [lookalikes, artistSongs],
      'fuerza',
      declaredArtists: declared,
    );
    expect(ids(merged).take(5), ['a1', 'a2', 'a3', 'a4', 'a5']);
  });

  test('a pure title query keeps relevance order', () {
    final lists = [
      [
        song('o', 'Otra Cosa', 'Mira Sol'),
        song('e', 'Luna Llena', 'Ana'),
        song('p', 'Luna Llena Hoy', 'Beto'),
      ],
    ];
    expect(ids(mergeRankedSongs(lists, 'luna llena')), ['e', 'p', 'o']);
    expect(
      ids(mergeRankedSongs(lists, 'luna llena', declaredArtists: ['Ana Luna'])),
      ['e', 'p', 'o'],
    );
  });

  test('an undeclared, unweighted artist does not displace a title', () {
    final merged = mergeRankedSongs([
      [
        song('x', 'Mira Sol', 'Otro Nombre'),
        song('a1', 'Alpha', 'Mira Sol'),
      ],
    ], 'mira sol');
    expect(ids(merged), ['x', 'a1']);
  });

  test('a weighted artist wins over the same title by another artist', () {
    final songs = [
      song('x', 'Mira Sol', 'Otro Nombre'),
      song('a1', 'Alpha', 'Mira Sol'),
    ];
    final merged = mergeRankedSongs(
      [songs],
      'mira sol',
      regionalScore: (track) => track.id == 'a1' ? 3 : 0,
    );
    expect(ids(merged), ['a1', 'x']);
  });

  test('cover metadata of another artist never beats a real song', () {
    final merged = mergeRankedSongs(
      [
        [
          song(
            'full',
            'Fuerza Regida',
            'KASSYRIA',
            album: 'Fuerza Regida',
            cover: 'https://img/full',
            isrc: 'USAAA0000001',
          ),
          song('real', 'Suzuki', 'Fuerza Regida'),
        ],
      ],
      'fuerza regida',
      declaredArtists: declared,
    );
    expect(ids(merged), ['real', 'full']);
  });

  test('tribute and cover markers go below equivalent text matches', () {
    final merged = mergeRankedSongs([
      [
        song('t', 'Luna Llena (Karaoke Version)', 'Studio X'),
        song('c', 'Luna Llena', 'Cover Band', album: 'Tribute to Ana'),
        song('p', 'Luna Llena', 'Ana'),
        song('o', 'Algo', 'Beto'),
      ],
    ], 'luna llena');
    expect(ids(merged), ['p', 'o', 't', 'c']);
  });

  test('a query that asks for a cover keeps those results', () {
    final merged = mergeRankedSongs([
      [song('o', 'Algo', 'Beto'), song('c', 'Luna Llena Cover', 'X')],
    ], 'luna llena cover');
    expect(ids(merged), ['c', 'o']);
  });

  test('downloaded songs lead the artist group, then the rest by region', () {
    final downloaded = [
      artistSongs[3],
      artistSongs[4],
    ];
    final local = LocalSongSignal(downloaded);
    final merged = mergeRankedSongs(
      [lookalikes, artistSongs],
      'fuerza regida',
      declaredArtists: declared,
      regionalScore: (track) =>
          local.scoreOf(track) + (track.id == 'a2' ? 5 : 0),
    );
    expect(ids(merged).take(5), ['a4', 'a5', 'a2', 'a1', 'a3']);
    expect(ids(merged).skip(5).toSet(), {'k1', 'n1', 't1'});
  });

  test('a downloaded artist counts as weighted without a declared result', () {
    final local = LocalSongSignal([artistSongs[1]]);
    final merged = mergeRankedSongs(
      [lookalikes, artistSongs],
      'fuerza regida',
      regionalScore: local.scoreOf,
    );
    expect(ids(merged).take(5).toSet(), {'a1', 'a2', 'a3', 'a4', 'a5'});
    expect(merged.first.id, 'a2');
  });

  test('artist result named by exact or prefix name', () {
    Track artist(String name) => Track(
      id: name,
      name: name,
      artistName: name,
      albumName: '',
      duration: 0,
      itemType: 'artist',
    );
    final artists = [artist('Fuerza Aerea'), artist('Fuerza Regida')];
    expect(artistResultNamed(artists, 'fuerza regida')?.id, 'Fuerza Regida');
    expect(artistResultNamed(artists, 'Fuerza')?.id, 'Fuerza Aerea');
    expect(artistResultNamed(artists, 'regida'), isNull);
  });
}
