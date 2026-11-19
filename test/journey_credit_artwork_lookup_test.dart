import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/journey_credit_artwork_lookup.dart';

const mbid = 'cc197bad-dc9c-440d-a5b5-d52ba2e14234';

void main() {
  test(
    'does not follow artwork from a mismatched MusicBrainz identity',
    () async {
      var imageRequests = 0;
      final lookup = JourneyCreditArtworkLookup(
        client: MockClient((request) async {
          imageRequests++;
          return http.Response('{}', 200);
        }),
        musicBrainzGet: (uri) async => http.Response(
          jsonEncode({
            'id': '00000000-0000-0000-0000-000000000000',
            'relations': [
              {
                'type': 'wikidata',
                'url': {'resource': 'https://www.wikidata.org/wiki/Q45188'},
              },
            ],
          }),
          200,
        ),
      );
      final result = await lookup.lookup(
        artistIds: {'Coldplay': mbid},
        labelIds: {},
      );
      expect(result.artists, isEmpty);
      expect(imageRequests, 0);
    },
  );
  test(
    'uses linked entity logo and returns its licence and attribution',
    () async {
      var mbCalls = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'www.wikidata.org') {
          return http.Response(
            jsonEncode({
              'entities': {
                'Q45188': {
                  'claims': {
                    'P154': [
                      {
                        'mainsnak': {
                          'datavalue': {'value': 'Coldplay Rainbow Logo.png'},
                        },
                      },
                    ],
                  },
                },
              },
            }),
            200,
          );
        }
        if (request.url.host == 'commons.wikimedia.org') {
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [
                  {
                    'imageinfo': [
                      {
                        'thumburl':
                            'https://upload.wikimedia.org/thumb/logo.png',
                        'descriptionurl':
                            'https://commons.wikimedia.org/wiki/File:Logo.png',
                        'mime': 'image/png',
                        'extmetadata': {
                          'Artist': {'value': 'Coldplay'},
                          'LicenseShortName': {'value': 'Public domain'},
                        },
                      },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        }
        fail('Unexpected Wikimedia host');
      });
      final lookup = JourneyCreditArtworkLookup(
        client: client,
        musicBrainzGet: (uri) async {
          mbCalls++;
          expect(uri.path, '/ws/2/artist/$mbid');
          return http.Response(
            jsonEncode({
              'id': mbid,
              'relations': [
                {
                  'type': 'wikidata',
                  'url': {'resource': 'https://www.wikidata.org/wiki/Q45188'},
                },
              ],
            }),
            200,
          );
        },
      );
      final result = await lookup.lookup(
        artistIds: {'Coldplay': mbid},
        labelIds: {},
      );
      final image = result.artists['Coldplay'];
      expect(image?.imageUrl.host, 'upload.wikimedia.org');
      expect(image?.sourcePage.host, 'commons.wikimedia.org');
      expect(image?.license, 'Public domain');
      expect(image?.author, 'Coldplay');
      expect(image?.kind, JourneyCreditArtworkKind.logo);
      await lookup.lookup(artistIds: {'Coldplay': mbid}, labelIds: {});
      expect(mbCalls, 1);
    },
  );

  test(
    'omits an image when attribution is missing and rejects unverified ids',
    () async {
      var mbCalls = 0;
      final client = MockClient((request) async {
        if (request.url.host == 'www.wikidata.org') {
          return http.Response(
            jsonEncode({
              'entities': {
                'Q1': {
                  'claims': {
                    'P109': [
                      {
                        'mainsnak': {
                          'datavalue': {'value': 'Signature.png'},
                        },
                      },
                    ],
                  },
                },
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'query': {
              'pages': [
                {
                  'imageinfo': [
                    {
                      'thumburl':
                          'https://upload.wikimedia.org/thumb/signature.png',
                      'descriptionurl':
                          'https://commons.wikimedia.org/wiki/File:Signature.png',
                      'mime': 'image/png',
                      'extmetadata': {
                        'LicenseShortName': {'value': 'CC BY 4.0'},
                      },
                    },
                  ],
                },
              ],
            },
          }),
          200,
        );
      });
      final lookup = JourneyCreditArtworkLookup(
        client: client,
        musicBrainzGet: (uri) async {
          mbCalls++;
          return http.Response(
            jsonEncode({
              'id': mbid,
              'relations': [
                {
                  'type': 'wikidata',
                  'url': {'resource': 'https://www.wikidata.org/wiki/Q1'},
                },
              ],
            }),
            200,
          );
        },
      );
      final result = await lookup.lookup(
        artistIds: {'Valid': mbid, 'Invalid': 'wrong'},
        labelIds: {},
      );
      expect(result.artists, isEmpty);
      expect(mbCalls, 1);
    },
  );
  test(
    'requires an approved matching license and resolves verified producers',
    () async {
      Future<JourneyCreditArtworkResult> resolve(
        String license,
        String licenseUrl,
      ) async {
        final client = MockClient((request) async {
          if (request.url.host == 'www.wikidata.org') {
            return http.Response(
              jsonEncode({
                'entities': {
                  'Q1': {
                    'claims': {
                      'P154': [
                        {
                          'mainsnak': {
                            'datavalue': {'value': 'Producer.png'},
                          },
                        },
                      ],
                    },
                  },
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'query': {
                'pages': [
                  {
                    'imageinfo': [
                      {
                        'thumburl':
                            'https://upload.wikimedia.org/thumb/logo.png',
                        'descriptionurl':
                            'https://commons.wikimedia.org/wiki/File:Producer.png',
                        'mime': 'image/png',
                        'extmetadata': {
                          'Artist': {'value': 'Credited Artist'},
                          'LicenseShortName': {'value': license},
                          'LicenseUrl': {'value': licenseUrl},
                        },
                      },
                    ],
                  },
                ],
              },
            }),
            200,
          );
        });
        return JourneyCreditArtworkLookup(
          client: client,
          musicBrainzGet: (uri) async => http.Response(
            jsonEncode({
              'id': mbid,
              'relations': [
                {
                  'type': 'wikidata',
                  'url': {'resource': 'https://www.wikidata.org/wiki/Q1'},
                },
              ],
            }),
            200,
          ),
        ).lookup(artistIds: {}, labelIds: {}, producerIds: {'Producer': mbid});
      }

      final valid = await resolve(
        'CC BY-SA 4.0',
        'https://creativecommons.org/licenses/by-sa/4.0/',
      );
      expect(valid.producers['Producer']?.license, 'CC BY-SA 4.0');
      final mismatch = await resolve(
        'CC BY-SA 4.0',
        'https://creativecommons.org/licenses/by/4.0/',
      );
      expect(mismatch.producers, isEmpty);
      final unknown = await resolve(
        'Fair use',
        'https://creativecommons.org/licenses/by/4.0/',
      );
      expect(unknown.producers, isEmpty);
    },
  );
}
