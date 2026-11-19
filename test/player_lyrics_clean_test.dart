import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/controllers/player_metadata_controller.dart';
import 'package:mornye/l10n/app_localizations.dart';
import 'package:mornye/models/settings.dart';
import 'package:mornye/models/track.dart';
import 'package:mornye/providers/music_player_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/playable_media.dart';
import 'package:mornye/services/track_video_source.dart';
import 'package:mornye/services/track_video_tags.dart';
import 'package:mornye/utils/lyrics_parser.dart';
import 'package:mornye/utils/playback_seek_preview.dart';
import 'package:mornye/widgets/lyrics_line_correction.dart';
import 'package:mornye/widgets/player_lyrics_preview.dart';
import 'package:mornye/widgets/player_lyrics_section.dart';
import 'package:mornye/widgets/player_song_journey.dart';
import 'package:mornye/widgets/settings_group.dart';
import 'package:mornye/widgets/track_video_chip.dart';
import 'package:mornye/widgets/track_video_gate.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _served =
    '[00:01.00]Alpha beta gamma\n'
    '[00:05.00]Delta epsilon zeta\n'
    '[00:09.00]Eta theta iota';

const _track = Track(
  id: 'catalog-song',
  source: 'spotify',
  name: 'Invented song',
  artistName: 'Invented artist',
  albumName: 'Invented album',
  duration: 120,
  isrc: 'ZZ0000000001',
);

class _Source implements TrackVideoSource {
  _Source(this.offer);
  final TrackVideoOffer? offer;

  @override
  Future<TrackVideoOffer?> offerFor(Track track) async => offer;

  @override
  Future<String?> prepare(Track track, TrackVideoOffer offer) async => null;
}

class _Position extends Notifier<Duration> {
  @override
  Duration build() => const Duration(seconds: 2);
}

final _position = NotifierProvider<_Position, Duration>(_Position.new);

List<Override> _overrides(AppSettings settings) => [
  initialSettingsProvider.overrideWithValue(settings),
  playbackPositionProvider.overrideWith((ref) => ref.watch(_position)),
  playbackPlayingProvider.overrideWith((ref) => false),
  playbackLoadingProvider.overrideWith((ref) => false),
  playbackStateProvider.overrideWith((ref) => Stream.value(PlaybackState())),
];

PlayerMetadataController _controller() => PlayerMetadataController(
  onlineAvailable: () async => true,
  fetchOnlineLyrics: (_) async => _served,
  parseLyrics: (raw) async => LyricsParser.parse(raw),
  saveOnlineLyrics: (_, _) async => fail('A catalog track has no file'),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Widget _host(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: child),
      ),
    );

void _expectNoBox(WidgetTester tester, Finder scope) {
  for (final type in [ClipRRect, BackdropFilter, DecoratedBox, Card]) {
    expect(
      find.descendant(of: scope, matching: find.byType(type)),
      findsNothing,
      reason: '$type draws a box behind the lyrics',
    );
  }
}

