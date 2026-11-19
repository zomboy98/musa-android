import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/services/ffmpeg_conversion.dart';
import 'package:mornye/services/ffmpeg_models.dart';

void main() {
  test('retired conversion keys in saved settings are ignored and dropped', () {
    final settings = AppSettings.fromJson({
      'autoConvertDownloads': true,
      'autoConvertFormat': 'opus',
      'hasSearchedBefore': true,
      'lastSeenVersion': '1.0.0',
      'pauseOnMute': true,
      'askQualityBeforeDownload': false,
    });
    final json = settings.toJson();
    for (final key in const [
      'autoConvertDownloads',
      'autoConvertFormat',
      'autoConvertBitrate',
      'autoConvertMaxBitDepth',
      'autoConvertMaxSampleRate',
      'hasSearchedBefore',
      'lastSeenVersion',
      'pauseOnMute',
      'askQualityBeforeDownload',
    ]) {
      expect(json.containsKey(key), isFalse, reason: key);
    }
  });

  test('preservation mode rejects ALAC encoding and keeps source', () async {
    final dir = await Directory.systemTemp.createTemp('preserve-audio-');
    addTearDown(() => dir.delete(recursive: true));
    final source = await File('${dir.path}/track.m4a').writeAsString('source');
    var invoked = false;
    final output = await FFmpegConversion.convertM4aToFlac(
      source.path,
      sourceCodec: 'alac',
      preserveAudio: true,
      execute: (_) async {
        invoked = true;
        return FFmpegResult(success: true, returnCode: 0, output: '');
      },
    );
    expect(output, isNull);
    expect(invoked, isFalse);
    expect(await source.readAsString(), 'source');
  });

  test('preservation mode never encodes after FLAC remux failure', () async {
    final dir = await Directory.systemTemp.createTemp('preserve-audio-');
    addTearDown(() => dir.delete(recursive: true));
    final source = await File('${dir.path}/track.m4a').writeAsString('source');
    final commands = <List<String>>[];
    final output = await FFmpegConversion.convertM4aToFlac(
      source.path,
      sourceCodec: 'flac',
      preserveAudio: true,
      execute: (args) async {
        commands.add(args);
        return FFmpegResult(success: false, returnCode: 1, output: '');
      },
    );
    expect(output, isNull);
    expect(commands, hasLength(1));
    expect(commands.single, containsAllInOrder(['-c:a', 'copy']));
    expect(await source.readAsString(), 'source');
  });
}
