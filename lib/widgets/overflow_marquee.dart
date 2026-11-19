import 'dart:async';

import 'package:flutter/material.dart';

/// Reveals overflowing content without making the mini player's text draggable.
class OverflowMarquee extends StatefulWidget {
  const OverflowMarquee({
    super.key,
    required this.resetKey,
    required this.child,
    this.maxCycles,
    this.pause = const Duration(seconds: 3),
    this.speed = 28,
    this.gap = 32,
    this.continuous = false,
    this.fadeBothEdges = false,
  });

  final Object resetKey;
  final Widget child;

  /// Stops at the start after this many passes; null scrolls indefinitely.
  /// A new [resetKey], width or lifecycle resume starts a fresh count.
  final int? maxCycles;

  /// Wait before each pass; with [continuous] only before the first one.
  final Duration pause;

  /// Scroll speed in logical pixels per second.
  final double speed;

  /// Space between the end of the content and its next repetition.
  final double gap;

  /// Starts each pass as soon as the previous one ends, without a pause.
  final bool continuous;

  /// Also fades the leading edge once the content has moved.
  final bool fadeBothEdges;

  @override
  State<OverflowMarquee> createState() => _OverflowMarqueeState();
}

class _OverflowMarqueeState extends State<OverflowMarquee>
    with WidgetsBindingObserver {
  double get _gap => widget.gap;

  late final _scroll = _MarqueeController(() => _running);
  final _contentKey = GlobalKey();
  Timer? _pause;
  int _generation = 0;
  int _cycles = 0;
  bool _restartQueued = false;
  bool _motionEnabled = false;
  bool _appActive = true;
  bool _looping = false;
  bool _running = false;
  double _loopDistance = 0;
  double? _viewport;
  double? _extent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _appActive = lifecycle == null || lifecycle == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _motionEnabled =
        !MediaQuery.disableAnimationsOf(context) &&
        TickerMode.valuesOf(context).enabled;
    _queueRestart();
  }

  @override
  void didUpdateWidget(OverflowMarquee oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.resetKey != oldWidget.resetKey ||
        widget.maxCycles != oldWidget.maxCycles ||
        widget.gap != oldWidget.gap ||
        widget.speed != oldWidget.speed) {
      _queueRestart();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appActive = state == AppLifecycleState.resumed;
    if (!_appActive && _scroll.hasClients) {
      _pause?.cancel();
      _generation++;
      _running = false;
      _scroll.jumpTo(0);
    }
    _queueRestart();
  }

  void _queueRestart() {
    _pause?.cancel();
    _generation++;
    _cycles = 0;
    _running = false;
    if (_restartQueued) return;
    _restartQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restartQueued = false;
      if (!mounted || !_scroll.hasClients) return;
      // Also cancels an in-flight animation after a track/width change.
      _scroll.jumpTo(0);
      final content = _contentKey.currentContext?.findRenderObject();
      if (content is! RenderBox || !content.hasSize) return;
      final overflowing =
          content.size.width > _scroll.position.viewportDimension + 0.5;
      _loopDistance = content.size.width + _gap;
      if (_looping != overflowing) {
        setState(() => _looping = overflowing);
        _queueRestart();
        return;
      }
      if (_motionEnabled && _appActive && _looping) {
        _scheduleCycle(_generation);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _canScroll(int generation) =>
      mounted &&
      generation == _generation &&
      _motionEnabled &&
      _appActive &&
      _scroll.hasClients;

  void _scheduleCycle(int generation) {
    if (widget.continuous && _cycles > 0) {
      unawaited(_scrollCycle(generation));
      return;
    }
    _pause = Timer(widget.pause, () => _scrollCycle(generation));
  }

  Future<void> _scrollCycle(int generation) async {
    if (!_canScroll(generation)) return;
    _running = true;
    await _scroll.animateTo(
      _loopDistance,
      duration: Duration(milliseconds: (_loopDistance / widget.speed * 1000).round()),
      curve: Curves.linear,
    );
    if (_canScroll(generation)) {
      // The next copy is now exactly where the first started, so resetting
      // the offset changes neither the visible text nor its direction.
      _running = false;
      _scroll.jumpTo(0);
      _cycles++;
      final maxCycles = widget.maxCycles;
      if (maxCycles != null && _cycles >= maxCycles) return;
      if (widget.continuous) {
        unawaited(_scrollCycle(generation));
      } else {
        _scheduleCycle(generation);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pause?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_motionEnabled) return widget.child;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        final metrics = notification.metrics;
        if (_viewport != metrics.viewportDimension ||
            _extent != metrics.maxScrollExtent) {
          _viewport = metrics.viewportDimension;
          _extent = metrics.maxScrollExtent;
          _queueRestart();
        }
        return false;
      },
      child: _EdgeFade(
        enabled: _looping,
        leading: widget.fadeBothEdges ? _scroll : null,
        child: SingleChildScrollView(
          controller: _scroll,
          scrollDirection: Axis.horizontal,
          physics: const NeverScrollableScrollPhysics(),
          // The viewport repaints as it scrolls; retain the unchanged content.
          child: RepaintBoundary(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                KeyedSubtree(key: _contentKey, child: widget.child),
                if (_looping) ...[
                  SizedBox(width: _gap),
                  ExcludeSemantics(child: IgnorePointer(child: widget.child)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MarqueeController extends ScrollController {
  _MarqueeController(this.running);

  final bool Function() running;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _MarqueePosition(
      physics: physics,
      context: context,
      oldPosition: oldPosition,
      running: running,
    );
  }
}

class _MarqueePosition extends ScrollPositionWithSingleContext {
  _MarqueePosition({
    required super.physics,
    required super.context,
    super.oldPosition,
    required this.running,
  });

  final bool Function() running;

  @override
  bool applyContentDimensions(double minScrollExtent, double maxScrollExtent) {
    if (!running() && hasPixels && pixels != 0) correctPixels(0);
    return super.applyContentDimensions(minScrollExtent, maxScrollExtent);
  }
}

class _EdgeFade extends StatelessWidget {
  const _EdgeFade({required this.enabled, required this.child, this.leading});

  final bool enabled;
  final Widget child;
  final ScrollController? leading;

  static const _width = 20.0;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    final rtl = Directionality.of(context) == TextDirection.rtl;
    Widget mask(double lead) => ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (bounds) {
        if (bounds.width <= _width * 2) {
          return LinearGradient(
            begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
            end: rtl ? Alignment.centerLeft : Alignment.centerRight,
            colors: const [Colors.white, Color(0x00FFFFFF)],
          ).createShader(bounds);
        }
        final edge = _width / bounds.width;
        return LinearGradient(
          begin: rtl ? Alignment.centerRight : Alignment.centerLeft,
          end: rtl ? Alignment.centerLeft : Alignment.centerRight,
          colors: [
            Colors.white.withValues(alpha: 1 - lead),
            Colors.white,
            Colors.white,
            const Color(0x00FFFFFF),
          ],
          stops: [0, edge, 1 - edge, 1],
        ).createShader(bounds);
      },
      child: child,
    );
    final controller = leading;
    if (controller == null) return mask(0);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => mask(
        controller.hasClients
            ? (controller.offset / _width).clamp(0.0, 1.0)
            : 0,
      ),
    );
  }
}
