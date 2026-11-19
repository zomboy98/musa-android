import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/extension_auth_launcher.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/providers/track_provider.dart';
import 'package:mornye/services/platform_bridge.dart';
import 'package:mornye/services/provider_session_preparer.dart';
import 'package:mornye/utils/desktop_platform.dart';

import 'support/fixed_settings.dart';

SessionRenewalResult _valid(DateTime expiry) => SessionRenewalResult(
  status: SessionRenewalStatus.validUntil,
  expiresAt: expiry.toUtc().toIso8601String(),
);
const _missing = SessionRenewalResult(status: SessionRenewalStatus.missing);

class _Harness {
  _Harness() {
    preparer = ProviderSessionPreparer(
      renew: (id) async {
        renews.add(id);
        return sessions[id];
      },
      verify: (id, cancelled) async {
        verifies.add(id);
        final outcome = verifyOutcome[id] ?? ProviderSessionOutcome.granted;
        if (outcome == ProviderSessionOutcome.granted) {
          sessions[id] = _valid(now.add(const Duration(hours: 5)));
        }
        return outcome;
      },
      canRun: () => foreground,
      delay: (d) async {
        pauses.add(d);
        now = now.add(d);
      },
      now: () => now,
      onStatus: (id, status, failed) =>
          statuses.add('$id:${failed ? 'error' : status?.name}'),
      onPass: (event, n) => passes.add('$event:$n'),
    );
  }

  late final ProviderSessionPreparer preparer;
  DateTime now = DateTime.utc(2026, 11, 13, 12);
  bool foreground = true;
  final sessions = <String, SessionRenewalResult?>{};
  final verifyOutcome = <String, ProviderSessionOutcome>{};
  final renews = <String>[];
  final verifies = <String>[];
  final pauses = <Duration>[];
  final statuses = <String>[];
  final passes = <String>[];
}

class _FakeExtensions extends ExtensionNotifier {
  _FakeExtensions(this.harness);
  final _Harness harness;

  @override
  ExtensionState build() => const ExtensionState(isInitialized: true);

  @override
  ProviderSessionPreparer get sessionPreparer => harness.preparer;

  @override
  Future<void> runBackgroundSessionPass({bool force = false}) =>
      harness.preparer.run(['sample'], force: force);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProviderSessionPreparer', () {
    test(
      'arranque: verifica en serie y en orden, con pausa entre proveedores',
      () async {
        final h = _Harness();
        final order = ['default', 'second', 'third'];
        for (final id in order) {
          h.sessions[id] = _missing;
        }
        final pass = h.preparer.run(order, force: true);
        // No bloquea: run() devuelve un Future y el llamador sigue de inmediato.
        var continued = false;
        unawaited(Future<void>.microtask(() => continued = true));
        expect(h.preparer.running, isTrue);
        await pass;
        expect(continued, isTrue);
        expect(h.verifies, order);
        expect(h.pauses, hasLength(2), reason: 'pausa entre proveedores');
        expect(h.pauses.every((d) => d >= const Duration(seconds: 1)), isTrue);
      },
    );

    test('no re-verifica ni consulta sesiones vigentes', () async {
      final h = _Harness();
      h.sessions['a'] = _valid(h.now.add(const Duration(hours: 4)));
      await h.preparer.run(['a'], force: true);
      expect(h.verifies, isEmpty);
      h.renews.clear();
      h.now = h.now.add(const Duration(minutes: 5));
      await h.preparer.run(['a'], force: true);
      expect(h.renews, isEmpty, reason: 'vigente y lejos de vencer');
      expect(h.verifies, isEmpty);
    });

    test(
      'por vencer: solo consulta/renueva sin challenge, no verifica',
      () async {
        final h = _Harness();
        h.sessions['a'] = _valid(h.now.add(const Duration(minutes: 10)));
        await h.preparer.run(['a'], force: true);
        expect(h.renews, ['a']);
        expect(h.verifies, isEmpty);
        expect(h.preparer.nextDue(), isNotNull);
      },
    );

    test('expirada o inexistente pide sesión nueva', () async {
      final h = _Harness();
      h.sessions['expired'] = const SessionRenewalResult(
        status: SessionRenewalStatus.invalid,
      );
      h.sessions['none'] = _missing;
      await h.preparer.run(['expired', 'none'], force: true);
      expect(h.verifies, ['expired', 'none']);
    });

