import 'dart:convert';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new_audio/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_audio/return_code.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;

// Requires a freshly installed, dedicated application ID. The normal debug
// build is deliberately refused because its existing data may belong to the
// user. Launch this file directly, not from the application's main entrypoint.
// PowerShell, build only (does not install):
// $env:MORNYE_CATALOG_INTEGRATION = '1'
// flutter build apk --debug -t integration_test/catalog_android_loopback_test.dart
// Remove-Item Env:MORNYE_CATALOG_INTEGRATION
// Before execution, inspect the device's installed packages and use a fresh
// exclusive installation and process. Do not replace or remove existing data.
// Run with the same environment override using flutter test on an unlocked
// authorized device, and remove the override afterwards.
const _isolatedPackage = 'org.musa.music.catalogintegration';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Android Rust extension downloads once, caches and promotes Opus', (
    tester,
  ) async {
    expect(Platform.isAndroid, isTrue);
    final temp = Directory.systemTemp.absolute.path.replaceAll('\\', '/');
    expect(
      temp.split('/'),
      contains(_isolatedPackage),
      reason: 'Use a fresh dedicated package; never use the normal debug app.',
    );

    final root = await Directory.systemTemp.createTemp('catalog-loopback-');
    addTearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });
    final source = p.join(root.path, 'synthetic.flac');
    final generated = await FFmpegKit.executeWithArguments([
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=44100:duration=4',
      '-c:a',
      'flac',
      '-y',
      source,
    ]);
    expect(
      ReturnCode.isSuccess(await generated.getReturnCode()),
      isTrue,
      reason: await generated.getOutput(),
    );
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

    final sources = await Directory(p.join(root.path, 'sources')).create();
    final data = await Directory(p.join(root.path, 'data')).create();
    final provider = await Directory(
      p.join(sources.path, 'example.audio'),
    ).create();
    await File(p.join(provider.path, 'manifest.json')).writeAsString(
      jsonEncode({
        'name': 'example.audio',
        'version': '1',
        'description': 'Synthetic loopback fixture',
        'type': ['download_provider'],
        'permissions': {
          'file': true,
          'network': ['127.0.0.1'],
          'allowHttp': true,
        },
        'skipMetadataEnrichment': true,
      }),
    );
    await File(p.join(provider.path, 'index.js')).writeAsString('''
registerExtension({
  checkAvailability(){return {available:true,track_id:'track'};},
  download(trackId,quality,outputPath){
    file.download('http://127.0.0.1:${server.port}/audio.flac', outputPath);
    return {success:true,file_path:outputPath};
  }
});
''');
    // Registered before initialization so partial initialization is cleaned up.
    addTearDown(() => PlatformBridge.cleanupExtensions());
    await PlatformBridge.initExtensionSystem(
      sources.path,
      data.path,
      masterKey: base64Encode(List<int>.filled(32, 0)),
      lyricsProviders: const [],
      lyricsFetchOptions: const {},
      allowedDirectories: [root.path],
    );
    final implementations = await PlatformBridge.getBackendImplementations();
    expect(implementations['downloads'], 'rust');
    expect(implementations['extensions'], 'rust');
    // SelectedCoreBackend defaults to false in a fresh process. There is no
    // getter; this test must run alone in the fresh dedicated installation.
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
    final path = first.path;
    expect(await FFmpegProbe.audioCodec(path), 'opus');
    expect((await File(path).readAsBytes()).take(4), [79, 103, 103, 83]);
    final decoded = await FFmpegKit.executeWithArguments([
      '-v',
      'error',
      '-xerror',
      '-i',
      path,
      '-map',
      '0:a:0',
      '-f',
      'null',
      '-',
    ]);
    expect(
      ReturnCode.isSuccess(await decoded.getReturnCode()),
      isTrue,
      reason: await decoded.getOutput(),
    );
    expect(requests, 1);
    final deck = const PlaybackDependencies().createDeck(
      'catalog-loopback-test',
    );
    addTearDown(deck.dispose);
    await deck.configureOutput();
    await deck.setVolume(0);
    await deck.setFileSource(path);
    expect(deck.isDirect, isFalse);
    await deck.setVolume(0);
    await deck.resume();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    var progressed = false;
    while (DateTime.now().isBefore(deadline)) {
      final position = await deck.getCurrentPosition();
      if (position != null && position > Duration.zero) {
        progressed = true;
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(progressed, isTrue, reason: 'Muted playback did not advance');
    await deck.stop();
    await first.release();
    final second = await playback.acquire(track);
    addTearDown(second.release);
    expect(second.path, path);
    expect(requests, 1);
    await second.release();
    final before = await File(path).readAsBytes();
    expect(await playback.promote(track), isTrue);
    final promoted = await store.lookup(playback.key(track));
    expect(promoted?.persistent, isTrue);
    expect(await File(promoted!.path).readAsBytes(), before);
    expect(await FFmpegProbe.audioCodec(promoted.path), 'opus');
    expect(requests, 1);
  }, timeout: const Timeout(Duration(seconds: 120)));
}
