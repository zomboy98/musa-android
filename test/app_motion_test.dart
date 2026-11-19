import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/app_motion.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/theme/motion_profile.dart';
import 'package:mornye/theme/mornye_theme.dart';

void main() {
  test('spring curves start at rest and settle within their duration', () {
    for (final spring in [
      M3EMotion.expressiveSpatialFast,
      M3EMotion.expressiveSpatialDefault,
      M3EMotion.expressiveSpatialSlow,
      M3EMotion.effectsFast,
      M3EMotion.effectsDefault,
    ]) {
      final curve = SpringCurve(spring);
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      expect(curve.transform(0.98), closeTo(1, 0.01));
      expect(curve.duration.inMilliseconds, inInclusiveRange(100, 1200));
    }
  });

  test('spatial springs overshoot while effects springs do not', () {
    double peak(SpringCurve curve) => [
      for (var t = 0.0; t <= 1; t += 0.01) curve.transform(t),
    ].reduce((a, b) => a > b ? a : b);

    expect(
      peak(SpringCurve(M3EMotion.expressiveSpatialDefault)),
      greaterThan(1),
    );
    expect(peak(SpringCurve(M3EMotion.effectsDefault)), lessThanOrEqualTo(1));
  });

  Future<AppMotionSpec> resolve(
    WidgetTester tester, {
    required ThemeData theme,
    bool reduceMotion = false,
  }) async {
    late AppMotionSpec spec;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Builder(
            builder: (context) {
              spec = AppMotion.spatial(
                context,
                const AppMotionSpec(
                  Duration(milliseconds: 250),
                  Curves.easeOutCubic,
                ),
              );
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    // MaterialApp animates theme changes between pumps.
    await tester.pumpAndSettle();
    return spec;
  }

  testWidgets(
    'Material uses sober ease-out curves; Mornye and reduced motion keep fallback',
    (tester) async {
      final material = await resolve(tester, theme: AppTheme.light());
      expect(material.curve, Curves.easeOutCubic);
      expect(material.duration, const Duration(milliseconds: 300));
      for (final spec in [
        await resolve(tester, theme: MornyeTheme.build(Brightness.light)),
        await resolve(tester, theme: AppTheme.light(), reduceMotion: true),
      ]) {
        expect(spec.curve, Curves.easeOutCubic);
        expect(spec.duration, const Duration(milliseconds: 250));
      }
    },
  );

  testWidgets('sober motion never overshoots and keeps fixed durations', (
    tester,
  ) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) {
            captured = context;
            return const SizedBox();
          },
        ),
      ),
    );
    const fallback = AppMotionSpec(Duration.zero, Curves.linear);
    final specs = [
      AppMotion.spatialFast(captured, fallback),
      AppMotion.spatial(captured, fallback),
      AppMotion.spatialSlow(captured, fallback),
      AppMotion.effectsFast(captured, fallback),
      AppMotion.effects(captured, fallback),
    ];
    for (final spec in specs) {
      // Transitions last 120-350 ms and never run past the end value.
      expect(spec.duration.inMilliseconds, inInclusiveRange(120, 350));
      for (var t = 0.0; t <= 1; t += 0.01) {
        expect(spec.curve.transform(t), inInclusiveRange(0, 1));
      }
    }
    final surface = AppMotion.surfaceEntrance(captured)!;
    expect(surface.duration, const Duration(milliseconds: 300));
    expect(surface.reverseDuration, const Duration(milliseconds: 200));
  });

  testWidgets('MotionProfile reads the display rate without changing motion', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    late BuildContext captured;
    await tester.pumpWidget(
      Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      ),
    );
    for (final hz in [30.0, 40.0, 60.0, 90.0, 120.0]) {
      tester.view.display.refreshRate = hz;
      expect(MotionProfile.refreshRateOf(captured), hz);
      expect(MotionProfile.lowRefreshOf(captured), hz < 50);
      expect(MotionProfile.costlyEffectsAllowed(captured), hz >= 50);
    }
  });
}
