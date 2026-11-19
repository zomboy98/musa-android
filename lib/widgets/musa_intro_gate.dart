import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:mornye/theme/motion_profile.dart';
import 'package:mornye/widgets/musa_intro_still.dart';
import 'package:mornye/widgets/musa_intro_video.dart';
import 'package:video_player/video_player.dart';

const _launcherChannel = MethodChannel('musa/launcher_icon');

/// Tiempo maximo que la bienvenida estatica retiene la app.
const Duration musaIntroMaxHold = Duration(milliseconds: 3000);

/// Tiempo que se ve el logo quieto antes del fundido.
const Duration musaIntroStillHold = Duration(milliseconds: 700);
const Duration _fadeOut = Duration(milliseconds: 200);
const Duration _fadeOutQuick = Duration(milliseconds: 160);

/// El video es cuadrado (1080x1080) sobre negro: se pinta al ancho de la
/// pantalla, sin deformar y sin recuadro.

/// Arranque en frio de la bienvenida. Vive a nivel de proceso.
///
/// Se dispara una sola vez por proceso: una app que sigue en segundo plano no
/// la repite, ni al volver a primer plano ni al recrearse la Activity. Como al
/// recrear la Activity el motor de Flutter (y con el su isolate) puede
/// reiniciarse dentro del mismo proceso, la marca tambien se guarda junto con
/// el pid en el directorio temporal: un proceso nuevo tiene otro pid.
///
/// Con el icono original y la animacion activada reproduce el video; en
/// cualquier otro caso (otro icono, animacion desactivada, reduce-motion, el
/// video falla o tarda) muestra el logo quieto.
class MusaIntroLaunch {
  MusaIntroLaunch._({
    required String? variant,
    required AssetBundle? bundle,
    required bool animation,
    required bool sound,
    required double refreshRate,
    required bool reduceMotion,
    required Duration videoTimeout,
  }) {
    final id = _variantOf(variant);
    still = id.then((v) => _loadStill(v, bundle)).then((s) {
      readyStill = s;
      stillSettled = true;
      return s;
    });
    video = id
        .then((v) async {
          if (!animation || reduceMotion || v != 'original') return null;
          return MusaIntroVideo.open(
            refreshRate: refreshRate,
            sound: sound,
            timeout: videoTimeout,
          );
        })
        .then((v) {
          readyVideo = v;
          videoSettled = true;
          return v;
        });
  }

  /// Para pruebas: una bienvenida con el arte (y el video) ya listos.
  @visibleForTesting
  MusaIntroLaunch.withParts(MusaIntroStill? still, {MusaIntroVideo? video})
    : still = Future.value(still),
      video = Future.value(video),
      readyStill = still,
      readyVideo = video,
      stillSettled = true,
      videoSettled = true;

  static bool _claimedInThisProcess = false;

  late final Future<MusaIntroStill?> still;
  late final Future<MusaIntroVideo?> video;

  /// El arte y el video ya resueltos, para que la capa que toma el relevo los
  /// pinte en su primer fotograma sin esperar a los futuros.
  MusaIntroStill? readyStill;
  MusaIntroVideo? readyVideo;
  bool stillSettled = false;
  bool videoSettled = false;

  /// Momento (del reloj de [clock]) en que el logo quieto se pinto por primera
  /// vez; el tiempo minimo de exposicion se cuenta desde ahi.
  Duration? stillShownAt;
  final Stopwatch clock = Stopwatch()..start();

  /// Un toque durante el arranque; la capa que tome el relevo lo respeta.
  bool skipRequested = false;
  Duration? videoStartedAt;
  bool _released = false;

