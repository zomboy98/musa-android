import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/catalog_audio_store.dart';
import 'package:mornye/services/catalog_id_resolver.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/ffmpeg_probe.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/streaming_quality_resolver.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:mornye/utils/failure_cause.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => ProviderCooldown.instance = ProviderCooldown());
  const track = Track(
    id: 'relay',
    source: 'spotify',
    name: 'R',
    artistName: 'A',
    albumName: 'B',
    duration: 1,
  );

  Future<(CatalogPlayback, List<String>)> build(
    Set<String> failing, {
    bool alternatives = true,
    Duration delay = Duration.zero,
    String codec = 'aac',
    List<(String, bool)>? fallbacks,
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
      resolvedPreparerFactory: (_, service, useFallback) {
        fallbacks?.add((service, useFallback));
        return TemporaryTrackPreparer(
          stagingRoot: Directory('${root.path}/staging'),
          download: (dir, _) async {
            tried.add(service);
            if (delay > Duration.zero) await Future<void>.delayed(delay);
            if (failing.contains(service)) {
              throw const TemporaryTrackException('provider timed out');
            }
            return File('${dir.path}/input').writeAsString('audio');
          },
          takeQualityMetadata: (_) => {'provider': service},
          cancelDownload: (_) async {},
          codec: (_) async => codec,
          container: (_) async => codec == 'flac' ? 'flac' : 'mp4',
          validate: (_) async => true,
        );
      },
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

  test('un proveedor que expira pasa al siguiente y suena', () async {
    final (playback, tried) = await build({'a'});
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b']);
    expect(await File(lease.path).readAsString(), isNotEmpty);
    await lease.release();
  });

  test('el relevo prueba cada candidato forzado sin recorrer todos', () async {
    final fallbacks = <(String, bool)>[];
    final (playback, tried) = await build({'a', 'b'}, fallbacks: fallbacks);
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b', 'c']);
    expect(fallbacks, [('a', false), ('b', false), ('c', false)]);
    await lease.release();
  });

  test(
    'sin relevo la petición normal conserva el recorrido completo',
    () async {
      final fallbacks = <(String, bool)>[];
      final (playback, tried) = await build(
        {},
        alternatives: false,
        fallbacks: fallbacks,
      );
      final lease = await playback.acquire(track);
      expect(tried, ['a']);
      expect(fallbacks, [('a', true)]);
      await lease.release();
    },
  );

  test('con relevo ningún proveedor recibe más de una petición', () async {
    final fallbacks = <(String, bool)>[];
    final (playback, tried) = await build({
      'a',
      'b',
      'c',
    }, fallbacks: fallbacks);
    await expectLater(
      playback.acquire(track),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(tried, ['a', 'b', 'c']);
    expect(tried.toSet().length, tried.length);
    expect(tried.length, lessThanOrEqualTo(3));
    expect(fallbacks.every((entry) => !entry.$2), isTrue);
  });

  test('con relevo el primero que responde gana y no se piden más', () async {
    final (playback, tried) = await build({'a'});
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b']);
    await lease.release();
  });

  test(
    'sin relevo explícito el primer intento conserva el recorrido',
    () async {
      final fallbacks = <(String, bool)>[];
      final (playback, tried) = await build({}, fallbacks: fallbacks);
      final lease = await playback.acquire(track, relay: false);
      expect(tried, ['a']);
      expect(fallbacks, [('a', true)]);
      await lease.release();
    },
  );

  test('sin relevo un fallo no añade intentos', () async {
    final fallbacks = <(String, bool)>[];
    final (playback, tried) = await build({'a'}, fallbacks: fallbacks);
    await expectLater(
      playback.acquire(track, relay: false),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(tried, ['a']);
    expect(fallbacks, [('a', true)]);
  });

  test('el relevo exitoso no emite error y avisa una sola vez', () async {
    final (playback, tried) = await build({'a'});
    final lines = <String>[];
    playback.failureDiagnostic = lines.add;
    var notices = 0;
    playback.qualityNotice.addListener(() => notices++);
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service, 'opus');
    final lease = await playback.acquire(track, initial: true);
    expect(tried, ['a', 'b']);
    expect(notices, 1);
    final notice = playback.qualityNotice.value!;
    expect(notice.requested, 'Opus');
    expect(notice.actual, 'AAC');
    expect(notice.unavailable, isFalse);
    expect(lines.where((l) => l.startsWith('preparation failed')), isEmpty);
    expect(
      lines.where((l) => l.startsWith('relay attempt failed attempt=1/3')),
      hasLength(1),
    );
    expect(
      lines.where((l) => l.startsWith('relay succeeded attempt=2/3')),
      hasLength(1),
    );
    for (final line in lines) {
      expect(line, isNot(contains('http')));
      expect(line, isNot(contains('://')));
    }
    await lease.release();
  });

  test('si todos fallan hay un único error final', () async {
    final (playback, tried) = await build({'a', 'b', 'c'});
    final lines = <String>[];
    playback.failureDiagnostic = lines.add;
    var notices = 0;
    playback.qualityNotice.addListener(() => notices++);
    await expectLater(
      playback.acquire(track, initial: true),
      throwsA(isA<CatalogPlaybackException>()),
    );
    expect(notices, 0);
    expect(
      lines.where((l) => l.startsWith('preparation failed')),
      hasLength(1),
    );
    expect(
      lines.where((l) => l.startsWith('relay attempt failed')),
      hasLength(3),
    );
    expect(tried, ['a', 'b', 'c']);
  });

  test('si todos fallan hay un único error final', () async {
    final (playback, tried) = await build({'a', 'b', 'c'});
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'providers exhausted',
        ),
      ),
    );
    expect(tried, ['a', 'b', 'c']);
  });

  test('un candidato en enfriamiento se salta sin llamarlo', () async {
    ProviderCooldown.instance.note('b', 900);
    final (playback, tried) = await build({'a'});
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'c']);
    await lease.release();
  });

  test('con todos los candidatos en enfriamiento falla sin pedir', () async {
    ProviderCooldown.instance.note('b', 900);
    ProviderCooldown.instance.note('c', 900);
    final (playback, tried) = await build({'a'});
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'providers exhausted',
        ),
      ),
    );
    expect(tried, ['a']);
  });

  test('sin relevo disponible el error original se conserva', () async {
    final (playback, tried) = await build({'a'}, alternatives: false);
    await expectLater(
      playback.acquire(track),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'provider timed out',
        ),
      ),
    );
    expect(tried, ['a']);
  });

  test(
    'candidatos: otros proveedores con el mismo formato, luego equivalentes y al final lo más ligero del mismo',
    () {
      Extension provider(String id, List<(String, String)> options) =>
          Extension(
            id: id,
            name: id,
            displayName: id,
            version: '1',
            description: '',
            enabled: true,
            status: 'loaded',
            hasDownloadProvider: true,
            qualityOptions: [
              for (final o in options)
                QualityOption(id: o.$1, label: o.$1, kind: o.$2),
            ],
          );
      final amazon = provider('amazon', [
        ('best', 'lossless'),
        ('opus', 'lossy'),
        ('ac4', 'spatial'),
      ]);
      final tidal = provider('tidal-web', [
        ('DOLBY_ATMOS', 'spatial'),
        ('LOSSLESS', 'lossless'),
        ('HIGH', 'lossy'),
      ]);
      final candidates = streamingRelayCandidates(
        settingsQuality: 'ac4',
        first: const StreamingRequest('amazon', 'ac4'),
        extensions: [tidal, amazon],
      );
      expect(candidates.map((c) => '${c.serviceId}/${c.qualityId}').toList(), [
        'tidal-web/DOLBY_ATMOS',
        'amazon/best',
        'tidal-web/LOSSLESS',
        'amazon/opus',
      ]);
    },
  );

  test('la precarga releva por los mismos proveedores que la reproducción', () async {
    final fallbacks = <(String, bool)>[];
    final (playback, tried) = await build({'a'}, fallbacks: fallbacks);
    var asked = 0;
    final alternatives = playback.streamingAlternatives!;
    playback.streamingAlternatives = (first, quality, useFallback) {
      asked++;
      return alternatives(first, quality, useFallback);
    };
    await playback.prefetch(track);
    expect(tried, ['a', 'b']);
    expect(asked, 1);
    expect(fallbacks.every((entry) => !entry.$2), isTrue);
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b']);
    await lease.release();
  });

  test('el fallo de la precarga lleva la causa de cada intento', () async {
    final (playback, tried) = await build({'a', 'b', 'c'});
    await expectLater(
      playback.prefetch(track),
      throwsA(
        isA<CatalogPlaybackException>()
            .having((e) => e.detail, 'detail', contains('service=a'))
            .having((e) => e.detail, 'detail', contains('service=b'))
            .having((e) => e.detail, 'detail', isNot(contains('://'))),
      ),
    );
    expect(tried, ['a', 'b', 'c']);
  });

  test('una precarga sin plazo cumplido no deja al proveedor primero ocupado', () async {
    final (playback, tried) = await build(
      {},
      delay: const Duration(milliseconds: 200),
    );
    playback.firstAttemptBudget = const Duration(milliseconds: 50);
    await playback.prefetch(track);
    expect(tried.first, 'a');
    expect(tried, contains('b'));
  });

  test('una precarga lenta no tumba la reproducción que se le une', () async {
    final (playback, tried) = await build(
      {},
      delay: const Duration(milliseconds: 200),
    );
    playback.firstAttemptBudget = const Duration(seconds: 5);
    final prefetch = playback.prefetch(track);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final lease = await playback.acquire(track, initial: true);
    await prefetch;
    expect(tried, ['a']);
    expect(await File(lease.path).readAsString(), isNotEmpty);
    await lease.release();
  });

  test('sin relevo un fallo no prueba otros formatos', () async {
    final (playback, tried) = await build({'a'});
    var asked = 0;
    playback.streamingAlternatives = (first, quality, _) async {
      asked++;
      return const [StreamingRequest('b', 'aac_160')];
    };
    await expectLater(
      playback.acquire(track, relay: false),
      throwsA(
        isA<CatalogPlaybackException>().having(
          (e) => e.category,
          'category',
          'provider timed out',
        ),
      ),
    );
    expect(tried, ['a']);
    expect(asked, 0);
  });

  test('el aviso compara con la calidad pedida tras un relevo', () async {
    final (playback, tried) = await build({'a'});
    final lease = await playback.acquire(track, initial: true);
    expect(tried, ['a', 'b']);
    expect(playback.qualityNotice.value?.requested, 'FLAC');
    expect(playback.qualityNotice.value?.actual, 'AAC');
    await lease.release();
  });

  test('el aviso espera a los bits del archivo y sale una sola vez', () async {
    final (playback, _) = await build({}, codec: 'flac');
    playback.resolveStreaming = (quality, service, _) async =>
        StreamingRequest(service, 'eac3');
    playback.audioFileFacts = (_) async => const PrimaryAudioProperties(
      codec: 'flac',
      bitDepth: 24,
      sampleRate: 48000,
    );
    var notices = 0;
    playback.qualityNotice.addListener(() => notices++);
    final lease = await playback.acquire(track, initial: true);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(notices, 1);
    expect(playback.qualityNotice.value?.actual, 'Hi-Res 24-bit');
    expect(playback.qualityNotice.value?.requested, 'E-AC-3');
    await lease.release();
  });

  test(
    'si el archivo no se puede leer el aviso sale igual con la calidad servida',
    () async {
      final (playback, _) = await build({}, codec: 'flac');
      playback.resolveStreaming = (quality, service, _) async =>
          StreamingRequest(service, 'eac3');
      playback.audioFileFacts = (_) async => throw StateError('sin sonda');
      var notices = 0;
      playback.qualityNotice.addListener(() => notices++);
      final lease = await playback.acquire(track, initial: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(notices, 1);
      expect(playback.qualityNotice.value?.actual, 'FLAC');
      await lease.release();
    },
  );

  Future<CatalogIdResolver> resolverFor(
    List<String> lines, {
    CatalogIdSearch? search,
  }) async {
    final dir = await Directory.systemTemp.createTemp('relay-ids-');
    addTearDown(() => dir.delete(recursive: true));
    return CatalogIdResolver(
      enabled: () async => true,
      directory: () async => dir,
      search: search ?? (_, _, _) async => <Map<String, dynamic>>[],
      diagnostic: lines.add,
    );
  }

  test('el resolutor se consulta solo para los candidatos forzados', () async {
    final (playback, tried) = await build({'a', 'b'});
    final lines = <String>[];
    playback.idResolver = await resolverFor(lines);
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b', 'c']);
    expect(lines, hasLength(2));
    expect(lines[0], contains('provider=b'));
    expect(lines[1], contains('provider=c'));
    expect(lines.any((l) => l.contains('provider=a')), isFalse);
    await lease.release();
  });

  test('sin relevo el resolutor no se consulta', () async {
    final (playback, tried) = await build({}, alternatives: false);
    final lines = <String>[];
    playback.idResolver = await resolverFor(lines);
    final lease = await playback.acquire(track);
    expect(tried, ['a']);
    expect(lines, isEmpty);
    await lease.release();
  });

  test('un resolutor que lanza no altera el relevo', () async {
    final (playback, tried) = await build({'a'});
    playback.idResolver = _ThrowingResolver();
    final lease = await playback.acquire(track);
    expect(tried, ['a', 'b']);
    await lease.release();
  });

  test('un resolutor lento no bloquea el intento del candidato', () async {
    final (playback, tried) = await build({'a'});
    playback.streamingAlternatives = (first, quality, _) async => [
      const StreamingRequest('beatport', 'LOSSLESS'),
    ];
    playback.idResolutionBudget = const Duration(milliseconds: 20);
    final lines = <String>[];
    playback.idResolver = await resolverFor(
      lines,
      search: (_, _, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        return <Map<String, dynamic>>[];
      },
    );
    final lease = await playback.acquire(
      const Track(
        id: 'relay',
        source: 'spotify',
        name: 'R',
        artistName: 'A',
        albumName: 'B',
        duration: 1,
        isrc: 'USAT22607218',
      ),
    );
    expect(tried, ['a', 'beatport']);
    expect(lines.any((l) => l.contains('result=timeout')), isTrue);
    await lease.release();
    await Future<void>.delayed(const Duration(milliseconds: 350));
  });

  test(
    'el enriquecimiento corre una vez y no bloquea si no responde',
    () async {
      final (playback, _) = await build({});
      var calls = 0;
      playback.enrichmentBudget = const Duration(milliseconds: 30);
      playback.trackEnricher = (_) {
        calls++;
        return Completer<Track>().future;
      };
      const bare = Track(
        id: 'enrich',
        source: 'apple-music',
        name: 'R (from X)',
        artistName: 'A',
        albumName: 'B',
        duration: 0,
      );
      final lease = await playback.acquire(bare);
      await lease.release();
      final again = await playback.acquire(bare);
      await again.release();
      expect(calls, 1);
    },
  );

  test(
    'un no encontrado reintenta una vez con la consulta simplificada',
    () async {
      SharedPreferences.setMockInitialValues({});
      final root = await Directory.systemTemp.createTemp('relay-simple-');
      addTearDown(() => root.delete(recursive: true));
      final store = CatalogAudioStore(
        cacheDirectory: Directory('${root.path}/cache'),
        libraryDirectory: Directory('${root.path}/library'),
      );
      await store.initialize();
      final tried = <String>[];
      final playback = CatalogPlayback(
        storage: store,
        resolvedPreparerFactory: (track, service, useFallback) {
          return TemporaryTrackPreparer(
            stagingRoot: Directory('${root.path}/staging'),
            download: (dir, _) async {
              tried.add(service);
              if (tried.length == 1) {
                throw TemporaryTrackException(
                  providerFailureReasonFor('not_found'),
                );
              }
              return File('${dir.path}/input').writeAsString('audio');
            },
            takeQualityMetadata: (_) => {'provider': service},
            cancelDownload: (_) async {},
            codec: (_) async => 'aac',
            container: (_) async => 'mp4',
            validate: (_) async => true,
          );
        },
      );
      playback.defaultService = 'a';
      playback.resolveDownloadService = (requested, _) async => requested;
      playback.resolveStreaming = (quality, service, _) async =>
          StreamingRequest(service, quality);
      playback.streamingAlternatives = (first, quality, _) async => [
        const StreamingRequest('b', 'aac_160'),
      ];
      const annotated = Track(
        id: 'simple',
        source: 'apple-music',
        name: 'Canción (feat. X)',
        artistName: 'A, B',
        albumName: 'B',
        duration: 1,
      );
      final lease = await playback.acquire(annotated);
      await lease.release();
      expect(tried, ['a', 'a']);
    },
  );
}

class _ThrowingResolver extends CatalogIdResolver {
  @override
  Future<CatalogNativeId?> resolve(
    Track track,
    String serviceId, {
    Duration timeout = const Duration(seconds: 6),
  }) async => throw StateError('falla');
}
