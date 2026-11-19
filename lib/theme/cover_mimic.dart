import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// Zones of a cover that tint the mimetic backdrop: four corners and centre.
const int mimicZoneCount = 5;

/// Share of the cover's width and height each corner zone spans.
const double mimicZoneExtent = 0.4;

/// Height share of the bottom strip, split in two halves, that replaces the
/// lower corner zones when a video is shown at the screen width and its lower
/// edge melts into the backdrop.
const double mimicBottomBand = 0.18;

/// Relative luminance the brightest area of the backdrop keeps after the
/// veil. White text over it holds a contrast ratio of about 5.5.
const double mimicTargetLuminance = 0.14;

/// Bounds of the black veil's alpha at the top of the backdrop.
const double mimicMinVeil = 0.22;
const double mimicMaxVeil = 0.82;

/// Extra veil alpha at the bottom, where the controls sit.
const double mimicVeilBottomBoost = 0.12;

/// Saturation multiplier of colourful zones.
const double mimicSaturationBoost = 1.35;

/// Mean HSL saturation under which a cover counts as nearly monochrome.
const double mimicMonoSaturation = 0.12;

/// Hue (degrees) of the accent a monochrome cover without any tint receives.
const double mimicFallbackAccentHue = 215;

/// Lightness bounds of the zone colours, before the veil.
const double mimicMinLightness = 0.2;
const double mimicMaxLightness = 0.62;

/// Zone colours of one cover and how bright its lightest areas are.
@immutable
class CoverMimicZones {
  const CoverMimicZones(
    this.colors, {
    this.brightLuminance = 0,
    this.meanSaturation = 0,
  });

  /// Mean colour of each zone: top left, top right, bottom left, bottom
  /// right, centre.
  final List<Color> colors;

  /// Mean relative luminance of the lightest 8 % of the pixels.
  final double brightLuminance;

  /// Mean HSL saturation of the zones.
  final double meanSaturation;

  static const neutral = CoverMimicZones(<Color>[
    Color(0xff3a3a3a),
    Color(0xff3a3a3a),
    Color(0xff3a3a3a),
    Color(0xff3a3a3a),
    Color(0xff3a3a3a),
  ]);
}

/// Final zone colours and veil alpha of one cover.
@immutable
class CoverMimicLook {
  const CoverMimicLook(this.colors, this.veil);

  final List<Color> colors;

  /// Black veil alpha at the top; the bottom adds [mimicVeilBottomBoost].
  final double veil;

  static final neutral = mimicLookOf(CoverMimicZones.neutral);

  @override
  bool operator ==(Object other) =>
      other is CoverMimicLook &&
      other.veil == veil &&
      listEquals(other.colors, colors);

  @override
  int get hashCode => Object.hash(veil, Object.hashAll(colors));
}

