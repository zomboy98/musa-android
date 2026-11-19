import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:mornye/services/feedback/feedback_store.dart';
import 'package:path/path.dart' as p;

/// Prepares gallery photos before they are stored or uploaded: the long side
/// is capped and the image is re-encoded as PNG, which drops EXIF metadata
/// such as the capture location.
class FeedbackImageProcessor {
  const FeedbackImageProcessor._();

  static const maxSide = 1600;

  static Future<FeedbackImage?> prepare(FeedbackImage image) async {
    try {
      final bytes = image.bytes ?? await File(image.path!).readAsBytes();
      final png = await shrinkToPng(bytes);
      if (png == null) return null;
      final base = p.basenameWithoutExtension(image.name);
      return FeedbackImage(
        name: '${base.isEmpty ? 'foto' : base}.png',
        bytes: png,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> shrinkToPng(
    Uint8List bytes, {
    int side = maxSide,
  }) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? decoded;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final wide = descriptor.width >= descriptor.height;
      final longSide = wide ? descriptor.width : descriptor.height;
      final scale = longSide > side;
      codec = await descriptor.instantiateCodec(
        targetWidth: scale && wide ? side : null,
        targetHeight: scale && !wide ? side : null,
      );
      decoded = (await codec.getNextFrame()).image;
      final data = await decoded.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } finally {
      decoded?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
