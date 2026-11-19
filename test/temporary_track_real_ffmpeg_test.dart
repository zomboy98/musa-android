import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'real desktop backend prepares and stores generated PCM as AAC in M4A',
    () async {
      final tools = await DesktopFFmpegTools.locate();
      expect(tools.ffmpegPath, isNotNull);
      expect(tools.ffprobePath, isNotNull);
      debugDesktopPlatformOverride = true;
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        tools: () async => tools,
      );
      final root = await Directory.systemTemp.createTemp('musa-opus-real-');
      addTearDown(() async {
        debugDesktopPlatformOverride = null;
        DesktopFFmpegRunner.debugShared = null;
        await root.delete(recursive: true);
      });
      final preparer = TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) async {
          const samples = 8000;
          final data = ByteData(44 + samples * 2);
          void ascii(int at, String text) {
            for (var i = 0; i < text.length; i++) {
              data.setUint8(at + i, text.codeUnitAt(i));
            }
          }

          ascii(0, 'RIFF');
          data.setUint32(4, 36 + samples * 2, Endian.little);
          ascii(8, 'WAVE');
          ascii(12, 'fmt ');
          data.setUint32(16, 16, Endian.little);
          data.setUint16(20, 1, Endian.little);
          data.setUint16(22, 1, Endian.little);
          data.setUint32(24, 8000, Endian.little);
          data.setUint32(28, 16000, Endian.little);
          data.setUint16(32, 2, Endian.little);
          data.setUint16(34, 16, Endian.little);
          ascii(36, 'data');
          data.setUint32(40, samples * 2, Endian.little);
          final file = File('${dir.path}/synthetic.wav');
          return file.writeAsBytes(data.buffer.asUint8List());
        },
        cancelDownload: (_) async {},
      );
      final prepared = await preparer.prepare('fixture');
      expect(await FFmpegProbe.audioCodec(prepared.file.path), 'aac');
      final profile = await Process.run(tools.ffprobePath!, [
        '-v',
        'error',
        '-select_streams',
        'a:0',
        '-show_entries',
        'stream=profile',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        prepared.file.path,
      ]);
      expect(profile.exitCode, 0);
      expect('${profile.stdout}'.trim(), 'LC');
      expect((await prepared.file.readAsBytes()).skip(4).take(4), [
        102,
        116,
        121,
        112,
      ]);
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final stored = await store.putTemporary(
        'fixture',
        prepared.file,
        extension: '.m4a',
      );
      await prepared.dispose();
      expect(await File(stored.path).exists(), isTrue);
      expect((await store.lookup('fixture'))?.path, stored.path);
      expect(await FFmpegProbe.audioCodec(stored.path), 'aac');
      final lease = await store.acquire('fixture');
      expect(lease?.path, stored.path);
      expect(await store.clearTemporary(), 0);
      await lease!.release();
      expect(await store.clearTemporary(), 1);
      expect(await File(stored.path).exists(), isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
