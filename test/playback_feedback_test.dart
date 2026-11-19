import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/services/music_player_service.dart';
import 'package:mornye/services/remote_playback.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/services/music_player_runtime.dart';
import 'package:mornye/theme/mornye_theme.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/mornye_chrome.dart';
import 'package:mornye/widgets/playback_feedback.dart';

class _FeedbackRemote extends Fake implements RemotePlayback {
  _FeedbackRemote(this.mediaItems);

  @override
  final Stream<MediaItem?> mediaItems;
}

class _FeedbackMediaItems extends CurrentMediaItemNotifier {
  _FeedbackMediaItems(this.items);

  final Stream<MediaItem?> items;

  @override
  Stream<MediaItem?> build() => items;
}

class _FeedbackHandler extends Fake implements MusicPlayerHandler {
  @override
  int playbackRequestGeneration = 0;
}

class _FeedbackRuntime extends MusicPlayerRuntime {
  @override
  final _FeedbackHandler handler = _FeedbackHandler();
}

void main() {
  for (final locale in [const Locale('es'), const Locale('es', 'ES')]) {
    test('catalog messages are localized for $locale', () async {
      final l10n = await AppLocalizations.delegate.load(locale);
      expect(
        l10n.playbackProviderUnavailable,
        'No hay ningún proveedor de reproducción disponible.',
      );
      expect(
        l10n.playbackVerificationRequired,
        'Completa la verificación del proveedor para reproducir esta canción.',
      );
    });
  }
  for (final mornye in [false, true]) {
    testWidgets('playback errors show themed feedback (Mornye: $mornye)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      final states = StreamController<PlaybackState>();
      addTearDown(states.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            playbackStateProvider.overrideWith((_) => states.stream),
          ],
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final failed = PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: 'Audio output failed',
      );
      states.add(failed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(
        find.text('Cannot open file: Audio output failed'),
        findsOneWidget,
      );
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      states.add(failed.copyWith(updatePosition: const Duration(seconds: 1)));
      await tester.pumpAndSettle();
      expect(find.text('Cannot open file: Audio output failed'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'superseded errors do not linger after playback recovers ($mornye)',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        final runtime = MusicPlayerRuntime();
        addTearDown(runtime.dispose);
        final states = StreamController<PlaybackState>();
        addTearDown(states.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              musicPlayerRuntimeProvider.overrideWithValue(runtime),
              playbackStateProvider.overrideWith((_) => states.stream),
            ],
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
              builder: (_, child) =>
                  AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
              home: const Scaffold(body: SizedBox.expand()),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final failed = PlaybackState(
          processingState: AudioProcessingState.error,
          errorCode: 1,
          errorMessage: 'Cancelled source',
        );
        final ready = PlaybackState(
          processingState: AudioProcessingState.ready,
          playing: true,
        );
        states.add(failed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        states.add(ready);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('Cannot open file: Cancelled source'), findsNothing);

        // A lasting failure is still visible, then clears when playback works.
        states.add(failed);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.text('Cannot open file: Cancelled source'), findsOneWidget);
        states.add(ready);
        await tester.pumpAndSettle();
        expect(find.text('Cannot open file: Cancelled source'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('muted feedback is transient and themed (Mornye: $mornye)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      // Notices emitted before the shell mounts must not be replayed.
      runtime.notifyMutedPlayback();
      final message = mornye
          ? 'Volume media nol. Lagu dijeda. Tekan play lagi untuk tetap memutar.'
          : 'Media volume is zero. Playback paused. Press play again to continue.';
      await tester.pumpWidget(
        ProviderScope(
          overrides: [musicPlayerRuntimeProvider.overrideWithValue(runtime)],
          child: MaterialApp(
            locale: Locale(mornye ? 'id' : 'en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            theme: mornye ? MornyeTheme.build(Brightness.dark) : ThemeData(),
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(
        find.byType(MornyeGlassPanel),
        mornye ? findsOneWidget : findsNothing,
      );
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text(message), findsNothing);
      // A later mute episode may emit the exact same warning again.
      runtime.notifyMutedPlayback();
      await tester.pumpAndSettle();
      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('temporary preparation failure shows safe feedback once', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final runtime = MusicPlayerRuntime();
    addTearDown(runtime.dispose);
    final states = StreamController<PlaybackState>();
    addTearDown(states.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          playbackStateProvider.overrideWith((_) => states.stream),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final failed = PlaybackState(
      processingState: AudioProcessingState.error,
      errorCode: 1,
      errorMessage: 'CatalogPlaybackException: provider download failed',
    );
    void setBackground(bool background) {
      final states = background
          ? [
              AppLifecycleState.inactive,
              AppLifecycleState.hidden,
              AppLifecycleState.paused,
            ]
          : [
              AppLifecycleState.hidden,
              AppLifecycleState.inactive,
              AppLifecycleState.resumed,
            ];
      for (final state in states) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
    }

    setBackground(true);
    states.add(failed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SnackBar), findsNothing);
    setBackground(false);
    await tester.pumpAndSettle();
    expect(
      find.text('The provider could not retrieve the song. Please try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('CatalogPlaybackException'), findsNothing);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    states.add(failed.copyWith(updatePosition: const Duration(seconds: 1)));
    await tester.pumpAndSettle();
    expect(
      find.text('The provider could not retrieve the song. Please try again.'),
      findsNothing,
    );

    states.add(PlaybackState(queueIndex: 1));
    await tester.pump();
    setBackground(true);
    states.add(failed.copyWith(queueIndex: 1));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    states.add(
      PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: 'CatalogPlaybackException: provider track not found',
        queueIndex: 2,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    setBackground(false);
    await tester.pumpAndSettle();
    expect(find.text('No matching track was found.'), findsOneWidget);
    expect(
      find.text('The provider could not retrieve the song. Please try again.'),
      findsNothing,
    );

    states.add(PlaybackState(queueIndex: 3));
    await tester.pumpAndSettle();
    setBackground(true);
    states.add(failed.copyWith(queueIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    states.add(failed.copyWith(queueIndex: 4));
    await tester.pump();
    setBackground(false);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);

    states.add(PlaybackState(queueIndex: 3));
    await tester.pumpAndSettle();
    setBackground(true);
    states.add(failed.copyWith(queueIndex: 3));
    await tester.pump();
    await tester.pump(const Duration(seconds: 31));
    setBackground(false);
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
  });

  for (final (appMessenger, remote, changeGeneration, leaveForeground) in [
    (false, true, false, false),
    (true, true, false, false),
    (true, false, false, false),
    (true, false, true, false),
    (true, false, false, true),
  ]) {
    testWidgets('track changes discard only playback feedback (app: $appMessenger, remote: $remote, generation: $changeGeneration, inactive: $leaveForeground)', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final runtime = _FeedbackRuntime();
      final states = StreamController<PlaybackState>();
      final items = StreamController<MediaItem?>();
      addTearDown(runtime.dispose);
      addTearDown(states.close);
      addTearDown(items.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            if (remote)
              activeRemotePlaybackProvider.overrideWithValue(
                _FeedbackRemote(items.stream),
              )
            else
              currentMediaItemProvider.overrideWith(
                () => _FeedbackMediaItems(items.stream),
              ),
            playerUiEnabledProvider.overrideWithValue(true),
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            playbackStateProvider.overrideWith((_) => states.stream),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) => appMessenger
                ? AppScaffoldMessenger(child: PlaybackFeedback(child: child!))
                : PlaybackFeedback(child: child!),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      items.add(const MediaItem(id: 'fixture-a', title: 'Fixture A'));
      await tester.pump();
      if (remote) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        states.add(
          PlaybackState(
            processingState: AudioProcessingState.error,
            errorMessage: 'CatalogPlaybackException: provider download failed',
            queueIndex: 0,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        items.add(const MediaItem(id: 'fixture-b', title: 'Fixture B'));
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);

        states.add(PlaybackState(queueIndex: 0));
        await tester.pump();
        states.add(
          PlaybackState(
            processingState: AudioProcessingState.error,
            errorMessage: 'CatalogPlaybackException: provider download failed',
            queueIndex: 0,
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsOneWidget);
        items.add(const MediaItem(id: 'fixture-c', title: 'Fixture C'));
        await tester.pumpAndSettle();
        expect(find.byType(SnackBar), findsNothing);

      }
      states.add(PlaybackState(queueIndex: 0));
      await tester.pump();
      final foreign = ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold)),
      ).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 10),
          content: Text('Unrelated notice'),
        ),
      );
      await tester.pumpAndSettle();
      states.add(
        PlaybackState(
          processingState: AudioProcessingState.error,
          errorMessage: 'CatalogPlaybackException: provider download failed',
          queueIndex: 0,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Unrelated notice'), findsOneWidget);
      if (leaveForeground) {
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      } else if (changeGeneration) {
        // No PlaybackState or MediaItem emission before the queue advances.
        runtime.handler.playbackRequestGeneration++;
      } else {
        items.add(const MediaItem(id: 'fixture-d', title: 'Fixture D'));
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Unrelated notice'), findsOneWidget);
      foreign.close();
      await tester.pumpAndSettle();
      if (leaveForeground) {
        expect(find.byWidgetPredicate((widget) => widget is SnackBar), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
      }
      expect(find.byWidgetPredicate((widget) => widget is SnackBar), findsNothing);
    });
  }

  for (final (category, expected) in <(String, String?)>[
    ('provider track not found', 'No matching track was found.'),
    ('provider unavailable', 'No playback provider is available.'),
    (
      'provider intervention required',
      'Complete the provider verification to play this song.',
    ),
    ('AAC conversion failed', 'Could not convert the song for playback.'),
    ('invalid Opus output', 'Could not convert the song for playback.'),
    (
      'https://secret.test/token?key=private',
      'Could not prepare the song. Please try again.',
    ),
    ('cancelled', null),
  ]) {
    testWidgets('catalog feedback safely handles $category', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final runtime = MusicPlayerRuntime();
      addTearDown(runtime.dispose);
      final states = StreamController<PlaybackState>();
      addTearDown(states.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicPlayerRuntimeProvider.overrideWithValue(runtime),
            playbackStateProvider.overrideWith((_) => states.stream),
          ],
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            builder: (_, child) =>
                AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
            home: const Scaffold(body: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      states.add(
        PlaybackState(
          processingState: AudioProcessingState.error,
          errorCode: 1,
          errorMessage: 'CatalogPlaybackException: $category',
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      if (expected != null) expect(find.text(expected), findsOneWidget);
      expect(find.textContaining('CatalogPlaybackException'), findsNothing);
      expect(find.textContaining('secret.test'), findsNothing);
      if (expected == null) expect(find.byType(SnackBar), findsNothing);
    });
  }

  testWidgets('an unplayable format is named instead of the raw error', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final runtime = MusicPlayerRuntime();
    addTearDown(runtime.dispose);
    final states = StreamController<PlaybackState>();
    addTearDown(states.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicPlayerRuntimeProvider.overrideWithValue(runtime),
          playbackStateProvider.overrideWith((_) => states.stream),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (_, child) =>
              AppScaffoldMessenger(child: PlaybackFeedback(child: child!)),
          home: const Scaffold(body: SizedBox.expand()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    const skipped =
        "This format can't be played on this device: APE. "
        'Playing the next song.';
    runtime.notifyUnplayableSong('APE', skipped: true);
    await tester.pumpAndSettle();
    expect(find.text(skipped), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpAndSettle();
    expect(find.text(skipped), findsNothing);

    // Playback stops on the last song; its error needs no second notice.
    runtime.notifyUnplayableSong('WavPack', skipped: false);
    states.add(
      PlaybackState(
        processingState: AudioProcessingState.error,
        errorCode: 1,
        errorMessage: 'Cannot Open',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(
      find.text("This format can't be played on this device: WavPack"),
      findsOneWidget,
    );
    expect(find.text('Cannot open file: Cannot Open'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