  /// Devuelve la bienvenida de este arranque, o `null` si no toca mostrarla.
  static MusaIntroLaunch? begin({
    bool? enabled,
    String? variant,
    AssetBundle? bundle,
    String? stateDirectory,
    bool animation = true,
    bool sound = false,
    double? refreshRate,
    bool? reduceMotion,
    Duration videoTimeout = musaIntroVideoInitTimeout,
  }) {
    final on = enabled ?? (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
    if (!on) return null;
    if (!claim(stateDirectory: stateDirectory)) return null;
    final dispatcher = WidgetsBinding.instance.platformDispatcher;
    return MusaIntroLaunch._(
      variant: variant,
      bundle: bundle,
      animation: animation,
      sound: sound,
      refreshRate:
          refreshRate ??
          MotionProfile.refreshRateOfView(dispatcher.implicitView),
      reduceMotion:
          reduceMotion ?? dispatcher.accessibilityFeatures.disableAnimations,
      videoTimeout: videoTimeout,
    );
  }

  static Future<String> _variantOf(String? variant) async {
    try {
      return variant ?? await readLauncherVariant();
    } on Object {
      return 'original';
    }
  }

  static Future<MusaIntroStill?> _loadStill(
    String id,
    AssetBundle? bundle,
  ) async {
    try {
      return await MusaIntroStill.load(id, bundle: bundle);
    } on Object catch (error, stack) {
      debugPrint('Musa intro: no se pudo cargar el arte: $error\n$stack');
      return null;
    }
  }

  /// Marca la bienvenida como ya mostrada en este proceso.
  @visibleForTesting
  static bool claim({String? stateDirectory}) {
    if (_claimedInThisProcess) return false;
    _claimedInThisProcess = true;
    try {
      final dir = stateDirectory ?? Directory.systemTemp.path;
      final file = File('$dir${Platform.pathSeparator}musa_intro_pid');
      if (file.existsSync() && file.readAsStringSync().trim() == '$pid') {
        return false;
      }
      file.writeAsStringSync('$pid');
    } on Object {
      // Sin poder anotar el pid, la bandera en memoria basta.
    }
    return true;
  }

  @visibleForTesting
  static void resetForTest() => _claimedInThisProcess = false;

  /// Empieza el video una vez y anota cuando (para el tope de reproduccion).
  void startVideo(MusaIntroVideo v) {
    if (v.start()) videoStartedAt = clock.elapsed;
  }

  /// Libera la imagen y el video. Se llama cuando la bienvenida ya termino.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    (await still)?.dispose();
    await (await video)?.dispose();
  }
}

/// Icono del cajon de apps elegido en Ajustes ("original" si no se puede leer).
Future<String> readLauncherVariant() async {
  if (kIsWeb || !Platform.isAndroid) return 'original';
  try {
    final id = await _launcherChannel
        .invokeMethod<String>('get')
        .timeout(const Duration(milliseconds: 400));
    return id ?? 'original';
  } on Object {
    return 'original';
  }
}

/// Capa negra con el video. El logo quieto solo aparece si el video no se
/// va a reproducir (otro icono, animacion desactivada, reduce-motion o fallo);
/// mientras el video se prepara solo se ve negro.
/// Se funde sola al terminar.
class MusaIntroOverlay extends StatefulWidget {
  const MusaIntroOverlay({
    super.key,
    required this.launch,
    required this.appReady,
    required this.onFinished,
  });

  final MusaIntroLaunch launch;

  /// Verdadero cuando la app ya tiene su primer fotograma.
  final ValueListenable<bool> appReady;
  final VoidCallback onFinished;

  @override
  State<MusaIntroOverlay> createState() => _MusaIntroOverlayState();
}

