import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/provider_cooldown.dart';

class _MemoryStore implements ProviderCooldownStore {
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
  late _MemoryStore store;
  late ProviderCooldown cooldown;

  setUp(() {
    now = DateTime.utc(2026, 11, 16, 12);
    store = _MemoryStore();
    cooldown = ProviderCooldown(clock: () => now, store: store);
  });

  test('un valor de cero o negativo no registra enfriamiento', () {
    cooldown.note('tidal', 0);
    cooldown.note('tidal', -5);
    expect(cooldown.remaining('tidal'), Duration.zero);
    expect(store.values, isEmpty);
  });

  test('una espera de 60 s indicada por el proveedor se anota', () {
    cooldown.note('tidal', 60);
    expect(cooldown.remaining('tidal'), const Duration(seconds: 60));
    expect(store.values.keys.single, 'provider_cooldown_until.tidal');
  });

  test('una espera menor de 30 s se sube al minimo de 30 s', () {
    cooldown.note('tidal', 5);
    expect(cooldown.remaining('tidal'), const Duration(seconds: 30));
  });

  test('un timeout con retry_after_s de 60 enfria al proveedor', () {
    cooldown.noteAttempts([
      {'provider': 'tidal', 'error_type': 'timeout', 'retry_after_s': 60},
    ]);
    expect(cooldown.isCoolingDown('tidal'), isTrue);
    expect(cooldown.remaining('tidal'), const Duration(seconds: 60));
  });

  test('registra la espera y baja con el reloj', () {
    cooldown.note('Amazon', 40947);
    expect(cooldown.remaining('amazon'), const Duration(seconds: 40947));
    now = now.add(const Duration(seconds: 40000));
    expect(cooldown.remaining('amazon'), const Duration(seconds: 947));
    expect(store.values.keys.single, 'provider_cooldown_until.amazon');
  });

  test('un valor menor posterior no acorta el enfriamiento', () {
    cooldown.note('tidal', 900);
    cooldown.note('tidal', 100);
    expect(cooldown.remaining('tidal'), const Duration(seconds: 900));
  });

  test('vencido devuelve cero y borra la clave', () {
    cooldown.note('tidal', 900);
    now = now.add(const Duration(seconds: 901));
    expect(cooldown.remaining('tidal'), Duration.zero);
    expect(store.values, isEmpty);
  });

  test('aplica el tope de 86400 s', () {
    cooldown.note('amazon', 500000);
    expect(cooldown.remaining('amazon'), const Duration(seconds: 86400));
  });

  test('sobrevive a recrear la instancia con el mismo almacen', () async {
    cooldown.note('tidal', 900);
    final other = ProviderCooldown(clock: () => now, store: store);
    expect(other.remaining('tidal'), Duration.zero);
    await other.load();
    expect(other.remaining('tidal'), const Duration(seconds: 900));
  });

  test('noteAttempts solo toma rate_limit, rate_limited y timeout', () {
    cooldown.noteAttempts([
      {
        'provider': 'amazon',
        'error_type': 'rate_limited',
        'retry_after_s': 40947,
      },
      {'provider': 'tidal', 'error_type': 'timeout', 'retry_after_s': 900},
      {'provider': 'deezer', 'error_type': 'not_found', 'retry_after_s': 900},
      {'provider': 'qobuz', 'error_type': 'rate_limit'},
    ]);
    expect(cooldown.isCoolingDown('amazon'), isTrue);
    expect(cooldown.isCoolingDown('tidal'), isTrue);
    expect(cooldown.isCoolingDown('deezer'), isFalse);
    expect(cooldown.isCoolingDown('qobuz'), isFalse);
  });
}
