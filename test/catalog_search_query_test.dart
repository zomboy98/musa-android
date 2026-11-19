import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_id_resolver.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/utils/catalog_search_query.dart';

void main() {
  group('titulo simplificado', () {
    final cases = <String, String>{
      'Suzuki (from GTAVI: The Album)': 'suzuki',
      'Canción del Mariachi (feat. Los Tigres del Norte)':
          'cancion del mariachi',
      'Ojitos Lindos [con Bomba Estéreo]': 'ojitos lindos',
      'Pa’ Ti + Lo Que Quiero': 'pa ti lo que quiero',
      'Mamiii - Remastered 2011': 'mamiii',
      'La Barbie - Live': 'la barbie',
      'Coração Cachorro (ft. Anitta) - Deluxe': 'coracao cachorro',
      'Não Me Toca': 'nao me toca',
      'Ke\$ha Song': 'kesha song',
      'El Niño “Perdido”': 'el nino perdido',
      "Don't Stop   Believin'": 'dont stop believin',
      'Baile Inolvidable feat. Bad Bunny': 'baile inolvidable',
      'Dancing with Myself': 'dancing with myself',
      'Año Nuevo / Vida Nueva': 'ano nuevo vida nueva',
      'Tití Me Preguntó': 'titi me pregunto',
      'Amor – Version Acústica': 'amor',
    };
    cases.forEach((input, expected) {
      test(input, () => expect(simplifiedSearchTitle(input), expected));
    });

    test('un titulo solo de simbolos no queda vacio', () {
      expect(simplifiedSearchTitle('(Live)'), isNotEmpty);
    });
  });

  group('artista principal', () {
    final cases = <String, String>{
      'Fuerza Regida, Grupo Frontera': 'fuerza regida',
      'Bad Bunny & Jhay Cortez': 'bad bunny',
      'Karol G feat. Peso Pluma': 'karol g',
      'Anitta ft. Becky G': 'anitta',
      'A\$AP Rocky': 'asap rocky',
      'Ñengo Flow': 'nengo flow',
      'Rosalía x Travis Scott': 'rosalia',
      'Natanael Cano y Peso Pluma': 'natanael cano',
      'Jorge & Mateus': 'jorge',
      'AC/DC': 'ac dc',
      'Maná': 'mana',
      'Luísa Sonza': 'luisa sonza',
    };
    cases.forEach((input, expected) {
      test(input, () => expect(simplifiedSearchArtist(input), expected));
    });
  });

  test('fold del resolvedor ignora tildes, signos y dolar', () {
    expect(
      CatalogIdResolver.fold('Canción'),
      CatalogIdResolver.fold('Cancion'),
    );
    expect(CatalogIdResolver.fold('Ke\$ha'), CatalogIdResolver.fold('Kesha'));
    expect(CatalogIdResolver.fold('Ñengo'), 'nengo');
  });

  test('el resolvedor reintenta con la consulta simplificada', () async {
    final queries = <String>[];
    final dir = await Directory.systemTemp.createTemp('query_resolver');
    addTearDown(() => dir.delete(recursive: true));
    final resolver = CatalogIdResolver(
      directory: () async => dir,
      enabled: () async => true,
      deezerByIsrc: (_) async => {'success': false},
      search: (provider, query, options) async {
        queries.add(query);
        if (query != 'cancion del mariachi tigres del norte') return [];
        return [
          {
            'id': 'tidal:99',
            'name': 'Canción del Mariachi',
            'artists': 'Tigres del Norte',
            'duration_ms': 200000,
          },
        ];
      },
    );
    const track = Track(
      id: 'apple-music:1',
      source: 'apple-music',
      name: 'Canción del Mariachi',
      artistName: 'Tigres del Norte, X',
      albumName: 'A',
      duration: 200,
    );
    await resolver.resolve(track, 'tidal-web');
    expect(queries.last, 'cancion del mariachi tigres del norte');
    expect(queries.length, 3);
  });

  group('solicitud', () {
    const track = Track(
      id: 'apple-music:1',
      source: 'apple-music',
      name: 'Canción “Única” (feat. X)',
      artistName: 'Peso Pluma,  Grupo Frontera',
      albumName: 'A',
      duration: 100,
    );
    ({String title, String artist}) probe(bool simplified) {
      final payload = buildCatalogDownloadPayload(
        track: track,
        directory: Directory.systemTemp,
        transferId: 't',
        service: 'deezer',
        quality: 'aac_160',
        useExtensions: true,
        useFallback: true,
        simplifiedQuery: simplified,
      );
      return (title: payload.trackName, artist: payload.artistName);
    }

    test('la consulta normal quita creditos y normaliza comillas', () {
      final payload = probe(false);
      expect(payload.title, 'Canción "Única"');
      expect(payload.artist, 'Peso Pluma, Grupo Frontera');
    });

    test('la consulta simplificada usa titulo y artista principal planos', () {
      final payload = probe(true);
      expect(payload.title, 'cancion unica');
      expect(payload.artist, 'peso pluma');
    });

    test('solo se reintenta cuando la forma simplificada difiere', () {
      expect(catalogQueryCanBeSimplified(track), isTrue);
      const plain = Track(
        id: 'x',
        source: 'a',
        name: 'hola',
        artistName: 'luz',
        albumName: '',
        duration: 1,
      );
      expect(catalogQueryCanBeSimplified(plain), isFalse);
    });
  });
}
