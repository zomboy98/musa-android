import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/regional_song_signal.dart';
import 'package:mornye/services/search_region.dart';
import 'package:mornye/services/search_taste_profile.dart';
import 'package:mornye/services/song_search_ranking.dart';

Track song(
  String id,
  String name,
  String artist, {
  String? isrc,
  String? genre,
}) => Track(
  id: id,
  name: name,
  artistName: artist,
  albumName: '',
  duration: 0,
  isrc: isrc,
  genre: genre,
  source: 'prov',
);

List<String> ids(List<Track> tracks) => [for (final t in tracks) t.id];

void main() {
  group('title ranking', () {
    test('exact title goes above songs of the artist with that name', () {
      final artistSongs = [
        song('a1', 'Alpha Beat', 'Mira Sol'),
        song('a2', 'Beta Day', 'Mira Sol'),
      ];
      final exact = [song('x', 'MIRA SOL', 'Otro Nombre')];
      expect(ids(mergeRankedSongs([artistSongs, exact], 'mira sol')), [
        'x',
        'a1',
        'a2',
      ]);
    });

    test('accents, signs and suffixes do not break the exact match', () {
      final lists = [
        [
          song('o', 'Otra Cosa', 'Mira Sol'),
          song('s', 'Canción Única (feat. Zeta) - Remastered', 'Ana'),
          song('e', 'Canción Única (Explicit)', 'Beto'),
        ],
      ];
      final merged = mergeRankedSongs(lists, 'cancion unica!');
      expect(ids(merged), ['s', 'e', 'o']);
      expect(cleanSongTitle('Tema (feat. X) - 2011 Remaster'), 'tema');
    });

    test('tiers: exact, prefix, words, other', () {
      final merged = mergeRankedSongs([
        [
          song('other', 'Nada', 'Luz Roja'),
          song('words', 'La Luz Roja Brilla Hoy', 'A'),
          song('prefix', 'Luz Roja Noche', 'B'),
          song('exact', 'Luz Roja', 'C'),
        ],
      ], 'luz roja');
      expect(ids(merged), ['exact', 'prefix', 'words', 'other']);
    });

    test('order inside a tier is the provider order and is stable', () {
      final list = [
        for (var i = 0; i < 5; i++) song('s$i', 'Luz Roja $i', 'X$i'),
      ];
      expect(ids(mergeRankedSongs([list], 'luz roja')), ids(list));
    });

    test('duplicates by ISRC or id are merged', () {
      final merged = mergeRankedSongs([
        [song('1', 'Luz Roja', 'A', isrc: 'qm0000000001')],
        [
          song('2', 'Luz Roja', 'A', isrc: 'QM0000000001'),
          song('1', 'Otra', 'B'),
          song('3', 'Luz Roja', 'A'),
        ],
      ], 'luz roja');
      expect(ids(merged), ['1', '3', '1']);
      expect(merged.last.name, 'Otra');
    });

    test('caps the merged list', () {
      final list = [for (var i = 0; i < 80; i++) song('s$i', 'T$i', 'A')];
      expect(mergeRankedSongs([list], 'zzz').length, songSearchMergedLimit);
    });

    test('compound queries put the title by that artist first', () {
      final lists = [
        [
          song('cover', 'Luz Roja', 'Banda Falsa'),
          song('real', 'Luz Roja', 'Mira Sol'),
          song('art', 'Otro', 'Mira Sol'),
        ],
      ];
      for (final q in [
        'luz roja de mira sol',
        'luz roja - mira sol',
        'luz roja by mira sol',
        'mira sol - luz roja',
        'mira sol luz roja',
      ]) {
        expect(ids(mergeRankedSongs(lists, q)).first, 'real', reason: q);
      }
    });

    test('a title that is part of the artist name is not an artist match', () {
      final merged = mergeRankedSongs([
        [song('g', 'Sol', 'Mira Sol'), song('e', 'Mira Sol', 'Otro')],
      ], 'mira sol');
      expect(ids(merged).first, 'e');
    });
  });

  group('compound parsing and targeted queries', () {
    test('splits at the last separator', () {
      final parsed = parseCompoundSongQuery('Cartas de amor de Pepe')!;
      expect(parsed.title, 'Cartas de amor');
      expect(parsed.artist, 'Pepe');
      expect(parsed.ambiguousOrder, isFalse);
      expect(parseCompoundSongQuery('A - B')!.ambiguousOrder, isTrue);
      expect(parseCompoundSongQuery('solo titulo'), isNull);
    });

    test('only providers with the syntax get extra queries', () {
      expect(targetedSongQueries('deezer', 'Luz Roja'), ['track:"Luz Roja"']);
      expect(targetedSongQueries('deezer', 'Luz Roja de Mira Sol'), [
        'track:"Luz Roja de Mira Sol"',
        'track:"Luz Roja" Mira Sol',
      ]);
      expect(targetedSongQueries('other', 'Luz Roja'), isEmpty);
      expect(targetedSongQueries('deezer', 'https://x.test/a'), isEmpty);
      expect(targetedSongQueries('deezer', 'QM7282306246'), isEmpty);
      expect(targetedSongQueries('deezer', 'track:"a"'), isEmpty);
    });
  });

  group('regional tie-break', () {
    final signal = RegionalSongSignal([
      RegionalRanking(1.0, [
        (isrc: null, title: 'Luz Roja Dos', artist: 'Beta'),
      ]),
      RegionalRanking(0.6, [
        (isrc: 'QM1', title: 'Luz Roja Tres', artist: 'Gamma'),
        (isrc: null, title: 'Luz Roja Uno', artist: 'Alfa'),
      ]),
    ]);

    test('reorders only inside the same tier', () {
      final merged = mergeRankedSongs(
        [
          [
            song('1', 'Luz Roja Uno', 'Alfa'),
            song('2', 'Luz Roja Dos', 'Beta'),
            song('exact', 'Luz Roja', 'Delta'),
            song('4', 'Nada', 'Epsilon'),
          ],
        ],
        'luz roja',
        regionalScore: signal.scoreOf,
      );
      expect(ids(merged), ['exact', '2', '1', '4']);
    });

    test('a song that does not match the text is never raised', () {
      final merged = mergeRankedSongs(
        [
          [song('t', 'Luz Roja Uno', 'Alfa'), song('x', 'Nada', 'Alfa')],
        ],
        'luz roja',
        regionalScore: (track) => track.id == 'x' ? 99 : 0,
      );
      expect(ids(merged), ['t', 'x']);
    });

    test('neighbors weigh less than the region; ISRC pairs first', () {
      final a = signal.scoreOf(song('a', 'Luz Roja Dos', 'Beta'));
      final b = signal.scoreOf(song('b', 'zz', 'Gamma', isrc: 'qm1'));
      expect(a, 1.0);
      expect(b, closeTo(0.6, 1e-9));
      expect(signal.scoreOf(song('c', 'Desconocida', 'Nadie')), 0);
    });

    test('without signal the order is the provider order', () {
      final list = [song('1', 'Luz A', 'x'), song('2', 'Luz B', 'y')];
      expect(ids(mergeRankedSongs([list], 'luz', regionalScore: (_) => 0)), [
        '1',
        '2',
      ]);
    });
  });

  group('taste profile', () {
    test('empty profile scores zero and keeps the order', () {
      final profile = SearchTasteProfile();
      expect(profile.isEmpty, isTrue);
      expect(profile.scoreOf(song('1', 'Luz', 'Mira Sol')), 0);
    });

    test('a followed artist rises inside its tier only', () {
      final profile = SearchTasteProfile(followedArtists: ['Mira Sol']);
      final merged = mergeRankedSongs(
        [
          [
            song('a', 'Luz Roja Uno', 'Otro'),
            song('b', 'Luz Roja Dos', 'Mira Sol'),
            song('exact', 'Luz Roja', 'Nadie'),
            song('c', 'Zzz', 'Mira Sol'),
          ],
        ],
        'luz roja',
        regionalScore: profile.scoreOf,
      );
      expect(ids(merged), ['exact', 'b', 'a', 'c']);
      expect(merged.length, 4);
    });

    test('played artists score by listening time; genres by exact match', () {
      final profile = SearchTasteProfile(
        playedMilliseconds: {'Mucho': 1000, 'Poco': 100},
        genres: ['Cumbia'],
      );
      expect(
        profile.scoreOf(song('1', 't', 'Mucho')),
        searchTastePlayedMaxPoints,
      );
      expect(profile.scoreOf(song('2', 't', 'Poco')), closeTo(0.15, 1e-9));
      expect(
        profile.scoreOf(song('3', 't', 'Otro', genre: 'cumbia')),
        searchTasteGenrePoints,
      );
    });
  });

  group('region table', () {
    test('resolution and weights', () {
      expect(resolveSearchRegion('none'), isNull);
      expect(resolveSearchRegion('auto', deviceCountry: 'MX'), 'mx');
      expect(resolveSearchRegion('auto'), 'us');
      expect(resolveSearchRegion('ca'), 'ca');
      expect(resolveSearchRegion('xx', deviceCountry: 'ca'), 'ca');
      expect(searchRegionWeights('us'), [
        (code: 'us', weight: 1.0),
        (code: 'ca', weight: 0.6),
        (code: 'mx', weight: 0.6),
      ]);
      expect(searchRegionWeights('mx').length, 3);
      expect(searchRegionWeights('zz'), [(code: 'zz', weight: 1.0)]);
    });

    test('a country is never its own neighbor', () {
      searchRegionNeighbors.forEach((code, list) {
        expect(list.contains(code), isFalse);
      });
    });
  });

  group('regional cache and failures', () {
    test('caches per query and country for ten minutes', () async {
      var now = DateTime(2030);
      final cache = RegionalRankingCache(now: () => now);
      var calls = 0;
      Future<List<RegionalRankRow>> fetch(String country) async {
        calls++;
        return [(isrc: null, title: 'Luz', artist: country)];
      }

      await buildRegionalSignal(
        query: 'Luz',
        region: 'us',
        fetch: fetch,
        cache: cache,
      );
      expect(calls, 3);
      await buildRegionalSignal(
        query: ' luz ',
        region: 'us',
        fetch: fetch,
        cache: cache,
      );
      expect(calls, 3);
      now = now.add(const Duration(minutes: 11));
      await buildRegionalSignal(
        query: 'Luz',
        region: 'us',
        fetch: fetch,
        cache: cache,
      );
      expect(calls, 6);
    });

    test('a failing country is skipped without error', () async {
      final signal = await buildRegionalSignal(
        query: 'Luz',
        region: 'us',
        cache: RegionalRankingCache(),
        fetch: (country) async {
          if (country == 'us') throw StateError('boom');
          return [(isrc: null, title: 'Luz', artist: 'Ana')];
        },
      );
      expect(signal.scoreOf(song('1', 'Luz', 'Ana')), closeTo(0.6 * 2, 1e-9));
    });
  });

  test('no artist or genre names are reserved in the code', () {
    final banned = [
      'peso pluma',
      'regional mexic',
      'corridos',
      'lady gaga',
      'bad bunny',
    ];
    const skipped = [
      'lib/l10n',
      'lib/utils/genre_normalizer.dart',
      'lib/services/library_mixes.dart',
    ];
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is! File) continue;
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || skipped.any(path.startsWith)) continue;
      final text = file.readAsStringSync().toLowerCase();
      for (final word in banned) {
        if (text.contains(word)) offenders.add('$path: $word');
      }
    }
    expect(offenders, isEmpty);
  });
}
