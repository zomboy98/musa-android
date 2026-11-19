import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/musa_intro_gate.dart';
import 'package:mornye/widgets/musa_intro_still.dart';
import 'package:mornye/widgets/musa_intro_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

/// Plataforma de video falsa: registra lo que la bienvenida le pide.
class _FakeVideoPlatform extends VideoPlayerPlatform {
  bool failCreate = false;
  bool neverInitialize = false;
  bool playing = false;
  int playCalls = 0;
  int creations = 0;
  int disposals = 0;
  double volume = 1;
  double speed = 1;
  bool? mixWithOthers;
  String? asset;
  final Map<int, StreamController<VideoEvent>> _events = {};

  void finish(int id) =>
      _events[id]!.add(VideoEvent(eventType: VideoEventType.completed));

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    if (failCreate) throw PlatformException(code: 'video_error');
    asset = options.dataSource.asset;
    final id = ++creations;
    // ignore: close_sinks
    final events = StreamController<VideoEvent>();
    _events[id] = events;
    if (!neverInitialize) {
      events.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(milliseconds: 4970),
          size: const Size(1080, 1080),
        ),
      );
    }
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => _events[playerId]!.stream;

  @override
  Future<void> play(int playerId) async {
    playing = true;
    playCalls++;
  }

  @override
  Future<void> pause(int playerId) async => playing = false;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> setVolume(int playerId, double volume) async =>
      this.volume = volume;

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async =>
      this.speed = speed;

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) async =>
      this.mixWithOthers = mixWithOthers;

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Widget buildViewWithOptions(VideoViewOptions options) => const SizedBox();

  @override
  Future<void> dispose(int playerId) async {
    disposals++;
    playing = false;
    await _events[playerId]?.close();
  }
}

