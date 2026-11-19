import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// The controller of the track video that is on screen with a first frame
/// drawn, shared so the backdrop can draw the same texture blurred.
class PlayerVideoGlowSource extends ValueNotifier<VideoPlayerController?> {
  PlayerVideoGlowSource() : super(null);

  static final instance = PlayerVideoGlowSource();

  void publish(VideoPlayerController controller) {
    scheduleMicrotask(() {
      finishRetire();
      value = controller;
    });
  }

  VideoPlayerController? _retiring;

  /// Hands over a controller that is going away. The glow keeps drawing its
  /// last frame while it fades out and then calls [finishRetire]; without a
  /// glow on screen the controller is disposed at once.
  void retire(VideoPlayerController controller) {
    scheduleMicrotask(() {
      final shown = identical(value, controller);
      if (shown && hasListeners) {
        finishRetire();
        _retiring = controller;
        unawaited(controller.pause());
        value = null;
        return;
      }
      if (shown) value = null;
      unawaited(controller.dispose());
    });
  }

  void finishRetire() {
    final controller = _retiring;
    _retiring = null;
    if (controller != null) unawaited(controller.dispose());
  }
}

/// Turns the blur off for good when the raster thread cannot keep up while
/// the glow is on screen, so it can never cost smoothness.
class PlayerVideoGlowFrameGovernor {
  PlayerVideoGlowFrameGovernor({
    this.window = 90,
    this.slowFrame = const Duration(milliseconds: 20),
    this.slowShare = 0.25,
    this.warmup = 30,
  });

  final int window;
  final Duration slowFrame;
  final double slowShare;
  final int warmup;
  int _seen = 0;
  int _count = 0;
  int _slow = 0;

  bool add(Duration frame) {
    if (_seen < warmup) {
      _seen++;
      return false;
    }
    _count++;
    if (frame > slowFrame) _slow++;
    if (_count < window) return false;
    final tooSlow = _slow / _count > slowShare;
    _count = 0;
    _slow = 0;
    return tooSlow;
  }

  void reset() {
    _seen = 0;
    _count = 0;
    _slow = 0;
  }
}
