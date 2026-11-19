import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/temporary_track_preparer.dart';
import 'package:path/path.dart' as p;

Future<String?> _container(String _) async => 'mp4';

class _Probe {
  var running = 0;
  var maxRunning = 0;
  var started = 0;
  final order = <String>[];
  final gates = <String, Completer<void>>{};

  Future<String> call(String name) async {
    started++;
    running++;
    if (running > maxRunning) maxRunning = running;
    order.add(name);
    try {
      await gates.putIfAbsent(name, Completer<void>.new).future;
      return name;
    } finally {
      running--;
    }
  }

  void open(String name) {
    final gate = gates.putIfAbsent(name, Completer<void>.new);
    if (!gate.isCompleted) gate.complete();
  }
}

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('nunca hay dos peticiones en curso a la vez', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final results = [
      for (final name in ['a', 'b', 'c', 'd'])
        gate.run(() => probe(name), priority: ProviderRequestPriority.queue),
    ];
    await _settle();
    expect(probe.running, 1);
    for (final name in ['a', 'b', 'c', 'd']) {
      probe.open(name);
      await _settle();
    }
    expect(await Future.wait(results), ['a', 'b', 'c', 'd']);
    expect(probe.maxRunning, 1);
    expect(probe.started, 4);
    expect(gate.busy, isFalse);
    expect(gate.waiting, 0);
  });

  test('conserva el orden de llegada dentro de una prioridad', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final results = [
      for (final name in ['a', 'b', 'c'])
        gate.run(() => probe(name), priority: ProviderRequestPriority.queue),
    ];
    for (final name in ['a', 'b', 'c']) {
      await _settle();
      probe.open(name);
    }
    await Future.wait(results);
    expect(probe.order, ['a', 'b', 'c']);
  });

  test(
    'el primer plano pasa por delante de la cola sin cancelar la que va',
    () async {
      final gate = ProviderRequestGate();
      final probe = _Probe();
      final running = gate.run(
        () => probe('cola-en-curso'),
        priority: ProviderRequestPriority.queue,
      );
      await _settle();
      final waiting = [
        gate.run(
          () => probe('precarga'),
          priority: ProviderRequestPriority.prefetch,
        ),
        gate.run(
          () => probe('cola-espera'),
          priority: ProviderRequestPriority.queue,
        ),
        gate.run(
          () => probe('primer-plano'),
          priority: ProviderRequestPriority.foreground,
        ),
      ];
      await _settle();
      expect(probe.order, ['cola-en-curso']);
      expect(probe.running, 1);
      for (final name in [
        'cola-en-curso',
        'primer-plano',
        'cola-espera',
        'precarga',
      ]) {
        probe.open(name);
        await _settle();
      }
      expect(await running, 'cola-en-curso');
      await Future.wait(waiting);
      expect(probe.order, [
        'cola-en-curso',
        'primer-plano',
        'cola-espera',
        'precarga',
      ]);
      expect(probe.maxRunning, 1);
    },
  );

  test('promover una espera la adelanta sin saltarse la petición en curso', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final first = gate.run(() => probe('en-curso'));
    await _settle();
    ProviderTurn? low;
    final prefetch = gate.run(
      () => probe('precarga'),
      priority: ProviderRequestPriority.prefetch,
      onRequested: (turn) => low = turn,
    );
    final queue = gate.run(
      () => probe('cola'),
      priority: ProviderRequestPriority.queue,
    );
    await _settle();
    low!.promote(ProviderRequestPriority.foreground);
    probe.open('en-curso');
    await _settle();
    expect(probe.order, ['en-curso', 'precarga']);
    probe.open('precarga');
    probe.open('cola');
    await Future.wait([first, prefetch, queue]);
    expect(probe.maxRunning, 1);
  });

  test('libera el turno cuando la petición falla', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final failing = gate.run<String>(() async => throw StateError('fallo'));
    final next = gate.run(() => probe('siguiente'));
    await expectLater(failing, throwsA(isA<StateError>()));
    await _settle();
    expect(probe.order, ['siguiente']);
    probe.open('siguiente');
    await next;
    expect(gate.busy, isFalse);
  });

  test('una espera cancelada sale de la fila y no lanza su petición', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final holder = gate.run(() => probe('en-curso'));
    await _settle();
    final cancel = Completer<void>();
    final cancelled = gate.run(
      () => probe('cancelada'),
      cancelled: cancel.future,
    );
    final expectation = expectLater(
      cancelled,
      throwsA(isA<ProviderRequestCancelled>()),
    );
    final after = gate.run(() => probe('despues'));
    await _settle();
    expect(gate.waiting, 2);
    cancel.complete();
    await expectation;
    expect(gate.waiting, 1);
    probe.open('en-curso');
    await _settle();
    probe.open('despues');
    await Future.wait([holder, after]);
    expect(probe.order, ['en-curso', 'despues']);
    expect(probe.started, 2);
  });

  test('cancelar tras recibir el turno no interrumpe la petición', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    final cancel = Completer<void>();
    final result = gate.run(() => probe('a'), cancelled: cancel.future);
    await _settle();
    cancel.complete();
    probe.open('a');
    expect(await result, 'a');
  });

  test('el tiempo máximo libera el turno y avisa para cancelar', () async {
    final gate = ProviderRequestGate();
    final probe = _Probe();
    var cancelCalls = 0;
    final stuck = gate.run(
      () => probe('colgada'),
      maxTurn: const Duration(milliseconds: 50),
      onTimeout: () => cancelCalls++,
    );
    final next = gate.run(() => probe('siguiente'));
    await expectLater(stuck, throwsA(isA<ProviderTurnTimeout>()));
    expect(cancelCalls, 1);
    await _settle();
    expect(probe.order, ['colgada', 'siguiente']);
    probe.open('siguiente');
    await next;
    expect(gate.busy, isFalse);
    probe.open('colgada');
  });

  test('un TimeoutException propio de la petición no es tiempo máximo', () async {
    final gate = ProviderRequestGate();
    await expectLater(
      gate.run<void>(() async => throw TimeoutException('propio')),
      throwsA(isA<TimeoutException>()),
    );
    expect(gate.busy, isFalse);
  });

  test('liberar dos veces no entrega dos turnos', () async {
    final gate = ProviderRequestGate();
    final first = gate.request(ProviderRequestPriority.queue);
    final second = gate.request(ProviderRequestPriority.queue);
    final third = gate.request(ProviderRequestPriority.queue);
    await first.granted;
    first.release();
    first.release();
    await second.granted;
    expect(second.isHolding, isTrue);
    expect(third.isHolding, isFalse);
    second.release();
    await third.granted;
    third.release();
    expect(gate.busy, isFalse);
  });

  group('preparador', () {
    late Directory root;
    setUp(
      () async => root = await Directory.systemTemp.createTemp('gate-test-'),
    );
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    TemporaryTrackPreparer build(
      ProviderRequestGate gate,
      Future<File> Function(Directory, String) download, {
      Future<void> Function(String)? cancel,
      Duration timeout = const Duration(minutes: 5),
    }) => TemporaryTrackPreparer(
      container: _container,
      stagingRoot: root,
      gate: gate,
      timeout: timeout,
      download: download,
      cancelDownload: cancel ?? (_) async {},
      codec: (_) async => 'aac',
      validate: (_) async => true,
    );

    test('dos preparaciones a la vez descargan de una en una', () async {
      final gate = ProviderRequestGate();
      final probe = _Probe();
      Future<File> download(Directory dir, String id) async {
        await probe(id);
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      }

      final one = build(gate, download);
      final two = build(gate, download);
      final first = one.prepare('a');
      final second = two.prepare('b');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(probe.started, 1);
      probe.gates.values.single.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(probe.started, 2);
      for (final gateCompleter in probe.gates.values) {
        if (!gateCompleter.isCompleted) gateCompleter.complete();
      }
      await (await first).dispose();
      await (await second).dispose();
      expect(probe.maxRunning, 1);
    });

    test('el primer plano adelanta a la precarga en espera', () async {
      final gate = ProviderRequestGate();
      final order = <String>[];
      final holder = gate.request(ProviderRequestPriority.queue);
      await holder.granted;
      final prefetchService = build(gate, (dir, id) {
        order.add('precarga');
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      });
      final foregroundService = build(gate, (dir, id) {
        order.add('primer-plano');
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      });
      final low = prefetchService.prepare(
        'p',
        priority: ProviderRequestPriority.prefetch,
      );
      final high = foregroundService.prepare('f');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(order, isEmpty);
      holder.release();
      await (await high).dispose();
      await (await low).dispose();
      expect(order, ['primer-plano', 'precarga']);
    });

    test('promover una precarga en curso la sube de prioridad', () async {
      final gate = ProviderRequestGate();
      final order = <String>[];
      final holder = gate.request(ProviderRequestPriority.queue);
      await holder.granted;
      final slow = build(gate, (dir, id) {
        order.add('promovida');
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      });
      final queued = gate.run(() async {
        order.add('cola-general');
        return 1;
      }, priority: ProviderRequestPriority.queue);
      final background = slow.prepare(
        'x',
        priority: ProviderRequestPriority.prefetch,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      slow.promote('x');
      holder.release();
      await (await background).dispose();
      await queued;
      expect(order, ['promovida', 'cola-general']);
    });

    test('cancelar una preparación en espera libera su lugar', () async {
      final gate = ProviderRequestGate();
      final holder = gate.request(ProviderRequestPriority.queue);
      await holder.granted;
      var started = false;
      final service = build(gate, (dir, id) {
        started = true;
        return File(p.join(dir.path, 'source')).writeAsString('audio');
      });
      final visible = expectLater(
        service.prepare('x'),
        throwsA(isA<TemporaryTrackException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gate.waiting, 1);
      await service.cancel('x');
      await visible;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gate.waiting, 0);
      expect(started, isFalse);
      holder.release();
      expect(gate.busy, isFalse);
    });

    test('un fallo de la descarga libera el turno', () async {
      final gate = ProviderRequestGate();
      final service = build(gate, (dir, id) async {
        throw const TemporaryTrackException('provider download failed');
      });
      await expectLater(
        service.prepare('x'),
        throwsA(isA<TemporaryTrackException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(gate.busy, isFalse);
    });

    test('al vencer la preparación se cancela y el turno se libera', () async {
      final gate = ProviderRequestGate();
      final cancelled = <String>[];
      final never = Completer<File>();
      final service = TemporaryTrackPreparer(
        container: _container,
        stagingRoot: root,
        gate: gate,
        timeout: const Duration(milliseconds: 300),
        download: (dir, id) => never.future,
        cancelDownload: (id) async {
          cancelled.add(id);
          never.completeError(StateError('cancelled'));
        },
        codec: (_) async => 'aac',
        validate: (_) async => true,
      );
      await expectLater(
        service.prepare('x'),
        throwsA(isA<TemporaryTrackException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(gate.busy, isFalse);
      expect(cancelled, isNotEmpty);
    });
  });

  group('enfriamiento', () {
    test('un 429 con espera de 60 s o menos deja 60 s y un timeout corto sube a 30 s', () {
      var now = DateTime.utc(2026, 11, 16, 12);
      final cooldown = ProviderCooldown(
        clock: () => now,
        store: _MemoryStore(),
      );
      cooldown.noteAttempts([
        {'provider': 'tidal', 'error_type': 'rate_limited', 'retry_after_s': 5},
        {'provider': 'amazon', 'error_type': 'rate_limit', 'retry_after_s': 60},
        {'provider': 'qobuz', 'error_type': 'timeout', 'retry_after_s': 5},
      ]);
      expect(cooldown.remaining('tidal'), const Duration(seconds: 60));
      expect(cooldown.remaining('amazon'), const Duration(seconds: 60));
      expect(cooldown.remaining('qobuz'), const Duration(seconds: 30));
      now = now.add(const Duration(seconds: 61));
      expect(cooldown.isCoolingDown('tidal'), isFalse);
    });

    test('una espera mayor se respeta y el suelo no la acorta', () {
      final cooldown = ProviderCooldown(
        clock: () => DateTime.utc(2026, 11, 16, 12),
        store: _MemoryStore(),
      );
      cooldown.noteAttempts([
        {'provider': 'tidal', 'error_type': 'rate_limited', 'retry_after_s': 900},
      ]);
      cooldown.noteRateLimited('tidal', 10);
      expect(cooldown.remaining('tidal'), const Duration(seconds: 900));
    });
  });
}

class _MemoryStore implements ProviderCooldownStore {
  final Map<String, int> values = {};

  @override
  Future<Map<String, int>> readAll() async => Map.of(values);

  @override
  void write(String key, int value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}
