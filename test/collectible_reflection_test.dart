import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/widgets/collectible_reflection.dart';

List<Offset> _grid() => [
  for (var x = -1.5; x <= 1.5; x += 0.25)
    for (var y = -1.5; y <= 1.5; y += 0.25) Offset(x, y),
];

void main() {
  test('the band orientation and width are fixed constants', () {
    expect(collectibleBandAxis.distance, closeTo(1, 1e-12));
    expect(
      collectibleBandAxis.dx.abs() + collectibleBandAxis.dy.abs(),
      closeTo(collectibleBandSpan, 1e-12),
    );
    final degrees =
        math.atan2(collectibleBandAxis.dy, collectibleBandAxis.dx) *
        180 /
        math.pi;
    expect(degrees, inInclusiveRange(30, 45));
    expect(collectibleCoreWidth, closeTo(0.07 * 1.4, 1e-9));
  });

  test('the result carries only position and intensity', () {
    for (final unit in _grid()) {
      final r = collectibleReflection(unit);
      expect(r.centre.isFinite, isTrue);
      expect(r.intensity, inInclusiveRange(collectibleIntensityFloor, 1));
    }
  });

  test('the position is monotone along each axis and bounded', () {
    const lo = 0.5 - collectibleTravel;
    const hi = 0.5 + collectibleTravel;
    for (final other in [-1.0, -0.4, 0.0, 0.7, 1.0]) {
      var prevX = -double.infinity;
      var prevY = -double.infinity;
      for (var t = -1.5; t <= 1.5; t += 0.05) {
        final cx = collectibleReflection(Offset(t, other)).centre;
        final cy = collectibleReflection(Offset(other, t)).centre;
        expect(cx, greaterThanOrEqualTo(prevX));
        expect(cy, greaterThanOrEqualTo(prevY));
        expect(cx, inInclusiveRange(lo, hi));
        expect(cy, inInclusiveRange(lo, hi));
        prevX = cx;
        prevY = cy;
      }
    }
  });

  test('flat is centred and the band leaves the card at full tilt', () {
    expect(collectibleReflection(Offset.zero).centre, closeTo(0.5, 1e-9));
    expect(CollectibleReflection.rest.centre, 0.5);
    expect(collectibleReflection(const Offset(1, 1)).centre, greaterThan(0.95));
    expect(collectibleReflection(const Offset(-1, -1)).centre, lessThan(0.05));
  });

  test('the position moves with each tilt axis', () {
    final flat = collectibleReflection(Offset.zero).centre;
    expect(collectibleReflection(const Offset(1, 0)).centre, greaterThan(flat));
    expect(collectibleReflection(const Offset(0, 1)).centre, greaterThan(flat));
    expect(collectibleReflection(const Offset(-1, 0)).centre, lessThan(flat));
    expect(collectibleReflection(const Offset(0, -1)).centre, lessThan(flat));
  });

  test('the intensity peaks towards the light and fades to the sides', () {
    var best = Offset.zero;
    var peak = 0.0;
    for (final unit in _grid()) {
      final i = collectibleReflection(unit).intensity;
      if (i > peak) {
        peak = i;
        best = unit;
      }
    }
    expect(best.dx, lessThan(0));
    expect(best.dy, lessThan(0));
    expect(peak, greaterThan(0.95));
    final away = collectibleReflection(-best).intensity;
    expect(away, lessThan(peak * 0.2));
    expect(
      collectibleReflection(const Offset(1, 1)).intensity,
      lessThan(collectibleReflection(const Offset(-1, -1)).intensity),
    );
  });

  test('the intensity is smooth', () {
    var prev = collectibleReflection(const Offset(-1.5, 0.3)).intensity;
    for (var t = -1.49; t <= 1.5; t += 0.01) {
      final i = collectibleReflection(Offset(t, 0.3)).intensity;
      expect((i - prev).abs(), lessThan(0.03));
      prev = i;
    }
  });

  test('the rest state is a faint centred reflection', () {
    expect(CollectibleReflection.rest.intensity, lessThan(0.5));
    expect(CollectibleReflection.rest.fresnel, lessThan(0.25));
  });

  test('the follower never exceeds the speed limit', () {
    var at = Offset.zero;
    const dt = 1 / 60;
    for (var i = 0; i < 30; i++) {
      final next = collectibleFollow(at, const Offset(100, -100), dt);
      expect(
        (next - at).distance,
        lessThanOrEqualTo(collectibleMaxSpeed * dt + 1e-9),
      );
      at = next;
    }
  });

  test('the follower converges without overshoot', () {
    var at = Offset.zero;
    const target = Offset(6, -3);
    var previous = (target - at).distance;
    for (var i = 0; i < 240; i++) {
      at = collectibleFollow(at, target, 1 / 60);
      final d = (target - at).distance;
      expect(d, lessThanOrEqualTo(previous + 1e-9));
      previous = d;
    }
    expect(previous, lessThan(0.01));
  });

  test('the dead zone holds small changes and lets real ones through', () {
    const base = Offset(3, 3);
    expect(collectibleDeadzoned(base, const Offset(3.05, 3)), base);
    expect(collectibleDeadzoned(base, const Offset(4, 3)), const Offset(4, 3));
  });
}
