import 'package:flutter/material.dart';
import 'package:mornye/services/app_orientation.dart';
import 'package:mornye/theme/mornye_theme.dart';

/// Hero tag shared by the mini player artwork and the full player artwork so
/// the cover visually expands when the player opens.
const kNowPlayingArtworkHeroTag = 'now-playing-artwork';

/// Slide-up route for the full player. Supports live drag-to-dismiss: the
/// page follows the finger (via [startDrag]/[updateDrag]/[endDrag]) and
/// settles open or pops based on release position and velocity.
class NowPlayingRoute extends PageRoute<void> {
  NowPlayingRoute({required this.child, this.miniPlayerGeometry})
    : super(
        fullscreenDialog: true,
        settings: const RouteSettings(name: fullPlayerRouteName),
      );

  final Widget child;

  /// Read at dismissal so rotation and collapsing navigation cannot leave a
  /// stale destination from when the player was opened.
  final ({Rect surface, Rect artwork})? Function()? miniPlayerGeometry;
  ({Rect bounds, Widget child, bool fullBleed})? Function()? readArtwork;

  /// How much of the mini player shows while the sheet is being minimized:
  /// 0 while the sheet still covers it, 1 once the cover has landed on it.
  static final ValueNotifier<double> miniReveal = ValueNotifier(1);

  /// Sheet opacity is solid down to this expansion value, then fades to
  /// nothing at the bottom.
  static const double sheetSolidUntil = 0.85;
  static const double _coverLag = 0.12;
  static const Curve _coverSettle = Cubic(0.45, 0.0, 0.3, 1.5);

  /// Cover position, 0 at its place in the sheet and 1 on the mini player,
  /// for a minimize progress of [p]. The cover trails the sheet and settles
  /// with a small overshoot; without animations it follows linearly.
  static double coverProgress(double p, {required bool reduceMotion}) {
    final clamped = p.clamp(0.0, 1.0);
    if (reduceMotion) return clamped;
    final u = ((clamped - _coverLag) / (1 - _coverLag)).clamp(0.0, 1.0);
    return _coverSettle.transform(u);
  }

  ({Rect bounds, Widget child, bool fullBleed})? _flightCover;
  ({Rect surface, Rect artwork})? _flightTarget;
  Size? _flightSize;
  double _flightStart = 1;

  bool get hasDismissArtwork => _dismissArtwork != null || _flightCover != null;

  double _flightProgress(double value) =>
      _flightStart <= 0 ? 1 : (1 - value / _flightStart).clamp(0.0, 1.0);

  bool get _reduceMotion {
    final context = subtreeContext;
    return context != null && MediaQuery.disableAnimationsOf(context);
  }

  ({Rect surface, Rect artwork})? _dismissTarget;
  ({Rect bounds, Widget child, bool fullBleed})? _dismissArtwork;
  Rect? _dismissStart;
  double _dismissStartValue = 1;

  bool _interactiveTransition = false;
  int _dragGeneration = 0;

  // The player paints an opaque surface over the whole screen, including the
  // status bar and bottom safe area. Once settled, the framework therefore
  // keeps the pages below offstage: their glass, marquees and tickers stop
  // compositing. Every drag or dismissal moves the animation off `completed`,
  // which makes this route translucent again before the page is exposed.
  @override
  bool get opaque => true;

  /// Overlay size when the pages below were last laid out, recorded while this
  /// route hides them. A rotation while hidden leaves their geometry stale.
  Size? _coveredOverlaySize;

  Size? get _overlaySize {
    final box = navigator?.overlay?.context.findRenderObject();
    return box is RenderBox && box.hasSize ? box.size : null;
  }

