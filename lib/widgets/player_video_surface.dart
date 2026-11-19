import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/player_video_glow.dart';
import 'package:mornye/services/player_video_sync.dart';
import 'package:mornye/utils/logger.dart';
import 'package:video_player/video_player.dart';

export 'package:mornye/services/player_video_sync.dart';

typedef VideoSurfaceControllerFactory =
    VideoPlayerController Function(File file);

VideoPlayerController _fileController(File file) => VideoPlayerController.file(
  file,
  videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
);

const _maxSeekLatency = Duration(milliseconds: 600);
const _firstFrameTimeout = Duration(milliseconds: 1200);
const _revealFade = Duration(milliseconds: 240);
final _log = AppLogger('Video');

class PlayerVideoSurface extends ConsumerStatefulWidget {
  const PlayerVideoSurface({
    super.key,
    required this.path,
    this.fallback,
    this.controllerFactory,
    this.afterOpen,
    this.aspectRatio,
    this.clock,
    this.glowSource,
  });

  final String path;

  final Widget? fallback;
  final VideoSurfaceControllerFactory? controllerFactory;
  final Future<void> Function()? afterOpen;
  final double? aspectRatio;
  final Duration Function()? clock;
  final PlayerVideoGlowSource? glowSource;

  @override
  ConsumerState<PlayerVideoSurface> createState() => _PlayerVideoSurfaceState();
}

