import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';

import '../l10n/app_localizations.dart';
import '../services/gyroscope_tilt_source.dart';
import 'collectible_reflection.dart';
import 'cover_image_frame.dart';
import 'settled_blur.dart';

export 'collectible_reflection.dart';

abstract class TiltSource {
  Stream<Offset> get changes;
}

class ManualTiltSource implements TiltSource {
  final StreamController<Offset> _controller =
      StreamController<Offset>.broadcast();

  bool get hasListener => _controller.hasListener;

  void push(Offset value) => _controller.add(value);

  Future<void> close() => _controller.close();

  @override
  Stream<Offset> get changes => _controller.stream;
}

const double collectibleDismissDistance = 110;
const double collectibleDismissVelocity = 900;
const double collectibleDismissVerticalRatio = 1.4;
const double _dismissSpan = 220;
const double _dragFollow = 0.9;
const Duration _hintDuration = Duration(milliseconds: 2500);
const Duration _reducedFade = Duration(milliseconds: 120);
const Duration _centerFade = Duration(milliseconds: 260);

final SpringDescription _flightSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 380,
  ratio: 0.82,
);
const Tolerance _flightTolerance = Tolerance(distance: 0.003, velocity: 0.05);

@visibleForTesting
bool collectibleHintShown = false;

@visibleForTesting
TiltSource? Function() defaultTiltSourceFactory = () =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android
    ? GyroscopeTiltSource()
    : null;

