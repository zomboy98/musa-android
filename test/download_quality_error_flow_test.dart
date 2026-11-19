// These flows were reached from the rows of the visible download queue,
// which was removed from the interface on 2026-11-13. Re-enable them when
// the recovery dialog is offered from the per-song download icon.
@Skip('Visible download queue removed; recovery dialog has no entry yet')
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/download_item.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/download_queue_provider.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/screens/queue_tab.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Queue extends DownloadQueueNotifier {
  _Queue({this.errorType});
  final DownloadErrorType? errorType;
  String? retriedId;
  String? retriedQuality;
  @override
  DownloadQueueState build() => const DownloadQueueState().copyWith(items: [DownloadItem(
    id: 'item-b', service: 'B', status: DownloadStatus.failed,
    error: errorType == null
        ? 'Bad state: Select a download quality for this provider in settings'
        : 'https://diagnostic-canary.invalid/?token=secret',
    errorType: errorType,
    track: const Track(id: 'track', name: 'Canción', artistName: 'Artista', albumName: 'Álbum', duration: 100),
    createdAt: DateTime.utc(2026),
  )]);
  @override
  Future<void> retryItemWithQuality(String id, String quality) async {
    retriedId = id;
    retriedQuality = quality;
  }
}

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() => const AppSettings(defaultService: 'a', audioQuality: 'a1');
  @override
  void setAudioQualityForProvider(String provider, String quality, {QualityOption? option}) {
    state = state.copyWith(downloadQualityByProvider: {...state.downloadQualityByProvider, provider: quality});
  }
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(extensions: [Extension(
    id: 'b', name: 'b', displayName: 'Fuente B', version: '1', description: '',
    enabled: true, status: 'loaded', hasDownloadProvider: true,
    qualityOptions: [
      QualityOption(id: ' b1 ', label: 'Calidad B'),
      QualityOption(id: 'B1', label: 'Calidad duplicada'),
    ],
  )]);
}

class _UnavailableExtensions extends ExtensionNotifier {
  _UnavailableExtensions(this.absent);
  final bool absent;
  @override
  ExtensionState build() => ExtensionState(extensions: absent ? [] : [const Extension(
    id: 'b', name: 'b', displayName: 'Fuente B', version: '1', description: '',
    enabled: true, status: 'loaded', hasDownloadProvider: true,
    qualityOptions: [QualityOption(id: '  ', label: 'Sin ID')],
  )]);
}

void main() {
  testWidgets('queue localizes a typed subscription failure safely', (tester) async {
    final container = ProviderContainer(overrides: [
      downloadQueueProvider.overrideWith(
        () => _Queue(errorType: DownloadErrorType.subscriptionRequired),
      ),
      settingsProvider.overrideWith(_Settings.new),
      extensionProvider.overrideWith(_Extensions.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        locale: Locale('es'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: QueueTab(librarySection: 'downloads')),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Se requiere una suscripción al proveedor'), findsOneWidget);
    expect(find.textContaining('diagnostic-canary'), findsNothing);
  });

  for (final absent in [true, false]) {
    testWidgets(absent ? 'fuente ausente informa al usuario' : 'opciones inválidas informan al usuario', (tester) async {
      final queue = _Queue();
      final container = ProviderContainer(overrides: [
        downloadQueueProvider.overrideWith(() => queue),
        settingsProvider.overrideWith(_Settings.new),
        extensionProvider.overrideWith(() => _UnavailableExtensions(absent)),
      ]);
      addTearDown(container.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(
        locale: Locale('es'), localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: QueueTab(librarySection: 'downloads')),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Reintentar').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elegir calidad'));
      await tester.pumpAndSettle();
      expect(find.text('La fuente o sus opciones de calidad ya no están disponibles.'), findsOneWidget);
      expect(queue.retriedId, isNull);
    });
  }
  for (final choose in [true, false]) {
    testWidgets(choose ? 'elige calidad y reintenta la fuente correcta' : 'cancelar no modifica preferencias ni reintenta', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final queue = _Queue();
      final container = ProviderContainer(overrides: [
        downloadQueueProvider.overrideWith(() => queue),
        initialSettingsProvider.overrideWithValue(const AppSettings(defaultService: 'a', audioQuality: 'a1')),
        extensionProvider.overrideWith(_Extensions.new),
      ]);
      addTearDown(container.dispose);
      await tester.runAsync(() => container.read(settingsProvider.notifier).ensureLoaded());
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: const MaterialApp(
        locale: Locale('es'), localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: QueueTab(librarySection: 'downloads')),
      )));
      await tester.pumpAndSettle();
      expect(find.text('Selecciona una calidad de descarga para Fuente B.'), findsOneWidget);
      await tester.tap(find.byTooltip('Reintentar').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elegir calidad'));
      await tester.pumpAndSettle();
      expect(find.text('Calidad duplicada'), findsNothing);
      if (choose) {
        await tester.tap(find.text('Calidad B'));
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).downloadQualityByProvider['b'], 'b1');
        await tester.runAsync(() async => Future<void>.delayed(const Duration(milliseconds: 30)));
        expect(loadBootstrapSettings(await SharedPreferences.getInstance()).downloadQualityByProvider['b'], 'b1');
        expect(queue.retriedId, 'item-b');
        expect(queue.retriedQuality, 'b1');
      } else {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(container.read(settingsProvider).downloadQualityByProvider, isEmpty);
        expect(queue.retriedId, isNull);
      }
    });
  }
}