class _PlayerVideoSurfaceState extends ConsumerState<PlayerVideoSurface>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _foreground = true;
  int _generation = 0;
  bool _correcting = false;
  final PlayerVideoSyncGovernor _governor = PlayerVideoSyncGovernor();
  Duration _seekLatency = Duration.zero;
  double _appliedRate = 1.0;
  bool _revealed = false;
  bool _coverGone = false;
  bool _glowPublished = false;
  Duration _openPosition = Duration.zero;
  Timer? _revealTimeout;
  Stopwatch _opening = Stopwatch();
  final GlobalKey _fallbackKey = GlobalKey();
  final Stopwatch _clock = Stopwatch()..start();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    ref.listenManual(playbackPlayingProvider, (_, _) => _sync());
    ref.listenManual(playbackPositionProvider, (_, position) {
      _align(position);
    });
    unawaited(_open());
  }

  @override
  void didUpdateWidget(PlayerVideoSurface old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) {
      _release();
      unawaited(_open());
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
    final line = _governor.summary(_now(), force: true);
    if (line != null) _trace(line);
    _release();
    super.dispose();
  }

  Future<void> _open() async {
    final generation = ++_generation;
    _opening = Stopwatch()..start();
    final controller = (widget.controllerFactory ?? _fileController)(
      File(widget.path),
    );
    try {
      await controller.initialize();
      _openPosition = ref.read(playbackPositionProvider);
      await Future.wait([
        controller.setVolume(0),
        controller.setLooping(false),
        controller.seekTo(_openPosition),
      ]);
      unawaited(
        (widget.afterOpen ?? restoreMusicAudioSessionAfterVideo)().catchError(
          (_) {},
        ),
      );
    } catch (_) {
      await controller.dispose();
      return;
    }
    if (!mounted || generation != _generation) {
      await controller.dispose();
      return;
    }
    _traceOpen(controller);
    _trace('video: initialized after ${_opening.elapsedMilliseconds}ms');
    setState(() => _controller = controller);
    controller.addListener(_watchFirstFrame);
    _revealTimeout = Timer(_firstFrameTimeout, () => _reveal(timedOut: true));
    _sync();
    _watchFirstFrame();
  }

  void _watchFirstFrame() {
    final controller = _controller;
    if (controller == null || _revealed) return;
    final value = controller.value;
    if (!value.isPlaying || value.position > _openPosition) _reveal();
  }

  void _reveal({bool timedOut = false}) {
    final controller = _controller;
    if (controller == null || _revealed || !mounted) return;
    _revealed = true;
    _revealTimeout?.cancel();
    controller.removeListener(_watchFirstFrame);
    _trace(
      'video: first frame after ${_opening.elapsedMilliseconds}ms'
      '${timedOut ? ' (timeout)' : ''}',
    );
    _glow.publish(controller);
    _glowPublished = true;
    setState(() {});
  }

  PlayerVideoGlowSource get _glow =>
      widget.glowSource ?? PlayerVideoGlowSource.instance;

  Duration _now() => widget.clock?.call() ?? _clock.elapsed;

  void _trace(String line) {
    debugPrint(line);
    _log.i(line);
  }

  void _traceOpen(VideoPlayerController controller) {
    var bytes = 0;
    try {
      bytes = File(widget.path).lengthSync();
    } catch (_) {}
    final size = controller.value.size;
    final duration = controller.value.duration;
    final kbps = duration.inMilliseconds <= 0
        ? 0
        : (bytes * 8 / duration.inMilliseconds).round();
    _trace(
      'video: open size=${size.width.round()}x${size.height.round()} '
      'duration=${duration.inMilliseconds}ms file=${bytes ~/ 1024}KB '
      'bitrate=${kbps}kbps player=video_player texture=true '
      'ext=${widget.path.split('.').last}',
    );
  }

  void _release() {
    _generation++;
    final controller = _controller;
    _controller = null;
    _revealed = false;
    _coverGone = false;
    _appliedRate = 1.0;
    _revealTimeout?.cancel();
    if (controller == null) return;
    controller.removeListener(_watchFirstFrame);
    if (_glowPublished) {
      _glowPublished = false;
      _glow.retire(controller);
    } else {
      unawaited(controller.dispose());
    }
  }

  void _sync() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    final shouldPlay = ref.read(playbackPlayingProvider) && _foreground;
    if (shouldPlay && !controller.value.isPlaying) {
      unawaited(controller.play());
    } else if (!shouldPlay && controller.value.isPlaying) {
      unawaited(controller.pause());
    }
  }

  void _align(Duration audio) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _correcting) {
      return;
    }
    final now = _now();
    if (!_governor.due(now)) return;
    _correcting = true;
    unawaited(
      _correct(controller, audio, now).whenComplete(() {
        _correcting = false;
      }),
    );
  }

  Future<void> _correct(
    VideoPlayerController controller,
    Duration audio,
    Duration arrivedAt,
  ) async {
    try {
      final generation = _generation;
      final video = await controller.position;
      if (video == null || generation != _generation || !mounted) return;
      final playing = controller.value.isPlaying;
      final age = playing ? _now() - arrivedAt : Duration.zero;
      final current = audio + age;
      final now = _now();
      _governor.observe(
        now: now,
        video: video,
        audio: current,
        playing: playing,
      );
      final action = _governor.correction(
        now: now,
        video: video,
        audio: current,
        duration: controller.value.duration,
      );
      if (action == PlayerVideoCorrection.speedUp ||
          action == PlayerVideoCorrection.slowDown ||
          action == PlayerVideoCorrection.restoreSpeed) {
        await _applyRate(
          controller,
          _governor.rate,
          drift: (video - current).inMilliseconds,
        );
      }
      if (action == PlayerVideoCorrection.seek) {
        final drift = (video - current).inMilliseconds;
        await _applyRate(controller, 1.0);
        final watch = Stopwatch()..start();
        await controller.seekTo(current + _seekLatency);
        final measured = watch.elapsed;
        _seekLatency = measured > _maxSeekLatency ? _maxSeekLatency : measured;
        _governor.restartAfterSeek();
        _trace(
          'video: correction=seek drift=${drift}ms '
          'latency=${measured.inMilliseconds}ms '
          'total=${_governor.corrections}',
        );
      }
      final line = _governor.summary(_now());
      if (line != null) _trace(line);
    } catch (_) {}
  }

  Future<void> _applyRate(
    VideoPlayerController controller,
    double rate, {
    int? drift,
  }) async {
    if (rate == _appliedRate) return;
    _appliedRate = rate;
    await controller.setPlaybackSpeed(rate);
    _trace(
      'video: rate=${rate.toStringAsFixed(2)}'
      '${drift == null ? '' : ' drift=${drift}ms'}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final fallback = KeyedSubtree(
      key: _fallbackKey,
      child: widget.fallback ?? const SizedBox.shrink(),
    );
    if (controller == null || !controller.value.isInitialized) return fallback;
    final ratio = widget.aspectRatio ?? controller.value.aspectRatio;
    return AspectRatio(
      aspectRatio: ratio <= 0 ? 16 / 9 : ratio,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_coverGone) fallback,
          AnimatedOpacity(
            opacity: _revealed ? 1 : 0,
            duration: _revealFade,
            curve: Curves.easeOut,
            onEnd: () {
              if (_revealed && mounted) setState(() => _coverGone = true);
            },
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: controller.value.size.width,
                  height: controller.value.size.height,
                  child: RepaintBoundary(child: VideoPlayer(controller)),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
