import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('real MOV decryption and AAC preparation stay private', () async {
    const key = '00112233445566778899aabbccddeeff'; // Synthetic fixture only.
    const keyId = 'ffeeddccbbaa99887766554433221100';
    final tools = await DesktopFFmpegTools.locate();
    expect(tools.ffmpegPath, isNotNull);
    debugDesktopPlatformOverride = true;
    DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
      tools: () async => tools,
    );
    final root = await Directory.systemTemp.createTemp('encrypted-opus-test-');
    addTearDown(() async {
      debugDesktopPlatformOverride = null;
      DesktopFFmpegRunner.debugShared = null;
      if (await root.exists()) await root.delete(recursive: true);
    });
    final fixture = p.join(root.path, 'encrypted.mp4');
    final generated = await Process.run(tools.ffmpegPath!, [
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:duration=1',
      '-c:a',
      'aac',
      '-encryption_scheme',
      'cenc-aes-ctr',
      '-encryption_key',
      key,
      '-encryption_kid',
      keyId,
      '-y',
      fixture,
    ]);
    expect(
      generated.exitCode,
      0,
      reason: 'Fixture generation failed: ${generated.stderr}',
    );
    final withoutKey = await Process.run(tools.ffmpegPath!, [
      '-v',
      'error',
      '-xerror',
      '-i',
      fixture,
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ]);
    expect(
      withoutKey.exitCode,
      isNot(0),
      reason: 'Fixture must require decryption',
    );
    final diagnostics = <String>[];
    final prints = <String>[];
    final preparer = TemporaryTrackPreparer.platform(
      stagingRoot: Directory(p.join(root.path, 'staging')),
      payload: (dir, id) => DownloadRequestPayload(
        trackName: 'fixture',
        artistName: '',
        albumName: '',
        outputDir: dir.path,
        filenameFormat: 'fixture',
        itemId: id,
      ),
      acquireDirectory: (_) async => 'fixture',
      releaseDirectory: (_) async {},
      transfer: (request) async {
        final target = File(p.join(request.outputDir, 'input.mp4'));
        await File(fixture).copy(target.path);
        return {
          'success': true,
          'file_path': target.path,
          'native_finalized': false,
          'decryption': {
            'strategy': 'ffmpeg.mov_key',
            'key': key,
            'input_format': 'mov',
            'output_extension': '.m4a',
          },
        };
      },
      cancelTransfer: (_) async {},
      diagnostic: diagnostics.add,
    );
    await runZoned(
      () async {
        final prepared = await preparer.prepare('fixture');
        try {
          expect(await FFmpegProbe.audioCodec(prepared.file.path), 'aac');
          final decoded = await Process.run(tools.ffmpegPath!, [
            '-v',
            'error',
            '-xerror',
            '-i',
            prepared.file.path,
            '-map',
            '0:a:0',
            '-f',
            'null',
            '-',
          ]);
          expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
        } finally {
          await prepared.dispose();
        }
      },
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => prints.add(line),
      ),
    );
    expect(diagnostics, isNotEmpty);
    expect('${diagnostics.join()} ${prints.join()}', isNot(contains(key)));
  }, timeout: const Timeout(Duration(seconds: 90)));
}
