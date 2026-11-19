import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/theme/cover_mimic.dart';

ByteData _quadrants(
  int size,
  Color topLeft,
  Color topRight,
  Color bottomLeft,
  Color bottomRight,
) {
  final data = ByteData(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final color = y < size / 2
          ? (x < size / 2 ? topLeft : topRight)
          : (x < size / 2 ? bottomLeft : bottomRight);
      final i = (y * size + x) * 4;
      data.setUint8(i, (color.r * 255).round());
      data.setUint8(i + 1, (color.g * 255).round());
      data.setUint8(i + 2, (color.b * 255).round());
      data.setUint8(i + 3, 255);
    }
  }
  return data;
}

ByteData _flat(Color color, {int size = 8}) =>
    _quadrants(size, color, color, color, color);

double _hueDistance(double a, double b) {
  final d = (a - b).abs() % 360;
  return d > 180 ? 360 - d : d;
}

void main() {
  group('sampleCoverZones', () {
    test('reads each corner and the centre from its own area', () {
      final zones = sampleCoverZones(
        _quadrants(
          20,
          const Color(0xffe03020),
          const Color(0xff2040e0),
          const Color(0xff20c060),
          const Color(0xfff0d020),
        ),
        20,
        20,
      );
      expect(zones.colors, hasLength(mimicZoneCount));
      expect(zones.colors[0], const Color(0xffe03020));
      expect(zones.colors[1], const Color(0xff2040e0));
      expect(zones.colors[2], const Color(0xff20c060));
      expect(zones.colors[3], const Color(0xfff0d020));
      expect(zones.colors[4], isNot(zones.colors[0]));
    });

    test('a bottom band reads the lower strip in two halves', () {
      final data = ByteData(20 * 20 * 4);
      for (var y = 0; y < 20; y++) {
        for (var x = 0; x < 20; x++) {
          final strip = y >= 16;
          final color = strip
              ? (x < 10 ? const Color(0xff2040e0) : const Color(0xfff0d020))
              : const Color(0xff808080);
          final i = (y * 20 + x) * 4;
          data.setUint8(i, (color.r * 255).round());
          data.setUint8(i + 1, (color.g * 255).round());
          data.setUint8(i + 2, (color.b * 255).round());
          data.setUint8(i + 3, 255);
        }
      }
      final zones = sampleCoverZones(data, 20, 20, bottomBand: 0.18);
      expect(zones.colors[2], const Color(0xff2040e0));
      expect(zones.colors[3], const Color(0xfff0d020));
      final corners = sampleCoverZones(data, 20, 20);
      expect(corners.colors[2], isNot(const Color(0xff2040e0)));
    });

    test('ignores transparent pixels and empty images', () {
      expect(sampleCoverZones(ByteData(16 * 4), 4, 4), CoverMimicZones.neutral);
      expect(sampleCoverZones(ByteData(0), 0, 0), CoverMimicZones.neutral);
      final half = _flat(const Color(0xff2a8040));
      for (var i = 0; i < 4 * 8 * 4; i += 4) {
        half.setUint8(i + 3, 0);
      }
      final zones = sampleCoverZones(half, 8, 8);
      expect(zones.colors[2], const Color(0xff2a8040));
    });

    test('measures how bright the lightest areas are', () {
      final white = sampleCoverZones(_flat(Colors.white), 8, 8);
      final black = sampleCoverZones(_flat(Colors.black), 8, 8);
      expect(white.brightLuminance, closeTo(1, 0.02));
      expect(black.brightLuminance, closeTo(0, 0.02));
    });
  });

  group('mimicZoneColors', () {
    test('colourful covers gain saturation and stay in the lightness band', () {
      final zones = sampleCoverZones(
        _quadrants(
          20,
          const Color(0xff8a6a50),
          const Color(0xff3a5a7a),
          const Color(0xff202020),
          const Color(0xfff0f0e0),
        ),
        20,
        20,
      );
      expect(isMonochromeMimic(zones), isFalse);
      final colors = mimicZoneColors(zones);
      for (var i = 0; i < colors.length; i++) {
        final out = HSLColor.fromColor(colors[i]);
        expect(out.lightness, inInclusiveRange(0.19, 0.63));
        final before = HSLColor.fromColor(zones.colors[i]).saturation;
        expect(
          out.saturation,
          greaterThanOrEqualTo(math.min(before, 0.3) - 0.02),
        );
      }
    });

    test('a monochrome cover keeps lights, shadows and an accent', () {
      final zones = sampleCoverZones(
        _quadrants(
          20,
          const Color(0xff101010),
          const Color(0xff808080),
          const Color(0xff303030),
          const Color(0xffe0e0e0),
        ),
        20,
        20,
      );
      expect(isMonochromeMimic(zones), isTrue);
      final colors = mimicZoneColors(zones);
      final lightness = [
        for (final c in colors) HSLColor.fromColor(c).lightness,
      ];
      expect(
        lightness.reduce(math.max) - lightness.reduce(math.min),
        greaterThan(0.25),
      );
      final saturation = [
        for (final c in colors) HSLColor.fromColor(c).saturation,
      ];
      expect(saturation.reduce(math.max), greaterThan(0.3));
      for (final c in colors) {
        expect(
          _hueDistance(HSLColor.fromColor(c).hue, mimicFallbackAccentHue),
          lessThan(6),
        );
      }
    });

    test('a nearly monochrome cover borrows its only tint as accent', () {
      final zones = sampleCoverZones(
        _quadrants(
          20,
          const Color(0xff202020),
          const Color(0xff808080),
          const Color(0xff302820),
          const Color(0xffd0d0d0),
        ),
        20,
        20,
      );
      expect(isMonochromeMimic(zones), isTrue);
      final colors = mimicZoneColors(zones);
      expect(
        _hueDistance(HSLColor.fromColor(colors.first).hue, 30),
        lessThan(20),
      );
    });
  });

  group('veil', () {
    test('is stronger for lighter covers and stays in bounds', () {
      var previous = 0.0;
      for (final luminance in [0.0, 0.1, 0.14, 0.3, 0.6, 1.0]) {
        final alpha = mimicVeilAlpha(luminance);
        expect(alpha, inInclusiveRange(mimicMinVeil, mimicMaxVeil));
        expect(alpha, greaterThanOrEqualTo(previous));
        previous = alpha;
      }
      expect(mimicVeilAlpha(0), mimicMinVeil);
    });

    test('keeps white text at 4.5:1 over any cover, light or dark', () {
      final covers = <Color>[
        Colors.white,
        const Color(0xfff8f4e0),
        const Color(0xffffff00),
        const Color(0xff00ffff),
        const Color(0xffe8e8e8),
        const Color(0xff808080),
        const Color(0xff101010),
        Colors.black,
        const Color(0xffff3050),
      ];
      for (final cover in covers) {
        final zones = sampleCoverZones(_flat(cover), 8, 8);
        final look = mimicLookOf(zones);
        for (final color in look.colors) {
          final veiled = mimicVeiledLuminance(color, look.veil);
          expect(
            mimicContrastWithWhite(veiled),
            greaterThanOrEqualTo(4.5),
            reason: '$cover -> $color veil ${look.veil}',
          );
        }
        final brightest = mimicVeiledLuminance(
          Color.fromARGB(
            255,
            (zones.brightLuminance * 255).round(),
            (zones.brightLuminance * 255).round(),
            (zones.brightLuminance * 255).round(),
          ),
          look.veil,
        );
        expect(mimicContrastWithWhite(brightest), greaterThanOrEqualTo(4.5));
      }
    });
  });

  group('motion', () {
    test('lerp reaches both ends and mixes in between', () {
      final from = [Colors.black, Colors.black];
      final to = [Colors.white, const Color(0xfff44336)];
      expect(lerpMimicColors(from, to, 0), from);
      expect(lerpMimicColors(from, to, 1), to);
      expect(lerpMimicColors(from, to, 0.5)[0].r, closeTo(0.5, 0.01));
    });

    test('ease is monotonic from 0 to 1', () {
      expect(mimicEase(0), 0);
      expect(mimicEase(1), 1);
      var previous = -1.0;
      for (var i = 0; i <= 20; i++) {
        final value = mimicEase(i / 20);
        expect(value, greaterThanOrEqualTo(previous));
        previous = value;
      }
    });

    test('drift is slow, bounded and periodic between 20 and 40 s', () {
      for (final period in mimicDriftPeriods) {
        expect(period, inInclusiveRange(20, 40));
      }
      for (var i = 0; i < mimicZoneCount; i++) {
        final period = mimicDriftPeriods[i];
        expect(
          mimicDrift(i, 5, vertical: false),
          closeTo(mimicDrift(i, 5 + period, vertical: false), 1e-9),
        );
        for (var t = 0.0; t < 120; t += 0.5) {
          final x = mimicDrift(i, t, vertical: false);
          expect(x.abs(), lessThanOrEqualTo(mimicDriftAmplitude + 1e-9));
          final step = (mimicDrift(i, t + 0.5, vertical: false) - x).abs();
          expect(step, lessThan(0.012));
          expect(
            (mimicBreath(i, t) - 1).abs(),
            lessThanOrEqualTo(mimicBreathAmplitude + 1e-9),
          );
        }
      }
    });
  });
}
