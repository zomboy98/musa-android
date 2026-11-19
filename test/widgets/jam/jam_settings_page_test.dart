import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/screens/settings/jam_settings_page.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';

void main() {
  testWidgets('Jam is unavailable and offers no session controls', (
    tester,
  ) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: JamSettingsPage(tabActive: active),
        ),
      ),
    );
    expect(
      find.textContaining('Jam está temporalmente desactivado'),
      findsOneWidget,
    );
    expect(find.text('Crear sesión'), findsNothing);
    expect(find.text('Unirse'), findsNothing);
    expect(find.text('Conectar cola al reproductor local'), findsNothing);
  });
  testWidgets(
    'host playback requires an explicit action and reports unavailable player',
    (tester) async {
      final controller = _RecordingController();
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            jamControllerFactoryProvider.overrideWithValue(() => controller),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            home: JamSettingsPage(tabActive: active),
          ),
        ),
      );
      expect(find.text('Conectar cola al reproductor local'), findsOneWidget);
      expect(find.textContaining('No se pudo conectar:'), findsNothing);
      await tester.tap(find.text('Conectar cola al reproductor local'));
      await tester.pump();
      expect(find.textContaining('No se pudo conectar:'), findsOneWidget);
      expect(find.text('Reproductor local conectado'), findsNothing);
    },
  );

  testWidgets('leaving the settings tab closes the session', (tester) async {
    final controller = _RecordingController();
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jamControllerFactoryProvider.overrideWithValue(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: JamSettingsPage(tabActive: active),
        ),
      ),
    );
    active.value = false;
    await tester.pump();
    expect(controller.closeCalls, 1);
    expect(controller.phase, JamAppPhase.idle);
  });

  testWidgets('a new session does not show an earlier connection error', (
    tester,
  ) async {
    final controller = _RecordingController();
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jamControllerFactoryProvider.overrideWithValue(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: JamSettingsPage(tabActive: active),
        ),
      ),
    );
    await tester.tap(find.text('Conectar cola al reproductor local'));
    await tester.pump();
    expect(find.textContaining('No se pudo conectar:'), findsOneWidget);
    controller.nextSession();
    await tester.pump();
    expect(find.textContaining('No se pudo conectar:'), findsNothing);
  });

  testWidgets('playback status follows reconciliation and permits retry', (
    tester,
  ) async {
    final controller = _RecordingController();
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jamControllerFactoryProvider.overrideWithValue(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: JamSettingsPage(tabActive: active),
        ),
      ),
    );
    controller.setPlaybackState(JamPlaybackState.pending);
    await tester.pump();
    expect(find.text('Sincronizando con el reproductor…'), findsOneWidget);
    expect(find.text('Reproductor local conectado'), findsNothing);
    controller.setPlaybackState(JamPlaybackState.error);
    await tester.pump();
    await tester.tap(find.text('Reintentar sincronización'));
    await tester.pump();
    expect(controller.retryCalls, 1);
    expect(find.text('Sincronizando con el reproductor…'), findsOneWidget);
    controller.setPlaybackState(JamPlaybackState.synchronized);
    await tester.pump();
    expect(find.text('Reproductor local conectado'), findsOneWidget);
  });

  testWidgets('disposing the page closes the session', (tester) async {
    final controller = _RecordingController();
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          jamControllerFactoryProvider.overrideWithValue(() => controller),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: JamSettingsPage(tabActive: active),
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());
    expect(controller.closeCalls, 1);
  });
}

class _RecordingController extends JamAppController {
  _RecordingController() {
    phase = JamAppPhase.hosting;
  }
  int closeCalls = 0;
  int _generation = 0;
  @override
  int get sessionGeneration => _generation;
  void nextSession() {
    _generation++;
    notifyListeners();
  }

  int retryCalls = 0;
  void setPlaybackState(JamPlaybackState state) {
    playbackState = state;
    notifyListeners();
  }

  @override
  bool retryHostPlayback() {
    retryCalls++;
    setPlaybackState(JamPlaybackState.pending);
    return true;
  }

  @override
  Future<void> close() {
    closeCalls++;
    return super.close();
  }
}
