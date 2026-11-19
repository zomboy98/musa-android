import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/providers/extension_provider.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/app_navigation_service.dart';
import 'package:mornye/services/catalog_playback.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/services/verification_contract.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/playback_feedback.dart';
import 'package:mornye/widgets/verification_prompts.dart';

class _Settings extends SettingsNotifier {
  _Settings(this.service);
  final String service;
  @override
  AppSettings build() => AppSettings(defaultService: service);
}

class _Extensions extends ExtensionNotifier {
  @override
  ExtensionState build() => const ExtensionState(
    isInitialized: true,
    extensions: [
      Extension(
        id: 'prov',
        name: 'prov',
        displayName: 'Prov',
        version: '1',
        description: '',
        enabled: true,
        status: 'loaded',
      ),
    ],
  );
}

class _Pushes extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute != null) pushes++;
  }
}

const _verificationError =
    'CatalogPlaybackException: provider intervention required';
const _chip = 'Verification pending · Prov';
const _body = "Prov needs you to confirm it's you. Tap Verify.";

void main() {
  late StreamController<PlaybackState> states;
  late List<String> opened;
  late _Pushes pushes;
  Future<void> Function() gate = () async {};

  Future<void> pumpApp(
    WidgetTester tester, {
    String service = '',
    Widget? home,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final runtime = MusicPlayerRuntime();
    addTearDown(runtime.dispose);
    states = StreamController<PlaybackState>();
    addTearDown(states.close);
    opened = [];
    pushes = _Pushes();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          playbackStateProvider.overrideWith((_) => states.stream),
          settingsProvider.overrideWith(() => _Settings(service)),
          extensionProvider.overrideWith(_Extensions.new),
          interimVerificationFacadeProvider.overrideWithValue(
            InterimVerificationFacade(
              openVerification: (id, _) async {
                opened.add(id);
                await gate();
                return false;
              },
            ),
          ),
        ],
        child: MaterialApp(
          navigatorKey: AppNavigationService.rootNavigatorKey,
          navigatorObservers: [pushes],
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
          home: Scaffold(
            body: Column(
              children: [
                const PendingVerificationChip(),
                Expanded(child: home ?? const SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> fail(WidgetTester tester) async {
    states.add(
      PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: _verificationError,
        queueIndex: 0,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  }

  setUp(() => catalogPlayback.verificationBlock.value = null);

  testWidgets('unknown provider: generic notice with Verify provider action', (
    tester,
  ) async {
    await pumpApp(tester);
    await fail(tester);
    expect(
      find.text(
        "A provider needs you to confirm it's you. Tap Verify provider.",
      ),
      findsOneWidget,
    );
    expect(find.text('Verify provider'), findsNWidgets(2));
    await tester.tap(find.widgetWithText(TextButton, 'Verify provider'));
    await tester.pump();
    expect(pushes.pushes, 1);
    expect(opened, isEmpty);
    tester.takeException();
  });

  testWidgets('known provider: names it and verifies it', (tester) async {
    await pumpApp(tester);
    final release = Completer<void>();
    gate = () => release.future;
    addTearDown(() => gate = () async {});
    catalogPlayback.verificationBlock.value = CatalogVerificationBlock(
      trackKey: 'k',
      extensionId: 'prov',
    );
    await fail(tester);
    expect(
      find.text('Complete the Prov verification to play this song.'),
      findsOneWidget,
    );
    expect(find.text(_body), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Verify'));
    await tester.pump();
    expect(opened, ['prov']);
    expect(find.text('Opening verification…'), findsWidgets);
    release.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('default provider resolves when error and block are empty', (
    tester,
  ) async {
    await pumpApp(tester, service: 'prov');
    await fail(tester);
    expect(
      find.text('Complete the Prov verification to play this song.'),
      findsOneWidget,
    );
  });

  testWidgets('the notice outlives 15 s and tapping the body verifies', (
    tester,
  ) async {
    await pumpApp(tester, service: 'prov');
    await fail(tester);
    await tester.pump(const Duration(seconds: 16));
    await tester.pumpAndSettle();
    expect(find.text(_body), findsOneWidget);
    await tester.tap(find.text(_body));
    await tester.pump();
    expect(opened, ['prov']);
    await tester.pumpAndSettle();
  });

  testWidgets(
    'the chip stays while blocked and leaves when playback recovers',
    (tester) async {
      await pumpApp(tester, service: 'prov');
      expect(find.text(_chip), findsNothing);
      await fail(tester);
      expect(find.text(_chip), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold)),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(minutes: 3));
      expect(find.text(_chip), findsOneWidget);
      await tester.tap(find.text(_chip));
      await tester.pump();
      expect(opened, ['prov']);
      await tester.pumpAndSettle();
      states.add(
        PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
          queueIndex: 0,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(_chip), findsNothing);
    },
  );

  testWidgets('a search verification failure offers the action', (
    tester,
  ) async {
    var retried = 0;
    await pumpApp(
      tester,
      service: 'prov',
      home: SearchVerificationCard(
        extensionId: null,
        onResumed: () => retried++,
      ),
    );
    expect(find.text('Verify'), findsOneWidget);
    await tester.tap(find.text('Verify'));
    await tester.pump();
    expect(opened, ['prov']);
    expect(retried, 0);
    await tester.pumpAndSettle();
  });
}
