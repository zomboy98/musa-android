import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';

/// A duration and curve pair for implicit animations.
@immutable
class AppMotionSpec {
  const AppMotionSpec(this.duration, this.curve);

  final Duration duration;
  final Curve curve;
}

/// A [Curve] that follows an [M3ESpring] released from rest at 0 toward 1.
///
/// [duration] is the spring's settling time, so implicit animations driven by
/// this curve end exactly when the physical motion does.
class SpringCurve extends Curve {
  SpringCurve(M3ESpring spring)
    : this._(SpringSimulation(spring.toDescription(), 0, 1, 0));

  SpringCurve._(this._simulation) : duration = _settleTime(_simulation);

  final SpringSimulation _simulation;
  final Duration duration;

  static Duration _settleTime(SpringSimulation simulation) {
    const step = 1 / 1000;
    var settledSince = 0.0;
    for (var t = 0.0; t < 2; t += step) {
      final settled =
          (simulation.x(t) - 1).abs() < 0.002 && simulation.dx(t).abs() < 0.02;
      if (!settled) {
        settledSince = t + step;
      } else if (t - settledSince >= 0.05) {
        break;
      }
    }
    return Duration(microseconds: (settledSince * 1e6).round());
  }

  @override
  double transformInternal(double t) =>
      _simulation.x(t * duration.inMicroseconds / 1e6);
}

/// Sober Material motion for the Material theme.
///
/// Standard ease-out curves with no overshoot: transitions last 200-350 ms
/// and micro-interactions 120-200 ms. Durations never depend on the display
/// refresh rate; the engine samples the curve once per frame, so the same
/// motion looks smoother at 90 or 120 Hz without changing speed. Mornye and
/// reduced motion keep each call site's original [AppMotionSpec].
abstract final class AppMotion {
  static const _spatialFast = AppMotionSpec(
    Duration(milliseconds: 200),
    Curves.easeOutCubic,
  );
  static const _spatialDefault = AppMotionSpec(
    Duration(milliseconds: 300),
    Curves.easeOutCubic,
  );
  static const _spatialSlow = AppMotionSpec(
    Duration(milliseconds: 350),
    Curves.fastOutSlowIn,
  );
  static const _effectsFast = AppMotionSpec(
    Duration(milliseconds: 120),
    Curves.easeOut,
  );
  static const _effectsDefault = AppMotionSpec(
    Duration(milliseconds: 200),
    Curves.easeOut,
  );

  /// Fast spatial motion for small components: chips, checks, buttons.
  static AppMotionSpec spatialFast(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _spatialFast : fallback;

  /// Default spatial motion for list items, panels and content changes.
  static AppMotionSpec spatial(BuildContext context, AppMotionSpec fallback) =>
      materialExpressiveEnabled(context) ? _spatialDefault : fallback;

  /// Slow spatial motion for full-screen surfaces such as the player.
  static AppMotionSpec spatialSlow(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _spatialSlow : fallback;

  /// Fast effects motion for opacity and color.
  static AppMotionSpec effectsFast(
    BuildContext context,
    AppMotionSpec fallback,
  ) => materialExpressiveEnabled(context) ? _effectsFast : fallback;

  /// Default effects motion for opacity and color.
  static AppMotionSpec effects(BuildContext context, AppMotionSpec fallback) =>
      materialExpressiveEnabled(context) ? _effectsDefault : fallback;

  /// Entrance for sheets and menus: a short ease-out that never overshoots
  /// its own size and reveals what is behind it. Null keeps the platform
  /// transition.
  static AnimationStyle? surfaceEntrance(BuildContext context) =>
      materialExpressiveEnabled(context)
      ? const AnimationStyle(
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          reverseDuration: Duration(milliseconds: 200),
          reverseCurve: Curves.easeInCubic,
        )
      : null;
}
