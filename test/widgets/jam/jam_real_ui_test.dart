import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/jam/jam_app_controller.dart';
import 'package:mornye/services/jam/jam_invitation_codec.dart';
import 'package:mornye/services/local_network_access.dart';
import 'package:mornye/widgets/jam/jam_library_app_view.dart';

void main() {
  testWidgets(
    'internal host and guest pair over TLS and share a chosen track',
    (tester) async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      final network = LocalNetworkAccess(isAndroid: false);
      final host = JamAppController(networkAccess: network);
      final guest = JamAppController(networkAccess: network);
      final navigator = GlobalKey<NavigatorState>();
      final item = LocalLibraryItem(
        id: 'song',
        trackName: 'Luna',
        artistName: 'Sol',
        albumName: 'Cielo',
        filePath: r'C:\private\song.flac',
        scannedAt: DateTime(2026),
        isrc: 'USABC1234567',
      );
      Widget page(JamAppController controller) =>
          Scaffold(body: JamLibraryAppView(controller: controller));

      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsProvider.overrideWith(() => _Settings()),
            jamLibraryPageLoaderProvider.overrideWithValue(
              (_) async => QueueLibraryDbPage(
                rows: [
                  {'source': 'local', 'item': item.toJson()},
                ],
                nextCursor: null,
              ),
            ),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('es'),
            navigatorKey: navigator,
            home: page(host),
          ),
        ),
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Dirección IPv4 local'),
        '127.0.0.1',
      );
      await tester.runAsync(() async {
        final hosted = _waitFor(host, () => host.phase == JamAppPhase.hosting);
        await tester.tap(find.widgetWithText(FilledButton, 'Crear sesión'));
        await hosted;
      });
      await tester.pump();
      expect(find.text('Anfitrión'), findsOneWidget);
      final invitation = JamInvitationCodec.encode(host.invitation!);

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page(guest)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Invitación'),
        invitation,
      );
      await tester.runAsync(() async {
        final joined = _waitFor(
          guest,
          () => guest.phase == JamAppPhase.connected,
        );
        await tester.tap(find.widgetWithText(OutlinedButton, 'Unirse'));
        await joined;
      });
      await tester.pump();
      expect(find.text('Invitado'), findsOneWidget);
      await tester.ensureVisible(find.text('Añadir a la cola'));
      await tester.runAsync(() async {
        await tester.tap(find.text('Añadir a la cola'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Luna'), findsOneWidget);
        final updated = _waitFor(
          host,
          () => host.snapshot?.entries.isNotEmpty ?? false,
        );
        await tester.tap(find.text('Luna'));
        await tester.pump(const Duration(milliseconds: 300));
        await updated;
        await _waitFor(
          guest,
          () => guest.snapshot?.entries.isNotEmpty ?? false,
        );
      });
      await tester.pump();
      expect(host.snapshot!.entries, hasLength(1));
      expect(guest.snapshot!.entries, hasLength(1));
      expect(find.text('Luna'), findsOneWidget);

      await tester.runAsync(() async {
        final closed = _waitFor(host, () => host.phase == JamAppPhase.idle);
        await host.close();
        await guest.close();
        await closed;
        await _waitFor(guest, () => guest.phase == JamAppPhase.idle);
      });
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Future<void> _waitFor(
  JamAppController controller,
  bool Function() ready,
) async {
  if (ready()) return;
  final done = Completer<void>();
  void listener() {
    if (ready() && !done.isCompleted) done.complete();
    if (controller.phase == JamAppPhase.error && !done.isCompleted) {
      done.completeError(StateError('Jam failed: ${controller.error}'));
    }
  }

  controller.addListener(listener);
  try {
    listener();
    await done.future.timeout(const Duration(seconds: 10));
  } finally {
    controller.removeListener(listener);
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => AppSettings(localLibraryEnabled: true);
}
