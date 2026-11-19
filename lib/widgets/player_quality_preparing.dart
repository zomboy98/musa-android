import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/catalog_playback.dart' show CatalogPreparation;
import 'package:mornye/utils/quality_mark.dart';
import 'package:mornye/widgets/player_cover_quality.dart';
import 'package:mornye/widgets/quality_mark_art.dart';

/// The format a song is being prepared in, lit up from the left as the
/// preparation advances. Uses the same fill as a live quality switch and keeps
/// the size of the selector so nothing moves when it is replaced.
class PreparingQualityMark extends StatefulWidget {
  const PreparingQualityMark({
    super.key,
    required this.mark,
    required this.started,
    required this.label,
    this.detail,
    this.realProgress,
    this.colorScheme,
    this.height = 44,
    this.badgeSize = 26,
    this.compact = false,
    this.tick = const Duration(milliseconds: 160),
  });

  final QualityMark mark;
  final String? detail;
  final DateTime started;
  final String label;
  final double? Function()? realProgress;
  final ColorScheme? colorScheme;
  final double height;
  final double badgeSize;
  final bool compact;
  final Duration tick;

  @override
  State<PreparingQualityMark> createState() => _PreparingQualityMarkState();
}

class _PreparingQualityMarkState extends State<PreparingQualityMark> {
  final _progress = ValueNotifier<double>(0);
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(PreparingQualityMark old) {
    super.didUpdateWidget(old);
    if (old.started != widget.started) {
      _progress.value = 0;
      _start();
    } else if (old.tick != widget.tick) {
      _start();
    }
  }

  void _start() {
    _ticker?.cancel();
    _update();
    _ticker = Timer.periodic(widget.tick, (_) => _update());
  }

  void _update() {
    final elapsed = DateTime.now().difference(widget.started);
    final real = widget.realProgress?.call();
    final next = real == null
        ? estimatedQualityProgress(elapsed, slow: !isLossyMark(widget.mark))
        : math.min(real, 0.95);
    if (next > _progress.value) _progress.value = next;
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _progress.dispose();
    super.dispose();
  }

  Widget _logo(Color color) => QualityMarkLockup(
    mark: widget.mark,
    detail: widget.detail,
    color: color,
    size: widget.badgeSize,
    compact: widget.compact,
  );

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? Theme.of(context).colorScheme;
    final color = scheme.onSurface;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final l10n = context.l10n;
    Widget filled(double fill) => Stack(
      children: [
        Opacity(opacity: 0.32, child: _logo(color)),
        ClipRect(
          child: Align(
            alignment: Alignment.centerLeft,
            widthFactor: fill,
            heightFactor: 1,
            child: _logo(color),
          ),
        ),
      ],
    );
    return RepaintBoundary(
      child: ValueListenableBuilder<double>(
        valueListenable: _progress,
        builder: (context, progress, _) {
          final percent = (progress * 20).floor() * 5;
          return Semantics(
            label: '${l10n.qualityPickerTitle}: ${widget.label}',
            value: '$percent %',
            liveRegion: false,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: widget.height),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Center(
                    widthFactor: 1,
                    child: reduce
                        ? filled(progress)
                        : TweenAnimationBuilder<double>(
                            tween: Tween(end: progress),
                            duration: const Duration(milliseconds: 240),
                            curve: Curves.easeOut,
                            builder: (context, fill, _) => filled(fill),
                          ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

enum PreparationStage { quiet, slow, trying, stuck }

const Duration preparationSlowAfter = Duration(seconds: 8);
const Duration preparationTryingAfter = Duration(seconds: 20);
const Duration preparationActionsAfter = Duration(seconds: 45);

/// Progressive, non-blocking feedback under the badge while a song is being
/// prepared: after 8 s a calm note, after 20 s a note about the relay moving
/// to another candidate (only once it really did), after 45 s retry and
/// cancel. It disappears with the preparation.
class PreparationFeedback extends StatefulWidget {
  const PreparationFeedback({
    super.key,
    required this.preparation,
    required this.onRetry,
    required this.onCancel,
    this.colorScheme,
  });

  final CatalogPreparation preparation;
  final VoidCallback onRetry;
  final VoidCallback onCancel;
  final ColorScheme? colorScheme;

  @override
  State<PreparationFeedback> createState() => _PreparationFeedbackState();
}

class _PreparationFeedbackState extends State<PreparationFeedback> {
  final List<Timer> _timers = [];
  Duration _elapsed = Duration.zero;
  int _candidates = 1;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(PreparationFeedback old) {
    super.didUpdateWidget(old);
    final prep = widget.preparation;
    if (old.preparation.key != prep.key ||
        old.preparation.started != prep.started) {
      _candidates = 1;
      _arm();
    } else if (!identical(old.preparation, prep)) {
      _candidates++;
    }
  }

  void _arm() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    final already = DateTime.now().difference(widget.preparation.started);
    _elapsed = already.isNegative ? Duration.zero : already;
    for (final at in const [
      preparationSlowAfter,
      preparationTryingAfter,
      preparationActionsAfter,
    ]) {
      final left = at - _elapsed;
      if (left <= Duration.zero) continue;
      _timers.add(
        Timer(left, () {
          if (!mounted) return;
          setState(() => _elapsed = at);
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  bool get _relayed => _candidates >= 3;

  PreparationStage get _stage {
    if (_elapsed >= preparationActionsAfter) return PreparationStage.stuck;
    if (_elapsed >= preparationTryingAfter && _relayed) {
      return PreparationStage.trying;
    }
    if (_elapsed >= preparationSlowAfter) return PreparationStage.slow;
    return PreparationStage.quiet;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final stage = _stage;
    final reduce = MediaQuery.disableAnimationsOf(context);
    final trying = _relayed && stage != PreparationStage.slow;
    final line = switch (stage) {
      PreparationStage.quiet => null,
      PreparationStage.slow => l10n.qualityPreparingSlow,
      _ => trying ? l10n.qualityPreparingTrying : l10n.qualityPreparingSlow,
    };
    final semantics = line == l10n.qualityPreparingSlow
        ? l10n.qualityPreparingSlowSemantics
        : line;
    final body = line == null
        ? const SizedBox.shrink(key: ValueKey('preparation-quiet'))
        : DecoratedBox(
            key: ValueKey('preparation-$stage-$trying'),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(18),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    liveRegion: true,
                    label: semantics,
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          line,
                          key: const ValueKey('preparation-note'),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                      ),
                    ),
                  ),
                  if (stage == PreparationStage.stuck)
                    Wrap(
                      alignment: WrapAlignment.center,
                      children: [
                        TextButton(
                          key: const ValueKey('preparation-retry'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: widget.onRetry,
                          child: Text(l10n.qualityPreparingRetry),
                        ),
                        TextButton(
                          key: const ValueKey('preparation-cancel'),
                          style: TextButton.styleFrom(
                            foregroundColor: Colors.white70,
                            textStyle: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                            visualDensity: VisualDensity.compact,
                          ),
                          onPressed: widget.onCancel,
                          child: Text(l10n.qualityPreparingCancel),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          );
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 150),
      layoutBuilder: (current, previous) => Align(
        alignment: Alignment.center,
        child: current ?? const SizedBox.shrink(),
      ),
      child: body,
    );
  }
}
