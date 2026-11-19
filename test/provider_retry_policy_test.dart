import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_retry_policy.dart';

class _Store implements ProviderCooldownStore {
  final Map<String, int> values = {};

  @override
  Future<Map<String, int>> readAll() async => Map.of(values);

  @override
  void write(String key, int value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

void main() {
  late DateTime now;
  late ProviderCooldown cooldown;
  late ProviderRetryPolicy policy;

  setUp(() {
    now = DateTime.utc(2026, 11, 16, 12);
    cooldown = ProviderCooldown(clock: () => now, store: _Store());
    policy = ProviderRetryPolicy(
      clock: () => now,
      cooldown: cooldown,
      spacing: Duration.zero,
    );
  });

  test('la misma pista no se repite dentro del retroceso creciente', () {
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 30));
    now = now.add(const Duration(seconds: 31));
    expect(policy.blockedFor('tidal', 'k'), Duration.zero);
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 60));
    now = now.add(const Duration(seconds: 61));
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 120));
    now = now.add(const Duration(seconds: 121));
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 120));
  });

  test('otra pista u otro proveedor no queda bloqueado', () {
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'otra'), Duration.zero);
    expect(policy.blockedFor('amazon', 'k'), Duration.zero);
  });

  test('un acierto reinicia el retroceso', () {
    policy.recordFailure('tidal', 'k');
    policy.recordFailure('tidal', 'k');
    policy.recordSuccess('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), Duration.zero);
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 30));
  });

  test('usa la espera indicada por el proveedor si existe', () {
    policy.recordFailure('tidal', 'k', retryAfter: const Duration(seconds: 75));
    expect(policy.blockedFor('tidal', 'k'), const Duration(seconds: 75));
  });

  test('el tope de intentos por pista y proveedor bloquea lo automatico', () {
    for (var i = 0; i < ProviderRetryPolicy.defaultMaxAttempts; i++) {
      expect(policy.blockedFor('tidal', 'k'), Duration.zero);
      policy.recordAttempt('tidal', 'k');
    }
    expect(policy.blockedFor('tidal', 'k') > Duration.zero, isTrue);
    expect(policy.exhausted('tidal', 'k'), isTrue);
    expect(policy.blockedFor('tidal', 'k', manual: true), Duration.zero);
    expect(policy.blockedFor('tidal', 'otra'), Duration.zero);
  });

  test('la peticion manual se salta el retroceso pero no el enfriamiento', () {
    policy.recordFailure('tidal', 'k');
    expect(policy.blockedFor('tidal', 'k', manual: true), Duration.zero);
    cooldown.noteRateLimited('tidal', 300);
    expect(
      policy.blockedFor('tidal', 'k', manual: true),
      const Duration(seconds: 300),
    );
    expect(
      policy.blockedFor('tidal', 'k') >= const Duration(seconds: 300),
      isTrue,
    );
  });

  test('la espera explicita del proveedor frena tambien la peticion manual', () {
    cooldown.noteAttempts([
      {'provider': 'tidal', 'error_type': 'timeout', 'retry_after_s': 60},
    ]);
    expect(
      policy.blockedFor('tidal', 'k', manual: true),
      const Duration(seconds: 60),
    );
  });

  test('respeta la separacion minima entre peticiones al mismo proveedor',
      () async {
    final spaced = ProviderRetryPolicy(
      cooldown: cooldown,
      spacing: const Duration(milliseconds: 200),
    );
    final marks = <int>[];
    final watch = Stopwatch()..start();
    await Future.wait([
      for (var i = 0; i < 3; i++)
        spaced
            .spaceRequest('tidal')
            .then((_) => marks.add(watch.elapsedMilliseconds)),
    ]);
    expect(marks[0], lessThan(100));
    expect(marks[1], greaterThanOrEqualTo(190));
    expect(marks[2], greaterThanOrEqualTo(390));
    final other = Stopwatch()..start();
    await spaced.spaceRequest('amazon');
    expect(other.elapsedMilliseconds, lessThan(100));
  });

  test('un fallo de formato solo bloquea la misma calidad', () {
    policy.recordAttempt('amazon', 'k');
    policy.recordFailure('amazon', 'k', quality: 'ac4');
    expect(
      policy.blockedFor('amazon', 'k', quality: 'ac4') > Duration.zero,
      isTrue,
    );
    expect(policy.blockedFor('amazon', 'k', quality: 'best'), Duration.zero);
    expect(policy.blockedFor('amazon', 'k'), Duration.zero);
  });

  test('un fallo del proveedor bloquea todas las calidades', () {
    policy.recordAttempt('amazon', 'k');
    policy.recordFailure('amazon', 'k');
    expect(
      policy.blockedFor('amazon', 'k', quality: 'best') > Duration.zero,
      isTrue,
    );
  });

  test('el tope cuenta todas las calidades de la pista y el proveedor', () {
    for (var i = 0; i < ProviderRetryPolicy.defaultMaxAttempts; i++) {
      policy.recordAttempt('amazon', 'k');
      policy.recordFailure('amazon', 'k', quality: 'q$i');
    }
    expect(
      policy.blockedFor('amazon', 'k', quality: 'otra') > Duration.zero,
      isTrue,
    );
    expect(
      policy.blockedFor('amazon', 'k', quality: 'otra', manual: true),
      Duration.zero,
    );
  });

  test('un acierto limpia los retrocesos por calidad', () {
    policy.recordFailure('amazon', 'k', quality: 'ac4');
    policy.recordSuccess('amazon', 'k');
    expect(policy.blockedFor('amazon', 'k', quality: 'ac4'), Duration.zero);
  });
}
