import 'dart:ui' as ui;

import 'package:flutter/services.dart' show AssetBundle, rootBundle;

/// Iconos del cajon de apps que tienen arte propio (ver
/// `launcher_icon_setting.dart`). Cualquier otro valor usa el original.
const List<String> musaIntroVariants = [
  'original',
  'chrome',
  'brushed',
  'glass',
  'neon',
  'pearl',
];

/// Arte estatico de bienvenida de [variant]. Para el original es el cuadro
/// final del video de bienvenida.
String musaIntroStillAsset(String variant) {
  final id = musaIntroVariants.contains(variant) ? variant : 'original';
  return 'assets/images/splash/$id/full.png';
}

/// Logo quieto ya decodificado de UNA variante: lo que se ve cuando no hay
/// video (otros iconos, animacion desactivada, reduce-motion o fallo).
class MusaIntroStill {
  MusaIntroStill._(this.variant, this.image);

  final String variant;
  final ui.Image image;

  static Future<MusaIntroStill> load(
    String variant, {
    AssetBundle? bundle,
  }) async {
    final id = musaIntroVariants.contains(variant) ? variant : 'original';
    final data = await (bundle ?? rootBundle).load(musaIntroStillAsset(id));
    final codec = await ui.instantiateImageCodec(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
    try {
      final frame = await codec.getNextFrame();
      return MusaIntroStill._(id, frame.image);
    } finally {
      codec.dispose();
    }
  }

  void dispose() => image.dispose();
}
