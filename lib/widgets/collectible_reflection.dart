import 'dart:math' as math;
import 'dart:ui' show Offset;

const double collectibleMaxTiltDegrees = 12;

const double collectibleBandAxisDegrees = 40;
const Offset collectibleBandAxis = Offset(
  0.766044443118978,
  0.6427876096865393,
);
const double collectibleBandSpan = 1.4088320528055173;

const double collectibleWidthScale = 1.4;
const double collectibleCoreWidth = 0.07 * collectibleWidthScale;
const double collectibleRimWidth = 0.4 * collectibleWidthScale;
const double collectibleCorePeakAlpha = 0.18;
const double collectibleHaloPeakAlpha = 0.07;
const double collectibleRimPeakAlpha = 0.35;
const double collectibleTintPeakAlpha = 0.045;
const double collectibleFresnelPeakAlpha = 0.16;
const double collectibleHaloRadius = 0.62;

const double collectibleRestIntensity = 0.3;
const double collectibleIntensityFloor = 0.06;
const double collectibleIntensitySigmaDegrees = 9;
const double collectibleTravel = 0.62;
const double collectiblePositionSlope = 0.6;

const double collectibleFollowTau = 0.09;
const double collectibleMaxSpeed = 220;
const double collectibleDeadzone = 0.012;

const double _lightX = -0.4;
const double _lightY = -0.4;
const double _lightZ = 0.82;

class CollectibleReflection {
  const CollectibleReflection({required this.centre, required this.intensity});

  final double centre;
  final double intensity;

  static const CollectibleReflection rest = CollectibleReflection(
    centre: 0.5,
    intensity: collectibleRestIntensity,
  );

  double get fresnel => intensity * intensity;
}

({double x, double y, double z}) _halfVector() {
  final length = math.sqrt(
    _lightX * _lightX + _lightY * _lightY + _lightZ * _lightZ,
  );
  final lx = _lightX / length;
  final ly = _lightY / length;
  final lz = _lightZ / length;
  final hx = lx;
  final hy = ly;
  final hz = lz + 1;
  final hl = math.sqrt(hx * hx + hy * hy + hz * hz);
  return (x: hx / hl, y: hy / hl, z: hz / hl);
}

final ({double x, double y, double z}) _half = _halfVector();

CollectibleReflection collectibleReflection(Offset unit) {
  final maxRad = collectibleMaxTiltDegrees * math.pi / 180;
  final ux = unit.dx.clamp(-1.5, 1.5).toDouble();
  final uy = unit.dy.clamp(-1.5, 1.5).toDouble();
  final sx = math.sin(ux * maxRad);
  final sy = math.sin(uy * maxRad);
  final sz = math.sqrt(math.max(0.0, 1 - sx * sx - sy * sy));
  final cosAngle = (sx * _half.x + sy * _half.y + sz * _half.z).clamp(
    -1.0,
    1.0,
  );
  final angle = math.acos(cosAngle);
  final sigma = collectibleIntensitySigmaDegrees * math.pi / 180;
  final bell = math.exp(-0.5 * (angle / sigma) * (angle / sigma));
  final intensity =
      collectibleIntensityFloor + (1 - collectibleIntensityFloor) * bell;
  final along =
      (sx * collectibleBandAxis.dx + sy * collectibleBandAxis.dy) /
      math.sin(maxRad);
  final centre =
      0.5 +
      collectibleTravel *
          _tanh(along * collectiblePositionSlope / collectibleTravel);
  return CollectibleReflection(centre: centre, intensity: intensity);
}

double _tanh(double x) {
  if (x > 20) return 1;
  if (x < -20) return -1;
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}

Offset collectibleFollow(
  Offset current,
  Offset target,
  double dt, {
  double tau = collectibleFollowTau,
  double maxSpeed = collectibleMaxSpeed,
}) {
  final alpha = 1 - math.exp(-dt / tau);
  var step = (target - current) * alpha;
  final limit = maxSpeed * dt;
  final length = step.distance;
  if (length > limit && length > 0) step = step * (limit / length);
  return current + step;
}

Offset collectibleDeadzoned(
  Offset previous,
  Offset next, {
  double deadzone = collectibleDeadzone * collectibleMaxTiltDegrees,
}) => (next - previous).distance < deadzone ? previous : next;
