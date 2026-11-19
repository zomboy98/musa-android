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
      Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
      false;
  test(
    'real desktop extension fetches synthetic audio once and promotes AAC',
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
      final source = p.join(root.path, 'synthetic.flac');
      final generated = await Process.run(tools.ffmpegPath!, [
        '-v',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=1',
        '-c:a',
        'flac',
        '-y',
        source,
      ]);
      expect(generated.exitCode, 0, reason: '${generated.stderr}');
      final bytes = await File(source).readAsBytes();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var requests = 0;
      server.listen((request) async {
        requests++;
        request.response.headers.contentType = ContentType('audio', 'flac');
        request.response.contentLength = bytes.length;
        request.response.add(bytes);
        await request.response.close();
      });
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
        p.join(sources.path, 'example.audio'),
      ).create(recursive: true);
      final data = await Directory(p.join(root.path, 'data')).create();
      await File(p.join(ext.path, 'manifest.json')).writeAsString(
        jsonEncode({
          'name': 'example.audio',
          'version': '1',
          'description': 'Local synthetic audio fixture',
          'type': ['download_provider'],
          'permissions': {
            'file': true,
            'network': ['127.0.0.1'],
            'allowHttp': true,
          },
          'skipMetadataEnrichment': true,
        }),
      );
      await File(p.join(ext.path, 'index.js')).writeAsString('''
registerExtension({
 checkAvailability(){return {available:true,track_id:'track'};},
 download(trackId,quality,outputPath){
   file.download('http://127.0.0.1:${server.port}/audio.flac', outputPath);
   return {success:true,file_path:outputPath};
 }
});
''');
      addTearDown(() => PlatformBridge.cleanupExtensions());
      await PlatformBridge.initExtensionSystem(
        sources.path,
        data.path,
        masterKey: base64Encode(List.filled(32, 0)),
        lyricsProviders: [],
        lyricsFetchOptions: {},
      );
      addTearDown(() => PlatformBridge.setAllowPrivateNetwork(false));
      await PlatformBridge.setAllowPrivateNetwork(true);
      await PlatformBridge.loadExtensionsFromDir(sources.path);
      await PlatformBridge.setExtensionEnabled('example.audio', true);
      final installed = await PlatformBridge.getInstalledExtensions();
      final fixture = installed.singleWhere((e) => e['id'] == 'example.audio');
      expect(fixture['status'], 'loaded');
      expect(fixture['enabled'], isTrue);

      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      const track = Track(
        id: 'track',
        source: 'example.audio',
        name: 'Synthetic',
        artistName: 'Fixture',
        albumName: 'Fixture',
        duration: 1,
      );
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
        preparerFactory: (_) => TemporaryTrackPreparer.platform(
          stagingRoot: Directory(p.join(root.path, 'staging')),
          bugLog: bugLog,
          payload: (dir, id) => buildCatalogDownloadPayload(
            track: track,
            directory: dir,
            transferId: id,
            service: 'example.audio',
            quality: 'LOSSLESS',
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
      expect(requests, 1);
      await first.release();
      final second = await playback.acquire(track);
      addTearDown(second.release);
      expect(second.path, firstPath);
      expect(requests, 1);
      await second.release();
      final before = await File(firstPath).readAsBytes();
      expect(await playback.promote(track), isTrue);
      final promoted = await store.lookup(playback.key(track));
      expect(promoted?.persistent, isTrue);
      expect(await File(promoted!.path).readAsBytes(), before);
      expect(promoted.path, endsWith('.m4a'));
      expect(await FFmpegProbe.audioCodec(promoted.path), 'aac');
      expect(requests, 1);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
