import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/player_cover_mode.dart';
import 'package:mornye/theme/cover_mimic.dart';
import 'package:mornye/widgets/cover_mimic_backdrop.dart';
import 'package:video_player/video_player.dart';

typedef CanvasControllerFactory = VideoPlayerController Function(File file);

VideoPlayerController _fileController(File file) => VideoPlayerController.file(
  file,
  videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
);

const double canvasVeilTopFloor = 0.4;
const double canvasVeilTextFloor = 0.55;
const double canvasVeilBottomFloor = 0.75;

const double fullBleedScrimTop = 0.45;
const double fullBleedScrimText = 0.55;
const double fullBleedScrimBottom = 0.82;

/// Share of the video's height, from its lower edge, that fades into the
/// backdrop when the video is shown at the screen width.
const double playerVideoFadeFraction = 0.28;

class PlayerCanvasBackground extends StatefulWidget {
  const PlayerCanvasBackground({
    super.key,
    required this.source,
    this.veil = 0.34,
    this.veilColor = Colors.black,
    this.controllerFactory,
    this.afterOpen,
    this.fadeDuration = const Duration(milliseconds: 450),
    this.edgeScrims = false,
    this.adaptiveFit = false,
    this.liveSource,
  });

  final String source;

  final double veil;
  final Color veilColor;
  final CanvasControllerFactory? controllerFactory;
  final Future<void> Function()? afterOpen;
  final Duration fadeDuration;

  /// Lets the video show through between a scrim at the top and one that
  /// darkens the lower half, where the title and controls sit, instead of
  /// veiling it evenly.
  final bool edgeScrims;

  /// Shows a video that `BoxFit.cover` would crop at the sides by more than
  /// [playerVideoMaxCropFraction] at the full width, top aligned, with its
  /// lower edge fading into whatever is painted behind.
  final bool adaptiveFit;

  /// Receives the boundary of the video shown at full width, so the backdrop
  /// behind can follow its colours.
  final CoverMimicLiveSource? liveSource;

  @override
  State<PlayerCanvasBackground> createState() => _PlayerCanvasBackgroundState();
}

