import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/music_player_automix_harness.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

void main() {
  setUpMusicPlayerHarness();
  test(
    'exact provider cache remains available when provider is unavailable',
    () async {
      final root = await Directory.systemTemp.createTemp('provider-cache-');
      addTearDown(() async => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      const track = Track(
        id: 'one',
        source: 'spotify',
        name: 'One',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      var resolutions = 0;
      final playback =
          CatalogPlayback(storage: store, savedLookup: (_) async => false)
            ..defaultService = 'provider-a'
            ..resolveDownloadService = (_, _) async {
              resolutions++;
              return '';
            };
      final source = File(p.join(root.path, 'fixture.opus'));
      await source.writeAsBytes([1, 2, 3]);
      await store.putTemporary(
        jsonEncode([
          'catalog-audio-v5',
          playback.key(track),
          128,
          'LOSSLESS',
          'provider-a',
          true,
        ]),
        source,
        qualityMetadata: {'provider': 'provider-a'},
      );
      final lease = await playback.acquire(track);
      expect(await File(lease.path).readAsBytes(), [1, 2, 3]);
      expect(resolutions, 1);
      await lease.release();
    },
  );
  test(
    'blank or unavailable default resolves an enabled usable provider',
    () async {
      const state = ExtensionState(
        extensions: [
          Extension(
            id: 'broken',
            name: 'Broken',
            displayName: 'Broken',
            version: '1',
            description: '',
            enabled: true,
            status: 'error',
            hasDownloadProvider: true,
          ),
          Extension(
            id: 'working',
            name: 'Working',
            displayName: 'Working',
            version: '1',
            description: '',
            enabled: true,
            status: 'loaded',
            hasDownloadProvider: true,
          ),
        ],
      );
      expect(
        await resolveCatalogDownloadService('', () async => state),
        'working',
      );
      expect(
        await resolveCatalogDownloadService('broken', () async => state),
        'working',
      );
      expect(
        await resolveCatalogDownloadService(
          'broken',
          () async => state,
          autoFallback: false,
        ),
        isEmpty,
      );
      expect(
        await resolveCatalogDownloadService(
          'missing',
          () async => state,
          autoFallback: false,
        ),
        isEmpty,
      );
      expect(
        await resolveCatalogDownloadService(
          '',
          () async => state,
          autoFallback: false,
        ),
        'working',
      );
      expect(
        await resolveCatalogDownloadService('working', () async => state),
        'working',
      );
      expect(
        await resolveCatalogDownloadService(
          '',
          () async => const ExtensionState(),
        ),
        isEmpty,
      );
    },
  );
  test(
    'alternative respects priority while usable explicit provider wins',
    () async {
      Extension provider(
        String id, {
        bool enabled = true,
        String status = 'loaded',
      }) => Extension(
        id: id,
        name: id,
        displayName: id,
        version: '1',
        description: '',
        enabled: enabled,
        status: status,
        hasDownloadProvider: true,
      );
      final state = ExtensionState(
        extensions: [
          provider('a'),
          provider('b'),
          provider('bad', status: 'error'),
          provider('disabled', enabled: false),
        ],
        providerPriority: ['missing', 'bad', 'disabled', 'b', 'a'],
      );
      for (final requested in ['', 'missing']) {
        final service = await resolveCatalogDownloadService(
          requested,
          () async => state,
        );
        expect(service, 'b');
        final payload = buildCatalogDownloadPayload(
          track: const Track(
            id: '1',
            name: 'A',
            artistName: 'B',
            albumName: 'C',
            duration: 1,
          ),
          directory: Directory('staging'),
          transferId: '1',
          service: service,
          quality: 'LOSSLESS',
          useExtensions: true,
          useFallback: true,
        );
        expect(payload.downloadProvider, 'b');
        expect(payload.toJson()['use_fallback'], isTrue);
      }
      expect(
        await resolveCatalogDownloadService(
          'a',
          () async => state,
          autoFallback: false,
        ),
        'a',
      );
      final partial = state.copyWith(providerPriority: ['absent', ' B ', 'b']);
      expect(await resolveCatalogDownloadService('', () async => partial), 'b');
      final unlisted = state.copyWith(
        providerPriority: ['absent', 'bad', 'bad'],
      );
      expect(
        await resolveCatalogDownloadService('', () async => unlisted),
        'a',
      );
    },
  );
  test(
    'cache miss without provider reaches playback state with safe category',
    () async {
      final root = await Directory.systemTemp.createTemp('provider-signal-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      });
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final playback = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      )..resolveDownloadService = (_, _) async => '';
      await handler.dispose();
      handler = MusicPlayerHandler(catalogPlaybackOverride: playback);
      await handler.setQueueAndPlay([
        playableFromCatalogTrack(
          const Track(
            id: 'one',
            source: 'spotify',
            name: 'One',
            artistName: 'Artist',
            albumName: 'Album',
            duration: 2,
          ),
        ),
      ]);
      expect(
        handler.playbackState.value.processingState,
        AudioProcessingState.error,
      );
      expect(
        handler.playbackState.value.errorMessage,
        'CatalogPlaybackException: $catalogProviderUnavailableCategory',
      );
    },
  );
  test(
    'unavailable provider can be retried with the current fallback setting',
    () async {
      final root = await Directory.systemTemp.createTemp('provider-retry-');
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await root.delete(recursive: true);
      });
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final seen = <bool>[];
      final created = <(String, bool)>[];
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => false,
              resolvedPreparerFactory: (_, service, fallback) {
                created.add((service, fallback));
                return TemporaryTrackPreparer(
                  stagingRoot: Directory(p.join(root.path, 'staging')),
                  download: (directory, _) async => File(
                    p.join(directory.path, 'input'),
                  ).writeAsBytes([1, 2, 3]),
                  cancelDownload: (_) async {},
                  codec: (_) async => 'aac', container: (_) async => 'mp4',
                  validate: (_) async => true,
                );
              },
            )
            ..defaultService = 'missing'
            ..useFallback = false
            ..resolveDownloadService = (requested, fallback) async {
              seen.add(fallback);
              return fallback ? 'working' : '';
            };
      const track = Track(
        id: 'retry',
        name: 'A',
        artistName: 'B',
        albumName: 'C',
        duration: 1,
      );
      await expectLater(
        playback.acquire(track),
        throwsA(
          isA<CatalogPlaybackException>().having(
            (e) => e.category,
            'category',
            catalogProviderUnavailableCategory,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      playback.useFallback = true;
      final lease = await playback.acquire(track);
      expect(await File(lease.path).readAsBytes(), [1, 2, 3]);
      await lease.release();
      expect(seen, [false, true]);
      expect(created, [('working', true)]);
    },
  );
  test(
    'cancelling while resolver waits never creates or publishes audio',
    () async {
      final root = await Directory.systemTemp.createTemp('provider-cancel-');
      addTearDown(() async => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final entered = Completer<void>();
      final result = Completer<String>();
      var creations = 0;
      final playback =
          CatalogPlayback(
              storage: store,
              savedLookup: (_) async => false,
              resolvedPreparerFactory: (_, _, _) {
                creations++;
                throw StateError('must not create preparer');
              },
            )
            ..resolveDownloadService = (_, _) {
              entered.complete();
              return result.future;
            };
      const track = Track(
        id: 'cancel',
        name: 'A',
        artistName: 'B',
        albumName: 'C',
        duration: 1,
      );
      final pending = playback.acquire(track);
      final failure = expectLater(
        pending,
        throwsA(isA<CatalogPlaybackException>()),
      );
      await entered.future;
      await playback.cancel(track);
      await failure;
      result.complete('working');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(creations, 0);
      expect(await store.lookup(playback.key(track)), isNull);
      expect(
        await store.lookup(
          jsonEncode([
            'catalog-audio-v5',
            playback.key(track),
            128,
            'LOSSLESS',
            '',
            true,
          ]),
        ),
        isNull,
      );
    },
  );
}
