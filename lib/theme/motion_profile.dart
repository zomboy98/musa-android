import 'dart:ui' show FlutterView;

import 'package:flutter/widgets.dart';

/// What the phone allows for motion, read from the system and the display.
///
/// Animation durations and curves never depend on this: they are fixed in
/// time, so a 90 or 120 Hz display only draws more frames of the same motion.
/// The profile only turns off optional effects that are costly to draw on
/// every frame, such as live backdrop blur behind scrolling content, when the
/// display runs at a low rate (a power-saving profile or a 30 or 40 Hz mode)
/// and every frame is expensive to meet.
abstract final class MotionProfile {
  /// Below this rate the display is in a power-saving or fixed low-rate mode.
  static const lowRefreshRateThreshold = 50.0;

  /// Rate the display is running at, in Hz; 60 when the platform reports none.
  static double refreshRateOf(BuildContext context) =>
      refreshRateOfView(View.maybeOf(context));

  /// Same as [refreshRateOf] for a view, usable before any widget exists.
  static double refreshRateOfView(FlutterView? view) {
    final rate = view?.display.refreshRate ?? 0;
    return rate > 0 ? rate : 60;
  }

  /// Whether the display runs at a low rate, so optional continuous effects
  /// should stay off.
  static bool lowRefreshOf(BuildContext context) =>
      refreshRateOf(context) < lowRefreshRateThreshold;

  /// Whether optional, costly effects (live blur, ambient drift) may run.
  static bool costlyEffectsAllowed(BuildContext context) =>
      !lowRefreshOf(context);
}
