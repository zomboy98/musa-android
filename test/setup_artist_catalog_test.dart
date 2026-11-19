import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/setup_artist_catalog.dart';

Extension provider(String id, String filter, {bool enabled = true}) =>
    Extension(
      id: id,
      name: id,
      displayName: id,
      version: '1',
      description: '',
      enabled: enabled,
      status: 'loaded',
      searchBehavior: SearchBehavior(
        enabled: true,
        filters: [SearchFilter(id: filter)],
      ),
    );

void main() {
  test(
    'homonymous catalog results cannot trigger identity-based relations',
    () async {
      final choices = await searchSetupArtistCatalog(
        provider('deezer', 'artist'),
        'Muse',
        search: (_, query, options) async => [
          {'id': 'deezer:1', 'name': 'Muse', 'item_type': 'artist'},
          {'id': 'deezer:2', 'name': 'Muse', 'item_type': 'artist'},
        ],
      );
      expect(choices.map((choice) => choice.deezerId), everyElement(isNull));
    },
  );
  test('does not request blank or one-character artist searches', () async {
    for (final query in ['', '   ', ' A ']) {
      final choices = await searchSetupArtistCatalog(
        provider('catalog', 'artists'),
        query,
        search: (_, query, options) async {
          fail('Short queries must not reach the catalog');
        },
      );
      expect(choices, isEmpty);
    }
  });

  test('trims an explicit artist search before reaching the catalog', () async {
    await searchSetupArtistCatalog(
      provider('catalog', 'artists'),
      '  Muse  ',
      search: (_, query, options) async {
        expect(query, 'Muse');
        return [];
      },
    );
  });

  for (final entry in {'spotify': 'artists', 'deezer': 'artist'}.entries) {
    test('real ${entry.key} manifest uses its declared artist filter', () async {
      // Snapshots from extensiones/sources/{spotify-web,deezer}/manifest.json.
      final manifest =
          jsonDecode(
                File(
                  'test/fixtures/setup_artist_catalog_${entry.key}_manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final extension = Extension(
        id: manifest['name'] as String,
        name: manifest['name'] as String,
        displayName: manifest['name'] as String,
        version: manifest['version'] as String,
        description: '',
        enabled: true,
        status: 'loaded',
        searchBehavior: SearchBehavior.fromJson(
          manifest['searchBehavior'] as Map<String, dynamic>,
        ),
      );
      expect(setupArtistCatalogProvider([extension], extension.id), extension);
      var called = false;
      await searchSetupArtistCatalog(
        extension,
        'Muse',
        search: (id, query, options) async {
          called = true;
          expect(options['filter'], entry.value);
          return [];
        },
      );
      expect(called, isTrue);
    });
  }

  for (final filter in ['artist', 'artists']) {
    test(
      'artist search sends declared $filter filter and discards other types',
      () async {
        final choices = await searchSetupArtistCatalog(
          provider('catalog', filter),
          'Muse',
          search: (id, query, options) async {
            expect(id, 'catalog');
            expect(query, 'Muse');
            expect(options, {'filter': filter});
            return [
              {'id': '1', 'name': 'Muse', 'item_type': 'artist'},
              {'id': '2', 'name': 'A song', 'item_type': 'track'},
            ];
          },
        );
        expect(choices.map((choice) => choice.name), ['Muse']);
      },
    );
  }

  test('selects a capable enabled provider and honors preferred provider', () {
    final tracks = provider('tracks', 'tracks');
    final singular = provider('singular', 'artist');
    final plural = provider('plural', 'artists');
    final disabled = provider('disabled', 'artists', enabled: false);
    expect(setupArtistCatalogProvider([tracks, disabled], 'tracks'), isNull);
    expect(
      setupArtistCatalogProvider([tracks, singular, plural], 'plural'),
      plural,
    );
    expect(setupArtistCatalogProvider([tracks, singular], 'tracks'), singular);
  });

  test('does not query unsupported or disabled provider', () async {
    for (final extension in [
      provider('tracks', 'tracks'),
      provider('disabled', 'artists', enabled: false),
    ]) {
      final choices = await searchSetupArtistCatalog(
        extension,
        'Muse',
        search: (_, query, options) async {
          fail('Unsupported provider must remain offline');
        },
      );
      expect(choices, isEmpty);
    }
  });
}
