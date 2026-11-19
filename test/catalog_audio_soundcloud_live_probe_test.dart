import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/bug_log.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // Run this file in its own Flutter test process with MORNYE_DESKTOP_LIB set:
  // the native backend initializes once per process and must not inherit an
  // earlier backend's directories or network settings.
  final enabled =
      Platform.environment['MUSA_SOUNDCLOUD_LIVE_PROBE'] == '1' &&
      (Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
          false);
  test(
    'public CC BY SoundCloud track uses real provider',
    () async {
      SharedPreferences.setMockInitialValues({});
      final bugLog = BugLog(preferences: SharedPreferences.getInstance);
      final root = await Directory.systemTemp.createTemp('musa-real-http-');
      addTearDown(() async {
        if (await root.exists()) await root.delete(recursive: true);
      });
      final tools = await DesktopFFmpegTools.locate();
      expect(tools.ffmpegPath, isNotNull);
      expect(tools.ffprobePath, isNotNull);
      debugDesktopPlatformOverride = true;
      addTearDown(() => debugDesktopPlatformOverride = null);
      DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
        tools: () async => tools,
      );
      addTearDown(() => DesktopFFmpegRunner.debugShared = null);
      RustFfiBackend.debugShared = RustFfiBackend(
        openTransport: FfiBackendTransport.open,
        loadConfig: () async => DesktopBackendConfig(
          appSupportDir: root.path,
          documentsDir: root.path,
          tempDir: root.path,
          ffmpegPath: tools.ffmpegPath,
          ffprobePath: tools.ffprobePath,
        ),
      );
      addTearDown(() => RustFfiBackend.debugShared = null);
      final sources = Directory(p.join(root.path, 'sources'));
      final ext = await Directory(
        p.join(sources.path, 'soundcloud'),
      ).create(recursive: true);
      final data = await Directory(p.join(root.path, 'data')).create();
      final extracted = await Process.run('tar', [
        '-xf',
        p.join(
          Directory.current.path,
          'assets',
          'bundled_extensions',
          'soundcloud.sflx',
        ),
        '-C',
        ext.path,
      ]);
      expect(extracted.exitCode, 0);
      addTearDown(() => PlatformBridge.cleanupExtensions());
      await PlatformBridge.initExtensionSystem(
        sources.path,
        data.path,
        masterKey: base64Encode(List.filled(32, 0)),
        lyricsProviders: [],
        lyricsFetchOptions: {},
      );
      await PlatformBridge.loadExtensionsFromDir(sources.path);
      await PlatformBridge.setExtensionEnabled('soundcloud', true);
      final installed = await PlatformBridge.getInstalledExtensions();
      final fixture = installed.singleWhere((e) => e['id'] == 'soundcloud');
      expect(fixture['status'], 'loaded');
      expect(fixture['enabled'], isTrue);
      final matches = await PlatformBridge.searchTracksWithMetadataProvider(
        'soundcloud',
        'Decoherence Scott Buckley',
      );
      print('Public search result count: ${matches.length}');
      expect(matches.any((match) => '${match['id']}' == '1242600556'), isTrue);

      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      const track = Track(
        id: '1242600556',
        source: 'soundcloud',
        name: 'Decoherence (CC-BY)',
        artistName: 'Scott Buckley',
        albumName: '',
        duration: 618,
      );
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer.platform(
          stagingRoot: Directory(p.join(root.path, 'staging')),
          bugLog: bugLog,
          diagnostic: (message) => print('Diagnostic: $message'),
          transfer: (request) async {
            final result = await PlatformBridge.downloadTemporary(request);
            print('Result fields: ${result.keys.toList()}');
            final raw = result.toString().toLowerCase();
            for (final term in [
              'search failed',
              'not found',
              'availability',
              'no confident',
              'authorization',
              'forbidden',
              'timeout',
              'network',
              'no supported',
              'not playable',
              'access_playable',
              'access_preview',
              'access_blocked',
              'access_absent',
              'streamable_true',
              'streamable_false',
              'streamable_undefined',
              'media_true',
              'media_false',
              'transcodings_true',
              'transcodings_false',
              'api_error',
              'download_error',
              '404',
              '403',
              '401',
              '429',
              '500',
              '502',
              '503',
            ]) {
              if (raw.contains(term)) print('Failure category: $term');
            }
            return result;
          },
          payload: (dir, id) => buildCatalogDownloadPayload(
            track: track,
            directory: dir,
            transferId: id,
            service: 'soundcloud',
            quality: 'aac_160',
            useExtensions: true,
            useFallback: false,
          ),
        ),
      );
      final first = await playback.acquire(track);
      addTearDown(first.release);
      final firstPath = first.path;
      expect(firstPath, endsWith('.m4a'));
      expect(await FFmpegProbe.audioCodec(firstPath), 'aac');
      final durationProbe = await Process.run(tools.ffprobePath!, [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'default=noprint_wrappers=1:nokey=1',
        firstPath,
      ]);
      expect(durationProbe.exitCode, 0);
      final actualDuration = double.parse('${durationProbe.stdout}'.trim());
      print('Prepared audio duration: ${actualDuration.toStringAsFixed(2)} s');
      expect(actualDuration, inInclusiveRange(613, 623));
      expect((await File(firstPath).readAsBytes()).skip(4).take(4), [
        102,
        116,
        121,
        112,
      ]);
      final decode = await Process.run(tools.ffmpegPath!, [
        '-v',
        'error',
        '-xerror',
        '-i',
        firstPath,
        '-map',
        '0:a:0',
        '-f',
        'null',
        '-',
      ]);
      expect(decode.exitCode, 0, reason: '${decode.stderr}');
      await first.release();
      final second = await playback.acquire(track);
      addTearDown(second.release);
      expect(second.path, firstPath);
      await second.release();
      final before = await File(firstPath).readAsBytes();
      expect(await playback.promote(track), isTrue);
      final promoted = await store.lookup(playback.key(track));
      expect(promoted?.persistent, isTrue);
      expect(await File(promoted!.path).readAsBytes(), before);
      expect(promoted.path, endsWith('.m4a'));
      expect(await FFmpegProbe.audioCodec(promoted.path), 'aac');
    },
    skip: !enabled,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
