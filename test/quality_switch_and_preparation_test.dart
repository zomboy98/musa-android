import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/quality_switch_result.dart';
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

class _Fixture {
  _Fixture(this.playback, this.gate);
  final CatalogPlayback playback;
  final Completer<void> gate;
  int downloads = 0;
}

void main() {
  setUpMusicPlayerHarness();

  const track = Track(
    id: 'switch-result-track',
    source: 'spotify',
    name: 'S',
    artistName: 'A',
    albumName: 'B',
    duration: 200,
  );

  Future<_Fixture> build() async {
    final root = await Directory.systemTemp.createTemp('switch-result-');
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
    final gate = Completer<void>();
    late final _Fixture fixture;
    final playback =
        CatalogPlayback(
            storage: store,
            savedLookup: (_) async => false,
            resolvedPreparerFactory: (_, service, _) => TemporaryTrackPreparer(
              stagingRoot: Directory(p.join(root.path, 'staging')),
              download: (directory, _) async {
                fixture.downloads++;
                await gate.future;
                return File(
                  p.join(directory.path, 'input'),
                ).writeAsBytes([1, 2, 3]);
              },
              takeQualityMetadata: (_) => {'provider': service},
              cancelDownload: (_) async {},
              codec: (_) async => 'aac',
              container: (_) async => 'mp4',
              validate: (_) async => true,
            ),
          )
          ..defaultService = 'a'
          ..resolveDownloadService = (requested, _) async =>
              requested.isEmpty ? 'a' : requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service.isEmpty ? 'a' : service, 'aac_160');
    fixture = _Fixture(playback, gate);
    return fixture;
  }

  Future<void> until(bool Function() done) async {
    for (var i = 0; i < 300 && !done(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('cancelar la preparacion deja pausa sin error', () async {
    final fixture = await build();
    await handler.dispose();
    handler = MusicPlayerHandler(catalogPlaybackOverride: fixture.playback);
    final first = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    await until(() => fixture.downloads == 1);
    await handler.cancelCurrentPreparation();
    fixture.gate.complete();
    await first;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final state = handler.playbackState.value;
    expect(state.playing, isFalse);
    expect(state.processingState.name, isNot('error'));
    expect(state.errorMessage, isNull);
  });

  test('reintentar lanza una adquisicion nueva en vez de reutilizar', () async {
    final fixture = await build();
    await handler.dispose();
    handler = MusicPlayerHandler(catalogPlaybackOverride: fixture.playback);
    final first = handler.setQueueAndPlay([playableFromCatalogTrack(track)]);
    await until(() => fixture.downloads == 1);
    final retry = handler.retryCurrentPreparation();
    await until(() => fixture.downloads == 2);
    expect(fixture.downloads, 2);
    fixture.gate.complete();
    await Future.wait([first, retry]);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('la peticion se restaura con restorePlayingRequest', () async {
    final fixture = await build();
    fixture.gate.complete();
    final playback = fixture.playback;
    final lease = await playback.acquire(track, relay: false);
    await lease.release();
    final previous = playback.playingRequest(track);
    expect(previous, isNotNull);
    playback.setQualityOverride(track, 'aac_96', service: 'a');
    final other = await playback.acquire(track, relay: false);
    await other.release();
    playback.restorePlayingRequest(track, previous);
    expect(playback.playingRequest(track), previous);
    playback.restorePlayingRequest(track, null);
    expect(playback.playingRequest(track), isNull);
  });

  group('categorias de fallo', () {
    final cases = <String, QualitySwitchFailure>{
      'provider quality unavailable': QualitySwitchFailure.unavailable,
      'provider track not found': QualitySwitchFailure.unavailable,
      'provider timed out': QualitySwitchFailure.timedOut,
      'preparation timed out': QualitySwitchFailure.timedOut,
      'unsupported audio format': QualitySwitchFailure.unsupportedFormat,
      'cancelled': QualitySwitchFailure.cancelled,
      'provider network failed': QualitySwitchFailure.other,
    };
    cases.forEach((reason, expected) {
      test('$reason -> ${expected.name}', () {
        expect(
          qualitySwitchResultForError(CatalogPlaybackException(reason)).failure,
          expected,
        );
        expect(
          qualitySwitchResultForError(TemporaryTrackException(reason)).failure,
          expected,
        );
      });
    });

    test('verificacion lleva el id del proveedor', () {
      final result = qualitySwitchResultForError(
        const TemporaryVerificationRequired('tidal'),
      );
      expect(result.failure, QualitySwitchFailure.verificationRequired);
      expect(result.providerId, 'tidal');
      final viaCatalog = qualitySwitchResultForError(
        const CatalogPlaybackException('provider intervention required'),
        verificationProvider: 'qobuz',
      );
      expect(viaCatalog.providerId, 'qobuz');
      expect(
        qualitySwitchResultForError(StateError('x')).failure,
        QualitySwitchFailure.other,
      );
    });

    test('compatibilidad bool', () {
      expect(const QualitySwitchResult.success().ok, isTrue);
      expect(
        const QualitySwitchResult.failed(QualitySwitchFailure.other).ok,
        isFalse,
      );
    });
  });
}