  @override
  void install() {
    // The player ends editing. Clear the saved search focus too, so closing
    // the route cannot reopen the IME and shrink Home behind the bottom bar.
    final focus = FocusManager.instance.primaryFocus;
    if (focus?.context?.findAncestorStateOfType<EditableTextState>() != null) {
      focus?.unfocus();
    }
    super.install();
    animation!.addStatusListener((status) {
      _coveredOverlaySize = status.isCompleted ? _overlaySize : null;
    });
    animation!.addListener(_syncMiniReveal);
  }

  void _syncMiniReveal() {
    final flying = _flightCover != null && _flightTarget != null;
    final next = flying
        ? const Interval(
            0.35,
            1.0,
            curve: Curves.easeIn,
          ).transform(_flightProgress(animation!.value))
        : 1.0;
    if (miniReveal.value != next) miniReveal.value = next;
  }

  void _captureFlight() {
    if (_flightCover != null || !isCurrent) return;
    final context = subtreeContext;
    if (context == null || !context.isMornye) return;
    final coveredSize = _coveredOverlaySize;
    if (coveredSize != null && coveredSize != _overlaySize) return;
    final target = miniPlayerGeometry?.call();
    final cover = readArtwork?.call();
    final value = controller?.value ?? 1.0;
    if (target == null ||
        target.surface.isEmpty ||
        target.artwork.isEmpty ||
        cover == null ||
        value <= 0) {
      return;
    }
    final size = MediaQuery.sizeOf(context);
    final slide = _interactiveTransition
        ? value
        : Easing.emphasizedDecelerate.transform(value);
    _flightCover = (
      bounds: cover.bounds.shift(Offset(0, -(1 - slide) * size.height)),
      child: cover.child,
      fullBleed: cover.fullBleed,
    );
    _flightTarget = target;
    _flightSize = size;
    _flightStart = slide;
  }

  void _clearFlight() {
    _flightCover = null;
    _flightTarget = null;
    _flightSize = null;
    _flightStart = 1;
    miniReveal.value = 1;
  }

