import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/lyrics_timing_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/lyrics_sync.dart';
import 'package:mornye/utils/synced_lyrics_scroll.dart';
import 'package:mornye/widgets/lyrics_sync_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

LyricLine _l(int ms, String text) => LyricLine(
  time: Duration(milliseconds: ms),
  text: text,
);

List<LyricLine> _song(int shiftMs, {int count = 8}) => [
  for (var i = 0; i < count; i++) _l(i * 10000 + shiftMs, 'Invented line $i'),
];

const _served =
    '[00:01.00]Alpha beta gamma\n'
    '[00:05.00]Delta epsilon zeta\n'
    '[00:09.00]Eta theta iota';

MediaItem _item() => playableFromCatalogTrack(
  Track(
    id: 'one',
    source: 'spotify',
    name: 'Invented song',
    artistName: 'Invented artist',
    albumName: 'Invented album',
    duration: 120,
    isrc: 'ZZ0000000009',
  ),
).toMediaItem();

PlayerMetadataController _controller() => PlayerMetadataController(
  onlineAvailable: () async => true,
  fetchOnlineLyrics: (_) async => _served,
  parseLyrics: (raw) async => LyricsParser.parse(raw),
  saveOnlineLyrics: (_, _) async {},
  fetchSecondaryLyrics: (_, _) async => null,
);

