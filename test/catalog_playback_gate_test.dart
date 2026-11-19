import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
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
  final fallbacks = <(String, bool)>[];
  var running = 0;
  var maxRunning = 0;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    ProviderCooldown.instance = ProviderCooldown();
    ProviderRequestGate.instance = ProviderRequestGate();
  });

  Future<_Run> build({
    Set<String> failing = const {},
    Duration delay = Duration.zero,
    bool alternatives = true,
  }) async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('gate-playback-');
    addTearDown(() => root.delete(recursive: true));
    final store = CatalogAudioStore(
      cacheDirectory: Directory('${root.path}/cache'),
      libraryDirectory: Directory('${root.path}/library'),
    );
    await store.initialize();
    late final _Run run;
    final playback = CatalogPlayback(
      storage: store,
      resolvedPreparerFactory: (_, service, useFallback) {
        run.fallbacks.add((service, useFallback));
        return TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            run.tried.add(service);
            run.running++;
            if (run.running > run.maxRunning) run.maxRunning = run.running;
            try {
              if (delay > Duration.zero) await Future<void>.delayed(delay);
              if (failing.contains(service)) {
                throw const TemporaryTrackException('provider timed out');
              }
              return await File('${dir.path}/input').writeAsString('audio');
            } finally {
              run.running--;
            }
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
    playback.resolveDownloadService = (requested, _) async => requested;
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service, quality);
    if (alternatives) {
      playback.streamingAlternatives = (first, quality, _) async => [
        const StreamingRequest('b', 'aac_160'),
        const StreamingRequest('c', 'aac_160'),
      ];
    }
    return run;
  }

  test('la precarga va a un único proveedor sin recorrido del motor', () async {
    final run = await build();
    await run.playback.prefetch(_track('p1'));
    expect(run.tried, ['a']);
    expect(run.fallbacks, [('a', false)]);
  });

  test('la precarga no pide nada si el proveedor está en enfriamiento', () async {
    ProviderCooldown.instance.note('a', 900);
    final run = await build();
    await expectLater(
      run.playback.prefetch(_track('p1')),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(run.tried, isEmpty);
  });

  test('el primer intento no sale si su proveedor está enfriado', () async {
    ProviderCooldown.instance.note('a', 900);
    final run = await build();
    final lease = await run.playback.acquire(_track('f1'));
    expect(run.tried, ['b']);
    await lease.release();
  });

  test('sin relevo y con enfriamiento no se envía ninguna petición', () async {
    ProviderCooldown.instance.note('a', 900);
    final run = await build(alternatives: false);
    await expectLater(
      run.playback.acquire(_track('f1')),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(run.tried, isEmpty);
  });

  test('el cambio de calidad puede pedir sin recorrido del motor', () async {
    final run = await build();
    final lease = await run.playback.acquire(
      _track('q1'),
      relay: false,
      engineFallback: false,
    );
    expect(run.tried, ['a']);
    expect(run.fallbacks, [('a', false)]);
    await lease.release();
  });

  test('una precarga y una reproducción nunca piden a la vez', () async {
    final run = await build(delay: const Duration(milliseconds: 80));
    final prefetch = run.playback.prefetch(_track('p1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final lease = await run.playback.acquire(_track('f1'), initial: true);
    await prefetch;
    expect(run.maxRunning, 1);
    expect(run.tried.length, 2);
    await lease.release();
  });

  test('la canción pedida pasa por delante de una precarga en espera', () async {
    final run = await build(delay: const Duration(milliseconds: 80));
    final holder = ProviderRequestGate.instance.request(
      ProviderRequestPriority.queue,
    );
    await holder.granted;
    final order = <String>[];
    final prefetch = run.playback.prefetch(_track('p1')).then((_) {
      order.add('precarga');
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final foreground = run.playback.acquire(_track('f1'), initial: true).then((
      lease,
    ) {
      order.add('primer-plano');
      return lease;
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    holder.release();
    final lease = await foreground;
    await prefetch;
    expect(order, ['primer-plano', 'precarga']);
    expect(run.maxRunning, 1);
    await lease.release();
  });

  test('una precarga en espera sube de prioridad si se pide esa canción', () async {
    final run = await build(delay: const Duration(milliseconds: 60));
    final holder = ProviderRequestGate.instance.request(
      ProviderRequestPriority.queue,
    );
    await holder.granted;
    final order = <String>[];
    final other = ProviderRequestGate.instance.run<void>(() async {
      order.add('cola con ${run.tried.length} descarga(s) previas');
    }, priority: ProviderRequestPriority.queue);
    final prefetch = run.playback.prefetch(_track('same')).then((_) {
      order.add('canción');
    });
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final foreground = run.playback.acquire(_track('same'), initial: true);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    holder.release();
    final lease = await foreground;
    await prefetch;
    await other;
    expect(order.first, 'cola con 1 descarga(s) previas');
    expect(run.tried, ['a']);
    await lease.release();
  });
}
