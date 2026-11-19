import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;

void main() {
  test('legacy bitrate does not block or alter original audio', () async {
    final root = await Directory.systemTemp.createTemp('preserve-bitrate-');
    addTearDown(() async => root.delete(recursive: true));
    final bytes = [1, 2, 3, 4];
    var converted = false;
    final preparer = TemporaryTrackPreparer(
      stagingRoot: root,
      bitrateKbps: 320,
      download: (dir, _) => File(p.join(dir.path, 'source.mp3')).writeAsBytes(bytes),
      cancelDownload: (_) async {},
      codec: (_) async => 'mp3',
      container: (_) async => 'mp3',
      validate: (_) async => true,
    );
    final result = await preparer.prepare('track');
    expect(await result.file.readAsBytes(), bytes);
    expect(converted, isFalse);
    await result.dispose();
  });

  test('a forged WAV header cannot redirect the restricted probe to HTTP', () async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final root = await Directory.systemTemp.createTemp('probe-forged-');
    addTearDown(() async => root.delete(recursive: true));
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    server.listen((request) { requests++; request.response.close(); });
    final preparer = TemporaryTrackPreparer(
      stagingRoot: root,
      download: (dir, _) => File(p.join(dir.path, 'source')).writeAsBytes([
        ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits,
        ...'#EXTM3U\nhttp://127.0.0.1:${server.port}/payload\n'.codeUnits,
      ]),
      cancelDownload: (_) async {},
    );
    await expectLater(preparer.prepare('forged'), throwsA(isA<TemporaryTrackException>()));
    expect(requests, 0);
  });

  test('rejects failed decode without converting', () async {
    final root = await Directory.systemTemp.createTemp('preserve-reject-');
    addTearDown(() async => root.delete(recursive: true));
    for (final mismatch in [true, false]) {
      var converted = false;
      final preparer = TemporaryTrackPreparer(
        stagingRoot: root,
        download: (dir, _) => File(p.join(dir.path, 'source')).writeAsString('bad'),
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => mismatch ? 'ogg' : 'mp4',
        validate: (_) async => false,
      );
      await expectLater(preparer.prepare('bad'), throwsA(
        isA<TemporaryTrackException>().having((e) => e.reason, 'reason',
          'invalid audio output')));
      expect(converted, isFalse);
      expect((await root.list().toList()).whereType<Directory>(), isEmpty);
    }
  });

  test('desktop FFmpeg validates real formats and preserves encoded bytes', () async {
    debugDesktopPlatformOverride = true;
    addTearDown(() => debugDesktopPlatformOverride = null);
    final root = await Directory.systemTemp.createTemp('preserve-real-');
    addTearDown(() async => root.delete(recursive: true));
    for (final f in [
      ('aac', 'mp4', 'm4a'), ('libopus', 'ogg', 'opus'),
      ('flac', 'flac', 'flac'), ('libmp3lame', 'mp3', 'mp3'),
      ('pcm_s16le', 'wav', 'wav'), ('pcm_s24le', 'wav', 'wav'),
      ('pcm_s32le', 'wav', 'wav'), ('pcm_f32le', 'wav', 'wav'),
      ('libvorbis', 'ogg', 'ogg'),
    ]) {
      final source = File(p.join(root.path, 'fixture.${f.$3}'));
      final generated = await Process.run('ffmpeg', [
        '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2',
        '-c:a', f.$1, '-f', f.$2, '-y', source.path,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final preparer = TemporaryTrackPreparer(
        stagingRoot: Directory(p.join(root.path, 'staging')),
        download: (dir, _) => source.copy(p.join(dir.path, 'source.${f.$3}')),
        cancelDownload: (_) async {},
      );
      final result = await preparer.prepare(f.$3);
      expect(await result.file.readAsBytes(), await source.readAsBytes());
      if (f.$2 == 'wav') expect(result.qualityMetadata['output_codec'], f.$1);
      await result.dispose();
    }
    final quicktime = File(p.join(root.path, 'quicktime.mov'));
    final generated = await Process.run('ffmpeg', [
      '-v', 'error', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2',
      '-c:a', 'aac', '-f', 'mov', '-y', quicktime.path,
    ]);
    expect(generated.exitCode, 0, reason: '${generated.stderr}');
    final accepted = TemporaryTrackPreparer(
      stagingRoot: Directory(p.join(root.path, 'staging')),
      download: (dir, _) => quicktime.copy(p.join(dir.path, 'source')),
      cancelDownload: (_) async {},
    );
    final prepared = await accepted.prepare('mov');
    expect(p.extension(prepared.file.path), '.mov');
    await prepared.dispose();
  });
  for (final format in [
    ('aac', 'mp4', '.m4a'),
    ('opus', 'ogg', '.opus'),
    ('flac', 'flac', '.flac'),
    ('mp3', 'mp3', '.mp3'),
  ]) {
    test('preserves ${format.$1} in ${format.$2} byte for byte', () async {
      final root = await Directory.systemTemp.createTemp('preserve-test-');
      addTearDown(() async => root.delete(recursive: true));
      final bytes = [0, 1, 2, 127, 128, 255];
      var conversions = 0;
      final preparer = TemporaryTrackPreparer(
        stagingRoot: root,
        download: (dir, _) => File(p.join(dir.path, 'source${format.$3}'))
            .writeAsBytes(bytes),
        cancelDownload: (_) async {},
        codec: (_) async => format.$1,
        container: (_) async => format.$2,
        validate: (_) async => true,
      );
      final result = await preparer.prepare('track');
      expect(await result.file.readAsBytes(), bytes);
      expect(p.extension(result.file.path), format.$3);
      expect(conversions, 0);
      expect(result.qualityMetadata['output_codec'], format.$1);
      expect(result.qualityMetadata['output_container'], format.$2);
      await result.dispose();
    });
  }
}
