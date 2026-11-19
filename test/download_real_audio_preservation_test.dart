import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_result.dart';
import 'package:mornye/services/download_container_finalizer.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_models.dart';
import 'package:mornye/services/ffmpeg_probe.dart';

// Requires a local ffmpeg executable with FLAC and MP4 support. No network or
// platform FFmpeg plugin is used; the production Dart finalizers are exercised.
void main() {
  test('FLAC in MP4 is remuxed without changing encoded audio packets', () async {
    final dir = await Directory.systemTemp.createTemp('musa-remux-real-');
    addTearDown(() => dir.delete(recursive: true));
    final source = '${dir.path}/track.m4a';
    final before = '${dir.path}/before.bin';
    final after = '${dir.path}/after.bin';
    Future<void> ffmpeg(List<String> args) async {
      final result = await Process.run('ffmpeg', ['-v', 'error', ...args]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    await ffmpeg(['-f', 'lavfi', '-i', 'sine=frequency=440:duration=1',
      '-c:a', 'flac', '-strict', '-2', '-f', 'mp4', source, '-y']);
    await ffmpeg(['-i', source, '-map', '0:a:0', '-c:a', 'copy',
      '-f', 'data', before, '-y']);
    final commands = <List<String>>[];
    final stage = DownloadContainerFinalizer(
      probeCodec: (_) async => 'flac',
      isNativeFlac: FFmpegProbe.isNativeFlacFile,
      ensureFlacExtension: FFmpegConversion.ensureNativeFlacExtension,
      convertToFlac: (path) => FFmpegConversion.convertM4aToFlac(
        path, sourceCodec: 'flac', preserveAudio: true,
        execute: (args) async {
          commands.add(List.of(args));
          final result = await Process.run('ffmpeg', args);
          return FFmpegResult(success: result.exitCode == 0,
            returnCode: result.exitCode, output: '${result.stderr}');
        },
      ),
      replaceSafFile: ({required uri, required treeUri, required relativeDir,
        required op, avoidOverwrite = false, onPublishedFileName}) async =>
          throw StateError('Unexpected SAF access'),
      debug: (_) {},
    );
    final result = DownloadResult.fromMap({'file_name': 'track.m4a'});
    final output = await stage.finalize(result: result, filePath: source,
      requestedExtension: '.flac', forceConversion: false, useSaf: false);
    expect(output, isNotNull);
    expect(output, endsWith('.flac'));
    expect(commands, hasLength(2));
    expect(commands.first, containsAllInOrder(['-c:a', 'copy']));
    expect(commands.last, containsAllInOrder(['-f', 'null']));
    await ffmpeg(['-i', output!, '-map', '0:a:0', '-c:a', 'copy',
      '-f', 'data', after, '-y']);
    final originalPackets = await File(before).readAsBytes();
    expect(originalPackets, isNotEmpty);
    expect(await File(after).readAsBytes(), orderedEquals(originalPackets));
    expect(result.outputExtension(), '.flac');
  });
}

