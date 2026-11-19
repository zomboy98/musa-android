import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';

/// Key of the heartbeat highlight, for tests and diagnostics.
const playbackLoadingPulseKey = ValueKey('playback-loading-pulse');

/// Label read by screen readers while a track is being prepared.
String playbackLoadingLabel(BuildContext context) =>
    context.l10n.playbackPulseLoading;

/// A soft heartbeat that travels along a seek track while a song prepares.
///
/// The highlight is a gradient band in the track's accent color. It crosses
/// the track left to right once per [period]; its brightness and thickness
/// follow a "lub-dub" envelope (two short beats, then a rest), so it reads as
/// a pulse that advances instead of a spinner.
///
/// Cost model: one [AnimationController] that runs only while loading (or
/// while the short fade-out plays), a [CustomPainter] inside a
/// [RepaintBoundary] repainted through its `repaint` listenable, so the
/// widget tree is never rebuilt per frame. The ticker follows [TickerMode],
/// and with reduced motion the band is static and faint.
class PlaybackLoadingPulse extends StatefulWidget {
  const PlaybackLoadingPulse({
    super.key,
    required this.loading,
    required this.color,
    this.inset = 0,
    this.trackHeight = 4,
    this.period = const Duration(milliseconds: 1600),
    this.fadeDuration = const Duration(milliseconds: 240),
  });

  final bool loading;
  final Color color;

  /// Horizontal space before and after the track.
  final double inset;
  final double trackHeight;
  final Duration period;
  final Duration fadeDuration;

  @override
  State<PlaybackLoadingPulse> createState() => _PlaybackLoadingPulseState();
}

class _PlaybackLoadingPulseState extends State<PlaybackLoadingPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _phase = AnimationController(
    vsync: this,
    duration: widget.period,
  );
  bool _shown = false;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _shown = widget.loading;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _sync();
  }

  @override
  void didUpdateWidget(PlaybackLoadingPulse oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.loading && !_shown) _shown = true;
    _sync();
  }

  void _sync() {
    if (widget.loading && !_reduceMotion) {
      if (!_phase.isAnimating) _phase.repeat();
    } else if (_reduceMotion || !_shown) {
      _phase.stop();
      // No fade under reduced motion: drop the highlight right away.
      if (!widget.loading) _shown = false;
    }
    // When loading ends, the fade-out keeps the phase running until onEnd.
  }

  void _fadeEnded() {
    if (widget.loading || !mounted) return;
    _phase.stop();
    setState(() => _shown = false);
  }

  @override
  void dispose() {
    _phase.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_shown || (!widget.loading && _reduceMotion)) {
      return const SizedBox.shrink();
    }
    final fadeTime = _reduceMotion ? Duration.zero : widget.fadeDuration;
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: widget.loading ? playbackLoadingLabel(context) : null,
        child: AnimatedOpacity(curve: Curves.easeOutCubic,
          key: playbackLoadingPulseKey,
          opacity: widget.loading ? 1 : 0,
          duration: fadeTime,
          onEnd: _fadeEnded,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _HeartbeatPainter(
                phase: _phase,
                color: widget.color,
                inset: widget.inset,
                trackHeight: widget.trackHeight,
                still: _reduceMotion,
              ),
              size: Size.infinite,
            ),
          ),
        ),
      ),
    );
  }
}

/// Brightness in `[0, 1]` for a cycle position: a strong beat and a softer
/// second one, with a rest before the next cycle.
@visibleForTesting
double heartbeatEnvelope(double t) {
  double bump(double center, double width) {
    final d = (t - center) / width;
    return math.exp(-d * d);
  }

  return math.max(bump(0.22, 0.07), 0.7 * bump(0.44, 0.07));
}

class _HeartbeatPainter extends CustomPainter {
  _HeartbeatPainter({
    required this.phase,
    required this.color,
    required this.inset,
    required this.trackHeight,
    required this.still,
  }) : super(repaint: phase);

  final Animation<double> phase;
  final Color color;
  final double inset;
  final double trackHeight;
  final bool still;

  @override
  void paint(Canvas canvas, Size size) {
    final left = inset;
    final trackWidth = size.width - inset * 2;
    if (trackWidth <= 0) return;
    final cy = size.height / 2;
    final t = still ? 0.0 : phase.value;
    final beat = still ? 0.35 : 0.3 + 0.7 * heartbeatEnvelope(t);
    // Thickness breathes slightly with the beat, never beyond ~1.5x.
    final h = trackHeight * (1 + 0.5 * (still ? 0 : beat - 0.3));
    final track = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, cy - h / 2, trackWidth, h),
      Radius.circular(h / 2),
    );
    final bandWidth = math.max(48.0, trackWidth * 0.26);
    final head = still
        ? left + trackWidth * 0.5
        : left -
              bandWidth / 2 +
              (trackWidth + bandWidth) * Curves.easeInOutSine.transform(t);
    final rect = Rect.fromLTWH(head - bandWidth / 2, 0, bandWidth, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          color.withValues(alpha: 0),
          color.withValues(alpha: 0.85 * beat),
          color.withValues(alpha: 0),
        ],
      ).createShader(rect);
    canvas
      ..save()
      ..clipRRect(track)
      ..drawRect(rect, paint)
      ..restore();
  }

  @override
  bool shouldRepaint(_HeartbeatPainter old) =>
      old.color != color ||
      old.inset != inset ||
      old.trackHeight != trackHeight ||
      old.still != still ||
      old.phase != phase;
}