double _channel(int value) {
  final c = value / 255;
  return c <= 0.03928
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

/// Relative luminance of an 8-bit sRGB pixel.
double mimicPixelLuminance(int r, int g, int b) =>
    0.2126 * _channel(r) + 0.7152 * _channel(g) + 0.0722 * _channel(b);

/// Mean colour of the five zones of straight RGBA [data] of [width] x
/// [height] pixels, plus how bright the lightest pixels are. Transparent
/// pixels are ignored; an empty image gives [CoverMimicZones.neutral]. With a
/// [bottomBand] above zero the two lower zones become the left and right
/// halves of the bottom strip of that height share.
CoverMimicZones sampleCoverZones(
  ByteData data,
  int width,
  int height, {
  double bottomBand = 0,
}) {
  if (width <= 0 || height <= 0 || data.lengthInBytes < width * height * 4) {
    return CoverMimicZones.neutral;
  }
  final band = bottomBand.clamp(0.0, 0.5);
  final rects = <List<double>>[
    [0, 0, mimicZoneExtent, mimicZoneExtent],
    [1 - mimicZoneExtent, 0, 1, mimicZoneExtent],
    band > 0
        ? [0, 1 - band, 0.5, 1]
        : [0, 1 - mimicZoneExtent, mimicZoneExtent, 1],
    band > 0
        ? [0.5, 1 - band, 1, 1]
        : [1 - mimicZoneExtent, 1 - mimicZoneExtent, 1, 1],
    [
      0.5 - mimicZoneExtent / 2,
      0.5 - mimicZoneExtent / 2,
      0.5 + mimicZoneExtent / 2,
      0.5 + mimicZoneExtent / 2,
    ],
  ];
  final sums = List<double>.filled(mimicZoneCount * 4, 0);
  const bins = 64;
  final histogram = List<int>.filled(bins, 0);
  var opaque = 0;
  final total = List<double>.filled(4, 0);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final index = (y * width + x) * 4;
      if (data.getUint8(index + 3) < 128) continue;
      final r = data.getUint8(index);
      final g = data.getUint8(index + 1);
      final b = data.getUint8(index + 2);
      opaque++;
      total[0] += r;
      total[1] += g;
      total[2] += b;
      total[3] += 1;
      final luminance = mimicPixelLuminance(r, g, b);
      histogram[(luminance * (bins - 1)).round().clamp(0, bins - 1)]++;
      final fx = (x + 0.5) / width;
      final fy = (y + 0.5) / height;
      for (var zone = 0; zone < mimicZoneCount; zone++) {
        final rect = rects[zone];
        if (fx >= rect[0] && fx < rect[2] && fy >= rect[1] && fy < rect[3]) {
          sums[zone * 4] += r;
          sums[zone * 4 + 1] += g;
          sums[zone * 4 + 2] += b;
          sums[zone * 4 + 3] += 1;
        }
      }
    }
  }
  if (opaque == 0) return CoverMimicZones.neutral;
  Color mean(List<double> s, int offset) => Color.fromARGB(
    255,
    (s[offset] / s[offset + 3]).round(),
    (s[offset + 1] / s[offset + 3]).round(),
    (s[offset + 2] / s[offset + 3]).round(),
  );
  final fallback = mean(total, 0);
  final colors = [
    for (var zone = 0; zone < mimicZoneCount; zone++)
      sums[zone * 4 + 3] == 0 ? fallback : mean(sums, zone * 4),
  ];
  final take = math.max(1, (opaque * 0.08).round());
  var remaining = take;
  var brightSum = 0.0;
  for (var bin = bins - 1; bin >= 0 && remaining > 0; bin--) {
    final used = math.min(histogram[bin], remaining);
    brightSum += used * bin / (bins - 1);
    remaining -= used;
  }
  var saturation = 0.0;
  for (final color in colors) {
    saturation += HSLColor.fromColor(color).saturation;
  }
  return CoverMimicZones(
    colors,
    brightLuminance: brightSum / take,
    meanSaturation: saturation / colors.length,
  );
}

/// Whether [zones] describe a cover that is nearly black and white.
bool isMonochromeMimic(CoverMimicZones zones) =>
    zones.meanSaturation < mimicMonoSaturation;

/// Colours the backdrop paints for [zones]: colourful covers get their zone
/// colours with more saturation and a lightness kept inside a readable range;
/// monochrome ones get their lights and shadows stretched and an accent hue
/// (the most tinted zone's, or a cool fallback) that grows with lightness, so
/// the backdrop never goes flat.
List<Color> mimicZoneColors(CoverMimicZones zones) {
  final hsl = [for (final c in zones.colors) HSLColor.fromColor(c)];
  if (!isMonochromeMimic(zones)) {
    return [
      for (final c in hsl)
        c
            .withSaturation(
              (c.saturation * mimicSaturationBoost).clamp(0.3, 0.9),
            )
            .withLightness(
              c.lightness.clamp(mimicMinLightness, mimicMaxLightness),
            )
            .toColor(),
    ];
  }
  var accentHue = mimicFallbackAccentHue;
  var accentSaturation = 0.0;
  var meanLightness = 0.0;
  for (final c in hsl) {
    meanLightness += c.lightness / hsl.length;
    if (c.saturation > accentSaturation) {
      accentSaturation = c.saturation;
      accentHue = c.hue;
    }
  }
  if (accentSaturation < 0.04) accentHue = mimicFallbackAccentHue;
  var low = 1.0;
  var high = 0.0;
  for (final c in hsl) {
    low = math.min(low, c.lightness);
    high = math.max(high, c.lightness);
  }
  final spread = math.max(high - low, 0.02);
  return [
    for (final c in hsl)
      () {
        final rank = ((c.lightness - low) / spread).clamp(0.0, 1.0);
        final stretched = 0.4 + (c.lightness - meanLightness) * 2.2;
        return HSLColor.fromAHSL(
          1,
          accentHue,
          0.16 + 0.34 * rank,
          stretched.clamp(mimicMinLightness, mimicMaxLightness),
        ).toColor();
      }(),
  ];
}

