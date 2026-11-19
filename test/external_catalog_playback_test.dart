import 'dart:io';
import 'dart:async';
import 'dart:convert';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/playback_provider.dart' hide PlaybackState;
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/music_player_automix_harness.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(playerMode: 'external');
}

class _Runtime extends MusicPlayerRuntime {
  @override
  MusicPlayerHandler? get handler => activeHandler;
  @override
  Future<MusicPlayerHandler> initialize() async => activeHandler!;
  @override
  Stream<MediaItem?> mediaItemEvents() => activeHandler!.mediaItem.stream;
  @override
  Stream<PlaybackState> playbackStateEvents() =>
      activeHandler!.playbackState.stream;
  @override
  Stream<List<MediaItem>> queueEvents() => activeHandler!.queue.stream;
}

MusicPlayerHandler? activeHandler;

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

class _SlowStop extends MusicPlayerHandler {
  _SlowStop(CatalogPlayback catalog) : super(catalogPlaybackOverride: catalog);
  Completer<void> entered = Completer<void>();
  Completer<void> release = Completer<void>();
  void resetStop() {
    entered = Completer<void>();
    release = Completer<void>();
  }

  @override
  Future<void> stop({bool keepResume = false}) async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}

class _Playback extends PlaybackController {
  _Playback(this.localPath);
  String localPath;
  @override
  Future<List<String?>> resolveTrackFilePaths(List<Track> tracks) async => [
    for (final t in tracks) t.id == 'local' ? localPath : null,
  ];
}

void main() {
  setUpMusicPlayerHarness();
  test(
    'first playlist activation reaches missing-provider error without another play tap',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'playlist-first-failure-',
      );
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(root.path);
      addTearDown(() async {
        PathProviderPlatform.instance = oldPaths;
        await root.delete(recursive: true);
      });
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final catalog = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      )..resolveDownloadService = (_, _) async => '';
      await handler.dispose();
      handler = MusicPlayerHandler(catalogPlaybackOverride: catalog);
      activeHandler = handler;
      addTearDown(() => activeHandler = null);
      final runtime = _Runtime();
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          playbackProvider.overrideWith(() => _Playback('')),
        ],
      );
      addTearDown(container.dispose);
      await container.read(playbackProvider.notifier).playTrackList([
        const Track(
          id: 'one',
          source: 'spotify',
          name: 'One',
          artistName: 'Artist',
          albumName: 'Album',
          duration: 1,
        ),
      ], playlistId: 'playlist');
      expect(handler.mediaItem.value?.title, 'One');
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
    'external preference uses internal catalog queue and stops before external file',
    () async {
      const remote = Track(
        id: 'remote',
        source: 'spotify',
        name: 'Remote',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      const local = Track(
        id: 'local',
        source: 'local',
        name: 'Local',
        artistName: 'Artist',
        albumName: 'Album',
        duration: 2,
      );
      final root = await Directory.systemTemp.createTemp('external-catalog-');
      addTearDown(() async => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory(p.join(root.path, 'cache')),
        libraryDirectory: Directory(p.join(root.path, 'library')),
      );
      await store.initialize();
      final catalog = CatalogPlayback(
        storage: store,
        savedLookup: (_) async => false,
      )..resolveDownloadService = (_, _) async => 'test-provider';
      final fixture = File(p.join(root.path, 'cached.opus'));
      await fixture.writeAsBytes([1, 2, 3]);
      await store.putTemporary(
        jsonEncode([
          'catalog-audio-v5',
          catalog.key(remote),
          128,
          'ac4',
          'test-provider',
          true,
        ]),
        fixture,
        qualityMetadata: {'provider': 'test-provider'},
      );
      await handler.dispose();
      handler = MusicPlayerHandler(catalogPlaybackOverride: catalog);
      activeHandler = handler;
      addTearDown(() => activeHandler = null);
      final runtime = _Runtime();
      final localFile = File(p.join(root.path, 'local.mp3'));
      await localFile.writeAsBytes([1, 2, 3]);
      final playbackController = _Playback(localFile.path);
      final container = ProviderContainer(
        overrides: [
          settingsProvider.overrideWith(_Settings.new),
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          playbackProvider.overrideWith(() => playbackController),
        ],
      );
      addTearDown(container.dispose);
      await container.read(playbackProvider.notifier).playTrackList([
        remote,
        local,
      ], playlistId: 'fixture-playlist');
      expect(handler.mediaItem.value?.title, 'Remote');
      expect(handler.playbackState.value.playing, isTrue);
      expect(handler.queue.value.map((item) => item.title), [
        'Remote',
        'Local',
      ]);
      expect(container.read(playerUiEnabledProvider), isTrue);
      expect(container.read(settingsProvider).playerMode, 'external');
      await handler.skipToNext();
      expect(handler.mediaItem.value?.title, 'Local');
      expect(handler.playbackState.value.playing, isTrue);
      expect(container.read(playerUiEnabledProvider), isTrue);
      const channel = MethodChannel('com.zarz.mornye/backend');
      var stoppedBeforeOpen = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openContentUri')
              stoppedBeforeOpen =
                  !handler.playbackState.value.playing &&
                  handler.mediaItem.value == null;
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      playbackController.localPath = 'content://library/local';
      await container.read(playbackProvider.notifier).playTrackList([local]);
      expect(stoppedBeforeOpen, isTrue);
      expect(container.read(internalCatalogSessionProvider), isFalse);
      expect(container.read(settingsProvider).playerMode, 'external');
      await handler.dispose();
      final slow = _SlowStop(catalog);
      handler = slow;
      activeHandler = slow;
      await container.read(playbackProvider.notifier).playTrackList([remote]);
      var opens = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'openContentUri') opens++;
            return null;
          });
      final stale = container.read(playbackProvider.notifier).playTrackList([
        local,
      ]);
      await slow.entered.future;
      await container.read(playbackProvider.notifier).playTrackList([remote]);
      slow.release.complete();
      await stale;
      expect(opens, 0);
      expect(container.read(internalCatalogSessionProvider), isTrue);
      expect(slow.mediaItem.value?.title, 'Remote');
      slow.resetStop();
      playbackController.localPath = localFile.path;
      await container.read(playbackProvider.notifier).playTrackList([
        remote,
        local,
      ]);
      playbackController.localPath = 'content://library/local';
      final staleAfterNext = container
          .read(playbackProvider.notifier)
          .playTrackList([local]);
      await slow.entered.future;
      await slow.skipToNext();
      slow.release.complete();
      await staleAfterNext;
      expect(opens, 0);
      expect(slow.mediaItem.value?.title, 'Local');
      expect(slow.playbackState.value.playing, isTrue);
      expect(container.read(internalCatalogSessionProvider), isTrue);
    },
  );
}