Future<void> showCollectibleCover(
  BuildContext context, {
  required ImageProvider imageProvider,
  Object? heroTag,
  String? title,
  TiltSource? tiltSource,
  Rect? Function()? originRect,
  double originRadius = 0,
}) {
  final source = tiltSource ?? defaultTiltSourceFactory();
  final opened = originRect?.call();
  return Navigator.of(context, rootNavigator: true).push<void>(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 320),
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (context, animation, secondaryAnimation) =>
          CollectibleCoverViewer(
            imageProvider: imageProvider,
            heroTag: heroTag,
            title: title,
            tiltSource: source,
            animation: animation,
            origin: opened,
            readOrigin: originRect,
            originRadius: originRadius,
          ),
      transitionsBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class CollectibleCoverViewer extends StatefulWidget {
  const CollectibleCoverViewer({
    super.key,
    required this.imageProvider,
    this.heroTag,
    this.title,
    this.tiltSource,
    this.animation,
    this.origin,
    this.readOrigin,
    this.originRadius = 0,
  });

  final ImageProvider imageProvider;
  final Object? heroTag;
  final String? title;
  final TiltSource? tiltSource;
  final Animation<double>? animation;
  final Rect? origin;
  final Rect? Function()? readOrigin;
  final double originRadius;

  @override
  State<CollectibleCoverViewer> createState() => _CollectibleCoverViewerState();
}

enum _Phase { idle, back, fly, fade }

class _Pose {
  const _Pose({
    this.offset = Offset.zero,
    this.scale = 1,
    this.radius = 0,
    this.backdrop = 1,
    this.card = 1,
    this.title = 1,
  });

  final Offset offset;
  final double scale;
  final double radius;
  final double backdrop;
  final double card;
  final double title;
}

class _CollectibleCoverViewerState extends State<CollectibleCoverViewer>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  final ValueNotifier<Offset> _angle = ValueNotifier(Offset.zero);
  final ValueNotifier<Offset> _drag = ValueNotifier(Offset.zero);
  final GlobalKey _slotKey = GlobalKey(debugLabel: 'collectible-slot');
  late final AnimationController _ctl = AnimationController.unbounded(
    vsync: this,
  );
  late final Ticker _ticker = createTicker(_onTick);
  StreamSubscription<Offset>? _subscription;
  Timer? _hintTimer;
  Offset _sourceTarget = Offset.zero;
  Offset _dragTarget = Offset.zero;
  Duration _last = Duration.zero;
  bool _reduced = false;
  bool _resumed = true;
  bool _closing = false;
  bool _allowPop = false;
  bool _hint = false;
  Offset _dragStart = Offset.zero;
  double _cardSide = 280;
  _Phase _phase = _Phase.idle;
  Offset _releaseDrag = Offset.zero;
  Rect _slot = Rect.zero;
  Rect _flyTo = Rect.zero;
  double _flyToRadius = 0;
  double _flyToScale = 1;
  _Pose _flyFrom = const _Pose();
  bool _fadeScale = false;

  Offset get _target => _clampAngle(_sourceTarget + _dragTarget);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (!collectibleHintShown) {
      collectibleHintShown = true;
      _hint = true;
      _hintTimer = Timer(_hintDuration, () {
        _hintTimer = null;
        if (mounted) setState(() => _hint = false);
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced != _reduced || _subscription == null && !reduced) {
      _reduced = reduced;
      _syncSubscription();
    }
  }

  @override
  void didUpdateWidget(CollectibleCoverViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tiltSource != widget.tiltSource) _syncSubscription();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final resumed = state == AppLifecycleState.resumed;
    if (resumed == _resumed) return;
    _resumed = resumed;
    _syncSubscription();
  }

  void _syncSubscription() {
    final shouldListen =
        widget.tiltSource != null && !_reduced && _resumed && !_closing;
    if (!shouldListen) {
      _subscription?.cancel();
      _subscription = null;
      _sourceTarget = Offset.zero;
      if (_reduced) {
        _dragTarget = Offset.zero;
        _angle.value = Offset.zero;
        _ticker.stop();
      } else {
        _kick();
      }
      return;
    }
    if (_subscription != null) return;
    _subscription = widget.tiltSource!.changes.listen((value) {
      final next = Offset(
        value.dx.clamp(-1.0, 1.0) * collectibleMaxTiltDegrees,
        value.dy.clamp(-1.0, 1.0) * collectibleMaxTiltDegrees,
      );
      final held = collectibleDeadzoned(_sourceTarget, next);
      if (held == _sourceTarget) return;
      _sourceTarget = held;
      _kick();
    });
  }

  Offset _clampAngle(Offset value) => Offset(
    value.dx.clamp(-collectibleMaxTiltDegrees, collectibleMaxTiltDegrees),
    value.dy.clamp(-collectibleMaxTiltDegrees, collectibleMaxTiltDegrees),
  );

  void _kick() {
    if (_reduced) return;
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 1 / 60
        : (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final target = _target;
    final next = collectibleFollow(_angle.value, target, dt);
    if ((target - next).distance < 0.02) {
      _angle.value = target;
      _ticker.stop();
      return;
    }
    _angle.value = next;
  }

  void _hideHint() {
    _hintTimer?.cancel();
    _hintTimer = null;
    if (_hint) setState(() => _hint = false);
  }

  void _onPanStart(DragStartDetails details) {
    if (_closing) return;
    _ctl.stop();
    _phase = _Phase.idle;
    _dragStart = details.globalPosition;
    _hideHint();
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (_closing) return;
    final delta = details.globalPosition - _dragStart;
    if (!_reduced) {
      final half = _cardSide / 2;
      _dragTarget = Offset(
        delta.dx / half * collectibleMaxTiltDegrees,
        delta.dy / half * collectibleMaxTiltDegrees,
      );
      _kick();
    }
    _drag.value = delta;
  }

  void _onPanEnd(DragEndDetails details) => _release(details.velocity);

  void _onPanCancel() => _release(Velocity.zero);

  void _release(Velocity velocity) {
    if (_closing) return;
    final drag = _drag.value;
    final fling = velocity.pixelsPerSecond;
    final up = -drag.dy;
    final byDistance =
        up > collectibleDismissDistance &&
        up > collectibleDismissVerticalRatio * drag.dx.abs();
    final byFling =
        fling.dy < -collectibleDismissVelocity &&
        fling.dy.abs() > collectibleDismissVerticalRatio * fling.dx.abs();
    _dragTarget = Offset.zero;
    if (byDistance || byFling) {
      _close(velocity: fling);
      return;
    }
    _kick();
    if (_reduced || drag == Offset.zero) {
      _drag.value = Offset.zero;
      return;
    }
    _releaseDrag = drag;
    _drag.value = Offset.zero;
    _phase = _Phase.back;
    _ctl.value = 0;
    _ctl
        .animateWith(
          SpringSimulation(_flightSpring, 0, 1, 0, tolerance: _flightTolerance),
        )
        .whenComplete(() {
          if (_phase == _Phase.back) {
            _phase = _Phase.idle;
            _releaseDrag = Offset.zero;
            _ctl.value = 0;
          }
        });
  }

  Rect? _validOrigin(Rect? rect) {
    if (rect == null ||
        !rect.isFinite ||
        rect.isEmpty ||
        rect.width < 8 ||
        rect.height < 8) {
      return null;
    }
    final ratio = rect.width / rect.height;
    if (ratio < 0.85 || ratio > 1.18) return null;
    return rect;
  }

  Rect? _readSlot() {
    final box = _slotKey.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  _Pose _dragPose(Offset drag) {
    final up = math.max(0.0, -drag.dy);
    final p = (up / _dismissSpan).clamp(0.0, 1.0);
    return _Pose(
      offset: Offset(0, -up * _dragFollow),
      scale: 1 - 0.1 * p,
      radius: _cardSide * 0.06,
      backdrop: 1 - 0.6 * p,
      title: 1 - p,
    );
  }

  _Pose _pose() {
    switch (_phase) {
      case _Phase.idle:
        return _dragPose(_drag.value);
      case _Phase.back:
        return _dragPose(_releaseDrag * (1 - _ctl.value));
      case _Phase.fly:
        final v = _ctl.value;
        final from = _flyFrom;
        final scale = ui.lerpDouble(from.scale, _flyToScale, v)!;
        final centre = Offset.lerp(
          _slot.center + from.offset,
          _flyTo.center,
          v,
        )!;
        final visible = math.max(
          0.0,
          ui.lerpDouble(from.radius * from.scale, _flyToRadius, v)!,
        );
        final fade = v.clamp(0.0, 1.0);
        return _Pose(
          offset: centre - _slot.center,
          scale: scale,
          radius: visible / math.max(scale, 0.01),
          backdrop: from.backdrop * (1 - fade),
          title: from.title * (1 - math.min(1.0, fade * 3)),
        );
      case _Phase.fade:
        final v = _ctl.value.clamp(0.0, 1.0);
        final from = _flyFrom;
        return _Pose(
          offset: from.offset,
          scale: _fadeScale ? from.scale * (1 - 0.15 * v) : from.scale,
          radius: from.radius,
          backdrop: from.backdrop * (1 - v),
          card: 1 - v,
          title: from.title * (1 - v),
        );
    }
  }

  Future<void> _close({Offset velocity = Offset.zero}) async {
    if (_closing) return;
    _closing = true;
    _hideHint();
    _subscription?.cancel();
    _subscription = null;
    _sourceTarget = Offset.zero;
    _dragTarget = Offset.zero;
    _kick();
    final slot = _readSlot();
    final from = _pose();
    _ctl.stop();
    Rect? target;
    if (!_reduced && slot != null) {
      target =
          _validOrigin(widget.readOrigin?.call()) ??
          _validOrigin(widget.origin);
    }
    _slot = slot ?? Rect.zero;
    _flyFrom = from;
    _releaseDrag = Offset.zero;
    if (target != null) {
      final to = target;
      _flyTo = to;
      _flyToScale = to.width / _cardSide;
      _flyToRadius = widget.originRadius;
      _phase = _Phase.fly;
      _drag.value = Offset.zero;
      _ctl.value = 0;
      final distance = (to.center - (slot!.center + from.offset)).distance;
      var initial = 0.0;
      if (distance > 1 && velocity != Offset.zero) {
        final direction = (to.center - (slot.center + from.offset)) / distance;
        initial =
            ((velocity.dx * direction.dx + velocity.dy * direction.dy) /
                    distance)
                .clamp(0.0, 14.0);
      }
      await _ctl.animateWith(
        SpringSimulation(
          _flightSpring,
          0,
          1,
          initial,
          tolerance: _flightTolerance,
        ),
      );
      if (!mounted) return;
      _ctl.value = 1;
    } else {
      _fadeScale = !_reduced;
      _phase = _Phase.fade;
      _drag.value = Offset.zero;
      _ctl.value = 0;
      await _ctl.animateTo(
        1,
        duration: _reduced ? _reducedFade : _centerFade,
        curve: _reduced ? Curves.linear : Curves.easeOutCubic,
      );
      if (!mounted) return;
    }
    setState(() => _allowPop = true);
    final route = ModalRoute.of(context);
    final done = Completer<void>();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await Navigator.of(context).maybePop();
      done.complete();
    });
    await done.future;
    if (!mounted || route == null || !route.isActive) return;
    _closing = false;
    _allowPop = false;
    _phase = _Phase.idle;
    _ctl.value = 0;
    _drag.value = Offset.zero;
    setState(() {});
    _syncSubscription();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hintTimer?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _ticker.dispose();
    _ctl.dispose();
    _angle.dispose();
    _drag.dispose();
    super.dispose();
  }

  Widget _hintWidget(BuildContext context) {
    final l10n = Localizations.of<AppLocalizations>(context, AppLocalizations);
    final text = l10n?.collectibleCoverSwipeHint ?? 'Swipe up to exit';
    return SafeArea(
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.only(bottom: 28),
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: AnimatedOpacity(
                key: const ValueKey('collectible-hint'),
                opacity: _hint ? 1 : 0,
                duration: _reduced
                    ? Duration.zero
                    : const Duration(milliseconds: 300),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.keyboard_arrow_up_rounded,
                      color: Color(0xB3FFFFFF),
                      size: 28,
                    ),
                    Text(
                      text,
                      style: const TextStyle(
                        color: Color(0xB3FFFFFF),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    _cardSide = math
        .min(size.width - 56, size.height * 0.56)
        .clamp(180.0, 460.0);
    final side = _cardSide;
    final animation = widget.animation;
    Widget card = RepaintBoundary(
      child: ListenableBuilder(
        listenable: Listenable.merge([_drag, _ctl]),
        builder: (context, _) => _CollectibleCard(
          image: widget.imageProvider,
          side: side,
          angle: _angle,
          reduced: _reduced,
          radius: _pose().radius,
        ),
      ),
    );
    if (widget.heroTag != null) {
      card = HeroMode(
        enabled: !_closing,
        child: Hero(
          tag: widget.heroTag!,
          flightShuttleBuilder: (_, _, _, _, toContext) => SizedBox.square(
            dimension: side,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(side * 0.06),
              child: CoverImageFrame(image: widget.imageProvider),
            ),
          ),
          child: card,
        ),
      );
    }
    if (animation != null && !_reduced) {
      card = ScaleTransition(
        scale: Tween<double>(begin: 0.9, end: 1).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: card,
      );
    }
    final movingCard = SizedBox.square(
      key: _slotKey,
      dimension: side,
      child: ListenableBuilder(
        listenable: Listenable.merge([_drag, _ctl]),
        child: card,
        builder: (context, child) {
          final pose = _pose();
          return Opacity(
            opacity: pose.card.clamp(0.0, 1.0),
            child: Transform(
              transform: Matrix4.identity()
                ..translateByDouble(pose.offset.dx, pose.offset.dy, 0, 1)
                ..scaleByDouble(pose.scale, pose.scale, 1, 1),
              alignment: Alignment.center,
              child: child,
            ),
          );
        },
      ),
    );
    final content = Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          movingCard,
          if (widget.title != null && widget.title!.isNotEmpty)
            ListenableBuilder(
              listenable: Listenable.merge([_drag, _ctl]),
              builder: (context, child) {
                final pose = _pose();
                return Opacity(
                  opacity: pose.title.clamp(0.0, 1.0),
                  child: Transform.translate(
                    offset: Offset(0, pose.offset.dy * 0.5),
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.only(top: 24),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: side),
                  child: Text(
                    widget.title!,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xEBFFFFFF),
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
    return PopScope(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _close();
      },
      child: Scaffold(
        key: const ValueKey('collectible-viewer'),
        backgroundColor: Colors.transparent,
        body: Stack(
          fit: StackFit.expand,
          children: [
            ListenableBuilder(
              listenable: Listenable.merge([_drag, _ctl]),
              builder: (context, child) => Opacity(
                opacity: _pose().backdrop.clamp(0.0, 1.0),
                child: child,
              ),
              child: _GlassBackdrop(
                image: widget.imageProvider,
                solid: MediaQuery.highContrastOf(context),
              ),
            ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _onPanStart,
              onPanUpdate: _onPanUpdate,
              onPanEnd: _onPanEnd,
              onPanCancel: _onPanCancel,
              child: content,
            ),
            _hintWidget(context),
            SafeArea(
              child: Align(
                alignment: AlignmentDirectional.topStart,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_drag, _ctl]),
                    builder: (context, child) => Opacity(
                      opacity: _pose().title.clamp(0.0, 1.0),
                      child: child,
                    ),
                    child: IconButton(
                      key: const ValueKey('collectible-close'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: _close,
                      icon: const Icon(Icons.close_rounded),
                      color: Colors.white,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CollectibleCard extends StatelessWidget {
  const _CollectibleCard({
    required this.image,
    required this.side,
    required this.angle,
    required this.reduced,
    required this.radius,
  });

  final ImageProvider image;
  final double side;
  final ValueNotifier<Offset> angle;
  final bool reduced;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(this.radius);
    final decodeSide = (side * MediaQuery.devicePixelRatioOf(context))
        .round()
        .clamp(64, 2048);
    final picture = RepaintBoundary(
      child: ClipRRect(
        borderRadius: radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(
              color: Color(0xFF14141C),
              child: Center(
                child: Icon(
                  Icons.album_rounded,
                  color: Colors.white24,
                  size: 56,
                ),
              ),
            ),
            CoverImageFrame(
              image: ResizeImage.resizeIfNeeded(decodeSide, null, image),
              frameBuilder: (context, child, frame, synchronous) {
                if (synchronous || reduced) return child;
                return AnimatedOpacity(
                  opacity: frame == null ? 0 : 1,
                  duration: const Duration(milliseconds: 220),
                  child: child,
                );
              },
            ),
          ],
        ),
      ),
    );
    if (reduced) {
      return SizedBox.square(
        dimension: side,
        child: Stack(
          fit: StackFit.expand,
          children: [
            picture,
            IgnorePointer(
              child: CustomPaint(painter: _SheenPainter(radius: radius)),
            ),
          ],
        ),
      );
    }
    final shadow = RepaintBoundary(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 34,
              offset: const Offset(0, 20),
            ),
          ],
        ),
      ),
    );
    final sheen = RepaintBoundary(
      child: IgnorePointer(
        child: CustomPaint(
          painter: _SheenPainter(radius: radius, angle: angle),
        ),
      ),
    );
    final face = Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned.fill(child: picture),
        Positioned.fill(child: sheen),
      ],
    );
    return ValueListenableBuilder<Offset>(
      valueListenable: angle,
      child: face,
      builder: (context, tilt, face) {
        final rx = tilt.dy * math.pi / 180;
        final ry = tilt.dx * math.pi / 180;
        final unit = Offset(
          tilt.dx / collectibleMaxTiltDegrees,
          tilt.dy / collectibleMaxTiltDegrees,
        );
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.0012)
          ..rotateX(-rx)
          ..rotateY(ry);
        return Transform(
          key: const ValueKey('collectible-tilt'),
          alignment: Alignment.center,
          transform: matrix,
          child: SizedBox.square(
            dimension: side,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: Transform.translate(
                    offset: Offset(2 - unit.dx * 19, 3 - unit.dy * 15),
                    child: shadow,
                  ),
                ),
                Positioned.fill(child: face!),
              ],
            ),
          ),
        );
      },
    );
  }
}

