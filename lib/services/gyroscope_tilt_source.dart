import 'dart:async';

import 'package:flutter/services.dart';

import '../widgets/collectible_cover_viewer.dart';

const String gyroscopeTiltChannelName = 'musa/tilt';

class GyroscopeTiltSource implements TiltSource {
  GyroscopeTiltSource({Stream<dynamic> Function()? streamFactory})
    : _streamFactory =
          streamFactory ??
          (() => const EventChannel(
            gyroscopeTiltChannelName,
          ).receiveBroadcastStream());

  final Stream<dynamic> Function() _streamFactory;
  StreamController<Offset>? _controller;
  StreamSubscription<dynamic>? _native;

  bool get isActive => _native != null;

  @override
  Stream<Offset> get changes {
    final existing = _controller;
    if (existing != null) return existing.stream;
    final controller = StreamController<Offset>.broadcast(
      onListen: _start,
      onCancel: _stop,
    );
    _controller = controller;
    return controller.stream;
  }

  void _start() {
    if (_native != null) return;
    final controller = _controller;
    if (controller == null) return;
    try {
      _native = _streamFactory().listen(
        (event) {
          final offset = _toOffset(event);
          if (offset != null && !controller.isClosed) controller.add(offset);
        },
        onError: (Object error) => _finish(),
        onDone: _finish,
        cancelOnError: true,
      );
    } on Object {
      _finish();
    }
  }

  void _stop() {
    final native = _native;
    _native = null;
    native?.cancel();
  }

  void _finish() {
    _stop();
    final controller = _controller;
    _controller = null;
    if (controller != null && !controller.isClosed) controller.close();
  }

  static Offset? _toOffset(dynamic event) {
    if (event is! List || event.length < 2) return null;
    final x = event[0];
    final y = event[1];
    if (x is! num || y is! num) return null;
    final dx = x.toDouble();
    final dy = y.toDouble();
    if (!dx.isFinite || !dy.isFinite) return null;
    return Offset(dx.clamp(-1.0, 1.0), dy.clamp(-1.0, 1.0));
  }
}
