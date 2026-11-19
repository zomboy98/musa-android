import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/theme/app_theme.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/app_icon.dart';
import 'package:mornye/widgets/app_loading_indicator.dart';
import 'package:mornye/widgets/expressive_playback_transport.dart';
import 'package:mornye/widgets/mornye_playback_button.dart';
import 'package:mornye/widgets/playback_loading_pulse.dart';
import 'package:mornye/widgets/playback_seek_slider.dart';
import 'package:mornye/widgets/player_compact_bar.dart';

class _Player extends MusicPlayerController {
  final calls = <String>[];

  @override
  Future<void> togglePlayPause(bool isPlaying) async =>
      calls.add(isPlaying ? 'pause' : 'play');
}

final playGlyph = find.byWidgetPredicate(
  (w) => w is AppIcon && w.icon == Icons.play_arrow,
);

void main() {
  Widget slider({required bool loading, bool disableAnimations = false}) =>
      MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PlaybackSeekSlider(
              position: Duration.zero,
              duration: const Duration(minutes: 3),
              onSeek: (_) async {},
              loading: loading,
            ),
          ),
        ),
      );

  testWidgets('the timeline pulses while loading and stops with a fade', (
    tester,
  ) async {
    await tester.pumpWidget(slider(loading: false));
    expect(find.byKey(playbackLoadingPulseKey), findsNothing);

    await tester.pumpWidget(slider(loading: true));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(playbackLoadingPulseKey), findsOneWidget);
    expect(tester.hasRunningAnimations, isTrue);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(
      tester.getSemantics(find.byKey(playbackLoadingPulseKey)),
      matchesSemantics(label: 'Loading', isLiveRegion: true),
    );

    await tester.pumpWidget(slider(loading: false));
    await tester.pump(const Duration(milliseconds: 100));
    // Mid-fade: still there.
    expect(find.byKey(playbackLoadingPulseKey), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.byKey(playbackLoadingPulseKey), findsNothing);
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('reduced motion shows a still, faint highlight', (tester) async {
    await tester.pumpWidget(slider(loading: true, disableAnimations: true));
    await tester.pump();
    expect(find.byKey(playbackLoadingPulseKey), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await tester.pumpWidget(slider(loading: false, disableAnimations: true));
    await tester.pumpAndSettle();
    expect(find.byKey(playbackLoadingPulseKey), findsNothing);
  });

  testWidgets('a disabled TickerMode keeps the pulse from ticking', (
    tester,
  ) async {
    await tester.pumpWidget(
      TickerMode(enabled: false, child: slider(loading: true)),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.hasRunningAnimations, isFalse);
  });

  test('the heartbeat envelope has two beats and a rest', () {
    expect(heartbeatEnvelope(0.22), closeTo(1, 1e-9));
    expect(heartbeatEnvelope(0.44), closeTo(0.7, 1e-9));
    expect(heartbeatEnvelope(0.33), lessThan(0.4));
    expect(heartbeatEnvelope(0.95), lessThan(0.01));
  });

  testWidgets('Mornye play button shows a spinner and ignores taps while loading', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MornyePlaybackButton(
            icon: Icons.play_arrow,
            tooltip: 'Play',
            color: Colors.white,
            loading: true,
            onPressed: () => taps++,
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.play_arrow), findsNothing);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(taps, 0);
  });

  testWidgets(
    'expressive transport shows a spinner and ignores taps while loading',
    (tester) async {
      final scheme = ColorScheme.fromSeed(seedColor: Colors.teal);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(localizationsDelegates: AppLocalizations.localizationsDelegates,supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ExpressivePlaybackTransport(
              colorScheme: scheme,
              playing: false,
              loading: true,
              playTooltip: 'Play',
              previousTooltip: 'Previous',
              nextTooltip: 'Next',
              onPlayPause: () => taps++,
              onPrevious: () {},
              onNext: () {},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(playGlyph, findsNothing);
      expect(find.byType(AppLoadingIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(taps, 0);
    },
  );

  testWidgets('compact bar: play spins, timeline pulses, tap is ignored', (
    tester,
  ) async {
    final player = _Player();
    final seekPreview = PlaybackSeekPreview();
    addTearDown(seekPreview.dispose);
    final theme = AppTheme.light();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          playbackPlayingProvider.overrideWith((ref) => false),
          playbackLoadingProvider.overrideWith((ref) => true),
          playbackPositionProvider.overrideWith((ref) => Duration.zero),
          musicPlayerControllerProvider.overrideWithValue(player),
        ],
        child: MaterialApp(
          theme: theme,
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: PlayerCompactBar(
                mediaItem: const MediaItem(
                  id: 'song',
                  title: 'Song',
                  artist: 'Artist',
                  duration: Duration(minutes: 2),
                ),
                seekPreview: seekPreview,
                colorScheme: theme.colorScheme,
                onOpenQueue: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(playGlyph, findsNothing);
    expect(find.byType(AppLoadingIndicator), findsOneWidget);
    expect(find.byKey(playbackLoadingPulseKey), findsOneWidget);
    expect(find.text('0:00'), findsOneWidget);
    final l10n = AppLocalizations.of(tester.element(find.text('Song')));
    await tester.tap(find.byTooltip(l10n.tooltipPlay));
    await tester.pump();
    expect(player.calls, isEmpty);
  });
}
