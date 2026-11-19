import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/providers/library_mixes_provider.dart';
import 'package:mornye/services/library_mixes.dart';
import 'package:mornye/services/playable_media.dart';

void main() {
  test('preferred keys include kind and genre aliases match actual tags', () {
    final mixes = buildLibraryMixes(
      LibraryMixRequest(
        at: DateTime(2026),
        songs: [
          PlayableMedia(
            id: 'local_1',
            source: '/1',
            title: '1',
            artist: 'Latin',
            album: '',
            genre: 'Latina',
          ),
          PlayableMedia(
            id: 'local_2',
            source: '/2',
            title: '2',
            artist: 'Other',
            album: '',
            genre: 'Electrónica',
          ),
          PlayableMedia(
            id: 'local_3',
            source: '/3',
            title: '3',
            artist: 'Other',
            album: '',
            genre: 'Clásica',
          ),
        ],
        preferredArtists: ['Latin'],
        preferredGenres: ['Latin', 'Electronic', 'Classical'],
        exists: (_) => true,
      ),
    );
    expect(mixes.map((mix) => mix.key).toSet(), {
      'preferred:artist:latin',
      'preferred:genre:latin',
      'preferred:genre:electronic',
      'preferred:genre:classical',
    });
    expect(mixes.map((mix) => mix.songIds), [
      ['local_1'],
      ['local_1'],
      ['local_2'],
      ['local_3'],
    ]);
  });
  test('invalid preferences are ignored safely', () {
    expect(decodeMixPreferences('{').artists, isEmpty);
    final parsed = decodeMixPreferences(
      '{"artists":[" Björk ",42],"genres":false}',
    );
    expect(parsed.artists, [' Björk ']);
    expect(parsed.genres, isEmpty);
  });

  test('small libraries match genre families and skip missing files', () {
    PlayableMedia song(String id, String artist, String? genre) =>
        PlayableMedia(
          id: 'local_$id',
          source: '/$id',
          title: id,
          artist: artist,
          album: '',
          genre: genre,
        );
    final mixes = buildLibraryMixes(
      LibraryMixRequest(
        at: DateTime(2026),
        songs: [
          song('1', 'Björk', 'Rock'),
          song('2', 'Björk tribute', 'Hard Rock'),
          song('3', 'Björk', null),
          song('4', 'Other', 'Rock'),
        ],
        preferredArtists: [' björk '],
        preferredGenres: ['rock'],
        exists: (source) => source != '/3',
      ),
    );
    expect(mixes.map((m) => m.songIds), [
      ['local_1'],
      ['local_1', 'local_2', 'local_4'],
    ]);
    expect(mixes.every((m) => m.key.startsWith('preferred:')), isTrue);
    expect(
      buildLibraryMixes(
        LibraryMixRequest(
          at: DateTime(2026),
          songs: [song('1', 'Other', null)],
          preferredArtists: ['Unknown'],
          preferredGenres: ['Rock'],
          exists: (_) => true,
        ),
      ),
      isEmpty,
    );
  });

  test('preferred genre matches canonical family aliases', () {
    PlayableMedia song(String id, String genre) => PlayableMedia(
      id: 'local_$id',
      source: '/$id',
      title: id,
      artist: 'Artist $id',
      album: '',
      genre: genre,
    );
    final mixes = buildLibraryMixes(
      LibraryMixRequest(
        at: DateTime(2026),
        exists: (_) => true,
        songs: [
          song('1', 'Hip Hop'),
          song('2', 'Rap'),
          song('3', 'Trap'),
          song('4', 'Electronica'),
          song('5', 'Techno'),
          song('6', 'Jazz'),
        ],
        preferredGenres: ['Hip-Hop', 'Electronic'],
      ),
    );
    expect(mixes[0].songIds, ['local_1', 'local_2', 'local_3']);
    expect(mixes[1].songIds, ['local_4', 'local_5']);
  });
}
