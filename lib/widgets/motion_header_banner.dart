import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/cover_image_frame.dart';
import 'package:video_player/video_player.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/services/music_player_service.dart';

final _log = AppLogger('MotionHeaderBanner');

class MotionHeaderBanner extends ConsumerStatefulWidget {
  final String videoUrl;
  final Widget fallback;
  final ValueChanged<double>? onAspectRatioChanged;
  final VoidCallback? onError;
  final VideoPlayerController? controller;
  final Duration fadeDuration;

  /// Holds the current video frame without recreating its decoder.
  final bool playbackEnabled;

  /// Shows every pixel of the video when its proportions differ from the
  /// frame's, over [fallback], instead of cropping it.
  final bool complete;

  const MotionHeaderBanner({
    super.key,
    required this.videoUrl,
    required this.fallback,
    this.onAspectRatioChanged,
    this.onError,
    this.controller,
    this.fadeDuration = const Duration(milliseconds: 400),
    this.playbackEnabled = true,
    this.complete = false,
  });

  @override
  ConsumerState<MotionHeaderBanner> createState() => _MotionHeaderBannerState();
}

class _MotionHeaderBannerState extends ConsumerState<MotionHeaderBanner>
    with WidgetsBindingObserver {
  /// Banners showing each borrowed controller. It plays while any of them is
  /// visible, so an outgoing copy (a cover fading out as the player rotates)
  /// cannot pause the video the incoming one shows.
  static final _borrowers =
      <VideoPlayerController, Set<_MotionHeaderBannerState>>{};

  VideoPlayerController? _controller;
  bool _ownsController = true;
  bool _ready = false;
  bool _failed = false;
  bool _headerVisible = true;
  bool _reduceMotion = true;
  ValueListenable<TickerModeData>? _tickerMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    ref.listenManual(settingsProvider.select((s) => s.motionArtworkEnabled), (
      _,
      enabled,
    ) {
      _disposeController();
      _ready = false;
      _failed = false;
      if (enabled) _syncPlayback();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      _disposeController();
      _ready = false;
      _failed = false;
    }
    final header = context
        .dependOnInheritedWidgetOfExactType<FlexibleSpaceBarSettings>();
    // A collapsed FlexibleSpaceBar hides its background with opacity only;
    // its TickerMode remains enabled while the pinned toolbar is visible.
    _headerVisible = header == null || header.currentExtent > header.minExtent;
    // TickerMode is off while this subtree is hidden: covered by an opaque
    // route (Navigator offstages it) or on an inactive shell tab. Follow it
    // so the decoder doesn't keep running behind other screens.
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _tickerMode)) {
      _tickerMode?.removeListener(_syncPlayback);
      _tickerMode = notifier;
      notifier.addListener(_syncPlayback);
    }
    _syncPlayback();
  }

  bool get _visible {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final appVisible =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;
    return !_reduceMotion &&
        appVisible &&
        _headerVisible &&
        (_tickerMode?.value.enabled ?? true);
  }

  bool get _shouldPlay => _visible && widget.playbackEnabled;

  void _syncPlayback() {
    final controller = _controller;
    if (controller == null) {
      if (_visible && !_failed) _initialize();
      return;
    }
    if (!_ready) return;
    final shouldPlay = _ownsController
        ? _shouldPlay
        : _borrowers[controller]?.any((banner) => banner._shouldPlay) ?? false;
    if (controller.value.isPlaying == shouldPlay) return;
    if (shouldPlay) {
      controller.play();
    } else {
      controller.pause();
    }
  }

  @override
  void didUpdateWidget(MotionHeaderBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl ||
        oldWidget.controller != widget.controller) {
      _disposeController();
      _ready = false;
      _failed = false;
      _syncPlayback();
    } else if (oldWidget.playbackEnabled != widget.playbackEnabled) {
      _syncPlayback();
    }
  }

  Future<void> _initialize() async {
    if (_reduceMotion || !ref.read(settingsProvider).motionArtworkEnabled) {
      return;
    }
    final prepared = widget.controller;
    if (prepared != null && prepared.value.isInitialized) {
      _ownsController = false;
      _controller = prepared;
      _borrowers.putIfAbsent(prepared, () => {}).add(this);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(prepared, _controller)) return;
        setState(() => _ready = true);
        widget.onAspectRatioChanged?.call(prepared.value.aspectRatio);
        _syncPlayback();
      });
      // Lifecycle callbacks need not coincide with a scheduled frame.
      WidgetsBinding.instance.scheduleFrame();
      return;
    }
    _ownsController = true;
    final url = widget.videoUrl.trim();
    if (url.isEmpty) {
      setState(() => _failed = true);
      return;
    }

    final uri = Uri.tryParse(url);
    final options = VideoPlayerOptions(mixWithOthers: true);
    final controller = uri?.scheme == 'file' || url.startsWith('/')
        ? VideoPlayerController.file(
            uri?.scheme == 'file' ? File.fromUri(uri!) : File(url),
            videoPlayerOptions: options,
          )
        : VideoPlayerController.networkUrl(
            Uri.parse(url),
            formatHint: uri?.path.toLowerCase().endsWith('.m3u8') == true
                ? VideoFormat.hls
                : null,
            videoPlayerOptions: options,
          );
    _controller = controller;
    try {
      await controller.initialize();
      if (!mounted || !identical(controller, _controller)) return;
      await controller.setVolume(0);
      await controller.setLooping(true);
      if (!mounted || !identical(controller, _controller)) return;
      setState(() => _ready = true);
      widget.onAspectRatioChanged?.call(controller.value.aspectRatio);
      _syncPlayback();
    } catch (e) {
      _log.w('Failed to play motion banner: $e');
      if (!mounted || !identical(controller, _controller)) return;
      _disposeController();
      setState(() => _failed = true);
      widget.onError?.call();
    } finally {
      await restoreMusicAudioSessionAfterVideo();
    }
  }

  void _disposeController() {
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    if (_ownsController) {
      controller.dispose();
      return;
    }
    final borrowers = _borrowers[controller]?..remove(this);
    if (borrowers == null || borrowers.isEmpty) {
      _borrowers.remove(controller);
      controller.pause();
    } else {
      borrowers.first._syncPlayback();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncPlayback();
  }

  @override
  void dispose() {
    _tickerMode?.removeListener(_syncPlayback);
    WidgetsBinding.instance.removeObserver(this);
    _disposeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion ||
        !ref.watch(settingsProvider.select((s) => s.motionArtworkEnabled))) {
      return widget.fallback;
    }
    final controller = _controller;
    final showVideo = _ready && !_failed && controller != null;

    return Stack(
      fit: StackFit.expand,
      children: [
        widget.fallback,
        AnimatedOpacity(
          curve: Curves.easeOutCubic,
          opacity: showVideo ? 1.0 : 0.0,
          duration: widget.fadeDuration,
          child: showVideo ? _video(controller) : const SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _video(VideoPlayerController controller) {
    final size = controller.value.size;
    Widget fitted(BoxFit fit, Alignment alignment) => FittedBox(
      fit: fit,
      alignment: alignment,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: RepaintBoundary(child: VideoPlayer(controller)),
      ),
    );
    if (!widget.complete || size.width <= 0 || size.height <= 0) {
      return fitted(BoxFit.cover, Alignment.topCenter);
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final frameAspect =
            constraints.hasBoundedWidth &&
                constraints.hasBoundedHeight &&
                constraints.maxHeight > 0
            ? constraints.maxWidth / constraints.maxHeight
            : size.width / size.height;
        return CoverImageFrame.needsContain(
              size.width / size.height,
              frameAspect,
            )
            ? fitted(BoxFit.contain, Alignment.center)
            : fitted(BoxFit.cover, Alignment.topCenter);
      },
    );
  }
}
