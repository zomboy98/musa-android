import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'support/music_player_automix_harness.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.root);
  final String root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
}

class _Session implements AudioSession {
  _Session(this.denials);

  int denials;
  int requests = 0;

  @override
  Future<bool> setActive(
    bool active, {
    AVAudioSessionSetActiveOptions? avAudioSessionSetActiveOptions,
    AndroidAudioFocusGainType? androidAudioFocusGainType,
    AndroidAudioAttributes? androidAudioAttributes,
    bool? androidWillPauseWhenDucked,
    AudioSessionConfiguration fallbackConfiguration =
        const AudioSessionConfiguration.music(),
  }) async {
    if (!active) return true;
    requests++;
    if (denials > 0) {
      denials--;
      return false;
    }
    return true;
  }

  @override
  Future<void> configure(AudioSessionConfiguration configuration) async {}

  @override
  Stream<AudioInterruptionEvent> get interruptionEventStream =>
      const Stream.empty();
  @override
  Stream<void> get becomingNoisyEventStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpMusicPlayerHarness();

  Future<(CatalogPlayback, List<String>)> relayingPlayback(
    Set<String> failing, {
    Set<String> hanging = const {},
  }) async {
    final root = await Directory.systemTemp.createTemp('relay-start-');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    addTearDown(() async {
      PathProviderPlatform.instance = previous;
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        return;
      }
    });
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await store.initialize();
    final tried = <String>[];
    final playback =
        CatalogPlayback(
            storage: store,
            savedLookup: (_) async => false,
            resolvedPreparerFactory: (_, service, _) => TemporaryTrackPreparer(
              stagingRoot: Directory(p.join(root.path, 'staging')),
              download: (directory, _) async {
                tried.add(service);
                if (hanging.contains(service)) {
                  await Completer<void>().future;
                }
                if (failing.contains(service)) {
                  throw const TemporaryTrackException('provider timed out');
                }
                return File(
                  p.join(directory.path, 'input'),
                ).writeAsBytes([1, 2, 3]);
              },
              takeQualityMetadata: (_) => {'provider': service},
              cancelDownload: (_) async {},
              codec: (_) async => service == 'a' ? 'opus' : 'aac',
              container: (_) async => service == 'a' ? 'ogg' : 'mp4',
              validate: (_) async => true,
            ),
          )
          ..defaultService = 'a'
          ..resolveDownloadService = (requested, _) async =>
              requested.isEmpty ? 'a' : requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service.isEmpty ? 'a' : service, 'opus');
    playback.streamingAlternatives = (first, quality, _) async => [
      const StreamingRequest('b', 'aac_160'),
    ];
    return (playback, tried);
  }

  const track = Track(
    id: 'relay-start',
    source: 'spotify',
    name: 'R',
    artistName: 'A',
    albumName: 'B',
    duration: 200,
  );

  Future<void> useSession(CatalogPlayback playback, _Session session) async {
    await handler.dispose();
    handler = MusicPlayerHandler(
      catalogPlaybackOverride: playback,
      runtime: MusicPlayerRuntime(
        dependencies: PlaybackDependencies(audioSession: () async => session),
      ),
    );
  }

  test('a relayed preparation starts playing by itself', () async {
    final (playback, tried) = await relayingPlayback({'a'});
    final lines = <String>[];
    playback.failureDiagnostic = lines.add;
    await useSession(playback, _Session(0));
    await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    expect(tried, ['a', 'b']);
    expect(
      handler.playbackState.value.processingState,
      AudioProcessingState.ready,
    );
    expect(handler.playbackState.value.playing, isTrue);
    expect(native.playing, isNotEmpty);
    expect(
      lines.where((l) => l.startsWith('relay playback started paused=false')),
      hasLength(1),
    );
  });

  test('a relayed preparation after a timeout starts playing by itself',
      () async {
    final (playback, tried) = await relayingPlayback({}, hanging: {'a'});
    playback.firstAttemptBudget = const Duration(milliseconds: 300);
    await useSession(playback, _Session(0));
    await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    expect(tried, ['a', 'b']);
    expect(handler.playbackState.value.playing, isTrue);
    expect(native.playing, isNotEmpty);
  });

  test('a relayed preparation retries a denied audio focus and plays',
      () async {
    final (playback, tried) = await relayingPlayback({'a'});
    final lines = <String>[];
    playback.failureDiagnostic = lines.add;
    final session = _Session(1);
    await useSession(playback, session);
    await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    expect(tried, ['a', 'b']);
    expect(session.requests, 2);
    expect(handler.playbackState.value.playing, isTrue);
    expect(native.playing, isNotEmpty);
    expect(
      lines.where((l) => l.startsWith('relay playback focus granted')),
      hasLength(1),
    );
    expect(
      lines.where((l) => l.startsWith('relay playback started paused=false')),
      hasLength(1),
    );
  });

  test('a plain preparation keeps pausing when the focus is denied', () async {
    final (playback, tried) = await relayingPlayback({});
    await useSession(playback, _Session(1));
    await handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    expect(tried, ['a']);
    expect(handler.playbackState.value.playing, isFalse);
  });
}