Future<void> _load(PlayerMetadataController controller) async {
  await controller.load(_item());
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('duration validation', () {
    final lines = _song(0, count: 12);

    test('a last line inside the track is trusted', () {
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: const Duration(seconds: 125),
        ),
        LyricsSyncConfidence.high,
      );
    });

    test('a last line well past the end is suspect, a little past is low', () {
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: const Duration(seconds: 90),
        ),
        LyricsSyncConfidence.suspect,
      );
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: const Duration(seconds: 106),
        ),
        LyricsSyncConfidence.low,
      );
    });

    test('a track far longer than the lyrics span is suspect', () {
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: const Duration(minutes: 5),
        ),
        LyricsSyncConfidence.suspect,
      );
    });

    test('a declared length is compared directly', () {
      const track = Duration(seconds: 200);
      expect(
        lrcDeclaredLength('[ar:x]\n[length: 03:22]\n[00:01.00]a'),
        const Duration(minutes: 3, seconds: 22),
      );
      Duration declared(int seconds) => Duration(seconds: seconds);
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: track,
          declaredLength: declared(202),
        ),
        LyricsSyncConfidence.high,
      );
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: track,
          declaredLength: declared(207),
        ),
        LyricsSyncConfidence.low,
      );
      expect(
        lyricsDurationConfidence(
          lines: lines,
          trackDuration: track,
          declaredLength: declared(230),
        ),
        LyricsSyncConfidence.suspect,
      );
    });

    test('an unknown track length cannot be judged', () {
      expect(
        lyricsDurationConfidence(lines: lines, trackDuration: null),
        LyricsSyncConfidence.unknown,
      );
      expect(
        lyricsConfidenceBeats(
          LyricsSyncConfidence.high,
          LyricsSyncConfidence.low,
        ),
        isTrue,
      );
    });
  });

  group('constant offset estimate', () {
    test('uses the median of matching lines', () {
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: _song(-2300)),
        2300,
      );
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: _song(1500)),
        -1500,
      );
    });

    test('ignores a few outliers but not a drifting source', () {
      final noisy = _song(-1000);
      noisy[2] = _l(noisy[2].time.inMilliseconds + 4000, 'Invented line 2');
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: noisy),
        1000,
      );
      final drifting = [
        for (var i = 0; i < 8; i++) _l(i * 10000 - i * 900, 'Invented line $i'),
      ];
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: drifting),
        isNull,
      );
    });

    test('does nothing for tiny, huge or unsupported shifts', () {
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: _song(-300)),
        isNull,
      );
      expect(
        estimateConstantOffsetMs(reference: _song(0), candidate: _song(-9000)),
        isNull,
      );
      expect(
        estimateConstantOffsetMs(
          reference: _song(0),
          candidate: [_l(0, 'Invented line 1'), _l(5, 'Other')],
        ),
        isNull,
      );
    });
  });

  group('effective offset', () {
    test('composes global, automatic, Bluetooth and look-ahead', () {
      expect(effectiveLyricsOffsetMs(globalMs: 0), -kLyricsLookAheadMs);
      expect(
        effectiveLyricsOffsetMs(globalMs: 50, autoMs: 600, bluetooth: true),
        50 + 600 + kBluetoothLyricsCompensationMs - kLyricsLookAheadMs,
      );
    });

    test('a track offset overrides automatic timing and Bluetooth', () {
      expect(
        effectiveLyricsOffsetMs(
          globalMs: 100,
          trackMs: -400,
          autoMs: 600,
          bluetooth: true,
        ),
        100 - 400 - kLyricsLookAheadMs,
      );
    });

    test('tap timing yields the shift between sung and heard', () {
      expect(
        trackOffsetFromTap(
          tapPosition: const Duration(milliseconds: 12500),
          lineTime: const Duration(milliseconds: 10000),
          globalMs: 100,
        ),
        2400,
      );
    });

    test('the log line carries timing but no text', () {
      final line = lyricsSyncLogLine(
        provider: 'invented',
        trackDuration: const Duration(seconds: 100),
        span: lyricsSpan(_song(0)),
        confidence: LyricsSyncConfidence.low,
        autoMs: 600,
        trackMs: null,
      );
      expect(
        line,
        'lyrics-sync: provider=invented dur=100000 first=0 last=70000 '
        'conf=low auto=600 track=0ms ahead=${kLyricsLookAheadMs}ms '
        'bt=${kBluetoothLyricsCompensationMs}ms kind=synced upgrade=none',
      );
    });
  });

  group('clock reconciliation', () {
    Duration ms(int v) => Duration(milliseconds: v);

    test('a seek, a deck change or a crossfade jump snaps to the report', () {
      for (final jump in [450, -450, 8000, -30000]) {
        expect(
          reconcileSyncedLyricsPosition(
            predictedPosition: ms(60000),
            reportedPosition: ms(60000 + jump),
          ),
          ms(60000 + jump),
        );
      }
    });

    test('small jitter is blended instead of jumping', () {
      expect(
        reconcileSyncedLyricsPosition(
          predictedPosition: ms(1000),
          reportedPosition: ms(1200),
        ),
        ms(1050),
      );
      expect(
        reconcileSyncedLyricsPosition(
          predictedPosition: ms(1000),
          reportedPosition: ms(900),
        ),
        ms(975),
      );
    });

    test('a paused or loading clock does not extrapolate', () {
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: ms(5000),
          elapsedSinceAnchor: ms(900),
          isPlaying: false,
        ),
        ms(5000),
      );
      expect(
        interpolatedSyncedLyricsPosition(
          anchorPosition: ms(5000),
          elapsedSinceAnchor: ms(-5),
          isPlaying: true,
        ),
        ms(5000),
      );
    });
  });

  testWidgets('the Sync control saves a shift for this track only', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = _controller();
    addTearDown(controller.dispose);
    await tester.runAsync(() => _load(controller));
    expect(controller.canAdjustSync, isTrue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [lyricsOutputPlatformProvider.overrideWithValue(null)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('es'),
          home: Scaffold(body: LyricsSyncControl(metadata: controller)),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('lyrics-sync-plus-1')));
    await tester.tap(find.byKey(const ValueKey('lyrics-sync-plus-01')));
    await tester.pump();
    expect(controller.trackOffsetMs, 1100);
    expect(find.text('+1.1 s'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('lyrics_track_offsets_v1'), contains('1100'));

    final other = _controller();
    addTearDown(other.dispose);
    await tester.runAsync(() => _load(other));
    expect(other.trackOffsetMs, 1100);

    await tester.tap(find.byKey(const ValueKey('lyrics-sync-reset')));
    await tester.pump();
    expect(controller.trackOffsetMs, isNull);

    final applied = ProviderContainer(
      overrides: [lyricsOutputPlatformProvider.overrideWithValue(null)],
    );
    addTearDown(applied.dispose);
    expect(
      applied.read(lyricsTimingOffsetProvider((trackMs: 1100, autoMs: 0))),
      1100 - kLyricsLookAheadMs,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
