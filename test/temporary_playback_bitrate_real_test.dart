import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real FFmpeg uses the selected AAC output bitrate', () async {
    final tools = await DesktopFFmpegTools.locate();
    expect(tools.ffmpegPath, isNotNull);
    expect(tools.ffprobePath, isNotNull);
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => tools,
    );
    final root = await Directory.systemTemp.createTemp('musa-aac-profile-');
    addTearDown(() async {
      debugDesktopPlatformOverride = null;
      DesktopFFmpegRunner.debugShared = null;
      await root.delete(recursive: true);
    });

    // Deterministic stereo noise avoids a silent or narrow-band signal causing
    // AAC to use dramatically less than the requested average bitrate.
    final random = Random(42);
    const samples = 44100 * 4;
    final wav = ByteData(44 + samples * 4);
    void ascii(int offset, String value) {
      for (var i = 0; i < value.length; i++) {
        wav.setUint8(offset + i, value.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    wav.setUint32(4, 36 + samples * 4, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    wav.setUint32(16, 16, Endian.little);
    wav.setUint16(20, 1, Endian.little);
    wav.setUint16(22, 2, Endian.little);
    wav.setUint32(24, 44100, Endian.little);
    wav.setUint32(28, 44100 * 4, Endian.little);
    wav.setUint16(32, 4, Endian.little);
    wav.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    wav.setUint32(40, samples * 4, Endian.little);
    for (var i = 0; i < samples * 2; i++) {
      wav.setInt16(44 + i * 2, random.nextInt(65536) - 32768, Endian.little);
    }

    final measured = <int, int>{};
    for (final bitrate in [96, 128, 192, 256]) {
      final preparer = TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        bitrateKbps: bitrate,
        download: (dir, _) => File(
          '${dir.path}/source.wav',
        ).writeAsBytes(wav.buffer.asUint8List()),
        cancelDownload: (_) async {},
      );
      final prepared = await preparer.prepare('track');
      try {
        final probe = await Process.run(tools.ffprobePath!, [
          '-v',
          'error',
          '-select_streams',
          'a:0',
          '-show_entries',
          'stream=codec_name,bit_rate',
          '-of',
          'default=noprint_wrappers=1',
          prepared.file.path,
        ]);
        expect(probe.exitCode, 0, reason: '${probe.stderr}');
        expect('${probe.stdout}', contains('codec_name=aac'));
        final match = RegExp(r'bit_rate=(\d+)').firstMatch('${probe.stdout}');
        expect(match, isNotNull);
        measured[bitrate] = int.parse(match!.group(1)!);
        expect(measured[bitrate]!, greaterThan(bitrate * 700));
        expect(measured[bitrate]!, lessThan(bitrate * 1300));
      } finally {
        await prepared.dispose();
      }
    }
    expect(measured[256]!, greaterThan(measured[96]!));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
