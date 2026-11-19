import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/utils/download_quality_options.dart';

void main() {
  test('matches only a fully specified codec and quality signature', () {
    const options = [
      QualityOption(id: 'new-lossless', label: 'FLAC 24-bit 96kHz'),
      QualityOption(id: 'aac-new', label: 'AAC 320 kbps'),
      QualityOption(id: 'opus-new', label: 'Opus 320 kbps'),
    ];
    expect(
      findEquivalentDownloadQualityOption(options, 'flac_24bit_96khz')?.id,
      'new-lossless',
    );
    expect(
      findEquivalentDownloadQualityOption(options, 'aac_320')?.id,
      'aac-new',
    );
    expect(findEquivalentDownloadQualityOption(options, 'flac'), isNull);
    expect(findEquivalentDownloadQualityOption(options, ''), isNull);
    expect(findEquivalentDownloadQualityOption(options, 'mp3_320'), isNull);
    expect(
      findEquivalentDownloadQualityOption(options, 'flac_16bit_96khz'),
      isNull,
    );
    expect(
      findEquivalentDownloadQualityOption(const [
        QualityOption(id: 'aac_128', label: 'AAC 320 kbps'),
      ], 'aac_128'),
      isNull,
    );
    expect(
      findEquivalentDownloadQualityOption(const [
        QualityOption(id: 'aac_128', label: 'Opus 128 kbps'),
      ], 'aac_128'),
      isNull,
    );
    expect(
      findEquivalentDownloadQualityOption(const [
        QualityOption(id: 'flac_24bit_96khz', label: 'FLAC 16-bit 96kHz'),
      ], 'flac_24bit_96khz'),
      isNull,
    );
  });

  // Rust (manifest.rs `quality_claims_conflict` / `extension_quality_kind`)
  // distingue por `kind == "spatial"` (y por palabras espaciales en manifiestos
  // antiguos sin kind). Sin red ni dispositivo.
  group('spatial vs stereo kind', () {
    // Fixture simulada con la forma JSON del manifiesto que Rust consume.
    final spatialManifestJson = <Map<String, dynamic>>[
      {'id': 'spatial_aac_128', 'label': 'AAC 128 kbps', 'kind': 'spatial'},
      {'id': 'aac_128', 'label': 'AAC 128 kbps', 'kind': 'lossy'},
    ];

    test('fromJson conserva kind y JSON antiguo sin kind queda vacio', () {
      final options = spatialManifestJson.map(QualityOption.fromJson).toList();
      expect(options[0].kind, 'spatial');
      expect(options[1].kind, 'lossy');
      expect(QualityOption.fromJson({'id': 'x', 'label': 'y'}).kind, '');
      expect(QualityOption.fromJson({'id': 'x', 'kind': 7}).kind, '');
      expect(const QualityOption(id: 'x', label: 'y').kind, '');
    });

    test('tier spatial "AAC 128 kbps" no se equipara a aac_128 estereo', () {
      final options = spatialManifestJson.map(QualityOption.fromJson).toList();
      // El spatial va primero: antes ganaba por firstOrNull.
      expect(
        findEquivalentDownloadQualityOption(options, 'aac_128')?.id,
        'aac_128',
      );
    });

    test('con solo un tier spatial disponible no se acepta para estereo', () {
      final options = [QualityOption.fromJson(spatialManifestJson.first)];
      expect(findEquivalentDownloadQualityOption(options, 'aac_128'), isNull);
    });

    test(
      'manifiesto antiguo sin kind ("Dolby Atmos") no se equipara a estereo',
      () {
        const options = [
          QualityOption(id: 'atmos', label: 'Dolby Atmos AAC 128 kbps'),
        ];
        expect(findEquivalentDownloadQualityOption(options, 'aac_128'), isNull);
      },
    );

    test('control: opcion estereo identica sin kind sigue equiparandose', () {
      const options = [QualityOption(id: 'aac-new', label: 'AAC 128 kbps')];
      expect(
        findEquivalentDownloadQualityOption(options, 'aac_128')?.id,
        'aac-new',
      );
    });

    test(
      'equivalencia spatial explicita: solicitud espacial con opcion spatial',
      () {
        final options = spatialManifestJson
            .map(QualityOption.fromJson)
            .toList();
        expect(
          findEquivalentDownloadQualityOption(options, 'atmos_aac_128')?.id,
          'spatial_aac_128',
        );
        const legacy = [
          QualityOption(id: 'atmos', label: 'Dolby Atmos AAC 128 kbps'),
        ];
        expect(
          findEquivalentDownloadQualityOption(legacy, 'atmos_aac_128')?.id,
          'atmos',
        );
        // Una solicitud espacial tampoco cae en el tier estereo.
        final stereoOnly = [QualityOption.fromJson(spatialManifestJson.last)];
        expect(
          findEquivalentDownloadQualityOption(stereoOnly, 'atmos_aac_128'),
          isNull,
        );
      },
    );

    test('control: bitrate distinto sigue sin equipararse', () {
      final options = [QualityOption.fromJson(spatialManifestJson.first)];
      expect(findEquivalentDownloadQualityOption(options, 'aac_320'), isNull);
    });

    test('F3: solicitud que dice "spatial" no cae en un tier estereo', () {
      const stereo = [QualityOption(id: 'aac_128', label: 'AAC 128 kbps')];
      expect(
        findEquivalentDownloadQualityOption(stereo, 'spatial_aac_128'),
        isNull,
      );
      final spatial = [QualityOption.fromJson(spatialManifestJson.first)];
      expect(
        findEquivalentDownloadQualityOption(spatial, 'spatial_aac_128')?.id,
        'spatial_aac_128',
      );
    });

    // Limitacion documentada: la ruta de ajustes guarda solo el id
    // (Map<String,String>), nunca el QualityOption de origen. Si el id
    // recordado no dice "spatial/atmos" y ya no esta en la lista viva, su
    // origen espacial es irrecuperable sin inventarlo; se trata como estereo.
    test('F3 limitacion: id sin texto espacial se evalua como estereo', () {
      const stereo = [QualityOption(id: 'aac_128', label: 'AAC 128 kbps')];
      expect(
        findEquivalentDownloadQualityOption(stereo, 'aac_128_v1')?.id,
        'aac_128',
      );
    });
  });

  group('F1: kind declarado contradice el codec', () {
    test('kind lossless con AAC se descarta', () {
      const options = [
        QualityOption(id: 'aac_128', label: 'AAC 128 kbps', kind: 'lossless'),
      ];
      expect(findEquivalentDownloadQualityOption(options, 'aac_128'), isNull);
    });

    test('kind lossy con FLAC se descarta', () {
      const options = [
        QualityOption(
          id: 'flac_24bit_96khz',
          label: 'FLAC 24-bit 96kHz',
          kind: 'lossy',
        ),
      ];
      expect(
        findEquivalentDownloadQualityOption(options, 'flac_24bit_96khz'),
        isNull,
      );
    });

    test('palabra lossless/lossy en el label contradice el codec', () {
      const lossless = [
        QualityOption(id: 'aac_128', label: 'Lossless AAC 128 kbps'),
      ];
      const lossy = [
        QualityOption(id: 'flac_24bit_96khz', label: 'Lossy FLAC 24-bit 96kHz'),
      ];
      expect(findEquivalentDownloadQualityOption(lossless, 'aac_128'), isNull);
      expect(
        findEquivalentDownloadQualityOption(lossy, 'flac_24bit_96khz'),
        isNull,
      );
    });

    test('controles: kind coherente con el codec sigue equiparando', () {
      const options = [
        QualityOption(id: 'a', label: 'AAC 128 kbps', kind: 'lossy'),
        QualityOption(id: 'f', label: 'FLAC 24-bit 96kHz', kind: 'lossless'),
      ];
      expect(findEquivalentDownloadQualityOption(options, 'aac_128')?.id, 'a');
      expect(
        findEquivalentDownloadQualityOption(options, 'flac_24bit_96khz')?.id,
        'f',
      );
    });

    test('solicitud con clase explicita contradictoria no equipara', () {
      const options = [QualityOption(id: 'aac_128', label: 'AAC 128 kbps')];
      expect(
        findEquivalentDownloadQualityOption(options, 'lossless_aac_128'),
        isNull,
      );
    });
  });

  group('F2: frecuencia/profundidad conflictivas o ambiguas', () {
    QualityOption? match(String label, String requested, {String id = 'x'}) =>
        findEquivalentDownloadQualityOption([
          QualityOption(id: id, label: label),
        ], requested);

    test('control: opcion limpia equipara', () {
      expect(match('FLAC 24-bit 96kHz', 'flac_24bit_96khz')?.id, 'x');
      expect(match('FLAC 24-bit 44100 Hz', 'flac_24bit_44.1khz')?.id, 'x');
    });

    test('dos frecuencias en la opcion', () {
      expect(match('FLAC 24-bit 96kHz 192kHz', 'flac_24bit_96khz'), isNull);
    });

    test('dos profundidades en la opcion', () {
      expect(match('FLAC 24-bit 16-bit 96kHz', 'flac_24bit_96khz'), isNull);
    });

    test('frecuencia no soportada junto a una soportada es ambigua', () {
      expect(match('FLAC 24-bit 88.2kHz 96kHz', 'flac_24bit_96khz'), isNull);
    });

    test('profundidad no soportada junto a una soportada es ambigua', () {
      expect(match('FLAC 20-bit 24-bit 96kHz', 'flac_24bit_96khz'), isNull);
    });

    test('numero pegado no fabrica una frecuencia/profundidad soportada', () {
      expect(match('FLAC 24-bit 196kHz', 'flac_24bit_96khz'), isNull);
      expect(match('FLAC 124-bit 96kHz', 'flac_24bit_96khz'), isNull);
    });

    test('frecuencia o profundidad distinta entre solicitud y opcion', () {
      expect(match('FLAC 24-bit 44.1kHz', 'flac_24bit_96khz'), isNull);
      expect(match('FLAC 16-bit 96kHz', 'flac_24bit_96khz'), isNull);
    });

    test('solicitud con claims contradictorios', () {
      const options = [QualityOption(id: 'x', label: 'FLAC 24-bit 96kHz')];
      for (final requested in [
        'flac_16bit_24bit_96khz',
        'flac_24bit_96khz_192khz',
        'flac_24bit_88.2khz_96khz',
      ]) {
        expect(
          findEquivalentDownloadQualityOption(options, requested),
          isNull,
          reason: requested,
        );
      }
    });

    test('lossy con frecuencias conflictivas o distintas no equipara', () {
      expect(match('AAC 128 kbps 44.1kHz 48kHz', 'aac_128'), isNull);
      expect(match('AAC 128 kbps 16-bit 24-bit', 'aac_128'), isNull);
      expect(match('AAC 128 kbps 44.1kHz', 'aac_128_48khz'), isNull);
    });

    test('lossy: misma frecuencia o sin claim de frecuencia equipara', () {
      expect(match('AAC 128 kbps 44.1kHz', 'aac_128_44.1khz')?.id, 'x');
      expect(match('AAC 128 kbps 44.1kHz', 'aac_128')?.id, 'x');
    });
  });
}
