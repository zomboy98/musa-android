import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mornye/services/journey_credit_lookup.dart';

const _artistId = 'a0000000-0000-4000-8000-000000000001';
const _labelId = 'b0000000-0000-4000-8000-000000000001';
const _releaseId = 'c0000000-0000-4000-8000-000000000001';
const _producerId = 'e0000000-0000-4000-8000-000000000001';

Map<String, dynamic> _recording({List<Map<String, dynamic>>? releases}) => {
  'id': 'd0000000-0000-4000-8000-000000000001',
  'artist-credit': [
    {
      'name': 'Tito Double P',
      'artist': {'id': _artistId, 'name': 'Tito Double P'},
    },
  ],
  'relations': [
    {
      'type': 'producer',
      'target-type': 'artist',
      'artist': {'id': _producerId, 'name': 'Productor real'},
    },
    {
      'type': 'performer',
      'target-type': 'artist',
      'artist': {'name': 'No productor'},
    },
  ],
  'releases':
      releases ??
      [
        {'id': _releaseId, 'title': 'ACOMODO'},
      ],
};

void main() {
  test('omite MBID de productores con homónimos o datos incompletos', () async {
    final recording = _recording();
    recording['relations'] = [
      {
        'type': 'producer',
        'target-type': 'artist',
        'artist': {'id': _producerId, 'name': 'Mismo Nombre'},
      },
      {
        'type': 'producer',
        'target-type': 'artist',
        'artist': {
          'id': 'e0000000-0000-4000-8000-000000000002',
          'name': 'Mismo Nombre',
        },
      },
      {
        'type': 'producer',
        'target-type': 'artist',
        'artist': {'name': 'Sin ID'},
      },
    ];
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'recordings': [recording],
        }),
        200,
      ),
    );
    final result = await JourneyCreditLookup(
      client: client,
      minInterval: Duration.zero,
    ).lookup(isrc: 'USABC2400001', artists: ['Tito Double P']);
    expect(result.producers, ['Mismo Nombre', 'Sin ID']);
    expect(result.producerIds, isEmpty);
  });
  test(
    'obtiene créditos y entidades solo de grabación y edición coincidentes',
    () async {
      final requests = <Uri>[];
      final client = MockClient((request) async {
        requests.add(request.url);
        if (request.url.path.contains('/isrc/')) {
          return http.Response(
            jsonEncode({
              'recordings': [_recording()],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'label-info': [
              {
                'label': {'id': _labelId, 'name': 'Sello real'},
              },
            ],
          }),
          200,
        );
      });
      final lookup = JourneyCreditLookup(
        client: client,
        minInterval: Duration.zero,
      );
      final result = await lookup.lookup(
        isrc: 'USABC2400001',
        album: 'ACOMODO',
        artists: ['Tito Double P'],
      );
      expect(result.producers, ['Productor real']);
      expect(result.producerIds, {'Productor real': _producerId});
      expect(result.labels, ['Sello real']);
      expect(result.artistIds, {'Tito Double P': _artistId});
      expect(result.labelIds, {'Sello real': _labelId});
      expect(requests.length, 2);
      expect(requests.first.queryParameters['inc'], contains('artist-rels'));
    },
  );

  test('omite sello si hay más de una edición con ese álbum', () async {
    var calls = 0;
    final client = MockClient((request) async {
      calls++;
      return http.Response(
        jsonEncode({
          'recordings': [
            _recording(
              releases: [
                {'id': _releaseId, 'title': 'ACOMODO'},
                {
                  'id': 'c0000000-0000-4000-8000-000000000002',
                  'title': 'ACOMODO',
                },
              ],
            ),
          ],
        }),
        200,
      );
    });
    final result =
        await JourneyCreditLookup(
          client: client,
          minInterval: Duration.zero,
        ).lookup(
          isrc: 'USABC2400001',
          album: 'ACOMODO',
          artists: ['Tito Double P'],
        );
    expect(result.labels, isEmpty);
    expect(result.labelIds, isEmpty);
    expect(result.producers, ['Productor real']);
    expect(calls, 1);
  });

  test(
    'no atribuye créditos si ISRC o artista no identifica con seguridad',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'recordings': [_recording(), _recording()],
          }),
          200,
        );
      });
      final lookup = JourneyCreditLookup(
        client: client,
        minInterval: Duration.zero,
      );
      final invalid = await lookup.lookup(
        isrc: 'malo',
        album: 'ACOMODO',
        artists: ['Tito Double P'],
      );
      expect(invalid.labels, isEmpty);
      expect(calls, 0);
      final ambiguous = await lookup.lookup(
        isrc: 'USABC2400001',
        album: 'ACOMODO',
        artists: ['Tito Double P'],
      );
      expect(ambiguous.producers, isEmpty);
      expect(ambiguous.artistIds, {'Tito Double P': _artistId});
    },
  );

  test(
    'comparte peticiones concurrentes y permite reintento tras error de red',
    () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (calls == 1) return http.Response('', 503);
        return http.Response(
          jsonEncode({
            'recordings': [_recording()],
          }),
          200,
        );
      });
      final lookup = JourneyCreditLookup(
        client: client,
        minInterval: Duration.zero,
      );
      final a = lookup.lookup(isrc: 'USABC2400001', artists: ['Tito Double P']);
      final b = lookup.lookup(isrc: 'USABC2400001', artists: ['Tito Double P']);
      expect(
        (await Future.wait([a, b])).every((x) => x.producers.isEmpty),
        isTrue,
      );
      expect(calls, 1);
      final retried = await lookup.lookup(
        isrc: 'USABC2400001',
        artists: ['Tito Double P'],
      );
      expect(retried.producers, ['Productor real']);
      expect(calls, 2);
      await lookup.lookup(isrc: 'USABC2400001', artists: ['Tito Double P']);
      expect(calls, 2);
    },
  );

  test(
    'devuelve solo artista al coincidir varias grabaciones con mismo MBID',
    () async {
      final client = MockClient(
        (_) async => http.Response(
          jsonEncode({
            'recordings': [_recording(), _recording(), _recording()],
          }),
          200,
        ),
      );
      final result =
          await JourneyCreditLookup(
            client: client,
            minInterval: Duration.zero,
          ).lookup(
            isrc: 'GBAYE0000267',
            album: 'Parachutes',
            artists: ['Tito Double P'],
          );
      expect(result.artistIds, {'Tito Double P': _artistId});
      expect(result.producers, isEmpty);
      expect(result.producerIds, isEmpty);
      expect(result.labels, isEmpty);
      expect(result.labelIds, isEmpty);
    },
  );

  test('omite artista si las grabaciones discrepan en MBID', () async {
    final other = _recording();
    other['artist-credit'] = [
      {
        'name': 'Tito Double P',
        'artist': {
          'id': 'a0000000-0000-4000-8000-000000000002',
          'name': 'Tito Double P',
        },
      },
    ];
    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'recordings': [_recording(), other],
        }),
        200,
      ),
    );
    final result = await JourneyCreditLookup(
      client: client,
      minInterval: Duration.zero,
    ).lookup(isrc: 'GBAYE0000267', artists: ['Tito Double P']);
    expect(result.artistIds, isEmpty);
    expect(result.producers, isEmpty);
  });

  test('consulta ediciones por grabación cuando ISRC no las incluye', () async {
    final recording = _recording(releases: []);
    final client = MockClient((request) async {
      if (request.url.path.contains('/isrc/')) {
        return http.Response(
          jsonEncode({
            'recordings': [recording],
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/release')) {
        expect(request.url.queryParameters['recording'], recording['id']);
        return http.Response(
          jsonEncode({
            'release-count': 1,
            'release-offset': 0,
            'releases': [
              {
                'id': _releaseId,
                'title': 'ACOMODO',
                'label-info': [
                  {
                    'label': {'id': _labelId, 'name': 'Sello real'},
                  },
                ],
              },
            ],
          }),
          200,
        );
      }
      return http.Response('', 404);
    });
    final result =
        await JourneyCreditLookup(
          client: client,
          minInterval: Duration.zero,
        ).lookup(
          isrc: 'USABC2400001',
          album: 'ACOMODO',
          artists: ['Tito Double P'],
        );
    expect(result.labels, ['Sello real']);
    expect(result.labelIds, {'Sello real': _labelId});
  });

  test(
    'no atribuye sello cuando catálogo de ediciones está paginado',
    () async {
      final client = MockClient((request) async {
        if (request.url.path.contains('/isrc/')) {
          return http.Response(
            jsonEncode({
              'recordings': [_recording(releases: [])],
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'release-count': 200,
            'release-offset': 0,
            'releases': [
              {
                'id': _releaseId,
                'title': 'ACOMODO',
                'label-info': [
                  {
                    'label': {'id': _labelId, 'name': 'Sello real'},
                  },
                ],
              },
            ],
          }),
          200,
        );
      });
      final result =
          await JourneyCreditLookup(
            client: client,
            minInterval: Duration.zero,
          ).lookup(
            isrc: 'USABC2400001',
            album: 'ACOMODO',
            artists: ['Tito Double P'],
          );
      expect(result.labels, isEmpty);
      expect(result.producers, ['Productor real']);
    },
  );
  test('exige acuerdo para cada artista en todas las grabaciones', () async {
    Map<String, dynamic> rec(String collaboratorId) {
      final r = _recording();
      r['artist-credit'] = [
        {
          'name': 'Tito Double P',
          'artist': {'id': _artistId, 'name': 'Tito Double P'},
        },
        {
          'name': 'Invitado',
          'artist': {'id': collaboratorId, 'name': 'Invitado'},
        },
      ];
      return r;
    }

    final client = MockClient(
      (_) async => http.Response(
        jsonEncode({
          'recordings': [
            rec('a0000000-0000-4000-8000-000000000002'),
            rec('a0000000-0000-4000-8000-000000000003'),
          ],
        }),
        200,
      ),
    );
    final result = await JourneyCreditLookup(
      client: client,
      minInterval: Duration.zero,
    ).lookup(isrc: 'GBAYE0000267', artists: ['Tito Double P', 'Invitado']);
    expect(result.artistIds, isEmpty);
    expect(result.producers, isEmpty);
  });
}
