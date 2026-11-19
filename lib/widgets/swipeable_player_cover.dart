import 'dart:math' as math;

import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/services/cover_cache_manager.dart';
import 'package:mornye/widgets/cached_cover_image.dart';
import 'package:mornye/widgets/player_track_swipe.dart';

class SwipeablePlayerCover extends StatefulWidget {
  const SwipeablePlayerCover({
    super.key,
    required this.current,
    required this.child,
    required this.neighborBuilder,
    this.cacheWidth,
  });

  final MediaItem current;
  final Widget child;
  final Widget Function(BuildContext context, MediaItem item) neighborBuilder;
  final int? cacheWidth;

  @override
  State<SwipeablePlayerCover> createState() => _SwipeablePlayerCoverState();
}

class _SwipeablePlayerCoverState extends State<SwipeablePlayerCover>
    with SingleTickerProviderStateMixin {
  static const _gap = 24.0;
  static const _maxTilt = 3 * math.pi / 180;
  static const _reducedFade = Duration(milliseconds: 120);

  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: _reducedFade,
    value: 1,
  );
  String? _precached;
  MediaItem? _neighbor;
  Widget? _neighborWidget;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheNeighbors();
  }

  @override
  void didUpdateWidget(SwipeablePlayerCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.current.id != widget.current.id &&
        MediaQuery.disableAnimationsOf(context)) {
      _fade.forward(from: 0);
    }
    _precacheNeighbors();
  }

  void _precacheNeighbors() {
    final handle = PlayerTrackSwipeHandle.maybeOf(context);
    if (handle == null) return;
    final next = handle.nextItem;
    final previous = handle.previousItem;
    final key =
        '${widget.current.id}|${next?.artUri}|${previous?.artUri}|${widget.cacheWidth}';
    if (key == _precached) return;
    _precached = key;
    for (final item in [next, previous]) {
      final provider = _providerFor(item?.artUri?.toString());
      if (provider != null) {
        precacheImage(provider, context, onError: (_, _) {});
      }
    }
  }

  ImageProvider? _providerFor(String? uri) {
    if (uri == null || uri.isEmpty) return null;
    if (isHttpCoverUrl(uri)) {
      return CachedNetworkImageProvider(
        uri,
        cacheManager: CoverCacheManager.instance,
        maxWidth: widget.cacheWidth,
      );
    }
    return coverImageProvider(uri, cacheWidth: widget.cacheWidth);
  }

  Widget _neighborFor(BuildContext context, MediaItem item) {
    if (!identical(item, _neighbor) || _neighborWidget == null) {
      _neighbor = item;
      _neighborWidget = RepaintBoundary(
        child: widget.neighborBuilder(context, item),
      );
    }
    return _neighborWidget!;
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final handle = PlayerTrackSwipeHandle.maybeOf(context);
    if (handle == null) return widget.child;
    final l10n = context.l10n;
    final next = handle.nextItem;
    final previous = handle.previousItem;
    final reduced = MediaQuery.disableAnimationsOf(context);
    Widget cover;
    if (reduced) {
      cover = FadeTransition(
        opacity: _fade,
        child: RepaintBoundary(child: widget.child),
      );
    } else {
      cover = LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          handle.coverWidth = width.isFinite ? width : 0;
          final travel = (width.isFinite ? width : 0.0) + _gap;
          final current = RepaintBoundary(child: widget.child);
          return AnimatedBuilder(
            animation: handle.offset,
            child: current,
            builder: (context, child) {
              final offset = handle.offset.value;
              final progress = (offset / handle.extent).clamp(-1.0, 1.0);
              final amount = progress.abs();
              final item = progress == 0 ? null : handle.neighbor(progress);
              final dx = progress * travel;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: ExcludeSemantics(
                      child: IgnorePointer(
                        child: item == null
                            ? const SizedBox.shrink()
                            : Transform.translate(
                                offset: Offset(dx - progress.sign * travel, 0),
                                child: Transform.scale(
                                  scale: 0.9 + 0.1 * amount,
                                  child: Opacity(
                                    opacity: amount,
                                    child: _neighborFor(context, item),
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                  Transform(
                    alignment: Alignment.center,
                    transform: Matrix4.identity()
                      ..translateByDouble(dx, 0, 0, 1)
                      ..rotateZ(progress * _maxTilt)
                      ..scaleByDouble(
                        1 - 0.06 * amount,
                        1 - 0.06 * amount,
                        1,
                        1,
                      ),
                    child: Opacity(opacity: 1 - 0.5 * amount, child: child),
                  ),
                ],
              );
            },
          );
        },
      );
    }
    return Semantics(
      onScrollLeft: next == null ? null : () => handle.step(forward: true),
      onScrollRight: previous == null
          ? null
          : () => handle.step(forward: false),
      customSemanticsActions: {
        if (next != null)
          CustomSemanticsAction(label: l10n.nowPlayingNextTrack): () =>
              handle.step(forward: true),
        if (previous != null)
          CustomSemanticsAction(label: l10n.nowPlayingPreviousTrack): () =>
              handle.step(forward: false),
      },
      child: cover,
    );
  }
}