const double collectibleGrainAlpha = 0.028;
const double collectibleBackdropSigma = 45;
const double collectibleBackdropDarkness = 0.8;

const int _profileSteps = 8;
const Color _coolTint = Color(0xFF7FB0FF);
const Color _warmTint = Color(0xFFFFB98A);

final Map<int, List<Color>> _profileCache = <int, List<Color>>{};
final Map<int, List<Color>> _tintCache = <int, List<Color>>{};
final List<double> _profileStops = List<double>.unmodifiable([
  for (var i = 0; i <= _profileSteps; i++) i / _profileSteps,
]);

List<Color> _profile(Color base, double peak, Map<int, List<Color>> cache) {
  final key = (peak * 2000).round().clamp(0, 2000);
  return cache.putIfAbsent(
    key,
    () => List<Color>.unmodifiable([
      for (var i = 0; i <= _profileSteps; i++)
        base.withValues(
          alpha:
              key /
              2000 *
              math.pow(math.cos((i / _profileSteps * 2 - 1) * math.pi / 2), 2),
        ),
    ]),
  );
}

@visibleForTesting
List<double> collectibleGlareStops() => _profileStops;

@visibleForTesting
List<Color> collectibleGlareColors({
  double strength = 1,
  double peak = collectibleCorePeakAlpha,
}) => _profile(Colors.white, peak * strength, _profileCache);

