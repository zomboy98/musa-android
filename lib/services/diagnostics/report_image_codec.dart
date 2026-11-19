import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Shrinks pictures to JPEG without metadata so a report stays light and
/// carries no location or camera data.
class ReportImageCodec {
  const ReportImageCodec._();

  static const maxSide = 1600;
  static const maxBytes = 1024 * 1024;
  static const firstQuality = 80;

  static Future<Uint8List?> compress(Uint8List bytes) =>
      compute(_compressEntry, bytes);

  static Uint8List? _compressEntry(Uint8List bytes) => compressSync(bytes);

  static Uint8List? compressSync(
    Uint8List bytes, {
    int side = maxSide,
    int limit = maxBytes,
  }) {
    try {
      final decoded = img.decodeImage(bytes);
      if (decoded == null) return null;
      var image = img.bakeOrientation(decoded);
      image.exif = img.ExifData();
      if (image.hasAlpha) {
        final flat = img.Image(width: image.width, height: image.height)
          ..clear(img.ColorRgb8(255, 255, 255));
        image = img.compositeImage(flat, image);
      }
      image = _fit(image, side);
      for (var round = 0; round < 5; round++) {
        for (final quality in const [firstQuality, 70, 60, 50]) {
          final out = img.encodeJpg(image, quality: quality);
          if (out.length <= limit) return out;
        }
        image = img.copyResize(
          image,
          width: (image.width * 0.75).round().clamp(1, side),
          interpolation: img.Interpolation.average,
        );
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static img.Image _fit(img.Image image, int side) {
    final longest = image.width > image.height ? image.width : image.height;
    if (longest <= side) return image;
    return image.width >= image.height
        ? img.copyResize(
            image,
            width: side,
            interpolation: img.Interpolation.average,
          )
        : img.copyResize(
            image,
            height: side,
            interpolation: img.Interpolation.average,
          );
  }
}
