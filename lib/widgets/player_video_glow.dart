import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/theme_provider.dart';
import 'package:mornye/services/player_video_glow.dart';
import 'package:video_player/video_player.dart';

const double playerVideoGlowOpacity = 0.68;
const double playerVideoGlowBlur = 44;
const Duration playerVideoGlowFadeIn = Duration(milliseconds: 380);

/// Ambient light of the track video: the same texture, stretched over the
/// whole backdrop and heavily blurred, blended over the cover gradient and
/// darkened so white text stays legible. Draws nothing without a video,
/// with reduced motion, on AMOLED black, or after frames turned slow.
class PlayerVideoGlow extends ConsumerStatefulWidget {
  const PlayerVideoGlow({
    super.key,
    this.source,
    this.opacity = playerVideoGlowOpacity,
    this.blur = playerVideoGlowBlur,
    this.timings = true,
  });

  final PlayerVideoGlowSource? source;
  final double opacity;
  final double blur;
  final bool timings;

  @override
  ConsumerState<PlayerVideoGlow> createState() => _PlayerVideoGlowState();
}

class _PlayerVideoGlowState extends ConsumerState<PlayerVideoGlow> {
  late PlayerVideoGlowSource _source;
  VideoPlayerController? _controller;
  bool _visible = false;
  bool _on = false;
  bool _gaveUp = false;
  final PlayerVideoGlowFrameGovernor _frames = PlayerVideoGlowFrameGovernor();
  bool _timing = false;

  @override
  void initState() {
    super.initState();
    _source = widget.source ?? PlayerVideoGlowSource.instance;
    _source.addListener(_changed);
    _adopt();
  }

  @override
  void didUpdateWidget(PlayerVideoGlow old) {
    super.didUpdateWidget(old);
    final next = widget.source ?? PlayerVideoGlowSource.instance;
    if (!identical(next, _source)) {
      _source.removeListener(_changed);
      _source = next;
      _source.addListener(_changed);
      _adopt();
    }
  }

  @override
  void dispose() {
    _source.removeListener(_changed);
    _source.finishRetire();
    _stopTiming();
    super.dispose();
  }

  void _adopt() {
    final next = _source.value;
    _visible = next != null;
    _on = false;
    if (next != null) {
      _controller = next;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _visible && !_on) setState(() => _on = true);
      });
    }
    _syncTiming();
  }

  void _changed() {
    if (!mounted) return;
    setState(_adopt);
  }

  void _syncTiming() {
    final want = _visible && !_gaveUp && widget.timings && !kDebugMode;
    if (want && !_timing) {
      _frames.reset();
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
      _timing = true;
    } else if (!want && _timing) {
      _stopTiming();
    }
  }

  void _stopTiming() {
    if (!_timing) return;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _timing = false;
  }

  void _onTimings(List<ui.FrameTiming> timings) {
    for (final timing in timings) {
      if (_frames.add(timing.totalSpan)) {
        debugPrint('video: glow off, frames too slow');
        _stopTiming();
        if (mounted) setState(() => _gaveUp = true);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final allowed =
        !MediaQuery.disableAnimationsOf(context) &&
        !ref.watch(themeProvider.select((s) => s.useAmoled)) &&
        !_gaveUp;
    if (controller == null || !allowed) {
      if (!_visible) {
        SchedulerBinding.instance.addPostFrameCallback(
          (_) => _source.finishRetire(),
        );
      }
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: AnimatedOpacity(
        key: const ValueKey('player-video-glow'),
        opacity: _on ? widget.opacity : 0,
        duration: playerVideoGlowFadeIn,
        curve: Curves.easeInOut,
        onEnd: () {
          if (_visible) return;
          _source.finishRetire();
          if (mounted) setState(() => _controller = null);
        },
        child: _GlowLayer(controller: controller, blur: widget.blur),
      ),
    );
  }
}

class _GlowLayer extends StatelessWidget {
  const _GlowLayer({required this.controller, required this.blur});

  final VideoPlayerController controller;
  final double blur;

  @override
  Widget build(BuildContext context) {
    final size = controller.value.size;
    return SizedBox.expand(
      child: RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRect(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: blur,
                  sigmaY: blur,
                  tileMode: TileMode.mirror,
                ),
                child: FittedBox(
                  fit: BoxFit.fill,
                  child: SizedBox(
                    width: size.width <= 0 ? 16 : size.width,
                    height: size.height <= 0 ? 9 : size.height,
                    child: VideoPlayer(controller),
                  ),
                ),
              ),
            ),
            const DecoratedBox(
              key: ValueKey('player-video-glow-veil'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color(0x59000000),
                    Color(0x73000000),
                    Color(0xB3000000),
                  ],
                  stops: [0, 0.5, 1],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