void main() {
  late PlayerMetadataController metadata;
  late ProviderContainer container;
  late MediaItem item;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    item = playableFromCatalogTrack(_track).toMediaItem();
    metadata = _controller();
    container = ProviderContainer(overrides: _overrides(const AppSettings()));
    await metadata.load(item);
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  });

  tearDown(() {
    container.dispose();
    metadata.dispose();
  });

  Widget row({required Widget pill, ValueChanged<LyricLine>? onLong}) => Align(
    alignment: Alignment.topLeft,
    child: SizedBox(
      width: 360,
      child: PlayerVideoLyricsRow(
        metadata: metadata,
        onOpenLyrics: () {},
        onLongPressLine: onLong,
        pill: pill,
      ),
    ),
  );

  final preview = find.byKey(const ValueKey('player-lyrics-preview'));

  testWidgets('the preview is plain text: no box, fill, blur or border', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(container, row(pill: const SizedBox.shrink())),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alpha beta gamma'), findsOneWidget);
    _expectNoBox(tester, find.byType(PlayerVideoLyricsRow));
    final text = tester.widget<Text>(find.text('Alpha beta gamma'));
    expect(text.style?.fontWeight, FontWeight.w700);
  });

  testWidgets('the video pill sits left of the lyrics, same row', (
    tester,
  ) async {
    final tags = TrackVideoTags();
    final lookup = TrackVideoLookup(
      tags: tags,
      source: () =>
          _Source(const TrackVideoOffer(provider: 'youtube', videoId: 'abc')),
    );
    await tester.pumpWidget(
      _host(
        container,
        row(
          pill: TrackVideoGate(
            track: _track,
            lookup: lookup,
            onPressed: (_) {},
          ),
        ),
      ),
    );
    await _settle(tester);
    final chip = tester.getRect(find.byType(TrackVideoChip));
    final lyrics = tester.getRect(preview);
    expect(chip.right, lessThanOrEqualTo(lyrics.left));
    expect((chip.center.dy - lyrics.center.dy).abs(), lessThan(2));
    expect(lyrics.right, closeTo(360, 0.01));
  });

  testWidgets('without a video the lyrics take the whole row', (tester) async {
    final lookup = TrackVideoLookup(tags: TrackVideoTags(), source: () => null);
    await tester.pumpWidget(
      _host(
        container,
        row(
          pill: TrackVideoGate(
            track: _track,
            lookup: lookup,
            onPressed: (_) {},
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.byType(TrackVideoChip), findsNothing);
    expect(tester.getRect(preview).left, closeTo(0, 0.01));
    expect(tester.getRect(preview).right, closeTo(360, 0.01));
  });

  testWidgets('hiding by drag still works without a box', (tester) async {
    await tester.pumpWidget(
      _host(container, row(pill: const SizedBox.shrink())),
    );
    await tester.pumpAndSettle();
    await tester.drag(preview, const Offset(200, 0));
    await tester.pumpAndSettle();
    expect(container.read(settingsProvider).playerLyricsPreviewHidden, isTrue);
    expect(find.byIcon(Icons.chevron_left_rounded), findsOneWidget);
    _expectNoBox(tester, find.byType(PlayerVideoLyricsRow));
  });

  testWidgets('holding the preview text corrects the line in both views', (
    tester,
  ) async {
    final preview0 = PlaybackSeekPreview();
    addTearDown(preview0.dispose);
    await tester.pumpWidget(
      _host(
        container,
        Column(
          children: [
            row(
              pill: const SizedBox.shrink(),
              onLong: (line) => showLyricsLineActions(
                tester.element(find.byType(PlayerVideoLyricsRow)),
                metadata,
                line,
              ),
            ),
            Expanded(
              child: PlayerLyricsSection(
                metadata: metadata,
                seekPreview: preview0,
                colorScheme: const ColorScheme.dark(),
                isActive: true,
              ),
            ),
          ],
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Alpha beta gamma'), findsWidgets);

    await tester.longPress(find.text('Alpha beta gamma').first);
    await _settle(tester);
    expect(find.byKey(const ValueKey('lyrics-line-correct')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('lyrics-line-correct')));
    await _settle(tester);
    await tester.enterText(
      find.byKey(const ValueKey('lyrics-line-field')),
      'Alpha beta omega',
    );
    await tester.tap(find.text('Save'));
    await _settle(tester);
    expect(find.text('Alpha beta omega'), findsWidgets);
    expect(find.text('Alpha beta gamma'), findsNothing);
    expect(
      find.descendant(
        of: find.byType(PlayerVideoLyricsRow),
        matching: find.text('Alpha beta omega'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(PlayerLyricsSection),
        matching: find.text('Alpha beta omega'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('holding the lower preview line picks the next line', (
    tester,
  ) async {
    LyricLine? held;
    await tester.pumpWidget(
      _host(
        container,
        row(pill: const SizedBox.shrink(), onLong: (line) => held = line),
      ),
    );
    await tester.pumpAndSettle();
    final top = tester.getTopLeft(find.text('Alpha beta gamma'));
    await tester.longPressAt(top + const Offset(10, 6));
    await tester.pump();
    expect(held?.text, 'Alpha beta gamma');
    final next = tester.getTopLeft(find.text('Delta epsilon zeta'));
    await tester.longPressAt(next + const Offset(10, 6));
    await tester.pump();
    expect(held?.text, 'Delta epsilon zeta');
  });

  testWidgets('the lyrics section has no card and keeps its text', (
    tester,
  ) async {
    final seek = PlaybackSeekPreview();
    addTearDown(seek.dispose);
    await tester.pumpWidget(
      _host(
        container,
        SizedBox(
          height: 300,
          child: PlayerLyricsSection(
            metadata: metadata,
            seekPreview: seek,
            colorScheme: const ColorScheme.dark(),
            isActive: true,
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(find.text('Alpha beta gamma'), findsOneWidget);
    for (final type in [BackdropFilter, Card, VisionGradientCard]) {
      expect(
        find.descendant(
          of: find.byType(PlayerLyricsSection),
          matching: find.byType(type),
        ),
        findsNothing,
      );
    }
  });

  testWidgets('the journey lyrics are a plain heading over the text', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        container,
        PlayerSongJourney(
          item: item,
          metadata: metadata,
          playerHeight: 200,
          player: const SizedBox(),
          lyrics: const Text('lyrics body'),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Lyrics'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Lyrics'),
        matching: find.byType(VisionGradientCard),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('lyrics body'),
        matching: find.byType(VisionGradientCard),
      ),
      findsNothing,
    );
  });

  testWidgets('the correction tip shows once and is remembered', (
    tester,
  ) async {
    final seek = PlaybackSeekPreview();
    addTearDown(seek.dispose);
    Widget section({bool visible = true}) => SizedBox(
      height: 300,
      child: PlayerLyricsSection(
        metadata: metadata,
        seekPreview: seek,
        colorScheme: const ColorScheme.dark(),
        isActive: true,
        showCorrectionHint: visible,
      ),
    );
    const tip = 'Press and hold a line to correct it';

    await tester.pumpWidget(_host(container, section(visible: false)));
    await _settle(tester);
    expect(find.text(tip), findsNothing);
    expect(container.read(settingsProvider).lyricsLineHintShown, isFalse);

    await tester.pumpWidget(_host(container, section()));
    await _settle(tester);
    expect(find.text(tip), findsOneWidget);
    expect(container.read(settingsProvider).lyricsLineHintShown, isTrue);

    final saved = container.read(settingsProvider);
    container.dispose();
    container = ProviderContainer(overrides: _overrides(saved));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_host(container, section()));
    await _settle(tester);
    expect(find.text(tip), findsNothing);
    expect(AppSettings.fromJson(saved.toJson()).lyricsLineHintShown, isTrue);
    expect(AppSettings.fromJson({}).lyricsLineHintShown, isFalse);
  });
}
