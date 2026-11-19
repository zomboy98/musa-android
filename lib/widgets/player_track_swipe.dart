import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

abstract interface class PlayerTrackSwipeHandle {
  Animation<double> get offset;

  double get extent;

  MediaItem? neighbor(double direction);

  MediaItem? get nextItem;

  MediaItem? get previousItem;

  bool get committing;

  set coverWidth(double width);

  Future<void> step({required bool forward});

  static PlayerTrackSwipeHandle? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SwipeScope>()?.state;
}

/// Shares one horizontal gesture between artwork and metadata.
class PlayerTrackSwipe extends StatefulWidget {
  const PlayerTrackSwipe({
    super.key,
    required this.queue,
    required this.currentIndex,
    required this.onSelected,
    required this.child,
  });

  final List<MediaItem> queue;
  final int currentIndex;
  final Future<void> Function(MediaItem) onSelected;
  final Widget child;

  @override
  State<PlayerTrackSwipe> createState() => _PlayerTrackSwipeState();
}

class _PlayerTrackSwipeState extends State<PlayerTrackSwipe>
    with SingleTickerProviderStateMixin
    implements PlayerTrackSwipeHandle {
  static const _titleGap = 32.0;

  late final _offset = AnimationController.unbounded(vsync: this);
  static const _commitFraction = 0.35;
  static const _flingVelocity = 700.0;
  static const _edgeResistance = 0.3;

  double _width = 240;
  double? _coverWidth;
  double get _pageExtent => _width + _titleGap;
  double get _gestureWidth => _coverWidth ?? _width;

  @override
  Animation<double> get offset => _offset;

  @override
  double get extent => _pageExtent;

  @override
  set coverWidth(double width) => _coverWidth = width > 0 ? width : null;

  @override
  MediaItem? neighbor(double direction) => _neighbor(direction);

  @override
  bool get committing => _committing;

  @override
  MediaItem? get nextItem => _neighbor(-1);

  @override
  MediaItem? get previousItem => _neighbor(1);

  double _drag = 0;
  bool _settling = false;
  bool _committing = false;
  int _generation = 0;

  MediaItem? _neighbor(double direction) {
    if (widget.currentIndex < 0) return null;
    final at = widget.currentIndex + (direction < 0 ? 1 : -1);
    return at >= 0 && at < widget.queue.length ? widget.queue[at] : null;
  }

  @override
  void didUpdateWidget(PlayerTrackSwipe oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex ||
        !listEquals(oldWidget.queue, widget.queue)) {
      _reset();
    }
  }

  void _reset() {
    _generation++;
    _settling = false;
    _drag = 0;
    _offset.value = 0;
    if (_committing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _committing = false);
    }
  }

  void _start(DragStartDetails details) {
    if (_settling) return;
    _offset.stop();
    _drag = _offset.value;
  }

  void _update(DragUpdateDetails details) {
    if (_settling) return;
    _drag += details.primaryDelta ?? 0;
    _offset.value = _neighbor(_drag) == null
        ? (_drag * _edgeResistance).clamp(
            -_gestureWidth * 0.2,
            _gestureWidth * 0.2,
          )
        : _drag.clamp(-_pageExtent, _pageExtent);
  }

  Future<void> _finish([DragEndDetails? details]) async {
    if (_settling) return;
    final offset = _offset.value;
    final velocity = details?.primaryVelocity ?? 0;
    final target = _neighbor(offset);
    final commit =
        details != null &&
        target != null &&
        (offset.abs() > _gestureWidth * _commitFraction ||
            (velocity.abs() > _flingVelocity && velocity.sign == offset.sign));
    await _settle(commit ? offset.sign : 0, velocity, commit ? target : null);
  }

  @override
  Future<void> step({required bool forward}) async {
    if (_settling) return;
    final direction = forward ? -1.0 : 1.0;
    final target = _neighbor(direction);
    if (target == null) return;
    _offset.stop();
    _drag = 0;
    await _settle(direction, 0, target);
  }

  Future<void> _settle(
    double direction,
    double velocity,
    MediaItem? target,
  ) async {
    final generation = ++_generation;
    _settling = true;
    _committing = target != null;
    final end = direction * _pageExtent;
    try {
      if (MediaQuery.disableAnimationsOf(context)) {
        _offset.value = end;
      } else {
        final spring = SpringDescription.withDampingRatio(
          mass: 1,
          stiffness: 500,
          ratio: 1,
        );
        await _offset
            .animateWith(
              SpringSimulation(
                spring,
                _offset.value,
                end,
                velocity,
                tolerance: const Tolerance(distance: 0.5, velocity: 20),
              ),
            )
            .orCancel;
        if (!mounted || generation != _generation) return;
        _offset.value = end;
      }
      if (!mounted || generation != _generation) return;
      if (target != null) await widget.onSelected(target);
    } on TickerCanceled {
      // A new song/queue or closing the player supersedes this gesture.
    } finally {
      if (mounted && generation == _generation) _reset();
    }
  }

  @override
  void dispose() {
    _generation++;
    _offset.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _SwipeScope(state: this, child: widget.child);
}

class _SwipeScope extends InheritedWidget {
  const _SwipeScope({required this.state, required super.child});

  final _PlayerTrackSwipeState state;

  @override
  bool updateShouldNotify(_SwipeScope oldWidget) => true;
}

/// Multiple hit regions can drive the same titles without moving their child.
class PlayerTrackSwipeRegion extends StatelessWidget {
  const PlayerTrackSwipeRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SwipeScope>()
        ?.state;
    if (state == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Keep the initial movement when a cover/title tap competes with a swipe.
      dragStartBehavior: DragStartBehavior.down,
      onHorizontalDragStart: state._start,
      onHorizontalDragUpdate: state._update,
      onHorizontalDragEnd: state._finish,
      onHorizontalDragCancel: state._finish,
      child: child,
    );
  }
}

class PlayerTrackSwipeTitles extends StatelessWidget {
  const PlayerTrackSwipeTitles({
    super.key,
    required this.current,
    required this.builder,
  });

  final MediaItem current;
  final Widget Function(MediaItem item) builder;

  @override
  Widget build(BuildContext context) {
    final state = context
        .dependOnInheritedWidgetOfExactType<_SwipeScope>()
        ?.state;
    if (state == null) return builder(current);
    return PlayerTrackSwipeRegion(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          state._width = width > 0 ? width : 1;
          MediaItem? cachedNeighbor;
          double? cachedDirection;
          Widget? neighborTitle;
          return ClipRect(
            child: AnimatedBuilder(
              animation: state._offset,
              child: ClipRect(child: builder(current)),
              builder: (context, child) {
                final offset = state._offset.value;
                final next = state._neighbor(offset);
                if (offset != 0 && next != null) {
                  if (!identical(next, cachedNeighbor) ||
                      offset.sign != cachedDirection) {
                    cachedNeighbor = next;
                    cachedDirection = offset.sign;
                    neighborTitle = builder(next);
                  }
                }
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Transform.translate(
                      offset: Offset(offset, 0),
                      child: child,
                    ),
                    if (offset != 0 && next != null)
                      Positioned(
                        left: offset - state._pageExtent * offset.sign,
                        top: 0,
                        width: width,
                        child: ExcludeSemantics(
                          child: IgnorePointer(
                            child: ClipRect(child: neighborTitle),
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          );
        },
      ),
    );
  }
}