class _MusaIntroOverlayState extends State<MusaIntroOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade;
  MusaIntroStill? _still;
  MusaIntroVideo? _video;
  bool _done = false;
  bool _fading = false;
  bool _quick = false;
  Timer? _maxHold;
  Timer? _stillHold;

  @override
  void initState() {
    super.initState();
    _fade = AnimationController(vsync: this, duration: _fadeOut)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onFinished();
      });
    widget.appReady.addListener(_maybeFinish);
    _quick = widget.launch.skipRequested;
    _armMaxHold(musaIntroMaxHold - widget.launch.clock.elapsed, _beginFade);
    final launch = widget.launch;
    final readyVideo = launch.readyVideo;
    if (readyVideo != null) {
      _attachVideo(readyVideo, notify: false);
    } else if (launch.videoSettled && launch.readyStill != null) {
      _still = launch.readyStill;
      launch.stillShownAt ??= launch.clock.elapsed;
    }
    if (_video == null) unawaited(_load());
  }

  void _armMaxHold(Duration left, VoidCallback action) {
    _maxHold?.cancel();
    _maxHold = Timer(left.isNegative ? Duration.zero : left, action);
  }

  Future<void> _load() async {
    final launch = widget.launch;
    final video = await launch.video;
    if (!mounted) return;
    if (video != null) {
      _attachVideo(video);
      return;
    }
    final still = await launch.still;
    if (!mounted) return;
    if (still == null) {
      _beginFade(quick: true);
      return;
    }
    _showStill(still);
    final shownAt = launch.stillShownAt ?? launch.clock.elapsed;
    final left = shownAt + musaIntroStillHold - launch.clock.elapsed;
    _stillHold?.cancel();
    _stillHold = Timer(left.isNegative ? Duration.zero : left, () {
      _done = true;
      _quick = true;
      _maybeFinish();
    });
  }

  void _showStill(MusaIntroStill? still) {
    if (!mounted || still == null || _video != null || _still != null) return;
    widget.launch.stillShownAt ??= widget.launch.clock.elapsed;
    setState(() => _still = still);
  }

  void _attachVideo(MusaIntroVideo video, {bool notify = true}) {
    final launch = widget.launch;
    if (notify) {
      setState(() => _video = video);
    } else {
      _video = video;
    }
    video.controller.addListener(_onVideo);
    if (launch.skipRequested) {
      _stopVideo();
      _done = true;
      _maybeFinish();
      return;
    }
    launch.startVideo(video);
    final started = launch.videoStartedAt ?? launch.clock.elapsed;
    _armMaxHold(started + musaIntroVideoMaxPlay - launch.clock.elapsed, () {
      _stopVideo();
      _beginFade();
    });
    _onVideo();
  }

  void _onVideo() {
    final video = _video;
    if (video == null || _fading) return;
    final value = video.controller.value;
    if (value.hasError) {
      _stopVideo();
      _beginFade(quick: true);
    } else if (value.isCompleted && !_done) {
      _done = true;
      _maybeFinish();
    }
  }

  void _stopVideo() => _video?.stop();

  @override
  void dispose() {
    _maxHold?.cancel();
    _stillHold?.cancel();
    _video?.controller.removeListener(_onVideo);
    widget.appReady.removeListener(_maybeFinish);
    _fade.dispose();
    super.dispose();
  }

  void _maybeFinish() {
    if (_fading || !mounted) return;
    if (_done && widget.appReady.value) _beginFade(quick: _quick);
  }

  void _beginFade({bool quick = false}) {
    if (_fading || !mounted) return;
    _fading = true;
    _maxHold?.cancel();
    _fade.duration = quick ? _fadeOutQuick : _fadeOut;
    _fade.forward();
  }

  void _skip() {
    widget.launch.skipRequested = true;
    _quick = true;
    _stopVideo();
    _done = true;
    _maybeFinish();
  }

  @override
  Widget build(BuildContext context) {
    final shortest = MediaQuery.maybeSizeOf(context)?.shortestSide ?? 360;
    Widget content = const SizedBox.expand();
    final video = _video;
    final still = _still;
    if (video != null) {
      final width = shortest;
      content = Center(
        child: SizedBox(
          width: width,
          height: width,
          child: VideoPlayer(video.controller),
        ),
      );
    } else if (still != null) {
      final width = shortest;
      content = Center(
        child: SizedBox(
          width: width,
          child: AspectRatio(
            aspectRatio: still.image.width / still.image.height,
            child: RawImage(image: still.image, fit: BoxFit.contain),
          ),
        ),
      );
    }
    return FadeTransition(
      opacity: ReverseAnimation(_fade),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _skip,
        child: ColoredBox(color: const Color(0xFF000000), child: content),
      ),
    );
  }
}

/// Primera fase: solo la bienvenida sobre negro mientras la app se
/// inicializa. Despues `runApp` la sustituye por la app envuelta en
/// [MusaIntroGate], que sigue con el mismo video o logo y el reloj de
/// [launch].
class MusaIntroBoot extends StatelessWidget {
  const MusaIntroBoot({super.key, required this.launch});

  final MusaIntroLaunch launch;

  static final ValueNotifier<bool> _notReady = ValueNotifier<bool>(false);

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery.fromView(
        view: View.of(context),
        child: MusaIntroOverlay(
          launch: launch,
          appReady: _notReady,
          onFinished: () {},
        ),
      ),
    );
  }
}

/// Pone la bienvenida encima de [child] (la app) hasta que termina y la app
/// esta lista; despues la retira y libera sus recursos.
class MusaIntroGate extends StatefulWidget {
  const MusaIntroGate({super.key, required this.launch, required this.child});

  final MusaIntroLaunch? launch;
  final Widget child;

  @override
  State<MusaIntroGate> createState() => _MusaIntroGateState();
}

class _MusaIntroGateState extends State<MusaIntroGate> {
  final ValueNotifier<bool> _ready = ValueNotifier<bool>(false);
  bool _showOverlay = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _ready.value = true;
    });
  }

  @override
  void dispose() {
    unawaited(widget.launch?.release());
    _ready.dispose();
    super.dispose();
  }

  void _finished() {
    if (!mounted) return;
    setState(() => _showOverlay = false);
    unawaited(widget.launch?.release());
  }

  @override
  Widget build(BuildContext context) {
    final launch = widget.launch;
    if (launch == null || !_showOverlay) return widget.child;
    return Stack(
      fit: StackFit.passthrough,
      textDirection: TextDirection.ltr,
      children: [
        widget.child,
        Positioned.fill(
          // Fuera de MaterialApp no hay MediaQuery: se toma de la vista.
          child: MediaQuery.fromView(
            view: View.of(context),
            child: MusaIntroOverlay(
              launch: launch,
              appReady: _ready,
              onFinished: _finished,
            ),
          ),
        ),
      ],
    );
  }
}