    test('al reanudar reintenta solo las faltantes, sin ráfagas', () async {
      final h = _Harness();
      h.sessions['a'] = _missing;
      h.sessions['b'] = _missing;
      h.verifyOutcome['b'] = ProviderSessionOutcome.failed;
      await h.preparer.run(['a', 'b'], force: true);
      expect(h.verifies, ['a', 'b']);
      h.verifies.clear();
      // Reanudar enseguida: intervalo mínimo entre pasadas -> nada.
      await h.preparer.run(['a', 'b']);
      expect(h.verifies, isEmpty);
      // Pasada forzada dentro del enfriamiento de fallo: b no se reintenta.
      await h.preparer.run(['a', 'b'], force: true);
      expect(h.verifies, isEmpty);
      // Pasado el enfriamiento: solo b (a ya está vigente).
      h.now = h.now.add(const Duration(minutes: 3));
      h.verifyOutcome['b'] = ProviderSessionOutcome.granted;
      await h.preparer.run(['a', 'b']);
      expect(h.verifies, ['b']);
    });

    test('panel ocupado corta la pasada; segundo plano la cancela', () async {
      final h = _Harness();
      h.sessions['a'] = _missing;
      h.sessions['b'] = _missing;
      h.verifyOutcome['a'] = ProviderSessionOutcome.busy;
      await h.preparer.run(['a', 'b'], force: true);
      expect(h.verifies, ['a']);
      final h2 = _Harness();
      h2.sessions['a'] = _missing;
      h2.foreground = false;
      await h2.preparer.run(['a'], force: true);
      expect(h2.renews, isEmpty);
      expect(h2.verifies, isEmpty);
    });

    test('proveedor sin sesión firmada no se verifica', () async {
      final h = _Harness();
      h.sessions['n/a'] = const SessionRenewalResult(
        status: SessionRenewalStatus.notApplicable,
      );
      await h.preparer.run(['n/a'], force: true);
      expect(h.verifies, isEmpty);
    });

    test('bloqueado pide verificación y respeta el enfriamiento', () async {
      final h = _Harness();
      h.sessions['blocked'] = const SessionRenewalResult(
        status: SessionRenewalStatus.blocked,
      );
      h.verifyOutcome['blocked'] = ProviderSessionOutcome.failed;
      await h.preparer.run(['blocked'], force: true);
      expect(h.verifies, ['blocked']);
      await h.preparer.run(['blocked'], force: true);
      expect(h.verifies, ['blocked']);
    });

    test('no disponible no verifica y reprograma la consulta', () async {
      final h = _Harness();
      h.sessions['u'] = const SessionRenewalResult(
        status: SessionRenewalStatus.unavailable,
      );
      await h.preparer.run(['u'], force: true);
      expect(h.verifies, isEmpty);
      expect(h.preparer.nextDue(), h.now.add(const Duration(minutes: 10)));
      h.now = h.now.add(const Duration(minutes: 10));
      h.sessions['u'] = const SessionRenewalResult(
        status: SessionRenewalStatus.invalid,
      );
      await h.preparer.run(['u'], force: true);
      expect(h.verifies, ['u']);
    });

    test('trazas del planificador', () async {
      final h = _Harness();
      h.sessions['a'] = _valid(h.now.add(const Duration(hours: 5)));
      h.sessions['b'] = const SessionRenewalResult(
        status: SessionRenewalStatus.unavailable,
      );
      await h.preparer.run(['a', 'b'], force: true);
      expect(h.passes, ['started:2', 'finished:2']);
      expect(h.statuses, ['a:validUntil', 'b:unavailable']);
      final h2 = _Harness();
      h2.foreground = false;
      await h2.preparer.run(['a', 'b'], force: true);
      expect(h2.passes, ['started:2', 'not_runnable:2']);
    });