  @override
  void dispose() {
    animation?.removeListener(_syncMiniReveal);
    miniReveal.value = 1;
    super.dispose();
  }

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 400);

  @override
  Duration get reverseTransitionDuration => const Duration(milliseconds: 300);

  void startDrag() {
    _dragGeneration++;
    _captureFlight();
    controller?.stop();
    if (!_interactiveTransition && controller != null) {
      controller!.value = Easing.emphasizedDecelerate.transform(
        controller!.value,
      );
    }
    _interactiveTransition = true;
    changedInternalState();
  }

  void updateDrag(DragUpdateDetails details, double pageHeight) {
    controller?.value -= (details.primaryDelta ?? 0) / pageHeight;
  }

  void endDrag(DragEndDetails details, double pageHeight) {
    final velocity = (details.primaryVelocity ?? 0) / pageHeight;
    final value = controller?.value ?? 1.0;
    if (velocity > 1.0 || (velocity >= 0 && value < 0.7)) {
      final flying = _flightCover != null && _flightTarget != null;
      navigator?.pop();
      if (flying) {
        final reduce = _reduceMotion;
        controller?.animateBack(
          0,
          duration: reduce
              ? const Duration(milliseconds: 160)
              : Duration(
                  milliseconds: 280 + (140 * value.clamp(0.0, 1.0)).round(),
                ),
          curve: reduce ? Curves.linear : Curves.easeOutCubic,
        );
      }
    } else {
      _settleOpen();
    }
  }

  void cancelDrag() {
    _settleOpen();
  }

  void _settleOpen() {
    final generation = _dragGeneration;
    // Keep the same linear position mapping until settling finishes. Switching
    // to the entrance curve on release jumps away from the finger's position.
    controller
        ?.animateTo(
          1,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        )
        .whenCompleteOrCancel(() {
          if (generation != _dragGeneration) return;
          _interactiveTransition = false;
          _clearFlight();
          if (isCurrent) changedInternalState();
        });
  }

  @override
  bool didPop(void result) {
    final context = subtreeContext;
    if (context != null &&
        _flightCover == null &&
        context.isMornye &&
        !MediaQuery.disableAnimationsOf(context) &&
        (controller?.value ?? 0) > 0) {
      final coveredSize = _coveredOverlaySize;
      final target = coveredSize == null || coveredSize == _overlaySize
          ? miniPlayerGeometry?.call()
          : null;
      if (target != null && !target.surface.isEmpty) {
        final size = MediaQuery.sizeOf(context);
        _dismissStartValue = controller!.value;
        final position = _interactiveTransition
            ? _dismissStartValue
            : Easing.emphasizedDecelerate.transform(_dismissStartValue);
        _dismissStart = Rect.fromLTWH(
          0,
          size.height * (1 - position),
          size.width,
          size.height,
        );
        _dismissTarget = target;
        _dismissArtwork = readArtwork?.call();
      }
    }
    return super.didPop(result);
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _RouteDragRegion(route: this, child: child);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final target = _dismissTarget;
    // Restoring portrait can resize the window during dismissal. Geometry
    // captured in landscape no longer points at the mini player in that case.
    if (target != null && _dismissStart?.size == MediaQuery.sizeOf(context)) {
      final progress = Curves.easeInOutCubic.transform(
        (1 - animation.value / _dismissStartValue).clamp(0.0, 1.0),
      );
      final bounds = Rect.lerp(_dismissStart, target.surface, progress)!;
      final size = MediaQuery.sizeOf(context);
      final cover = _dismissArtwork;
      return Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fromRect(
            rect: bounds,
            child: ClipRRect(
              key: const ValueKey('player-minimize-surface'),
              borderRadius: BorderRadius.circular(28 * progress),
              child: OverflowBox(
                alignment: Alignment.topLeft,
                minWidth: size.width,
                maxWidth: size.width,
                minHeight: size.height,
                maxHeight: size.height,
                child: Transform.scale(
                  scale: bounds.width / size.width,
                  alignment: Alignment.topLeft,
                  child: Opacity(
                    opacity: 1 - const Interval(0.15, 0.85).transform(progress),
                    child: child,
                  ),
                ),
              ),
            ),
          ),
          if (cover != null)
            Positioned.fromRect(
              rect: Rect.lerp(cover.bounds, target.artwork, progress)!,
              child: ClipRRect(
                key: const ValueKey('player-minimize-artwork'),
                borderRadius: BorderRadius.circular(
                  cover.fullBleed ? 6 * progress : 12 - 6 * progress,
                ),
                child: cover.fullBleed
                    ? ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.58, 1],
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.white.withValues(alpha: progress),
                          ],
                        ).createShader(bounds),
                        child: cover.child,
                      )
                    : cover.child,
              ),
            ),
        ],
      );
    }
    final reversing = animation.status == AnimationStatus.reverse;
    // Mornye's full-bleed artwork travels with its panel. Material keeps the
    // independent cover flight back to the mini-player on button/back pop.
    final inPlacePop =
        reversing && !_interactiveTransition && !context.isMornye;
    final slide = _interactiveTransition
        ? animation
        : animation.drive(CurveTween(curve: Easing.emphasizedDecelerate));
    final position = inPlacePop
        ? const AlwaysStoppedAnimation(Offset.zero)
        : slide.drive(Tween(begin: const Offset(0, 1), end: Offset.zero));
    final flightTarget = _flightTarget;
    final flightCover = _flightCover;
    final flying =
        flightTarget != null &&
        flightCover != null &&
        _flightSize == MediaQuery.sizeOf(context);
    final solid = MediaQuery.highContrastOf(context);
    final Animation<double> opacity = inPlacePop
        ? animation
        : solid || !(flying || _interactiveTransition)
        ? kAlwaysCompleteAnimation
        : animation.drive(
            CurveTween(curve: const Interval(0, sheetSolidUntil)),
          );
    return Stack(
      fit: StackFit.expand,
      children: [
        SlideTransition(
          position: position,
          child: FadeTransition(opacity: opacity, child: child),
        ),
        if (flying)
          _FlyingCover(
            animation: animation,
            cover: flightCover,
            target: flightTarget.artwork,
            start: _flightStart,
            reduceMotion: MediaQuery.disableAnimationsOf(context),
          )
        else
          const SizedBox.shrink(),
      ],
    );
  }
}

