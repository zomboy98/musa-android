import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/lyrics_timing_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/lyrics_estimated_sync.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/player_lyrics.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _plain =
    'Invented opening line here\n'
    'Second made up sentence\n'
    'Third imaginary words\n'
    '\n'
    'New stanza begins now\n'
    'Another fictional phrase\n'
    '\n'
    '[Chorus]\n'
    'Sing the invented chorus together';

const _synced =
    '[00:10.00]Invented opening line here\n'
    '[00:20.00]Second made up sentence\n'
    '[00:30.00]Third imaginary words\n'
    '[00:50.00]New stanza begins now\n'
    '[01:00.00]Another fictional phrase\n'
    '[01:30.00]Sing the invented chorus together';

const _wrongVersion =
    '[00:10.00]Invented opening line here\n'
    '[06:40.00]Sing the invented chorus together';

MediaItem _item({int seconds = 120, String id = 'one'}) =>
    playableFromCatalogTrack(
      Track(
        id: id,
        source: 'spotify',
        name: 'Invented song',
        artistName: 'Invented artist',
        albumName: 'Invented album',
        duration: seconds,
        isrc: 'ZZ00000000$id',
      ),
    ).toMediaItem();

PlayerMetadataController _controller({
  required String served,
  required Future<List<({String provider, String raw})>> Function(MediaItem)
  upgrade,
  DateTime Function()? clock,
}) => PlayerMetadataController(
  onlineAvailable: () async => true,
  fetchOnlineLyrics: (_) async => served,
  parseLyrics: (raw) async => LyricsParser.parse(raw),
  saveOnlineLyrics: (_, _) async {},
  fetchSecondaryLyrics: (_, _) async => null,
  fetchUpgradeCandidates: upgrade,
  clock: clock,
);

