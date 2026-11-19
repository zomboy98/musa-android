import 'dart:async';
import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_guest_client.dart';
import 'package:mornye/services/jam/jam_invitation_codec.dart';
import 'package:mornye/services/jam/jam_queue.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/widgets/jam/jam_app_view.dart';

class _CurrentPlayingController extends JamAppController {
  @override
  Future<JamOutcome> remove({
    required String occurrenceId,
    String? commandId,
    int? revision,
  }) async => JamOutcome.currentPlaying;
}

void main() {
  testWidgets('session error does not expose internal details', (tester) async {
    final controller = JamAppController()
      ..error = StateError(r'C:\private\secret-token');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    expect(find.text('No se pudo completar la acción.'), findsOneWidget);
    expect(find.textContaining('private'), findsNothing);
    expect(find.textContaining('secret-token'), findsNothing);
  });
  for (final scenario in ['success', 'error', 'cancel', 'changed']) {
    testWidgets('host selection $scenario', (tester) async {
      final pending = Completer<PlayableMedia?>();
      final controller = _HostController()..fail = scenario == 'error';
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(
            body: JamAppView(
              controller: controller,
              selectHostMedia: (_) => pending.future,
              trackTitle: (_) => 'Canción del anfitrión',
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Añadir a la cola'));
      await tester.tap(find.text('Añadir a la cola'));
      await tester.pump();
      if (scenario == 'changed') controller.testGeneration++;
      pending.complete(
        scenario == 'cancel'
            ? null
            : PlayableMedia(
                id: 'local',
                source: r'C:\private\song.mp3',
                title: 'Song',
                artist: 'Artist',
                album: 'Album',
              ),
      );
      await tester.pumpAndSettle();
      expect(
        controller.calls,
        scenario == 'cancel' || scenario == 'changed' ? 0 : 1,
      );
      if (scenario == 'success')
        expect(find.text('Canción del anfitrión'), findsOneWidget);
      if (scenario == 'error')
        expect(find.text('No se pudo completar la acción.'), findsOneWidget);
      expect(find.textContaining('private'), findsNothing);
    });
  }
  for (final phase in [JamAppPhase.hosting, JamAppPhase.connected]) {
    testWidgets('pending track cannot be removed in $phase', (tester) async {
      final controller = JamAppController()
        ..phase = phase
        ..snapshot = JamGuestSnapshot(
          revision: 1,
          guestEditingEnabled: true,
          pendingOccurrenceId: 'one',
          entries: [const JamEntry(occurrenceId: 'one', trackId: 'song')],
        );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: JamAppView(controller: controller)),
        ),
      );
      expect(
        find.text('Pista pendiente del reproductor · No se puede quitar'),
        findsOneWidget,
      );
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip ==
                  'No se puede quitar la pista pendiente del reproductor',
        ),
      );
      expect(button.onPressed, isNull);
    });
    testWidgets('current track cannot be removed in $phase', (tester) async {
      final controller = JamAppController()
        ..phase = phase
        ..snapshot = JamGuestSnapshot(
          revision: 1,
          guestEditingEnabled: true,
          currentOccurrenceId: 'one',
          entries: [const JamEntry(occurrenceId: 'one', trackId: 'song')],
        );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: JamAppView(controller: controller)),
        ),
      );
      expect(find.text('Pista actual · No se puede quitar'), findsOneWidget);
      final button = tester.widget<IconButton>(
        find.byWidgetPredicate(
          (widget) =>
              widget is IconButton &&
              widget.tooltip == 'No se puede quitar la pista actual',
        ),
      );
      expect(button.onPressed, isNull);
    });
  }

  testWidgets('explains concurrent current track rejection', (tester) async {
    final controller = _CurrentPlayingController()
      ..phase = JamAppPhase.connected
      ..snapshot = JamGuestSnapshot(
        revision: 1,
        guestEditingEnabled: true,
        entries: [const JamEntry(occurrenceId: 'one', trackId: 'song')],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('Quitar'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Quitar').last);
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No se puede quitar una pista actual o pendiente del reproductor.',
      ),
      findsOneWidget,
    );
  });
  testWidgets('equivalent poll permits pending selection', (tester) async {
    final pending = Completer<String?>();
    final controller = _RecordingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(
          body: JamAppView(
            controller: controller,
            selectTrack: (_) => pending.future,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Añadir a la cola'));
    await tester.pump();
    controller.snapshot = JamGuestSnapshot(
      revision: 1,
      guestEditingEnabled: false,
      entries: [],
    );
    pending.complete('track');
    await tester.pump();
    expect(controller.addCalls, 1);
  });

  testWidgets('new generation on same controller discards selection', (
    tester,
  ) async {
    final pending = Completer<String?>();
    final controller = _RecordingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(
          body: JamAppView(
            controller: controller,
            selectTrack: (_) => pending.future,
          ),
        ),
      ),
    );
    await tester.tap(find.text('Añadir a la cola'));
    await tester.pump();
    controller.testGeneration++;
    controller.snapshot = JamGuestSnapshot(
      revision: 1,
      guestEditingEnabled: false,
      entries: [],
    );
    pending.complete('track');
    await tester.pump();
    expect(controller.addCalls, 0);
  });
  testWidgets('pending selection cannot be added to a replacement session', (
    tester,
  ) async {
    final pending = Completer<String?>();
    final first = _RecordingController();
    final second = _RecordingController();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    Widget view(_RecordingController controller) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('es'),
      home: Scaffold(
        body: JamAppView(
          controller: controller,
          selectTrack: (_) => pending.future,
        ),
      ),
    );
    await tester.pumpWidget(view(first));
    await tester.tap(find.text('Añadir a la cola'));
    await tester.pump();
    await tester.pumpWidget(view(second));
    pending.complete('track');
    await tester.pump();
    expect(first.addCalls, 0);
    expect(second.addCalls, 0);
  });
  testWidgets('selector is guarded and its errors are reported', (
    tester,
  ) async {
    final pending = Completer<String?>();
    var calls = 0;
    final controller = JamAppController()
      ..phase = JamAppPhase.connected
      ..snapshot = JamGuestSnapshot(
        revision: 1,
        guestEditingEnabled: false,
        entries: [],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(
          body: JamAppView(
            controller: controller,
            selectTrack: (_) {
              calls++;
              return pending.future;
            },
          ),
        ),
      ),
    );
    final add = find.text('Añadir a la cola');
    await tester.tap(add);
    await tester.tap(add);
    await tester.pump();
    expect(calls, 1);
    pending.completeError(StateError('private details'));
    await tester.pump();
    expect(find.text('No se pudo completar la acción.'), findsOneWidget);
    expect(find.textContaining('private details'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('shows a sanitized playback synchronization error', (
    tester,
  ) async {
    final controller = JamAppController()
      ..phase = JamAppPhase.hosting
      ..playbackError = StateError('private-track-id');
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    expect(
      find.textContaining('No se pudo sincronizar la cola de Jam'),
      findsOneWidget,
    );
    expect(find.textContaining('private-track-id'), findsNothing);
    final semantics = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.textContaining('No se pudo sincronizar la cola de Jam'),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(semantics.properties.liveRegion, isTrue);
  });
  testWidgets('invitation disappears and cannot be copied after expiry', (
    tester,
  ) async {
    var now = DateTime(2026, 1, 1, 12);
    final controller = JamAppController()
      ..phase = JamAppPhase.hosting
      ..invitation = JamInvitation(
        endpoint: Uri.parse('https://127.0.0.1:1234'),
        certificateSha256: 'a' * 64,
        grant: 'A' * 43,
      )
      ..invitationExpiresAt = now.add(const Duration(seconds: 2));
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(
          body: JamAppView(controller: controller, now: () => now),
        ),
      ),
    );
    expect(find.text('Copiar invitación'), findsOneWidget);
    expect(find.textContaining('Caduca a las'), findsOneWidget);
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Copiar invitación'), findsNothing);
    expect(find.text('Invitación caducada o no disponible.'), findsOneWidget);
    expect(find.text('Generar invitación'), findsOneWidget);
  });
  testWidgets('rejects invalid invitation before connecting', (tester) async {
    final controller = JamAppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Invitación'),
      'invalid',
    );
    await tester.ensureVisible(find.text('Unirse'));
    await tester.tap(find.text('Unirse'));
    await tester.pump();
    expect(find.text('La invitación no es válida.'), findsOneWidget);
    expect(controller.phase, JamAppPhase.idle);
  });

  testWidgets('guest sees authoritative queue without forbidden controls', (
    tester,
  ) async {
    final controller = JamAppController()
      ..phase = JamAppPhase.connected
      ..snapshot = JamGuestSnapshot(
        revision: 1,
        guestEditingEnabled: false,
        entries: [const JamEntry(occurrenceId: 'one', trackId: 'track-1')],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    expect(find.text('track-1'), findsOneWidget);
    expect(find.byTooltip('Quitar'), findsNothing);
    expect(find.text('Añadir a la cola'), findsOneWidget);
    expect(find.text('Salir de la sesión'), findsOneWidget);
    expect(
      find.textContaining('selector de canciones compartibles'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Añadir a la cola'),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('queue removal asks for confirmation and can be cancelled', (
    tester,
  ) async {
    final controller = JamAppController()
      ..phase = JamAppPhase.connected
      ..snapshot = JamGuestSnapshot(
        revision: 1,
        guestEditingEnabled: true,
        entries: [const JamEntry(occurrenceId: 'one', trackId: 'track-1')],
      );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: Scaffold(body: JamAppView(controller: controller)),
      ),
    );
    await tester.tap(find.byTooltip('Quitar'));
    await tester.pumpAndSettle();
    expect(find.text('¿Quitar “track-1” de la sesión?'), findsOneWidget);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(controller.snapshot!.entries, hasLength(1));
  });
}

