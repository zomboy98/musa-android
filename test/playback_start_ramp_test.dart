import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/playback_ramp.dart';

void main() {
  test(
    'la rampa de entrada arranca en cero y llega al volumen objetivo',
    () async {
      final gains = <double>[];
      final ramp = PlaybackRamp(
        apply: (gain) async => gains.add(gain),
        fadeIn: const Duration(milliseconds: 16),
      );
      await ramp.rampIn(() => 0.8);
      expect(gains.length, ramp.steps);
      expect(gains.first, greaterThan(0));
      expect(gains.first, lessThan(0.2));
      expect(gains.last, closeTo(0.8, 1e-9));
    },
  );

  test('la rampa de entrada es monotona y nunca salta de golpe', () async {
    final gains = <double>[];
    final ramp = PlaybackRamp(
      apply: (gain) async => gains.add(gain),
      fadeIn: const Duration(milliseconds: 16),
    );
    await ramp.rampIn(() => 1);
    for (var i = 1; i < gains.length; i++) {
      expect(gains[i], greaterThanOrEqualTo(gains[i - 1]));
      expect(gains[i] - gains[i - 1], lessThan(0.4));
    }
    expect(gains.first, lessThan(0.1));
  });

  test('la rampa de salida baja hasta cero desde el volumen actual', () async {
    final gains = <double>[];
    final ramp = PlaybackRamp(
      apply: (gain) async => gains.add(gain),
      fadeOut: const Duration(milliseconds: 8),
    );
    await ramp.rampOut(0.7);
    expect(gains.first, lessThan(0.7));
    expect(gains.last, closeTo(0, 1e-9));
    for (var i = 1; i < gains.length; i++) {
      expect(gains[i], lessThanOrEqualTo(gains[i - 1]));
    }
  });

  test(
    'cancelar interrumpe la rampa y respeta el volumen aplicado despues',
    () async {
      final gains = <double>[];
      late PlaybackRamp ramp;
      ramp = PlaybackRamp(
        apply: (gain) async {
          gains.add(gain);
          if (gains.length == 3) ramp.cancel();
        },
        fadeIn: const Duration(milliseconds: 16),
      );
      await ramp.rampIn(() => 1);
      expect(gains.length, 3);
    },
  );

  test(
    'el objetivo se lee en cada paso para seguir cambios de volumen',
    () async {
      final gains = <double>[];
      var target = 0.5;
      final ramp = PlaybackRamp(
        apply: (gain) async {
          gains.add(gain);
          if (gains.length == 2) target = 1;
        },
        fadeIn: const Duration(milliseconds: 16),
      );
      await ramp.rampIn(() => target);
      expect(gains.last, closeTo(1, 1e-9));
    },
  );

  test('la curva es suave en los extremos', () {
    expect(PlaybackRamp.curve(0), 0);
    expect(PlaybackRamp.curve(1), closeTo(1, 1e-12));
    expect(PlaybackRamp.curve(0.5), closeTo(0.5, 1e-12));
  });
}
