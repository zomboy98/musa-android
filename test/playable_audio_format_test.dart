import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/utils/playable_audio_format.dart';

void main() {
  test('accepts every common audio codec and container', () {
    const cases = <(String, String, String)>[
      ('aac', 'mp4', '.m4a'),
      ('alac', 'mp4', '.m4a'),
      ('eac3', 'mp4', '.m4a'),
      ('eac3', 'eac3', '.eac3'),
      ('ac3', 'ac3', '.ac3'),
      ('ac4', 'mp4', '.m4a'),
      ('opus', 'ogg', '.opus'),
      ('vorbis', 'ogg', '.ogg'),
      ('flac', 'flac', '.flac'),
      ('mp3', 'mp3', '.mp3'),
      ('pcm_s24le', 'wav', '.wav'),
      ('pcm_s16be', 'aiff', '.aiff'),
      ('alac', 'caf', '.caf'),
      ('wmav2', 'asf', '.wma'),
      ('ape', 'ape', '.ape'),
      ('wavpack', 'wv', '.wv'),
      ('dsd_lsbf_planar', 'dsf', '.dsf'),
      ('opus', 'matroska,webm', '.mka'),
      ('aac', 'mpegts', '.ts'),
      ('amr_nb', 'amr', '.amr'),
      ('aac', 'mov', '.mov'),
    ];
    for (final c in cases) {
      expect(playableAudioExtension(c.$1, c.$2), c.$3, reason: '${c.$1}/${c.$2}');
    }
  });

  test('unknown codec or container still gets an extension to try', () {
    expect(playableAudioExtension('truehd', 'unknownfmt'), '.truehd');
    expect(playableAudioExtension('', 'weirdfmt'), '.weirdfmt');
  });

  test('only a completely empty description has no extension', () {
    expect(playableAudioExtension('', ''), isNull);
    expect(playableAudioExtension(null, null), isNull);
  });
}
