import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

const String musaIntroVideo120 = 'assets/video/musa_intro_120.mp4';
const String musaIntroVideo60 = 'assets/video/musa_intro_60.mp4';

/// Desde esta tasa de refresco (Hz) se usa la version de 120 fps.
const double musaIntroHighRefreshRate = 100;

/// Si el video no esta listo en este tiempo se muestra el logo quieto.
const Duration musaIntroVideoInitTimeout = Duration(milliseconds: 2200);

/// Tope de reproduccion (el video dura 4,14 s).
const Duration musaIntroVideoMaxPlay = Duration(milliseconds: 4600);

const _channel = MethodChannel('musa/launcher_icon');

/// Version del video segun la tasa de refresco de la pantalla.
String musaIntroVideoAssetFor(double refreshRate) =>
    refreshRate >= musaIntroHighRefreshRate
    ? musaIntroVideo120
    : musaIntroVideo60;

/// Video de bienvenida listo para reproducir. Sin pausa ni foco de audio: se
/// mezcla con lo que suene y nunca interrumpe una cancion.
class MusaIntroVideo {
  MusaIntroVideo._(this.controller, this.asset, this.audible);

  final VideoPlayerController controller;
  final String asset;

  /// Con volumen normal (ajuste activado y telefono en modo sonoro).
  final bool audible;
  bool _started = false;
  bool _disposed = false;

  /// Inicializa el video. Devuelve `null` si falla o tarda mas de [timeout].
  static Future<MusaIntroVideo?> open({
    required double refreshRate,
    required bool sound,
    Duration timeout = musaIntroVideoInitTimeout,
    Future<bool> Function()? soundAllowed,
  }) async {
    final asset = musaIntroVideoAssetFor(refreshRate);
    final controller = VideoPlayerController.asset(
      asset,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await controller.initialize().timeout(timeout);
      final audible = sound && await (soundAllowed ?? ringerIsNormal)();
      await controller.setVolume(audible ? 1 : 0);
      await controller.setLooping(false);
      return MusaIntroVideo._(controller, asset, audible);
    } on Object catch (error) {
      debugPrint('Musa intro: el video no esta disponible: $error');
      unawaited(controller.dispose().catchError((Object _) {}));
      return null;
    }
  }

  /// Falso con el telefono en silencio o vibracion.
  @visibleForTesting
  static Future<bool> ringerIsNormal() async {
    if (kIsWeb || !Platform.isAndroid) return true;
    try {
      final mode = await _channel
          .invokeMethod<int>('ringer')
          .timeout(const Duration(milliseconds: 300));
      return mode == null || mode == 2;
    } on Object {
      return true;
    }
  }

  /// Empieza a reproducir (una sola vez). Devuelve si lo inicio ahora.
  bool start() {
    if (_started || _disposed) return false;
    _started = true;
    unawaited(controller.play().catchError((Object _) {}));
    return true;
  }

  void stop() {
    if (_disposed) return;
    unawaited(controller.pause().catchError((Object _) {}));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await controller.dispose();
    } on Object {
      // Ya liberado.
    }
  }
}