class _SheenPainter extends CustomPainter {
  _SheenPainter({required this.radius, this.angle}) : super(repaint: angle);

  final BorderRadius radius;
  final ValueListenable<Offset>? angle;

  Paint _band(Size size, double centre, double width, List<Color> colors) {
    final span = size.width * collectibleBandSpan;
    final half = width / collectibleBandSpan / 2;
    final origin =
        Offset(size.width / 2, size.height / 2) -
        collectibleBandAxis * (span / 2);
    return Paint()
      ..shader = ui.Gradient.linear(
        origin + collectibleBandAxis * (span * (centre - half)),
        origin + collectibleBandAxis * (span * (centre + half)),
        colors,
        _profileStops,
      );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect);
    final tilt = angle?.value;
    final reflection = tilt == null
        ? CollectibleReflection.rest
        : collectibleReflection(
            Offset(
              tilt.dx / collectibleMaxTiltDegrees,
              tilt.dy / collectibleMaxTiltDegrees,
            ),
          );
    final k = reflection.intensity;
    final span = size.width * collectibleBandSpan;
    final along = collectibleBandAxis * (span * (reflection.centre - 0.5));
    canvas.save();
    canvas.clipRRect(rrect);
    final haloAlpha = collectibleHaloPeakAlpha * k;
    if (haloAlpha > 0.002) {
      canvas.drawRect(
        rect,
        Paint()
          ..shader = ui.Gradient.radial(
            rect.center + along,
            size.width * collectibleHaloRadius,
            [
              Colors.white.withValues(alpha: haloAlpha),
              Colors.white.withValues(alpha: haloAlpha * 0.35),
              Colors.white.withValues(alpha: 0),
            ],
            const [0, 0.45, 1],
          ),
      );
    }
    const shift = collectibleCoreWidth * 1.1 / collectibleBandSpan;
    final bands = <(double, double, List<Color>)>[
      (
        reflection.centre - shift,
        collectibleCoreWidth * 1.3,
        _profile(_coolTint, collectibleTintPeakAlpha * k, _tintCache),
      ),
      (
        reflection.centre + shift,
        collectibleCoreWidth * 1.3,
        _profile(_warmTint, collectibleTintPeakAlpha * k, _tintCache),
      ),
      (
        reflection.centre,
        collectibleCoreWidth,
        _profile(Colors.white, collectibleCorePeakAlpha * k, _profileCache),
      ),
    ];
    for (final band in bands) {
      canvas.drawRect(
        rect,
        _band(size, band.$1, band.$2, band.$3)..blendMode = BlendMode.plus,
      );
    }
    canvas.restore();

