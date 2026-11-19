import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_id_resolver.dart';
import 'package:mornye/services/catalog_playback.dart';

void main() {
  const suzuki = Track(
    id: 'deezer:4337604802',
    source: 'deezer',
    name: 'Suzuki (from GTAVI: The Album)',
    artistName: 'Fuerza Regida, Grand Theft Auto VI',
    albumName: 'GTAVI: The Album',
    isrc: 'USAT22607218',
    duration: 112,
    deezerId: '4337604802',
  );

  Map<String, dynamic> build(
    Track track,
    String service,
    String quality,
    CatalogNativeId? nativeId, {
    bool useFallback = false,
    bool pass = true,
  }) {
    final directory = Directory('/tmp/x');
    final payload = pass
        ? buildCatalogDownloadPayload(
            track: track,
            directory: directory,
            transferId: 't',
            service: service,
            quality: quality,
            useExtensions: true,
            useFallback: useFallback,
            nativeId: nativeId,
          )
        : buildCatalogDownloadPayload(
            track: track,
            directory: directory,
            transferId: 't',
            service: service,
            quality: quality,
            useExtensions: true,
            useFallback: useFallback,
          );
    return payload.toJson();
  }

  CatalogNativeId native(String provider, String id) =>
      CatalogNativeId(provider, id, CatalogIdVia.isrc);

  void expectFields(Map<String, dynamic> json, Map<String, dynamic> expected) {
    expected.forEach((key, value) {
      expect(json[key], value, reason: key);
    });
  }

  test('Tidal entrega su ID en el campo nativo y conserva la fuente', () {
    final json = build(
      suzuki,
      'tidal-web',
      'HI_RES_LOSSLESS',
      native('tidal-web', '568276392'),
    );
    expectFields(json, {
      'source': 'deezer',
      'provider_track_id': '',
      'tidal_id': '568276392',
      'deezer_id': '4337604802',
      'qobuz_id': '',
      'spotify_id': '',
      'quality': 'HI_RES_LOSSLESS',
      'use_fallback': false,
      'service': 'tidal-web',
      'download_provider': 'tidal-web',
      'isrc': 'USAT22607218',
      'duration_ms': 112000,
    });
  });

  test('Beatport usa la ruta directa y vacia los ID ajenos', () {
    final json = build(
      suzuki,
      'beatport',
      'LOSSLESS',
      native('beatport', '30982448'),
    );
    expectFields(json, {
      'source': 'beatport',
      'provider_track_id': '30982448',
      'tidal_id': '',
      'qobuz_id': '',
      'deezer_id': '',
      'spotify_id': '',
      'quality': 'LOSSLESS',
      'isrc': 'USAT22607218',
    });
  });

  test('Amazon con ASIN conocido usa la ruta directa', () {
    final json = build(
      suzuki,
      'amazon',
      'best',
      native('amazon', 'B0HMDH7PHM'),
    );
    expectFields(json, {
      'source': 'amazon',
      'provider_track_id': 'B0HMDH7PHM',
      'tidal_id': '',
      'qobuz_id': '',
      'deezer_id': '',
      'spotify_id': '',
      'quality': 'best',
    });
  });

  test('Qobuz entrega su ID en el campo nativo', () {
    final json = build(
      suzuki,
      'qobuz-web',
      'HI_RES_LOSSLESS',
      native('qobuz-web', '308372039'),
    );
    expectFields(json, {
      'source': 'deezer',
      'qobuz_id': '308372039',
      'provider_track_id': '',
      'deezer_id': '4337604802',
    });
  });

  test('Deezer desde otro catalogo recibe su ID sin cambiar la fuente', () {
    const tidalTrack = Track(
      id: 'tidal:568276392',
      source: 'tidal-web',
      name: 'Suzuki (from GTAVI: The Album)',
      artistName: 'Fuerza Regida, Grand Theft Auto VI',
      albumName: 'GTAVI: The Album',
      isrc: 'USAT22607218',
      duration: 112,
    );
    final json = build(
      tidalTrack,
      'deezer',
      'flac',
      native('deezer', '4337604802'),
    );
    expectFields(json, {
      'source': 'tidal-web',
      'deezer_id': '4337604802',
      'tidal_id': '568276392',
      'provider_track_id': '',
      'quality': 'flac',
    });
  });

  test('la calidad se normaliza a la grafia del manifiesto', () {
    final json = build(
      suzuki,
      'beatport',
      'hi_res_lossless',
      native('beatport', '30982448'),
    );
    expect(json['quality'], 'LOSSLESS');
  });

  test('sin ID resuelto el payload es el de siempre', () {
    final without = build(suzuki, 'beatport', 'LOSSLESS', null, pass: false);
    final withNull = build(suzuki, 'beatport', 'LOSSLESS', null);
    expect(withNull, without);
  });

  test('con recorrido completo el ID resuelto se ignora', () {
    final base = build(suzuki, 'beatport', 'LOSSLESS', null, useFallback: true);
    final json = build(
      suzuki,
      'beatport',
      'LOSSLESS',
      native('beatport', '30982448'),
      useFallback: true,
    );
    expect(json, base);
  });

  test('un ID de otro proveedor se ignora', () {
    final base = build(suzuki, 'beatport', 'LOSSLESS', null);
    final json = build(
      suzuki,
      'beatport',
      'LOSSLESS',
      native('tidal-web', '568276392'),
    );
    expect(json, base);
  });

  test('un ID con formato invalido se ignora', () {
    final base = build(suzuki, 'amazon', 'best', null);
    final json = build(suzuki, 'amazon', 'best', native('amazon', '568276392'));
    expect(json, base);
  });

  test('una pista ya nativa del proveedor no cambia', () {
    const beatportTrack = Track(
      id: 'beatport:111',
      source: 'beatport',
      name: 'Suzuki',
      artistName: 'Fuerza Regida',
      albumName: 'GTAVI: The Album',
      isrc: 'USAT22607218',
      duration: 112,
    );
    final base = build(beatportTrack, 'beatport', 'LOSSLESS', null);
    final json = build(
      beatportTrack,
      'beatport',
      'LOSSLESS',
      native('beatport', '30982448'),
    );
    expect(json['provider_track_id'], '111');
    expect(json, base);
  });
}
