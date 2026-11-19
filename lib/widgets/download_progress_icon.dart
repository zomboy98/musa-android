import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';

/// What the per-song download icon shows.
enum DownloadIconPhase {
  /// Nothing in flight: the plain download glyph (also after a cancel).
  idle,

  /// Tap registered or waiting in the queue: static neutral glyph.
  queued,

  /// Transferring. [DownloadProgressIcon.progress] null means unknown size.
  downloading,

  /// Transfer done, file being tagged/moved: full ring, pulsing.
  finalizing,

  /// File is available: filled check.
  completed,

  /// Last attempt failed: retry glyph in the error color.
  failed,
}

/// Texts used for the accessibility label of [DownloadProgressIcon].
class DownloadIconLabels {
  const DownloadIconLabels({
    required this.idle,
    required this.queued,
    required this.downloading,
    required this.finalizing,
    required this.completed,
    required this.failed,
  });

  final String idle;
  final String queued;

  /// Receives the whole percentage (0-100), or null when unknown.
  final String Function(int? percent) downloading;
  final String finalizing;
  final String completed;
  final String failed;

  /// Reuses existing strings where they exist; the two without a key
  /// (queued, downloading + percent) fall back to Spanish or English.
  factory DownloadIconLabels.of(BuildContext context) {
    final l10n = context.l10n;
    return DownloadIconLabels(
      idle: l10n.dialogDownload,
      queued: context.l10n.downloadProgressQueued,
      downloading: (percent) {
        final base = context.l10n.downloadProgressDownloading;
        return percent == null ? base : '$base $percent %';
      },
      finalizing: l10n.queueFinalizingDownload,
      completed: l10n.trackDownloaded,
      failed: l10n.dialogRetry,
    );
  }

  String describe(DownloadIconPhase phase, double? progress) {
    switch (phase) {
      case DownloadIconPhase.idle:
        return idle;
      case DownloadIconPhase.queued:
        return queued;
      case DownloadIconPhase.downloading:
        return downloading(
          progress == null ? null : (progress.clamp(0.0, 1.0) * 100).round(),
        );
      case DownloadIconPhase.finalizing:
        return finalizing;
      case DownloadIconPhase.completed:
        return completed;
      case DownloadIconPhase.failed:
        return failed;
    }
  }
}

/// Icon that reflects the state and progress of one download.
///
/// Pure view: callers decide [phase]/[progress]. Progress is interpolated
/// between updates, loops (pulse, indeterminate sweep) are skipped when the
/// platform asks for reduced motion, and only this icon repaints.
class DownloadProgressIcon extends StatefulWidget {
  const DownloadProgressIcon({
    super.key,
    required this.phase,
    this.progress,
    this.idleIcon = Icons.download_outlined,
    this.size,
    this.color,
    this.idleColor,
    this.labels,
  });

  final DownloadIconPhase phase;

  /// 0..1 while [DownloadIconPhase.downloading]; null when unknown.
  final double? progress;
  final IconData idleIcon;

  /// Defaults to the ambient [IconTheme] size, then 24.
  final double? size;

  /// Ring/check color; defaults to the theme primary.
  final Color? color;

  /// Color of the idle glyph; defaults to the ambient [IconTheme] color.
  final Color? idleColor;
  final DownloadIconLabels? labels;

  @override
  State<DownloadProgressIcon> createState() => _DownloadProgressIconState();
}