    final bevel = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..shader = ui.Gradient.linear(
        rect.topLeft,
        rect.bottomRight,
        [
          Colors.white.withValues(alpha: 0.3),
          Colors.white.withValues(alpha: 0.06),
          Colors.black.withValues(alpha: 0.32),
        ],
        const [0, 0.5, 1],
      );
    canvas.drawRRect(rrect.deflate(0.6), bevel);

    final fresnel = reflection.fresnel * collectibleFresnelPeakAlpha;
    if (fresnel > 0.004) {
      canvas.drawRRect(
        rrect.deflate(0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withValues(alpha: fresnel),
      );
    }

    final rim = collectibleRimPeakAlpha * reflection.fresnel;
    if (rim > 0.004) {
      canvas.drawRRect(
        rrect.deflate(0.5),
        _band(
            size,
            reflection.centre,
            collectibleRimWidth,
            _profile(Colors.white, rim, _profileCache),
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1,
      );
    }
  }

  @override
  bool shouldRepaint(_SheenPainter old) =>
      old.radius != radius || old.angle != angle;
}

class _GlassBackdrop extends StatelessWidget {
  const _GlassBackdrop({required this.image, required this.solid});

  final ImageProvider image;
  final bool solid;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Color(0xFF05050A)),
        if (!solid) ...[
          RepaintBoundary(
            child: SettledBlur(
              key: const ValueKey('collectible-blur'),
              sigma: collectibleBackdropSigma,
              child: SizedBox.expand(
                child: Image(
                  image: ResizeImage.resizeIfNeeded(160, null, image),
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          ColoredBox(
            color: Colors.black.withValues(alpha: collectibleBackdropDarkness),
          ),
          const RepaintBoundary(
            child: CustomPaint(
              key: ValueKey('collectible-grain'),
              painter: _GlassPainter(),
            ),
          ),
        ],
      ],
    );
  }
}

class _GlassPainter extends CustomPainter {
  const _GlassPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.linear(
          rect.topCenter,
          rect.bottomCenter,
          [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.22),
          ],
          const [0.3, 1],
        ),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = ui.Gradient.radial(
          rect.center,
          rect.longestSide * 0.62,
          [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.4),
          ],
          const [0.45, 1],
        ),
    );
    final count = (size.width * size.height / 18).round().clamp(2, 60000);
    final light = Float32List(count - count % 2);
    final dark = Float32List(count - count % 2);
    var seed = 0x2F6B1A;
    double next() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return seed / 0x7fffffff;
    }

    for (var i = 0; i < light.length; i += 2) {
      light[i] = next() * size.width;
      light[i + 1] = next() * size.height;
      dark[i] = next() * size.width;
      dark[i + 1] = next() * size.height;
    }
    canvas.drawRawPoints(
      ui.PointMode.points,
      light,
      Paint()
        ..strokeWidth = 1
        ..color = Colors.white.withValues(alpha: collectibleGrainAlpha),
    );
    canvas.drawRawPoints(
      ui.PointMode.points,
      dark,
      Paint()
        ..strokeWidth = 1
        ..color = Colors.black.withValues(alpha: collectibleGrainAlpha),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => false;
}
