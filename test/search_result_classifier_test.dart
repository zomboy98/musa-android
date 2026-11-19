import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/home_search_logic.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/search_result_classifier.dart';

Track item(
  String name, {
  String type = 'artist',
  String? id,
  String? artistId,
  String? cover,
  String? source = 'prov',
  String artist = '',
  String? albumType,
}) {
  return Track(
    id: id ?? 'id-${name.toLowerCase().replaceAll(' ', '-')}',
    name: name,
    artistName: artist,
    albumName: '',
    artistId: artistId,
    coverUrl: cover,
    duration: 0,
    source: source,
    itemType: type,
    albumType: albumType,
  );
}

List<String> names(List<ClassifiedSearchItem> items) => [
  for (final i in items) i.track.name,
];

void main() {
  group('search result classifier', () {
    final photo = <Track>[
      item('Tito Double P', artistId: 'a1', cover: 'https://img/person.jpg'),
      item('Some Artist Mix', cover: 'https://img/mosaic.jpg'),
      item('Tito Dorca'),
      item('Mc Tuto'),
      item('Monde des Titounis'),
    ];

    test('the reported list: a derived list is not an artist', () {
      final result = classifySearchResults(photo, query: 'tito do');
      expect(names(result.artists), [
        'Tito Double P',
        'Tito Dorca',
        'Monde des Titounis',
        'Mc Tuto',
      ]);
      expect(names(result.playlists), ['Some Artist Mix']);
      final demoted = result.playlists.single;
      expect(demoted.track.isPlaylistItem, isTrue);
      expect(demoted.track.isArtistItem, isFalse);
      expect(demoted.demotedFromArtist, isTrue);
      expect(demoted.track.coverUrl, 'https://img/mosaic.jpg');
      // Mc Tuto matches no token of the query: kept, but last.
      expect(result.albums, isEmpty);
      expect(result.songs, isEmpty);
    });

    test('is deterministic', () {
      final a = classifySearchResults(photo, query: 'tito do');
      final b = classifySearchResults(photo, query: 'tito do');
      expect(names(a.artists), names(b.artists));
      expect(names(a.playlists), names(b.playlists));
    });

    test('Bad Bunny vs Mix vs Radio', () {
      final result = classifySearchResults([
        item('Bad Bunny Mix'),
        item('Bad Bunny', artistId: 'bb'),
        item('Bad Bunny Radio'),
        item('Bad Bunny - Topic'),
      ], query: 'bad bunny');
      expect(names(result.artists), ['Bad Bunny']);
      expect(names(result.playlists), [
        'Bad Bunny Mix',
        'Bad Bunny Radio',
        'Bad Bunny - Topic',
      ]);
    });

    test('leading list phrases are demoted next to the artist', () {
      final result = classifySearchResults([
        item('Bad Bunny', artistId: 'bb'),
        item('This Is Bad Bunny'),
        item('Lo mejor de Bad Bunny'),
      ], query: 'bad bunny');
      expect(names(result.artists), ['Bad Bunny']);
      expect(names(result.playlists), [
        'This Is Bad Bunny',
        'Lo mejor de Bad Bunny',
      ]);
    });

    test('Taylor Swift Hits alone keeps the declared type with an artist id', () {
      final kept = classifySearchResults([
        item('Taylor Swift Hits', artistId: 'ts-hits'),
      ], query: 'taylor swift');
      expect(names(kept.artists), ['Taylor Swift Hits']);
      expect(kept.playlists, isEmpty);

      final demoted = classifySearchResults([
        item('Taylor Swift Hits'),
      ], query: 'taylor swift');
      expect(names(demoted.playlists), ['Taylor Swift Hits']);
    });

    test('legit artists with a generic word are not demoted when alone', () {
      final result = classifySearchResults([
        item('Los Hits'),
        item('Radio Futura'),
        item('Top Gear'),
      ]);
      expect(names(result.artists), ['Los Hits', 'Radio Futura', 'Top Gear']);
      expect(result.playlists, isEmpty);
    });

    test('a generic word typed by the user is not evidence', () {
      final result = classifySearchResults([
        item('Gaby Mix'),
      ], query: 'gaby mix');
      expect(names(result.artists), ['Gaby Mix']);
    });

    test('the source can state it is a list', () {
      final result = classifySearchResults([
        item('Jose Jose', artistId: 'jj', albumType: 'playlist'),
      ]);
      expect(names(result.playlists), ['Jose Jose']);
    });

    test('declared types are respected otherwise', () {
      final result = classifySearchResults([
        item('Un Album Mix', type: 'album'),
        item('Mi Lista Hits', type: 'playlist'),
        item('Una cancion', type: 'track'),
        item('Sin tipo', type: ''),
      ]);
      expect(names(result.albums), ['Un Album Mix']);
      expect(names(result.playlists), ['Mi Lista Hits']);
      expect(names(result.songs), ['Una cancion', 'Sin tipo']);
      expect(result.songs.map((i) => i.originalIndex), [2, 3]);
    });

    test('no duplicates inside or across sections', () {
      final result = classifySearchResults([
        item('Peso Pluma', artistId: 'pp'),
        item('Peso Pluma Mix'),
        item('peso  pluma', id: 'id-peso-pluma', cover: 'https://img/b.jpg'),
        item('Peso Pluma Radio', type: 'playlist'),
        item('Peso Pluma Mix', type: 'playlist'),
      ], query: 'peso pluma');
      expect(names(result.artists), ['Peso Pluma']);
      // The artist keeps the better image from its duplicate.
      expect(result.artists.single.track.coverUrl, 'https://img/b.jpg');
      expect(names(result.playlists), ['Peso Pluma Mix', 'Peso Pluma Radio']);
      final all = [
        ...result.artists,
        ...result.albums,
        ...result.playlists,
      ].map((i) => '${i.kind}-${i.track.name}').toList();
      expect(all.toSet().length, all.length);
    });

    test('albums with one name but another owner stay separate', () {
      final result = classifySearchResults([
        item('Greatest Hits', type: 'album', artist: 'Queen', id: '1'),
        item('Greatest Hits', type: 'album', artist: 'ABBA', id: '2'),
      ]);
      expect(result.albums, hasLength(2));
    });

    test('duplicates merge keeping the most reliable id and the image', () {
      final result = classifySearchResults([
        item('Karol G', id: ''),
        item('Karol G', id: 'kg-1', cover: 'https://img/kg.jpg'),
      ]);
      expect(result.artists, hasLength(1));
      expect(result.artists.single.track.id, 'kg-1');
      expect(result.artists.single.track.coverUrl, 'https://img/kg.jpg');
    });

    test('spelling variants merge only when both look like artists', () {
      final both = classifySearchResults([
        item('Tito Double P', artistId: 'a'),
        item('Tito Doble P', artistId: 'b'),
      ]);
      expect(names(both.artists), ['Tito Double P']);

      final one = classifySearchResults([
        item('Tito Double P', artistId: 'a'),
        item('Tito Doble P'),
      ]);
      expect(one.artists, hasLength(2));
    });

    test('relevance: full prefix match > partial > single token', () {
      final result = classifySearchResults([
        item('Los Titounis'),
        item('Mix Dorado Tito'),
        item('Tito Dorado'),
      ], query: 'tito do');
      expect(names(result.artists), [
        'Tito Dorado',
        'Mix Dorado Tito',
        'Los Titounis',
      ]);
    });

    test('ties keep the provider order', () {
      final result = classifySearchResults([
        item('Zeta Band'),
        item('Alfa Band'),
        item('Mid Band'),
      ], query: 'band');
      expect(names(result.artists), ['Zeta Band', 'Alfa Band', 'Mid Band']);
    });

    test('accents and case do not matter', () {
      expect(normalizeSearchText('  Beyoncé!!  Mix '), 'beyonce mix');
      final result = classifySearchResults([
        item('Beyoncé', artistId: 'b'),
        item('BEYONCE Radio'),
      ], query: 'beyonce');
      expect(names(result.playlists), ['BEYONCE Radio']);
    });
  });

  group('home search buckets', () {
    test('a demoted artist lands in playlists only', () {
      final buckets = bucketHomeSearchResults([
        item('Tito Double P', artistId: 'a1'),
        item('Some Artist Mix'),
        item('Song X', type: 'track'),
      ], query: 'tito do');
      expect(buckets.artistItems.map((t) => t.name), ['Tito Double P']);
      expect(buckets.playlistItems.map((t) => t.name), [
        'Some Artist Mix',
      ]);
      expect(buckets.playlistItems.single.isPlaylistItem, isTrue);
      expect(buckets.realTracks.map((t) => t.name), ['Song X']);
      expect(buckets.realTrackIndexes, [2]);
    });
  });
}