class _PlayerCanvasBackgroundState extends State<PlayerCanvasBackground>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _foreground = true;
  bool _covered = false;
  bool _reduced = false;
  bool _started = false;
  bool _frame = false;
  Stopwatch _opening = Stopwatch();
  Timer? _frameTimeout;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _covered = !TickerMode.valuesOf(context).enabled;
    final reduced = MediaQuery.disableAnimationsOf(context);
    if (reduced != _reduced || !_started) {
      _started = true;
      _reduced = reduced;
      if (reduced) {
        _release();
      } else {
        unawaited(_open());
      }
    }
    _sync();
  }

  @override
  void didUpdateWidget(PlayerCanvasBackground old) {
    super.didUpdateWidget(old);
    if (old.source != widget.source) {
      _release();
      if (!_reduced) unawaited(_open());
    } else {
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _sync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _release();
    super.dispose();
  }

  File _file() {
    final uri = Uri.tryParse(widget.source);
    return uri != null && uri.scheme == 'file'
        ? File.fromUri(uri)
        : File(widget.source);
  }

  VideoPlayerController _create() {
    final factory = widget.controllerFactory;
    final uri = Uri.tryParse(widget.source);
    final remote =
        uri != null && (uri.scheme == 'http' || uri.scheme == 'https');
    if (factory != null && !remote) return factory(_file());
    if (!remote) return _fileController(_file());
    return VideoPlayerController.networkUrl(
      uri,
      formatHint: uri.path.toLowerCase().endsWith('.m3u8')
          ? VideoFormat.hls
          : null,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _opening = Stopwatch()..start();
    final controller = _create();
    try {
      await controller.initialize();
      await Future.wait([controller.setVolume(0), controller.setLooping(true)]);
      unawaited(
        (widget.afterOpen ?? restoreMusicAudioSessionAfterVideo)().catchError(
          (_) {},
        ),
      );
    } catch (error) {
      debugPrint('video: canvas open failed ${error.runtimeType}');
      await controller.dispose();
      return;
    }
    if (!mounted || generation != _generation) {
      await controller.dispose();
      return;
    }
    debugPrint(
      'video: canvas initialized after ${_opening.elapsedMilliseconds}ms '
      '(${widget.source.startsWith('http') ? 'stream' : 'file'})',
    );
    controller.addListener(_watch);
    _frameTimeout = Timer(
      const Duration(milliseconds: 1500),
      () => _markFrame(timedOut: true),
    );
    setState(() {
      _controller = controller;
      _ready = true;
    });
    _sync();
    _watch();
  }

  void _watch() {
    final controller = _controller;
    if (controller == null) return;
    final value = controller.value;
    if (value.hasError) {
      debugPrint('video: canvas error ${value.errorDescription}');
      _release();
      if (mounted) setState(() {});
      return;
    }
    if (!_frame && (value.position > Duration.zero || !value.isPlaying)) {
      _markFrame();
    }
  }

  void _markFrame({bool timedOut = false}) {
    if (_frame || !mounted || _controller == null) return;
    _frame = true;
    _frameTimeout?.cancel();
    debugPrint(
      'video: canvas first frame after ${_opening.elapsedMilliseconds}ms'
      '${timedOut ? ' (timeout)' : ''}',
    );
    setState(() {});
  }

  void _release() {
    _generation++;
    final controller = _controller;
    _controller = null;
    _ready = false;
    _frame = false;
    _frameTimeout?.cancel();
    if (controller != null) {
      controller.removeListener(_watch);
      unawaited(controller.dispose());
    }
  }

  void _sync() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final shouldPlay = _foreground && !_covered;
    if (shouldPlay && !controller.value.isPlaying) {
      unawaited(controller.play());
    } else if (!shouldPlay && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (MediaQuery.disableAnimationsOf(context) ||
        controller == null ||
        !_ready) {
      return const SizedBox.shrink();
    }
    final size = controller.value.size;
    return IgnorePointer(
      child: AnimatedOpacity(
        key: ValueKey(widget.source),
        opacity: _frame ? 1 : 0,
        duration: widget.fadeDuration,
        curve: Curves.easeInOutCubic,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final area = constraints.biggest;
            final videoAspect = size.width > 0 && size.height > 0
                ? size.width / size.height
                : 0.0;
            final fitWidth =
                widget.adaptiveFit &&
                area.isFinite &&
                !area.isEmpty &&
                videoFitForAspect(videoAspect, area.width / area.height).fit ==
                    PlayerVideoFit.fitWidth;
            final videoHeight = fitWidth ? area.width / videoAspect : 0.0;
            final shown = fitWidth ? (videoHeight / area.height) : 1.0;
            final live = widget.liveSource;
            if (live != null) live.bottomBand = fitWidth ? mimicBottomBand : 0;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (fitWidth)
                  Align(
                    alignment: Alignment.topCenter,
                    child: ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (rect) => const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFFFFFFF),
                          Color(0xC7FFFFFF),
                          Color(0x61FFFFFF),
                          Color(0x00FFFFFF),
                        ],
                        stops: [
                          0,
                          1 - playerVideoFadeFraction,
                          1 - playerVideoFadeFraction * 0.65,
                          1 - playerVideoFadeFraction * 0.3,
                          1,
                        ],
                      ).createShader(rect),
                      child: SizedBox(
                        key: const ValueKey('canvas-video-fit-width'),
                        width: area.width,
                        height: videoHeight,
                        child: live == null
                            ? RepaintBoundary(child: VideoPlayer(controller))
                            : CoverMimicLiveBoundary(
                                source: live,
                                child: VideoPlayer(controller),
                              ),
                      ),
                    ),
                  )
                else
                  ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: size.width <= 0 ? 1 : size.width,
                        height: size.height <= 0 ? 1 : size.height,
                        child: RepaintBoundary(child: VideoPlayer(controller)),
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: widget.edgeScrims ? 0 : 1,
                  duration: const Duration(milliseconds: 300),
                  child: DecoratedBox(
                    key: const ValueKey('canvas-veil'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          widget.veilColor.withValues(
                            alpha: math.max(
                              widget.veil * 0.9,
                              canvasVeilTopFloor,
                            ),
                          ),
                          widget.veilColor.withValues(
                            alpha: math.max(widget.veil, canvasVeilTopFloor),
                          ),
                          widget.veilColor.withValues(
                            alpha: math.max(widget.veil, canvasVeilTextFloor),
                          ),
                          widget.veilColor.withValues(
                            alpha: math
                                .max(widget.veil + 0.3, canvasVeilBottomFloor)
                                .clamp(0.0, 0.9),
                          ),
                        ],
                        stops: const [0, 0.3, 0.5, 1],
                      ),
                    ),
                  ),
                ),
                AnimatedOpacity(
                  opacity: widget.edgeScrims ? 1 : 0,
                  duration: const Duration(milliseconds: 300),
                  child: DecoratedBox(
                    key: const ValueKey('canvas-edge-scrims'),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: fullBleedScrimTop),
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: 0),
                          Colors.black.withValues(alpha: fullBleedScrimText),
                          Colors.black.withValues(alpha: fullBleedScrimBottom),
                        ],
                        stops: fitWidth
                            ? [
                                0,
                                0.14,
                                math.max(0.15, shown * 0.62),
                                math.max(0.16, shown),
                                1,
                              ]
                            : const [0, 0.16, 0.3, 0.42, 1],
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
