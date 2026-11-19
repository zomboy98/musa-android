import 'dart:math' as math;

import 'package:flutter/material.dart';

const double videoFillCeiling = 0.95;
const double videoFillTauSeconds = 6;
const double videoFillCompleteSeconds = 0.18;
const double videoShimmerPeriodSeconds = 1.6;
const double videoPulsePeriodSeconds = 1.2;

double videoFillProgress(double seconds) {
  if (seconds <= 0) return 0;
  return videoFillCeiling * (1 - math.exp(-seconds / videoFillTauSeconds));
}

double videoFillAt({
  required double seconds,
  double? doneAt,
  double fillAtDone = 0,
  double? real,
}) {
  if (doneAt != null) {
    final t = ((seconds - doneAt) / videoFillCompleteSeconds).clamp(0.0, 1.0);
    if (t >= 1) return 1;
    return fillAtDone + (1 - fillAtDone) * Curves.easeOut.transform(t);
  }
  final estimate = videoFillProgress(seconds);
  if (real == null) return estimate;
  return math.max(estimate, math.min(real, videoFillCeiling));
}

class VideoFillState {
  VideoFillState(this.clock);

  final Animation<double> clock;
  double? doneAt;
  double fillAtDone = 0;
  double? real;

  double get fill => videoFillAt(
    seconds: clock.value,
    doneAt: doneAt,
    fillAtDone: fillAtDone,
    real: real,
  );

  void complete() {
    if (doneAt != null) return;
    fillAtDone = fill;
    doneAt = clock.value;
  }

  void reset() {
    doneAt = null;
    fillAtDone = 0;
  }
}

class VideoFillClipper extends CustomClipper<Rect> {
  VideoFillClipper(this.state) : super(reclip: state.clock);

  final VideoFillState state;

  double get fill => state.fill;

  @override
  Rect getClip(Size size) =>
      Rect.fromLTWH(0, 0, size.width * fill, size.height);

  @override
  bool shouldReclip(VideoFillClipper oldClipper) => oldClipper.state != state;
}

class VideoFillGlowPainter extends CustomPainter {
  VideoFillGlowPainter({
    required this.state,
    required this.color,
    required this.shimmer,
  }) : super(repaint: state.clock);

  final VideoFillState state;
  final Color color;
  final bool shimmer;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = state.fill;
    final width = size.width * fill;
    if (width <= 0 || !shimmer) return;
    final seconds = state.clock.value;
    final band = math.max(24.0, size.width * 0.3);
    final phase =
        (seconds % videoShimmerPeriodSeconds) / videoShimmerPeriodSeconds;
    final x = phase * (width + band) - band;
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, width, size.height));
    final rect = Rect.fromLTWH(x, 0, band, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: 0.3),
            color.withValues(alpha: 0),
          ],
        ).createShader(rect),
    );
    canvas.restore();
    if (fill < 1) {
      final pulse =
          0.5 + 0.5 * math.sin(2 * math.pi * seconds / videoPulsePeriodSeconds);
      final edge = Rect.fromLTWH(width - 8, 0, 8, size.height);
      canvas.drawRect(
        edge,
        Paint()
          ..shader = LinearGradient(
            colors: [
              color.withValues(alpha: 0),
              color.withValues(alpha: 0.18 + 0.32 * pulse),
            ],
          ).createShader(edge),
      );
    }
  }

  @override
  bool shouldRepaint(VideoFillGlowPainter old) =>
      old.state != state || old.color != color || old.shimmer != shimmer;
}