    test('orden: por defecto, prioridad, resto; sin YouTube/SoundCloud', () {
      ({String id, bool enabled, bool loaded, bool download}) e(
        String id, {
        bool enabled = true,
        bool download = true,
      }) => (id: id, enabled: enabled, loaded: true, download: download);
      final ids = orderedSessionProviders(
        defaultService: 'Default',
        priority: ['third', 'second', 'default'],
        extensions: [
          e('second'),
          e('third'),
          e('default'),
          e('zeta'),
          e('off', enabled: false),
          e('soundcloud'),
          e('youtube'),
          e('ytmusic-spotiflac'),
          e('meta-only', download: false),
        ],
      );
      expect(ids, ['default', 'third', 'second', 'zeta']);
    });
  });

  group('búsqueda sin sesión', () {
    const backendChannel = MethodChannel('com.zarz.mornye/backend');
    const panelChannel = MethodChannel('com.zarz.mornye/verification_panel');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(backendChannel, null);
      messenger.setMockMethodCallHandler(panelChannel, null);
      debugDefaultTargetPlatformOverride = null;
      debugDesktopPlatformOverride = null;
    });

    test(
      'no abre panel ni consulta verificación; el planificador la obtiene y '
      'la búsqueda se completa sola',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        debugDesktopPlatformOverride = false;
        var searches = 0;
        final calls = <String>[];
        messenger.setMockMethodCallHandler(backendChannel, (call) async {
          calls.add(call.method);
          if (call.method == 'customSearchWithExtension') {
            searches++;
            if (searches == 1) {
              throw PlatformException(
                code: 'ERROR',
                message:
                    "verification_required: extension 'sample' VERIFY_REQUIRED",
              );
            }
            return [
              {'id': 't1', 'name': 'Track', 'artist_name': 'Artist'},
            ];
          }
          return null;
        });
        var panelOpens = 0;
        messenger.setMockMethodCallHandler(panelChannel, (call) async {
          panelOpens++;
          return 'granted';
        });
        final harness = _Harness()..sessions['sample'] = _missing;
        final container = ProviderContainer(
          overrides: [
            settingsProvider.overrideWith(FixedSettingsNotifier.new),
            extensionProvider.overrideWith(() => _FakeExtensions(harness)),
          ],
        );
        addTearDown(container.dispose);
        container.read(extensionProvider);
        await container
            .read(trackProvider.notifier)
            .customSearch('sample', 'q');
        // Inmediato: sin error, sin spinner, sin verificación propia.
        var state = container.read(trackProvider);
        expect(state.error, isNull);
        expect(state.isLoading, isFalse);
        expect(panelOpens, 0);
        expect(calls, isNot(contains('getExtensionPendingAuth')));
        // El planificador de fondo (único que verifica) obtiene la sesión y
        // la búsqueda se reintenta sola, sin intervención del usuario.
        for (var i = 0; i < 30; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(harness.verifies, ['sample']);
        state = container.read(trackProvider);
        expect(state.error, isNull);
        expect(state.tracks.single.id, 't1');
        expect(panelOpens, 0);
      },
    );
  });

  test('la UI no contiene diálogos, avisos ni hojas de verificación', () {
    final forbidden = RegExp(
      r'showExtensionVerificationHelpDialog|showExtensionVerificationUnavailable|'
      r'showVerificationRequired|resolveExtensionVerification|'
      r'openVerificationAndAwaitGrant|_prepareDownloadProvidersForSearch|'
      r'extensionVerificationHelp|extensionVerificationUnavailable',
    );
    final offenders = <String>[];
    for (final dir in ['lib/screens', 'lib/widgets']) {
      for (final file in Directory(dir).listSync(recursive: true)) {
        if (file is! File || !file.path.endsWith('.dart')) continue;
        if (forbidden.hasMatch(file.readAsStringSync())) {
          offenders.add(file.path);
        }
      }
    }
    expect(offenders, isEmpty);
    // Con verificación embebida el launcher no ofrece ayuda manual ni avisos.
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugDesktopPlatformOverride = false;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugDesktopPlatformOverride = null;
    });
    if (embeddedExtensionVerificationEnabled) {
      expect(extensionVerificationIsSilent, isTrue);
      expect(
        scheduleExtensionVerificationHelpDialog(
          'p',
          Uri.parse('https://example.invalid/v'),
        ),
        isNull,
      );
      expect(() => showExtensionVerificationUnavailable('p'), returnsNormally);
    }
  });
}