class _HostController extends JamAppController {
  _HostController() {
    phase = JamAppPhase.hosting;
    snapshot = JamGuestSnapshot(
      revision: 1,
      guestEditingEnabled: false,
      entries: [],
    );
  }
  int testGeneration = 0;
  int calls = 0;
  bool fail = false;
  @override
  int get sessionGeneration => testGeneration;
  @override
  Future<JamResult> addHostMedia(PlayableMedia media) async {
    calls++;
    if (fail) throw StateError(media.source);
    snapshot = JamGuestSnapshot(
      revision: 2,
      guestEditingEnabled: false,
      entries: [
        const JamEntry(occurrenceId: 'one', trackId: 'jamhost1:opaque'),
      ],
    );
    notifyListeners();
    return JamResult(JamQueue(hostId: 'host'), JamOutcome.applied);
  }
}

class _RecordingController extends JamAppController {
  _RecordingController() {
    phase = JamAppPhase.connected;
    snapshot = JamGuestSnapshot(
      revision: 1,
      guestEditingEnabled: false,
      entries: [],
    );
  }
  int addCalls = 0;
  int testGeneration = 0;
  @override
  int get sessionGeneration => testGeneration;
  @override
  Future<JamOutcome> add({
    required String trackId,
    int? revision,
    String? commandId,
    String? occurrenceId,
  }) async {
    addCalls++;
    return JamOutcome.applied;
  }
}
