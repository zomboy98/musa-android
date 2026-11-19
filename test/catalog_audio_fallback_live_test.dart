import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/main.dart' show EagerInitialization;
import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/backend/ffi_backend_transport.dart';
import 'package:mornye/services/backend/rust_ffi_backend.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/ffmpeg_desktop.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/utils/desktop_platform.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final enabled =
      Platform.environment['MUSA_SOUNDCLOUD_LIVE_PROBE'] == '1' &&
      (Platform.environment[desktopBackendLibraryEnvironmentKey]?.isNotEmpty ??
          false);
  testWidgets(
    'real playback falls back from local failure fixture to SoundCloud',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      const links = MethodChannel('com.llfbandit.app_links/events');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        links,
        (_) async => null,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          links,
          null,
        ),
      );
      late Directory root;
      late DesktopFFmpegTools tools;
      late ProviderContainer container;
      await tester.runAsync(() async {
        SharedPreferences.setMockInitialValues({});
        root = await Directory.systemTemp.createTemp('musa-fallback-');
        final oldPaths = PathProviderPlatform.instance;
        PathProviderPlatform.instance = _Paths(root.path);
        tools = await DesktopFFmpegTools.locate();
        expect(tools.ffmpegPath, isNotNull);
        expect(tools.ffprobePath, isNotNull);
        debugDesktopPlatformOverride = true;
        DesktopFFmpegRunner.debugShared = DesktopFFmpegRunner(
          tools: () async => tools,
        );
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
        final sources = Directory(p.join(root.path, 'sources'));
        final sc = await Directory(
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
          sc.path,
        ]);
        expect(extracted.exitCode, 0);
        final fail = await Directory(
          p.join(sources.path, 'a-fixture'),
        ).create();
        await File(p.join(fail.path, 'manifest.json')).writeAsString(
          jsonEncode({
            'name': 'a-fixture',
            'version': '1',
            'description': 'Offline failure fixture',
            'type': ['download_provider', 'metadata_provider'],
            'permissions': {'file': true, 'storage': true},
          }),
        );
        await File(p.join(fail.path, 'index.js')).writeAsString(
          "registerExtension({checkAvailability(){storage.set('attempted','yes');return {available:false,reason:'fixture unavailable'};},searchTracks(){return {tracks:storage.get('attempted') === 'yes' ? [{id:'visited',name:'visited',artists:'fixture',duration_ms:1}] : []};},download(){return {success:false,error_message:'fixture unavailable'};}});",
        );
        container = ProviderContainer();
        addTearDown(() async {
          container.dispose();
          await PlatformBridge.cleanupExtensions();
          RustFfiBackend.debugShared = null;
          DesktopFFmpegRunner.debugShared = null;
          debugDesktopPlatformOverride = null;
          PathProviderPlatform.instance = oldPaths;
          if (await root.exists()) {
            try {
              await root.delete(recursive: true);
            } on FileSystemException {
              print('Temporary test directory remains locked by test services');
            }
          }
        });
        final notifier = container.read(extensionProvider.notifier);
        print('Initializing real extension provider');
        await notifier.initialize(
          sources.path,
          data.path,
          masterKey: base64Encode(List.filled(32, 0)),
        );
        print('Extension provider initialized');
        await PlatformBridge.setExtensionEnabled('a-fixture', true);
        await PlatformBridge.setExtensionEnabled('soundcloud', true);
        await notifier.refreshExtensions();
        await notifier.setProviderPriority(['a-fixture', 'soundcloud']);
        expect(
          resolveEffectiveDownloadService(
            '',
            container.read(extensionProvider),
          ),
          'a-fixture',
        );
        final settings = container.read(settingsProvider);
        expect(settings.playbackProviderConfirmed, isFalse);
        expect(settings.playbackCacheBitrate, '128k');
        // Exercise the actual empty-default resolver. Fixture priorities are
        // configured in this isolated test container; no user preference is read.
        catalogPlayback.defaultService = '';
        catalogPlayback.providerConfirmed = false;
        catalogPlayback.quality = settings.playbackQuality;
        catalogPlayback.playbackBitrateKbps = int.parse(
          settings.playbackCacheBitrate.replaceAll('k', ''),
        );
        catalogPlayback.useExtensions = settings.useExtensionProviders;
        catalogPlayback.useFallback = settings.autoFallback;
        await catalogPlayback.store.timeout(const Duration(seconds: 10));
        print('Store prewarmed');
        print('Provider priorities configured');
      });
      await tester.runAsync(() async {
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const EagerInitialization(child: SizedBox()),
          ),
        );
      });
      print('Root initialization mounted');
      const track = Track(
        id: '1683393261',
        source: 'apple_music',
        name: 'Decoherence',
        artistName: 'Scott Buckley',
        albumName: '',
        duration: 618,
      );
      await tester.runAsync(() async {
        await catalogPlayback.store.timeout(const Duration(seconds: 10));
        print('Store available');
        await catalogPlayback
            .withRetentionLock(() async {})
            .timeout(const Duration(seconds: 10));
        print('Retention lock available');
        final lease = await catalogPlayback
            .acquire(track)
            .timeout(const Duration(seconds: 100));
        final cached = await (await catalogPlayback.store).lookup(lease.id);
        expect(cached?.qualityMetadata['provider'], 'soundcloud');
        expect(cached?.qualityMetadata['requested_quality'], 'LOSSLESS');
        expect(cached?.qualityMetadata['resolved_quality'], 'aac_160');
        expect(cached?.qualityMetadata['quality_fallback_used'], isTrue);
        final visited = await PlatformBridge.searchTracksWithMetadataProvider(
          'a-fixture',
          'visited',
        );
        expect(visited.any((item) => item['id'] == 'visited'), isTrue);
        final dir = await Directory(p.join(root.path, 'diagnostic')).create();
        final service = resolveEffectiveDownloadService(
          '',
          container.read(extensionProvider),
        );
        final payload = buildCatalogDownloadPayload(
          track: track,
          directory: dir,
          transferId: 'diagnostic',
          service: service,
          quality: catalogPlayback.quality,
          useExtensions: catalogPlayback.useExtensions,
          useFallback: catalogPlayback.useFallback,
        );
        expect(catalogPlayback.quality, 'LOSSLESS');
        expect(payload.toJson()['allow_quality_fallback'], isTrue);
        print(
          'Verified fixture attempted; SoundCloud is the sole remaining provider',
        );
        print('Playback acquired');
        final path = lease.path;
        expect(await FFmpegProbe.audioCodec(path), 'aac');
        expect(p.extension(path), '.m4a');
        final rate = await Process.run(tools.ffprobePath!, [
          '-v',
          'error',
          '-select_streams',
          'a:0',
          '-show_entries',
          'stream=bit_rate',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          path,
        ]);
        expect(rate.exitCode, 0);
        final bitrate = int.parse('${rate.stdout}'.trim());
        print('AAC bitrate: $bitrate bps');
        expect(bitrate, inInclusiveRange(80000, 160000));
        final probe = await Process.run(tools.ffprobePath!, [
          '-v',
          'error',
          '-show_entries',
          'format=duration',
          '-of',
          'default=noprint_wrappers=1:nokey=1',
          path,
        ]);
        expect(probe.exitCode, 0);
        expect(
          double.parse('${probe.stdout}'.trim()),
          inInclusiveRange(613, 623),
        );
        final decode = await Process.run(tools.ffmpegPath!, [
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
        expect(decode.exitCode, 0);
        await lease.release();
        final second = await catalogPlayback.acquire(track);
        expect(second.path, path);
        expect(
          (await (await catalogPlayback.store).lookup(second.id))?.persistent,
          isFalse,
        );
        await second.release();
      });
      await tester.pumpWidget(const SizedBox());
    },
    skip: !enabled,
    timeout: const Timeout(Duration(seconds: 120)),
  );
}
