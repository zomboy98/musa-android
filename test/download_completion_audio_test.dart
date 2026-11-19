import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_completion_audio.dart';

void main() {
  const backend = <String, dynamic>{
    'actual_bit_depth': 24,
    'actual_sample_rate': 96000,
    'audio_codec': 'flac',
    'bitrate': 900,
  };
  final warnings = <String>[];
  setUp(warnings.clear);

  Future<DownloadCompletionAudio> resolve({
    String path = '/music/track.flac',
    Map<String, dynamic> result = backend,
    Map<String, dynamic>? cached,
    required Future<Map<String, dynamic>> Function(String) probe,
  }) => resolveDownloadCompletionAudio(
    result: result,
    filePath: path,
    fileName: 'track.m4a',
    quality: 'requested quality',
    metadata: cached,
    readMetadata: probe,
    debug: warnings.add,
  );

  test('SAF completion reuses measured audio and tag scan metadata', () async {
    final metadata = <String, dynamic>{
      'bit_depth': '16',
      'sample_rate': 44100.0,
      'audio_codec': 'alac',
      'bit_rate': '256000',
      'hasLyrics': true,
      'replaygain_track_gain': '-2.1 dB',
    };
    final audio = await resolve(
      path: 'content://library/42',
      cached: metadata,
      probe: (_) async => fail('Cached SAF audio must not be copied again'),
    );
    expect(audio.metadata, same(metadata));
    expect(audio.bitDepth, 16);
    expect(audio.sampleRate, 44100);
    expect(audio.bitrate, 256);
    expect(audio.format, 'alac');
    expect(audio.quality, '16-bit/44.1kHz');
    expect(warnings, isEmpty);
  });

  test(
    'failed cache is replaced and lossy specs cannot enter history',
    () async {
      var reads = 0;
      final metadata = <String, dynamic>{
        'audio_codec': 'opus',
        'bit_depth': 32,
        'sample_rate': 48000,
        'bitrate': 192000,
        'lyrics': '',
      };
      final audio = await resolve(
        cached: {'error': 'temporary file missing'},
        probe: (path) async {
          expect(path, '/music/track.flac');
          reads++;
          return metadata;
        },
      );
      expect(reads, 1);
      expect(audio.metadata, same(metadata));
      expect(audio.bitDepth, isNull);
      expect(audio.sampleRate, isNull);
      expect(audio.bitrate, 192);
      expect(audio.format, 'opus');
      expect(audio.quality, 'OPUS 192kbps');
    },
  );

  test('invalid measured values do not inherit backend specs', () async {
    final audio = await resolve(
      probe: (_) async => {
        'bit_depth': 0,
        'sample_rate': '-1',
        'bitrate': '0',
        'audio_codec': 'unknown',
      },
    );
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
    expect(audio.bitrate, isNull);
    expect(audio.format, isNull);
    expect(audio.quality, isEmpty);
  });

  test('unverified extension protocol does not claim actual quality', () async {
    final audio = await resolve(
      result: {
        'actual_bit_depth': '24',
        'actual_sample_rate': 96000.0,
        'actual_audio_codec': 'alac',
        'actual_bitrate': '900000',
        'extension_context': {'opaque': 'kept'},
      },
      probe: (_) async => {'error': 'metadata unavailable'},
    );
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
    expect(audio.format, isNull);
    expect(audio.bitrate, isNull);
    expect(audio.quality, isEmpty);
  });

  for (final throws in [false, true]) {
    test(
      'probe failure leaves quality unknown and retains cache ($throws)',
      () async {
        final cached = <String, dynamic>{'error': 'old probe failed'};
        final audio = await resolve(
          cached: cached,
          probe: (_) async {
            if (throws) throw StateError('metadata unavailable');
            return {'error': 'metadata unavailable'};
          },
        );
        expect(audio.metadata, same(cached));
        expect(audio.bitDepth, isNull);
        expect(audio.sampleRate, isNull);
        expect(audio.bitrate, isNull);
        expect(audio.quality, isEmpty);
        expect(warnings, throws ? hasLength(1) : isEmpty);
      },
    );
  }

  test('unsupported local output skips final audio probing', () async {
    final audio = await resolve(
      path: '/music/track.xyz',
      result: {},
      probe: (_) async => fail('Unsupported path must not trigger a probe'),
    );
    expect(audio.format, isNull);
    expect(audio.metadata, isNull);
    expect(audio.quality, isEmpty);
  });

  test('failed probe does not report requested quality as actual', () async {
    final audio = await resolve(
      path: '/music/track.m4a',
      result: {},
      probe: (_) async => {'error': 'metadata unavailable'},
    );
    expect(audio.quality, isEmpty);
  });

  test('different measured codec cannot inherit backend bitrate', () async {
    final audio = await resolve(
      path: '/music/track.m4a',
      probe: (_) async => {'audio_codec': 'aac'},
    );
    expect(audio.format, 'aac');
    expect(audio.bitrate, isNull);
    expect(audio.quality, 'AAC');
  });

  for (final extension in ['wav', 'aif', 'aiff', 'alac']) {
    test('probes local $extension audio', () async {
      var called = false;
      final audio = await resolve(
        path: '/music/track.$extension',
        probe: (_) async {
          called = true;
          return {'format': 'alac', 'bit_depth': 16, 'sample_rate': 44100};
        },
      );
      expect(called, isTrue);
      expect(audio.quality, '16-bit/44.1kHz');
    });
  }

  test('unknown codec falls back to measured format', () async {
    final audio = await resolve(
      path: 'content://library/42',
      probe: (_) async => {
        'audio_codec': 'unknown',
        'format': 'opus',
        'bitrate': 128000,
      },
    );
    expect(audio.format, 'opus');
    expect(audio.quality, 'OPUS 128kbps');
  });

  test('lossy path clears depth before quality is calculated', () async {
    final audio = await resolve(
      path: '/music/track.mp3',
      probe: (_) async => {'bit_depth': 16, 'sample_rate': 44100},
    );
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
    expect(audio.quality, isEmpty);
  });

  for (final container in ['ogg', 'm4a']) {
    test(
      '$container container without codec does not assert audio quality',
      () async {
        final audio = await resolve(
          path: '/music/track.$container',
          probe: (_) async => {
            'format': container,
            'bit_depth': 16,
            'sample_rate': 44100,
            'bitrate': 128000,
          },
        );
        expect(audio.format, isNull);
        expect(audio.bitDepth, isNull);
        expect(audio.sampleRate, isNull);
        expect(audio.quality, isEmpty);
      },
    );
  }

  test('Ogg with measured FLAC codec retains lossless specs', () async {
    final audio = await resolve(
      path: '/music/track.ogg',
      probe: (_) async => {
        'audio_codec': 'flac',
        'format': 'ogg',
        'bit_depth': 16,
        'sample_rate': 44100,
      },
    );
    expect(audio.format, 'flac');
    expect(audio.quality, '16-bit/44.1kHz');
  });

  test('lossy filename suppresses stale lossless backend specs', () async {
    final audio = await resolve(
      path: '/music/track.MP3',
      probe: (_) async => {'error': 'metadata unavailable'},
    );
    expect(audio.bitDepth, isNull);
    expect(audio.sampleRate, isNull);
    expect(audio.bitrate, isNull);
  });
}
