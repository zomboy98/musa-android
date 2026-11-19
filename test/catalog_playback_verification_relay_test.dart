import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/download_request_payload.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/services/verification_contract.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const track = Track(
    id: 'verify',
    source: 'spotify',
    name: 'R',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );

  Future<(CatalogPlayback, List<String>)> build(
    Set<String> failing, {
    Set<String> verifying = const {},
    bool alternatives = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('relay-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    final tried = <String>[];
    final playback = CatalogPlayback(
      storage: store,
      resolvedPreparerFactory: (_, service, _) => TemporaryTrackPreparer(
        stagingRoot: Directory('${root.path}/staging'),
        download: (dir, _) async {
          tried.add(service);
          if (verifying.contains(service)) {
            throw TemporaryVerificationRequired(service);
          }
          if (failing.contains(service)) {
            throw const TemporaryTrackException('provider timed out');
          }
          return File('${dir.path}/input').writeAsString('audio');
        },
        takeQualityMetadata: (_) => {'provider': service},
        cancelDownload: (_) async {},
        codec: (_) async => 'aac',
        container: (_) async => 'mp4',
        validate: (_) async => true,
      ),
    );
    playback.defaultService = 'a';
    playback.resolveDownloadService = (requested, _) async => requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service, quality);
    if (alternatives) {
      playback.streamingAlternatives = (first, quality, _) async => [
        const StreamingRequest('b', 'aac_160'),
        const StreamingRequest('c', 'aac_160'),
      ];
    }
    return (playback, tried);
  }

  test('verificación pendiente: se prueba el siguiente y suena', () async {
    final (playback, tried) = await build({}, verifying: {'a'});
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b']);
    expect(await File(lease.path).readAsString(), isNotEmpty);
    expect(playback.verificationBlock.value, isNull);
    await lease.release();
  });

  test('todos piden verificación: un único aviso con el proveedor', () async {
    final (playback, tried) = await build({}, verifying: {'a', 'b', 'c'});
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'provider intervention required',
        ),
      ),
    );
    expect(tried, ['a', 'b', 'c']);
    expect(playback.verificationBlock.value?.extensionId, 'a');
  });

  test(
    'verificación en uno y fallo en otros: avisa de la verificación',
    () async {
      final (playback, tried) = await build({'b', 'c'}, verifying: {'a'});
      await expectLater(
        playback.acquire(track),
        throwsA(
          isA<CatalogPlaybackException>().having(
            (e) => e.category,
            'category',
            'provider intervention required',
          ),
        ),
      );
      expect(tried, ['a', 'b', 'c']);
      expect(playback.verificationBlock.value?.extensionId, 'a');
    },
  );

  test('sin relevo la verificación se avisa sin probar otros', () async {
    final (playback, tried) = await build(
      {},
      verifying: {'a'},
      alternatives: false,
    );
    await expectLater(
      playback.acquire(track),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(tried, ['a']);
    expect(playback.verificationBlock.value?.extensionId, 'a');
  });

  test('el botón de verificar llama a la acción de verificación', () async {
    var resumed = 0;
    final calls = <String>[];
    final facade = InterimVerificationFacade(
      openVerification: (id, _) async {
        calls.add(id);
        return true;
      },
    );
    final op = facade.begin(
      extensionId: 'amazon',
      providerName: 'Amazon',
      kind: VerificationOperation.track,
      resume: () => resumed++,
    );
    expect(
      await facade.verifyAndResume(op.operationId),
      VerificationOutcome.resumed,
    );
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['amazon']);
    expect(resumed, 1);
  });

  test('la verificación en curso no se corta por el plazo del intento', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('verify-budget-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory(p.join(root.path, 'cache')),
      libraryDirectory: Directory(p.join(root.path, 'library')),
    );
    await store.initialize();
    final playback = CatalogPlayback(
      storage: store,
      preparerFactoryWithVerification: (track, verify) =>
          TemporaryTrackPreparer.platform(
            stagingRoot: Directory(p.join(root.path, 'staging')),
            payload: (dir, id) => DownloadRequestPayload(
              trackName: track.name,
              artistName: '',
              albumName: '',
              outputDir: dir.path,
              filenameFormat: 'track',
              itemId: id,
            ),
            acquireDirectory: (_) async => 'scope',
            releaseDirectory: (_) async {},
            transfer: (request) async => {
              'success': false,
              'error_type': 'verification_required',
              'service': 'a',
            },
            verify: verify,
            cancelTransfer: (_) async {},
            codec: (_) async => 'aac',
            validate: (_) async => true,
          ),
    );
    playback.defaultService = 'a';
    playback.firstAttemptBudget = const Duration(milliseconds: 50);
    playback.streamingAlternatives = (first, quality, _) async => const [];
    playback.verifyExtension = (_, _) async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return false;
    };
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'provider intervention required',
        ),
      ),
    );
    expect(playback.verificationBlock.value, isNotNull);
  });
}