Future<void> _settle(
  PlayerMetadataController controller,
  MediaItem item,
) async {
  await controller.load(item);
  for (var i = 0; i < 40; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    PlayerMetadataController.resetUpgradeMisses();
  });

  group('estimateSyncedLines', () {
    const duration = Duration(minutes: 3);
    final lines = estimateSyncedLines(plainText: _plain, duration: duration);

    test('places every sung line, skipping blanks and section labels', () {
      expect(lines.length, 6);
      expect(lines.last.text, 'Sing the invented chorus together');
    });

    test('is strictly increasing and stays inside the track', () {
      for (var i = 1; i < lines.length; i++) {
        expect(lines[i].time, greaterThan(lines[i - 1].time));
        expect(lines[i].time, greaterThanOrEqualTo(lines[i - 1].end!));
      }
      expect(lines.last.end!, lessThanOrEqualTo(duration));
    });

    test('leaves an intro and a closing, and covers the rest', () {
      expect(
        lines.first.time,
        greaterThanOrEqualTo(const Duration(seconds: 8)),
      );
      expect(lines.first.time, lessThanOrEqualTo(const Duration(seconds: 15)));
      final closing = duration - lines.last.end!;
      expect(closing, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(closing, lessThanOrEqualTo(const Duration(seconds: 10)));
    });

    test('pauses longer between stanzas than between lines', () {
      Duration gap(int i) => lines[i].time - lines[i - 1].end!;
      expect(gap(3), greaterThan(gap(1)));
      expect(gap(5), greaterThan(gap(4)));
    });

    test('longer lines take longer to sing', () {
      final short = estimateSyncedLines(
        plainText: 'Oh\nA much longer invented line with many syllables',
        duration: const Duration(minutes: 2),
      );
      expect(
        short[1].end! - short[1].time,
        greaterThan(short[0].end! - short[0].time),
      );
    });

    test('has nothing to place without text or length', () {
      expect(estimateSyncedLines(plainText: '', duration: duration), isEmpty);
      expect(
        estimateSyncedLines(plainText: _plain, duration: Duration.zero),
        isEmpty,
      );
    });

    test('plain never replaces synced, synced replaces plain', () {
      final plain = LyricsParser.parse(_plain);
      final synced = LyricsParser.parse(_synced);
      expect(plain.synced, isFalse);
      expect(synced.synced, isTrue);
      expect(lyricsUpgradeAllowed(current: synced, candidate: plain), isFalse);
      expect(lyricsUpgradeAllowed(current: plain, candidate: synced), isTrue);
      final estimated = estimatedLyricsFor(plain, duration)!;
      expect(estimated.estimated, isTrue);
      expect(
        lyricsUpgradeAllowed(current: estimated, candidate: synced),
        isTrue,
      );
      expect(
        lyricsUpgradeAllowed(current: synced, candidate: estimated),
        isFalse,
      );
    });
  });

  group('plain lyrics in the controller', () {
    test(
      'show estimated timing at once and upgrade to synced lyrics',
      () async {
        var asked = 0;
        final controller = _controller(
          served: _plain,
          upgrade: (_) async {
            asked++;
            return [(provider: 'invented', raw: _synced)];
          },
        );
        addTearDown(controller.dispose);
        await _settle(controller, _item());
        expect(asked, 1);
        expect(controller.upgradeState, 'done');
        expect(controller.lyricsEstimated, isFalse);
        expect(controller.lyrics.synced, isTrue);
        expect(controller.lyrics.lines.first.time, const Duration(seconds: 10));
      },
    );

    test('are estimated while no provider has synced lyrics', () async {
      final controller = _controller(
        served: _plain,
        upgrade: (_) async => [(provider: 'invented', raw: _plain)],
      );
      addTearDown(controller.dispose);
      await _settle(controller, _item());
      expect(controller.lyricsEstimated, isTrue);
      expect(controller.lyrics.synced, isTrue);
      expect(controller.upgradeState, 'none');
      expect(controller.canAdjustSync, isTrue);
    });

    test('a version that cannot be this track is not accepted', () async {
      final controller = _controller(
        served: _plain,
        upgrade: (_) async => [(provider: 'invented', raw: _wrongVersion)],
      );
      addTearDown(controller.dispose);
      await _settle(controller, _item());
      expect(controller.lyricsEstimated, isTrue);
      expect(controller.rawLyrics, _plain);
    });

    test('can turn the estimate off', () async {
      final controller = _controller(
        served: _plain,
        upgrade: (_) async => const [],
      );
      addTearDown(controller.dispose);
      await _settle(controller, _item());
      await controller.setEstimatedSyncEnabled(false);
      expect(controller.lyricsEstimated, isFalse);
      expect(controller.lyrics.synced, isFalse);
      expect(controller.lyrics.plainText, isNotEmpty);
    });

    test('a miss is remembered for a while, then asked again', () async {
      var now = DateTime(2030);
      var asked = 0;
      Future<List<({String provider, String raw})>> upgrade(MediaItem _) async {
        asked++;
        return const [];
      }

      Future<void> open() async {
        final controller = _controller(
          served: _plain,
          upgrade: upgrade,
          clock: () => now,
        );
        await _settle(controller, _item());
        controller.dispose();
      }

      await open();
      expect(asked, 1);
      now = now.add(const Duration(minutes: 20));
      await open();
      expect(asked, 1);
      now = now.add(const Duration(minutes: 40));
      await open();
      expect(asked, 2);
    });

    test('synced lyrics are never looked up again', () async {
      var asked = 0;
      final controller = _controller(
        served: _synced,
        upgrade: (_) async {
          asked++;
          return [(provider: 'invented', raw: _plain)];
        },
      );
      addTearDown(controller.dispose);
      await _settle(controller, _item());
      expect(asked, 0);
      expect(controller.lyricsEstimated, isFalse);
      expect(controller.lyrics.synced, isTrue);
      expect(controller.upgradeState, 'none');
    });
  });

  testWidgets('the credit names the approximate sync', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('es'),
        home: const Scaffold(body: LyricsCredits(estimated: true)),
      ),
    );
    expect(find.text('Sincronía aproximada'), findsOneWidget);
  });

  testWidgets('the screen goes from approximate to real synced lyrics', (
    tester,
  ) async {
    final late = Completer<List<({String provider, String raw})>>();
    final controller = _controller(served: _plain, upgrade: (_) => late.future);
    final preview = PlaybackSeekPreview();
    addTearDown(controller.dispose);
    addTearDown(preview.dispose);
    await tester.runAsync(() => _settle(controller, _item()));
    expect(controller.lyricsEstimated, isTrue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [lyricsOutputPlatformProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(
            body: PlayerLyricsSection(
              metadata: controller,
              seekPreview: preview,
              colorScheme: const ColorScheme.dark(),
              isActive: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(SyncedLyricsView), findsOneWidget);
    expect(find.text('Third imaginary words'), findsOneWidget);

    late.complete([(provider: 'invented', raw: _synced)]);
    await tester.runAsync(() async {
      for (var i = 0; i < 40; i++) {
        await Future<void>.delayed(Duration.zero);
      }
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.upgradeState, 'done');
    expect(find.byType(AnimatedSwitcher), findsWidgets);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(SyncedLyricsView), findsOneWidget);
    expect(find.text('Third imaginary words'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
