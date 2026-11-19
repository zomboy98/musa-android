import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/extension.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/services/provider_cooldown.dart';
import 'package:mornye/services/provider_request_gate.dart';
import 'package:mornye/services/provider_retry_policy.dart';
import 'package:mornye/services/special_quality_availability.dart';
import 'package:mornye/utils/track_quality_choices.dart';

const _options = [
  QualityOption(id: 'LOSSLESS', label: 'FLAC 16-bit', kind: 'lossless'),
  QualityOption(id: 'DOLBY_ATMOS', label: 'Dolby Atmos', kind: 'spatial'),
];

class _Store implements ProviderCooldownStore {
  final Map<String, int> values = {};

  @override
  Future<Map<String, int>> readAll() async => Map.of(values);

  @override
  void write(String key, int value) => values[key] = value;

  @override
  void remove(String key) => values.remove(key);
}

Track _deezer(String id, String isrc) => Track(
  id: id,
  name: 'n$id',
  artistName: 'a',
  albumName: 'b',
  duration: 100,
  isrc: isrc,
  source: 'deezer',
);

Future<void> _settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

bool _offered(
  SpecialQualityAvailability registry,
  Track track,
  String service,
) => buildTrackQualityChoices(
  options: _options,
  track: track,
  service: service,
  availability: registry,
).firstWhere((c) => c.id == 'DOLBY_ATMOS').available;

void main() {
  late List<String> loads;
  late List<String> resolved;
  late Map<String, String> atmosModes;
  late ProviderCooldown cooldown;
  late ProviderRequestGate gate;

  setUp(() {
    loads = [];
    resolved = [];
    atmosModes = {};
    cooldown = ProviderCooldown(store: _Store());
    gate = ProviderRequestGate();
  });

  SpecialQualityAvailability build() => SpecialQualityAvailability(
    directory: null,
    loadMetadata: (provider, type, id) async {
      loads.add('$provider:$id');
      return {
        'track': {'id': id, 'audio_modes': atmosModes[id] ?? 'STEREO'},
      };
    },
    gate: gate,
    cooldown: cooldown,
    resolveNativeId: (track, provider) async {
      resolved.add('$provider:${track.id}');
      return 'tidal${track.id}';
    },
  );

  test('una pista de origen deezer se sondea en tidal por su equivalente',
      () async {
    atmosModes['tidalA'] = 'STEREO,DOLBY_ATMOS';
    final registry = build();
    final track = _deezer('A', 'USAAA1111111');
    expect(
      registry.atmosStatus(track, 'tidal-web'),
      SpecialQualityStatus.checking,
    );
    await _settle();
    expect(resolved, ['tidal-web:A']);
    expect(loads, ['tidal-web:tidalA']);
    expect(
      registry.atmosStatus(track, 'tidal-web'),
      SpecialQualityStatus.confirmed,
    );
    expect(_offered(registry, track, 'tidal-web'), isTrue);
  });

  test('Atmos no disponible en una pista no oculta Atmos en otra', () async {
    atmosModes['tidalB'] = 'STEREO,DOLBY_ATMOS';
    final registry = build();
    final sin = _deezer('A', 'USAAA1111111');
    final con = _deezer('B', 'USBBB2222222');
    registry.atmosStatus(sin, 'tidal-web');
    await _settle();
    registry.atmosStatus(con, 'tidal-web');
    await _settle();
    expect(_offered(registry, sin, 'tidal-web'), isFalse);
    expect(_offered(registry, con, 'tidal-web'), isTrue);
  });

  test('amazon tambien sondea sus propias pistas', () async {
    atmosModes['AMZ1'] = 'DOLBY_ATMOS';
    final registry = build();
    final track = Track(
      id: 'AMZ1',
      name: 'n',
      artistName: 'a',
      albumName: 'b',
      duration: 100,
      source: 'amazon',
    );
    registry.atmosStatus(track, 'amazon');
    await _settle();
    expect(loads, ['amazon:AMZ1']);
    expect(
      registry.atmosStatus(track, 'amazon'),
      SpecialQualityStatus.confirmed,
    );
  });

  test('no sondea ni resuelve con el proveedor en enfriamiento', () async {
    cooldown.noteRateLimited('tidal-web', 600);
    final registry = build();
    final track = _deezer('A', 'USAAA1111111');
    expect(
      registry.atmosStatus(track, 'tidal-web'),
      SpecialQualityStatus.unknown,
    );
    await _settle();
    expect(loads, isEmpty);
    expect(resolved, isEmpty);
  });

  test('el sondeo pasa por la compuerta con prioridad de cola', () async {
    atmosModes['tidalA'] = 'DOLBY_ATMOS';
    final registry = build();
    final holder = gate.request(ProviderRequestPriority.foreground);
    await holder.granted;
    final track = _deezer('A', 'USAAA1111111');
    registry.atmosStatus(track, 'tidal-web');
    await _settle();
    expect(loads, isEmpty);
    expect(gate.waiting, 1);
    holder.release();
    await _settle();
    expect(loads, ['tidal-web:tidalA']);
  });

  test('no sondea dos veces la misma pista y proveedor', () async {
    final registry = build();
    final track = _deezer('A', 'USAAA1111111');
    registry.atmosStatus(track, 'tidal-web');
    registry.atmosStatus(track, 'tidal-web');
    await _settle();
    registry.atmosStatus(track, 'tidal-web');
    await _settle();
    expect(loads, ['tidal-web:tidalA']);
  });

  test('un fallo del sondeo respeta el retroceso de la politica', () async {
    var now = DateTime.utc(2026, 11, 16, 12);
    final policy = ProviderRetryPolicy(
      clock: () => now,
      cooldown: cooldown,
      spacing: Duration.zero,
    );
    final registry = SpecialQualityAvailability(
      clock: () => now,
      directory: null,
      loadMetadata: (provider, type, id) async {
        loads.add(id);
        throw StateError('falla');
      },
      gate: gate,
      cooldown: cooldown,
      retryPolicy: policy,
      resolveNativeId: (track, provider) async => 'tidal${track.id}',
    );
    final track = _deezer('A', 'USAAA1111111');
    registry.atmosStatus(track, 'tidal-web');
    await _settle();
    expect(loads, hasLength(1));
    now = now.add(const Duration(seconds: 20));
    expect(
      registry.atmosStatus(track, 'tidal-web'),
      SpecialQualityStatus.unknown,
    );
    await _settle();
    expect(loads, hasLength(1));
    now = now.add(const Duration(seconds: 120));
    registry.atmosStatus(track, 'tidal-web');
    await _settle();
    expect(loads, hasLength(2));
  });
}
