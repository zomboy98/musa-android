import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;

import 'support/music_player_automix_harness.dart';

void main() {
  setUpMusicPlayerHarness();

  test(
    'player settings select the provider used for the cache variant',
    () async {
      const track = Track(
        id: 'provider-fixture',
        source: 'spotify',
        name: 'Fixture',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      final root = await Directory.systemTemp.createTemp(
        'catalog-provider-fixture-',
      );
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      var transfers = 0;
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer(
          stagingRoot: Directory(p.join(root.path, 'staging')),
          download: (directory, _) {
            transfers++;
            return File(
              p.join(directory.path, 'input'),
            ).writeAsString('fixture');
          },
          takeQualityMetadata: (_) => {'provider': 'fixture-provider'},
          cancelDownload: (_) async {},
          codec: (_) async => 'aac', container: (_) async => 'mp4',
          validate: (_) async => true,
        ),
      )..defaultService = 'fixture-provider';
      final originalSettings = musicPlayerRuntime.settings;
      musicPlayerRuntime.configure(
        originalSettings.copyWith(defaultService: ''),
      );
      addTearDown(() => musicPlayerRuntime.configure(originalSettings));
      await handler.dispose();
      handler = MusicPlayerHandler(
        catalogPlaybackOverride: playback,
        probeCatalogAudio: (_) async =>
            const PrimaryAudioProperties(codec: 'aac'),
      );
      await BugLog.instance.clear();
      await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
      final events = (await BugLog.instance.entries())
          .where((row) => row['type'] == 'TemporaryPipelineOutcome');
      expect(events.single['frames'],
          'stage_playback, provider_unknown, outcome_ready');
      expect(events.toString(), isNot(contains(track.id)));
      expect(events.toString(), isNot(contains(root.path)));
      expect(playback.defaultService, '');
      final priorVariant = jsonEncode([
        'catalog-audio-v5',
        playback.key(track),
        128,
        'ac4',
        '',
        true,
      ]);
      expect(await store.lookup(priorVariant), isNotNull);
      musicPlayerRuntime.configure(
        originalSettings.copyWith(defaultService: 'fixture-provider'),
      );
      await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
      expect(playback.defaultService, 'fixture-provider');
      final variant = jsonEncode([
        'catalog-audio-v5',
        playback.key(track),
        128,
        'ac4',
        'fixture-provider',
        true,
      ]);
      expect(await store.lookup(variant), isNotNull);
      await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
      expect(transfers, 2);
      await BugLog.instance.clear();
      native.failResumeMethod = true;
      await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
      final failures = (await BugLog.instance.entries())
          .where((row) => row['type'] == 'TemporaryPipelineOutcome');
      expect(failures.single['frames'],
          'stage_playback, provider_unknown, outcome_failed');
      expect(failures.toString(), isNot(contains(root.path)));
      await handler.dispose();
    },
  );

  for (final includeProvider in [true, false]) {
    test(
      'catalog queue prepares encrypted audio with ${includeProvider ? 'confirmed' : 'unknown'} provider',
      () async {
        const key = '00112233445566778899aabbccddeeff';
        const keyId = 'ffeeddccbbaa99887766554433221100';
        const first = Track(
          id: 'one',
          source: 'spotify',
          name: 'One',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 2,
        );
        const second = Track(
          id: 'two',
          source: 'spotify',
          name: 'Two',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 2,
        );
        final tools = await DesktopFFmpegTools.locate();
        expect(tools.ffmpegPath, isNotNull);
        final root = await Directory.systemTemp.createTemp('catalog-pipeline-');
        debugDesktopPlatformOverride = true;
        DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
          tools: () async => tools,
        );
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
          'sine=frequency=440:duration=2',
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
        expect(generated.exitCode, 0, reason: '${generated.stderr}');
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
        expect(withoutKey.exitCode, isNot(0));
        final store = CatalogAudioStore(
          cacheDirectory: Directory(p.join(root.path, 'cache')),
          libraryDirectory: Directory(p.join(root.path, 'library')),
        );
        await store.initialize();
        final transfers = <String>[];
        final playback = CatalogPlayback(
          storage: store,
          savedLookup: (_) async => false,
          preparerFactory: (track) => TemporaryTrackPreparer.platform(
            stagingRoot: Directory(p.join(root.path, 'staging')),
            payload: (dir, id) => DownloadRequestPayload(
              trackName: track.name,
              artistName: track.artistName,
              albumName: track.albumName,
              outputDir: dir.path,
              filenameFormat: 'fixture',
              itemId: id,
            ),
            acquireDirectory: (_) async => 'fixture',
            releaseDirectory: (_) async {},
            transfer: (request) async {
              transfers.add(track.id);
              final input = File(p.join(request.outputDir, 'input.mp4'));
              await File(fixture).copy(input.path);
              return {
                'success': true,
                'file_path': input.path,
                'native_finalized': false,
                if (includeProvider) 'provider': 'fixture-provider',
                'decryption': {
                  'strategy': 'ffmpeg.mov_key',
                  'key': key,
                  'input_format': 'mov',
                  'output_extension': '.m4a',
                },
              };
            },
            cancelTransfer: (_) async {},
          ),
        );
        final originalSettings = musicPlayerRuntime.settings;
        musicPlayerRuntime.configure(
          originalSettings.copyWith(defaultService: 'fixture-provider'),
        );
        addTearDown(() => musicPlayerRuntime.configure(originalSettings));
        await handler.dispose();
        handler = MusicPlayerHandler(catalogPlaybackOverride: playback);
        await handler.setQueueAndPlay([
          playableFromCatalogTrack(first),
          playableFromCatalogTrack(second),
        ]);
        String variant(Track track) => jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          128,
          'ac4',
          'fixture-provider',
          true,
        ]);
        final entry = (await store.lookup(variant(first)))!;
        expect(
          entry.qualityMetadata['provider'],
          includeProvider ? 'fixture-provider' : isNull,
        );
        expect(entry.path, endsWith('.m4a'));
        expect(await FFmpegProbe.audioCodec(entry.path), 'aac');
        expect((await File(entry.path).readAsBytes()).skip(4).take(4), [
          102,
          116,
          121,
          112,
        ]);
        final decoded = await Process.run(tools.ffmpegPath!, [
          '-v',
          'error',
          '-xerror',
          '-i',
          entry.path,
          '-map',
          '0:a:0',
          '-f',
          'null',
          '-',
        ]);
        expect(decoded.exitCode, 0, reason: '${decoded.stderr}');
        expect(transfers, ['one']);
        expect(await store.lookup(variant(second)), isNull);
        expect(handler.playbackState.value.playing, isTrue);
        expect(native.sources.values, contains(entry.path));
        await handler.seek(const Duration(milliseconds: 500));
        expect(
          handler.playbackState.value.updatePosition,
          const Duration(milliseconds: 500),
        );
        await handler.pause();
        expect(handler.playbackState.value.playing, isFalse);
        await handler.play();
        expect(handler.playbackState.value.playing, isTrue);
        await handler.setQueueAndPlay([
          playableFromCatalogTrack(first),
          playableFromCatalogTrack(second),
        ]);
        expect(transfers, includeProvider ? ['one'] : ['one', 'one']);
        await handler.skipToNext();
        expect(handler.playbackState.value.queueIndex, 1);
        expect(
          transfers,
          includeProvider ? ['one', 'two'] : ['one', 'one', 'two'],
        );
        expect(await store.lookup(variant(second)), isNotNull);
        await handler.dispose();
      },
      timeout: const Timeout(Duration(seconds: 90)),
    );
  }
}
