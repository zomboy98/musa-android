import 'package:flutter/material.dart';
import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/widgets/playback_provider_setup.dart';

class _Settings extends SettingsNotifier {
  @override
  AppSettings build() =>
      const AppSettings(playerMode: 'external', audioQuality: '');
  @override
  void setDefaultService(String value) =>
      state = state.copyWith(defaultService: value);
  @override
  bool setDefaultDownloadExtension(Extension value, {bool confirmed = false}) {
    state = state.copyWith(
      defaultService: value.id,
      playbackProviderConfirmed: confirmed,
    );
    return true;
  }

  @override
  void setPlaybackQuality(String value) =>
      state = state.copyWith(playbackQuality: value);
  @override
  void setAudioQuality(String value) =>
      state = state.copyWith(audioQuality: value);
  @override
  void setPlaybackCacheBitrate(String value) =>
      state = state.copyWith(playbackCacheBitrate: value);
}

class _RejectingSettings extends _Settings {
  @override
  bool setDefaultDownloadExtension(Extension value, {bool confirmed = false}) =>
      false;
}

class _Extensions extends ExtensionNotifier {
  _Extensions(
    this.available, {
    this.enabled = true,
    this.fail = false,
    this.breakOnEnable = false,
    this.restoreEmpty = false,
    this.status = 'loaded',
    this.id = 'example',
    this.qualityOptions = const [
      QualityOption(id: 'low', label: 'Low quality'),
      QualityOption(id: 'high', label: 'High quality'),
    ],
  });
  final bool available;
  final bool enabled;
  final bool fail;
  final bool breakOnEnable;
  final bool restoreEmpty;
  final String status;
  final String id;
  final List<QualityOption> qualityOptions;
  int enableCalls = 0;
  int restoreCalls = 0;
  Completer<void>? gate;
  @override
  ExtensionState build() => ExtensionState(
    isInitialized: true,
    extensions: available
        ? [
            Extension(
              id: id,
              name: 'example',
              displayName: 'Example',
              version: '1',
              description: '',
              enabled: enabled,
              status: status,
              hasDownloadProvider: true,
              qualityOptions: qualityOptions,
            ),
          ]
        : const [],
  );
  @override
  Future<void> setExtensionEnabled(
    String extensionId,
    bool enabled, {
    bool reconcilePreferences = true,
  }) async {
    enableCalls++;
    await gate?.future;
    if (fail) return;
    state = state.copyWith(
      extensions: [
        for (final e in state.extensions)
          if (e.id == extensionId)
            e.copyWith(
              enabled: enabled,
              status: breakOnEnable ? 'error' : e.status,
            )
          else
            e,
      ],
    );
  }

  @override
  Future<void> installBundledExtensions({
    bool reconcilePreferences = true,
  }) async {
    restoreCalls++;
    await gate?.future;
    if (fail) {
      state = state.copyWith(error: 'secret detail');
      return;
    }
    if (restoreEmpty) {
      state = state.copyWith(extensions: const []);
      return;
    }
    state = state.copyWith(
      extensions: [
        const Extension(
          id: 'restored',
          name: 'Restored',
          displayName: 'Restored',
          version: '1',
          description: '',
          enabled: true,
          status: 'loaded',
          hasDownloadProvider: true,
        ),
      ],
    );
  }

  void removeProviders() => state = state.copyWith(extensions: []);
}

void main() {
  Future<ProviderContainer> launch(
    WidgetTester tester, {
    required bool available,
    Locale? locale,
    _Extensions? extensions,
    _Settings? settings,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsProvider.overrideWith(() => settings ?? _Settings()),
          extensionProvider.overrideWith(
            () => extensions ?? _Extensions(available),
          ),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPlaybackProviderSetup(context),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    final container = ProviderScope.containerOf(
      tester.element(find.text('Open')),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('no provider offers restoring and no selection', (tester) async {
    final container = await launch(tester, available: false);
    expect(find.text('No audio sources are installed.'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).defaultService, isEmpty);
  });

  testWidgets('with sources it only points to the settings page', (
    tester,
  ) async {
    final container = await launch(tester, available: true);
    expect(
      find.text('Provider and quality are chosen in one place: Settings, Listening.'),
      findsOneWidget,
    );
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(find.text('Save'), findsNothing);
    expect(find.text('Open settings'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).defaultService, isEmpty);
    expect(container.read(settingsProvider).audioQuality, isEmpty);
  });

  testWidgets('failed restoration shows sanitized error', (tester) async {
    final extensions = _Extensions(false, fail: true);
    await launch(tester, available: false, extensions: extensions);
    await tester.tap(find.text('Restore built-in sources'));
    await tester.pumpAndSettle();
    expect(
      find.text('Could not restore the built-in sources. Try again.'),
      findsOneWidget,
    );
    expect(find.text('secret detail'), findsNothing);
  });

  testWidgets('restoring with nothing available says so', (tester) async {
    final extensions = _Extensions(false, restoreEmpty: true);
    await launch(tester, available: false, extensions: extensions);
    await tester.tap(find.text('Restore built-in sources'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'No audio source is available after restoring. Check your connection and try again.',
      ),
      findsOneWidget,
    );
  });
}
