import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/provider_cooldown.dart';

class _Store implements ProviderCooldownStore, ProviderFailureStore {
  final Map<String, int> cooldowns = {};
  final Map<String, String> failures = {};

  @override
  Future<Map<String, int>> readAll() async => Map.of(cooldowns);

  @override
  void write(String key, int value) => cooldowns[key] = value;

  @override
  void remove(String key) => cooldowns.remove(key);

  @override
  Future<Map<String, String>> readAllFailures() async => Map.of(failures);

  @override
  void writeFailure(String key, String value) => failures[key] = value;

  @override
  void removeFailure(String key) => failures.remove(key);
}

void main() {
  late DateTime now;
  late _Store store;
  late ProviderCooldown cooldown;

  setUp(() {
    now = DateTime.utc(2026, 11, 16, 12);
    store = _Store();
    cooldown = ProviderCooldown(clock: () => now, store: store);
  });

  test('registra el ultimo fallo con tipo, hora y codigo', () {
    cooldown.noteAttempts([
      {'provider': 'Deezer', 'error_type': 'api_error', 'http_status': 429},
    ]);
    final failure = cooldown.lastFailure('deezer')!;
    expect(failure.type, 'api_error');
    expect(failure.at, now);
    expect(failure.httpCode, 429);
    expect(failure.retryAfterSeconds, isNull);
    expect(store.failures.keys.single, 'provider_last_failure.deezer');
  });

  test('solo guarda etiquetas y codigos, sin mensajes ni direcciones', () {
    cooldown.noteAttempts([
      {
        'provider': 'qobuz',
        'error_type': 'download_error',
        'message': 'https://example.test/a?token=secreto',
        'retry_after_s': 90,
      },
    ]);
    final raw = store.failures['provider_last_failure.qobuz']!;
    expect(raw.contains('secreto'), isFalse);
    expect(raw.contains('http'), isFalse);
    expect(raw.contains('message'), isFalse);
    expect(cooldown.lastFailure('qobuz')!.retryAfterSeconds, 90);
  });

  test('ignora exitos, cancelaciones y etiquetas no validas', () {
    cooldown.noteAttempts([
      {'provider': 'tidal', 'error_type': ''},
      {'provider': 'tidal', 'error_type': 'none'},
      {'provider': 'tidal', 'error_type': 'cancelled'},
      {'provider': 'tidal', 'error_type': 'https://a.test/x'},
      {'provider': 'https://a.test', 'error_type': 'timeout'},
      {'error_type': 'timeout'},
    ]);
    expect(cooldown.failureSnapshot(), isEmpty);
    expect(store.failures, isEmpty);
  });

  test('conserva un unico registro por proveedor, el ultimo', () {
    cooldown.noteFailure('deezer', 'timeout');
    now = now.add(const Duration(minutes: 5));
    cooldown.noteFailure('deezer', 'provider_unavailable');
    expect(cooldown.failureSnapshot().length, 1);
    expect(cooldown.lastFailure('deezer')!.type, 'provider_unavailable');
    expect(store.failures.length, 1);
  });

  test('caduca a las 24 h y se borra del almacen', () {
    cooldown.noteFailure('deezer', 'timeout');
    now = now.add(const Duration(hours: 23, minutes: 59));
    expect(cooldown.lastFailure('deezer'), isNotNull);
    now = now.add(const Duration(minutes: 2));
    expect(cooldown.lastFailure('deezer'), isNull);
    expect(store.failures, isEmpty);
  });

  test('load recupera lo guardado y descarta lo caducado o alterado', () async {
    store.failures['provider_last_failure.deezer'] = ProviderFailure(
      type: 'api_error',
      at: now.subtract(const Duration(hours: 1)),
      httpCode: 503,
    ).encode();
    store.failures['provider_last_failure.qobuz'] = ProviderFailure(
      type: 'timeout',
      at: now.subtract(const Duration(hours: 30)),
    ).encode();
    store.failures['provider_last_failure.tidal'] = '{"t":"a b","at":1}';
    store.failures['provider_last_failure.amzn'] = 'no es json';
    await cooldown.load();
    final snapshot = cooldown.failureSnapshot();
    expect(snapshot.keys.toList(), ['deezer']);
    expect(snapshot['deezer']!.httpCode, 503);
    expect(store.failures.containsKey('provider_last_failure.tidal'), isFalse);
    expect(store.failures.containsKey('provider_last_failure.amzn'), isFalse);
    expect(store.failures.containsKey('provider_last_failure.qobuz'), isFalse);
  });

  test('un 429 con espera registra pausa y ultimo fallo', () {
    cooldown.noteAttempts([
      {'provider': 'deezer', 'error_type': 'rate_limit', 'retry_after_s': 2200},
    ]);
    expect(cooldown.isCoolingDown('deezer'), isTrue);
    expect(
      cooldown.untilSnapshot()['deezer']!.isAtSameMomentAs(
        now.add(const Duration(seconds: 2200)),
      ),
      isTrue,
    );
    expect(cooldown.lastFailure('deezer')!.type, 'rate_limit');
  });
}
