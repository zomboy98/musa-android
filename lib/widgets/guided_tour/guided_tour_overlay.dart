import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/guided_tour_provider.dart';
import 'package:mornye/widgets/guided_tour/guided_tour_anchors.dart';

class GuidedTourOverlay extends ConsumerStatefulWidget {
  const GuidedTourOverlay({super.key, required this.anchors});

  final GuidedTourAnchors anchors;

  @override
  ConsumerState<GuidedTourOverlay> createState() => _GuidedTourOverlayState();
}

class _GuidedTourOverlayState extends ConsumerState<GuidedTourOverlay> {
  static const Duration _pollEvery = Duration(milliseconds: 100);
  static const int _lostTicksToSkip = 18;

  late final List<GuidedTourTarget> _steps = [
    for (final target in guidedTourOrder)
      if (widget.anchors.isAvailable(target)) target,
  ];
  int _index = 0;
  Rect? _rect;
  Timer? _poll;
  int _lostTicks = 0;
  bool _revealed = false;
  GuidedTourScreen _screen = GuidedTourScreen.shell;

  @override
  void initState() {
    super.initState();
    if (_steps.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.read(guidedTourProvider.notifier).dismissWithoutCompleting();
        }
      });
      return;
    }
    widget.anchors.prepare();
    _poll = Timer.periodic(_pollEvery, (_) => _measure());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _measure() {
    if (!mounted || _steps.isEmpty) return;
    final ancestor = context.findRenderObject();
    final rect = ancestor == null || !ancestor.attached
        ? null
        : widget.anchors.rectFor(_steps[_index], ancestor);
    if (rect != null) {
      if (!_reveal(rect, ancestor)) return;
      _lostTicks = 0;
      if (rect != _rect) setState(() => _rect = rect);
      return;
    }
    _lost();
  }

  bool _reveal(Rect rect, RenderObject? ancestor) {
    if (ancestor is! RenderBox) return true;
    final bounds = Offset.zero & ancestor.size;
    if (bounds.contains(rect.center)) return true;
    final scrollable = widget.anchors.scrollContextFor(_steps[_index]);
    if (scrollable != null && scrollable.mounted && !_revealed) {
      _revealed = true;
      unawaited(
        Scrollable.ensureVisible(
          scrollable,
          alignment: 0.35,
          duration: const Duration(milliseconds: 200),
        ),
      );
    }
    _lostTicks = 0;
    return false;
  }

  void _lost() {
    if (_rect != null) setState(() => _rect = null);
    if (++_lostTicks < _lostTicksToSkip) return;
    _lostTicks = 0;
    _steps.removeAt(_index);
    if (_steps.isEmpty) {
      unawaited(_finish());
      return;
    }
    setState(() {
      if (_index >= _steps.length) _index = _steps.length - 1;
      _rect = null;
    });
    _enterStep();
  }

  void _next() {
    if (_index >= _steps.length - 1) {
      unawaited(_finish());
      return;
    }
    setState(() {
      _index++;
      _rect = null;
    });
    _enterStep();
  }

  void _enterStep() {
    _revealed = false;
    _lostTicks = 0;
    widget.anchors.prepare();
    final screen = guidedTourScreenOf(_steps[_index]);
    if (screen == _screen) return;
    _screen = screen;
    unawaited(widget.anchors.openScreen(screen));
  }

  Future<void> _finish() async {
    if (_screen != GuidedTourScreen.shell) {
      _screen = GuidedTourScreen.shell;
      await widget.anchors.openScreen(GuidedTourScreen.shell);
    }
    if (mounted) await ref.read(guidedTourProvider.notifier).finish();
  }

  ({String title, String body}) _text(GuidedTourTarget target) {
    final l10n = context.l10n;
    return switch (target) {
      GuidedTourTarget.home => (
        title: l10n.tourHomeTitle,
        body: widget.anchors.homeHasSearch
            ? l10n.tourHomeSearchBody
            : l10n.tourHomeBody,
      ),
      GuidedTourTarget.search => (
        title: l10n.tourSearchTitle,
        body: l10n.tourSearchBody,
      ),
      GuidedTourTarget.library => (
        title: l10n.tourLibraryTitle,
        body: l10n.tourLibraryBody,
      ),
      GuidedTourTarget.miniPlayer => (
        title: l10n.tourPlayerTitle,
        body: l10n.tourPlayerBody,
      ),
      GuidedTourTarget.store => (
        title: l10n.tourAddonsTitle,
        body: ref.read(extensionProvider).extensions.isEmpty
            ? l10n.tourAddonsBody
            : l10n.tourSourcesBody,
      ),
      GuidedTourTarget.settings => (
        title: l10n.tourSettingsTitle,
        body: l10n.tourSettingsBody,
      ),
      GuidedTourTarget.profile => (
        title: l10n.tourProfileTitle,
        body: l10n.tourProfileBody,
      ),
      GuidedTourTarget.code => (
        title: l10n.tourCodeTitle,
        body: l10n.tourCodeBody,
      ),
      GuidedTourTarget.catalog => (
        title: l10n.tourCatalogTitle,
        body: l10n.tourCatalogBody,
      ),
      GuidedTourTarget.homeSource => (
        title: l10n.tourHomeSourceTitle,
        body: l10n.tourHomeSourceBody,
      ),
      GuidedTourTarget.finale => (
        title: l10n.tourFinaleTitle,
        body: l10n.tourFinaleBody,
      ),
    };
  }

  Widget _hole(Rect focus, GuidedTourTap tap) => switch (tap) {
    GuidedTourTap.block => Positioned.fromRect(
      rect: focus,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: const SizedBox.expand(),
      ),
    ),
    GuidedTourTap.advance => Positioned.fromRect(
      rect: focus,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerUp: (_) => _next(),
        child: const SizedBox.expand(),
      ),
    ),
    GuidedTourTap.passThrough => const SizedBox.shrink(),
  };

  List<Widget> _blockers(Rect? focus) {
    Widget block(Rect rect) => Positioned.fromRect(
      rect: rect,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {},
        child: const SizedBox.expand(),
      ),
    );
    if (focus == null || focus.isEmpty) {
      return [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {},
          ),
        ),
      ];
    }
    const far = 4000.0;
    return [
      block(Rect.fromLTRB(-far, -far, far, focus.top)),
      block(Rect.fromLTRB(-far, focus.bottom, far, far)),
      block(Rect.fromLTRB(-far, focus.top, focus.left, focus.bottom)),
      block(Rect.fromLTRB(focus.right, focus.top, far, focus.bottom)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_steps.isEmpty) return const SizedBox.shrink();
    MediaQuery.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    if (_steps.isEmpty) return const SizedBox.shrink();

    final l10n = context.l10n;
    final theme = Theme.of(context);
    final text = _text(_steps[_index]);
    final last = _index == _steps.length - 1;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 260);
    final hole = _rect?.inflate(6);

    return BackButtonListener(
      onBackButtonPressed: () async {
        unawaited(_finish());
        return true;
      },
      child: BlockSemantics(
        child: TweenAnimationBuilder<Rect?>(
          tween: RectTween(end: hole ?? Rect.zero),
          duration: duration,
          curve: Curves.easeOutCubic,
          builder: (context, animated, _) {
            final focus = hole == null ? null : animated;
            return Stack(
              fit: StackFit.expand,
              children: [
                IgnorePointer(
                  child: CustomPaint(
                    painter: GuidedTourScrimPainter(
                      focus,
                      accent: theme.colorScheme.primary,
                    ),
                  ),
                ),
                ..._blockers(focus),
                if (focus != null && !focus.isEmpty)
                  _hole(focus, guidedTourTapOf(_steps[_index])),
                CustomSingleChildLayout(
                  delegate: _CardLayout(
                    focus: focus,
                    padding: MediaQuery.paddingOf(context),
                  ),
                  child: Material(
                    color: theme.colorScheme.surfaceContainerHigh,
                    elevation: 6,
                    borderRadius: BorderRadius.circular(20),
                    clipBehavior: Clip.antiAlias,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.tourStepCounter(_index + 1, _steps.length),
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: 6),
                          AnimatedSwitcher(
                            duration: duration,
                            child: Column(
                              key: ValueKey(_index),
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Semantics(
                                  header: true,
                                  liveRegion: true,
                                  child: Text(
                                    text.title,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  text.body,
                                  style: theme.textTheme.bodyMedium,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            alignment: WrapAlignment.end,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            spacing: 8,
                            runSpacing: 4,
                            children: [
                              if (!last)
                                TextButton(
                                  style: TextButton.styleFrom(
                                    minimumSize: const Size(64, 48),
                                  ),
                                  onPressed: () => unawaited(_finish()),
                                  child: Text(l10n.tourSkip),
                                ),
                              FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(88, 48),
                                ),
                                onPressed: _next,
                                child: Text(
                                  last ? l10n.tourDone : l10n.tourNext,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class GuidedTourScrimPainter extends CustomPainter {
  const GuidedTourScrimPainter(
    this.hole, {
    this.accent = const Color(0xFFFFFFFF),
  });

  final Rect? hole;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Path()..addRect(Offset.zero & size);
    final focus = hole;
    RRect? shape;
    if (focus != null && !focus.isEmpty) {
      final radius = math.min(18.0, math.min(focus.width, focus.height) / 2);
      shape = RRect.fromRectAndRadius(focus, Radius.circular(radius));
      scrim.addRRect(shape);
      scrim.fillType = PathFillType.evenOdd;
    }
    canvas.drawPath(scrim, Paint()..color = const Color(0xCC000000));
    if (shape == null) return;
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..color = accent.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawRRect(
      shape,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(GuidedTourScrimPainter old) =>
      old.hole != hole || old.accent != accent;
}

class _CardLayout extends SingleChildLayoutDelegate {
  const _CardLayout({required this.focus, required this.padding});

  final Rect? focus;
  final EdgeInsets padding;

  static const double _margin = 16;
  static const double _gap = 12;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final width = math.max(
      0.0,
      math.min(360.0, constraints.maxWidth - _margin * 2),
    );
    final height = math.max(0.0, constraints.maxHeight - padding.vertical);
    return BoxConstraints(minWidth: width, maxWidth: width, maxHeight: height);
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final minX = _margin;
    final maxX = math.max(minX, size.width - _margin - childSize.width);
    final minY = padding.top + _margin / 2;
    final maxY = math.max(
      minY,
      size.height - padding.bottom - _margin / 2 - childSize.height,
    );
    final target = focus;
    if (target == null || target.isEmpty) {
      return Offset(
        ((size.width - childSize.width) / 2).clamp(minX, maxX),
        ((size.height - childSize.height) / 2).clamp(minY, maxY),
      );
    }
    final x = (target.center.dx - childSize.width / 2).clamp(minX, maxX);
    final below = target.bottom + _gap;
    final above = target.top - _gap - childSize.height;
    final double y;
    if (below + childSize.height <=
        size.height - padding.bottom - _margin / 2) {
      y = below;
    } else if (above >= minY) {
      y = above;
    } else {
      y = (size.height - childSize.height) / 2;
    }
    return Offset(x, y.clamp(minY, maxY));
  }

  @override
  bool shouldRelayout(_CardLayout old) =>
      old.focus != focus || old.padding != padding;
}
