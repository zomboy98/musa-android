import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/utils/streaming_quality_notice.dart';

Extension _provider(String id, List<(String, String)> options) => Extension(
  id: id,
  name: id,
  displayName: id,
  version: '1',
  description: '',
  enabled: true,
  status: 'loaded',
  hasDownloadProvider: true,
  qualityOptions: [
    for (final o in options) QualityOption(id: o.$1, label: o.$1, kind: o.$2),
  ],
);

final _amazon = _provider('amazon', [
  ('best', 'lossless'),
  ('opus', 'lossy'),
  ('eac3', 'spatial'),
  ('ac4', 'spatial'),
]);
final _tidal = _provider('tidal-web', [
  ('DOLBY_ATMOS', 'spatial'),
  ('LOSSLESS', 'lossless'),
  ('HIGH', 'lossy'),
]);

void main() {
  group('pedido de streaming', () {
    test('AC-4 se pide tal cual al proveedor elegido', () {
      final request = resolveStreamingRequest(
        settingsQuality: 'ac4',
        selectedServiceId: 'amazon',
        extensions: [_tidal, _amazon],
      );
      expect(request.serviceId, 'amazon');
      expect(request.qualityId, 'ac4');
      expect(request.slower, isTrue);
    });

    test('el id explícito no se traduce a best', () {
      final request = resolveStreamingRequest(
        settingsQuality: 'ac4',
        selectedServiceId: 'amazon',
        extensions: [_amazon],
        autoFallback: false,
      );
      expect(request.qualityId, 'ac4');
    });
  });

  group('aviso de relevo', () {
    test('pedido AC-4 que llega en FLAC avisa', () {
      final notice = streamingQualityNotice(
        requestedQuality: 'ac4',
        metadata: {
          'output_codec': 'flac',
          'resolved_quality': 'best',
          'quality_fallback_used': true,
        },
      );
      expect(notice?.requested, 'AC-4');
      expect(notice?.actual, 'FLAC');
    });

    test('espacial perdido avisa aunque falte la marca de relevo', () {
      final notice = streamingQualityNotice(
        requestedQuality: 'eac3',
        metadata: {'output_codec': 'flac'},
      );
      expect(notice?.requested, 'E-AC-3');
    });

    test('AC-4 entregado como AC-4 no avisa', () {
      expect(
        streamingQualityNotice(
          requestedQuality: 'ac4',
          metadata: {'output_codec': 'ac4', 'resolved_quality': 'ac4'},
        ),
        isNull,
      );
    });

    test('modo automático y lossless entregado como FLAC no avisan', () {
      expect(
        streamingQualityNotice(
          requestedQuality: autoLightStreamingQuality,
          metadata: {'output_codec': 'flac', 'quality_fallback_used': true},
        ),
        isNull,
      );
      expect(
        streamingQualityNotice(
          requestedQuality: 'LOSSLESS',
          metadata: {'output_codec': 'flac'},
        ),
        isNull,
      );
    });
  });

  group('aviso y marca coinciden', () {
    StreamingQualityNotice? notice({
      required String codec,
      String resolved = 'best',
      int? bits,
      int? rate,
      String provider = 'ytmusic',
      String chosen = 'ytmusic',
    }) => streamingQualityNotice(
      requestedQuality: 'DOLBY_ATMOS',
      metadata: {
        'output_codec': codec,
        'resolved_quality': resolved,
        'provider': provider,
      },
      chosenService: chosen,
      bitDepth: bits,
      sampleRate: rate,
    );

    test('FLAC 16/44.1 se nombra FLAC como la insignia', () {
      final n = notice(codec: 'flac', bits: 16, rate: 44100)!;
      expect(n.actualMark, QualityMark.flac);
      expect(n.actual, 'FLAC');
      expect(n.needsFileFacts, isFalse);
    });

    test('FLAC 24/48 se nombra Hi-Res 24-bit como la insignia', () {
      final n = notice(codec: 'flac', bits: 24, rate: 48000)!;
      expect(n.actualMark, QualityMark.hiRes);
      expect(n.actual, 'Hi-Res 24-bit');
      expect(
        n.actualMark,
        verifiedQualityMark(
          declared: qualityMarkFor('', 'best'),
          codec: 'flac',
          sampleRate: 48000,
          bitDepth: 24,
        ),
      );
    });

    test('FLAC sin bits conocidos pide verificar el archivo', () {
      expect(notice(codec: 'flac')!.needsFileFacts, isTrue);
    });

    test('AAC y Opus coinciden con su marca', () {
      final aac = notice(codec: 'aac', resolved: 'aac_160')!;
      expect(aac.actualMark, QualityMark.aac);
      expect(aac.actual, 'AAC');
      expect(aac.needsFileFacts, isFalse);
      final opus = notice(codec: 'opus', resolved: 'opus')!;
      expect(opus.actualMark, QualityMark.opus);
      expect(opus.actual, 'Opus');
    });

    test('incluye el proveedor solo cuando cambió', () {
      final moved = notice(
        codec: 'flac',
        bits: 24,
        rate: 48000,
        provider: 'tidal-web',
      )!;
      expect(moved.requested, 'Dolby Atmos');
      expect(moved.requestedLabel, 'Dolby Atmos (YouTube Music)');
      expect(moved.actualLabel(), 'Hi-Res 24-bit (Tidal)');
      final same = notice(codec: 'flac', bits: 24, rate: 48000)!;
      expect(same.requestedLabel, 'Dolby Atmos');
      expect(same.actualLabel(), 'Hi-Res 24-bit');
    });
  });

  group('insignia verificada', () {
    test('FLAC 24/48 con declared atmos es Hi-Res, no Atmos', () {
      expect(
        verifiedQualityMark(
          declared: QualityMark.atmos,
          codec: 'flac',
          sampleRate: 48000,
          bitDepth: 24,
        ),
        QualityMark.hiRes,
      );
    });

    test('E-AC-3 verificado es Dolby Digital Plus', () {
      expect(
        verifiedQualityMark(declared: QualityMark.lossy, codec: 'eac3'),
        QualityMark.dolbyPlus,
      );
    });

    test('etiqueta Atmos con códec real flac, aac u opus no es Atmos', () {
      for (final codec in ['flac', 'aac', 'opus', 'mp3', 'unknown']) {
        expect(
          verifiedQualityMark(declared: QualityMark.atmos, codec: codec),
          isNot(QualityMark.atmos),
          reason: codec,
        );
      }
    });
  });
}
