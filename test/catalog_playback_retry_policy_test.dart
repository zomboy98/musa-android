import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/provider_retry_policy.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:shared_preferences/shared_preferences.dart';

Track _track(String id) => Track(
  id: id,
  source: 'spotify',
  name: id,
  artistName: 'A',
  albumName: 'B',
  duration: 1,
);

class _Run {
  _Run(this.playback);

  final CatalogPlayback playback;
  final tried = <String>[];
  final marks = <int>[];
  var failing = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderRetryPolicy policy;

  setUp(() {
    ProviderCooldown.instance = ProviderCooldown();
    ProviderRequestGate.instance = ProviderRequestGate();
    policy = ProviderRetryPolicy(spacing: Duration.zero);
  });

  Future<_Run> build({ProviderRetryPolicy? custom}) async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('retry-playback-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    late final _Run run;
    final watch = Stopwatch()..start();
    final playback = CatalogPlayback(
      storage: store,
      resolvedPreparerFactory: (_, service, useFallback) {
        return TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            run.tried.add(service);
            run.marks.add(watch.elapsedMilliseconds);
            if (run.failing) {
              throw const TemporaryTrackException('provider timed out');
            }
            return await File('${dir.path}/input').writeAsString('audio');
          },
          takeQualityMetadata: (_) => {'provider': service},
          cancelDownload: (_) async {},
          codec: (_) async => 'aac',
          container: (_) async => 'mp4',
          validate: (_) async => true,
        );
      },
    );
    run = _Run(playback);
    playback.defaultService = 'a';
    playback.retryPolicy = custom ?? policy;
    playback.resolveDownloadService = (requested, _) async => requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service, quality);
    return run;
  }

  Future<void> prefetchIgnoringFailure(_Run run, Track track) async {
    try {
      await run.playback.prefetch(track);
    } catch (_) {}
  }

  test('la misma pista no se repite en el proveedor dentro del retroceso',
      () async {
    final run = await build();
    await prefetchIgnoringFailure(run, _track('p1'));
    await prefetchIgnoringFailure(run, _track('p1'));
    expect(run.tried, ['a']);
    await prefetchIgnoringFailure(run, _track('p2'));
    expect(run.tried, ['a', 'a']);
  });

  test('la peticion manual se salta el retroceso de la pista', () async {
    final run = await build();
    await prefetchIgnoringFailure(run, _track('p1'));
    run.failing = false;
    final lease = await run.playback.acquire(_track('p1'), relay: false);
    expect(run.tried, ['a', 'a']);
    await lease.release();
  });

  test('la peticion manual respeta la espera indicada por el proveedor',
      () async {
    final run = await build();
    ProviderCooldown.instance.note('a', 60);
    run.failing = false;
    await expectLater(
      run.playback.acquire(_track('p1'), relay: false),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(run.tried, isEmpty);
  });

  test('el tope de intentos por pista detiene los reintentos automaticos',
      () async {
    final run = await build(
      custom: ProviderRetryPolicy(
        spacing: Duration.zero,
        backoff: const [Duration.zero],
        maxAttempts: 2,
      ),
    );
    for (var i = 0; i < 5; i++) {
      await prefetchIgnoringFailure(run, _track('p1'));
    }
    expect(run.tried, ['a', 'a']);
  });

  test('respeta la separacion minima entre peticiones al mismo proveedor',
      () async {
    final run = await build(
      custom: ProviderRetryPolicy(spacing: const Duration(milliseconds: 300)),
    );
    run.failing = false;
    final first = await run.playback.acquire(_track('s1'), relay: false);
    final second = await run.playback.acquire(_track('s2'), relay: false);
    expect(run.marks[1] - run.marks[0], greaterThanOrEqualTo(280));
    await first.release();
    await second.release();
  });
}
