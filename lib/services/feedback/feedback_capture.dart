import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

class FeedbackCapture {
  const FeedbackCapture._();

  static final GlobalKey boundaryKey = GlobalKey(debugLabel: 'feedbackScreen');

  static Future<Uint8List?> captureScreen({double pixelRatio = 1.5}) async {
    try {
      final boundary = boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) return null;
      final image = await boundary.toImage(pixelRatio: pixelRatio);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }
}