/// Alpha of the black veil that keeps the brightest area of a backdrop with
/// [brightLuminance] at [mimicTargetLuminance] or darker. Compositing black
/// at alpha `a` scales the sRGB channels by `1 - a`, and luminance by about
/// `(1 - a)^2.2`.
double mimicVeilAlpha(double brightLuminance) {
  if (brightLuminance <= mimicTargetLuminance) return mimicMinVeil;
  final alpha =
      1 - math.pow(mimicTargetLuminance / brightLuminance, 1 / 2.2).toDouble();
  return alpha.clamp(mimicMinVeil, mimicMaxVeil);
}

/// Colours and veil for [zones].
CoverMimicLook mimicLookOf(CoverMimicZones zones) {
  final colors = mimicZoneColors(zones);
  var bright = zones.brightLuminance;
  for (final color in colors) {
    bright = math.max(bright, color.computeLuminance());
  }
  return CoverMimicLook(colors, mimicVeilAlpha(bright));
}

/// Relative luminance of [color] under a black veil of [alpha].
double mimicVeiledLuminance(Color color, double alpha) {
  final keep = 1 - alpha;
  return mimicPixelLuminance(
    (color.r * 255 * keep).round(),
    (color.g * 255 * keep).round(),
    (color.b * 255 * keep).round(),
  );
}

/// WCAG contrast ratio of white over a surface of [luminance].
double mimicContrastWithWhite(double luminance) => 1.05 / (luminance + 0.05);

/// Colour of each zone halfway through a change of cover, `t` in [0, 1].
List<Color> lerpMimicColors(List<Color> from, List<Color> to, double t) => [
  for (var i = 0; i < to.length; i++)
    Color.lerp(i < from.length ? from[i] : to[i], to[i], t)!,
];

/// Eased progress of a cover change.
double mimicEase(double t) => Curves.easeInOutCubic.transform(t.clamp(0, 1));

/// Drift period of each blob, in seconds: all between 20 and 40.
const List<double> mimicDriftPeriods = [23, 31, 37, 27, 34];

/// Fraction of the backdrop's size a blob drifts away from its anchor.
const double mimicDriftAmplitude = 0.07;

/// Fraction of its radius a blob breathes in and out.
const double mimicBreathAmplitude = 0.06;

/// Offset of blob [index] from its anchor at [seconds], in fractions of the
/// backdrop's size. Slow, periodic and smooth.
double mimicDrift(int index, double seconds, {required bool vertical}) {
  final period =
      mimicDriftPeriods[index % mimicDriftPeriods.length] *
      (vertical ? 1.17 : 1);
  final phase = index * 0.37 + (vertical ? 0.25 : 0);
  return mimicDriftAmplitude *
      math.sin(2 * math.pi * (seconds / period + phase));
}

/// Radius multiplier of blob [index] at [seconds].
double mimicBreath(int index, double seconds) {
  final period = mimicDriftPeriods[(index + 2) % mimicDriftPeriods.length];
  return 1 +
      mimicBreathAmplitude *
          math.sin(2 * math.pi * (seconds / period + index * 0.21));
}