const _app = Directionality(
  textDirection: TextDirection.ltr,
  child: Text('APP'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeVideoPlatform platform;
  late Directory tmp;
  final original = VideoPlayerPlatform.instance;

  setUp(() {
    MusaIntroLaunch.resetForTest();
    platform = _FakeVideoPlatform();
    VideoPlayerPlatform.instance = platform;
    tmp = Directory.systemTemp.createTempSync('musa_intro_');
  });
  tearDown(() {
    VideoPlayerPlatform.instance = original;
    tmp.deleteSync(recursive: true);
  });

  /// La carga (imagen y video) usa el motor real: fuera del reloj falso.
  Future<MusaIntroLaunch> begin(
    WidgetTester tester, {
    String variant = 'original',
    bool animation = true,
    bool sound = false,
    double refreshRate = 120,
    bool reduceMotion = false,
  }) async {
    MusaIntroLaunch.resetForTest();
    final marker = File('${tmp.path}/musa_intro_pid');
    if (marker.existsSync()) marker.deleteSync();
    final launch = await tester.runAsync(() async {
      final l = MusaIntroLaunch.begin(
        enabled: true,
        variant: variant,
        stateDirectory: tmp.path,
        animation: animation,
        sound: sound,
        refreshRate: refreshRate,
        reduceMotion: reduceMotion,
      )!;
      await l.video;
      await l.still;
      return l;
    });
    return launch!;
  }

  Future<void> pumpGate(WidgetTester tester, MusaIntroLaunch? launch) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MusaIntroGate(launch: launch, child: _app));
    // Las cargas ya terminaron en el reloj real: deja correr sus avisos.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    await tester.pump();
  }

  /// La liberacion espera cargas del reloj real: deja que termine.
  Future<void> flush(WidgetTester tester) => tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );

  group('video segun la tasa de refresco', () {
    test('>= 100 Hz usa el de 120 fps y menos el de 60', () {
      expect(musaIntroVideoAssetFor(120), musaIntroVideo120);
      expect(musaIntroVideoAssetFor(100), musaIntroVideo120);
      expect(musaIntroVideoAssetFor(90), musaIntroVideo60);
      expect(musaIntroVideoAssetFor(60), musaIntroVideo60);
      expect(musaIntroVideoAssetFor(30), musaIntroVideo60);
    });

    test('los dos videos existen como assets', () {
      for (final f in [musaIntroVideo120, musaIntroVideo60]) {
        expect(File(f).existsSync(), isTrue, reason: f);
      }
    });

    testWidgets('begin pide el video que corresponde a la tasa', (t) async {
      await begin(t, refreshRate: 120);
      expect(platform.asset, musaIntroVideo120);
      MusaIntroLaunch.resetForTest();
      await begin(t, refreshRate: 60);
      expect(platform.asset, musaIntroVideo60);
    });

    testWidgets('sin tasa explicita lee la de la pantalla', (t) async {
      t.view.display.refreshRate = 120;
      addTearDown(t.view.reset);
      final launch = await t.runAsync(() async {
        final l = MusaIntroLaunch.begin(
          enabled: true,
          variant: 'original',
          stateDirectory: tmp.path,
          reduceMotion: false,
        )!;
        await l.video;
        return l;
      });
      expect(launch, isNotNull);
      expect(platform.asset, musaIntroVideo120);
    });
  });

  group('sonido', () {
    testWidgets('por defecto va mudo (volumen 0) y sin foco de audio', (
      t,
    ) async {
      await begin(t);
      expect(platform.volume, 0);
      expect(platform.mixWithOthers, isTrue);
    });

    testWidgets('con el ajuste activado suena a volumen normal', (t) async {
      final video = await t.runAsync(
        () => MusaIntroVideo.open(
          refreshRate: 60,
          sound: true,
          soundAllowed: () async => true,
        ),
      );
      expect(platform.volume, 1);
      expect(video!.audible, isTrue);
    });

    testWidgets('con el telefono en silencio queda mudo', (t) async {
      final video = await t.runAsync(
        () => MusaIntroVideo.open(
          refreshRate: 60,
          sound: true,
          soundAllowed: () async => false,
        ),
      );
      expect(platform.volume, 0);
      expect(video!.audible, isFalse);
    });
  });

  group('reproduccion', () {
    testWidgets('reproduce, termina con el video y libera el controlador', (
      t,
    ) async {
      final launch = await begin(t);
      await pumpGate(t, launch);
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(platform.playCalls, 1);
      await t.pump(const Duration(seconds: 2));
      expect(find.byType(MusaIntroOverlay), findsOneWidget);
      platform.finish(1);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.pumpAndSettle();
      expect(find.byType(MusaIntroOverlay), findsNothing);
      expect(find.text('APP'), findsOneWidget);
      await flush(t);
      expect(platform.disposals, 1);
    });

    testWidgets('se reproduce a velocidad nativa, sin acelerar', (t) async {
      final launch = await begin(t);
      await pumpGate(t, launch);
      expect(platform.speed, 1.0);
      platform.finish(1);
      await t.pump();
      await t.pumpAndSettle();
    });

    testWidgets('el relevo pinta el video ya listo en el primer fotograma', (
      t,
    ) async {
      final launch = await begin(t);
      expect(launch.readyVideo, isNotNull);
      await t.pumpWidget(MusaIntroGate(launch: launch, child: _app));
      expect(find.byType(VideoPlayer), findsOneWidget);
      expect(platform.playCalls, 1);
      platform.finish(1);
      await t.pump();
      await t.pumpAndSettle();
    });

    testWidgets('el video cuadrado ocupa el ancho de la pantalla sin deformar', (
      t,
    ) async {
      t.view.physicalSize = const Size(1200, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final launch = await begin(t);
      await pumpGate(t, launch);
      expect(t.getSize(find.byType(VideoPlayer)), const Size(1200, 1200));
      platform.finish(1);
      await t.pump();
      await t.pumpAndSettle();
    });

    testWidgets('un toque la salta con fundido corto y para el audio', (
      t,
    ) async {
      final launch = await begin(t, sound: true);
      await pumpGate(t, launch);
      await t.pump(const Duration(milliseconds: 300));
      expect(platform.playing, isTrue);
      await t.tap(find.byType(MusaIntroOverlay));
      await t.pump();
      expect(platform.playing, isFalse);
      await t.pump(const Duration(milliseconds: 400));
      await t.pump();
      expect(find.byType(MusaIntroOverlay), findsNothing);
      await flush(t);
      expect(platform.disposals, 1);
    });

    testWidgets('tope de 4,6 s si el video no avisa que termino', (t) async {
      final launch = await begin(t);
      await pumpGate(t, launch);
      await t.pump(const Duration(milliseconds: 4500));
      expect(find.byType(MusaIntroOverlay), findsOneWidget);
      await t.pump(const Duration(milliseconds: 200));
      await t.pumpAndSettle();
      expect(find.byType(MusaIntroOverlay), findsNothing);
      await flush(t);
      expect(platform.disposals, 1);
    });

    testWidgets('si la app se cierra a media bienvenida libera el video', (
      t,
    ) async {
      final launch = await begin(t);
      await pumpGate(t, launch);
      await t.pumpWidget(const SizedBox());
      await t.pump();
      await flush(t);
      expect(platform.disposals, 1);
    });
  });

  group('logo quieto (sin video)', () {
    Future<void> expectStillThenApp(
      WidgetTester t,
      MusaIntroLaunch launch,
    ) async {
      await pumpGate(t, launch);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(find.byType(RawImage), findsOneWidget);
      await t.pump(const Duration(milliseconds: 800));
      await t.pumpAndSettle();
      expect(find.byType(MusaIntroOverlay), findsNothing);
      expect(find.text('APP'), findsOneWidget);
    }

    testWidgets('con otro icono no hay video', (t) async {
      for (final variant in ['chrome', 'brushed', 'glass', 'neon', 'pearl']) {
        MusaIntroLaunch.resetForTest();
        final launch = await begin(t, variant: variant);
        await expectStillThenApp(t, launch);
      }
      expect(platform.creations, 0);
    });

    testWidgets('con la animacion desactivada en Ajustes', (t) async {
      final launch = await begin(t, animation: false);
      await expectStillThenApp(t, launch);
      expect(platform.creations, 0);
    });

    testWidgets('con reduce-motion', (t) async {
      final launch = await begin(t, reduceMotion: true);
      await expectStillThenApp(t, launch);
      expect(platform.creations, 0);
    });

    testWidgets('si el video falla al inicializar', (t) async {
      platform.failCreate = true;
      final launch = await begin(t);
      await expectStillThenApp(t, launch);
    });

    testWidgets('si el video tarda mas de 2,2 s', (t) async {
      expect(musaIntroVideoInitTimeout, const Duration(milliseconds: 2200));
      platform.neverInitialize = true;
      final sw = Stopwatch()..start();
      final launch = await begin(t);
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(2190));
      expect(platform.playCalls, 0);
      await expectStillThenApp(t, launch);
      // El controlador que no llego a iniciar tambien se libera.
      await flush(t);
      expect(platform.disposals, 1);
    });

    testWidgets('el relevo pinta el logo ya listo en el primer fotograma', (
      t,
    ) async {
      final launch = await begin(t, animation: false);
      await t.pumpWidget(MusaIntroGate(launch: launch, child: _app));
      expect(find.byType(RawImage), findsOneWidget);
      await flush(t);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      await t.pumpAndSettle();
      expect(find.byType(MusaIntroOverlay), findsNothing);
    });

    testWidgets('mientras el video se prepara solo hay negro, nunca el logo', (
      t,
    ) async {
      platform.neverInitialize = true;
      final launch = (await t.runAsync(() async {
        final l = MusaIntroLaunch.begin(
          enabled: true,
          variant: 'original',
          stateDirectory: tmp.path,
          refreshRate: 60,
          reduceMotion: false,
        )!;
        await l.still;
        return l;
      }))!;
      expect(launch.readyStill, isNotNull);
      expect(launch.videoSettled, isFalse);
      await t.pumpWidget(MusaIntroGate(launch: launch, child: _app));
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing);
      final black = find.descendant(
        of: find.byType(MusaIntroOverlay),
        matching: find.byWidgetPredicate(
          (w) => w is ColoredBox && w.color == const Color(0xFF000000),
        ),
      );
      expect(black, findsOneWidget);
      await t.runAsync(() => launch.video);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      await t.pumpAndSettle();
      expect(find.byType(MusaIntroOverlay), findsNothing);
      await flush(t);
    });

    testWidgets('al estar listo el video se muestra sin pasar por el logo', (
      t,
    ) async {
      final launch = (await t.runAsync(() async {
        final l = MusaIntroLaunch.begin(
          enabled: true,
          variant: 'original',
          stateDirectory: tmp.path,
          refreshRate: 60,
          reduceMotion: false,
        )!;
        await l.still;
        await l.video;
        return l;
      }))!;
      await t.pumpWidget(MusaIntroGate(launch: launch, child: _app));
      expect(find.byType(RawImage), findsNothing);
      expect(find.byType(VideoPlayer), findsOneWidget);
      platform.finish(1);
      await t.pump();
      await t.pumpAndSettle();
      await flush(t);
    });

    testWidgets('un toque salta el logo quieto', (t) async {
      final launch = await begin(t, animation: false);
      await pumpGate(t, launch);
      await t.tap(find.byType(MusaIntroOverlay));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      await t.pump();
      expect(find.byType(MusaIntroOverlay), findsNothing);
    });

    testWidgets('el arte de cada variante existe y se decodifica', (t) async {
      for (final variant in musaIntroVariants) {
        final still = await t.runAsync(() => MusaIntroStill.load(variant));
        expect(still!.image.width, greaterThan(100), reason: variant);
        still.dispose();
      }
    });
  });

  group('arranque en frio', () {
    test('solo se dispara una vez por proceso', () {
      expect(
        MusaIntroLaunch.begin(
          enabled: true,
          variant: 'chrome',
          stateDirectory: tmp.path,
        ),
        isNotNull,
      );
      expect(
        MusaIntroLaunch.begin(
          enabled: true,
          variant: 'original',
          stateDirectory: tmp.path,
        ),
        isNull,
      );
      expect(platform.creations, 0);
    });

    test('un motor nuevo en el mismo proceso (misma pid) no la repite', () {
      File('${tmp.path}/musa_intro_pid').writeAsStringSync('$pid');
      expect(
        MusaIntroLaunch.begin(
          enabled: true,
          variant: 'original',
          stateDirectory: tmp.path,
        ),
        isNull,
      );
    });

    test('un proceso nuevo (otra pid) la muestra', () {
      File('${tmp.path}/musa_intro_pid').writeAsStringSync('${pid + 1}');
      expect(
        MusaIntroLaunch.begin(
          enabled: true,
          variant: 'chrome',
          stateDirectory: tmp.path,
        ),
        isNotNull,
      );
    });

    test('desactivada en plataformas sin arranque en frio movil', () {
      expect(MusaIntroLaunch.begin(enabled: false), isNull);
    });

    testWidgets('en arranque en caliente no hay video ni capa', (t) async {
      await pumpGate(t, null);
      expect(find.text('APP'), findsOneWidget);
      expect(find.byType(MusaIntroOverlay), findsNothing);
      expect(find.byType(VideoPlayer), findsNothing);
      expect(platform.creations, 0);
    });
  });

  group('ajustes', () {
    test('por defecto: animacion activada y sonido desactivado', () {
      const s = AppSettings();
      expect(s.startupAnimation, isTrue);
      expect(s.startupSound, isFalse);
      final back = AppSettings.fromJson(
        jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>,
      );
      expect(back.startupAnimation, isTrue);
      expect(back.startupSound, isFalse);
      // Ajustes guardados antes de existir estas claves.
      final old = AppSettings.fromJson(const {});
      expect(old.startupAnimation, isTrue);
      expect(old.startupSound, isFalse);
    });

    test('se guardan y se leen en el siguiente arranque', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer(
        overrides: [
          initialSettingsProvider.overrideWithValue(const AppSettings()),
        ],
      );
      addTearDown(container.dispose);
      container.read(settingsProvider.notifier)
        ..setStartupAnimation(false)
        ..setStartupSound(true);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(settingsProvider).startupAnimation, isFalse);
      expect(container.read(settingsProvider).startupSound, isTrue);
      final prefs = await SharedPreferences.getInstance();
      final loaded = loadBootstrapSettings(prefs);
      expect(loaded.startupAnimation, isFalse);
      expect(loaded.startupSound, isTrue);
    });
  });
}