class _DownloadProgressIconState extends State<DownloadProgressIcon>
    with SingleTickerProviderStateMixin {
  static const _fillDuration = Duration(milliseconds: 360);
  static const _popDuration = Duration(milliseconds: 320);

  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );
  int _popEpoch = 0;
  bool _reduceMotion = false;

  bool get _needsLoop {
    switch (widget.phase) {
      case DownloadIconPhase.finalizing:
        return true;
      case DownloadIconPhase.queued:
        return false;
      case DownloadIconPhase.downloading:
        return widget.progress == null;
      case DownloadIconPhase.idle:
      case DownloadIconPhase.completed:
      case DownloadIconPhase.failed:
        return false;
    }
  }

  void _syncLoop() {
    if (_needsLoop && !_reduceMotion) {
      if (!_loop.isAnimating) _loop.repeat();
    } else if (_loop.isAnimating) {
      _loop.stop();
      _loop.value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _syncLoop();
  }

  @override
  void didUpdateWidget(DownloadProgressIcon old) {
    super.didUpdateWidget(old);
    final wasActive =
        old.phase == DownloadIconPhase.queued ||
        old.phase == DownloadIconPhase.downloading ||
        old.phase == DownloadIconPhase.finalizing;
    if (wasActive && widget.phase == DownloadIconPhase.completed) _popEpoch++;
    _syncLoop();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final iconTheme = IconTheme.of(context);
    final size = widget.size ?? iconTheme.size ?? 24;
    final active = widget.color ?? scheme.primary;
    final labels = widget.labels ?? DownloadIconLabels.of(context);
    final phase = widget.phase;
    final target = switch (phase) {
      DownloadIconPhase.finalizing => 1.0,
      DownloadIconPhase.downloading => widget.progress?.clamp(0.0, 1.0),
      _ => 0.0,
    };

    final Widget visual;
    if (phase == DownloadIconPhase.idle) {
      visual = Icon(
        widget.idleIcon,
        key: const ValueKey('download-icon-idle'),
        size: size,
        color: widget.idleColor ?? iconTheme.color,
      );
    } else if (phase == DownloadIconPhase.queued) {
      visual = Icon(
        widget.idleIcon,
        key: const ValueKey('download-icon-queued'),
        size: size,
        color: widget.idleColor ?? scheme.onSurfaceVariant,
      );
    } else if (phase == DownloadIconPhase.failed) {
      visual = Icon(
        Icons.refresh,
        key: const ValueKey('download-icon-failed'),
        size: size,
        color: scheme.error,
      );
    } else {
      visual = RepaintBoundary(
        key: const ValueKey('download-icon-progress'),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(end: target ?? 0),
          duration: _reduceMotion ? Duration.zero : _fillDuration,
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => TweenAnimationBuilder<double>(
            key: ValueKey(_popEpoch),
            tween: Tween<double>(begin: 0, end: 1),
            duration: _popEpoch == 0 || _reduceMotion
                ? Duration.zero
                : _popDuration,
            curve: Curves.easeOutCubic,
            builder: (context, pop, _) => Transform.scale(
              scale: phase == DownloadIconPhase.completed ? 0.7 + 0.3 * pop : 1,
              child: AnimatedBuilder(
                animation: _loop,
                builder: (context, _) => CustomPaint(
                  size: Size.square(size),
                  painter: DownloadIconPainter(
                    phase: phase,
                    progress: target == null ? null : value,
                    loop: _loop.value,
                    color: active,
                    onColor: scheme.onPrimary,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: labels.describe(phase, widget.progress),
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: size,
        child: AnimatedSwitcher(
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          duration: _reduceMotion
              ? Duration.zero
              : const Duration(milliseconds: 160),
          layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.center,
            children: [...previous, ?current],
          ),
          child: visual,
        ),
      ),
    );
  }
}

/// Draws ring, arrow and check for [DownloadProgressIcon].
class DownloadIconPainter extends CustomPainter {
  const DownloadIconPainter({
    required this.phase,
    required this.progress,
    required this.loop,
    required this.color,
    required this.onColor,
  });

  final DownloadIconPhase phase;

  /// Ring fill 0..1; null draws the indeterminate sweep.
  final double? progress;

  /// 0..1 loop clock (0 when animations are off).
  final double loop;
  final Color color;
  final Color onColor;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final center = size.center(Offset.zero);
    final stroke = math.max(1.8, s * 0.1);
    final radius = (s - stroke) / 2;
    final pulse = 0.5 - 0.5 * math.cos(loop * 2 * math.pi);

    if (phase == DownloadIconPhase.completed) {
      canvas.drawCircle(center, radius, Paint()..color = color);
      final check = Path()
        ..moveTo(center.dx - s * 0.22, center.dy + s * 0.01)
        ..lineTo(center.dx - s * 0.06, center.dy + s * 0.17)
        ..lineTo(center.dx + s * 0.23, center.dy - s * 0.14);
      canvas.drawPath(
        check,
        Paint()
          ..color = onColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 0.9
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
      return;
    }

    const trackAlpha = 0.25;
    final ring = Rect.fromCircle(center: center, radius: radius);
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = color.withValues(alpha: trackAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );

    final arcPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    if (phase == DownloadIconPhase.downloading ||
        phase == DownloadIconPhase.finalizing) {
      final fill = progress;
      if (fill == null) {
        canvas.drawArc(
          ring,
          -math.pi / 2 + loop * 2 * math.pi,
          math.pi * 0.55,
          false,
          arcPaint,
        );
      } else {
        // Soft tint inside the ring that deepens with the progress.
        canvas.drawCircle(
          center,
          radius - stroke / 2,
          Paint()..color = color.withValues(alpha: 0.06 + 0.16 * fill),
        );
        if (fill > 0) {
          canvas.drawArc(
            ring,
            -math.pi / 2,
            2 * math.pi * fill,
            false,
            arcPaint,
          );
        }
      }
    }

    final arrowAlpha = switch (phase) {
      DownloadIconPhase.finalizing => 0.6 + 0.4 * pulse,
      _ => 1.0,
    };
    final arrow = Paint()
      ..color = color.withValues(alpha: arrowAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.85
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final h = s * 0.17;
    final path = Path()
      ..moveTo(center.dx, center.dy - h)
      ..lineTo(center.dx, center.dy + h)
      ..moveTo(center.dx - h * 0.85, center.dy + h * 0.15)
      ..lineTo(center.dx, center.dy + h)
      ..lineTo(center.dx + h * 0.85, center.dy + h * 0.15);
    canvas.drawPath(path, arrow);
  }

  @override
  bool shouldRepaint(DownloadIconPainter old) =>
      old.phase != phase ||
      old.progress != progress ||
      old.loop != loop ||
      old.color != color ||
      old.onColor != onColor;
}

/// What the queue knows about one track, small enough to compare cheaply so
/// that a progress sample of another track never rebuilds this icon.
typedef DownloadIconQueueSnapshot = ({
  DownloadStatus status,
  double progress,
  bool preparing,
});

/// Maps the queue snapshot, an optimistic "just tapped" flag and the
/// on-disk availability to the icon phase. Pure so it is easy to test.
({DownloadIconPhase phase, double? progress}) resolveDownloadIconPhase({
  required DownloadIconQueueSnapshot? queue,
  bool pending = false,
  bool available = false,
  bool failed = false,
}) {
  if (queue != null) {
    switch (queue.status) {
      case DownloadStatus.queued:
        return (phase: DownloadIconPhase.queued, progress: null);
      case DownloadStatus.downloading:
        return (
          phase: DownloadIconPhase.downloading,
          progress: queue.preparing || queue.progress <= 0
              ? null
              : queue.progress.clamp(0.0, 1.0),
        );
      case DownloadStatus.finalizing:
        return (phase: DownloadIconPhase.finalizing, progress: 1);
      case DownloadStatus.completed:
        if (!pending) {
          return (phase: DownloadIconPhase.completed, progress: null);
        }
      case DownloadStatus.failed:
        if (!pending && !available) {
          return (phase: DownloadIconPhase.failed, progress: null);
        }
      case DownloadStatus.skipped:
        break; // cancelled: back to the starting state
    }
  }
  if (pending) return (phase: DownloadIconPhase.queued, progress: null);
  if (available) return (phase: DownloadIconPhase.completed, progress: null);
  if (failed) return (phase: DownloadIconPhase.failed, progress: null);
  return (phase: DownloadIconPhase.idle, progress: null);
}

/// [DownloadProgressIcon] wired to the download queue for one [track].
///
/// Observes only this track through a record `select`, so the row that hosts
/// it is not rebuilt by progress samples.
class TrackDownloadProgressIcon extends ConsumerWidget {
  const TrackDownloadProgressIcon({
    super.key,
    required this.track,
    this.available = false,
    this.failed = false,
    this.pending,
    this.idleIcon = Icons.download_outlined,
    this.size,
    this.color,
    this.idleColor,
  });

  final Track track;

  /// The file already exists (downloaded or kept offline).
  final bool available;

  /// The caller knows the last attempt failed even without a queue item.
  final bool failed;

  /// True from the tap until the queue registers the item.
  final ValueListenable<bool>? pending;
  final IconData idleIcon;
  final double? size;
  final Color? color;
  final Color? idleColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(
      downloadQueueLookupProvider.select((lookup) {
        final item = lookup.byTrackId[track.id];
        if (item == null) return null;
        final DownloadIconQueueSnapshot snap = (
          status: item.status,
          progress: item.progress,
          preparing:
              item.status == DownloadStatus.downloading &&
              item.progress <= 0 &&
              item.bytesTotal <= 0 &&
              item.bytesReceived <= 0,
        );
        return snap;
      }),
    );
    Widget build(bool isPending) {
      final resolved = resolveDownloadIconPhase(
        queue: snapshot,
        pending: isPending,
        available: available,
        failed: failed,
      );
      return DownloadProgressIcon(
        phase: resolved.phase,
        progress: resolved.progress,
        idleIcon: idleIcon,
        size: size,
        color: color,
        idleColor: idleColor,
      );
    }

    final listenable = pending;
    if (listenable == null) return build(false);
    return ValueListenableBuilder<bool>(
      valueListenable: listenable,
      builder: (_, isPending, _) => build(isPending),
    );
  }
}
