import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/playback_track_enrichment.dart';

void main() {
  const bare = Track(
    id: 'apple-music:123',
    source: 'apple-music',
    name: 'Suzuki (from GTAVI: The Album)',
    artistName: 'Fuerza Regida, X',
    albumName: 'A',
    duration: 0,
  );

  test('rellena ISRC y duracion desde el proveedor de origen', () async {
    final calls = <List<String>>[];
    final result = await enrichTrackForPlayback(
      bare,
      loadMetadata: (provider, type, id) async {
        calls.add([provider, type, id]);
        return {
          'track': {'isrc': 'us-abc-26-00001', 'duration_ms': 181000},
        };
      },
    );
    expect(calls.single, ['apple-music', 'track', '123']);
    expect(result.isrc, 'USABC2600001');
    expect(result.duration, 181);
    expect(result.name, bare.name);
    expect(result.id, bare.id);
  });

  test('acepta la carga sin envoltorio track', () async {
    final result = await enrichTrackForPlayback(
      bare,
      loadMetadata: (_, _, _) async => {'isrc': 'USABC2600001', 'duration': 90},
    );
    expect(result.isrc, 'USABC2600001');
    expect(result.duration, 90);
  });

  test('no pide nada si ya hay ISRC valido y duracion', () async {
    var called = false;
    final full = bare.copyWith(isrc: 'USABC2600001', duration: 100);
    final result = await enrichTrackForPlayback(
      full,
      loadMetadata: (_, _, _) async {
        called = true;
        return {};
      },
    );
    expect(called, isFalse);
    expect(identical(result, full), isTrue);
  });

  test('no sobrescribe valores existentes ni acepta ISRC invalido', () async {
    final partial = bare.copyWith(isrc: 'USABC2600001');
    final result = await enrichTrackForPlayback(
      partial,
      loadMetadata: (_, _, _) async => {
        'track': {'isrc': 'ZZZZZZZZZZZZ', 'duration_ms': 5000},
      },
    );
    expect(result.isrc, 'USABC2600001');
    expect(result.duration, 5);
  });

  test('un fallo o un tiempo agotado devuelve la pista intacta', () async {
    final failed = await enrichTrackForPlayback(
      bare,
      loadMetadata: (_, _, _) async => throw StateError('x'),
    );
    expect(identical(failed, bare), isTrue);
    final slow = await enrichTrackForPlayback(
      bare,
      timeout: const Duration(milliseconds: 20),
      loadMetadata: (_, _, _) => Completer<Map<String, dynamic>>().future,
    );
    expect(identical(slow, bare), isTrue);
  });

  test('pistas sin origen no se enriquecen', () {
    expect(playbackTrackNeedsEnrichment(bare.copyWith(source: '')), isFalse);
    expect(playbackTrackNeedsEnrichment(bare), isTrue);
  });

  test('la solicitud lleva ISRC, duracion y titulo limpio', () {
    final enriched = bare.copyWith(isrc: 'USABC2600001', duration: 181);
    final payload = buildCatalogDownloadPayload(
      track: enriched,
      directory: Directory.systemTemp,
      transferId: 't',
      service: 'deezer',
      quality: 'aac_160',
      useExtensions: true,
      useFallback: true,
    );
    expect(payload.isrc, 'USABC2600001');
    expect(payload.durationMs, 181000);
    expect(payload.trackName, 'Suzuki');
  });

  test('las versiones del titulo se conservan', () {
    final payload = buildCatalogDownloadPayload(
      track: bare.copyWith(name: 'Song (Live from Y)'),
      directory: Directory.systemTemp,
      transferId: 't',
      service: 'deezer',
      quality: 'aac_160',
      useExtensions: true,
      useFallback: true,
    );
    expect(payload.trackName, 'Song (Live from Y)');
  });
}