/// The cover of the minimizing sheet: one widget moved and scaled with a
/// transform from its place in the sheet to the mini player's thumbnail.
class _FlyingCover extends StatelessWidget {
  const _FlyingCover({
    required this.animation,
    required this.cover,
    required this.target,
    required this.start,
    required this.reduceMotion,
  });

  final Animation<double> animation;
  final ({Rect bounds, Widget child, bool fullBleed}) cover;
  final Rect target;
  final double start;
  final bool reduceMotion;

  @override
  Widget build(BuildContext context) {
    final rest = cover.bounds;
    final square =
        (rest.width - rest.height).abs() < 1 &&
        (target.width - target.height).abs() < 1;
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: animation,
        child: RepaintBoundary(child: cover.child),
        builder: (context, art) {
          final p = start <= 0
              ? 1.0
              : (1 - animation.value / start).clamp(0.0, 1.0);
          final q = NowPlayingRoute.coverProgress(
            p,
            reduceMotion: reduceMotion,
          );
          final settled = q.clamp(0.0, 1.0);
          final radius = cover.fullBleed ? 6 * settled : 12 - 6 * settled;
          final rect = Rect.lerp(rest, target, q)!;
          final Widget flying;
          if (square) {
            final scale = rect.width / rest.width;
            flying = Positioned(
              left: rest.left,
              top: rest.top,
              width: rest.width,
              height: rest.height,
              child: Transform(
                transform: Matrix4.identity()
                  ..translateByDouble(
                    rect.left - rest.left,
                    rect.top - rest.top,
                    0,
                    1,
                  )
                  ..scaleByDouble(scale, scale, 1, 1),
                child: ClipRRect(
                  key: const ValueKey('player-minimize-artwork'),
                  borderRadius: BorderRadius.circular(
                    scale <= 0 ? 0 : radius / scale,
                  ),
                  child: art,
                ),
              ),
            );
          } else {
            flying = Positioned.fromRect(
              rect: rect,
              child: ClipRRect(
                key: const ValueKey('player-minimize-artwork'),
                borderRadius: BorderRadius.circular(radius),
                child: cover.fullBleed
                    ? ShaderMask(
                        blendMode: BlendMode.dstIn,
                        shaderCallback: (bounds) => LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          stops: const [0, 0.58, 1],
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.white.withValues(alpha: settled),
                          ],
                        ).createShader(bounds),
                        child: art,
                      )
                    : art,
              ),
            );
          }
          return Opacity(
            opacity: 1 - const Interval(0.9, 1.0).transform(p),
            child: Stack(fit: StackFit.expand, children: [flying]),
          );
        },
      ),
    );
  }
}

/// Routes vertical drags to [NowPlayingRoute]. Scrollables inside [child]
/// still win the gesture arena, so this only fires on non-scrolling regions
/// (app bar, artwork, tab bar).
class _RouteDragRegion extends StatelessWidget {
  final NowPlayingRoute route;
  final Widget child;

  const _RouteDragRegion({required this.route, required this.child});

  @override
  Widget build(BuildContext context) {
    final pageHeight = MediaQuery.sizeOf(context).height;
    return GestureDetector(
      onVerticalDragStart: (_) => route.startDrag(),
      onVerticalDragUpdate: (details) => route.updateDrag(details, pageHeight),
      onVerticalDragEnd: (details) => route.endDrag(details, pageHeight),
      onVerticalDragCancel: route.cancelDrag,
      child: child,
    );
  }
}
